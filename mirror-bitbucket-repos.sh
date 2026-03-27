#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Mirror all repositories for a Bitbucket workspace.

Usage:
  mirror-bitbucket-repos.sh --account WORKSPACE [--dest DIR] [--token TOKEN] [--username USERNAME_OR_EMAIL] [--token-file FILE] [--dry-run] [--skip-forks] [--repo-regex REGEX] [--with-lfs]

Options:
  -a, --account WORKSPACE  Bitbucket workspace slug (required)
  -d, --dest DIR           Destination directory for mirrored repos (default: ./mirrors)
  -t, --token TOKEN        Bitbucket API token (or set BITBUCKET_TOKEN)
  -u, --username USERNAME  Atlassian account email for API auth
  -T, --token-file FILE    Read .env-style credentials file
  -n, --dry-run            Print planned actions without cloning/fetching
  -s, --skip-forks         Skip repositories that are forks (have a parent)
  -r, --repo-regex REGEX   Only process repositories whose name matches REGEX
  -l, --with-lfs           Fetch Git LFS objects with --all after mirror/update
  -h, --help               Show this help

Notes:
  - Existing mirrors are updated with fetch --prune.
  - New repositories are mirrored with git clone --mirror.
  - LFS objects are fetched only when --with-lfs is enabled.
  - Credential file supports WORKSPACE/ACCOUNT, BITBUCKET_TOKEN/TOKEN, BITBUCKET_EMAIL/BITBUCKET_USERNAME/USERNAME.
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
        if (match(rest, /"/)) {
          print substr(rest, 1, RSTART - 1)
          exit
        }
      }
    }
  '
}

