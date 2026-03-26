#!/usr/bin/env bash
set -euo pipefail

COLOR_SUCCESS="\033[1;32m"
COLOR_RESET="\033[0m"

log_success() {
  echo -e "${COLOR_SUCCESS}$1${COLOR_RESET}"
}

log_info() {
  echo "$1"
}

# Add convenient aliases for interactive shells.
BASHRC_PATH="${HOME}/.bashrc"
ALIASES=(
  "alias g='git'"
)

touch "${BASHRC_PATH}"
for alias_line in "${ALIASES[@]}"; do
  if ! grep -Fxq "${alias_line}" "${BASHRC_PATH}"; then
    echo "${alias_line}" >>"${BASHRC_PATH}"
  fi
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GIT_DIR="${REPO_ROOT}/.git"

if [[ -d "${GIT_DIR}" ]]; then
  HOOK_PATH="${GIT_DIR}/hooks/pre-commit"
  cat >"${HOOK_PATH}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "${REPO_ROOT}"

if [[ ! -x "scripts/lint.sh" ]]; then
  chmod +x scripts/lint.sh
fi

if [[ ! -x "scripts/smoke-test.sh" ]]; then
  chmod +x scripts/smoke-test.sh
fi

echo "pre-commit: running lint"
./scripts/lint.sh

echo "pre-commit: running smoke test"
./scripts/smoke-test.sh

echo "pre-commit: all checks passed"
EOF

  chmod +x "${HOOK_PATH}"
  log_success "Installed git pre-commit hook (lint + smoke test)."
else
  log_info "Skipping hook install: no .git directory found at ${REPO_ROOT}."
fi

log_success "Setup script completed."
