#!/usr/bin/env bats
# AWG_PROTOCOL: the installation's protocol-generation marker in awgsetup_cfg.init.
#
# This is the only thing that protects an existing install from a silent
# generation change once the installer learns a second profile. Three
# properties are asserted here, and every one of them was checked to go red
# when its guard is removed (mutation runs are recorded in the description of
# the pull request that introduced this file):
#
#   1. The marker travels from the file to the environment. safe_load_config()
#      filters keys through a whitelist WITHOUT a default branch: an unknown key
#      is dropped silently. A marker that is written but not whitelisted would
#      read as absent forever, and "absent" means 2.0 by rule - a 3.1 install
#      would quietly behave as 2.0. Both copies are covered: the installer
#      carries its own safe_load_config() because initialize_setup() runs at
#      step 0, before awg_common.sh is downloaded (step 5) and sourced (step 6).
#   2. awg_installed_protocol() has exactly one default rule: no field = 2.0
#      (every install made before the marker existed), '2.0' = 2.0, '3.1' = 3.1,
#      anything else = failure with no output, never a quiet default. A corrupt
#      marker on a 3.1 server must stop the caller, not hand out 2.0 profiles
#      that will not connect.
#   3. Every re-run of the installer that reaches configuration (--force or
#      AWG_FORCE_REINSTALL=1, optionally combined with --preset, --mobile,
#      --no-cps, --jc*; and any run while awg-quick@awg0 is not active: resume
#      after a reboot, the ARM repair after a kernel change) goes through the
#      same initialize_setup(): load the init, regenerate parameters, write the
#      init back. A run without --force on top of a working server exits at the
#      idempotency guard BEFORE that and never touches the file. `manage restore` is the one path outside the installer
#      that replaces the init: it is an explicit action bringing back a
#      consistent set, so it is allowed, but it must warn before writing when
#      the generation differs (asserted on the helper and on the call site). So the marker survives all of them iff (a) it is hard-reset
#      before the load so nothing leaks in from the environment, (b) it is
#      assigned once, from the function, and NOTHING ELSE assigns it in between,
#      and (c) the heredoc writes it back verbatim and that line really renders.
#      (a)-(c) are asserted structurally on both language versions, and (c) is
#      additionally executed: the real heredoc is extracted and rendered.
#
# shellcheck disable=SC2154  # variables set by sourced scripts at runtime

load test_helper

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
COMMON_RU="$BATS_TEST_DIRNAME/../awg_common.sh"
COMMON_EN="$BATS_TEST_DIRNAME/../awg_common_en.sh"

# Function body of $2 from script $1, without running the script.
func_from() { sed -n "/^$2()/,/^}/p" "$1"; }

# The awgsetup_cfg.init heredoc of initialize_setup(), from the redirect line to
# the closing EOF, exactly as the installer executes it.
init_heredoc_from() { sed -n '/cat > "\$temp_conf" << EOF/,/^EOF$/p' "$1"; }

# Render the extracted heredoc into $TEST_DIR/rendered.init with the current
# environment and return the path. Unset variables render empty, which is fine:
# only the marker line is under test here.
render_init() {
    local script="$1" temp_conf="$TEST_DIR/rendered.init"
    eval "$(init_heredoc_from "$script")"
    echo "$temp_conf"
}

# ---------- 1. whitelist: marker reaches the environment ----------

@test "safe_load_config (awg_common): AWG_PROTOCOL is whitelisted and reaches the environment" {
    echo "export AWG_PROTOCOL='3.1'" > "$CONFIG_FILE"
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    [ "${AWG_PROTOCOL:-}" = "3.1" ]
}

@test "safe_load_config (awg_common_en): AWG_PROTOCOL is whitelisted" {
    eval "$(func_from "$COMMON_EN" safe_load_config)"
    echo "export AWG_PROTOCOL='3.1'" > "$CONFIG_FILE"
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    [ "${AWG_PROTOCOL:-}" = "3.1" ]
}

