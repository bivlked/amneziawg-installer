#!/usr/bin/env bats
# The Amnezia PPA signing key is embedded in both installers (D#292).
#
# It used to be downloaded from keyserver.ubuntu.com only, with no timeout, so
# a server that could not reach that host (filtering, a keyserver outage)
# failed step 2 after minutes of silence, even when the PPA itself was
# reachable. Now step 2 needs no network to get the key: the key block ships
# in the script and is checked against the pinned fingerprint before it is
# installed.
#
# The real install_amnezia_ppa_keyring and _amnezia_ppa_key_armored from each
# installer run here, with curl and wget replaced by executables that fail
# and record the call.

PIN="75C9DD72C799870E310542E24166F2C257290828"

# key_run <installer> <keyring path> [extra shell] ; prints the output and RC=.
key_run() {
    local src="$1" dest="$2" extra="${3:-}"
    # curl and wget are executables first in PATH, not shell functions, so a
    # call through `timeout`, `env` or `command` is caught as well.
    PATH="$BATS_TEST_TMPDIR/netstub:$PATH" GNUPGHOME="$GNUPGHOME" NET_CALLS="$BATS_TEST_TMPDIR/net_calls" \
    timeout 60 bash -c '
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        die() { echo "DIE: $*"; exit 1; }
        eval "$(awk "/^_amnezia_ppa_key_armored\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^install_amnezia_ppa_keyring\\(\\) \\{/,/^\\}/" "$1")"
        declare -F install_amnezia_ppa_keyring >/dev/null || { echo NO_FUNC; exit 7; }
        eval "$3"
        install_amnezia_ppa_keyring "$2"
        echo "RC=$?"
    ' _ "$src" "$dest" "$extra"
}

setup() {
    export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
    mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    mkdir -p "$BATS_TEST_TMPDIR/keyrings"
    : > "$BATS_TEST_TMPDIR/net_calls"
    mkdir -p "$BATS_TEST_TMPDIR/netstub"
    local n
    for n in curl wget; do
        printf '#!/bin/sh\necho "%s $*" >> "$NET_CALLS"\nexit 1\n' "$n" > "$BATS_TEST_TMPDIR/netstub/$n"
        chmod +x "$BATS_TEST_TMPDIR/netstub/$n"
    done
}

# other_key_asc : prints the path of an armored throwaway key (not the pin).
other_key_asc() {
    local other="$BATS_TEST_TMPDIR/other.asc"
    if [[ ! -s "$other" ]]; then
        gpg --batch --no-tty --passphrase '' --quick-gen-key 'Not Amnezia <x@example.invalid>' ed25519 sign never >/dev/null 2>&1
        gpg --batch --no-tty --armor --export 'x@example.invalid' > "$other"
    fi
    [[ -s "$other" ]] && printf '%s\n' "$other"
}

# pin_asc <installer> : writes the embedded block of that installer to a file.
pin_asc() {
    local f
    f="$BATS_TEST_TMPDIR/pin-$(basename "$1" .sh).asc"
    bash -c 'eval "$(awk "/^_amnezia_ppa_key_armored\\(\\) \\{/,/^\\}/" "$1")"; _amnezia_ppa_key_armored' _ "$1" > "$f"
    [[ -s "$f" ]] && printf '%s\n' "$f"
}

fpr_of() {
    gpg --batch --no-tty --show-keys --with-colons "$1" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}'
}

