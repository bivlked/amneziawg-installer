#!/usr/bin/env bats
# The install default for AllowedIPs is the full tunnel (mode 1), not the
# 34-entry list (mode 2).
#
# Why it moved. Mode 2 covers all PUBLIC IPv4, leaving the private networks (and
# the reserved 0.0.0.0/8 and multicast) outside; the list form was chosen to dodge
# an iOS bug on 0.0.0.0/5 (issue #42), and keeping the private networks out is a
# real benefit of it, not an accident. But clients do not judge by coverage, they
# compare the list: the Amnezia app opens its own split-tunneling page only when it
# sees 0.0.0.0/0 among the routes, and the form it reliably recognises is the pair
# ["0.0.0.0/0","::/0"]; on Linux, awg-quick engages its fwmark machinery only for a
# /0 route, which a list-shaped IPv4 config does not carry, and a routing loop was
# measured on the bench. So mode 2 paid the compatibility price of a split tunnel
# while delivering exactly one split-tunnel benefit: the private networks stay out.
#
# Mode 2 is NOT removed - it is the documented retreat for whoever needs the
# LAN reachable (--route-amnezia). These tests guard both directions: the new
# default must hold, and the retreat must keep working.
#
# shellcheck disable=SC2154  # Variables set by sourced scripts at runtime

load test_helper

SCRIPTS=(install_amneziawg.sh install_amneziawg_en.sh)

# Run the routing-mode case statement EXTRACTED from the installer, not a copy:
# a copy would keep passing after someone edits the installer and breaks the
# property this file exists to protect.
run_case_block() {          # $1 installer, $2 ALLOWED_IPS_MODE, $3 CLI_CUSTOM_ROUTES
    local script="${BATS_TEST_DIRNAME}/../$1"
    # The REAL validator, not a permissive stub. With a stub the mode-3 branch
    # accepts anything, so the CIDR guard could be deleted and this file would
    # stay green - the same trap the comment on run_routing_fn describes, which
    # had been fixed there and left standing here.
    awk '/^validate_cidr_list\(\)/,/^}/' "$script" > "$TEST_DIR/case.sh"
    sed -n '/^    case "\$ALLOWED_IPS_MODE" in$/,/^    esac$/p' "$script" >> "$TEST_DIR/case.sh"
    # Both halves must be present. An empty or half extraction would make every
    # assertion below pass while testing nothing.
    grep -q '^validate_cidr_list()' "$TEST_DIR/case.sh"
    grep -q '^    esac$' "$TEST_DIR/case.sh"
    ALLOWED_IPS_MODE="$2" CLI_CUSTOM_ROUTES="${3-10.1.0.0/16}" bash -c '
        log(){ :; }; log_warn(){ :; }; die(){ printf "DIE"; exit 1; }
        source "$1"
        printf "%s|%s" "$ALLOWED_IPS_MODE" "$ALLOWED_IPS"' _ "$TEST_DIR/case.sh"
}

# The same block, but returning what log_warn said. The warning is the
# user-visible half of the new contract and every other helper stubs it away.
run_case_warn() {           # $1 installer, $2 value of ALLOWED_IPS_MODE
    local script="${BATS_TEST_DIRNAME}/../$1"
    awk '/^validate_cidr_list\(\)/,/^}/' "$script" > "$TEST_DIR/casew.sh"
    sed -n '/^    case "\$ALLOWED_IPS_MODE" in$/,/^    esac$/p' "$script" >> "$TEST_DIR/casew.sh"
    grep -q '^    esac$' "$TEST_DIR/casew.sh"
    ALLOWED_IPS_MODE="$2" CLI_CUSTOM_ROUTES="10.1.0.0/16" bash -c '
        log(){ :; }; log_warn(){ printf "%s" "$1"; }; die(){ exit 1; }
        source "$1"' _ "$TEST_DIR/casew.sh"
}

