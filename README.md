# GitHub Mirror Script

`mirror-github-repos.sh` mirrors all repositories for a GitHub account into local bare repositories (`*.git`).

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

## Requirements

- `git`
- `jq`
- `sed`
- `grep`
- `curl` or `wget`

## Usage

```bash
./mirror-github-repos.sh --account ACCOUNT [options]
```

Options:
- `-a, --account ACCOUNT` GitHub user or organization name (required)
- `-d, --dest DIR` destination directory for mirrored repos (default: `./mirrors`)
- `-t, --token TOKEN` GitHub token (or set `GITHUB_TOKEN`)
- `-T, --token-file FILE` read GitHub token from first line of file
- `-n, --dry-run` show planned operations without cloning/fetching
- `-s, --skip-forks` skip repositories where `fork=true`
- `-r, --repo-regex REGEX` only process repositories whose name matches the regex
- `-l, --with-lfs` fetch all Git LFS objects after mirror/update
- `-h, --help` show help

## Recommended Auth Setup

Using `--token-file` avoids putting your token in shell history.

```bash
mkdir -p .secrets
printf '%s\n' 'YOUR_GITHUB_TOKEN' > .secrets/github-token
chmod 600 .secrets/github-token
```

Run with:

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github-token
```

## Examples

Dry-run everything:

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github-token --dry-run
```

Mirror into a custom directory:

```bash
./mirror-github-repos.sh --account your-account --dest /volume1/backups/github --token-file .secrets/github-token
```

Skip forked repositories:

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github-token --skip-forks
```

Only mirror repositories matching a regex (name only):

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github-token --repo-regex '^(llvm|clang|lldb)$'
```

Mirror and fetch LFS objects:

```bash
./mirror-github-repos.sh --account your-account --token-file .secrets/github-token --with-lfs
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
