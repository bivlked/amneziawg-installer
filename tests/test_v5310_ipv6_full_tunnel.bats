#!/usr/bin/env bats
# v5.31.0 - the default install stopped leaking IPv6.
#
# Three forks in awg_common.sh decided "is this a full tunnel?" by comparing the
# AllowedIPs string with the literal 0.0.0.0/0. Routing mode 2 - the INSTALL
# DEFAULT - is a 34-entry list (all public IPv4 minus the private ranges); it is
# written as a list only to dodge the iOS bug on 0.0.0.0/5 (issue #42), so by
# meaning it is a full tunnel, but the string never matched. Result: the default
# client config carried no ::/0, the device's IPv6 went around the tunnel with
# its real address, and because the third fork sits on the regen path, telling
# the user to re-issue the profile did not help either.
#
# The forks now ask _is_full_tunnel, which answers by the COVERAGE of the route
# set: mode 1 and mode 2 are full tunnels, a real split (mode 3) is not.
#
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

# The real default list, read out of the installer rather than copied here: a
# copy would keep passing after someone edits the installer and breaks the
# property. Both language variants must carry the same list.
mode2_list() {
    local script="${1:-install_amneziawg.sh}"
    sed -n 's/^[[:space:]]*ALLOWED_IPS="\(1\.0\.0\.0\/8,.*\)"$/\1/p' \
        "${BATS_TEST_DIRNAME}/../${script}" | head -1
}

# --- the predicate itself ---

@test "v5.31.0 predicate: the installer still ships the mode-2 list we test against" {
    local ru en
    ru=$(mode2_list install_amneziawg.sh)
    en=$(mode2_list install_amneziawg_en.sh)
    # Guard against a silently empty fixture: an empty list would make every
    # test below pass while testing nothing.
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
    [[ "$ru" == *"208.0.0.0/4"* ]]
}

@test "v5.31.0 predicate: mode 1 (0.0.0.0/0) is a full tunnel" {
    _is_full_tunnel "0.0.0.0/0"
}

@test "v5.31.0 predicate: mode 2 (the default list) is a full tunnel" {
    _is_full_tunnel "$(mode2_list)"
}

@test "v5.31.0 predicate: mode 2 plus the tunnel subnet is still a full tunnel" {
    # Client isolation off (issue #178) appends the tunnel network to the list.
    _is_full_tunnel "$(mode2_list), 10.9.9.0/24"
}

@test "v5.31.0 predicate: two halves cover everything and count as a full tunnel" {
    _is_full_tunnel "0.0.0.0/1, 128.0.0.0/1"
}

@test "v5.31.0 predicate: overlapping and duplicate ranges do not confuse the sweep" {
    _is_full_tunnel "0.0.0.0/0, 0.0.0.0/0, 10.0.0.0/8, 0.0.0.0/1"
}

@test "v5.31.0 predicate: a LAN-only split is not a full tunnel" {
    run _is_full_tunnel "10.0.0.0/8, 192.168.0.0/16"
    [ "$status" -ne 0 ]
}

@test "v5.31.0 predicate: the truncated list used by other tests is not a full tunnel" {
    run _is_full_tunnel "0.0.0.0/5, 8.0.0.0/7"
    [ "$status" -ne 0 ]
}

@test "v5.31.0 predicate: everything except one public /8 is not a full tunnel" {
    # 5.0.0.0/8 is missing - one public hole is enough to keep IPv6 alone.
    run _is_full_tunnel "1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/8, 6.0.0.0/7, 8.0.0.0/5, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/1"
    [ "$status" -ne 0 ]
}

@test "v5.31.0 predicate: an IPv6-only list is not a full IPv4 tunnel" {
    run _is_full_tunnel "::/0"
    [ "$status" -ne 0 ]
}

@test "v5.31.0 predicate: an IPv6 token does not disturb the answer about IPv4" {
    # A dual-stack list must be judged by its IPv4 part alone. Feeding the IPv6
    # token into the IPv4 parser would turn a full tunnel into "unparseable".
    _is_full_tunnel "0.0.0.0/0, ::/0"
    _is_full_tunnel "0.0.0.0/0, fddd:2c4:2c4:2c4::/64"
    run _is_full_tunnel "10.0.0.0/8, ::/0"
    [ "$status" -ne 0 ]
}

@test "v5.31.0 predicate: an empty list is not a full tunnel" {
    run _is_full_tunnel ""
    [ "$status" -ne 0 ]
}

