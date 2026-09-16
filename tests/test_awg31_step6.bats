#!/usr/bin/env bats
# Step 6 of the installer on a 3.1 install: the order of the checks, what is
# fatal, and what a refusal leaves behind.
#
# The real step6_generate_configs from each installer runs here against a stub
# library that records every call. The checks themselves are tested in
# test_awg31_first_install.bats and test_awg31_artifacts.bats; this file tests
# the wiring:
# - on 3.1 the tools and the leftovers are checked before the first change;
# - a client that fails, an incomplete set of files or a failed validation
#   stops the install, and the folder goes back to what it was before the
#   attempt: the files of the clients made by this attempt are removed, the
#   server config comes back from its backup (or is removed on a first
#   install), the server keys and the header protection key stay;
# - a default client that already exists in the server config is neither
#   refused as a leftover nor recreated;
# - on 2.0, and with an unreadable marker, the step 6 wiring is the old one
#   (what the real renderers do with such a marker is tested in
#   test_awg31_render.bats).

# step6_run <installer> <setup snippet> ; env STUB_* chooses the failures.
step6_run() {
    local src="$1" setup="$2" d stub
    d="$BATS_TEST_TMPDIR/s6-$(basename "$src" .sh)"
    rm -rf "$d"; mkdir -p "$d/awg"
    stub="$d/stub_common.sh"
    cat > "$stub" <<'EOF'
_call() { printf '%s\n' "$*" >> "$CALLS"; }
# Answers STUB_GEN only for the init file: a call pointed at any other file
# would read no marker and the real function would answer 2.0.
_awg_generation_from_init() {
    if [[ "${1:-}" != "$CONFIG_FILE" ]]; then
        printf '2.0\n'
        return 0
    fi
    [[ "$STUB_GEN" == broken ]] && return 1
    printf '%s\n' "$STUB_GEN"
}
_awg31_require_client_tools() { _call tools; [[ -z "${STUB_FAIL_TOOLS:-}" ]]; }
_awg31_refuse_client_leftovers() { _call "leftovers $*"; [[ -z "${STUB_FAIL_LEFT:-}" ]]; }
awg_hpk_ensure() { _call "ensure $*"; }
generate_server_keys() { _call serverkeys; : > "$AWG_DIR/server_private.key"; }
render_server_config() {
    _call render
    {
        printf '[Interface]\nPrivateKey = NEW\n'
        if [[ -n "${1:-}" && -f "$1" ]]; then
            awk '/^\[Peer\]/{p=1} p' "$1"
        fi
    } > "$SERVER_CONF_FILE"
}
generate_client() {
    local n="$1"
    _call "client $n"
    # C6 of the real function: an existing client is refused, nothing touched.
    if [[ -e "$KEYS_DIR/$n.private" || -e "$KEYS_DIR/$n.public" || -e "$AWG_DIR/$n.conf" ]]; then
        return 1
    fi
    : > "$KEYS_DIR/$n.private"
    if [[ "$n" == "${STUB_FAIL_CLIENT:-}" ]]; then
        return 1
    fi
    : > "$KEYS_DIR/$n.public"
    local f
    for f in conf png vpnuri vpnuri.png; do printf 'x' > "$AWG_DIR/$n.$f"; done
    printf '\n[Peer]\n#_Name = %s\n' "$n" >> "$SERVER_CONF_FILE"
}
awg_client_artifacts_check() { _call "artifacts $1"; [[ "$1" != "${STUB_FAIL_ARTIFACTS:-}" ]]; }
validate_awg_config() { _call validate; [[ -z "${STUB_FAIL_VALIDATE:-}" ]]; }
secure_files() { _call secure; }
EOF
    # The real remover: the test must see what it actually deletes.
    awk '/^_remove_client_files\(\) \{/,/^\}/' "$BATS_TEST_DIRNAME/../awg_common.sh" >> "$stub"
    # Pre-existing state of the install: server keys and the key file are
    # already there, as they are after awg_hpk_ensure on a first 3.1 install.
    mkdir -p "$d/awg/keys"
    : > "$d/awg/server_private.key"
    printf 'HPK\n' > "$d/awg/server_hpk.key"
    AWG_DIR="$d/awg" eval "$setup"
    AWG_DIR="$d/awg" KEYS_DIR="$d/awg/keys" SERVER_CONF_FILE="$d/awg/awg0.conf" \
    CONFIG_FILE="$d/awg/awgsetup_cfg.init" COMMON_SCRIPT_PATH="$stub" CALLS="$d/calls" \
    LOG_FILE="$d/log" timeout 60 bash -c '
        : > "$CALLS"
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        die() { echo "DIE: $*"; exit 1; }
        update_state() { printf "state %s\n" "$1" >> "$CALLS"; }
        if [[ -n "${STUB_FAIL_CP:-}" ]]; then cp() { return 1; }; fi
        # Fails only the restore copy of the undo, which is the one made with -p,
        # after writing part of the destination, as an I/O error would.
        if [[ -n "${STUB_FAIL_RESTORE:-}" ]]; then
            cp() { if [[ "$1" == -p ]]; then printf "partial" > "${!#}"; return 1; fi; command cp "$@"; }
        fi
        eval "$(awk "/^_step6_undo_31\\(\\) \\{/,/^\\}/" "$1")"
        eval "$(awk "/^step6_generate_configs\\(\\) \\{/,/^\\}/" "$1")"
        declare -F step6_generate_configs >/dev/null || { echo NO_STEP6; exit 7; }
        step6_generate_configs
        echo "RC=$?"
    ' _ "$src"
}

