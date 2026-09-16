#!/usr/bin/env bats
# First install of a 3.1 server: the two checks that run BEFORE anything changes.
#
# A 3.1 profile is only usable as a complete set - config, QR code, vpn:// link
# and its QR code - and the link needs perl with Compress::Zlib and MIME::Base64,
# while both QR codes need qrencode. On 2.0 a missing tool costs a convenience;
# on 3.1 the link is the usual way to import the profile into the application,
# and a half-set is not usable. So the tools are checked first, and the
# installation stops with the missing one named instead of failing halfway.
#
# The second check is about leftovers: generate_client refuses a client whose
# keys or .conf exist, and on 3.1 that refusal would come after the server config
# was rewritten. Old QR and link files count too: the set check would take them
# for new ones. On 3.1 all of it is caught before the first change.
#
# On 2.0 both checks do nothing at all: that path is not touched by this work.

# lib_run <lib> <generation> <bin setup> <snippet>
lib_run() {
    local lib="$1" gen="$2" binsetup="$3" snippet="$4" d
    d="$BATS_TEST_TMPDIR/f-$(basename "$lib" .sh)"
    rm -rf "$d"; mkdir -p "$d/keys" "$d/bin"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\n"
        printf "export AWG_PROTOCOL='%s'\n" "$gen"
    } > "$d/awgsetup_cfg.init"
    eval "$binsetup"
    AWG_DIR="$d" AWG_BIN="$d/bin" timeout 60 bash -c '
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        # An isolated PATH is the only way to model "the tool is not installed":
        # with /usr/bin on the path the real perl answers and the case passes
        # while testing nothing. The stub directory then carries links to the
        # handful of utilities the library itself needs.
        if [[ -e "$AWG_BIN/.isolated" ]]; then
            export PATH="$AWG_BIN"
        else
            export PATH="$AWG_BIN:/usr/bin:/bin"
        fi
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        eval "$2"
    ' _ "$BATS_TEST_DIRNAME/../$lib" "$snippet"
}

dir_of() { echo "$BATS_TEST_TMPDIR/f-$(basename "$1" .sh)"; }

# Stubs: a working qrencode and a perl that has the modules; variants below
# remove one of them at a time.
stub_all() {
    local d; d=$(dir_of "$1")
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/qrencode"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/perl"
    chmod +x "$d/bin/qrencode" "$d/bin/perl"
}
stub_no_qrencode() {
    local d; d=$(dir_of "$1")
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/perl"
    chmod +x "$d/bin/perl"
}
stub_no_perl() {
    local d u; d=$(dir_of "$1")
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/qrencode"
    chmod +x "$d/bin/qrencode"
    # No perl anywhere on the path, but the library still needs its own tools.
    : > "$d/bin/.isolated"
    for u in grep sed awk cat mktemp rm find head tr; do
        [ -x "/usr/bin/$u" ] && ln -sf "/usr/bin/$u" "$d/bin/$u"
        [ -x "/bin/$u" ] && [ ! -e "$d/bin/$u" ] && ln -sf "/bin/$u" "$d/bin/$u"
    done
}
stub_perl_without_modules() {
    local d; d=$(dir_of "$1")
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/qrencode"
    # Fails exactly the way a perl without the modules does: the -M load fails.
    printf '#!/usr/bin/env bash\ncase "$*" in *Compress::Zlib*|*MIME::Base64*) exit 2 ;; esac\nexit 0\n' > "$d/bin/perl"
    chmod +x "$d/bin/qrencode" "$d/bin/perl"
}

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# ---------- tools ----------

