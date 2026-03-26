#!/usr/bin/env bash
set -euo pipefail

mapfile -t sh_files < <(git ls-files '*.sh' | LC_ALL=C sort)

for f in "${sh_files[@]}"; do
	bash -n "$f"
	shellcheck "$f"
done

echo "lint OK"