@test "v5.31.0 predicate: an unparseable route is refused LOUDLY, not silently" {
    # "could not tell" must not read as "checked and it is a split": the user
    # gets a warning naming the token.
    local out rc
    log_warn() { echo "WARN: $*"; }
    # `cmd || rc=$?` and not `! cmd`: in bats a `!` exempts the command from
    # errexit altogether, which would hide a later failure in this same test.
    out=$(_is_full_tunnel "0.0.0.0/0, garbage" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *"garbage"* ]]
}

@test "v5.31.0 predicate: a bare host address is parsed as /32, not called garbage" {
    local out rc
    log_warn() { echo "WARN: $*"; }
    out=$(_is_full_tunnel "8.8.8.8" 2>&1) && rc=0 || rc=$?
    # Understood, therefore no warning - and one host is obviously not a full tunnel.
    [ -z "$out" ]
    [ "$rc" -ne 0 ]
}

@test "v5.31.0 predicate: a multi-line list is read whole, not just its first line" {
    # wg allows AllowedIPs to repeat and the values add up (D#38). `read` stops
    # at the first newline even with newline in IFS, so the tail used to be
    # dropped silently - and a dropped route makes a full tunnel look split.
    _is_full_tunnel "$(printf '0.0.0.0/1
128.0.0.0/1')"
    run _is_full_tunnel "$(printf '10.0.0.0/8
192.168.0.0/16')"
    [ "$status" -ne 0 ]
}

@test "v5.31.0 predicate: a trailing carriage return does not break the parse" {
    # A config edited on Windows arrives with  glued to the last token.
    local out rc
    log_warn() { echo "WARN: $*"; }
    out=$(_is_full_tunnel "$(printf '0.0.0.0/0')" 2>&1) && rc=0 || rc=$?
    [ "$rc" -eq 0 ]
    [ -z "$out" ]
}

@test "v5.31.0 predicate: an oversized list is refused LOUDLY with its size" {
    # Every token costs a process; a list of tens of thousands of networks would
    # turn add and regen into minutes. The refusal must name the number.
    local big i out rc
    big="0.0.0.0/0"
    for ((i = 0; i < 600; i++)); do big="$big, 10.$((i / 256)).$((i % 256)).0/24"; done
    log_warn() { echo "WARN: $*"; }
    out=$(_is_full_tunnel "$big" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *"601"* ]]
}

@test "v5.31.0 predicate: the cap is exact - 512 evaluated, 513 refused" {
    # 401 and 601 would let an off-by-one live, so the boundary itself is tested.
    local big i out rc
    big="0.0.0.0/0"
    for ((i = 0; i < 511; i++)); do big="$big, 10.$((i / 256)).$((i % 256)).0/24"; done
    _is_full_tunnel "$big"
    big="$big, 10.2.0.0/24"
    log_warn() { echo "WARN: $*"; }
    out=$(_is_full_tunnel "$big" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *"513"* ]]
}

@test "v5.31.0 predicate: an octet above 255 is refused, not silently accepted" {
    local out rc
    log_warn() { echo "WARN: $*"; }
    out=$(_is_full_tunnel "0.0.0.0/0, 10.0.256.0/24" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *"10.0.256.0/24"* ]]
}

@test "v5.31.0 predicate: boundaries of the non-public table are exact" {
    # 9.0.0.0/8 is public and sits right before the private 10.0.0.0/8. Missing
    # the private one is fine; missing its public neighbour is not. This is the
    # exact edge of the table, so an off-by-one in it turns this test red.
    run _is_full_tunnel "0.0.0.0/5, 8.0.0.0/8, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/1"
    [ "$status" -ne 0 ]
    _is_full_tunnel "0.0.0.0/5, 8.0.0.0/8, 9.0.0.0/8, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/1"
}

@test "v5.31.0 warnings go to stderr in both entry points" {
    # The appender is called through $(...), so a warning printed on stdout
    # would end up INSIDE the AllowedIPs value of a client config.
    local p
    for p in install_amneziawg.sh manage_amneziawg.sh; do
        grep -qF 'if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then' "${BATS_TEST_DIRNAME}/../$p"
        # the very next printf must redirect to stderr
        grep -A 2 'if \[\[ "$type" == "ERROR" || "$type" == "WARN" \]\]; then' "${BATS_TEST_DIRNAME}/../$p" | grep -qF '>&2'
    done
}

