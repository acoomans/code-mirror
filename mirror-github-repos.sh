#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Mirror all repositories for a GitHub account.

Usage:
  mirror-github-repos.sh --account ACCOUNT [--dest DIR] [--token TOKEN] [--token-file FILE] [--dry-run] [--skip-forks] [--repo-regex REGEX] [--with-lfs]

Options:
  -a, --account ACCOUNT   GitHub user or organization name (required)
  -d, --dest DIR          Destination directory for mirrored repos (default: ./mirrors)
  -t, --token TOKEN       GitHub token (or set GITHUB_TOKEN env var)
  -T, --token-file FILE   Read .env-style credentials file (ACCOUNT/GITHUB_TOKEN)
  -n, --dry-run           Print planned actions without cloning/fetching
  -s, --skip-forks        Skip repositories where "fork" is true
  -r, --repo-regex REGEX  Only process repositories whose name matches REGEX
  -l, --with-lfs          Fetch Git LFS objects with --all after mirror/update
  -h, --help              Show this help

Notes:
  - Existing mirrors are updated with fetch --prune.
  - New repositories are mirrored with git clone --mirror.
  - LFS objects are fetched only when --with-lfs is enabled.
  - Credential file supports ACCOUNT/GITHUB_ACCOUNT and TOKEN/GITHUB_TOKEN.
  - For private repositories, pass a token with appropriate permissions.
  - Uses curl when available, otherwise falls back to wget.
EOF
}

err() {
  echo "Error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || err "Required command not found: $1"
}

select_http_client() {
  if command -v curl >/dev/null 2>&1; then
    HTTP_CLIENT="curl"
  elif command -v wget >/dev/null 2>&1; then
    HTTP_CLIENT="wget"
  else
    err "Required command not found: curl or wget"
  fi
}