# Same idea for the block that decides what to do with a server config that has
# no ALLOWED_IPS_MODE key at all.
run_infer_block() {         # $1 = installer, $2 = ALLOWED_IPS value
    local script="${BATS_TEST_DIRNAME}/../$1"
    sed -n '/^    if \[\[ "\$ALLOWED_IPS_MODE" == "default" \]\]; then$/,/^    fi$/p' \
        "$script" > "$TEST_DIR/infer.sh"
    [ -s "$TEST_DIR/infer.sh" ]
    # Both outcomes must be present, otherwise the extraction caught the wrong
    # block and the test would assert whatever that block happens to do.
    grep -q 'ALLOWED_IPS_MODE=2' "$TEST_DIR/infer.sh"
    grep -q 'ALLOWED_IPS_MODE=1' "$TEST_DIR/infer.sh"
    ALLOWED_IPS_MODE="default" ALLOWED_IPS="$2" bash -c '
        source "$1"; printf "%s" "$ALLOWED_IPS_MODE"' _ "$TEST_DIR/infer.sh"
}

# --- the interactive prompt ---

@test "default routing: the prompt offers 1 and both installers agree" {
    local s
    for s in "${SCRIPTS[@]}"; do
        run grep -cE 'read -rp "(Ваш выбор|Your choice) \[1\]: " r_mode' \
            "${BATS_TEST_DIRNAME}/../$s"
        [ "$output" = "1" ]
        run grep -cF 'ALLOWED_IPS_MODE=${r_mode:-1}' "${BATS_TEST_DIRNAME}/../$s"
        [ "$output" = "1" ]
    done
}

@test "default routing: no installer still prompts with [2]" {
    local s
    for s in "${SCRIPTS[@]}"; do
        # Anchored to the assignment and to the prompt line, not to a bare
        # substring: a comment mentioning the old value would otherwise fail a
        # pure documentation edit.
        run grep -F 'ALLOWED_IPS_MODE=${r_mode:-2}' "${BATS_TEST_DIRNAME}/../$s"
        [ "$status" -ne 0 ]
        run grep -E 'read -rp "(Ваш выбор|Your choice) \[2\]' "${BATS_TEST_DIRNAME}/../$s"
        [ "$status" -ne 0 ]
    done
}

# --- the case statement ---

@test "default routing: an empty answer selects the full tunnel" {
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(run_case_block "$s" "")" = "1|0.0.0.0/0" ]
    done
}

@test "default routing: a typo falls back to the full tunnel, not to the old default" {
    local s junk
    for s in "${SCRIPTS[@]}"; do
        for junk in "y" "22" "2 " "7" "-1"; do
            [ "$(run_case_block "$s" "$junk")" = "1|0.0.0.0/0" ]
        done
    done
}

@test "default routing: mode 2 is still reachable and still ships the whole list" {
    # Full equality against the list read out of the script, not a prefix/suffix
    # check: a list that lost entries in the middle would pass the loose form.
    # ⚠️ What this does NOT prove: the expectation is read from the same file the
    # block comes from, so an edit to the list itself changes both sides. That the
    # list is right, and identical in RU and EN, is pinned in
    # test_v5310_ipv6_full_tunnel.bats.
    local s out want
    for s in "${SCRIPTS[@]}"; do
        want=$(sed -n 's/^[[:space:]]*ALLOWED_IPS="\(1\.0\.0\.0\/8,.*\)"$/\1/p' \
            "${BATS_TEST_DIRNAME}/../$s" | head -1)
        [ -n "$want" ]
        out=$(run_case_block "$s" "2")
        [ "$out" = "2|$want" ]
    done
}

# --- the whole routing function, not just its case statement ---