@test "v5.31.0 predicate: a failing sort is reported, not answered silently" {
    # The sort used to run inside a process substitution, where its failure is
    # invisible to the parent shell: on a host with a broken PATH every client
    # would quietly fall back to the pre-v5.31.0 behaviour, mode 1 included.
    local out rc
    log_warn() { echo "WARN: $*" >&2; }
    sort() { return 1; }
    out=$(_is_full_tunnel "0.0.0.0/0" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ]
    [[ "$out" == *"упорядочить"* ]]
}

# --- the appender ---

@test "v5.31.0 append: a full tunnel gains ::/0" {
    [ "$(_append_ipv6_full_tunnel_route '0.0.0.0/0')" = "0.0.0.0/0, ::/0" ]
}

@test "v5.31.0 append: the default list gains ::/0" {
    local list
    list=$(mode2_list)
    [ "$(_append_ipv6_full_tunnel_route "$list")" = "$list, ::/0" ]
}

@test "v5.31.0 append: idempotent - a list that already has ::/0 is untouched" {
    [ "$(_append_ipv6_full_tunnel_route '0.0.0.0/0, ::/0')" = "0.0.0.0/0, ::/0" ]
}

@test "v5.31.0 append: a dual-stack list keeps its ULA and gains nothing" {
    local dual="0.0.0.0/0, fddd:2c4:2c4:2c4::/64"
    [ "$(_append_ipv6_full_tunnel_route "$dual")" = "$dual" ]
}

@test "v5.31.0 append: a split list is returned unchanged" {
    [ "$(_append_ipv6_full_tunnel_route '10.0.0.0/8')" = "10.0.0.0/8" ]
}

@test "v5.31.0 append: a warning is visible and stays out of the value" {
    # The appender is called through $(...), so the value is only safe because
    # the real log_warn writes to stderr (verified structurally in another test).
    # Here the production contract is stubbed faithfully and both halves are
    # asserted: the caller sees the warning, the value stays clean.
    local v
    log_warn() { echo "WARN: $*" >&2; }
    # stderr goes to a file, not through another $(...): an assignment inside a
    # command substitution happens in a subshell and would never reach the test.
    v=$(_append_ipv6_full_tunnel_route "0.0.0.0/0, garbage" 2>"$TEST_DIR/err1")
    [ "$v" = "0.0.0.0/0, garbage" ]
    grep -q "garbage" "$TEST_DIR/err1"
    v=$(_append_ipv6_full_tunnel_route "$(mode2_list), 10.0.256.0/24" 2>"$TEST_DIR/err2")
    [[ "$v" != *"WARN"* ]]
    grep -q "10.0.256.0/24" "$TEST_DIR/err2"
}

@test "v5.31.0 append: the emitted value is normalised, not the raw input" {
    # The decision is taken on a normalised copy; emitting the raw string would
    # carry a stray carriage return into the config alongside the ::/0.
    local v
    v=$(_append_ipv6_full_tunnel_route "$(printf '0.0.0.0/0\r')")
    [ "$v" = "0.0.0.0/0 , ::/0" ]
    [[ "$v" != *$'\r'* ]]
}

# --- render_client_config: the actual bug ---

setup_default_mode() {
    create_server_config
    create_init_config
    # Replace the truncated fixture list with the real mode-2 default.
    local list
    list=$(mode2_list)
    [ -n "$list" ]
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='${list}'|" "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
}

@test "v5.31.0 render: the DEFAULT install writes ::/0 into the client config" {
    setup_default_mode
    render_client_config "def" "10.9.9.2" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
    grep -q "^AllowedIPs = .*, ::/0$" "$AWG_DIR/def.conf"
}

@test "v5.31.0 render: the default client keeps its whole IPv4 list" {
    setup_default_mode
    render_client_config "def2" "10.9.9.3" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
    grep -q "^AllowedIPs = 1.0.0.0/8, .*208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32, ::/0$" "$AWG_DIR/def2.conf"
}

@test "v5.31.0 render: mode 1 output is unchanged" {
    create_server_config
    create_init_config
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='0.0.0.0/0'|" "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    render_client_config "one" "10.9.9.4" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
    grep -qxF "AllowedIPs = 0.0.0.0/0, ::/0" "$AWG_DIR/one.conf"
}

