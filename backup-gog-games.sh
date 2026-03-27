#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Download owned GOG game files from GOG servers.

Usage:
  backup-gog-games.sh --cookies FILE [--dest DIR] [--game-regex REGEX] [--dry-run] [--preflight-auth]

Options:
  -c, --cookies FILE       Netscape-format cookies file for gog.com (required)
  -d, --dest DIR           Destination directory for downloads (default: ./gog-downloads)
  -r, --game-regex REGEX   Only process games whose slug matches REGEX
  -n, --dry-run            Print planned downloads without downloading files
      --preflight-auth     Validate cookie auth before listing/downloading games
  -h, --help               Show this help

Notes:
  - You must be logged into gog.com and export cookies from your browser.
  - The script queries owned products from GOG account APIs.
  - Downloads are fetched with content-disposition so installer filenames are preserved.
  - Uses curl when available, otherwise falls back to wget.
EOF
}

err() {
  echo "Error: $*" >&2
  exit 1
}

AUTH_ERROR_EXIT_CODE=40

print_relogin_hint() {
  echo "Authentication appears expired or invalid." >&2
  echo "Refresh your gog.com cookies file and retry." >&2
  echo "Tip: log in at https://www.gog.com/account and export an updated Netscape cookies file." >&2
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

validate_regex() {
  local regex="$1"
  [[ -z "$regex" ]] && return 0

  set +e
  printf '' | grep -E "$regex" >/dev/null 2>&1
  local status=$?
  set -e

  if [[ "$status" -eq 2 ]]; then
    err "Invalid regular expression for --game-regex: ${regex}"
  fi
}

http_get() {
  local url="$1"
  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    curl -sSL --cookie "$COOKIES_FILE" --cookie-jar "$COOKIE_JAR" "$url"
  else
    wget -qO- --load-cookies "$COOKIES_FILE" --save-cookies "$COOKIE_JAR" --keep-session-cookies "$url"
  fi
}

looks_like_login_response() {
  local payload="$1"

  [[ "$payload" == *"<html"* ]] && return 0
  [[ "$payload" == *"auth.gog.com"* ]] && return 0
  [[ "$payload" == *"on_login_success"* ]] && return 0
  [[ "$payload" == *"sign in"* ]] && return 0
  [[ "$payload" == *"login"*"password"* ]] && return 0

  return 1
}

run_preflight_auth_check() {
  local data
  data="$(http_get "https://www.gog.com/account/getFilteredProducts?mediaType=1&sortBy=title&page=1")" || {
    echo "Failed to reach GOG products endpoint during preflight auth check." >&2
    return 1
  }

  if [[ "$data" == *'"products"'* ]]; then
    echo "Preflight auth check passed"
    return 0
  fi

  if looks_like_login_response "$data"; then
    echo "Preflight auth check failed: login response received instead of products." >&2
    return "$AUTH_ERROR_EXIT_CODE"
  fi

  echo "Preflight auth check failed: unexpected response from GOG products endpoint." >&2
  return 1
}

extract_json_number_field() {
  local json="$1"
  local field="$2"
  printf '%s\n' "$json" | awk -v key="$field" '
    {
      if (match($0, "\"" key "\"[[:space:]]*:[[:space:]]*[0-9]+")) {
        token = substr($0, RSTART, RLENGTH)
        sub(/^.*:[[:space:]]*/, "", token)
        print token
        exit
      }
    }
  '
}