# Review remark, accepted: the block-level helpers above skip CLI handling, the
# --yes branch and the recovery path, i.e. exactly the lifecycle where a default
# can silently overwrite an existing server's saved mode. These drive the real
# function end to end.
run_routing_fn() {   # $1 installer, $2 CLI mode, $3 AUTO_YES, $4 saved mode, $5 saved list, $6 CLI custom
    # validate_cidr_list is taken FROM the script, not stubbed. A permissive stub
    # was tried first and quietly made the mode-3 test pass for the wrong reason:
    # the endless "try again" loop only exists because the real validator rejects
    # an empty string, so with the stub the guard could be deleted and the test
    # stayed green.
    local fn
    fn=$(awk '/^validate_cidr_list\(\)/,/^}/' "${BATS_TEST_DIRNAME}/../$1"
         awk '/^configure_routing_mode\(\)/,/^}/' "${BATS_TEST_DIRNAME}/../$1")
    # -n alone is satisfied by the validator on its own: if the definition line of
    # configure_routing_mode ever changes shape, the function would simply not
    # exist, the "command not found" would be swallowed by the redirect below, and
    # the assertions would fail on the VALUE instead of naming the real cause.
    printf '%s\n' "$fn" | grep -q '^validate_cidr_list()'
    printf '%s\n' "$fn" | grep -q '^configure_routing_mode()' 
    timeout 15 bash -c '
        log(){ :; }; log_warn(){ :; }
        # die exits the shell outright, so the marker has to be printed by the
        # stub itself - an "|| echo DIE" after the call never runs.
        die(){ printf "DIE"; exit 1; }
        CONFIG_FILE=/root/awg/awgsetup_cfg.init
        CLI_ROUTING_MODE="'"$2"'"; AUTO_YES='"$3"'
        ALLOWED_IPS_MODE="'"$4"'"; ALLOWED_IPS="'"$5"'"; CLI_CUSTOM_ROUTES="'"$6"'"
        '"$fn"'
        configure_routing_mode 2>/dev/null
        printf "%s|%s" "$ALLOWED_IPS_MODE" "$ALLOWED_IPS"' < /dev/null
}

@test "default routing: a fresh --yes install picks the full tunnel" {
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(run_routing_fn "$s" default 1 default "" "")" = "1|0.0.0.0/0" ]
    done
}

@test "default routing: --route-amnezia still wins over the default" {
    local s out want
    for s in "${SCRIPTS[@]}"; do
        want=$(sed -n 's/^[[:space:]]*ALLOWED_IPS="\(1\.0\.0\.0\/8,.*\)"$/\1/p' \
            "${BATS_TEST_DIRNAME}/../$s" | head -1)
        out=$(run_routing_fn "$s" 2 1 default "" "")
        [ "$out" = "2|$want" ]
    done
}

@test "default routing: --route-custom still wins over the default" {
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(run_routing_fn "$s" 3 1 default "" "10.1.0.0/16")" = "3|10.1.0.0/16" ]
    done
}

@test "default routing: a saved mode survives the new default when the list is empty" {
    # The finding this guards: an existing server whose config carries a mode but
    # no list went through the --yes branch, which assigned the INSTALL default
    # over the saved value. Changing that default would then change the mode of a
    # working server without anyone choosing it.
    local s out want
    for s in "${SCRIPTS[@]}"; do
        want=$(sed -n 's/^[[:space:]]*ALLOWED_IPS="\(1\.0\.0\.0\/8,.*\)"$/\1/p' \
            "${BATS_TEST_DIRNAME}/../$s" | head -1)
        out=$(run_routing_fn "$s" default 1 2 "" "")
        [ "$out" = "2|$want" ]
        [ "$(run_routing_fn "$s" default 1 1 "" "")" = "1|0.0.0.0/0" ]
    done
}

@test "default routing: an explicit flag wins over a saved mode" {
    # The documented upgrade path: an existing list-based server re-run with
    # --route-all. Until now every test passed either a CLI mode or a saved mode,
    # never both, so the precedence between the CLI branch and the new recovery
    # branch was not verified by anything.
    local s want
    for s in "${SCRIPTS[@]}"; do
        want=$(sed -n 's/^[[:space:]]*ALLOWED_IPS="\(1\.0\.0\.0\/8,.*\)"$/\1/p' \
            "${BATS_TEST_DIRNAME}/../$s" | head -1)
        [ -n "$want" ]
        [ "$(run_routing_fn "$s" 1 1 2 "$want" "")" = "1|0.0.0.0/0" ]
        [ "$(run_routing_fn "$s" 2 1 1 "0.0.0.0/0" "")" = "2|$want" ]
    done
}

@test "default routing: --route-custom with an empty value is refused" {
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(run_routing_fn "$s" 3 1 default "" "")" = "DIE" ]
    done
}

