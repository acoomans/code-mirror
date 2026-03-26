#!/usr/bin/env bash
set -euo pipefail

bash -n mirror-github-repos.sh
shellcheck mirror-github-repos.sh

echo "lint OK"