json_product_id_and_slug() {
  local json="$1"
  printf '%s' "$json" | tr -d '\n\r' | awk '
    {
      line = $0
      while (match(line, /"id"[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*,[[:space:]]*"slug"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        token = substr(line, RSTART, RLENGTH)
        id = token
        slug = token
        sub(/^.*"id"[[:space:]]*:[[:space:]]*/, "", id)
        sub(/[[:space:]]*,.*$/, "", id)
        sub(/^.*"slug"[[:space:]]*:[[:space:]]*"/, "", slug)
        sub(/"$/, "", slug)
        print id "\t" slug
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

json_downlinks() {
  local json="$1"
  printf '%s' "$json" | tr -d '\n\r' | awk '
    {
      line = $0
      while (match(line, /"downlink"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
        token = substr(line, RSTART, RLENGTH)
        sub(/^"downlink"[[:space:]]*:[[:space:]]*"/, "", token)
        sub(/"$/, "", token)
        gsub(/\\\//, "/", token)
        print token
        line = substr(line, RSTART + RLENGTH)
      }
    }
  '
}

list_products() {
  local page=1
  local total_pages=1
  local data rows detected_pages

  while :; do
    data="$(http_get "https://www.gog.com/account/getFilteredProducts?mediaType=1&sortBy=title&page=${page}")" || {
      echo "Failed to fetch product page ${page}" >&2
      return 1
    }

    if [[ "$data" != *'"products"'* ]]; then
      if looks_like_login_response "$data"; then
        echo "GOG API returned a login/auth response on page ${page}." >&2
        return "$AUTH_ERROR_EXIT_CODE"
      fi
      echo "GOG API returned a non-product response on page ${page}." >&2
      return 1
    fi

    rows="$(json_product_id_and_slug "$data")"
    if [[ -n "$rows" ]]; then
      printf '%s\n' "$rows"
    fi

    detected_pages="$(extract_json_number_field "$data" "totalPages")"
    if [[ -n "$detected_pages" ]]; then
      total_pages="$detected_pages"
    fi

    if [[ "$page" -ge "$total_pages" ]]; then
      break
    fi
    ((page+=1))
  done
}

download_link() {
  local link="$1"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] download ${link}"
    LAST_ACTION="planned_download"
    return 0
  fi

  if [[ "$HTTP_CLIENT" == "curl" ]]; then
    if ! curl -fL -C - -OJ --cookie "$COOKIES_FILE" --cookie-jar "$COOKIE_JAR" "$link"; then
      echo "Download failed for ${link}" >&2
      return 1
    fi
  else
    if ! wget -c --content-disposition --load-cookies "$COOKIES_FILE" --save-cookies "$COOKIE_JAR" --keep-session-cookies "$link"; then
      echo "Download failed for ${link}" >&2
      return 1
    fi
  fi

  LAST_ACTION="downloaded"
}

process_game() {
  local game_id="$1"
  local game_slug="$2"
  local game_dir details links

  game_dir="${DEST_DIR}/${game_slug}"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Inspecting ${game_slug} (${game_id})"
  else
    mkdir -p "$game_dir"
  fi

  details="$(http_get "https://www.gog.com/account/gameDetails/${game_id}.json")" || {
    echo "Failed to fetch game details for ${game_slug}" >&2
    return 1
  }

  if looks_like_login_response "$details"; then
    echo "Received login/auth response while fetching details for ${game_slug}." >&2
    return "$AUTH_ERROR_EXIT_CODE"
  fi

  links="$(json_downlinks "$details")"
  if [[ -z "$links" ]]; then
    echo "Skipping ${game_slug}: no downloadable files in account response"
    LAST_ACTION="skipped"
    return 0
  fi

  local failed_file_count=0
  local downloaded_for_game=0
  local link

  while IFS= read -r link || [[ -n "$link" ]]; do
    [[ -z "$link" ]] && continue

    if [[ "$DRY_RUN" == "0" ]]; then
      mkdir -p "$game_dir"
      cd "$game_dir"
    fi

    if download_link "$link"; then
      ((downloaded_for_game+=1))
    else
      ((failed_file_count+=1))
    fi
  done <<< "$links"

  GAME_DOWNLOAD_COUNT="$downloaded_for_game"

  if [[ "$failed_file_count" -gt 0 ]]; then
    echo "Game ${game_slug} finished with ${failed_file_count} failed file downloads" >&2
    return 1
  fi

  if [[ "$downloaded_for_game" -eq 0 ]]; then
    LAST_ACTION="skipped"
  fi
}

COOKIES_FILE=""
DEST_DIR="./gog-downloads"
GAME_REGEX=""
DRY_RUN="0"
PREFLIGHT_AUTH="0"
HTTP_CLIENT=""
COOKIE_JAR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--cookies)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      COOKIES_FILE="$2"
      shift 2
      ;;
    -d|--dest)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      DEST_DIR="$2"
      shift 2
      ;;
    -r|--game-regex)
      [[ $# -lt 2 ]] && err "Missing value for $1"
      GAME_REGEX="$2"
      shift 2
      ;;
    -n|--dry-run)
      DRY_RUN="1"
      shift
      ;;
    --preflight-auth)
      PREFLIGHT_AUTH="1"
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

[[ -z "$COOKIES_FILE" ]] && {
  usage
  err "--cookies is required"
}

[[ -r "$COOKIES_FILE" ]] || err "Cookies file is not readable: ${COOKIES_FILE}"

require_cmd grep
require_cmd awk
validate_regex "$GAME_REGEX"
select_http_client

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR"' EXIT

mkdir -p "$DEST_DIR"

if [[ "$PREFLIGHT_AUTH" == "1" ]]; then
  echo "Running preflight auth check..."
  set +e
  run_preflight_auth_check
  preflight_status=$?
  set -e
  if [[ "$preflight_status" -eq "$AUTH_ERROR_EXIT_CODE" ]]; then
    print_relogin_hint
    exit "$AUTH_ERROR_EXIT_CODE"
  elif [[ "$preflight_status" -ne 0 ]]; then
    err "Preflight auth check failed"
  fi
fi

echo "Listing owned GOG games..."
set +e
game_rows="$(list_products)"
list_status=$?
set -e
if [[ "$list_status" -eq "$AUTH_ERROR_EXIT_CODE" ]]; then
  print_relogin_hint
  exit "$AUTH_ERROR_EXIT_CODE"
elif [[ "$list_status" -ne 0 ]]; then
  err "Failed to list owned games"
fi

if [[ -z "$game_rows" ]]; then
  echo "No owned games found"
  exit 0
fi

mapfile -t game_candidates <<<"$game_rows"
echo "Found ${#game_candidates[@]} candidate games"

games=()
filtered_skip_count=0
for row in "${game_candidates[@]}"; do
  [[ -z "$row" ]] && continue

  game_id="${row%%$'\t'*}"
  game_slug="${row##*$'\t'}"

  if [[ -n "$GAME_REGEX" && ! "$game_slug" =~ $GAME_REGEX ]]; then
    echo "Skipping non-matching game ${game_slug}"
    ((filtered_skip_count+=1))
    continue
  fi

  games+=("${game_id}"$'\t'"${game_slug}")
done

if [[ ${#games[@]} -eq 0 ]]; then
  echo "No games to download after filters"
  exit 0
fi

echo "Processing ${#games[@]} games"

failed_count=0
downloaded_count=0
skipped_count="$filtered_skip_count"
planned_download_count=0
downloaded_file_count=0
planned_file_count=0

START_DIR="$PWD"
GAME_DOWNLOAD_COUNT=0

for row in "${games[@]}"; do
  game_id="${row%%$'\t'*}"
  game_slug="${row##*$'\t'}"

  set +e
  process_game "$game_id" "$game_slug"
  process_status=$?
  set -e
  if [[ "$process_status" -eq "$AUTH_ERROR_EXIT_CODE" ]]; then
    cd "$START_DIR"
    print_relogin_hint
    exit "$AUTH_ERROR_EXIT_CODE"
  elif [[ "$process_status" -ne 0 ]]; then
    cd "$START_DIR"
    ((failed_count+=1))
    echo "Failed ${game_slug}; continuing"
    continue
  fi
  cd "$START_DIR"

  if [[ "$DRY_RUN" == "1" ]]; then
    ((planned_file_count+=GAME_DOWNLOAD_COUNT))
  else
    ((downloaded_file_count+=GAME_DOWNLOAD_COUNT))
  fi

  case "$LAST_ACTION" in
    downloaded)
      ((downloaded_count+=1))
      ;;
    skipped)
      ((skipped_count+=1))
      ;;
    planned_download)
      ((planned_download_count+=1))
      ;;
    *)
      ;;
  esac
done

echo "Summary:"
echo "  selected: ${#games[@]}"
echo "  skipped: ${skipped_count}"
if [[ "$DRY_RUN" == "1" ]]; then
  echo "  planned_download_games: ${planned_download_count}"
  echo "  planned_download_files: ${planned_file_count}"
else
  echo "  downloaded_games: ${downloaded_count}"
  echo "  downloaded_files: ${downloaded_file_count}"
fi
echo "  failed: ${failed_count}"

if [[ "$failed_count" -gt 0 ]]; then
  echo "Done with ${failed_count} failed games"
  exit 1
fi

echo "Done"
