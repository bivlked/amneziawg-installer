#!/usr/bin/env bats
# Tests for C3 (v5.15.3): strict numeric IP/CIDR validation in `manage modify`.
#
# The old modify_client regexes accepted octets 0-999 and prefixes /33-/99
# (IPv4) or />128 (IPv6), and only charset-checked IPv6 hosts. The shared
# _valid_ipv4 / _valid_ipv6 / _valid_cidr / _valid_host_or_ipv4 helpers in
# awg_common enforce octets 0-255, IPv4 prefix 0-32, IPv6 prefix 0-128 and a
# structural IPv6 shape. A bare address (no prefix) stays valid (host route).

load test_helper

@test "C3 _valid_ipv4: accepts well-formed addresses" {
    for ip in 0.0.0.0 1.2.3.4 192.168.1.1 255.255.255.255 10.0.0.0; do
        run _valid_ipv4 "$ip"
        [ "$status" -eq 0 ] || { echo "rejected valid: $ip"; false; }
    done
}

@test "C3 _valid_ipv4: rejects out-of-range / malformed" {
    for ip in 256.1.1.1 999.999.999.999 1.2.3 1.2.3.4.5 1.2.3. .1.2.3 10.0.0.x ""; do
        run _valid_ipv4 "$ip"
        [ "$status" -ne 0 ] || { echo "accepted invalid: $ip"; false; }
    done
}

@test "C3 _valid_ipv4: leading-zero octet does not crash (no octal trap)" {
    run _valid_ipv4 "08.09.0.1"
    [ "$status" -eq 0 ]   # 10# forces base-10; 8/9 are in range
}

@test "C3 _valid_ipv6: accepts well-formed addresses" {
    for ip in ::1 :: fe80::1 2001:db8::1 fddd:2c4:2c4:2c4:: 2001:db8:0:0:0:0:0:1 abcd:ef01:2345:6789:abcd:ef01:2345:6789; do
        run _valid_ipv6 "$ip"
        [ "$status" -eq 0 ] || { echo "rejected valid: $ip"; false; }
    done
}

@test "C3 _valid_ipv6: rejects malformed" {
    for ip in 2001:::1 12345::1 g::1 1:2:3:4:5:6:7 1:2:3:4:5:6:7:8:9 :1:2:3 ""; do
        run _valid_ipv6 "$ip"
        [ "$status" -ne 0 ] || { echo "accepted invalid: $ip"; false; }
    done
}

@test "C3 _valid_cidr: accepts valid IPv4/IPv6 with and without prefix" {
    for tok in 10.0.0.0/24 1.2.3.4 0.0.0.0/0 192.168.1.1/32 2001:db8::/32 ::/0 fddd:2c4:2c4:2c4::/64 fe80::1; do
        run _valid_cidr "$tok"
        [ "$status" -eq 0 ] || { echo "rejected valid: $tok"; false; }
    done
}

@test "C3 _valid_cidr: rejects bad octets and out-of-range prefixes" {
    for tok in 999.999.999.999 10.0.0.1/33 256.0.0.1/8 ::/129 2001:db8::/200 1.2.3.4/ "" "10.0.0.0/"; do
        run _valid_cidr "$tok"
        [ "$status" -ne 0 ] || { echo "accepted invalid: $tok"; false; }
    done
}

@test "C3 _valid_host_or_ipv4: accepts FQDN and IPv4, rejects bad" {
    for ok in example.com vpn.host.example.org 1.2.3.4 localhost; do
        run _valid_host_or_ipv4 "$ok"
        [ "$status" -eq 0 ] || { echo "rejected valid host: $ok"; false; }
    done
    for bad in 999.1.1.1 -bad.com "bad host" ""; do
        run _valid_host_or_ipv4 "$bad"
        [ "$status" -ne 0 ] || { echo "accepted invalid host: $bad"; false; }
    done
}

# --- source-level: modify_client must use the shared validators ---

@test "C3 RU modify_client uses _valid_cidr / _valid_host_or_ipv4 / _valid_ipv6" {
    run grep -E '_valid_cidr|_valid_host_or_ipv4|_valid_ipv6' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ]
    run grep -E '_valid_cidr "\$_aip_tok"' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ]
}

@test "C3 EN modify_client uses _valid_cidr / _valid_host_or_ipv4 / _valid_ipv6" {
    run grep -E '_valid_cidr|_valid_host_or_ipv4|_valid_ipv6' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ]
    run grep -E '_valid_cidr "\$_aip_tok"' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}

@test "C3 empty AllowedIPs list element is rejected (stray comma), not skipped" {
    # The fix replaced `continue` with an error on empty tokens; assert neither
    # script silently continues on an empty token in the AllowedIPs loop.
    run grep -nE '\[\[ -z "\$_aip_tok" \]\] && continue' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -ne 0 ]
    run grep -nE '\[\[ -z "\$_aip_tok" \]\] && continue' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -ne 0 ]
}

# --- RU/EN validator parity ---

# --- AllowedIPs comma-structure guard (trailing comma is dropped by word-split) ---

# Faithful copy of the comma-structure guard added to modify_client.
allowedips_comma_ok() {
    case "$1" in
        ,*|*,|*,,*) return 1 ;;
    esac
    return 0
}

@test "C3 AllowedIPs: leading/trailing/doubled comma is rejected" {
    for bad in "10.0.0.0/24," ",10.0.0.0/24" "10.0.0.0/24,,10.0.1.0/24" ","; do
        run allowedips_comma_ok "$bad"
        [ "$status" -ne 0 ] || { echo "accepted malformed: $bad"; false; }
    done
}

@test "C3 AllowedIPs: well-formed lists pass the comma guard" {
    for ok in "10.0.0.0/24" "10.0.0.0/24, 10.0.1.0/24" "::/0" "1.2.3.4, ::/0"; do
        run allowedips_comma_ok "$ok"
        [ "$status" -eq 0 ] || { echo "rejected valid: $ok"; false; }
    done
}

@test "C3 source: both manage scripts carry the trailing-comma guard" {
    run grep -E ',\*\|\*,\|\*,,\*' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    [ "$status" -eq 0 ]
    run grep -E ',\*\|\*,\|\*,,\*' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
    [ "$status" -eq 0 ]
}

@test "C3 RU/EN parity: validator definitions present in both awg_common" {
    for fn in _valid_ipv4 _valid_ipv6 _valid_cidr _valid_host_or_ipv4; do
        run grep -E "^${fn}\(\) \{" "$BATS_TEST_DIRNAME/../awg_common.sh"
        [ "$status" -eq 0 ] || { echo "missing $fn in RU"; false; }
        run grep -E "^${fn}\(\) \{" "$BATS_TEST_DIRNAME/../awg_common_en.sh"
        [ "$status" -eq 0 ] || { echo "missing $fn in EN"; false; }
    done
}
