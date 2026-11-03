#!/usr/bin/env bats
# manage qr <name> [--vpn] (issue #375): the client's QR code printed straight
# into the terminal (qrencode -t ansiutf8), for the config (AmneziaWG app) or,
# with --vpn, for the vpn:// link (Amnezia VPN app) - no picture to copy off
# the server. Every scenario runs against both manage twins.

# shellcheck disable=SC2154  # $stderr is set by bats `run --separate-stderr`

bats_require_minimum_version 1.5.0

load test_helper

MANAGERS=(manage_amneziawg.sh manage_amneziawg_en.sh)
require_jq() { command -v jq &>/dev/null || skip "jq not available"; }

setup() {
    T=$(mktemp -d)
    A="$T/awg"
    mkdir -p "$T/bin" "$A/keys"
    cat > "$T/bin/awg" << 'STUB'
#!/bin/bash
exit 0
STUB
    # qrencode stub: records its arguments; -t ASCII prints rows of "##" pairs
    # whose width is QR_MODULES modules, -t ansiutf8 prints a recognisable body
    # that carries the input (so the test sees which file was encoded).
    cat > "$T/bin/qrencode" << 'STUB'
#!/bin/bash
echo "qrencode $*" >> "$T/calls"
[[ -e "$T/qr.fail" ]] && { echo "Failed to encode the input data" >&2; exit 1; }
t="" r=""
while [[ $# -gt 0 ]]; do
    case "$1" in -t) t="$2"; shift ;; -r) r="$2"; shift ;; esac
    shift
done
case "$t" in
    ASCII) [[ -e "$T/ascii.fail" ]] && exit 1; n=${QR_MODULES:-97}; line=$(printf '%*s' $((n * 2)) '' | tr ' ' '#'); for _ in 1 2 3; do echo "$line"; done ;;
    ansiutf8) echo "QRBODY-START"; cat "$r"; echo "QRBODY-END" ;;
    *) exit 3 ;;
esac
STUB
    chmod +x "$T/bin/awg" "$T/bin/qrencode"
    export T PATH="$T/bin:$PATH"
    cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$A/awg_common.sh"
    printf 'export AWG_PORT=39743\nexport AWG_PROTOCOL=3.1\n' > "$A/awgsetup_cfg.init"
    printf '[Interface]\nPrivateKey = TESTKEY\n\n[Peer]\n#_Name = my_phone\nPublicKey = X\nAllowedIPs = 10.9.9.2/32\n' > "$A/awg0.conf"
    echo "CONF-OF-MY-PHONE" > "$A/my_phone.conf"
    echo "vpn://URI-OF-MY-PHONE" > "$A/my_phone.vpnuri"
    export AWG_SKIP_APPLY=1
}

teardown() { rm -rf "$T"; }

_m() { # _m <manage> <args...>
    local m="$1"; shift
    [[ "$m" == *_en.sh ]] && cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$A/awg_common.sh"
    bash "$BATS_TEST_DIRNAME/../$m" "$@" --conf-dir="$A" --server-conf="$A/awg0.conf"
}

@test "qr: prints the config QR built from NAME.conf, exit 0" {
    local m
    for m in "${MANAGERS[@]}"; do
        rm -f "$T/calls"
        run --separate-stderr _m "$m" qr my_phone
        [ "$status" -eq 0 ] || { echo "$m: $status $output $stderr"; return 1; }
        [[ "$output" == *$'QRBODY-START\nCONF-OF-MY-PHONE\nQRBODY-END'* ]] || { echo "$m: $output"; return 1; }
        grep -qxF "qrencode -t ansiutf8 -r $A/my_phone.conf" "$T/calls" || { echo "$m: $(cat "$T/calls")"; return 1; }
        # the private key warning goes with it
        [[ "$stderr" == *"clear"* ]] || { echo "$m: $stderr"; return 1; }
    done
}

@test "qr --vpn: prints the vpn:// QR from NAME.vpnuri in 8-bit mode" {
    local m
    for m in "${MANAGERS[@]}"; do
        rm -f "$T/calls"
        run --separate-stderr _m "$m" qr my_phone --vpn
        [ "$status" -eq 0 ] || { echo "$m: $status $output $stderr"; return 1; }
        [[ "$output" == *$'QRBODY-START\nvpn://URI-OF-MY-PHONE\nQRBODY-END'* ]] || { echo "$m: $output"; return 1; }
        grep -qxF "qrencode -t ansiutf8 -8 -r $A/my_phone.vpnuri" "$T/calls" || { echo "$m: $(cat "$T/calls")"; return 1; }
    done
}