@test "default routing: a saved mode 3 with no list refuses loudly instead of hanging" {
    # Reaching the mode-3 branch with nothing to rebuild from used to be
    # impossible; the recovery path above makes it reachable. Its prompt reads
    # /dev/tty, and with no terminal read fails at once while the validator keeps
    # rejecting the empty string - an endless, silent loop. Measured: identical
    # with and without --yes, so the refusal is unconditional.
    local s y
    for s in "${SCRIPTS[@]}"; do
        for y in 1 0; do
            [ "$(run_routing_fn "$s" default "$y" 3 "" "")" = "DIE" ]
        done
    done
}

# Drive the network prompt of mode 3 with a substituted /dev/tty.
#
# ⚠️ Asserting only "it terminated" is NOT enough, and that was the first version
# of this test: a silent fallback that accepts an unvalidated value terminates
# just as well as a refusal, and would write that value into the server config.
# So each scenario names the message it must produce, and the two guards - the
# read exit status and the retry cap - are told apart.
run_prompt3() {             # $1 installer, $2 "eof" | $3 "cap"
    local script="${BATS_TEST_DIRNAME}/../$1" fn
    printf '3\n' > "$TEST_DIR/tty.txt"
    fn=$(awk '/^validate_cidr_list\(\)/,/^}/' "$script"
         awk '/^configure_routing_mode\(\)/,/^}/' "$script")
    printf '%s\n' "$fn" | grep -q '^configure_routing_mode()'
    printf '%s\n' "$fn" > "$TEST_DIR/loop.sh"
    # 🔴 Substitute the READ LINES by name, never by order of occurrence. The
    # first /dev/tty in this function sits inside a COMMENT, so an occurrence
    # based replacement rewrote prose and left the menu reading a dead path - the
    # test then measured the harness instead of the guard.
    sed -i "s#\" r_mode < /dev/tty#\" r_mode < $TEST_DIR/tty.txt#" "$TEST_DIR/loop.sh"
    if [ "$2" = eof ]; then
        # The menu gets its answer, the network prompt hits end of input: Ctrl-D.
        sed -i 's#ALLOWED_IPS < /dev/tty#ALLOWED_IPS < /dev/null#' "$TEST_DIR/loop.sh"
    else
        # Every read returns "3", which the validator rejects: the "keeps typing
        # something invalid" case that the retry cap exists for.
        sed -i "s#ALLOWED_IPS < /dev/tty#ALLOWED_IPS < $TEST_DIR/tty.txt#" "$TEST_DIR/loop.sh"
    fi
    # Both substitutions must have landed, and no read may still point at a real
    # terminal - otherwise the run would block instead of testing anything.
    grep -qF "\" r_mode < $TEST_DIR/tty.txt" "$TEST_DIR/loop.sh"
    ! grep -qE 'read -rp .* < /dev/tty' "$TEST_DIR/loop.sh"
    timeout 15 bash -c '
        log(){ :; }; log_warn(){ :; }; die(){ printf "DIE:%s" "$1"; exit 1; }
        CONFIG_FILE=/root/awg/awgsetup_cfg.init
        CLI_ROUTING_MODE=default; AUTO_YES=0; CLI_CUSTOM_ROUTES=""
        ALLOWED_IPS_MODE=default; ALLOWED_IPS=""
        source "$1" >/dev/null 2>&1
        configure_routing_mode 2>/dev/null
        printf "NO-REFUSAL:%s" "$ALLOWED_IPS"' _ "$TEST_DIR/loop.sh"
}

@test "default routing: the network prompt refuses on end of input, not loops" {
    local s out want rc
    for s in "${SCRIPTS[@]}"; do
        case "$s" in
            *_en.sh) want="Input ended" ;;
            *)       want="Ввод закончился" ;;
        esac
        # rc is captured without tripping errexit: die exits 1 by design.
        # The menu prints its own lines to stdout, so the marker is matched as a
        # SUBSTRING, and the absence of NO-REFUSAL is asserted separately - that
        # is what tells a refusal apart from a silent fallback.
        rc=0
        out=$(run_prompt3 "$s" eof) || rc=$?
        [ "$rc" -ne 124 ]
        [[ "$out" == *"DIE:"* ]]
        [[ "$out" != *"NO-REFUSAL"* ]]
        [[ "$out" == *"$want"* ]]
    done
}

