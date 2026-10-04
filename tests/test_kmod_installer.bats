#!/usr/bin/env bats
# Installer side of the kernel 7.0 module fix (track K): the install_packages
# fallback (T1), the step 2 wiring (early helper, T1', T2) and the
# --repair-module entry point for installed servers. The helper itself is
# covered in test_kmod_helper.bats; here it is a stub. Every case runs on
# both installers: their functions differ in messages, so one cannot stand in
# for the other.

load test_helper

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

_fn() { sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"; }
_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
_st() { mkdir -p "$T/st"; printf '%s' "$2" > "$T/st/$1"; }   # dpkg status of a package
_calls() { cat "$T/calls" 2>/dev/null || true; }
_reset() { rm -rf "$T/st" "$T/calls" "$T"/helper.* "$T/log" "$T/dkms" "$T/src" "$T/owner" "$T/busy" "$T/units.fail" "$T/kmodlist" "$T/holds" "$T"/*.fail; mkdir -p "$T/st"; }

setup() {
    T=$(mktemp -d); export T
    mkdir -p "$T/bin" "$T/st"
    _stub uname 'echo 7.0.0-38-generic'
    _stub apt 'echo "apt $*" >> "$T/calls"; exit 100'
    # dpkg-query: kmod.fail breaks the pattern query, dkms.fail the query of
    # amneziawg-dkms; an unknown package answers the way dpkg-query does.
    _stub dpkg-query 'p="${*: -1}"
if [[ "$p" == *"*"* ]]; then
  [[ -e "$T/kmod.fail" ]] && { echo "dpkg-query: error: database locked" >&2; exit 2; }
  [[ -s "$T/kmodlist" ]] && { cat "$T/kmodlist"; exit 0; }
  echo "dpkg-query: no packages found matching $p" >&2; exit 1
fi
[[ "$p" == amneziawg-dkms && -e "$T/dkms.fail" ]] && { echo "dpkg-query: error: database locked" >&2; exit 2; }
[[ -f "$T/st/$p" ]] || { echo "dpkg-query: no packages found matching $p" >&2; exit 1; }
cat "$T/st/$p"'
    _stub apt-mark '[[ "$1" == showhold ]] || exit 0
[[ -e "$T/am.fail" ]] && { echo "E: cannot read the selections" >&2; exit 100; }
cat "$T/holds" 2>/dev/null; exit 0'
    _stub dpkg '[[ "$1" == -S ]] || echo "dpkg $*" >> "$T/calls"
if [[ "$1" == -S ]]; then cat "$T/owner" 2>/dev/null || exit 1; fi
exit 0'
    # The helper stub: records the call, prints helper.out.<mode>, exits
    # helper.rc.<mode>; --finish "configures" every package not marked .keep.
    _stub helper 'echo "helper $*" >> "$T/calls"; cat "$T/helper.out.$1" 2>/dev/null
rc=$(cat "$T/helper.rc.$1" 2>/dev/null || echo 0)
if [[ "$1" == --finish && "$rc" == 0 ]]; then
  for f in "$T"/st/*; do [[ "$f" == *.keep || -e "$f.keep" ]] || echo "install ok installed" > "$f"; done
fi
exit "$rc"'
    # Real installers run in this file believe they are not root.
    _stub id 'if [[ "$1" == -u ]]; then echo 1000; else /usr/bin/id "$@"; fi'
    export PATH="$T/bin:$PATH"
}

teardown() { rm -rf "$T"; }

# ---------- T1: the install_packages fallback ----------

# A driver that runs install_packages from installer $1 with the T1 flag $2.
_t1_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 1; }'
        echo 'apt_update_tolerant() { :; }; _install_temp_files=(); _APT_UPDATED=1'
        echo "AWG_ENSURE_HELPER=$T/bin/helper; _AWG_KMOD_T1=$2; LOG_FILE=$T/log"
        _fn "$1" _pkg_present; _fn "$1" _pkg_installed_ok; _fn "$1" _pkgs_installed_ok; _fn "$1" install_packages
        echo 'install_packages "$@"'
    } > "$T/drv.sh"
}

@test "T1: a failed apt with the module package unpacked: --repair, --finish, packages checked, output in the log" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; _st qrencode "unknown ok not-installed"
        echo "kernel 7.0.0-38-generic: module built" > "$T/helper.out.--repair"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms qrencode
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [ "$(_calls | grep -c '^helper')" -eq 2 ]
        [[ "$(_calls)" == *"helper --repair"*"helper --finish"* ]] || { echo "$f: $(_calls)"; return 1; }
        [[ "$(_calls)" != *"dpkg --configure"* ]] || { echo "$f: configure bypassed --finish"; return 1; }
        grep -q 'kernel 7.0.0-38-generic: module built' "$T/log" || { echo "$f: helper output not in the log"; return 1; }
    done
}

@test "T1: success repeats what matters before a reboot" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"
        echo "[ts] [--finish] WARN: already configured kernel(s) without the AmneziaWG module: 6.8.0-31-generic; booting ..." > "$T/helper.out.--finish"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        grep -q '^WARN: .*: WARN: already configured kernel(s) without the AmneziaWG module: 6\.8\.0-31-generic' <<<"$output" || { echo "$f: $output"; return 1; }
    done
}

@test "T1: enabled by the package state, not by the requested list" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok half-configured"; _st qrencode "unknown ok not-installed"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" qrencode
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [[ "$(_calls)" == *"helper --repair"* ]]
    done
}

@test "T1: off outside the PPA/DKMS path of step 2 (ARM prebuilt, pinned 2.0, other steps)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"
        _t1_driver "$f" 0
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 1 ]; [[ "$output" == *DIE:* ]]
        [[ "$(_calls)" != *helper* ]] || { echo "$f: helper called"; return 1; }
    done
}

@test "T1: a package left as config-files does not enable it" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "deinstall ok config-files"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 1 ]
        [[ "$(_calls)" != *helper* ]]
    done
}

@test "T1: the running kernel without a module (helper exit 2): failure, --finish is not run" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; echo 2 > "$T/helper.rc.--repair"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 1 ]
        [[ "$(_calls)" != *"--finish"* ]] || { echo "$f"; return 1; }
    done
}

@test "T1: helper exit 1 (another kernel failed) still finishes the install, and names that kernel" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; echo 1 > "$T/helper.rc.--repair"
        echo "[ts] [--repair] kernel 6.8.0-31-generic: NOT built (dkms rc=10); log: /x" > "$T/helper.out.--repair"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        # The warning line itself, not the helper's own line that also names the kernel.
        grep -q '^WARN: .*6\.8\.0-31-generic - ' <<<"$output" || { echo "$f: $output"; return 1; }
    done
}

@test "T1: a refused --finish is a failure" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; echo 1 > "$T/helper.rc.--finish"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 1 ] || { echo "$f"; return 1; }
    done
}

@test "T1: the known-issue line gives the exact reason and the kernel that failed" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; echo 2 > "$T/helper.rc.--repair"
        echo "[ts] [--repair] kernel 7.0.0-39-generic: NOT built [known-issue:kernel-70-udp-tunnel]: ..." > "$T/helper.out.--repair"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 1 ]
        [[ "$output" == *"DIE: "*"7.0.0-39-generic"*"setup_udp_tunnel_sock"*"kernel-70-backport-adv"* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "T1: helper exit 1 with no kernel named still warns (the source fix or depmod failed)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; echo 1 > "$T/helper.rc.--repair"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        grep -q '^WARN: .*(.*depmod)' <<<"$output" || { echo "$f: $output"; return 1; }
    done
}

@test "T1: without a saved helper output the warning does not guess the cause" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; echo 1 > "$T/helper.rc.--repair"
        _stub mktemp 'exit 1'
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        rm -f "$T/bin/mktemp"
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        grep -q '^WARN: .*, details above\.$\|^WARN: .*, подробности выше\.$' <<<"$output" || { echo "$f: $output"; return 1; }
        ! grep -q '^WARN: .*depmod' <<<"$output" || { echo "$f: guessed the cause: $output"; return 1; }
    done
}

@test "T1: a --finish refusal over an unfinished kernel names it and the way out" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; echo 1 > "$T/helper.rc.--finish"
        echo "[ts] [--finish] unfinished kernel(s) without the AmneziaWG module: 7.0.0-39-generic" > "$T/helper.out.--finish"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 1 ]
        [[ "$output" == *"DIE: "*"7.0.0-39-generic"*"--repair-module"* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "T1: the known issue of another kernel is not given as the reason when packages failed" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; _st qrencode "unknown ok not-installed"; : > "$T/st/qrencode.keep"
        echo 1 > "$T/helper.rc.--repair"
        echo "[ts] [--repair] kernel 7.0.0-39-generic: NOT built [known-issue:kernel-70-udp-tunnel]: ..." > "$T/helper.out.--repair"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms qrencode
        [ "$status" -eq 1 ]
        [[ "$output" != *"DIE: "*"setup_udp_tunnel_sock"* ]] || { echo "$f: $output"; return 1; }
        # It stops on the package check, not on something unrelated.
        [[ "$output" == *"DIE: Ошибка установки пакетов."* || "$output" == *"DIE: Package installation error."* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "T1: configure succeeded but a requested package is still missing: failure" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _reset; _st amneziawg-dkms "install ok unpacked"; _st qrencode "unknown ok not-installed"; : > "$T/st/qrencode.keep"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms qrencode
        [ "$status" -eq 1 ] || { echo "$f"; return 1; }
        [[ "$output" == *DIE:* ]]
    done
}

@test "T1: the flag is reset at start, so the environment cannot switch the fallback on" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _head_through_check "$f"
        run env _AWG_KMOD_T1=1 timeout 20 bash "$T/head.sh" --repair-module </dev/null
        [ "$status" -eq 0 ] || { echo "$f: $status $output"; return 1; }
        [[ "$output" == *"PASSED-CHECK repair=1 verbose=0 t1=0"* ]] || { echo "$f: $output"; return 1; }
    done
}

# ---------- step 2 wiring (structure) ----------

_step2() { _fn "$1" step2_install_amnezia; }
_line() { grep -n -m1 -x -F -- "$2" <<<"$1" | cut -d: -f1; }
# Depth of 4-space-indented if-blocks open right before line $2 of text $1.
_depth() { sed -n "1,$(( $2 - 1 ))p" <<<"$1" | awk '/^    if .*then$/ {d++} /^    fi$/ {d--} END {print d+0}'; }

@test "step 2: the helper is deployed unconditionally, before the first package install of the DKMS path" {
    local f s dep gcc pk arm
    for f in "${INSTALLERS[@]}"; do
        s=$(_step2 "$f")
        dep=$(_line "$s" '    _awg_deploy_ensure_helper')
        gcc=$(grep -n -m1 -F 'apt install -y gcc-13' <<<"$s" | cut -d: -f1)
        pk=$(_line "$s" '    install_packages "${packages[@]}"')
        arm=$(grep -n -m1 -F 'request_reboot 3' <<<"$s" | cut -d: -f1)
        [ -n "$dep" ] && [ -n "$gcc" ] && [ -n "$pk" ] && [ -n "$arm" ] || { echo "$f: dep=$dep gcc=$gcc pk=$pk arm=$arm"; return 1; }
        [ "$arm" -lt "$dep" ] && [ "$dep" -lt "$gcc" ] && [ "$dep" -lt "$pk" ] || { echo "$f: arm=$arm dep=$dep gcc=$gcc pk=$pk"; return 1; }
        [ "$(_depth "$s" "$dep")" -eq 0 ] || { echo "$f: the deploy is inside an if"; return 1; }
    done
}

@test "step 2: T1 is switched on inside the non-pinned block, before the package install, and off right after" {
    local f s on off pk guard
    for f in "${INSTALLERS[@]}"; do
        s=$(_step2 "$f")
        [ "$(grep -c '_AWG_KMOD_T1=1' <<<"$s")" -eq 1 ]
        on=$(grep -n -m1 '_AWG_KMOD_T1=1' <<<"$s" | cut -d: -f1)
        off=$(_line "$s" '    _AWG_KMOD_T1=0')
        pk=$(_line "$s" '    install_packages "${packages[@]}"')
        [ "$on" -lt "$pk" ] && [ "$pk" -lt "$off" ] || { echo "$f: on=$on pk=$pk off=$off"; return 1; }
        # the nearest 4-space if above the switch is the non-pinned guard, still open
        guard=$(sed -n "1,${on}p" <<<"$s" | grep -n '^    if ' | tail -n1)
        [[ "$guard" == *'if [[ "$use_pinned_awg2" -eq 0 ]]; then' ]] || { echo "$f: $guard"; return 1; }
        [ "$(sed -n "${guard%%:*},${on}p" <<<"$s" | grep -c '^    fi$')" -eq 0 ] || { echo "$f: the guard is closed before the switch"; return 1; }
    done
}

@test "step 2: the proactive --prepare (T2) runs after the packages and before the headers meta-package" {
    local f s pk meta blk
    for f in "${INSTALLERS[@]}"; do
        s=$(_step2 "$f")
        pk=$(_line "$s" '    install_packages "${packages[@]}"')
        meta=$(grep -n -m1 -F 'for meta in "${meta_candidates[@]}"' <<<"$s" | cut -d: -f1)
        [ -n "$pk" ] && [ -n "$meta" ] && [ "$pk" -lt "$meta" ]
        # Right after the package install: the non-pinned guard, and the
        # --prepare call inside it (not merely a matching line somewhere).
        [ "$(sed -n "$((pk + 1))p" <<<"$s")" = '    if [[ "$use_pinned_awg2" -eq 0 ]]; then' ] || { echo "$f: no guard after install_packages"; return 1; }
        blk=$(sed -n "$((pk + 2)),\$p" <<<"$s" | sed '/^    fi$/q')
        [[ "$blk" == *'"$AWG_ENSURE_HELPER" --prepare'* ]] || { echo "$f: --prepare not in the block"; return 1; }
        [ "$(sed -n "1,${pk}p" <<<"$s" | grep -c -F '"$AWG_ENSURE_HELPER" --prepare')" -eq 1 ] || { echo "$f: extra --prepare before install"; return 1; }
    done
}

@test "step 2: the hook, logrotate and unit are still deployed in step 2" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _step2 "$f" | grep -qx '    _awg_deploy_ensure_units || true'
    done
}

# ---------- _awg_dpkg_busy and _awg_kmod_prebuilt_present, executed ----------

_busy() { # installer -> exit code of _awg_dpkg_busy with the fake /proc
    bash -c 'eval "$1"; AWG_PROC_DIR="$2/proc"; AWG_DPKG_DIR="$2/dpkg"; _awg_dpkg_busy' _ "$(_fn "$1" _awg_dpkg_busy)" "$T"
}

@test "_awg_dpkg_busy: idle, busy on either lock file, and 'cannot check' counts as busy" {
    [[ $EUID -ne 0 ]] || skip "root reads a mode-000 directory anyway"
    local f l
    for f in "${INSTALLERS[@]}"; do
        rm -rf "$T/proc"; mkdir -p "$T/proc/1/fd"
        run _busy "$f"; [ "$status" -eq 1 ] || { echo "$f idle: $status"; return 1; }
        for l in lock-frontend lock; do
            ln -sfn "$T/dpkg/$l" "$T/proc/1/fd/5"
            run _busy "$f"; [ "$status" -eq 0 ] || { echo "$f $l: $status"; return 1; }
        done
        rm -rf "$T/proc"; mkdir -p "$T/proc"
        run _busy "$f"; [ "$status" -eq 0 ] || { echo "$f empty proc: $status"; return 1; }
        mkdir -p "$T/proc/1/fd" "$T/proc/7/fd"; chmod 000 "$T/proc/7/fd"
        run _busy "$f"; chmod 700 "$T/proc/7/fd"
        [ "$status" -eq 0 ] || { echo "$f unreadable fd: $status"; return 1; }
    done
}

@test "_awg_kmod_prebuilt_present: an installed prebuilt counts, a removed one does not" {
    local f
    for f in "${INSTALLERS[@]}"; do
        echo "amneziawg-kmod-6.12.0-rpi install ok installed" > "$T/kmodlist"
        run bash -c 'eval "$1"; _awg_kmod_prebuilt_present' _ "$(_fn "$f" _awg_kmod_prebuilt_present)"
        [ "$status" -eq 0 ]
        echo "amneziawg-kmod-6.12.0-rpi deinstall ok config-files" > "$T/kmodlist"
        run bash -c 'eval "$1"; _awg_kmod_prebuilt_present' _ "$(_fn "$f" _awg_kmod_prebuilt_present)"
        [ "$status" -eq 1 ]
    done
}

# ---------- --repair-module: arguments ----------

# The installer is NOT run whole here: if the check ever broke, a whole run
# would go on to whatever the other flag asks for (--uninstall included) and
# wait on the terminal. Only the head of the script runs - from the first line
# through the end of the --repair-module check - followed by a marker.
_head_through_check() { # installer -> $T/head.sh
    awk '{print} /^if \[\[ "\$REPAIR_MODULE" -eq 1 \]\]; then$/ {c=1} c && /^fi$/ {exit}' \
        "$BATS_TEST_DIRNAME/../$1" > "$T/head.sh"
    grep -q '^    unset _a$' "$T/head.sh" || { echo "$1: the check block was not found"; return 1; }
    # If the anchor ever stopped matching, awk would copy the WHOLE installer;
    # refuse to run anything that contains its functions.
    ! grep -q '^repair_module_cmd() {$\|^step_uninstall() {$\|^initialize_setup() {$' "$T/head.sh" \
        || { echo "$1: the head copy reaches into the installer body"; return 1; }
    [ "$(wc -l < "$T/head.sh")" -lt 600 ] || { echo "$1: the head copy is too long"; return 1; }
    printf '%s\n' 'echo "PASSED-CHECK repair=$REPAIR_MODULE verbose=$VERBOSE t1=$_AWG_KMOD_T1"; trap - EXIT; exit 0' >> "$T/head.sh"
}

@test "--repair-module refuses any other argument before doing anything" {
    local f a
    for f in "${INSTALLERS[@]}"; do
        _head_through_check "$f"
        for a in --uninstall --force --yes --diagnostic --help --port=51820 --bogus; do
            run timeout 20 bash "$T/head.sh" --repair-module "$a" </dev/null
            [ "$status" -eq 2 ] || { echo "$f $a: status $status: $output"; return 1; }
            [[ "$output" == *"--repair-module"*"$a"* ]] || { echo "$f $a: $output"; return 1; }
            [[ "$output" != *PASSED-CHECK* ]]
            run timeout 20 bash "$T/head.sh" "$a" --repair-module </dev/null
            [ "$status" -eq 2 ] || { echo "$f $a (before): status $status"; return 1; }
        done
    done
}

@test "--repair-module accepts --verbose, -v and --no-color" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _head_through_check "$f"
        run timeout 20 bash "$T/head.sh" --repair-module --verbose --no-color </dev/null
        [ "$status" -eq 0 ] || { echo "$f: status $status: $output"; return 1; }
        [[ "$output" == *"PASSED-CHECK repair=1 verbose=1"* ]] || { echo "$f: $output"; return 1; }
        run timeout 20 bash "$T/head.sh" -v --repair-module </dev/null
        [ "$status" -eq 0 ] || { echo "$f -v: status $status: $output"; return 1; }
    done
}

@test "--repair-module is dispatched after set -x and before the guard and the state machine" {
    local f rm sx guard
    for f in "${INSTALLERS[@]}"; do
        rm=$(grep -n -m1 '^if \[\[ "\$REPAIR_MODULE" -eq 1 \]\]; then repair_module_cmd; fi$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f1)
        sx=$(grep -n -m1 '^if \[\[ "\$VERBOSE" -eq 1 \]\]; then set -x; fi$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f1)
        guard=$(grep -n -m1 '^_resume_state=""$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f1)
        [ -n "$rm" ] && [ -n "$sx" ] && [ -n "$guard" ]
        [ "$sx" -lt "$rm" ] && [ "$rm" -lt "$guard" ] || { echo "$f: sx=$sx rm=$rm guard=$guard"; return 1; }
    done
}

@test "--repair-module is in the help of both installers" {
    grep -q -- '--repair-module       Починить модуль ядра' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -q -- '--repair-module       Repair the kernel module' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

# ---------- --repair-module: admission and stages ----------

# A driver for repair_module_cmd of installer $1 with everything around it stubbed.
_rm_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }'
        echo 'id() { echo 0; }'
        echo '_awg_dpkg_busy() { [[ -e "$T/busy" ]]; }'
        echo '_awg_deploy_ensure_helper() { echo deploy-helper >> "$T/calls"; }'
        echo '_awg_deploy_ensure_units() { echo deploy-units >> "$T/calls"; [[ ! -e "$T/units.fail" ]]; }'
        echo 'dkms() { :; }'
        echo "AWG_ENSURE_HELPER=$T/bin/helper; DKMS_STATE_DIR=$T/dkms; DKMS_SRC_PREFIX=$T/src; LOG_FILE=$T/log"
        echo '_install_temp_files=(); _KS_OK=0; _KS_COMPLETE=0; _KS_KERNELS=()'
        _fn "$1" _pkg_present; _fn "$1" _awg_kmod_prebuilt_present
        _fn "$1" _awg_kmod_status_parse; _fn "$1" _awg_kmod_status_warn; _fn "$1" repair_module_cmd
        echo 'repair_module_cmd'
    } > "$T/drv.sh"
}
_rm_server() {
    _reset
    mkdir -p "$T/dkms/amneziawg/1.0.0" "$T/src/amneziawg-1.0.0"
    ln -sfn "$T/src/amneziawg-1.0.0" "$T/dkms/amneziawg/1.0.0/source"
    _st amneziawg-dkms "install ok installed"
    echo "amneziawg-dkms: $T/src/amneziawg-1.0.0/dkms.conf" > "$T/owner"
    _status_ok
}
# A healthy final --status of the helper (the running kernel has its module).
_status_ok() {
    cat > "$T/helper.out.--status" <<'EOF'
path kind=ppa reason=-
source state=patched version=1.0.0 fix=enabled
kernel release=7.0.0-38-generic running=1 image=1 module=1 headers=ok package=installed
module loaded=1
packages audit=empty
status complete=1 time=1700000000
EOF
}

@test "repair-module: deploys, repairs, then finishes; exit 0 only when all succeed; output in the log" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _rm_server; echo "kernel x: module on disk" > "$T/helper.out.--repair"; _rm_driver "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [ "$(_calls | tr '\n' ' ')" = "deploy-helper deploy-units helper --repair helper --finish helper --status " ] || { echo "$f: $(_calls)"; return 1; }
        grep -q 'kernel x: module on disk' "$T/log"
    done
}

@test "repair-module: what matters before a reboot comes from the final --status, even with nothing to configure" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _rm_server
        # --finish said nothing (empty audit): the configured old kernel
        # without a module is named from --status alone.
        sed -i '/^module /i kernel release=6.8.0-31-generic running=0 image=1 module=0 headers=missing package=installed\nkernel release=6.8.0-40-generic running=0 image=1 module=unknown headers=broken package=installed\nkernel release=7.0.0-39-generic running=0 image=0 module=0 headers=missing package=unfinished\nkernel release=6.8.0-50-generic running=0 image=1 module=0 headers=missing package=unknown' "$T/helper.out.--status"
        _rm_driver "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [[ "$(_calls)" == *"helper --status"* ]]
        grep -q '^WARN: .*6\.8\.0-31-generic.*linux-headers-6\.8\.0-31-generic' <<<"$output" || { echo "$f: $output"; return 1; }
        grep -q '^WARN: .*6\.8\.0-40-generic.*\(не читается\|not readable\)' <<<"$output" || { echo "$f: $output"; return 1; }
        grep -q '^WARN: .*6\.8\.0-40-generic.*\(битая\|broken\)' <<<"$output" || { echo "$f: $output"; return 1; }
        # An unfinished kernel without the module is named too, and one whose
        # package state could not be read.
        grep -q '^WARN: .*\(недонастроенное ядро\|unfinished kernel\) 7\.0\.0-39-generic.*linux-headers-7\.0\.0-39-generic' <<<"$output" || { echo "$f: $output"; return 1; }
        grep -q '^WARN: .*6\.8\.0-50-generic.*linux-headers-6\.8\.0-50-generic' <<<"$output" || { echo "$f: $output"; return 1; }
        # The running kernel is never named as a kernel to avoid.
        if grep -q '^WARN: .*7\.0\.0-38-generic' <<<"$output"; then echo "$f: running kernel named: $output"; return 1; fi
    done
}

@test "repair-module: a running kernel whose module file is gone is named before a reboot" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _rm_server
        sed -i 's/^kernel release=7.0.0-38-generic running=1 image=1 module=1/kernel release=7.0.0-38-generic running=1 image=1 module=0/' "$T/helper.out.--status"
        _rm_driver "$f"
        run bash "$T/drv.sh"
        grep -q '^WARN: .*7\.0\.0-38-generic.*\(на диске\|on disk\)' <<<"$output" || { echo "$f: $output"; return 1; }
    done
}

@test "repair-module: unknown headers or fix values are a valid report, not a malformed one" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _rm_server
        sed -i 's/headers=ok/headers=unknown/; s/fix=enabled/fix=unknown/' "$T/helper.out.--status"
        _rm_driver "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        if grep -q '\(получить не удалось\|could not be obtained\)' <<<"$output"; then echo "$f: rejected: $output"; return 1; fi
    done
}

@test "repair-module: a malformed or incomplete --status is said, not taken as fine" {
    local f bad
    for f in "${INSTALLERS[@]}"; do
        for bad in notrailer tworunning dup badvalue missingkey codemismatch incomplete; do
            _rm_server
            case "$bad" in
                notrailer)   sed -i '/^status /d' "$T/helper.out.--status" ;;
                tworunning)  sed -i '/^module /i kernel release=6.8.0-31-generic running=1 image=1 module=1 headers=ok package=installed' "$T/helper.out.--status" ;;
                dup)         sed -i '/^module /i kernel release=7.0.0-38-generic running=0 image=0 module=1 headers=ok package=none' "$T/helper.out.--status" ;;
                badvalue)    sed -i 's/module=1 headers/module=maybe headers/' "$T/helper.out.--status" ;;
                missingkey)  sed -i 's/ headers=ok//' "$T/helper.out.--status" ;;
                codemismatch) echo 1 > "$T/helper.rc.--status" ;;
                incomplete)  sed -i 's/complete=1/complete=0/' "$T/helper.out.--status"; echo 1 > "$T/helper.rc.--status" ;;
            esac
            _rm_driver "$f"
            run bash "$T/drv.sh"
            if [[ "$bad" == incomplete ]]; then
                grep -q '^WARN: .*\(не полностью\|not determined in full\)' <<<"$output" || { echo "$f $bad: $output"; return 1; }
            else
                grep -q '^WARN: .*\(получить не удалось\|could not be obtained\)' <<<"$output" || { echo "$f $bad: $output"; return 1; }
            fi
        done
    done
}

@test "repair-module: a failed repair skips --finish (no dpkg --configure) and exits 1" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _rm_server; echo 1 > "$T/helper.rc.--repair"; _rm_driver "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 1 ]
        [[ "$(_calls)" != *"--finish"* ]] || { echo "$f"; return 1; }
    done
}

@test "repair-module: a failed --finish or a failed wiring stage is exit 1" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _rm_server; echo 1 > "$T/helper.rc.--finish"; _rm_driver "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 1 ] || { echo "$f finish"; return 1; }
        _rm_server; : > "$T/units.fail"
        run bash "$T/drv.sh"
        [ "$status" -eq 1 ] || { echo "$f units"; return 1; }
        [[ "$(_calls)" == *"helper --repair"* ]]
    done
}

@test "repair-module: refused without changes on a never-installed server, ARM prebuilt, pinned hold, busy apt" {
    local f why
    for f in "${INSTALLERS[@]}"; do
        for why in nopkg prebuilt held heldmark busy configfiles kmodfail dkmsfail amfail; do
            _rm_server
            case "$why" in
                nopkg) rm -f "$T/st/amneziawg-dkms" ;;
                configfiles) _st amneziawg-dkms "deinstall ok config-files" ;;
                prebuilt) echo "amneziawg-kmod-6.8.0-100-generic install ok installed" > "$T/kmodlist" ;;
                held) _st amneziawg-dkms "hold ok installed" ;;
                heldmark) echo amneziawg-dkms > "$T/holds" ;;
                # Every admission query fails closed.
                kmodfail) : > "$T/kmod.fail" ;;
                dkmsfail) : > "$T/dkms.fail" ;;
                amfail) : > "$T/am.fail" ;;
                *) : > "$T/$why" ;;
            esac
            _rm_driver "$f"
            run bash "$T/drv.sh"
            [ "$status" -eq 1 ] || { echo "$f $why: status $status"; return 1; }
            [ -z "$(_calls)" ] || { echo "$f $why: $(_calls)"; return 1; }
            # A failed query is named as such, not as "not installed".
            if [[ "$why" == dkmsfail ]]; then
                [[ "$output" == *"спросить dpkg о пакете amneziawg-dkms"* || "$output" == *"ask dpkg about the amneziawg-dkms"* ]] || { echo "$f dkmsfail: $output"; return 1; }
            fi
        done
    done
}

@test "repair-module: owner records are read per line, as the helper's --status reads them" {
    local f case
    for f in "${INSTALLERS[@]}"; do
        for case in divfirst arch multi; do
            _rm_server
            local p="$T/src/amneziawg-1.0.0/dkms.conf"
            case "$case" in
                divfirst) printf 'diversion by local from: %s\namneziawg-dkms: %s\n' "$p" "$p" > "$T/owner" ;;
                arch) echo "amneziawg-dkms:amd64: $p" > "$T/owner" ;;
                multi) echo "amneziawg-dkms, other-pkg: $p" > "$T/owner" ;;
            esac
            _rm_driver "$f"
            run bash "$T/drv.sh"
            if [[ "$case" == multi ]]; then
                [ "$status" -eq 1 ] || { echo "$f $case: $output"; return 1; }
                [[ "$output" == *other-pkg* ]]
                [ -z "$(_calls)" ]
            else
                [ "$status" -eq 0 ] || { echo "$f $case: $output"; return 1; }
            fi
        done
    done
}

@test "repair-module: no registration, two, a redirected one, an unknown or a foreign owner: refused" {
    local f case
    for f in "${INSTALLERS[@]}"; do
        for case in none two redirect noowner foreign; do
            _rm_server
            case "$case" in
                none) rm -rf "$T/dkms/amneziawg/1.0.0" ;;
                two) mkdir -p "$T/dkms/amneziawg/1.0.1"; ln -s "$T/src/amneziawg-1.0.0" "$T/dkms/amneziawg/1.0.1/source" ;;
                # The owner names the redirected path too: only the
                # canonical-path check can refuse it.
                redirect) mkdir -p "$T/elsewhere"; ln -sfn "$T/elsewhere" "$T/dkms/amneziawg/1.0.0/source"
                          echo "amneziawg-dkms: $T/elsewhere/dkms.conf" > "$T/owner" ;;
                noowner) rm -f "$T/owner" ;;
                foreign) echo "someone-else: $T/src/amneziawg-1.0.0/dkms.conf" > "$T/owner" ;;
            esac
            _rm_driver "$f"
            run bash "$T/drv.sh"
            [ "$status" -eq 1 ] || { echo "$f $case: status $status"; return 1; }
            [ -z "$(_calls)" ] || { echo "$f $case: $(_calls)"; return 1; }
            # The reason has to be the real one: with no registration a later
            # check would refuse too, but naming a path that does not exist.
            if [[ "$case" == none ]]; then
                [[ "$output" == *"не зарегистрирован в DKMS"* || "$output" == *"not registered in DKMS"* ]] || { echo "$f none: $output"; return 1; }
            fi
            if [[ "$case" == redirect ]]; then
                [[ "$output" == *"$T/elsewhere"*"$T/src/amneziawg-1.0.0"* ]] || { echo "$f redirect: $output"; return 1; }
            fi
        done
    done
}

@test "step 1 failure on a server with the module points at --repair-module" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _fn "$f" _die_upgrade_failed | grep -q 'bash \$0 --repair-module'
    done
}

@test "uninstall removes the helper's lock directory" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _fn "$f" step_uninstall | grep -q 'rm -rf /var/lib/amneziawg /run/amneziawg'
    done
}