@test "safe_load_config (installer RU copy): AWG_PROTOCOL is whitelisted" {
    eval "$(func_from "$INSTALL_RU" safe_load_config)"
    echo "export AWG_PROTOCOL='3.1'" > "$CONFIG_FILE"
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    [ "${AWG_PROTOCOL:-}" = "3.1" ]
}

@test "safe_load_config (installer EN copy): AWG_PROTOCOL is whitelisted" {
    eval "$(func_from "$INSTALL_EN" safe_load_config)"
    echo "export AWG_PROTOCOL='3.1'" > "$CONFIG_FILE"
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    [ "${AWG_PROTOCOL:-}" = "3.1" ]
}

@test "safe_load_config: an init without the field leaves AWG_PROTOCOL empty (no invention)" {
    create_init_config
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    [ -z "${AWG_PROTOCOL:-}" ]
}

# ---------- 2. the single default rule ----------

@test "awg_installed_protocol: no field means 2.0 (every pre-marker install)" {
    unset AWG_PROTOCOL
    run awg_installed_protocol
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "awg_installed_protocol: an empty field means 2.0" {
    AWG_PROTOCOL=""
    run awg_installed_protocol
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "awg_installed_protocol: '2.0' and '3.1' are returned as they are" {
    AWG_PROTOCOL="2.0"
    run awg_installed_protocol
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
    AWG_PROTOCOL="3.1"
    run awg_installed_protocol
    [ "$status" -eq 0 ]
    [ "$output" = "3.1" ]
}

@test "awg_installed_protocol: any other value fails with NO output (no quiet default)" {
    local v
    for v in "3.0" "yes" "3.1 " " 3.1" "2" "31" "3.1.0" "'3.1'"; do
        AWG_PROTOCOL="$v"
        run awg_installed_protocol
        [ "$status" -ne 0 ] || { echo "accepted: '$v'"; false; }
        [ -z "$output" ] || { echo "printed on failure for '$v': $output"; false; }
    done
}

@test "awg_installed_protocol: the four copies are byte-identical in SOURCE (RU/EN, common/installer)" {
    # Source text from the function's first line to its closing brace, compared
    # as bytes: a normalized declare -f would hide formatting or syntax
    # variants that happen to serialize the same way.
    local f body first=""
    for f in "$COMMON_RU" "$COMMON_EN" "$INSTALL_RU" "$INSTALL_EN"; do
        body=$(func_from "$f" awg_installed_protocol | tr -d '\r')
        [ -n "$body" ] || { echo "missing in $f"; false; }
        if [ -z "$first" ]; then first="$body"; else
            [ "$body" = "$first" ] || { echo "diverges: $f"; diff <(echo "$first") <(echo "$body") || true; false; }
        fi
    done
}

@test "awg_installed_protocol: a marker line that is present but unparseable fails closed (with the file argument)" {
    # safe_load_config drops what it cannot parse, so the variable is empty.
    # With the init path given, an empty value plus a line mentioning
    # AWG_PROTOCOL is a corrupt marker, not a missing one. Some forms are
    # dropped by the parser (empty variable, line present), others parse into a
    # value the rule rejects (an unbalanced quote stays in the value): both
    # must end in a failure, never in 2.0.
    local bad
    for bad in " export AWG_PROTOCOL='3.1'" "export AWG_PROTOCOL = '3.1'" "AWG_PROTOCOL='3.1" "export  AWG_PROTOCOL='3.1'" "export awg_protocol='3.1'" "export AWG_PROTOCOL=''"; do
        printf '%s\n' "$bad" > "$CONFIG_FILE"
        unset AWG_PROTOCOL
        safe_load_config "$CONFIG_FILE" || true
        run awg_installed_protocol "$CONFIG_FILE"
        [ "$status" -ne 0 ] || { echo "quietly read as 2.0: $bad"; false; }
        [ -z "$output" ]
    done
}

@test "awg_installed_protocol: the fail-closed check survives a large init under pipefail (no SIGPIPE inversion)" {
    # The previous form 'grep -v ... | grep -q' inverted under set -o pipefail
    # once the file exceeded the pipe buffer: grep -q closed the pipe, grep -v
    # died of SIGPIPE, the pipeline failed, and the corrupt marker read as 2.0.
    # 1000 non-comment filler lines of 300 bytes put the unparseable marker
    # well past 64 KiB; without '=' they are cheap for safe_load_config and,
    # unlike comment lines, they DO flow through a 'grep -v comments' stage.
    local filler
    filler=$(printf 'x%.0s' $(seq 1 300))
    { echo "export AWG_PROTOCOL = '3.1'"; for _ in $(seq 1 1000); do echo "$filler"; done; } > "$CONFIG_FILE"
    set -o pipefail
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE" || true
    run awg_installed_protocol "$CONFIG_FILE"
    set +o pipefail
    [ "$status" -ne 0 ] || { echo "guard inverted on a large file"; false; }
    [ -z "$output" ]
}

@test "awg_installed_protocol: CRLF line endings and both quote styles still parse to a valid value" {
    # safe_load_config strips the trailing CR explicitly; double quotes and no
    # quotes at all are legitimate hand-edited forms, not just single quotes.
    local variant
    for variant in "export AWG_PROTOCOL='3.1'"$'\r' 'export AWG_PROTOCOL="3.1"' 'export AWG_PROTOCOL=3.1' 'AWG_PROTOCOL=3.1'; do
        printf '%s\n' "$variant" > "$CONFIG_FILE"
        unset AWG_PROTOCOL
        safe_load_config "$CONFIG_FILE"
        run awg_installed_protocol "$CONFIG_FILE"
        [ "$status" -eq 0 ] || { echo "rejected: $variant"; false; }
        [ "$output" = "3.1" ] || { echo "wrong value for '$variant': $output"; false; }
    done
}

@test "awg_installed_protocol: a trailing space after the closing quote is a corrupt value, not 3.1" {
    # A hand-edit that leaves 'export AWG_PROTOCOL='3.1' ' quote-strips only the
    # leading quote (the trailing character is a space, not a quote), so the
    # parsed value is the garbage "3.1' " - it must fail, not silently become 3.1.
    printf "export AWG_PROTOCOL='3.1' \n" > "$CONFIG_FILE"
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    run awg_installed_protocol "$CONFIG_FILE"
    [ "$status" -ne 0 ] || { echo "accepted trailing-space form as: $output"; false; }
    [ -z "$output" ]
}

@test "awg_installed_protocol: two marker lines with different values fail instead of letting the last one win" {
    printf "export AWG_PROTOCOL='3.1'\nexport AWG_PROTOCOL='2.0'\n" > "$CONFIG_FILE"
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE" || true
    run awg_installed_protocol "$CONFIG_FILE"
    [ "$status" -ne 0 ] || { echo "last-wins accepted: $output"; false; }
    [ -z "$output" ]
}

@test "awg_installed_protocol: another key whose VALUE mentions AWG_PROTOCOL is not a marker" {
    printf "export AWG_SERVER_NAME='AWG_PROTOCOL'\n" > "$CONFIG_FILE"
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    run awg_installed_protocol "$CONFIG_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "installer RU/EN: a 3.1 marker is refused until the 3.1 generator exists (no 2.0 config under a 3.1 label)" {
    local f body assign_line guard_line
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        body=$(initialize_setup_body "$f")
        assign_line=$(echo "$body" | grep -n 'AWG_PROTOCOL=\$(awg_installed_protocol "\$CONFIG_FILE") || die ' | head -1 | cut -d: -f1)
        guard_line=$(echo "$body" | grep -n '^[[:space:]]*if \[\[ "\$AWG_PROTOCOL" == "3.1" \]\]; then$' | head -1 | cut -d: -f1)
        [ -n "$guard_line" ] || { echo "$f: no 3.1 refusal"; false; }
        [ "$guard_line" -gt "$assign_line" ] || { echo "$f: refusal before the assignment"; false; }
        echo "$body" | sed -n "$((guard_line+1))p" | grep -q '^[[:space:]]*die "' || { echo "$f: refusal does not die"; false; }
    done
}

@test "awg_installed_protocol: with the file argument, a comment mentioning AWG_PROTOCOL is not a marker" {
    printf '# AWG_PROTOCOL is written by the installer\nexport AWG_PORT=39743\n' > "$CONFIG_FILE"
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    run awg_installed_protocol "$CONFIG_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

@test "awg_installed_protocol: with the file argument, a missing file still means 2.0" {
    unset AWG_PROTOCOL
    run awg_installed_protocol "$TEST_DIR/does-not-exist.init"
    [ "$status" -eq 0 ]
    [ "$output" = "2.0" ]
}

# ---------- 3. non-migration by paths: structure of initialize_setup ----------

# All re-run paths share initialize_setup(). The marker survives them when it is
# reset before the load, assigned once from the function, never assigned
# elsewhere, and written back verbatim. Checked on both language versions.

initialize_setup_body() {
    sed -n '/^initialize_setup()/,/^}/p' "$1"
}

@test "installer RU: AWG_PROTOCOL is hard-reset BEFORE the init is loaded" {
    local body reset_line load_line
    body=$(initialize_setup_body "$INSTALL_RU")
    reset_line=$(echo "$body" | grep -n '^[[:space:]]*AWG_PROTOCOL=""$' | head -1 | cut -d: -f1)
    load_line=$(echo "$body" | grep -n 'safe_load_config "\$CONFIG_FILE"' | head -1 | cut -d: -f1)
    [ -n "$reset_line" ] || { echo "no hard reset"; false; }
    [ -n "$load_line" ] || { echo "no load"; false; }
    [ "$reset_line" -lt "$load_line" ]
}

@test "installer EN: AWG_PROTOCOL is hard-reset BEFORE the init is loaded" {
    local body reset_line load_line
    body=$(initialize_setup_body "$INSTALL_EN")
    reset_line=$(echo "$body" | grep -n '^[[:space:]]*AWG_PROTOCOL=""$' | head -1 | cut -d: -f1)
    load_line=$(echo "$body" | grep -n 'safe_load_config "\$CONFIG_FILE"' | head -1 | cut -d: -f1)
    [ -n "$reset_line" ] && [ -n "$load_line" ]
    [ "$reset_line" -lt "$load_line" ]
}

@test "modelled initialize_setup: an env AWG_PROTOCOL=3.1 never reaches the file, on a fresh install or an existing 2.0 one" {
    # The structural tests above prove the reset sits before the load in the
    # source; this executes the reset -> load -> assign -> render sequence for
    # real, the way initialize_setup would run it, with the leak attempted from
    # the environment rather than typed into the test.
    export AWG_PROTOCOL="3.1"                     # what a leaking env would set
    AWG_PROTOCOL=""                                # the hard reset
    # (a) fresh install: no init file yet.
    [ "$(awg_installed_protocol "$CONFIG_FILE")" = "2.0" ] || { echo "fresh install saw the env leak"; false; }
    AWG_PROTOCOL=$(awg_installed_protocol "$CONFIG_FILE")
    grep -qx "export AWG_PROTOCOL='2.0'" "$(render_init "$INSTALL_RU")" || { echo "fresh install did not render 2.0"; false; }
    # (b) existing 2.0 install: the init on disk must win over the env, too.
    echo "export AWG_PROTOCOL='2.0'" > "$CONFIG_FILE"
    export AWG_PROTOCOL="3.1"
    AWG_PROTOCOL=""
    safe_load_config "$CONFIG_FILE"
    AWG_PROTOCOL=$(awg_installed_protocol "$CONFIG_FILE")
    [ "$AWG_PROTOCOL" = "2.0" ] || { echo "existing 2.0 install saw the env leak: $AWG_PROTOCOL"; false; }
    unset AWG_PROTOCOL
}

@test "installer RU/EN: the marker is assigned from awg_installed_protocol() with die on failure, after the load" {
    local f body load_line assign_line
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        body=$(initialize_setup_body "$f")
        load_line=$(echo "$body" | grep -n 'safe_load_config "\$CONFIG_FILE"' | head -1 | cut -d: -f1)
        assign_line=$(echo "$body" | grep -n '^[[:space:]]*AWG_PROTOCOL=\$(awg_installed_protocol "\$CONFIG_FILE") || die ' | head -1 | cut -d: -f1)
        [ -n "$assign_line" ] || { echo "no guarded assignment in $f"; false; }
        [ "$assign_line" -gt "$load_line" ] || { echo "assignment before load in $f"; false; }
    done
}

@test "installer RU/EN: nothing else in the whole installer assigns AWG_PROTOCOL" {
    # Exactly three lines may assign the marker: the hard reset, the guarded
    # assignment from the function, and the heredoc line that writes it back.
    # ANY other occurrence of an assignment - at line start, mid-line after a
    # ';', inside an if/then, via printf -v or read - is a path that could
    # rewrite the generation of a live server. The scan is done in bash, not in
    # a grep chain: the file is read line by line, comment lines are skipped,
    # the three known lines are matched exactly, and everything else that still
    # mentions an assignment fails the test.
    local f line n extra
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        n=0; extra=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^[[:space:]]*AWG_PROTOCOL=\"\"$ ]]; then n=$((n+1)); continue; fi
            if [[ "$line" =~ ^[[:space:]]*AWG_PROTOCOL=\$\(awg_installed_protocol\ \"\$CONFIG_FILE\"\)\ \|\|\ die\  ]]; then n=$((n+1)); continue; fi
            if [[ "$line" == "export AWG_PROTOCOL='\${AWG_PROTOCOL}'" ]]; then n=$((n+1)); continue; fi
            if [[ "$line" =~ AWG_PROTOCOL\+?= ]] \
               || [[ "$line" =~ AWG_PROTOCOL:= ]] \
               || [[ "$line" =~ -v[[:space:]]+AWG_PROTOCOL([^A-Za-z0-9_]|$) ]] \
               || [[ "$line" =~ (^|[^A-Za-z0-9_])read[[:space:]].*AWG_PROTOCOL([^A-Za-z0-9_]|$) ]] \
               || [[ "$line" =~ (^|[^A-Za-z0-9_])(unset|local|declare|typeset|readarray|mapfile)[[:space:]]+AWG_PROTOCOL([^A-Za-z0-9_]|$) ]]; then
                extra+="$line"$'\n'
            fi
        done < "$f"
        [ "$n" -eq 3 ] || { echo "$f: expected the 3 known assignment lines, matched $n"; false; }
        [ -z "$extra" ] || { echo "$f: extra assignment(s):"; echo "$extra"; false; }
    done
    # The management script must not assign the marker at all (backup/restore
    # copy the whole init; nothing rewrites the field).
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        extra=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ AWG_PROTOCOL\+?= ]] \
               || [[ "$line" =~ AWG_PROTOCOL:= ]] \
               || [[ "$line" =~ -v[[:space:]]+AWG_PROTOCOL([^A-Za-z0-9_]|$) ]] \
               || [[ "$line" =~ (^|[^A-Za-z0-9_])read[[:space:]].*AWG_PROTOCOL([^A-Za-z0-9_]|$) ]] \
               || [[ "$line" =~ (^|[^A-Za-z0-9_])(unset|local|declare|typeset|readarray|mapfile)[[:space:]]+AWG_PROTOCOL([^A-Za-z0-9_]|$) ]]; then
                extra+="$line"$'\n'
            fi
        done < "$f"
        [ -z "$extra" ] || { echo "$f assigns the marker:"; echo "$extra"; false; }
    done
}

@test "installer RU/EN: the entrypoint calls initialize_setup once, after the idempotency guard and before the step loop" {
    # Every flagged re-run reaches initialize_setup; the flagless re-run on a
    # working server exits at the guard first and never touches the init.
    # Anchored on the guard's own condition (FORCE_REINSTALL), not on the
    # is-active check inside it: an unrelated later is-active check would have
    # made this pass on the wrong line.
    local f n guard_line init_line loop_line
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        n=$(grep -c '^initialize_setup$' "$f")
        [ "$n" -eq 1 ] || { echo "$f: top-level initialize_setup calls = $n"; false; }
        guard_line=$(grep -n '\[\[ "\$FORCE_REINSTALL" -ne 1 \]\]' "$f" | tail -1 | cut -d: -f1)
        init_line=$(grep -n '^initialize_setup$' "$f" | cut -d: -f1)
        loop_line=$(grep -n '^while (( current_step < 99 )); do' "$f" | head -1 | cut -d: -f1)
        [ -n "$guard_line" ] || { echo "$f: no FORCE_REINSTALL guard"; false; }
        [ -n "$loop_line" ] || { echo "$f: no step loop"; false; }
        [ "$guard_line" -lt "$init_line" ] || { echo "$f: guard after initialize_setup"; false; }
        [ "$init_line" -lt "$loop_line" ] || { echo "$f: initialize_setup after the step loop"; false; }
    done
}

# ---------- restore: the one path outside the installer that replaces the init ----------

@test "awg_restore_generation_notice: warns before writing when the backup generation differs" {
    local warned=""
    log_warn() { warned+="$1"; }
    echo "export AWG_PROTOCOL='3.1'" > "$TEST_DIR/backup.init"
    echo "export AWG_PORT=39743" > "$CONFIG_FILE"          # live: pre-marker = 2.0
    run awg_restore_generation_notice "$TEST_DIR/backup.init" "$CONFIG_FILE"
    [ "$status" -eq 0 ]
    warned=""; awg_restore_generation_notice "$TEST_DIR/backup.init" "$CONFIG_FILE"
    [[ "$warned" == *"3.1"* && "$warned" == *"2.0"* ]] || { echo "no warning: [$warned]"; false; }
}

@test "awg_restore_generation_notice: silent when both sides are the same generation, absent field counts as 2.0" {
    local warned=""
    log_warn() { warned+="$1"; }
    echo "export AWG_PORT=1" > "$TEST_DIR/backup.init"      # no field
    echo "export AWG_PROTOCOL='2.0'" > "$CONFIG_FILE"
    awg_restore_generation_notice "$TEST_DIR/backup.init" "$CONFIG_FILE"
    [ -z "$warned" ] || { echo "unexpected warning: $warned"; false; }
    rm -f "$CONFIG_FILE"                                     # live init missing entirely
    awg_restore_generation_notice "$TEST_DIR/backup.init" "$CONFIG_FILE"
    [ -z "$warned" ]
}

@test "awg_restore_generation_notice: a backup WITHOUT an init warns that the marker stays, instead of claiming 2.0" {
    # restore does not touch the live init when the backup has none, so the
    # generation does not become 2.0; saying so would be a confident false fact.
    local warned=""
    log_warn() { warned+="$1"; }
    echo "export AWG_PROTOCOL='3.1'" > "$CONFIG_FILE"
    awg_restore_generation_notice "$TEST_DIR/no-such-backup.init" "$CONFIG_FILE"
    [[ "$warned" == *"3.1"* ]] || { echo "no notice about the kept marker: [$warned]"; false; }
    [[ "$warned" != *"2.0"* ]] || { echo "claims 2.0 for a backup without init: [$warned]"; false; }
}

@test "awg_restore_generation_notice: an unreadable marker warns and prints as ?, even when both sides are unreadable" {
    local warned=""
    log_warn() { warned+="$1"; }
    echo "export AWG_PROTOCOL='yes'" > "$TEST_DIR/backup.init"
    echo "export AWG_PROTOCOL='2.0'" > "$CONFIG_FILE"
    awg_restore_generation_notice "$TEST_DIR/backup.init" "$CONFIG_FILE"
    [[ "$warned" == *"?"* ]] || { echo "no ? in: [$warned]"; false; }
    # both unreadable: "?" == "?" must still warn, silence here would hide a
    # backup whose marker cannot be trusted
    warned=""
    echo "export AWG_PROTOCOL='no'" > "$CONFIG_FILE"
    awg_restore_generation_notice "$TEST_DIR/backup.init" "$CONFIG_FILE"
    [[ "$warned" == *"?"* ]] || { echo "silent when both unreadable"; false; }
}

@test "awg_restore_generation_notice: the helper does not leak AWG_PROTOCOL into the caller" {
    unset AWG_PROTOCOL
    log_warn() { :; }
    echo "export AWG_PROTOCOL='3.1'" > "$TEST_DIR/backup.init"
    echo "export AWG_PROTOCOL='3.1'" > "$CONFIG_FILE"
    awg_restore_generation_notice "$TEST_DIR/backup.init" "$CONFIG_FILE"
    [ -z "${AWG_PROTOCOL:-}" ]
}

@test "awg_restore_generation_notice: RU/EN bodies are identical except the log_warn text" {
    # manage_amneziawg_en.sh runs against the EN copy of awg_common.sh in
    # production; every behavioral test above exercises only the RU body via
    # test_helper's source. This pins that the EN body cannot silently diverge
    # in logic (only the message text is allowed to differ).
    diff <(func_from "$COMMON_RU" awg_restore_generation_notice | grep -v log_warn | tr -d '\r') \
         <(func_from "$COMMON_EN" awg_restore_generation_notice | grep -v log_warn | tr -d '\r')
}

@test "awg_restore_generation_notice (EN body, executed): warns before writing when the backup generation differs" {
    eval "$(func_from "$COMMON_EN" awg_restore_generation_notice)"
    local warned=""
    log_warn() { warned+="$1"; }
    echo "export AWG_PROTOCOL='3.1'" > "$TEST_DIR/backup.init"
    echo "export AWG_PORT=39743" > "$CONFIG_FILE"
    awg_restore_generation_notice "$TEST_DIR/backup.init" "$CONFIG_FILE"
    [[ "$warned" == *"3.1"* && "$warned" == *"2.0"* ]] || { echo "no warning: [$warned]"; false; }
}

@test "awg_restore_generation_notice (EN body, executed): a backup WITHOUT an init keeps the marker, not 2.0" {
    eval "$(func_from "$COMMON_EN" awg_restore_generation_notice)"
    local warned=""
    log_warn() { warned+="$1"; }
    echo "export AWG_PROTOCOL='3.1'" > "$CONFIG_FILE"
    awg_restore_generation_notice "$TEST_DIR/no-such-backup.init" "$CONFIG_FILE"
    [[ "$warned" == *"3.1"* ]] || { echo "no notice about the kept marker: [$warned]"; false; }
    [[ "$warned" != *"2.0"* ]] || { echo "claims 2.0 for a backup without init: [$warned]"; false; }
}

@test "manage RU/EN: restore prints the generation notice BEFORE the service is stopped (still abortable)" {
    # A warning printed inside the destructive phase is a post-mortem, not a
    # signal: the service is already down and the rollback is armed. So the call
    # must sit after the backup completeness check and before systemctl stop.
    local f notice_line stop_line copy_line
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        notice_line=$(grep -n 'awg_restore_generation_notice "\$td/clients/awgsetup_cfg.init" "\$CONFIG_FILE"' "$f" | head -1 | cut -d: -f1)
        stop_line=$(grep -n 'systemctl stop awg-quick@awg0' "$f" | head -1 | cut -d: -f1)
        copy_line=$(grep -n 'cp -a "\$td/clients/"\* "\$AWG_DIR/"' "$f" | head -1 | cut -d: -f1)
        [ -n "$notice_line" ] || { echo "$f: no notice call"; false; }
        [ -n "$stop_line" ] && [ -n "$copy_line" ]
        [ "$notice_line" -lt "$stop_line" ] || { echo "$f: notice after the service stop"; false; }
        [ "$stop_line" -lt "$copy_line" ]
    done
}

@test "manage RU/EN: backup places CONFIG_FILE at exactly the path the restore notice reads back" {
    # The notice call hardcodes "$td/clients/awgsetup_cfg.init"; this is the
    # only thing that keeps that path in sync with where backup actually put
    # the file. If backup ever changes the layout, the notice would silently
    # compare "no file" against the live install and print a false 2.0.
    local f
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        grep -q 'cp -a "\$CONFIG_FILE" "\$td/clients/"' "$f" || { echo "$f: backup does not place the init at \$td/clients/"; false; }
    done
}

@test "manage RU/EN: nothing removes CONFIG_FILE between the notice call and the clients copy" {
    # A stray 'rm' of the live init in that window would make the notice's
    # premise (it read the CURRENT marker) false by the time restore finishes.
    local f notice_line copy_line window
    for f in "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        notice_line=$(grep -n 'awg_restore_generation_notice "\$td/clients/awgsetup_cfg.init"' "$f" | head -1 | cut -d: -f1)
        copy_line=$(grep -n 'cp -a "\$td/clients/"\* "\$AWG_DIR/"' "$f" | head -1 | cut -d: -f1)
        window=$(sed -n "${notice_line},${copy_line}p" "$f" | grep -E 'rm[[:space:]].*(CONFIG_FILE|awgsetup_cfg\.init)' || true)
        [ -z "$window" ] || { echo "$f: CONFIG_FILE removed between notice and copy:"; echo "$window"; false; }
    done
}

@test "installer RU/EN: the init heredoc writes the marker back verbatim, exactly once" {
    local f n
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        n=$(init_heredoc_from "$f" | grep -cx "export AWG_PROTOCOL='\${AWG_PROTOCOL}'")
        [ "$n" -eq 1 ] || { echo "$f: marker line count in heredoc = $n"; false; }
    done
}

# ---------- 3, executed: the heredoc really renders and reads back ----------

@test "rendered init (RU heredoc): a 3.1 marker survives the write and the read" {
    local rendered
    AWG_PROTOCOL="3.1"
    rendered=$(render_init "$INSTALL_RU")
    grep -qx "export AWG_PROTOCOL='3.1'" "$rendered"
    unset AWG_PROTOCOL
    safe_load_config "$rendered"
    [ "$(awg_installed_protocol)" = "3.1" ]
}

@test "rendered init (EN heredoc): a 3.1 marker survives the write and the read" {
    local rendered
    AWG_PROTOCOL="3.1"
    rendered=$(render_init "$INSTALL_EN")
    grep -qx "export AWG_PROTOCOL='3.1'" "$rendered"
    unset AWG_PROTOCOL
    safe_load_config "$rendered"
    [ "$(awg_installed_protocol)" = "3.1" ]
}

@test "rendered init: a pre-marker install is written back as an explicit 2.0, not as a blank" {
    # The load leaves AWG_PROTOCOL empty (no field), the guarded assignment
    # turns it into '2.0', and the heredoc persists that. Modelled exactly:
    # empty -> function -> render -> read.
    local rendered
    create_init_config
    unset AWG_PROTOCOL
    safe_load_config "$CONFIG_FILE"
    AWG_PROTOCOL=$(awg_installed_protocol)
    [ "$AWG_PROTOCOL" = "2.0" ]
    rendered=$(render_init "$INSTALL_RU")
    grep -qx "export AWG_PROTOCOL='2.0'" "$rendered"
}

@test "rendered init: the marker is written as the LAST line of the heredoc" {
    local f last
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        last=$(init_heredoc_from "$f" | grep -v '^EOF$' | grep -v '^[[:space:]]*#' | tail -1)
        [ "$last" = "export AWG_PROTOCOL='\${AWG_PROTOCOL}'" ] || { echo "$f last heredoc line: $last"; false; }
    done
}
