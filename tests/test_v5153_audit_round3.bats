#!/usr/bin/env bats
# v5.15.3 round-3 audit fixes: install inline validators + arg/flow hardening.
#
# install_amneziawg.sh keeps its OWN inline validators because they must run at
# step 0, before awg_common.sh is downloaded. Those copies were weaker than the
# canonical _valid_* in awg_common.sh. This file pins the hardening.
#
# .1 validators:
#    - validate_port: reject leading-zero/octal ('0080'), enforce 1-65535
#      (low ports like 443/80/53 allowed since v5.18.1 for DPI evasion)
#    - validate_subnet / validate_cidr_list: decimal octets, reject leading zeros
#    - validate_endpoint: structural [IPv6] check instead of charset-only
#    - validate_cidr_list: reject leading/trailing/double comma before split
#
# install_amneziawg.sh is not sourceable (runs top-to-bottom), so the four
# contiguous validators are extracted and evaluated with die/log stubs. Under
# bats `run` the function executes in a command-substitution subshell, so a
# die() that exits maps cleanly to a non-zero $status.

ROOT="$BATS_TEST_DIRNAME/.."

setup() {
    die()       { echo "DIE: $*"; exit 1; }
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    eval "$(awk '/^validate_port\(\) \{/{f=1} f{print} /^configure_routing_mode\(\) \{/{exit}' \
        "$ROOT/install_amneziawg.sh" | sed '/^configure_routing_mode/d')"
}

# ---------- .1 validate_port ----------

@test ".1 validate_port: rejects leading-zero/octal and out-of-range" {
    # v5.18.1: low ports (1-1023) are now allowed; only zero, leading-zero/octal,
    # over-max and non-numeric stay rejected.
    for bad in 0080 080 0 65536 99999 abc ""; do
        run validate_port "$bad"
        [ "$status" -ne 0 ] || { echo "accepted invalid port: $bad"; false; }
    done
}

@test ".1 validate_port: accepts valid ports incl. low DPI-evasion ports (v5.18.1)" {
    for ok in 1 53 80 443 1024 51820 65535; do
        run validate_port "$ok"
        [ "$status" -eq 0 ] || { echo "rejected valid port: $ok"; false; }
    done
}

# ---------- .1 validate_subnet ----------

@test ".1 validate_subnet: rejects octal/leading-zero, out-of-range, wrong last octet" {
    for bad in 010.008.009.001/24 300.0.0.1/24 256.0.0.1/24 10.0.0.0/24 10.0.0.255/24 10.0.0.2/24 10.0.0.1/16; do
        run validate_subnet "$bad"
        [ "$status" -ne 0 ] || { echo "accepted invalid subnet: $bad"; false; }
    done
}

@test ".1 validate_subnet: accepts canonical /24 with last octet 1" {
    for ok in 10.0.0.1/24 192.168.1.1/24; do
        run validate_subnet "$ok"
        [ "$status" -eq 0 ] || { echo "rejected valid subnet: $ok"; false; }
    done
}

# ---------- .1 validate_endpoint ----------

@test ".1 validate_endpoint: rejects malformed [IPv6] that charset-only would pass" {
    for bad in '[:::]' '[::::]' '[1:2:3]' '[gggg::]' '[]'; do
        run validate_endpoint "$bad"
        [ "$status" -ne 0 ] || { echo "accepted invalid endpoint: $bad"; false; }
    done
}

@test ".1 validate_endpoint: accepts valid [IPv6], FQDN, IPv4" {
    for ok in '[2001:db8::1]' '[::1]' '[fd00::1]' vpn.example.com 1.2.3.4; do
        run validate_endpoint "$ok"
        [ "$status" -eq 0 ] || { echo "rejected valid endpoint: $ok"; false; }
    done
}

@test ".1 validate_endpoint: still blocks injection characters" {
    run validate_endpoint '1.2.3.4 ; rm -rf'
    [ "$status" -ne 0 ]
}

# ---------- .1 validate_cidr_list ----------

@test ".1 validate_cidr_list: rejects comma-structure and leading-zero/out-of-range" {
    for bad in '10.0.0.0/24,' ',10.0.0.0/24' '10.0.0.0/24,,11.0.0.0/8' '010.0.0.0/24' '10.0.0.0/33' '256.0.0.0/8' ''; do
        run validate_cidr_list "$bad"
        [ "$status" -ne 0 ] || { echo "accepted invalid cidr list: $bad"; false; }
    done
}

@test ".1 validate_cidr_list: accepts well-formed lists including spaces after commas" {
    for ok in '10.0.0.0/24' '10.0.0.0/24,11.0.0.0/8' '0.0.0.0/0' '10.0.0.0/24, 11.0.0.0/8'; do
        run validate_cidr_list "$ok"
        [ "$status" -eq 0 ] || { echo "rejected valid cidr list: $ok"; false; }
    done
}

