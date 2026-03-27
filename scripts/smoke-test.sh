#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

mkdir -p "$work_dir/mockbin"

cat >"$work_dir/mockbin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

url=""
for arg in "$@"; do
  case "$arg" in
    http://*|https://*)
      url="$arg"
      ;;
  esac
done

case "$url" in
  "https://api.github.com/users/acoomans")
    printf '{"type":"User"}\n'
    ;;
  "https://api.github.com/user")
    printf '{"login":"acoomans"}\n'
    ;;
  "https://api.github.com/user/repos?type=owner&per_page=100&page=1")
    printf '[{"full_name":"acoomans/433Utils","fork":true},{"full_name":"acoomans/other","fork":false}]\n'
    ;;
  "https://api.github.com/user/repos?type=owner&per_page=100&page=2")
    printf '[]\n'
    ;;
  "https://api.bitbucket.org/2.0/repositories/acoomans?pagelen=100")
    printf '{"values":[{"full_name":"acoomans/ACReuseQueue","name":"ACReuseQueue"},{"full_name":"acoomans/forked","name":"forked","parent":{"full_name":"upstream/forked"}}],"next":"https://api.bitbucket.org/2.0/repositories/acoomans?page=2&pagelen=100"}\n'
    ;;
  "https://api.bitbucket.org/2.0/repositories/acoomans?page=2&pagelen=100")
    printf '{"values":[]}\n'
    ;;
  "https://www.gog.com/account/getFilteredProducts?mediaType=1&sortBy=title&page=1")
    printf '{"totalPages":1,"products":[{"id":111,"slug":"cyberpunk-2077"},{"id":222,"slug":"baldurs-gate-3"}]}'
    ;;
  "https://www.gog.com/account/gameDetails/111.json")
    printf '{"downloads":{"installers":[{"downlink":"https:\\/\\/www.gog.com\\/downlink\\/cp-setup"},{"downlink":"https:\\/\\/www.gog.com\\/downlink\\/cp-patch"}]}}'
    ;;
  "https://www.gog.com/account/gameDetails/222.json")
    printf '{"downloads":{"installers":[{"downlink":"https:\\/\\/www.gog.com\\/downlink\\/bg3-setup"}]}}'
    ;;
  *)
    echo "mock curl: unexpected URL: $url" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$work_dir/mockbin/curl"

cat >"$work_dir/creds.env" <<'EOF'
ACCOUNT=acoomans
GITHUB_TOKEN=dummy-token
EOF

output_file="$work_dir/output.txt"
(
  cd "$repo_root"
  PATH="$work_dir/mockbin:$PATH" ./mirror-github-repos.sh \
    --token-file "$work_dir/creds.env" \
    --dest "$work_dir/mirrors" \
    --repo-regex '^(433Utils)$' \
    --dry-run
) >"$output_file" 2>&1

grep -q "Resolving account type for acoomans" "$output_file"
grep -q "Found 2 repositories" "$output_file"
grep -q "Processing 1 repositories" "$output_file"
grep -q "\[dry-run\] mirror acoomans/433Utils" "$output_file"
grep -q "Summary:" "$output_file"
grep -q "failed: 0" "$output_file"

output_file_token_flag="$work_dir/output-token-flag.txt"
(
  cd "$repo_root"
  PATH="$work_dir/mockbin:$PATH" ./mirror-github-repos.sh \
    --token "$work_dir/creds.env" \
    --dest "$work_dir/mirrors-2" \
    --repo-regex '^(433Utils)$' \
    --dry-run
) >"$output_file_token_flag" 2>&1

grep -q "Resolving account type for acoomans" "$output_file_token_flag"
grep -q "Found 2 repositories" "$output_file_token_flag"
grep -q "Processing 1 repositories" "$output_file_token_flag"
grep -q "\[dry-run\] mirror acoomans/433Utils" "$output_file_token_flag"
grep -q "Summary:" "$output_file_token_flag"
grep -q "failed: 0" "$output_file_token_flag"

printf '\xEF\xBB\xBFWORKSPACE=acoomans\nBITBUCKET_USERNAME=dummy-user\nBITBUCKET_APP_PASSWORD=dummy-token\n' >"$work_dir/bitbucket-creds.env"

output_file_bitbucket="$work_dir/output-bitbucket.txt"
(
  cd "$repo_root"
  PATH="$work_dir/mockbin:$PATH" ./mirror-bitbucket-repos.sh \
    --token-file "$work_dir/bitbucket-creds.env" \
    --dest "$work_dir/mirrors-bb" \
    --skip-forks \
    --repo-regex '^(ACReuseQueue)$' \
    --dry-run
) >"$output_file_bitbucket" 2>&1

grep -q "Listing repositories for workspace acoomans" "$output_file_bitbucket"
grep -q "Found 2 repositories" "$output_file_bitbucket"
grep -q "Skipping fork acoomans/forked" "$output_file_bitbucket"
grep -q "Processing 1 repositories" "$output_file_bitbucket"
grep -q "\[dry-run\] mirror acoomans/ACReuseQueue" "$output_file_bitbucket"
grep -q "Summary:" "$output_file_bitbucket"
grep -q "failed: 0" "$output_file_bitbucket"

cat >"$work_dir/gog-cookies.txt" <<'EOF'
# Netscape HTTP Cookie File
.gog.com	TRUE	/	FALSE	2147483647	gog_lc	en-US
EOF

output_file_gog="$work_dir/output-gog.txt"
(
  cd "$repo_root"
  PATH="$work_dir/mockbin:$PATH" ./backup-gog-games.sh \
    --cookies "$work_dir/gog-cookies.txt" \
    --dest "$work_dir/gog-dest" \
    --game-regex '^(cyberpunk-2077)$' \
    --preflight-auth \
    --dry-run
) >"$output_file_gog" 2>&1

grep -q "Running preflight auth check" "$output_file_gog"
grep -q "Preflight auth check passed" "$output_file_gog"
grep -q "Listing owned GOG games" "$output_file_gog"
grep -q "Found 2 candidate games" "$output_file_gog"
grep -q "Skipping non-matching game baldurs-gate-3" "$output_file_gog"
grep -q "Processing 1 games" "$output_file_gog"
grep -q "Inspecting cyberpunk-2077 (111)" "$output_file_gog"
grep -q "\[dry-run\] download https://www.gog.com/downlink/cp-setup" "$output_file_gog"
grep -q "Summary:" "$output_file_gog"
grep -q "failed: 0" "$output_file_gog"

echo "smoke test OK"