@test "qr: unknown client, no name, two names, a bad name: exit 1, the reason, no QR" {
    local m a want
    # A name the validator refuses is written into awg0.conf too, so only the
    # validator can stop it.
    printf '[Peer]\n#_Name = ../etc\n' >> "$A/awg0.conf"
    for m in "${MANAGERS[@]}"; do
        for a in "qr nobody|не найден|not found" "qr|Не указано имя|No client name" \
                 "qr my_phone other|одно имя|one client name" "qr ../etc|недоп. символы|invalid characters"; do
            IFS='|' read -r a want want_en <<<"$a"
            [[ "$m" == *_en.sh ]] && want="$want_en"
            rm -f "$T/calls"
            # shellcheck disable=SC2086
            run --separate-stderr _m "$m" $a
            [ "$status" -eq 1 ] || { echo "$m [$a]: $status $output"; return 1; }
            [[ "$stderr" == *"$want"* ]] || { echo "$m [$a]: $stderr"; return 1; }
            [[ "$output" != *QRBODY* ]] || { echo "$m [$a]: printed"; return 1; }
            [ ! -e "$T/calls" ] || { echo "$m [$a]: qrencode ran"; return 1; }
        done
        # the bad name is stopped by the validator, not by the client lookup
        run --separate-stderr _m "$m" qr ../etc
        [[ "$stderr" != *"не найден"* && "$stderr" != *"not found"* ]] || { echo "$m: $stderr"; return 1; }
    done
}

@test "qr: --vpn before the name works too; --vpn with another command is refused" {
    local m
    for m in "${MANAGERS[@]}"; do
        rm -f "$T/calls"
        run --separate-stderr _m "$m" qr --vpn my_phone
        [ "$status" -eq 0 ] && [[ "$output" == *"vpn://URI-OF-MY-PHONE"* ]] || { echo "$m: $status $output"; return 1; }
        run --separate-stderr _m "$m" list --vpn
        [ "$status" -eq 1 ] && [[ "$stderr" == *"--vpn"*"qr"* ]] || { echo "$m list: $status $stderr"; return 1; }
        # an explicit help request still gets the help
        run --separate-stderr _m "$m" --vpn -h
        [ "$status" -eq 0 ] && [[ "$output" == *"qr <"* ]] || { echo "$m help: $status $output $stderr"; return 1; }
    done
}

@test "qr under bash -x: the QR does not reach the trace" {
    local m
    for m in "${MANAGERS[@]}"; do
        [[ "$m" == *_en.sh ]] && cp "$BATS_TEST_DIRNAME/../awg_common_en.sh" "$A/awg_common.sh"
        run --separate-stderr bash -x "$BATS_TEST_DIRNAME/../$m" qr my_phone --conf-dir="$A" --server-conf="$A/awg0.conf"
        [ "$status" -eq 0 ] && [[ "$output" == *CONF-OF-MY-PHONE* ]] || { echo "$m: $status $output"; return 1; }
        # the trace reached the function itself, so the check proves something
        [[ "$stderr" == *"_awg_xtrace_guard show_client_qr"* ]] || { echo "$m: the trace never reached show_client_qr"; return 1; }
        [[ "$stderr" != *CONF-OF-MY-PHONE* ]] || { echo "$m: the QR is in the trace"; return 1; }
    done
}

@test "qr: a missing file names regen; a missing .vpnuri does not fall back to the config" {
    local m
    for m in "${MANAGERS[@]}"; do
        rm -f "$T/calls" "$A/my_phone.vpnuri"
        run --separate-stderr _m "$m" qr my_phone --vpn
        [ "$status" -eq 1 ] || { echo "$m: $status"; return 1; }
        [[ "$stderr" == *"regen my_phone"* ]] || { echo "$m: $stderr"; return 1; }
        [[ "$output" != *QRBODY* ]]
        echo "vpn://URI-OF-MY-PHONE" > "$A/my_phone.vpnuri"
    done
}

@test "qr: a failed qrencode is exit 1 with the reason, nothing half printed" {
    local m
    for m in "${MANAGERS[@]}"; do
        touch "$T/qr.fail"
        run --separate-stderr _m "$m" qr my_phone
        [ "$status" -eq 1 ] && [[ "$output" != *QRBODY* ]] || { echo "$m fail: $status $output"; return 1; }
        [[ "$stderr" == *"qrencode"* ]] || { echo "$m fail: $stderr"; return 1; }
        rm -f "$T/qr.fail"
    done
}

@test "qr --json: refused with a JSON error, no QR on stdout" {
    local m
    require_jq
    for m in "${MANAGERS[@]}"; do
        run --separate-stderr _m "$m" qr my_phone --json
        [ "$status" -eq 1 ] || { echo "$m: $status $output"; return 1; }
        printf '%s' "$output" | jq -e '.ok == false and .command == "qr" and (.error | test("--json"))' >/dev/null || { echo "$m: $output"; return 1; }
    done
}

