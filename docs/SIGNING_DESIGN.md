# Release signing design (v5.14+ proposal)

Status: **DRAFT** - awaiting user-action (offline keypair generation) before activation.

## Why

Modern open-source security practice (NixOS, signify-based tools, libsodium ecosystem) ships releases with detached cryptographic signatures so users can verify a downloaded script has not been tampered with on the path from GitHub to their server. Right now `install_amneziawg.sh` is fetched via HTTPS from `raw.githubusercontent.com`, which means trust is rooted in GitHub's TLS chain + GitHub's account security alone. Adding a maintainer-controlled signature gives an independent verification path - with the important caveat below.

- TLS only proves "the bytes came from GitHub". A signature proves "the bytes were signed by the holder of the private key", which lives offline on the maintainer's machine and is never exposed to GitHub Actions.
- The protection is asymmetric. If a user already has the correct maintainer public key fingerprint pinned (e.g. saved from an earlier verified release, or fetched from an out-of-band channel - personal blog post, mastodon profile, signed git tag predating the compromise), then a malicious replacement script fails verification because the attacker cannot forge a signature without the offline secret key. **However**, a first-time user who fetches `KEYS.txt` and the installer from the same compromised GitHub account in the same session is exposed to a TOFU window: the attacker can atomically replace `KEYS.txt`, the script, and the signature, and the verification will succeed against the attacker's key. This is not a flaw of minisign - it is the general TOFU limitation of any public-key-on-the-same-domain scheme. To narrow the window, the maintainer should also publish the public-key fingerprint via at least one independent out-of-band channel.

Competitor `pwnnex/ByeByeVPN` (303 stars, viral growth +48/week) already ships `minisign` signatures and an SBOM with each release. Cost: ~2-4 hours one-time setup + ~30 sec per release.

## Tool choice: minisign