t_31_all_present() {
    local lib="$1" out
    out=$(lib_run "$lib" 3.1 "stub_all $lib" '_awg31_require_client_tools; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "a complete toolset was refused ($lib): $out"; return 1; }
}
@test "first install 3.1: with every tool present the check passes, both twins" {
    both t_31_all_present
}

t_31_missing() {
    local lib="$1" out setup want
    for setup in stub_no_qrencode stub_no_perl stub_perl_without_modules; do
        out=$(lib_run "$lib" 3.1 "$setup $lib" '_awg31_require_client_tools; echo "RC=$?"')
        [[ "$out" == *"RC=0"* ]] && { echo "$setup was accepted ($lib): $out"; return 1; }
        [[ "$out" == *"ERR:"* ]] || { echo "$setup refused without a reason ($lib): $out"; return 1; }
        # The phrase has to be unique to ONE message. Plain "perl" is not: the
        # message about the modules contains it too, so a library that dropped
        # the perl check would still pass this case while pointing the person at
        # the wrong thing.
        want="qrencode"
        if [[ "$setup" == stub_no_perl ]]; then
            want="нужен perl"
            [[ "$lib" == *_en.sh ]] && want="needs perl"
        fi
        [[ "$setup" == stub_perl_without_modules ]] && want="Compress::Zlib"
        [[ "$out" == *"$want"* ]] || { echo "$setup: the reason does not name $want ($lib): $out"; return 1; }
    done
}
@test "first install 3.1: a missing tool stops the install and is named, both twins" {
    both t_31_missing
}

t_20_untouched() {
    local lib="$1" out
    out=$(lib_run "$lib" 2.0 "stub_no_perl $lib" '_awg31_require_client_tools; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "a 2.0 install was stopped by the 3.1 tool check ($lib): $out"; return 1; }
}
@test "first install 2.0: the tool check does nothing, both twins" {
    both t_20_untouched
}

# ---------- leftovers ----------

t_clean() {
    local lib="$1" out
    out=$(lib_run "$lib" 3.1 "stub_all $lib" '_awg31_refuse_client_leftovers my_phone my_laptop; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "a clean directory was refused ($lib): $out"; return 1; }
}
@test "first install 3.1: a clean directory passes the leftovers check, both twins" {
    both t_clean
}

t_leftovers() {
    local lib="$1" out f
    local who
    for f in my_phone.conf my_phone.png my_phone.vpnuri my_phone.vpnuri.png keys/my_phone.private keys/my_phone.public my_laptop.conf; do
        out=$(lib_run "$lib" 3.1 "stub_all $lib" "
            mkdir -p \"\$AWG_DIR/keys\"
            printf 'x\\n' > \"\$AWG_DIR/$f\"
            _awg31_refuse_client_leftovers my_phone my_laptop; echo \"RC=\$?\"")
        [[ "$out" == *"RC=0"* ]] && { echo "a leftover $f was accepted ($lib): $out"; return 1; }
        [[ "$out" == *"ERR:"* ]] || { echo "a leftover $f refused without a reason ($lib): $out"; return 1; }
        # The second name has to be checked too, and named as itself.
        who=my_phone
        [[ "$f" == my_laptop.* ]] && who=my_laptop
        [[ "$out" == *"'$who'"* ]] || { echo "the reason does not name $who ($lib): $out"; return 1; }
    done
    # A dangling link is a leftover as well: -e alone does not see it.
    out=$(lib_run "$lib" 3.1 "stub_all $lib" '
        ln -s "$AWG_DIR/nowhere" "$AWG_DIR/my_phone.png"
        _awg31_refuse_client_leftovers my_phone my_laptop; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] && { echo "a dangling link was accepted ($lib): $out"; return 1; }
    [[ "$out" == *"ERR:"*"'my_phone'"* ]] || { echo "a dangling link refused without naming the client ($lib): $out"; return 1; }
    return 0
}
@test "first install 3.1: any leftover file of a default client stops the install, both twins" {
    both t_leftovers
}

t_leftovers_20() {
    local lib="$1" out
    out=$(lib_run "$lib" 2.0 "stub_all $lib" '
        printf "x\n" > "$AWG_DIR/my_phone.conf"
        _awg31_refuse_client_leftovers my_phone my_laptop; echo "RC=$?"')
    [[ "$out" == *"RC=0"* ]] || { echo "a 2.0 install was stopped by the leftovers check ($lib): $out"; return 1; }
}
@test "first install 2.0: the leftovers check does nothing, both twins" {
    both t_leftovers_20
}