@test "default routing: the network prompt gives up after a bounded number of tries" {
    local s out want rc
    for s in "${SCRIPTS[@]}"; do
        case "$s" in
            *_en.sh) want="Five invalid" ;;
            *)       want="Пять некорректных" ;;
        esac
        rc=0
        out=$(run_prompt3 "$s" cap) || rc=$?
        [ "$rc" -ne 124 ]
        [[ "$out" == *"DIE:"* ]]
        [[ "$out" != *"NO-REFUSAL"* ]]
        [[ "$out" == *"$want"* ]]
    done
}

@test "default routing: an unrecognised answer warns, an accepted one does not" {
    local s w
    for s in "${SCRIPTS[@]}"; do
        w=$(run_case_warn "$s" "7")
        [ -n "$w" ]
        [[ "$w" == *"7"* ]]
        # An empty answer is a deliberate choice of the default, and "1" is the
        # default named explicitly: neither may produce a warning.
        [ -z "$(run_case_warn "$s" "")" ]
        [ -z "$(run_case_warn "$s" "1")" ]
        [ -z "$(run_case_warn "$s" "2")" ]
    done
}

@test "default routing: an invalid --route-custom list is still refused" {
    # Guarded here because run_case_block used to stub the validator away, so the
    # refusal could be deleted with every test staying green.
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(run_case_block "$s" "3" "999.1.2.3/99")" = "DIE" ]
        [ "$(run_case_block "$s" "3" "10.1.0.0/16")" = "3|10.1.0.0/16" ]
    done
}

@test "default routing: a garbage ALLOWED_IPS_MODE in the config is refused" {
    # It was the only routing key with no validation. A garbage value reached the
    # isolation logic, where the comparisons against "1" and "2" give mode-3
    # semantics, and the tunnel subnet got appended to 0.0.0.0/0 - which stops the
    # profile from being the exact pair this whole change is about.
    local s out
    for s in "${SCRIPTS[@]}"; do
        sed -n '/^        case "\${ALLOWED_IPS_MODE:-}" in$/,/^        esac$/p' \
            "${BATS_TEST_DIRNAME}/../$s" > "$TEST_DIR/valid.sh"
        [ -s "$TEST_DIR/valid.sh" ]
        grep -q 'ALLOWED_IPS_MODE' "$TEST_DIR/valid.sh"
        local v
        for v in 1 2 3 "" default; do
            out=$(ALLOWED_IPS_MODE="$v" bash -c '
                die(){ printf "DIE"; exit 1; }
                CONFIG_FILE=/root/awg/awgsetup_cfg.init
                source "$1"; printf "OK"' _ "$TEST_DIR/valid.sh") || true
            [ "$out" = "OK" ]
        done
        for v in amnezia 02 "2 " on -1; do
            out=$(ALLOWED_IPS_MODE="$v" bash -c '
                die(){ printf "DIE"; exit 1; }
                CONFIG_FILE=/root/awg/awgsetup_cfg.init
                source "$1"; printf "OK"' _ "$TEST_DIR/valid.sh") || true
            [ "$out" = "DIE" ]
        done
    done
}

@test "default routing: an inferred mode 2 still gets the tunnel subnet with isolation off" {
    # Ties the inference to the behaviour it exists to protect: a legacy list is
    # labelled mode 2, and mode 2 with isolation off must still append the tunnel
    # subnet, or the clients stop seeing each other.
    local s fns
    for s in "${SCRIPTS[@]}"; do
    fns=$(awk '/^tunnel_network_cidr\(\)/,/^}/' "${BATS_TEST_DIRNAME}/../$s"
          awk '/^_apply_isolation_to_allowed_ips\(\)/,/^}/' "${BATS_TEST_DIRNAME}/../$s")
    # -n alone is satisfied by the first function on its own, so a rename of the
    # second one would fail on the VALUE instead of naming the extraction.
    printf '%s\n' "$fns" | grep -q '^tunnel_network_cidr()'
    printf '%s\n' "$fns" | grep -q '^_apply_isolation_to_allowed_ips()'
    run bash -c '
        log(){ :; }
        '"$fns"'
        AWG_TUNNEL_SUBNET=10.9.9.1/24
        CLIENT_ISOLATION=0 ALLOWED_IPS_MODE=2 ALLOWED_IPS="1.0.0.0/8, 8.8.8.8/32"
        _apply_isolation_to_allowed_ips; echo "inferred2:$ALLOWED_IPS"
        CLIENT_ISOLATION=0 ALLOWED_IPS_MODE=1 ALLOWED_IPS="0.0.0.0/0"
        _apply_isolation_to_allowed_ips; echo "mode1off:$ALLOWED_IPS"
        # Isolation ON plus mode 1 is what a default install now produces, and it
        # was the one combination no test covered: under mode 2 this function
        # STRIPS the tunnel subnet from the list, under mode 1 there is nothing to
        # strip and isolation rests entirely on the server-side DROP rule.
        CLIENT_ISOLATION=1 ALLOWED_IPS_MODE=1 ALLOWED_IPS="0.0.0.0/0"
        _apply_isolation_to_allowed_ips; echo "mode1on:$ALLOWED_IPS"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'inferred2:1.0.0.0/8, 8.8.8.8/32, 10.9.9.0/24'* ]]
    [[ "$output" == *'mode1off:0.0.0.0/0'* ]]
    [[ "$output" == *'mode1on:0.0.0.0/0'* ]]
    done
}