url_encode() {
  local str="$1"
  local out=""
  local i c
  for ((i=0; i<${#str}; i++)); do
    c="${str:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  printf '%s' "$out"
}

extract_json_string_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "$json" | awk -v key="$field" '
    BEGIN {
      pattern = "\"" key "\"[[:space:]]*:[[:space:]]*\""
    }
    {
      if (match($0, pattern)) {
        rest = substr($0, RSTART + RLENGTH)
        if (match(rest, /\"/)) {
          print substr(rest, 1, RSTART - 1)
          exit
        }
      }
    }
  '
}

json_repo_name_and_fork() {
  local json="$1"

  local names forks
  names="$(printf '%s\n' "$json" | awk '
    {
      line = $0
      while (match(line, /"full_name"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        token = substr(line, RSTART, RLENGTH)
        sub(/^"full_name"[[:space:]]*:[[:space:]]*"/, "", token)
        sub(/"$/, "", token)
        print token
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ')"

  forks="$(printf '%s\n' "$json" | awk '
    {
      line = $0
      while (match(line, /"fork"[[:space:]]*:[[:space:]]*(true|false)/)) {
        token = substr(line, RSTART, RLENGTH)
        sub(/^"fork"[[:space:]]*:[[:space:]]*/, "", token)
        print token
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ')"

  if [[ -z "$names" || -z "$forks" ]]; then
    return 0
  fi

  paste <(printf '%s\n' "$names") <(printf '%s\n' "$forks") | awk -F'\t' '
    NF >= 2 && $1 != "" && ($2 == "true" || $2 == "false")
  '
}

http_get() {
  local url="$1"
  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    if [[ -n "$TOKEN" ]]; then
      curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer ${TOKEN}" "$url"
    else
      curl -fsSL -H "Accept: application/vnd.github+json" "$url"
    fi
  else
    if [[ -n "$TOKEN" ]]; then
      wget -qO- --header="Accept: application/vnd.github+json" --header="Authorization: Bearer ${TOKEN}" "$url"
    else
      wget -qO- --header="Accept: application/vnd.github+json" "$url"
    fi
  fi
}

get_account_type() {
  local account="$1"
  local data
  data="$(http_get "https://api.github.com/users/${account}")" || return 1
  extract_json_string_field "$data" "type"
}

get_authenticated_login() {
  [[ -z "$TOKEN" ]] && return 0
  local data
  data="$(http_get "https://api.github.com/user")" || return 1
  extract_json_string_field "$data" "login"
}

list_repos() {
  local account="$1"
  local account_type="$2"
  local auth_login="$3"

  local page=1
  local endpoint=""
  local page_data=""
  local rows=""

  while :; do
    if [[ -n "$TOKEN" && -n "$auth_login" && "$account" == "$auth_login" ]]; then
      endpoint="https://api.github.com/user/repos?type=owner&per_page=100&page=${page}"
    elif [[ "$account_type" == "Organization" ]]; then
      endpoint="https://api.github.com/orgs/${account}/repos?type=all&per_page=100&page=${page}"
    else
      endpoint="https://api.github.com/users/${account}/repos?type=owner&per_page=100&page=${page}"
    fi

    page_data="$(http_get "$endpoint")" || {
      echo "Failed to fetch repository page ${page}" >&2
      return 1
    }

    local trimmed first_char
    trimmed="${page_data#"${page_data%%[![:space:]]*}"}"
    first_char="${trimmed:0:1}"
    if [[ "$first_char" != "[" ]]; then
      echo "GitHub API returned a non-repository response on page ${page}." >&2
      echo "This is often caused by rate limiting or insufficient token permissions." >&2
      return 1
    fi

    rows="$(json_repo_name_and_fork "$page_data")"
    if [[ -z "$rows" ]]; then
      break
    fi

    printf '%s\n' "$rows"
    ((page++))
  done
}

auth_clone_url() {
  local full_name="$1"
  if [[ -n "$TOKEN" ]]; then
    local enc_token
    enc_token="$(url_encode "$TOKEN")"
    printf 'https://x-access-token:%s@github.com/%s.git' "$enc_token" "$full_name"
  else
    printf 'https://github.com/%s.git' "$full_name"
  fi
}

safe_clone_url() {
  local full_name="$1"
  printf 'https://github.com/%s.git' "$full_name"
}

load_credentials_file() {
  local creds_file="$1"
  local first_plain_value=""

  [[ ! -r "$creds_file" ]] && err "Token file is not readable: ${creds_file}"

  while IFS= read -r line || [[ -n "$line" ]]; do
    local trimmed key key_normalized value

    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    trimmed="${trimmed%$'\r'}"

    [[ -z "$trimmed" ]] && continue
    [[ "${trimmed:0:1}" == "#" ]] && continue

    if [[ "$trimmed" == export[[:space:]]* ]]; then
      trimmed="${trimmed#export}"
      trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
    fi

    if [[ "$trimmed" != *=* ]]; then
      if [[ -z "$first_plain_value" ]]; then
        first_plain_value="$trimmed"
      fi
      continue
    fi

    key="${trimmed%%=*}"
    value="${trimmed#*=}"

    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%$'\r'}"
    key_normalized="${key^^}"

    if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" && ${#value} -ge 2 ]]; then
      value="${value:1:${#value}-2}"
    fi

    case "$key_normalized" in
      ACCOUNT|GITHUB_ACCOUNT)
        if [[ "$ACCOUNT_SET_BY_ARG" == "0" && -z "$ACCOUNT" ]]; then
          ACCOUNT="$value"
        fi
        ;;
      TOKEN|GITHUB_TOKEN)
        if [[ "$TOKEN_SET_BY_ARG" == "0" && -z "$TOKEN" ]]; then
          TOKEN="$value"
        fi
        ;;
      *)
        ;;
    esac
  done < "$creds_file"

  # Backward compatibility: token-only file using first non-comment line.
  if [[ "$TOKEN_SET_BY_ARG" == "0" && -z "$TOKEN" && -n "$first_plain_value" ]]; then
    TOKEN="$first_plain_value"
  fi
}

clone_or_update_repo() {
  local full_name="$1"
  local dest_dir="$2"

  local repo_name repo_path auth_url clean_url
  repo_name="${full_name##*/}"
  repo_path="${dest_dir}/${repo_name}.git"
  auth_url="$(auth_clone_url "$full_name")"
  clean_url="$(safe_clone_url "$full_name")"

  if [[ -d "$repo_path" ]]; then
    if [[ ! -f "$repo_path/HEAD" ]]; then
      echo "Skipping ${full_name}: ${repo_path} exists but does not look like a git mirror"
      LAST_ACTION="skipped"
      return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] update ${full_name} -> ${repo_path}"
      LAST_ACTION="planned_update"
      return 0
    fi

    echo "Updating ${full_name}"
    if [[ -n "$TOKEN" ]]; then
      if ! git -C "$repo_path" fetch --prune "$auth_url" '+refs/*:refs/*'; then
        echo "Update failed for ${full_name}" >&2
        return 1
      fi
    else
      if ! git -C "$repo_path" remote update --prune; then
        echo "Update failed for ${full_name}" >&2
        return 1
      fi
    fi

    LAST_ACTION="updated"
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] mirror ${full_name} -> ${repo_path}"
      LAST_ACTION="planned_mirror"
      return 0
    fi

    echo "Mirroring ${full_name}"
    if ! git clone --mirror "$auth_url" "$repo_path"; then
      echo "Mirror failed for ${full_name}" >&2
      return 1
    fi
    # Keep origin URL token-free on disk.
    if ! git -C "$repo_path" remote set-url origin "$clean_url"; then
      echo "Failed to set clean origin URL for ${full_name}" >&2
      return 1
    fi

    LAST_ACTION="mirrored"
  fi

  if [[ "$WITH_LFS" == "1" ]]; then
    echo "Fetching LFS objects for ${full_name}"

    if [[ -n "$TOKEN" ]]; then
      local auth_remote="__lfs_auth__"
      if git -C "$repo_path" remote | awk -v target="$auth_remote" '$0 == target { found = 1 } END { exit !found }'; then
        auth_remote="__lfs_auth_2__"
      fi

      if ! git -C "$repo_path" remote add "$auth_remote" "$auth_url"; then
        echo "Failed to create temporary LFS auth remote for ${full_name}" >&2
        return 1
      fi

      if ! git -C "$repo_path" lfs fetch --all "$auth_remote"; then
        git -C "$repo_path" remote remove "$auth_remote" >/dev/null 2>&1 || true
        echo "LFS fetch failed for ${full_name}" >&2
        return 1
      fi

      git -C "$repo_path" remote remove "$auth_remote" >/dev/null 2>&1 || true
    else
      if ! git -C "$repo_path" lfs fetch --all origin; then
        echo "LFS fetch failed for ${full_name}" >&2
        return 1
      fi
    fi
  fi
}

ACCOUNT=""
DEST_DIR="./mirrors"
TOKEN="${GITHUB_TOKEN:-}"
TOKEN_FILE=""
DRY_RUN="0"
SKIP_FORKS="0"
REPO_REGEX=""
WITH_LFS="0"
ACCOUNT_SET_BY_ARG="0"
TOKEN_SET_BY_ARG="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--account)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      ACCOUNT="$2"
      ACCOUNT_SET_BY_ARG="1"
      shift 2
      ;;
    -d|--dest)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      DEST_DIR="$2"
      shift 2
      ;;
    -t|--token)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      TOKEN="$2"
      TOKEN_SET_BY_ARG="1"
      shift 2
      ;;
    -T|--token-file)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      TOKEN_FILE="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN="1"
      shift
      ;;
    -s|--skip-forks)
      SKIP_FORKS="1"
      shift
      ;;
    -r|--repo-regex)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      REPO_REGEX="$2"
      shift 2
      ;;
    -l|--with-lfs)
      WITH_LFS="1"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown option: $1"
      ;;
  esac
