# Release signing design

Status: **ACTIVE** since 27 aug 2026. The keypair exists, `KEYS.txt` is
committed, and `release.yml` refuses to publish a release whose signatures do
not verify.

Public key: `RWQXfpABHIpZPttqrwYrQNHRTk/iLIz4cVh9KkRwAElHP+CoW/NPEysN` (key ID `3E598A1C01907E17`; the ID is not a fingerprint,
another key can carry the same ID, so compare the whole key). Publishing it through a channel that is
not this repository is what makes it worth anything to a first-time visitor;
that is tracked separately and is not done by this document.

## Why

Modern open-source security practice (NixOS, signify-based tools, libsodium ecosystem) ships releases with detached cryptographic signatures so users can verify a downloaded script has not been tampered with on the path from GitHub to their server. Without a signature, trust in a script fetched over HTTPS from the latest GitHub release assets rests on GitHub's TLS chain and GitHub's account security alone. Adding a maintainer-controlled signature gives an independent verification path - with the important caveat below.

- TLS only proves "the bytes came from GitHub". A signature proves "the bytes were signed by the holder of the private key", which lives offline on the maintainer's machine and is never exposed to GitHub Actions.
- The protection is asymmetric. If a user already has the correct maintainer public key pinned (e.g. saved from an earlier verified release, or fetched from an out-of-band channel - personal blog post, mastodon profile, signed git tag predating the compromise), then a malicious replacement script fails verification because the attacker cannot forge a signature without the offline secret key. **However**, a first-time user who fetches `KEYS.txt` and the installer from the same compromised GitHub account in the same session is exposed to a TOFU window: the attacker can atomically replace `KEYS.txt`, the script, and the signature, and the verification will succeed against the attacker's key. This is not a flaw of minisign - it is the general TOFU limitation of any public-key-on-the-same-domain scheme. To narrow the window, the maintainer should also publish the whole public key via at least one independent out-of-band channel.

## Tool choice: minisign

