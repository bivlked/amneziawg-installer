# signing/

Detached minisign signatures for the current release, one `<script>.minisig`
per signed file.

These files are **transient**. They are produced on the maintainer's machine
immediately before a tag, committed so they land in the tagged commit, and left
in place until the next release replaces them. They are deliberately **not**
gitignored: `release.yml` checks out the tag and refuses to publish without
them.

## Why the signing does not happen in CI

The private key never reaches GitHub Actions. That is the entire point of the
scheme: a signature produced by CI would prove only that CI ran, which is
already what a GitHub Release proves. A signature produced offline proves that
the holder of a key that has never touched the network approved these exact
bytes.

## Producing them

```bash
TAG=v5.29.0                                   # the tag about to be pushed
KEY=~/.minisign/amneziawg-installer.key
mkdir -p signing
for f in $(bash scripts/signed-file-list.sh); do
  minisign -Sm "$f" -s "$KEY" -x "signing/$f.minisig" \
           -t "amneziawg-installer $TAG $f"
done
bash scripts/verify-signatures.sh "$TAG"      # confirm before committing
```

The `-t` trusted comment is not decoration. A signature proves that some bytes
were signed, not that they were signed *for this release*: an old file with its
own old signature verifies perfectly well. Binding the comment to tag and
filename is what makes a rollback or a swapped file detectable, and
`verify-signatures.sh` fails if the comment does not name the expected tag.

## Verifying as a user

Everything needed is attached to each release, so nothing has to be trusted
from a second place at verification time:

```bash
minisign -V -p KEYS.txt -m install_amneziawg.sh -x install_amneziawg.sh.minisig
```

⚠️ Fetching `KEYS.txt` from this repository in the same session as the script
gives no protection against a compromise of the repository itself - an attacker
able to replace one can replace all three. The key is worth pinning once from a
source outside GitHub and reusing it afterwards; that is what turns the
signature into a real check rather than a ritual.