done

if [[ -n "$TOKEN_FILE" ]]; then
  load_credentials_file "$TOKEN_FILE"
elif [[ "$TOKEN_SET_BY_ARG" == "1" && -r "$TOKEN" ]]; then
  # Compatibility: if --token points to a readable file, treat it as credentials file.
  TOKEN_FILE="$TOKEN"
  TOKEN=""
  TOKEN_SET_BY_ARG="0"
  load_credentials_file "$TOKEN_FILE"
fi

if [[ -n "$REPO_REGEX" ]]; then
  set +e
  printf '' | grep -E "$REPO_REGEX" >/dev/null 2>&1
  regex_status=$?
  set -e
  if [[ "$regex_status" -eq 2 ]]; then
    err "Invalid regular expression for --repo-regex: ${REPO_REGEX}"
  fi
fi

[[ -z "$ACCOUNT" ]] && {
  usage
  err "--account is required"
}

require_cmd git
require_cmd awk
select_http_client

if [[ "$WITH_LFS" == "1" ]]; then
  if ! git lfs version >/dev/null 2>&1; then
    err "git-lfs is required when --with-lfs is enabled"
  fi
fi

mkdir -p "$DEST_DIR"

echo "Resolving account type for ${ACCOUNT}..."
ACCOUNT_TYPE="$(get_account_type "$ACCOUNT")" || err "Failed to resolve account: ${ACCOUNT}"
[[ -z "$ACCOUNT_TYPE" ]] && err "Could not detect account type for ${ACCOUNT}"