| Option | Pros | Cons |
|---|---|---|
| `minisign` ([jedisct1/minisign](https://github.com/jedisct1/minisign)) | Curve25519, single 32-byte key pair, no GPG keyring drama, Ed25519 signing, `minisign -V` is one command for users | Less ubiquitous than GPG, must be installed (`apt install minisign`) |
| `cosign` keyless via Sigstore | No key management, federated trust through Fulcio | Newer dependency, requires Sigstore infra availability at verification time, harder to verify offline |
| GPG signed tags + commits | Already supported by GitHub UI ("Verified" badge); a verified tag does cover the blobs it points at | Does not protect the curl-to-raw or release-asset download path; user has to verify the tag separately and rebuild from sources to be sure |

**Decision:** minisign. Smallest moving parts, offline-friendly verify, no third-party trust roots, well-understood by security-conscious sysadmins.

## Threat model

Covered:
- Tampering with `install_amneziawg.sh` or `install_amneziawg_en.sh` between GitHub Releases and the user's `wget` call, provided the user has the correct maintainer public key pinned from an earlier session or an out-of-band channel.
- Compromise of GitHub Actions specifically: signatures are never produced by Actions, so a compromised CI cannot forge them.

Partially covered:
- Compromise of the GitHub account leading to a malicious replacement upload. Returning users with a pinned public key detect this; first-time users fetching `KEYS.txt` from the same compromised repository in the same session do not (TOFU). Mitigated by publishing the public key via at least one independent channel.

NOT covered:
- Rollback / misbinding: an old valid script paired with its old valid `.minisig` will verify successfully if a user accepts whatever pair they happened to download. Mitigated by trusted comments tying the signature to a specific tag and filename (see signing flow below) and by users checking the comment line on verify.
- Compromise of the maintainer's offline machine where the private key is stored.
- Social engineering tricking the user into running a different command.
- Supply chain attacks on the AmneziaWG kernel module or the Amnezia PPA (out of scope - those are upstream concerns).

## Keypair generation (one-time, USER-ACTION)

The private key MUST be generated offline by the maintainer and MUST NEVER leave that machine.

```bash
# On a clean, network-isolated machine if possible:
minisign -G -p amneziawg-installer.pub -s amneziawg-installer.key

# Choose a strong password. Write it down somewhere physical.
# Backup the .key file to encrypted offline storage (e.g., encrypted USB stick).
```

Generated files:
- `amneziawg-installer.pub` (public key) - 56-byte file, safe to commit to the repository as `KEYS.txt` or `KEYS/amneziawg-installer.pub`.
- `amneziawg-installer.key` (private key) - encrypted with the password. NEVER commit. NEVER upload to GitHub Secrets (defeats the purpose - signing must be local to the maintainer's machine).

## Signing flow

Per release, after the last change to the six scripts and before `git tag`: the signatures are committed under `signing/` so they land in the tagged commit. Each signature carries a trusted comment binding it to the tag and filename, so `scripts/verify-signatures.sh`, and a user who reads the `Trusted comment:` line, reject a signature made for a different file or release (rollback / misbinding protection). Sign with:

```bash
bash scripts/sign-release.sh vX.Y.Z
```

It writes the `.minisig` files under `signing/`, asks for the key password once, and refuses to run without a terminal. `release.yml` attaches the signatures to the release.

`minisign -V` alone does not compare the comment with the tag, so verifiers should glance at the `Trusted comment:` line it prints and ensure it matches the file they actually downloaded for the tag they intended.

## Workflow integration (history)

Option B is what runs today; Option A is kept only as the record of the decision.

### Option A: Manual asset upload (lighter)

After `git push origin vX.Y.Z`, the existing `release.yml` creates the release (bilingual notes built by `scripts/build-release-notes.sh`). Add a manual step:

```bash
gh release upload vX.Y.Z \
  install_amneziawg.sh install_amneziawg.sh.minisig \
  install_amneziawg_en.sh install_amneziawg_en.sh.minisig \
  manage_amneziawg.sh manage_amneziawg.sh.minisig \
  manage_amneziawg_en.sh manage_amneziawg_en.sh.minisig \
  awg_common.sh awg_common.sh.minisig \
  awg_common_en.sh awg_common_en.sh.minisig
```

Pros: zero CI changes, signatures generated on the trusted maintainer machine. Cons: extra manual step per release.

### Option B: CI uploads signatures generated locally (asymmetric)

Maintainer generates `*.minisig` files locally, commits them to `signing/` (tracked, so they land in the tagged commit - `signing/` is intentionally NOT gitignored), tags. CI reads them and uploads them as assets. Same trust model as Option A, just without the manual upload step.

The signing of the files NEVER happens in GitHub Actions. The private key is never exposed to Actions. This is intentional and the whole point.

**Chosen: Option B, folded into `release.yml` rather than a separate dispatch.**

### Why the separate dispatch workflow was dropped (27 aug 2026)

The original draft put the upload in a standalone `workflow_dispatch` workflow, reasoning that two code paths uploading the same files would be worse than one manual step. Measurement showed the cost of that ordering was higher than the duplication it avoided.

`release.yml` published with `draft: false` immediately, so a release became **Latest with zero assets** and stayed that way until somebody remembered to run the dispatch. For that entire window `releases/latest/download/<file>` answered 404 - and that is precisely the address documentation and third-party write-ups hand to users. The window was unbounded because nothing forced the second step.

So the ordering is now: verify the signatures, create the release as a **draft**, attach the scripts, the signatures and `KEYS.txt`, count the assets, and only then flip it out of draft. A release is never visible in a half-assembled state, and the failure mode of a forgotten signature is a failed workflow rather than a silently empty release.

Two consequences worth stating plainly, because they change the maintainer's routine:

- **Signing is now mandatory for every release.** Without `signing/*.minisig` in the tagged commit, `release.yml` fails and nothing is published. `preflight-check.sh` performs the same verification locally, so the normal place to discover a missing signature is before the tag, not after.
- **A failed run is resumable.** The workflow distinguishes absent / draft / published: a leftover draft means "resume", so re-running after a network hiccup finishes the job instead of skipping it as already done.

## User-side verification

User-side verification lives in README ([EN](../README.en.md#verifying-a-release), [RU](../README.md#proverka-podpisi)); keep one copy of the commands there. It checks the whole public key with `minisign -P`, not the key ID.

## Implementation checkpoints

Activation steps, in order:

1. **USER**: Generate offline keypair with `minisign -G` on a trusted machine. Backup the private key to encrypted offline storage. Set a strong password.
2. **USER**: Hand over the public key file (`*.pub`) for commit to the repository as `KEYS.txt`.
3. Add `docs/SIGNING_DESIGN.md` (this file). DONE in this commit.
4. README section "Verifying a release": done, see 6c.
5. A draft dispatch workflow: done, then superseded by `release.yml` (see 6a).
6. After keypair exists and is published as `KEYS.txt`: DONE 27 aug 2026.
   a. Signature verification and asset upload folded into `release.yml`; the draft dispatch workflow was removed rather than activated (see above). The publish path uses `gh` directly, which removes one third-party action from the step that decides what the world downloads.
   b. Test on a pre-release tag (`vX.Y.Z-rc1`). A tag with a semver pre-release suffix is published as a pre-release automatically, so a test never displaces the real Latest.
   c. README "Verifying a release" section is live in both languages.
7. Optional follow-up: SBOM generation via `syft` or GitHub's native dependency graph (a separate, smaller task).

## Per-release routine

```bash
TAG=vX.Y.Z
KEY=~/.minisign/amneziawg-installer.key
mkdir -p signing
for f in $(bash scripts/signed-file-list.sh); do
  minisign -Sm "$f" -s "$KEY" -x "signing/$f.minisig" -t "amneziawg-installer $TAG $f"
done
bash scripts/verify-signatures.sh "$TAG"
git add signing && git commit -m "chore: signatures for $TAG"
```

Sign **after** the last change to the six scripts and **before** the tag. Signing earlier and then amending a script produces signatures that verify against nothing; `verify-signatures.sh` and `preflight-check.sh` both catch that, but only if they are run.

## Out of scope (intentionally deferred)

- **SBOM generation**: distinct deliverable. Will be added in a follow-up commit once signing is stable. `syft` is the leading tool; GitHub also auto-generates a dependency graph SBOM which is enough for an initial pass.
- **Signing of ARM prebuilt `.deb` packages** published to the `arm-packages` release: same principle applies but needs a separate flow because the arm-build workflow runs inside Docker via QEMU. Defer.
- **Reproducible builds**: Bash scripts are already self-contained text files - signatures cover them as-is. No build determinism work needed.

## References

- minisign project page: <https://jedisct1.github.io/minisign/>
- minisign source repository: <https://github.com/jedisct1/minisign>
- pwnnex/ByeByeVPN (prior art in this corner): <https://github.com/pwnnex/ByeByeVPN>
- OpenBSD `signify` (the design minisign is descended from): <https://man.openbsd.org/signify>
