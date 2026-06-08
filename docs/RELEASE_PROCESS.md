# Release process

This is the maintainer runbook for cutting a tagged release of
amneziawg-installer. It is the public, self-contained reference that
`scripts/preflight-check.sh` points at. Contributors do not need to run a
release, but a green `preflight-check.sh` is the bar a release branch must
clear before it is tagged.

## Versioned files and the lockstep rule

Six scripts carry a version and must stay in lockstep at the **same** release
number:

- `install_amneziawg.sh`, `install_amneziawg_en.sh`
- `manage_amneziawg.sh`, `manage_amneziawg_en.sh`
- `awg_common.sh`, `awg_common_en.sh`

On every release, regardless of which files changed content:

1. Set `SCRIPT_VERSION` in all four scripts that carry it
   (`install_amneziawg*.sh`, `manage_amneziawg*.sh`) and the
   `# Version:` / `# Версия:` header in all six scripts to the same new
   `X.Y.Z`. `preflight-check.sh` step 7 rejects a partial bump: it requires all
   four `SCRIPT_VERSION` values and all six headers to agree. Update the header
   date in every file you edited; an untouched file may keep its existing date
   as long as the version matches. (The version-triple check also ties
   `SCRIPT_VERSION` to the README badge and the top changelog heading, so this
   number is the release tag.)
2. Bumping the `# Version:` / `# Версия:` header in `awg_common*.sh` and
   `manage_amneziawg*.sh` changes their bytes, so their SHA256 changes on every
   release even when their logic did not. Recompute the four pins
   (`COMMON_SCRIPT_SHA256` / `MANAGE_SCRIPT_SHA256`, RU + EN) with:

   ```bash
   bash scripts/update-sha-pins.sh          # rewrite the four pins
   bash scripts/update-sha-pins.sh --verify # confirm they match
   ```

   A mismatched pin means a fresh install fails the over-the-network integrity
   check, so the pins must be recomputed after the helper scripts are final and
   before the tag is pushed.
3. Bump the pinned raw-URL tags in `README*.md`, `ADVANCED*.md` and
   `INSTALL_VPS.md` from the previous `vX.Y.Z` to the new one. Users copy the
   install and update one-liners verbatim, so a stale tag silently installs the
   previous release. `check-docs-consistency.sh` (preflight step 9) enforces
   that these tags equal `SCRIPT_VERSION`, but the bump itself is manual.

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
  installer `--help`, issue template). When adding a new OS version, decide its
  ARM story explicitly: either add a prebuilt target (an `arm-build.yml` matrix
  entry plus the mapping in `_try_install_prebuilt_arm`) or keep it DKMS-only and
  document that in INSTALL_VPS.md / ADVANCED. `check-docs-consistency.sh` fails
  if a supported Ubuntu version has no ARM prebuilt target and is not marked
  DKMS-only (e.g. Ubuntu 26.04 ARM64 is DKMS-only today).
- The public roadmap issue
  ([#79](https://github.com/bivlked/amneziawg-installer/issues/79)) reflects the
  release: shipped items move to "Recently shipped" and leave the plan sections,
  in both the RU and EN halves of the issue body.

## External-review gate (significant releases)

A significant release is developed on a public `dev/vX.Y.Z` branch pushed to
origin, with a draft PR into `main`, so other teams can review the code before
it is tagged. Do not merge until the review is addressed,
`preflight-check.sh` is green, and the maintainer has explicitly approved the
tag. Keep the PR description to clean public context only (no internal tooling
notes). This review gate sits between implementation and the tagging steps
below.

## Tagging and the two release workflows

A tag push (`git push origin vX.Y.Z`) triggers two independent workflows:

- `release.yml` (about 30 seconds): runs the preflight gate, then creates the
  GitHub Release with the bilingual body and title assembled by
  `scripts/build-release-notes.sh` from both changelogs (see "Release notes"
  below). The publish step depends on the gate, so a tag that fails preflight
  does not produce a release.
- `arm-build.yml` (about 20-30 minutes): builds the ARM prebuilt `.deb`
  packages under QEMU and publishes them to the separate `arm-packages`
  release. This is a separate, slower track and does not block the main
  release. For a reproducible build, pin the upstream kernel-module ref (a tag)
  in `scripts/arm-module-version.txt` before tagging; left at `HEAD` it builds
  the upstream default branch. Each `.deb` ships with a `.manifest.json`
  recording the installer tag, the exact upstream commit, the kernel version and
  the SHA256, so the mutable `arm-packages` assets stay auditable.

The release is not finished until both runs are green. Then run this post-publish
health check:

- The Releases page shows the new tag as "Latest", and that tag equals
  `SCRIPT_VERSION` and the README version badge.
- The `arm-packages` release was refreshed by `arm-build.yml` (its assets carry
  the new installer tag in their `.manifest.json`).
- Open the rendered README on GitHub and confirm the install and update
  one-liners point at the new tag - a final guard against a stale raw-URL
  slipping past the automated check.

Note: `release.yml` only depends on the preflight gate, so the GitHub Release can
appear before `arm-build.yml` finishes. For a release that advertises ARM
prebuilt packages, wait for the ARM run to go green before announcing.

If the preflight gate fails on a pushed tag, the release is not published.
Delete the tag (`git push origin :refs/tags/vX.Y.Z` and `git tag -d vX.Y.Z`),
fix the branch, and re-tag.

## Release notes

`release.yml` now builds the release body and title automatically via
`scripts/build-release-notes.sh`. It assembles the bilingual body from both
changelogs (Russian header, a `[English version below](#english-version)` link,
the Russian content, an `<a id="english-version"></a>` anchor, then the English
content) and derives a descriptive title from the EN lead line
`**vX.Y.Z** - <summary>.` (giving `vX.Y.Z: <summary>`, or just `vX.Y.Z` if no
lead is present). The job fails before publishing if the version section is
missing from either `CHANGELOG.md` or `CHANGELOG.en.md`.

Because the title comes from the changelog lead, write each release's EN lead
line in that form so the generated title reads well.

You can preview locally before tagging:

```bash
bash scripts/build-release-notes.sh X.Y.Z          # body
bash scripts/build-release-notes.sh --title X.Y.Z  # title
```

Emergency fallback only (if the automated body needs a manual touch-up):

```bash
gh release edit vX.Y.Z --notes-file body.md --title "vX.Y.Z: <short summary>"
```

## Release signing

Release signing (minisign detached signatures) is designed but not active. See
`docs/SIGNING_DESIGN.md`. The draft workflow `docs/release-sign.yml.draft` is
not installed under `.github/workflows/` until a maintainer public key is
published as `KEYS.txt`.
