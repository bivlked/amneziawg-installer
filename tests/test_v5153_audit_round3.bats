#!/usr/bin/env bats
# v5.15.3 round-3 audit fixes: install inline validators + arg/flow hardening.
#
# install_amneziawg.sh keeps its OWN inline validators because they must run at
# step 0, before awg_common.sh is downloaded. Those copies were weaker than the
# canonical _valid_* in awg_common.sh. This file pins the hardening.
#
# .1 validators:
#    - validate_port: reject leading-zero/octal ('0080'), enforce 1024-65535
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
    for bad in 0080 080 80 0 23 65536 99999 abc ""; do
        run validate_port "$bad"
        [ "$status" -ne 0 ] || { echo "accepted invalid port: $bad"; false; }
    done
}

@test ".1 validate_port: accepts valid high ports" {
    for ok in 1024 51820 65535; do
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