s6_dir() { echo "$BATS_TEST_TMPDIR/s6-$(basename "$1" .sh)/awg"; }
s6_calls() { grep -v '^state 6$' "$BATS_TEST_TMPDIR/s6-$(basename "$1" .sh)/calls" | paste -sd'|' -; }

both() {
    local seen=0 src
    for src in install_amneziawg.sh install_amneziawg_en.sh; do
        "$1" "$BATS_TEST_DIRNAME/../$src" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

# The folder after a refused attempt on a FIRST install: nothing of the
# attempt is left, the keys are.
s6_first_install_rolled_back() {
    local src="$1" out="$2" d n f
    d=$(s6_dir "$src")
    [[ "$out" == *"DIE:"* ]] || { echo "the failure did not stop step 6 ($src): $out"; return 1; }
    [[ "$out" != *"RC=0"* ]] || { echo "step 6 finished after a failure ($src): $out"; return 1; }
    ! grep -qx 'state 7' "$(dirname "$d")/calls" || { echo "state 7 was written after a failure ($src)"; return 1; }
    ! grep -qx 'secure' "$(dirname "$d")/calls" || { echo "step 6 went on past the failure ($src): $(s6_calls "$src")"; return 1; }
    [ ! -e "$d/awg0.conf" ] || { echo "the server config of the failed first install was left ($src)"; return 1; }
    for n in my_phone my_laptop; do
        for f in "$d/$n.conf" "$d/$n.png" "$d/$n.vpnuri" "$d/$n.vpnuri.png" "$d/keys/$n.private" "$d/keys/$n.public"; do
            [ ! -e "$f" ] || { echo "a file of the failed attempt was left: $f ($src)"; return 1; }
        done
    done
    [ -e "$d/server_private.key" ] || { echo "the server key was removed ($src)"; return 1; }
    [ "$(cat "$d/server_hpk.key")" = "HPK" ] || { echo "the header protection key was removed or changed ($src)"; return 1; }
}

# ---------- the order on 3.1 and on 2.0 ----------

t_31_order() {
    local src="$1" out want
    out=$(STUB_GEN=3.1 step6_run "$src" ':')
    [[ "$out" == *"RC=0"* ]] || { echo "a clean 3.1 run failed ($src): $out"; return 1; }
    want="tools|leftovers my_phone my_laptop|ensure install|render|client my_phone|client my_laptop|artifacts my_phone|artifacts my_laptop|validate|secure|state 7"
    [ "$(s6_calls "$src")" = "$want" ] || { echo "3.1 order ($src):"; echo " got  $(s6_calls "$src")"; echo " want $want"; return 1; }
}
@test "step 6 on 3.1: tools and leftovers before the key, every set checked, validation last, both twins" {
    both t_31_order
}

t_20_order() {
    local src="$1" out gen want
    want="ensure install|render|client my_phone|client my_laptop|validate|secure|state 7"
    for gen in 2.0 broken; do
        out=$(STUB_GEN=$gen step6_run "$src" ':')
        [[ "$out" == *"RC=0"* ]] || { echo "a clean $gen run failed ($src): $out"; return 1; }
        [ "$(s6_calls "$src")" = "$want" ] || { echo "$gen order changed ($src):"; echo " got  $(s6_calls "$src")"; echo " want $want"; return 1; }
    done
}
@test "step 6 on 2.0 and with an unreadable marker: the sequence is unchanged, both twins" {
    both t_20_order
}

t_20_failures_stay_warnings() {
    local src="$1" out
    out=$(STUB_GEN=2.0 STUB_FAIL_CLIENT=my_phone STUB_FAIL_VALIDATE=1 step6_run "$src" ':')
    [[ "$out" == *"RC=0"* ]] || { echo "a 2.0 client or validation failure became fatal ($src): $out"; return 1; }
    [[ "$out" == *"WARN:"*"my_phone"* ]] || { echo "the 2.0 client failure is no longer reported ($src): $out"; return 1; }
    grep -qx 'client my_laptop' "$(dirname "$(s6_dir "$src")")/calls" || { echo "2.0 stopped at the first failed client ($src)"; return 1; }
}
@test "step 6 on 2.0: a failed client and a failed validation stay warnings, both twins" {
    both t_20_failures_stay_warnings
}

# ---------- refusals before the first change ----------

t_31_refused_before_changes() {
    local src="$1" out var calls
    for var in STUB_FAIL_TOOLS STUB_FAIL_LEFT; do
        out=$(export STUB_GEN=3.1 "$var=1"; step6_run "$src" ':')
        [[ "$out" == *"DIE:"* ]] || { echo "$var did not stop step 6 ($src): $out"; return 1; }
        calls=$(s6_calls "$src")
        [[ "$calls" != *ensure* && "$calls" != *render* && "$calls" != *client* ]] || { echo "$var: step 6 changed things before refusing ($src): $calls"; return 1; }
        [ ! -e "$(s6_dir "$src")/awg0.conf" ] || { echo "$var: a server config appeared ($src)"; return 1; }
    done
}
@test "step 6 on 3.1: missing tools or leftovers stop it before the key and the render, both twins" {
    both t_31_refused_before_changes
}

# ---------- failures after the render: back to the state before the attempt ----------

t_31_first_install_failures() {
    local src="$1" out var
    for var in STUB_FAIL_CLIENT=my_laptop STUB_FAIL_CLIENT=my_phone STUB_FAIL_ARTIFACTS=my_laptop STUB_FAIL_VALIDATE=1; do
        out=$(export STUB_GEN=3.1 "${var?}"; step6_run "$src" ':')
        s6_first_install_rolled_back "$src" "$out" || { echo " (case $var)"; return 1; }
    done
}
@test "step 6 on 3.1: a failed client, an incomplete set or a failed validation undo the first install, both twins" {
    both t_31_first_install_failures
}

# A rerun over an install whose config already carries my_phone.
S6_EXISTING='
    printf "[Interface]\nPrivateKey = OLD\n\n[Peer]\n#_Name = my_phone\nPublicKey = P\n" > "$AWG_DIR/awg0.conf"
    cp "$AWG_DIR/awg0.conf" "$AWG_DIR/awg0.conf.orig"
    : > "$AWG_DIR/keys/my_phone.private"; : > "$AWG_DIR/keys/my_phone.public"
    for f in conf png vpnuri vpnuri.png; do printf "old" > "$AWG_DIR/my_phone.$f"; done
'

t_31_rerun_existing_client() {
    local src="$1" out want
    out=$(STUB_GEN=3.1 step6_run "$src" "$S6_EXISTING")
    [[ "$out" == *"RC=0"* ]] || { echo "a rerun with an existing default client was refused ($src): $out"; return 1; }
    want="tools|leftovers my_laptop|ensure install|render|client my_laptop|artifacts my_laptop|validate|secure|state 7"
    [ "$(s6_calls "$src")" = "$want" ] || { echo "rerun order ($src):"; echo " got  $(s6_calls "$src")"; echo " want $want"; return 1; }
}
@test "step 6 on 3.1: a default client already in the config is not a leftover and is not recreated, both twins" {
    both t_31_rerun_existing_client
}

t_31_rerun_failure_restores() {
    local src="$1" out d f
    out=$(STUB_GEN=3.1 STUB_FAIL_VALIDATE=1 step6_run "$src" "$S6_EXISTING")
    d=$(s6_dir "$src")
    [[ "$out" == *"DIE:"* ]] || { echo "a failed rerun did not stop ($src): $out"; return 1; }
    cmp -s "$d/awg0.conf" "$d/awg0.conf.orig" || { echo "the server config was not restored from its backup ($src): $(cat "$d/awg0.conf" 2>&1)"; return 1; }
    for f in conf png vpnuri vpnuri.png; do
        [ "$(cat "$d/my_phone.$f")" = "old" ] || { echo "the existing client lost my_phone.$f ($src)"; return 1; }
    done
    [ -e "$d/keys/my_phone.private" ] || { echo "the existing client lost its key ($src)"; return 1; }
    for f in "$d/my_laptop.conf" "$d/keys/my_laptop.private"; do
        [ ! -e "$f" ] || { echo "the new client of the failed attempt was left: $f ($src)"; return 1; }
    done
}
@test "step 6 on 3.1: a failed rerun restores the server config and keeps the existing client, both twins" {
    both t_31_rerun_failure_restores
}

t_31_backup_failure() {
    local src="$1" out calls
    out=$(STUB_GEN=3.1 STUB_FAIL_CP=1 step6_run "$src" "$S6_EXISTING")
    [[ "$out" == *"DIE:"* ]] || { echo "a failed backup did not stop a 3.1 rerun ($src): $out"; return 1; }
    calls=$(s6_calls "$src")
    [[ "$calls" != *render* ]] || { echo "the config was rewritten without a backup to undo to ($src): $calls"; return 1; }
    cmp -s "$(s6_dir "$src")/awg0.conf" "$(s6_dir "$src")/awg0.conf.orig" || { echo "the server config changed ($src)"; return 1; }
}
@test "step 6 on 3.1: without a backup of the server config nothing is rewritten, both twins" {
    both t_31_backup_failure
}

t_31_checks_before_server_keys() {
    local src="$1" out calls var
    for var in STUB_FAIL_TOOLS STUB_FAIL_LEFT; do
        out=$(export STUB_GEN=3.1 "$var=1"; step6_run "$src" 'rm -f "$AWG_DIR/server_private.key"')
        [[ "$out" == *"DIE:"* ]] || { echo "$var did not stop step 6 ($src): $out"; return 1; }
        calls=$(s6_calls "$src")
        [[ "$calls" != *serverkeys* ]] || { echo "$var: server keys were generated before the refusal ($src): $calls"; return 1; }
    done
    out=$(STUB_GEN=3.1 step6_run "$src" 'rm -f "$AWG_DIR/server_private.key"')
    [[ "$out" == *"RC=0"* ]] || { echo "a first 3.1 install without server keys failed ($src): $out"; return 1; }
    [[ "$(s6_calls "$src")" == "tools|leftovers my_phone my_laptop|serverkeys|ensure install|"* ]] \
        || { echo "the checks do not precede the server keys ($src): $(s6_calls "$src")"; return 1; }
}
@test "step 6 on 3.1: the checks run before the server keys are generated, both twins" {
    both t_31_checks_before_server_keys
}

# A name comment outside any peer block: the old config seems to carry my_phone,
# the render does not keep it. Files of my_phone that existed before the attempt
# must survive whatever happens next.
S6_STRAY_NAME='
    printf "[Interface]\nPrivateKey = OLD\n#_Name = my_phone\n" > "$AWG_DIR/awg0.conf"
    cp "$AWG_DIR/awg0.conf" "$AWG_DIR/awg0.conf.orig"
    : > "$AWG_DIR/keys/my_phone.private"; : > "$AWG_DIR/keys/my_phone.public"
    for f in conf png vpnuri vpnuri.png; do printf "old" > "$AWG_DIR/my_phone.$f"; done
'

t_31_stray_name_keeps_files() {
    local src="$1" out d f
    out=$(STUB_GEN=3.1 step6_run "$src" "$S6_STRAY_NAME")
    d=$(s6_dir "$src")
    [[ "$out" == *"DIE:"* ]] || { echo "a client lost by the render did not stop a 3.1 install ($src): $out"; return 1; }
    for f in conf png vpnuri vpnuri.png; do
        [ "$(cat "$d/my_phone.$f" 2>/dev/null)" = "old" ] || { echo "a file that existed before the attempt was removed: my_phone.$f ($src)"; return 1; }
    done
    [ -e "$d/keys/my_phone.private" ] && [ -e "$d/keys/my_phone.public" ] || { echo "the keys of my_phone were removed ($src)"; return 1; }
    cmp -s "$d/awg0.conf" "$d/awg0.conf.orig" || { echo "the server config was not restored ($src)"; return 1; }
}
@test "step 6 on 3.1: files that existed before the attempt are never removed by the undo, both twins" {
    both t_31_stray_name_keeps_files
}

t_31_restore_failure_keeps_config() {
    local src="$1" out d
    out=$(STUB_GEN=3.1 STUB_FAIL_VALIDATE=1 STUB_FAIL_RESTORE=1 step6_run "$src" "$S6_EXISTING")
    d=$(s6_dir "$src")
    [[ "$out" == *"DIE:"* ]] || { echo "a failed rerun did not stop ($src): $out"; return 1; }
    [[ "$out" == *"ERR:"* ]] || { echo "a failed restore was not reported ($src): $out"; return 1; }
    grep -q '^PrivateKey = NEW$' "$d/awg0.conf" || { echo "a failed restore damaged the server config ($src): $(cat "$d/awg0.conf" 2>&1)"; return 1; }
    [ -z "$(find "$d" -maxdepth 1 -name 'awg0.conf.restore.*')" ] || { echo "a temporary restore file was left ($src)"; return 1; }
}
@test "step 6 on 3.1: a restore that fails midway does not damage the server config, both twins" {
    both t_31_restore_failure_keeps_config
}
