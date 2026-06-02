# Release process

This is the maintainer runbook for cutting a tagged release of
amneziawg-installer. It is the public, self-contained reference that
`scripts/preflight-check.sh` points at. Contributors do not need to run a
release, but a green `preflight-check.sh` is the bar a release branch must
clear before it is tagged.

## Versioned files and the lockstep rule

Six scripts carry a version and must stay in lockstep:

- `install_amneziawg.sh`, `install_amneziawg_en.sh`
- `manage_amneziawg.sh`, `manage_amneziawg_en.sh`
- `awg_common.sh`, `awg_common_en.sh`

When any of them changes in a release:

1. Bump `SCRIPT_VERSION` and the `# Version:` / `# Версия:` header (plus the
   date) only in the files that actually changed.
2. The installers download the helper scripts over the network and verify
   their SHA256 against pinned constants. If `awg_common*.sh` or
   `manage_amneziawg*.sh` changed, recompute the four pins
   (`COMMON_SCRIPT_SHA256` / `MANAGE_SCRIPT_SHA256`, RU + EN) with:

   ```bash
   bash scripts/update-sha-pins.sh          # rewrite the four pins
   bash scripts/update-sha-pins.sh --verify # confirm they match
   ```

   A mismatched pin means a fresh install fails the over-the-network integrity
   check, so the pins must be recomputed after the helper scripts are final and
   before the tag is pushed.

## Pre-tag checklist

Run the full gate in one shot:

```bash
BASE_REF=origin/main bash scripts/preflight-check.sh
```

`preflight-check.sh` runs, in order:

1. `bash -n` on the six scripts.
2. `shellcheck -s bash -S warning` on the six scripts.
3. `bats tests/`.
4. No newly added em-dash / en-dash (U+2013 / U+2014) in the diff against
   `BASE_REF`. New text is hyphen-minus only. Legacy dashes in existing lines
   are kept (no mass purge); a word-diff is used so that point-editing a legacy
   line does not flag a dash it already contained - only a genuinely new dash
   fails. If you do touch such a line, converting its dashes to hyphens is
   welcome but not required.
5. No AI / tool markers introduced in the diff or in the commit-message log.
6. No `Co-authored-by` trailers in the commit-message log.
7. `SCRIPT_VERSION` and the six version headers agree.
8. SHA pins in lockstep (`update-sha-pins.sh --verify`).
9. Documentation consistency (`scripts/check-docs-consistency.sh`): internal
   anchors resolve, changelog headings have reference links and the RU/EN
   version sets match, the version triple agrees, the OS matrix is current.

`BASE_REF` selects the ref the diff checks compare against. If you do not set
it, the script tries `main`, then `origin/main`. On a detached checkout with no
local `main` (for example a freshly cloned CI runner on a tag), set it
explicitly: `BASE_REF=origin/main`. `LOG_RANGE` (default `<base>..HEAD`)
selects which commits the message checks read; merge commits brought in from
`main` are outside the branch range and are not re-checked.

Also confirm by hand before tagging:

- CHANGELOG entry added to both `CHANGELOG.md` and `CHANGELOG.en.md` in the
  exact heading format `## [X.Y.Z] - YYYY-MM-DD` (the release workflow parses it
  with awk), plus the matching `[X.Y.Z]:` reference link, and the `[Unreleased]`
  link retargeted to `vX.Y.Z...HEAD`.
- The RU and EN changelogs list the same set of versions.
- The README version badge, `SCRIPT_VERSION`, and the newest changelog heading
  all agree.
- Ubuntu / Debian support matrix is current everywhere it is stated (README,
  installer `--help`, issue template).

## Tagging and the two release workflows

A tag push (`git push origin vX.Y.Z`) triggers two independent workflows:

- `release.yml` (about 30 seconds): runs the preflight gate, then creates the
  GitHub Release from the matching `CHANGELOG.en.md` section. The publish step
  depends on the gate, so a tag that fails preflight does not produce a
  release.
- `arm-build.yml` (about 20-30 minutes): builds the ARM prebuilt `.deb`
  packages under QEMU and publishes them to the separate `arm-packages`
  release. This is a separate, slower track and does not block the main
  release.

The release is not finished until both runs are green.

If the preflight gate fails on a pushed tag, the release is not published.
Delete the tag (`git push origin :refs/tags/vX.Y.Z` and `git tag -d vX.Y.Z`),
fix the branch, and re-tag.

## Release notes

`release.yml` fills the English release body from `CHANGELOG.en.md`. Add the
Russian section by hand afterwards:

```bash
gh release edit vX.Y.Z --notes-file body.md
```

Follow the established bilingual template: Russian header, a
`[English version below](#english-version)` link, the Russian content, an
`<a id="english-version"></a>` anchor, then the English content.

## Release signing

Release signing (minisign detached signatures) is designed but not active. See
`docs/SIGNING_DESIGN.md`. The draft workflow `docs/release-sign.yml.draft` is
not installed under `.github/workflows/` until a maintainer public key is
published as `KEYS.txt`.