auth_login=""
if [[ -n "$TOKEN" ]]; then
  auth_login="$(get_authenticated_login || true)"
fi

echo "Listing repositories for ${ACCOUNT} (${ACCOUNT_TYPE})..."
repo_rows_output="$(list_repos "$ACCOUNT" "$ACCOUNT_TYPE" "$auth_login")" || err "Failed to list repositories for ${ACCOUNT}"
mapfile -t repo_rows <<<"$repo_rows_output"

if [[ ${#repo_rows[@]} -eq 0 ]]; then
  echo "No repositories found for ${ACCOUNT}"
  exit 0
fi

echo "Found ${#repo_rows[@]} repositories"

repos=()
filtered_skip_count=0
for row in "${repo_rows[@]}"; do
  full_name="${row%%$'\t'*}"
  is_fork="${row##*$'\t'}"
  repo_name="${full_name##*/}"

  if [[ "$SKIP_FORKS" == "1" && "$is_fork" == "true" ]]; then
    echo "Skipping fork ${full_name}"
    ((filtered_skip_count+=1))
    continue
  fi

  if [[ -n "$REPO_REGEX" && ! "$repo_name" =~ $REPO_REGEX ]]; then
    echo "Skipping non-matching repo ${full_name}"
    ((filtered_skip_count+=1))
    continue
  fi

  repos+=("$full_name")
done

if [[ ${#repos[@]} -eq 0 ]]; then
  echo "No repositories to mirror after filters"
  exit 0
fi

echo "Processing ${#repos[@]} repositories"

failed_count=0
mirrored_count=0
updated_count=0
skipped_count="$filtered_skip_count"
planned_mirror_count=0
planned_update_count=0
for full_name in "${repos[@]}"; do
  if ! clone_or_update_repo "$full_name" "$DEST_DIR"; then
    ((failed_count+=1))
    echo "Failed ${full_name}; continuing"
    continue
  fi

  case "$LAST_ACTION" in
    mirrored)
      ((mirrored_count+=1))
      ;;
    updated)
      ((updated_count+=1))
      ;;
    skipped)
      ((skipped_count+=1))
      ;;
    planned_mirror)
      ((planned_mirror_count+=1))
      ;;
    planned_update)
      ((planned_update_count+=1))
      ;;
    *)
      ;;
  esac
done

echo "Summary:"
echo "  selected: ${#repos[@]}"
echo "  skipped: ${skipped_count}"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  planned_mirror: ${planned_mirror_count}"
  echo "  planned_update: ${planned_update_count}"
else
  echo "  mirrored: ${mirrored_count}"
  echo "  updated: ${updated_count}"
fi
echo "  failed: ${failed_count}"

if [[ "$failed_count" -gt 0 ]]; then
  echo "Done with ${failed_count} failed repositories"
  exit 1
fi

echo "Done"
