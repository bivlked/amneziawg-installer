#!/usr/bin/env bats
# Code-review findings A5/B3 (DNS) and B4 (public IP octet range).
#
# A5/B3: `manage modify <client> DNS <value>` used a charset-only regex
#   ^[0-9a-fA-F.:,\ ]+$ that accepted non-addresses ('abc' is all a-f letters,
#   '999.999.999.999' is out of range). DNS is IP-only by contract, so each
#   comma-separated element must now pass _valid_ipv4 or _valid_ipv6.
# B4: get_server_public_ip() / _try_local_ip() accepted any N.N.N.N without an
#   octet-range check; they now reuse _valid_ipv4 (already in awg_common).

load test_helper

# Faithful copy of the per-element DNS validation added to modify_client.
dns_list_ok() {
    local value="$1"
    case "$value" in
        *$'\n'*|*$'\r'*|*\\*|*\"*|*\'*|"") return 1 ;;
    esac
    case "$value" in
        ,*|*,|*,,*) return 1 ;;
    esac
    local tok ifs="$IFS"
    IFS=','
    for tok in $value; do
        tok="${tok//[[:space:]]/}"
        if [[ -z "$tok" ]]; then IFS="$ifs"; return 1; fi
        if ! _valid_ipv4 "$tok" && ! _valid_ipv6 "$tok"; then IFS="$ifs"; return 1; fi
    done
    IFS="$ifs"
    return 0
}

@test "A5 DNS: well-formed IPv4/IPv6 lists pass" {
    for ok in "1.1.1.1" "8.8.8.8, 1.0.0.1" "2606:4700:4700::1111" "1.1.1.1, 2606:4700:4700::1001"; do
        run dns_list_ok "$ok"
        [ "$status" -eq 0 ] || { echo "rejected valid DNS: $ok"; false; }
    done
}

@test "A5 DNS: garbage that passed the old charset regex is now rejected" {
    for bad in "abc" "999.999.999.999" "1.2.3" "10.0.0.x" "1.1.1.1,," ",1.1.1.1" "1.1.1.1," ""; do
        run dns_list_ok "$bad"
        [ "$status" -ne 0 ] || { echo "accepted invalid DNS: $bad"; false; }
    done
}

@test "A5 source: both manage scripts validate DNS via _valid_ipv4/_valid_ipv6 (not charset-only)" {
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        # The old charset-only DNS regex must no longer be used in an active match
        # (a literal inside an explanatory comment is fine).
        run grep -E '=~ \^\[0-9a-fA-F' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still uses charset-only DNS regex"; false; }
        # The DNS branch must reference the structural validators.
        run grep -E '_valid_ipv4 "\$_dns_tok"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f DNS branch missing _valid_ipv4"; false; }
    done
}

@test "B4 source: public-IP detection uses _valid_ipv4 (no loose N.N.N.N regex)" {
    for f in awg_common.sh awg_common_en.sh; do
        # Loose four-octet regex must no longer gate detected IPs.
        run grep -F '=~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -ne 0 ] || { echo "$f still has loose public-IP regex"; false; }
        run grep -E '_valid_ipv4 "\$ip"' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ] || { echo "$f public-IP path missing _valid_ipv4"; false; }
    done
}

@test "B4 behavior: _valid_ipv4 rejects the out-of-range IP the old regex accepted" {
    run _valid_ipv4 "999.999.999.999"
    [ "$status" -ne 0 ]
    run _valid_ipv4 "203.0.113.7"
    [ "$status" -eq 0 ]
}
