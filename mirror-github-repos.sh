#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Mirror all repositories for a GitHub account.

Usage:
  mirror-github-repos.sh --account ACCOUNT [--dest DIR] [--token TOKEN] [--token-file FILE] [--dry-run] [--skip-forks]

Options:
  -a, --account ACCOUNT   GitHub user or organization name (required)
  -d, --dest DIR          Destination directory for mirrored repos (default: ./mirrors)
  -t, --token TOKEN       GitHub token (or set GITHUB_TOKEN env var)
  -T, --token-file FILE   Read GitHub token from file (first line)
  -n, --dry-run           Print planned actions without cloning/fetching
  -s, --skip-forks        Skip repositories where "fork" is true
  -h, --help              Show this help

Notes:
  - Existing mirrors are updated with fetch --prune.
  - New repositories are mirrored with git clone --mirror.
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
  local value
  value="$(printf '%s' "$json" | sed -n -E "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\".*/\1/p" | head -n1)"
  printf '%s' "$value"
}

json_repo_name_and_fork() {
  local json="$1"
  jq -r '.[] | select(.full_name != null) | [.full_name, (.fork | tostring)] | @tsv' <<<"$json"
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

json_type() {
  local json="$1"
  jq -r 'type' <<<"$json"
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

    if [[ "$(json_type "$page_data")" != "array" ]]; then
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
      return 0
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] update ${full_name} -> ${repo_path}"
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
  else
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "[dry-run] mirror ${full_name} -> ${repo_path}"
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
  fi
}

ACCOUNT=""
DEST_DIR="./mirrors"
TOKEN="${GITHUB_TOKEN:-}"
TOKEN_FILE=""
DRY_RUN="0"
SKIP_FORKS="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--account)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      ACCOUNT="$2"
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
  [[ ! -r "$TOKEN_FILE" ]] && err "Token file is not readable: ${TOKEN_FILE}"
  TOKEN="$(head -n1 "$TOKEN_FILE" | tr -d '\r\n')"
  [[ -z "$TOKEN" ]] && err "Token file is empty: ${TOKEN_FILE}"
fi

[[ -z "$ACCOUNT" ]] && {
  usage
  err "--account is required"
}

require_cmd curl
require_cmd git
require_cmd sed
require_cmd grep
require_cmd jq
select_http_client

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
for row in "${repo_rows[@]}"; do
  full_name="${row%%$'\t'*}"
  is_fork="${row##*$'\t'}"

  if [[ "$SKIP_FORKS" == "1" && "$is_fork" == "true" ]]; then
    echo "Skipping fork ${full_name}"
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
for full_name in "${repos[@]}"; do
  if ! clone_or_update_repo "$full_name" "$DEST_DIR"; then
    ((failed_count++))
    echo "Failed ${full_name}; continuing"
  fi
done

if [[ "$failed_count" -gt 0 ]]; then
  echo "Done with ${failed_count} failed repositories"
  exit 1
fi

echo "Done"
