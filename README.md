# Code Mirror Scripts

Mirrors all repositories for a GitHub account or a Bitbucket workspace into local bare repositories (`*.git`).


It supports:
- creating new mirrors
- updating existing mirrors
- optional Git LFS object backup (`--with-lfs`)
- dry-run mode
- skipping forked repositories
- token from environment, CLI, or file
- `curl` with `wget` fallback for API calls
- continue-on-error behavior (one repo failure does not stop the whole run)
- end-of-run summary counters

Provider-specific notes:
- GitHub script supports `--account` and token auth via GitHub token.
- Bitbucket script supports `--account`/`--workspace`, and token auth using API tokens (`--username` + `--token`).
- For Bitbucket token auth, use explicit `ACCOUNT`/`WORKSPACE` plus `BITBUCKET_EMAIL` and `BITBUCKET_TOKEN`.
- For Bitbucket git clone/fetch with API tokens, the script automatically uses a git-safe auth username when `BITBUCKET_EMAIL` is used for API calls.

## Requirements

- `git`
- `awk`
- `curl` or `wget`

The script intentionally avoids external JSON tooling (no `jq`) and uses portable shell/awk patterns for compatibility across macOS, Debian, and Synology DSM.

## Usage

```bash
./mirror-github-repos.sh --account ACCOUNT [options]
./mirror-bitbucket-repos.sh --account WORKSPACE [options]
```

Options:
- `-a, --account ACCOUNT` GitHub user or organization name (required)
- `-d, --dest DIR` destination directory for mirrored repos (default: `./mirrors`)
- `-t, --token TOKEN` GitHub token (or set `GITHUB_TOKEN`)
- `-T, --token-file FILE` read `.env`-style credentials file (`ACCOUNT`, `GITHUB_TOKEN`)
- `-n, --dry-run` show planned operations without cloning/fetching
- `-s, --skip-forks` skip repositories where `fork=true`
- `-r, --repo-regex REGEX` only process repositories whose name matches the regex
- `-l, --with-lfs` fetch all Git LFS objects after mirror/update
- `-h, --help` show help

## Recommended Auth Setup

Using `--token-file` avoids putting credentials in shell history.

```bash
mkdir -p .secrets
cat > .secrets/github.env <<'EOF'
ACCOUNT=your-account
GITHUB_TOKEN=YOUR_GITHUB_TOKEN
EOF
chmod 600 .secrets/github.env
```

Run with:

```bash
./mirror-github-repos.sh --token-file .secrets/github.env
```

Bitbucket credential file example:

```bash
mkdir -p .secrets
cat > .secrets/bitbucket.env <<'EOF'
WORKSPACE=your-workspace
BITBUCKET_EMAIL=you@example.com
BITBUCKET_TOKEN=YOUR_API_TOKEN
EOF
chmod 600 .secrets/bitbucket.env
```

Run with:

```bash
./mirror-bitbucket-repos.sh --token-file .secrets/bitbucket.env
```

Notes:
- CLI flags still override values from the credentials file.
- Backward compatibility is preserved: a token-only file with a single line still works.

## Examples

Dry-run everything:

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github.env --dry-run
```

Mirror into a custom directory:

```bash
./mirror-github-repos.sh --account your-account --dest /volume1/backups/github --token-file .secrets/github.env
```

Skip forked repositories:

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github.env --skip-forks
```

Only mirror repositories matching a regex (name only):

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github.env --repo-regex '^(llvm|clang|lldb)$'
```

Mirror and fetch LFS objects:

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github.env --with-lfs
```

Bitbucket dry-run with regex and fork skipping:

```bash
./mirror-bitbucket-repos.sh --workspace your-workspace --token-file .secrets/bitbucket.env --skip-forks --repo-regex '^(my-repo)$' --dry-run
```

## Behavior Notes

- Existing mirrors are updated with prune.
- New repositories are cloned with `git clone --mirror`.
- When `--with-lfs` is enabled, the script runs `git lfs fetch --all` per processed repository.
- After cloning with a token, the script resets origin URL to a token-free URL.
- If one repository fails, the script continues with the next one.
- The script exits non-zero if any repositories failed.

## Scheduling (NAS / Cron)

Example daily run at 02:15:

```cron
15 2 * * * cd /path/to/github-mirror && ./mirror-github-repos.sh --account your-account --dest /volume1/backups/github --token-file .secrets/github-token >> /volume1/backups/github/mirror.log 2>&1
```

## Output Summary

At the end of each run, the script prints a summary with:
- selected repos
- skipped repos
- mirrored/updated counts (or planned counts in dry-run)
- failed repos