@test ".1 validate_port: rejects overlong values that wrap 64-bit arithmetic" {
    run validate_port 123456
    [ "$status" -ne 0 ]
    # 2^64 + 51820: without a length bound (( )) wraps and the range check passes.
    run validate_port 18446744073709603436
    [ "$status" -ne 0 ]
}

@test ".1 validate_cidr_list: rejects embedded newline (config injection)" {
    # read <<< only sees the first line; the rest would land in the config unchecked.
    run validate_cidr_list $'10.0.0.0/24\nmalicious'
    [ "$status" -ne 0 ]
    run validate_cidr_list $'\n10.0.0.0/24'
    [ "$status" -ne 0 ]
}

# ---------- .1 RU/EN parity (source-level) ----------

@test ".1 RU/EN parity: anti-leading-zero octet pattern present in both installers" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F '(0|[1-9][0-9]{0,2})' "$ROOT/$f"
        [ "$status" -eq 0 ] || { echo "missing strict octet pattern in $f"; false; }
    done
}

@test ".1 RU/EN parity: structural [IPv6] check present in both installers" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F 'has_dcolon' "$ROOT/$f"
        [ "$status" -eq 0 ] || { echo "missing structural IPv6 check in $f"; false; }
    done
}

@test ".1 RU/EN parity: cidr comma-structure guard present in both installers" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -E ',\*\|\*,\|\*,,\*' "$ROOT/$f"
        [ "$status" -eq 0 ] || { echo "missing comma guard in $f"; false; }
    done
}

# ---------- .2 --route-custom first-run validation guard ----------
# A first run with --route-custom assigned ALLOWED_IPS straight from the CLI and
# never validated it (configure_routing_mode was skipped because the mode was
# already 3). A single mandatory guard now validates any non-empty ALLOWED_IPS
# before the config is written, regardless of source.

@test ".2 universal ALLOWED_IPS validation guard present in both installers" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F '[[ -n "$ALLOWED_IPS" ]] && ! validate_cidr_list "$ALLOWED_IPS"' "$ROOT/$f"
        [ "$status" -eq 0 ] || { echo "missing universal ALLOWED_IPS guard in $f"; false; }
    done
}

@test ".2 guard runs after the CLI override and before the config save (both)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        local override guard save
        override=$(grep -n 'CLI_ROUTING_MODE" -eq 3 \]\]; then ALLOWED_IPS=\$CLI_CUSTOM_ROUTES' "$ROOT/$f" | head -1 | cut -d: -f1)
        guard=$(grep -nF '[[ -n "$ALLOWED_IPS" ]] && ! validate_cidr_list "$ALLOWED_IPS"' "$ROOT/$f" | head -1 | cut -d: -f1)
        save=$(grep -n "^export ALLOWED_IPS='" "$ROOT/$f" | head -1 | cut -d: -f1)
        [ -n "$override" ] && [ -n "$guard" ] && [ -n "$save" ] || { echo "anchor missing in $f"; false; }
        [ "$guard" -gt "$override" ] || { echo "guard before override in $f"; false; }
        [ "$guard" -lt "$save" ] || { echo "guard after save in $f"; false; }
    done
}

# ---------- .3 unknown-argument exit code ----------
# An unknown argument used to print help and exit 0 (false success in CI/Ansible
# when a flag is mistyped). show_help now exits with HELP_EXIT_RC: 0 for an
# explicit --help, 1 for an unknown argument. Mirrors manage's HELP_EXIT_RC.

@test ".3 explicit --help / -h exit 0 (both installers)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run timeout 20 bash "$ROOT/$f" --help
        [ "$status" -eq 0 ] || { echo "$f --help rc=$status"; false; }
        run timeout 20 bash "$ROOT/$f" -h
        [ "$status" -eq 0 ] || { echo "$f -h rc=$status"; false; }
    done
}

@test ".3 unknown argument exits non-zero (both installers)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run timeout 20 bash "$ROOT/$f" --bogus-flag
        [ "$status" -ne 0 ] || { echo "$f --bogus-flag rc=$status (should be non-zero)"; false; }
    done
}

@test ".3 unknown-arg sets HELP_EXIT_RC=1 and writes to stderr (both installers)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -E '\*\) echo "(Неизвестный аргумент|Unknown argument): \$1" >&2; HELP=1; HELP_EXIT_RC=1' "$ROOT/$f"
        [ "$status" -eq 0 ] || { echo "missing stderr + rc=1 unknown-arg handler in $f"; false; }
    done
}

@test ".3 show_help honors HELP_EXIT_RC (both installers)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -F 'exit "${HELP_EXIT_RC:-0}"' "$ROOT/$f"
        [ "$status" -eq 0 ] || { echo "show_help does not honor HELP_EXIT_RC in $f"; false; }
    done
}