@test "v5.31.0 render: a real split tunnel still gets no ::/0" {
    create_server_config
    create_init_config
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='10.0.0.0/8, 192.168.0.0/16'|" "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    render_client_config "split" "10.9.9.5" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
    grep -qxF "AllowedIPs = 10.0.0.0/8, 192.168.0.0/16" "$AWG_DIR/split.conf"
    run grep -qF "::/0" "$AWG_DIR/split.conf"
    [ "$status" -ne 0 ]
}

# --- dual-stack: the same fork, the other branch ---

@test "v5.31.0 dual-stack: default list plus native server IPv6 mirrors into ::/0" {
    setup_default_mode
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=1
CONF
    safe_load_config "$CONFIG_FILE"
    render_client_config "d6" "10.9.9.6" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::6"
    grep -q "^AllowedIPs = .*, ::/0$" "$AWG_DIR/d6.conf"
}

@test "v5.31.0 dual-stack: default list without native IPv6 still gets the tunnel ULA" {
    setup_default_mode
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=0
CONF
    safe_load_config "$CONFIG_FILE"
    render_client_config "d7" "10.9.9.7" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::7"
    grep -q "^AllowedIPs = .*, fddd:2c4:2c4:2c4::/64$" "$AWG_DIR/d7.conf"
    run grep -qF "::/0" "$AWG_DIR/d7.conf"
    [ "$status" -ne 0 ]
}

# --- regen: the fork that decides whether "re-issue the profile" helps ---