@test "default routing: dual-stack on the new default mirrors IPv4 into IPv6" {
    # The dual-stack branch was only ever driven through the list-shaped mode,
    # which is no longer what an install produces by default.
    setup_default_install
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=1
CONF
    safe_load_config "$CONFIG_FILE"
    render_client_config "d6" "10.9.9.6" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::6"
    grep -qxF "AllowedIPs = 0.0.0.0/0, ::/0" "$AWG_DIR/d6.conf"
}

@test "default routing: dual-stack without native IPv6 gets the tunnel ULA, not ::/0" {
    setup_default_install
    cat >> "$CONFIG_FILE" << 'CONF'
export ALLOW_IPV6_TUNNEL=1
export IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
export SERVER_HAS_NATIVE_IPV6=0
CONF
    safe_load_config "$CONFIG_FILE"
    render_client_config "d7" "10.9.9.7" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743" "fddd:2c4:2c4:2c4::7"
    grep -qxF "AllowedIPs = 0.0.0.0/0, fddd:2c4:2c4:2c4::/64" "$AWG_DIR/d7.conf"
    run grep -qF "::/0" "$AWG_DIR/d7.conf"
    [ "$status" -ne 0 ]
}

@test "default routing: mode 3 keeps taking the list it was given" {
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(run_case_block "$s" "3")" = "3|10.1.0.0/16" ]
    done
}

# --- a server config written before the ALLOWED_IPS_MODE key existed ---

@test "default routing: an existing list-based config is NOT relabelled as mode 1" {
    # The trap this guards: with isolation off, mode 1 does not append the
    # tunnel subnet (0.0.0.0/0 already covers it) while a list-based mode does.
    # Silently calling an old list "mode 1" would strip that subnet on the next
    # run and the clients would stop seeing each other.
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(run_infer_block "$s" "1.0.0.0/8, 2.0.0.0/7, 208.0.0.0/4")" = "2" ]
        [ "$(run_infer_block "$s" "192.168.50.0/24")" = "2" ]
        # A list that CONTAINS 0.0.0.0/0 alongside something else is classified as
        # list-mode and then saved, permanently relabelling a full-tunnel server.
        # The installer does not produce such a value today, so this pins a latent
        # decision rather than live behaviour - but the decision is silent and
        # sticky, which is exactly why it should not drift unnoticed.
        [ "$(run_infer_block "$s" "0.0.0.0/0, 10.9.9.0/24")" = "2" ]
    done
}

@test "default routing: a config with no list at all gets the current default" {
    local s
    for s in "${SCRIPTS[@]}"; do
        [ "$(run_infer_block "$s" "")" = "1" ]
        [ "$(run_infer_block "$s" "0.0.0.0/0")" = "1" ]
        # Whitespace around the value must not change the verdict.
        [ "$(run_infer_block "$s" "  0.0.0.0/0  ")" = "1" ]
    done
}