json_repo_name_and_fork() {
  local json="$1"

  printf '%s' "$json" | tr -d '\n\r' | awk '
    function emit_repo(obj, full_name, is_fork) {
      full_name = ""
      is_fork = "false"

      if (match(obj, /"full_name"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        full_name = substr(obj, RSTART, RLENGTH)
        sub(/^"full_name"[[:space:]]*:[[:space:]]*"/, "", full_name)
        sub(/"$/, "", full_name)
      }

      if (obj ~ /"parent"[[:space:]]*:[[:space:]]*\{/) {
        is_fork = "true"
      }

      if (full_name != "") {
        print full_name "\t" is_fork
      }
    }

    BEGIN {
      in_values = 0
      values_level = 0
      object_level = 0
      in_string = 0
      escaped = 0
      prefix = ""
      object = ""
    }

    {
      data = $0
      for (i = 1; i <= length(data); i++) {
        c = substr(data, i, 1)

        if (!in_values) {
          prefix = prefix c
          if (length(prefix) > 64) {
            prefix = substr(prefix, length(prefix) - 63)
          }

          if (prefix ~ /"values"[[:space:]]*:[[:space:]]*\[$/) {
            in_values = 1
            values_level = 1
            object_level = 0
            object = ""
          }
          continue
        }

        if (in_string) {
          if (object_level > 0) {
            object = object c
          }

          if (escaped) {
            escaped = 0
          } else if (c == "\\") {
            escaped = 1
          } else if (c == "\"") {
            in_string = 0
          }
          continue
        }

        if (c == "\"") {
          in_string = 1
          if (object_level > 0) {
            object = object c
          }
          continue
        }

        if (c == "[") {
          values_level++
          continue
        }

        if (c == "]") {
          values_level--
          if (values_level == 0) {
            exit
          }
          continue
        }

        if (c == "{") {
          if (object_level == 0) {
            object = ""
          }
          object_level++
          object = object c
          continue
        }

        if (c == "}") {
          if (object_level > 0) {
            object = object c
            object_level--
            if (object_level == 0) {
              emit_repo(object)
              object = ""
            }
          }
          continue
        }

        if (object_level > 0) {
          object = object c
        }
      }
    }
  '
}

http_get() {
  local url="$1"

  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    if [[ -n "$TOKEN" ]]; then
      curl -fsSL -u "${AUTH_USER}:${TOKEN}" "$url"
    else
      curl -fsSL "$url"
    fi
  else
    if [[ -n "$TOKEN" ]]; then
      wget -qO- --user="$AUTH_USER" --password="$TOKEN" "$url"
    else
      wget -qO- "$url"
    fi
  fi
}

list_repos() {
  local account="$1"

  local endpoint="https://api.bitbucket.org/2.0/repositories/${account}?pagelen=100"
  local page_data=""
  local rows=""

  while [[ -n "$endpoint" ]]; do
    page_data="$(http_get "$endpoint")" || {
      echo "Failed to fetch repository list" >&2
      return 1
    }

    if [[ "$page_data" != *'"values"'* ]]; then
      echo "Bitbucket API returned a non-repository response." >&2
      echo "This is often caused by invalid workspace or insufficient permissions." >&2
      return 1
    fi

    rows="$(json_repo_name_and_fork "$page_data")"
    if [[ -n "$rows" ]]; then
      printf '%s\n' "$rows"
    fi

    endpoint="$(extract_json_string_field "$page_data" "next")"
  done
}

auth_clone_url() {
  local full_name="$1"
  if [[ -n "$TOKEN" ]]; then
    local enc_user enc_token git_auth_user
    git_auth_user="${AUTH_USER:-x-bitbucket-api-token-auth}"
    if [[ "$git_auth_user" == *"@"* ]]; then
      git_auth_user="x-bitbucket-api-token-auth"
    fi
    enc_user="$(url_encode "$git_auth_user")"
    enc_token="$(url_encode "$TOKEN")"
    printf 'https://%s:%s@bitbucket.org/%s.git' "$enc_user" "$enc_token" "$full_name"
  else
    printf 'https://bitbucket.org/%s.git' "$full_name"
  fi
}

safe_clone_url() {
  local full_name="$1"
  printf 'https://bitbucket.org/%s.git' "$full_name"
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
    trimmed="${trimmed#$'\xEF\xBB\xBF'}"

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
      ACCOUNT|WORKSPACE|BITBUCKET_WORKSPACE)
        if [[ "$ACCOUNT_SET_BY_ARG" == "0" && -z "$ACCOUNT" ]]; then
          ACCOUNT="$value"
        fi
        ;;
      TOKEN|BITBUCKET_TOKEN|BITBUCKET_APP_PASSWORD)
        if [[ "$TOKEN_SET_BY_ARG" == "0" && -z "$TOKEN" ]]; then
          TOKEN="$value"
        fi
        ;;
      USERNAME|BITBUCKET_USERNAME|BITBUCKET_USER|EMAIL|BITBUCKET_EMAIL)
        if [[ "$USER_SET_BY_ARG" == "0" && -z "$AUTH_USER" ]]; then
          AUTH_USER="$value"
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
TOKEN="${BITBUCKET_TOKEN:-}"
AUTH_USER="${BITBUCKET_EMAIL:-${BITBUCKET_USERNAME:-}}"
TOKEN_FILE=""
DRY_RUN="0"
SKIP_FORKS="0"
REPO_REGEX=""
WITH_LFS="0"
ACCOUNT_SET_BY_ARG="0"
TOKEN_SET_BY_ARG="0"
USER_SET_BY_ARG="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--account|--workspace)
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
    -u|--username)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      AUTH_USER="$2"
      USER_SET_BY_ARG="1"
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
  err "--account/--workspace is required"
}

require_cmd git
require_cmd awk
select_http_client

if [[ -n "$TOKEN" && -z "$AUTH_USER" ]]; then
  err "Token auth requires --username (Bitbucket username or Atlassian email), or set BITBUCKET_EMAIL/BITBUCKET_USERNAME"
fi

if [[ "$WITH_LFS" == "1" ]]; then
  if ! git lfs version >/dev/null 2>&1; then
    err "git-lfs is required when --with-lfs is enabled"
  fi
fi

mkdir -p "$DEST_DIR"

echo "Listing repositories for workspace ${ACCOUNT}..."
repo_rows_output="$(list_repos "$ACCOUNT")" || err "Failed to list repositories for ${ACCOUNT}"
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
  if clone_or_update_repo "$full_name" "$DEST_DIR"; then
    case "$LAST_ACTION" in
      mirrored)
        ((mirrored_count+=1))
        ;;
      updated)
        ((updated_count+=1))
        ;;
      planned_mirror)
        ((planned_mirror_count+=1))
        ;;
      planned_update)
        ((planned_update_count+=1))
        ;;
      skipped)
        ((skipped_count+=1))
        ;;
      *)
        ;;
    esac
  else
    echo "Failed processing ${full_name}" >&2
    ((failed_count+=1))
  fi
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
  exit 1
fi

echo "Done"
