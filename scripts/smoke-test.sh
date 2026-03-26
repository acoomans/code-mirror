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

echo "smoke test OK"