# --- what the client actually receives ---

setup_default_install() {
    create_server_config
    create_init_config
    sed -i "s|^export ALLOWED_IPS_MODE=.*|export ALLOWED_IPS_MODE=1|" "$CONFIG_FILE"
    sed -i "s|^export ALLOWED_IPS=.*|export ALLOWED_IPS='0.0.0.0/0'|" "$CONFIG_FILE"
    # 🔴 Prove the substitution landed. render_client_config falls back to
    # ${ALLOWED_IPS:-0.0.0.0/0}, so a sed that silently matched nothing would leave
    # the config WITHOUT a route list and the tests below would then be asserting
    # the fallback rather than the configured mode - and would stay green if the
    # shared fixture were renamed.
    grep -qxF "export ALLOWED_IPS_MODE=1" "$CONFIG_FILE"
    grep -qxF "export ALLOWED_IPS='0.0.0.0/0'" "$CONFIG_FILE"
    safe_load_config "$CONFIG_FILE"
    [ "$ALLOWED_IPS" = "0.0.0.0/0" ]
}

@test "default routing: the client config carries exactly '0.0.0.0/0, ::/0'" {
    setup_default_install
    render_client_config "def" "10.9.9.2" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
    # grep -qxF, not a loose match: the whole point is the EXACT pair, because
    # that is what the Amnezia app compares against.
    grep -qxF "AllowedIPs = 0.0.0.0/0, ::/0" "$AWG_DIR/def.conf"
}

@test "default routing: re-rendering does not duplicate ::/0" {
    setup_default_install
    render_client_config "def" "10.9.9.2" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
    render_client_config "def" "10.9.9.2" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
    grep -qxF "AllowedIPs = 0.0.0.0/0, ::/0" "$AWG_DIR/def.conf"
}

@test "default routing: the vpn:// array built from that config is exactly two elements" {
    require_grep_P
    setup_default_install
    render_client_config "def" "10.9.9.2" "FAKEPRIV" "FAKEPUB" "1.2.3.4" "39743"
    # The extraction pipeline is lifted OUT of awg_common.sh rather than retyped:
    # the perl side splits this string on commas straight into the JSON array, so
    # a change to the pipeline must be able to fail this test.
    local pipeline pipeline_en
    pipeline=$(grep -oF 'allowed_ips=$(grep -oP '"'"'AllowedIPs\s*=\s*\K.+'"'"' "$conf_file" | paste -sd, - | tr -d '"'"' \r'"'"')' \
        "${BATS_TEST_DIRNAME}/../awg_common.sh" | head -1)
    pipeline_en=$(grep -oF 'allowed_ips=$(grep -oP '"'"'AllowedIPs\s*=\s*\K.+'"'"' "$conf_file" | paste -sd, - | tr -d '"'"' \r'"'"')' \
        "${BATS_TEST_DIRNAME}/../awg_common_en.sh" | head -1)
    [ -n "$pipeline" ]
    # Every other test here loops both language variants; this one used to look at
    # the Russian library only.
    [ "$pipeline" = "$pipeline_en" ]
    local joined
    joined=$(conf_file="$AWG_DIR/def.conf" bash -c "$pipeline"'; printf "%s" "$allowed_ips"')
    [ "$joined" = "0.0.0.0/0,::/0" ]
    # And the split that perl performs yields two elements, in this order.
    local -a parts
    IFS=, read -ra parts <<< "$joined"
    [ "${#parts[@]}" -eq 2 ]
    [ "${parts[0]}" = "0.0.0.0/0" ]
    [ "${parts[1]}" = "::/0" ]
}

# --- documentation must not contradict the code ---