setup_regen() {
    # $1 name, $2 client_ip, $3 AllowedIPs already in the client config
    create_server_config
    create_init_config
    local list
    list=$(mode2_list)
    # Without this guard an empty fixture collapses to 0.0.0.0/0 and every
    # assertion below would pass while proving nothing about mode 2.
    [ -n "$list" ]
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='${list}'|" "$CONFIG_FILE"
    add_test_peer "$1" "$2"
    printf 'FAKEPRIV' > "$KEYS_DIR/$1.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    cat > "$AWG_DIR/$1.conf" << EOF
[Interface]
PrivateKey = FAKEPRIV
Address = $2/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = FAKESERVERPUB
Endpoint = 1.2.3.4:39743
AllowedIPs = $3
PersistentKeepalive = 33
EOF
    get_server_public_ip() { echo "1.2.3.4"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()        { return 0; }
    generate_vpn_uri()   { return 0; }
    generate_qr_vpnuri() { return 0; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr generate_vpn_uri generate_qr_vpnuri
}

@test "v5.31.0 regen: an already issued default client gets ::/0 on re-issue" {
    require_flock
    setup_regen "alice" "10.9.9.10" "$(mode2_list)"
    run regenerate_client "alice"
    [ "$status" -eq 0 ]
    # The whole IPv4 list is pinned, not just the tail: a collapsed list would
    # still satisfy ".*, ::/0".
    grep -q "^AllowedIPs = 1.0.0.0/8, .*208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32, ::/0$" "$AWG_DIR/alice.conf"
}

@test "v5.31.0 regen: running it twice does not double the ::/0" {
    require_flock
    setup_regen "bob" "10.9.9.11" "$(mode2_list)"
    run regenerate_client "bob"
    [ "$status" -eq 0 ]
    run regenerate_client "bob"
    [ "$status" -eq 0 ]
    [ "$(grep -c '::/0' "$AWG_DIR/bob.conf")" -eq 1 ]
    [ "$(grep -o '::/0' "$AWG_DIR/bob.conf" | wc -l)" -eq 1 ]
}

@test "v5.31.0 regen: a customized split client is still left alone" {
    require_flock
    setup_regen "carol" "10.9.9.12" "10.0.0.0/8"
    run regenerate_client "carol"
    [ "$status" -eq 0 ]
    grep -qxF "AllowedIPs = 10.0.0.0/8" "$AWG_DIR/carol.conf"
    run grep -qF "::/0" "$AWG_DIR/carol.conf"
    [ "$status" -ne 0 ]
}

# --- dual-stack regen: the cohort where a plain re-issue does NOT deliver ---

setup_regen_dualstack() {
    # $1 name, $2 ipv4, $3 ipv6, $4 AllowedIPs already in the client config
    create_server_config
    create_init_config
    local list
    list=$(mode2_list)
    [ -n "$list" ]
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='${list}'|" "$CONFIG_FILE"
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=1
CONF
    cat >> "$SERVER_CONF_FILE" << EOF

[Peer]
#_Name = $1
PublicKey = TESTPUBKEY_$1
AllowedIPs = $2/32, $3/128
EOF
    printf 'FAKEPRIV' > "$KEYS_DIR/$1.private"
    printf 'FAKESERVERPUB' > "$AWG_DIR/server_public.key"
    cat > "$AWG_DIR/$1.conf" << EOF
[Interface]
PrivateKey = FAKEPRIV
Address = $2/32, $3/128
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = FAKESERVERPUB
Endpoint = 1.2.3.4:39743
AllowedIPs = $4
PersistentKeepalive = 33
EOF
    get_server_public_ip() { echo "1.2.3.4"; }
    _ensure_server_public_key() { return 0; }
    generate_qr()        { return 0; }
    generate_vpn_uri()   { return 0; }
    generate_qr_vpnuri() { return 0; }
    export -f get_server_public_ip _ensure_server_public_key generate_qr generate_vpn_uri generate_qr_vpnuri
}

@test "v5.31.0 regen dual-stack: the kept IPv6 part is reported, not passed over in silence" {
    require_flock
    # This client carries the tunnel ULA, so the appender leaves the list alone
    # and the old value is restored over the freshly rendered one. The operator
    # ran the prescribed remedy; being told nothing would leave them with the
    # same leak and a cheerful "regenerated".
    local out
    setup_regen_dualstack "dual" "10.9.9.20" "fddd:2c4:2c4:2c4::20" "$(mode2_list), fddd:2c4:2c4:2c4::/64"
    log_warn() { echo "WARN: $*" >&3; }
    run regenerate_client "dual"
    [ "$status" -eq 0 ]
    grep -q "fddd:2c4:2c4:2c4::/64" "$AWG_DIR/dual.conf"
    # The warning names the working cure.
    out=$(_append_ipv6_full_tunnel_route "$(mode2_list), fddd:2c4:2c4:2c4::/64")
    [ "$out" = "$(mode2_list), fddd:2c4:2c4:2c4::/64" ]
    # The exact warning is pinned in both twins: a grep for 'reset-routes' alone
    # would still match the comment above it after the log_warn was deleted.
    grep -qF 'log_warn "Клиент' "${BATS_TEST_DIRNAME}/../awg_common.sh"
    grep -qF 'IPv6-часть AllowedIPs сохранена как есть' "${BATS_TEST_DIRNAME}/../awg_common.sh"
    grep -qF 'the IPv6 part of AllowedIPs was kept as-is' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

@test "v5.31.0 regen dual-stack: the warning about the kept IPv6 part exists in both twins" {
    # No require_flock here on purpose: the behavioural test above only runs
    # where flock exists, so without this one a deleted warning would go
    # unnoticed on every developer machine that skips it.
    grep -qF 'IPv6-часть AllowedIPs сохранена как есть' "${BATS_TEST_DIRNAME}/../awg_common.sh"
    grep -qF 'regen --reset-routes' "${BATS_TEST_DIRNAME}/../awg_common.sh"
    grep -qF 'the IPv6 part of AllowedIPs was kept as-is' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    grep -qF 'regen --reset-routes' "${BATS_TEST_DIRNAME}/../awg_common_en.sh"
}

@test "v5.31.0 regen: an empty appender result refuses instead of writing an empty list" {
    require_flock
    # The old code was a string comparison and could not fail; a command
    # substitution can return nothing. Writing 'AllowedIPs = ' and reporting
    # success is exactly the failure class this project treats as the worst.
    setup_regen "erin" "10.9.9.30" "$(mode2_list)"
    _append_ipv6_full_tunnel_route() { printf ''; }
    run regenerate_client "erin"
    [ "$status" -ne 0 ]
    run grep -qxF "AllowedIPs = " "$AWG_DIR/erin.conf"
    [ "$status" -ne 0 ]
}

# --- modify: the fourth decision point, deliberately left literal ---

_load_modify() {
    # Same harness as test_allowedips_dns_spacing.bats: take the function body
    # out of the RU script and eval it.
    local body
    body=$(awk '/^modify_client\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    eval "$body"
    escape_sed() { printf '%s' "$1" | sed 's/[&\/]/\&/g'; }
    apply_config() { return 0; }
    generate_qr()        { return 0; }
    generate_vpn_uri()   { return 0; }
    generate_qr_vpnuri() { return 0; }
}

_modify_fixture_full() {
    create_server_config
    create_init_config
    local list
    list=$(mode2_list)
    [ -n "$list" ]
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='${list}'|" "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    cat > "$AWG_DIR/$1.conf" << EOF
[Interface]
PrivateKey = FAKEPRIV
Address = 10.9.9.40/32
DNS = 1.1.1.1, 1.0.0.1
MTU = 1280

[Peer]
PublicKey = FAKESERVERPUB
Endpoint = 1.2.3.4:39743
AllowedIPs = ${list}, ::/0
PersistentKeepalive = 33
EOF
}

@test "v5.31.0 modify: setting the default list back strips ::/0 and says so" {
    require_flock
    # A published recipe does exactly this (modify <name> AllowedIPs "$ALLOWED_IPS"),
    # and awgsetup_cfg.init holds an IPv4-only list, so it removes the route this
    # release adds. modify stays literal - that is its contract, and it is how
    # people drop ::/0 on purpose - but it must not do it silently.
    local out
    _modify_fixture_full "mfull"
    _load_modify
    log_warn() { echo "WARN: $*" >&2; }
    run modify_client "mfull" "AllowedIPs" "$(mode2_list)"
    [ "$status" -eq 0 ]
    run grep -qF "::/0" "$AWG_DIR/mfull.conf"
    [ "$status" -ne 0 ]
    out=$(modify_client "mfull" "AllowedIPs" "$(mode2_list)" 2>&1 >/dev/null)
    [[ "$out" == *"regen"* ]]
}

@test "v5.31.0 modify: a genuine split list produces no such warning" {
    require_flock
    local out
    _modify_fixture_full "msplit"
    _load_modify
    log_warn() { echo "WARN: $*" >&2; }
    out=$(modify_client "msplit" "AllowedIPs" "10.0.0.0/8, 192.168.0.0/16" 2>&1 >/dev/null)
    [[ "$out" != *"regen"* ]]
    grep -qxF "AllowedIPs = 10.0.0.0/8, 192.168.0.0/16" "$AWG_DIR/msplit.conf"
}

@test "v5.31.0 modify: the warning exists in both manage twins" {
    grep -qF 'задан полным туннелем без ::/0' "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    grep -qF 'is a full tunnel without ::/0' "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
    local p
    for p in manage_amneziawg.sh manage_amneziawg_en.sh; do
        grep -qF 'declare -f _is_full_tunnel' "${BATS_TEST_DIRNAME}/../$p"
    done
}

# --- RU/EN parity ---

@test "v5.31.0 parity: both language variants carry the predicate and the appender" {
    local p
    for p in awg_common.sh awg_common_en.sh; do
        grep -qF '_is_full_tunnel()' "${BATS_TEST_DIRNAME}/../$p"
        grep -qF '_append_ipv6_full_tunnel_route()' "${BATS_TEST_DIRNAME}/../$p"
        grep -qF '_awg_ipv4_range_is_non_public()' "${BATS_TEST_DIRNAME}/../$p"
        # Defined is not called: without these two the EN twin could keep the
        # functions and stop using them, and every test here would stay green.
        grep -qF '_aip_new=$(_append_ipv6_full_tunnel_route "$allowed_ips")' "${BATS_TEST_DIRNAME}/../$p"
        grep -qF '_aip_new=$(_append_ipv6_full_tunnel_route "$current_allowed_ips")' "${BATS_TEST_DIRNAME}/../$p"
        grep -qF '_is_full_tunnel "$ipv4_part"' "${BATS_TEST_DIRNAME}/../$p"
        # No fork may go back to comparing the string.
        run grep -qF '[[ "$allowed_ips" == "0.0.0.0/0" ]]' "${BATS_TEST_DIRNAME}/../$p"
        [ "$status" -ne 0 ]
        run grep -qF '[[ "$current_allowed_ips" == "0.0.0.0/0" ]]' "${BATS_TEST_DIRNAME}/../$p"
        [ "$status" -ne 0 ]
    done
}

@test "v5.31.0 parity: the non-public range table is identical in RU and EN" {
    local ru en
    ru=$(sed -n '/^_AWG_NON_PUBLIC_IPV4=(/,/^)/p' "${BATS_TEST_DIRNAME}/../awg_common.sh")
    en=$(sed -n '/^_AWG_NON_PUBLIC_IPV4=(/,/^)/p' "${BATS_TEST_DIRNAME}/../awg_common_en.sh")
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}
