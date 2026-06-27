# Contributing to amneziawg-installer

Please note that this project has a [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to abide by its terms.

Thank you for your interest in contributing! This guide covers the process and conventions for submitting changes.

## How to Contribute

1. **Fork** the repository
2. **Create a branch** from `main` (e.g., `fix/ufw-rules` or `feat/multi-client-export`)
3. **Make your changes** following the code style below
4. **Test** locally and on a clean VPS
5. **Open a Pull Request** against `main`

## Code Style

### General

- All scripts use `set -o pipefail`
- Russian scripts are the primary implementation; changes must be mirrored in the corresponding English scripts (`*_en.sh`)
- Error handling: use `die()` for fatal errors, `log_error()` / `log_warn()` for non-fatal
- Logging: all output through `log_msg()` with appropriate level (INFO, WARN, ERROR, DEBUG)

### File Operations

- Atomic writes: use `awg_mktemp()` (auto-cleanup via trap) and `mv` to the final destination
- Create backups before modifying existing configs
- Set strict permissions: `chmod 600` for keys/configs, `chmod 700` for directories

### Shell Conventions

- Use `bash` (not `sh` or `zsh`)
- Quote all variable expansions: `"${var}"` instead of `$var`
- Use `[[ ]]` for conditionals (not `[ ]`)
- Prefer `$(command)` over backticks

## Testing Requirements

Before submitting a PR, ensure:

1. **Syntax check** passes:
   ```bash
   for f in install_amneziawg.sh install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh awg_common.sh awg_common_en.sh; do
     bash -n "$f" && echo "OK: $f"
   done
   ```

2. **ShellCheck** (version from Ubuntu repositories, typically >= 0.9.0) passes with **zero warnings**:
   ```bash
   for f in install_amneziawg.sh install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh awg_common.sh awg_common_en.sh; do
     shellcheck -s bash -S warning "$f"
   done
   ```

   > Note: these two loops cover the six runtime scripts as a quick local shortcut. CI (`shellcheck.yml`) and `scripts/preflight-check.sh` check a wider scope - all tracked `*.sh`, including `scripts/*.sh` and `tests/`. The full local gate is `BASE_REF=origin/main bash scripts/preflight-check.sh`.

3. **Unit tests (bats-core)** pass. The suite grows every release, so there is no fixed count to match - run `bats tests/` and make sure the full suite is green before opening a PR.
   ```bash
   bats tests/
   ```
   If you add a new function, add a corresponding test file (see `tests/test_*.bats` for the existing pattern). `test_helper.bash` provides common fixtures. Tests must pass on Linux with `flock` available; cross-platform edge cases use the `require_flock` skip helper where needed.

4. **VPS testing** (for script changes): test on a clean server (Ubuntu 24.04 LTS or Debian 12/13 minimal). The full test matrix includes:
   - Fresh install on clean Ubuntu 24.04 LTS
   - Fresh install on clean Ubuntu 25.10 (noble fallback path)
   - Fresh install on clean Ubuntu 26.04 (noble fallback path)
   - All management commands: add, remove, list, regen, check, restart
   - Reboot-resume between critical installer steps
   - Client connectivity (handshake, ping, DNS resolution)
   - Fresh install on clean Debian 12 (bookworm)
   - Fresh install on clean Debian 13 (trixie)
   - Client expiry: add with --expires, verify cron auto-removal
   - Stats: verify `stats` and `stats --json` output
   - Backup/restore: verify expiry data and cron job are included in backup and correctly restored
   - Uninstall + reinstall: `--uninstall` followed by fresh install on same server
   - vpn:// URI: verify `.vpnuri` files created when Perl + `Compress::Zlib` available
   - Uninstall: verify complete cleanup (UFW, Fail2Ban, cron, kernel module, working directory)

## Security Review Checklist

For security-sensitive changes, additionally verify:

- [ ] No `source` or `eval` on user-controlled files (use `safe_load_config()`)
- [ ] All file operations use strict permissions (600/700)
- [ ] No unquoted variable expansions in command arguments
- [ ] Download URLs are pinned to version tags (not `main`)
- [ ] Concurrent operations are protected with `flock`

## Multilingual Scripts

When modifying Russian scripts (`*.sh`), update the corresponding English versions (`*_en.sh`):

- `awg_common.sh` → `awg_common_en.sh`
- `manage_amneziawg.sh` → `manage_amneziawg_en.sh`
- `install_amneziawg.sh` → `install_amneziawg_en.sh`

Run `diff install_amneziawg.sh install_amneziawg_en.sh` to verify only text differences remain.

Function counts and the overall structure (the same functions in the same order) should remain equal between the two language versions. Line counts may differ slightly - RU and EN comments are not the same length, so a small line-count delta is normal and not a defect. Quick sanity check (compares function counts):

```bash
for pair in "install_amneziawg.sh install_amneziawg_en.sh" "awg_common.sh awg_common_en.sh" "manage_amneziawg.sh manage_amneziawg_en.sh"; do
  set -- $pair
  ru_funcs=$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$1")
  en_funcs=$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$2")
  echo "$1: $ru_funcs funcs | $2: $en_funcs funcs"
done
```

## Multilingual Documentation

The same mirror rule applies to user-facing markdown documents:

- `README.md` ↔ `README.en.md`
- `ADVANCED.md` ↔ `ADVANCED.en.md`
- `CHANGELOG.md` ↔ `CHANGELOG.en.md`

When updating any of them, keep the following in sync between the two versions:

- Section headings and order
- Commands and code examples (identical - commands are bash)
- Release facts: version numbers, test counts, supported distros
- Internal links (each RU anchor should have an EN counterpart at the same place)
- Tables (same rows and columns)

Non-mirrored documents (`CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`) are English-only by convention.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix     | Usage                        |
|------------|------------------------------|
| `fix:`     | Bug fix                      |
| `feat:`    | New feature                  |
| `docs:`    | Documentation only           |
| `ci:`      | CI/CD changes                |
| `refactor:`| Code restructuring, no behavior change |
| `test:`    | Adding or updating tests     |
| `chore:`   | Maintenance, dependency updates |

Examples:
```
fix: correct UFW rule ordering for dual-stack setups
feat: add --diagnostic flag for troubleshooting
docs: update CHANGELOG for v5.5
```

## Pull Request Workflow

1. Fill in the PR template completely
2. Ensure CI checks pass: ShellCheck, syntax (`bash -n`), the bats test suite, and documentation consistency (`scripts/check-docs-consistency.sh`). The quickest way to clear the bar locally is the full gate: `BASE_REF=origin/main bash scripts/preflight-check.sh`
3. **If your PR adds or modifies a GitHub Actions workflow** (`.github/workflows/*.yml`) or a build script (`scripts/*.sh`), run the workflow on your fork and confirm it passes **before** requesting review. `arm-build.yml` supports `workflow_dispatch` for manual triggering; other workflows run automatically on push. This catches environment-specific failures that local testing cannot.
4. Update **both** `CHANGELOG.md` and `CHANGELOG.en.md` if applicable
5. Update `[Unreleased]` comparator link in both CHANGELOGs when bumping version
6. Request a review from `@bivlked`
7. Address review feedback
8. Once approved, the maintainer will merge

## Questions?

Open a [discussion](https://github.com/bivlked/amneziawg-installer/discussions) or an issue if you have questions about contributing.