both() {
    local seen=0 src
    for src in install_amneziawg.sh install_amneziawg_en.sh; do
        "$1" "$BATS_TEST_DIRNAME/../$src" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

installs_pinned_key_offline() {
    local src="$1" dest="$BATS_TEST_TMPDIR/keyrings/amnezia-ppa.gpg" out
    rm -f "$dest"; : > "$BATS_TEST_TMPDIR/net_calls"
    out=$(key_run "$src" "$dest")
    [[ "$out" == *"RC=0"* && "$out" != *"DIE:"* ]] || { echo "install failed ($src): $out"; return 1; }
    [[ -s "$dest" ]] || { echo "no keyring written ($src)"; return 1; }
    [[ "$(fpr_of "$dest")" == "$PIN" ]] || { echo "keyring fingerprint is not the pin ($src): $(fpr_of "$dest")"; return 1; }
    [[ "$(stat -c %a "$dest")" == 644 ]] || { echo "keyring mode is not 644 ($src)"; return 1; }
    [[ ! -s "$BATS_TEST_TMPDIR/net_calls" ]] || { echo "network was used ($src): $(cat "$BATS_TEST_TMPDIR/net_calls")"; return 1; }
    [[ -z "$(find "$BATS_TEST_TMPDIR/keyrings" -name '.amnezia-ppa.gpg.tmp.*')" ]] || { echo "temp file left ($src)"; return 1; }
}

@test "PPA key: installed from the embedded block, pinned fingerprint, 644, no network, no temp left" {
    both installs_pinned_key_offline
}

# refused_intact <installer> <output> <what> : the refusal stopped the install
# and left neither the target nor a temp file.
refused_intact() {
    local src="$1" out="$2" what="$3" dest="$BATS_TEST_TMPDIR/keyrings/amnezia-ppa.gpg"
    [[ "$out" == *"DIE:"* ]] || { echo "$what was not refused ($src): $out"; return 1; }
    [[ "$out" != *"RC=0"* ]] || { echo "install went on after refusing $what ($src): $out"; return 1; }
    [[ ! -e "$dest" ]] || { echo "$what reached the target path ($src)"; return 1; }
    [[ -z "$(find "$BATS_TEST_TMPDIR/keyrings" -name '.amnezia-ppa.gpg.tmp.*')" ]] || { echo "temp file left ($src)"; return 1; }
}

# A key block that is not the pinned key (a wrong key pasted in during an
# update, say) is refused before it reaches the target path.
refuses_other_key() {
    local src="$1" dest="$BATS_TEST_TMPDIR/keyrings/amnezia-ppa.gpg" out other
    rm -f "$dest"
    other=$(other_key_asc) || { echo "could not make a test key"; return 1; }
    out=$(key_run "$src" "$dest" "_amnezia_ppa_key_armored() { cat \"$other\"; }")
    refused_intact "$src" "$out" "another key" || return 1
    [[ "$out" == *"$PIN"* ]] || { echo "the refusal does not name the expected fingerprint ($src): $out"; return 1; }
}

@test "PPA key: a block with another key is refused, target untouched" {
    both refuses_other_key
}

# The pinned key followed by a second key: the first fingerprint matches, but
# such a keyring would make apt trust the extra key for the PPA too.
refuses_extra_key() {
    local src="$1" dest="$BATS_TEST_TMPDIR/keyrings/amnezia-ppa.gpg" out other pin
    rm -f "$dest"
    other=$(other_key_asc) || { echo "could not make a test key"; return 1; }
    pin=$(pin_asc "$src") || { echo "no embedded block ($src)"; return 1; }
    out=$(key_run "$src" "$dest" "_amnezia_ppa_key_armored() { cat \"$pin\" \"$other\"; }")
    refused_intact "$src" "$out" "the pinned key plus another one"
}

@test "PPA key: the pinned key followed by another key is refused, target untouched" {
    both refuses_extra_key
}

refuses_garbage() {
    local src="$1" dest="$BATS_TEST_TMPDIR/keyrings/amnezia-ppa.gpg" out
    rm -f "$dest"
    out=$(key_run "$src" "$dest" "_amnezia_ppa_key_armored() { printf 'not a key\n'; }")
    refused_intact "$src" "$out" "a broken block"
}

@test "PPA key: a broken block is refused, target untouched" {
    both refuses_garbage
}

# gpg dearmors the block but cannot list the result: that is not reported as
# a fingerprint mismatch with an empty fingerprint, and gpg's own error shows.
unreadable_keyring_is_named() {
    local src="$1" dest="$BATS_TEST_TMPDIR/keyrings/amnezia-ppa.gpg" out
    rm -f "$dest"
    out=$(key_run "$src" "$dest" 'gpg() { if [[ " $* " == *" --show-keys "* ]]; then echo "gpg: listing failed" >&2; return 2; fi; command gpg "$@"; }' 2>&1)
    refused_intact "$src" "$out" "an unreadable keyring" || return 1
    [[ "$out" == *"gpg: listing failed"* ]] || { echo "gpg's error is hidden ($src): $out"; return 1; }
    [[ "$out" != *"<пусто>"* && "$out" != *"<empty>"* ]] || { echo "reported as an empty fingerprint ($src): $out"; return 1; }
}

@test "PPA key: a keyring gpg cannot list is refused with gpg's error, not as an empty fingerprint" {
    both unreadable_keyring_is_named
}

@test "PPA key: the RU and EN key blocks are identical" {
    local ru en
    ru=$(awk '/^_amnezia_ppa_key_armored\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en=$(awk '/^_amnezia_ppa_key_armored\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [[ -n "$ru" ]]
    [[ "$ru" == "$en" ]]
}

@test "PPA key: no installer fetches a key, step 2 calls the embedded-key installer" {
    local src block
    for src in install_amneziawg.sh install_amneziawg_en.sh; do
        # `! grep` would not fail a bats test unless it is the last command.
        [ "$(grep -cE 'pks/lookup|recv-keys|--keyserver|vks/v1' "$BATS_TEST_DIRNAME/../$src")" -eq 0 ]
        block=$(awk '/^step2_install_amnezia\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../$src")
        # A live call, not a commented-out one.
        grep -qE '^[[:space:]]*install_amnezia_ppa_keyring "\$keyring_file"' <<< "$block"
    done
}