| Option | Pros | Cons |
|---|---|---|
| `minisign` ([jedisct1/minisign](https://github.com/jedisct1/minisign)) | Curve25519, single 32-byte key pair, no GPG keyring drama, Ed25519 signing, `minisign -V` is one command for users | Less ubiquitous than GPG, must be installed (`apt install minisign`) |
| `cosign` keyless via Sigstore | No key management, federated trust through Fulcio | Newer dependency, requires Sigstore infra availability at verification time, harder to verify offline |
| GPG signed tags + commits | Already supported by GitHub UI ("Verified" badge); a verified tag does cover the blobs it points at | Does not protect the curl-to-raw or release-asset download path; user has to verify the tag separately and rebuild from sources to be sure |

**Decision:** minisign. Smallest moving parts, offline-friendly verify, no third-party trust roots, well-understood by security-conscious sysadmins.

## Threat model

Covered:
- Tampering with `install_amneziawg.sh` or `install_amneziawg_en.sh` between GitHub Releases and the user's `wget` call, provided the user has the correct maintainer public-key fingerprint pinned from an earlier session or an out-of-band channel.
- Compromise of GitHub Actions specifically: signatures are never produced by Actions, so a compromised CI cannot forge them.

Partially covered:
- Compromise of the GitHub account leading to a malicious replacement upload. Returning users with a pinned fingerprint detect this; first-time users fetching `KEYS.txt` from the same compromised repository in the same session do not (TOFU). Mitigated by publishing the fingerprint via at least one independent channel.

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

Per release, after `git tag vX.Y.Z` but before `git push origin vX.Y.Z`. Each signature carries a trusted comment binding it to the tag and filename, so an old signature paired with a different file or a different release fails to verify (rollback / misbinding protection):

```bash
TAG=v5.14.0
KEY=~/.minisign/amneziawg-installer.key
for f in install_amneziawg.sh install_amneziawg_en.sh \
         manage_amneziawg.sh manage_amneziawg_en.sh \
         awg_common.sh awg_common_en.sh; do
  minisign -Sm "$f" -s "$KEY" -t "amneziawg-installer ${TAG} ${f}"
done
```

Verifiers should glance at the `Trusted comment:` line that `minisign -V` prints and ensure it matches the file they actually downloaded for the tag they intended.

Produces `*.minisig` files alongside each script.

Then attach them to the GitHub Release as assets (manually via `gh release upload`, or via the workflow described below).

## Workflow integration (proposal)

Two options, pick one when activating:

### Option A: Manual asset upload (lighter)

After `git push origin vX.Y.Z`, the existing `release.yml` creates the release from `CHANGELOG.en.md`. Add a manual step:

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

Maintainer generates `*.minisig` files locally, commits them transiently to a `signing/` directory (gitignored elsewhere), tags. A separate, manually dispatched workflow reads them and uploads as assets. Same trust model as Option A - just automates the upload step.

The signing of the files NEVER happens in GitHub Actions. The private key is never exposed to Actions. This is intentional and the whole point.

A draft of Option B is committed at `docs/release-sign.yml.draft` for review. It is a standalone `workflow_dispatch` workflow (not a job added to `release.yml`), and is NOT placed in `.github/workflows/` until the public key is published. When activated it uploads, for each of the six scripts, the script itself plus its `.minisig`, and also attaches `KEYS.txt` - so everything needed to verify is available from a single release. `release.yml` itself does not publish the `.sh` files as assets; that is intentionally left to the signing workflow to avoid two code paths uploading the same files. Until signing is activated, the canonical way to obtain a script is still the documented `wget` from `raw.githubusercontent.com`.

## User-side verification

Document in README "Verifying releases" section:

```bash
# 1. Install minisign:
sudo apt install minisign           # Ubuntu/Debian
# or:
brew install minisign                # macOS

# 2. Fetch the public key from the repository (one time):
curl -O https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/KEYS.txt

# 3. Fetch the installer + signature:
TAG=v5.14.0
curl -LO "https://github.com/bivlked/amneziawg-installer/releases/download/$TAG/install_amneziawg_en.sh"
curl -LO "https://github.com/bivlked/amneziawg-installer/releases/download/$TAG/install_amneziawg_en.sh.minisig"

# 4. Verify:
minisign -V -p KEYS.txt -m install_amneziawg_en.sh -x install_amneziawg_en.sh.minisig
# Expected: "Signature and comment signature verified"

# 5. If verified - now you can install:
sudo bash ./install_amneziawg_en.sh
```

## Implementation checkpoints

Activation steps, in order:

1. **USER**: Generate offline keypair with `minisign -G` on a trusted machine. Backup the private key to encrypted offline storage. Set a strong password.
2. **USER**: Hand over the public key file (`*.pub`) for commit to the repository as `KEYS.txt`.
3. Add `docs/SIGNING_DESIGN.md` (this file). DONE in this commit.
4. Add README section "Verifying releases" with placeholder link to this design doc. TODO - add when the public key is published as `KEYS.txt` so the section is actionable, not vapor.
5. Add the draft workflow `docs/release-sign.yml.draft` for review. DONE.
6. After keypair exists and is published as `KEYS.txt`:
   a. Move `docs/release-sign.yml.draft` to `.github/workflows/release-sign.yml`.
   b. Test on a pre-release tag (e.g., `v5.14.0-rc1`).
   c. Flip the README section from "planned" to "active".
7. Optional follow-up: SBOM generation via `syft` or GitHub's native dependency graph (a separate, smaller task).

## Out of scope (intentionally deferred)

- **SBOM generation**: distinct deliverable. Will be added in a follow-up commit once signing is stable. `syft` is the leading tool; GitHub also auto-generates a dependency graph SBOM which is enough for an initial pass.
- **Signing of ARM prebuilt `.deb` packages** published to the `arm-packages` release: same principle applies but needs a separate flow because the arm-build workflow runs inside Docker via QEMU. Defer.
- **Reproducible builds**: Bash scripts are already self-contained text files - signatures cover them as-is. No build determinism work needed.

## References

- minisign project page: <https://jedisct1.github.io/minisign/>
- minisign source repository: <https://github.com/jedisct1/minisign>
- pwnnex/ByeByeVPN (prior art in this corner): <https://github.com/pwnnex/ByeByeVPN>
- OpenBSD `signify` (the design minisign is descended from): <https://man.openbsd.org/signify>
