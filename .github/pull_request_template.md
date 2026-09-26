## Summary

<!-- Brief description of changes -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Documentation
- [ ] CI/CD
- [ ] Refactoring

## Checklist

- [ ] `bash -n` passes for all modified scripts
- [ ] `shellcheck -s bash -S warning` passes
- [ ] `bats tests/` passes (add a test for new behaviour)
- [ ] `scripts/check-docs-consistency.sh` passes (if docs or metadata changed)
- [ ] Tested on clean Ubuntu 24.04 LTS VPS (if script changes)
- [ ] Tested on Ubuntu 25.10/26.04 (noble fallback path, if PPA/install logic changes)
- [ ] Tested on Debian 12/13 (if OS-specific changes)
- [ ] CHANGELOG.md **and** CHANGELOG.en.md updated (including `[Unreleased]` comparator link), or not applicable (internal/test-only change)
- [ ] SCRIPT_VERSION, AWG_COMMON_VERSION and the six `# Version:` headers updated (if releasing)
- [ ] SHA pins recomputed and verified (`scripts/update-sha-pins.sh --verify`) (if `awg_common*`/`manage_amneziawg*` changed)
- [ ] Version badge in README.md and README.en.md updated (if version bump)
- [ ] Documentation updated (if applicable)
- [ ] Security-sensitive changes reviewed (no eval/source on user data, strict permissions)
- [ ] English script versions (`_en.sh`) synchronized (if Russian scripts modified)
- [ ] Rollback tested: `--uninstall` + fresh install (if installer changes)
- [ ] vpn:// URI generation verified (if `awg_common` changes)

## If this PR prepares a release

Skip this section for ordinary PRs. For a release-bound PR, the tag is gated by
`preflight-check.sh`, which checks more than the boxes above:

- [ ] `BASE_REF=origin/main bash scripts/preflight-check.sh` is green (full pre-tag gate)
- [ ] `bash scripts/update-sha-pins.sh --verify` passes (4 helper SHA pins in lockstep)
- [ ] Pinned `raw.githubusercontent.com/.../vX.Y.Z/...` tags in ADVANCED and CASCADE (both languages) equal the release version
- [ ] Signatures made for this tag and committed under `signing/`: `bash scripts/sign-release.sh vX.Y.Z` (after the SHA pins, before the tag); `bash scripts/verify-signatures.sh vX.Y.Z` passes
- [ ] No `Co-authored-by` trailers and no AI/tool markers in the diff or commit log