@test "qr is in the help of both scripts" {
    grep -qF 'echo "  qr <имя> [--vpn]' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qF 'echo "  qr <name> [--vpn]' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

# ---------- window size: show_client_qr with the terminal size stubbed ----------

_fn() { sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"; }
_size_driver() { # manage, "rows cols" or empty (no terminal)
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*" >&2; }; log_error() { echo "ERR: $*" >&2; }'
        echo "AWG_DIR=$A; SERVER_CONF_FILE=$A/awg0.conf; JSON_OUTPUT=0"
        echo "_qr_term_size() { [[ -n \"$2\" ]] && echo \"$2\"; }"
        _fn "$1" validate_client_name
        _fn "$1" show_client_qr
        echo 'show_client_qr my_phone 0'
    } > "$T/size.sh"
}

@test "qr: warns when the code is wider or taller than the window, and still prints it" {
    local m
    for m in "${MANAGERS[@]}"; do
        # 97 modules: 97 columns, 49 rows
        _size_driver "$m" "40 80"
        QR_MODULES=97 run --separate-stderr bash "$T/size.sh"
        [ "$status" -eq 0 ] || { echo "$m: $status $stderr"; return 1; }
        [[ "$stderr" == *"WARN: "*"97"*"49"*"80"*"40"* ]] || { echo "$m narrow: $stderr"; return 1; }
        [[ "$output" == *QRBODY-START* ]]
        # wider only
        _size_driver "$m" "60 80"
        QR_MODULES=97 run --separate-stderr bash "$T/size.sh"
        [[ "$stderr" == *"WARN: "*"97"*"49"*"80"*"60"* ]] || { echo "$m wide: $stderr"; return 1; }
        # taller only
        _size_driver "$m" "40 200"
        QR_MODULES=97 run --separate-stderr bash "$T/size.sh"
        [[ "$stderr" == *"WARN: "*"97"*"49"* ]] || { echo "$m short: $stderr"; return 1; }
    done
}

@test "qr: without qrencode exit 1 names the package (a PATH that holds only grep)" {
    local m
    mkdir -p "$T/only"; ln -sf "$(command -v grep)" "$T/only/grep"
    for m in "${MANAGERS[@]}"; do
        _size_driver "$m" ""
        run --separate-stderr env PATH="$T/only" "$BASH" "$T/size.sh"
        [ "$status" -eq 1 ] || { echo "$m: $status $output $stderr"; return 1; }
        [[ "$stderr" == *"ERR: "*"apt install qrencode"* ]] || { echo "$m: $stderr"; return 1; }
        [[ "$output" != *QRBODY* ]]
    done
}

@test "qr: no size warning when the code fits, or when there is no terminal to measure" {
    local m s
    for m in "${MANAGERS[@]}"; do
        # "49 97" is exactly the size of a 97-module code; "0 0" is a hosting console
        for s in "60 120" "49 97" "" "0 0" "0 80" "40 0"; do
            _size_driver "$m" "$s"
            QR_MODULES=97 run --separate-stderr bash "$T/size.sh"
            [ "$status" -eq 0 ] && [[ "$stderr" != *"97"* ]] || { echo "$m [$s]: $stderr"; return 1; }
            [[ "$output" == *QRBODY-START* ]]
        done
    done
}

@test "_qr_term_size without a controlling terminal: empty answer, nothing on stderr" {
    local m
    command -v setsid >/dev/null || skip "setsid not available"
    for m in "${MANAGERS[@]}"; do
        # setsid drops the controlling terminal, so opening /dev/tty fails (as
        # from cron or a pipe on the server). The real function, not a stub.
        run --separate-stderr setsid -w bash -c "$(_fn "$m" _qr_term_size); _qr_term_size; echo RC=\$?"
        [ "$output" = "RC=0" ] || { echo "$m: [$output]"; return 1; }
        [ -z "$stderr" ] || { echo "$m: stderr [$stderr]"; return 1; }
    done
}

@test "qr: one row or one column short of the code is a warning" {
    local m s
    for m in "${MANAGERS[@]}"; do
        for s in "48 97" "49 96"; do
            _size_driver "$m" "$s"
            QR_MODULES=97 run --separate-stderr bash "$T/size.sh"
            [[ "$stderr" == *"WARN: "*"97"*"49"* ]] || { echo "$m [$s]: $stderr"; return 1; }
        done
    done
}

@test "qr: a failed measurement (qrencode -t ASCII) skips the size check and still prints" {
    local m
    for m in "${MANAGERS[@]}"; do
        touch "$T/ascii.fail"; _size_driver "$m" "10 10"
        run --separate-stderr bash "$T/size.sh"
        [ "$status" -eq 0 ] && [[ "$output" == *QRBODY-START* ]] || { echo "$m: $status $output"; return 1; }
        [[ "$stderr" != *"10"* ]] || { echo "$m: $stderr"; return 1; }
        rm -f "$T/ascii.fail"
    done
}