@test "default routing: the docs say the full tunnel is the default" {
    # Positive assertions, one per surface a reader actually lands on. A purely
    # negative guard would stay green on a doc that stopped saying anything at
    # all about which mode is chosen.
    # Separator is @@ and not | because one of the strings is a markdown table
    # row and starts with a pipe of its own.
    local line f s
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        f=${line%%@@*}
        s=${line#*@@}
        grep -qF "$s" "${BATS_TEST_DIRNAME}/../$f" || { echo "$f: нет строки '$s'"; false; }
    done <<'PAIRS'
README.md@@По умолчанию `1` (весь трафик, `0.0.0.0/0`)
README.en.md@@Default `1` (all traffic, `0.0.0.0/0`)
ADVANCED.md@@**Режим 1: Весь трафик (`0.0.0.0/0`) - по умолчанию**
ADVANCED.en.md@@**Mode 1: All traffic (`0.0.0.0/0`) - the default**
INSTALL_VPS.ru.md@@| `--route-all` | «Весь трафик» (`0.0.0.0/0`) | по умолчанию
INSTALL_VPS.md@@| `--route-all` | "All traffic" (`0.0.0.0/0`) | the default
install_amneziawg.sh@@Режим 'Весь трафик' (0.0.0.0/0) - выбирается по умолчанию
install_amneziawg_en.sh@@'All traffic' mode (0.0.0.0/0) - chosen by default
PAIRS
}

@test "default routing: no doc still calls mode 2 the default" {
    # A proximity regex was tried first and thrown away: every honest sentence
    # that lists both modes puts the word "default" near the OTHER mode's name,
    # so the pattern either missed real cases or cried wolf on correct text.
    # What follows is the literal wording this change removed. That makes the
    # guard narrow by construction - it catches a revert and the phrasings we
    # actually shipped, not every conceivable way to say the same thing - and
    # that limit is the price of its being unable to raise a false alarm.
    local phrases=(
        'По умолчанию `2` (Список Amnezia+DNS)'
        'Default `2` (Amnezia List + DNS)'
        '**Режим 2: Список Amnezia + DNS (По умолчанию)**'
        '**Mode 2: Amnezia List + DNS (Default)**'
        'Режим: Список Amnezia+DNS (умолч.)'
        'Mode: Amnezia List + DNS (default)'
        'по умолчанию, Amnezia List'
        'дефолтный <code>--route-amnezia</code>'
        'the default <code>--route-amnezia</code>'
        'дефолтный режим «Amnezia»'
        'Дефолтный режим «Amnezia»'
        'дефолтный «Amnezia»'
        'the default "Amnezia"'
        'Режим "Amnezia" (по умолчанию)'
        'The "Amnezia" routing mode (the default)'
        'Причина - режим маршрутизации по умолчанию (mode 2'
        'Fixed in v5.16.1. The default routing mode (mode 2'
        'дефолтном режиме маршрутизации (Amnezia List'
        'the default routing mode (Amnezia List'
        'по умолчанию, в туннель идёт весь публичный IPv4 кроме частных сетей'
        'Дефолтный режим маршрутизации начинался с'
        'The default routing mode started with'
        'включая дефолтный режим «Amnezia»'
        'the default "Amnezia" mode included'
    )
    # Набор файлов тот же, что сканирует scripts/check-docs-consistency.sh.
    # Первая редакция перечисляла только README/ADVANCED/INSTALL_VPS/ROADMAP, и
    # устаревшая формулировка уцелела в WARP-RU - ровно тот промах, который в
    # самом стороже доков описан как однажды уже оплаченный.
    local files=(README.md README.en.md ADVANCED.md ADVANCED.en.md
                 INSTALL_VPS.md INSTALL_VPS.ru.md docs/ROADMAP.md
                 WARP-RU.md WARP-RU.en.md CASCADE.md CASCADE.en.md
                 awg_common.sh awg_common_en.sh
                 install_amneziawg.sh install_amneziawg_en.sh)
    # Canary: the matcher itself must be able to fire. Without this the loop
    # below would stay green if grep -qF silently stopped working the way it is
    # used here, and a green guard is believed.
    printf '%s\n' "${phrases[0]}" > "$TEST_DIR/canary.txt"
    grep -qF "${phrases[0]}" "$TEST_DIR/canary.txt"
    local p f hits=""
    for f in "${files[@]}"; do
        for p in "${phrases[@]}"; do
            if grep -qF "$p" "${BATS_TEST_DIRNAME}/../$f"; then
                hits+="$f: $p"$'\n'
            fi
        done
    done
    [ -z "$hits" ] || { echo "$hits"; false; }
}
