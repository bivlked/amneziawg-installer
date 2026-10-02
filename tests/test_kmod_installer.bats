#!/usr/bin/env bats
# Installer side of the kernel 7.0 module fix (track K): the install_packages
# fallback (T1), the step 2 wiring (early helper, T1', T2) and the
# --repair-module entry point for installed servers. The helper itself is
# covered in test_kmod_helper.bats; here it is a stub.

load test_helper

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

_fn() { sed -n "/^$2() {\$/,/^}\$/p" "$BATS_TEST_DIRNAME/../$1"; }
_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
_st() { mkdir -p "$T/st"; printf '%s' "$2" > "$T/st/$1"; }   # dpkg status of a package
_calls() { cat "$T/calls" 2>/dev/null || true; }

setup() {
    T=$(mktemp -d); export T
    mkdir -p "$T/bin" "$T/st"
    _stub uname 'echo 7.0.0-38-generic'
    _stub apt 'echo "apt $*" >> "$T/calls"; exit 100'
    _stub dpkg-query 'p="${*: -1}"; [[ -f "$T/st/$p" ]] || exit 1; cat "$T/st/$p"'
    # dpkg -S is a read-only query: not recorded as a call.
    _stub dpkg '[[ "$1" == -S ]] || echo "dpkg $*" >> "$T/calls"
if [[ "$1" == --configure ]]; then
  [[ -e "$T/configure.fail" ]] && exit 1
  for f in "$T"/st/*; do [[ -e "$f.keep" ]] || [[ "$f" == *.keep ]] || echo "install ok installed" > "$f"; done
fi
if [[ "$1" == -S ]]; then cat "$T/owner" 2>/dev/null || exit 1; fi
exit 0'
    _stub helper 'echo "helper $*" >> "$T/calls"; cat "$T/helper.out.$1" 2>/dev/null; exit "$(cat "$T/helper.rc.$1" 2>/dev/null || echo 0)"'
    export PATH="$T/bin:$PATH"
}

teardown() { rm -rf "$T"; }

# ---------- T1: the install_packages fallback ----------

# A driver that runs install_packages from installer $1 with the T1 flag $2.
_t1_driver() {
    {
        echo 'log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; die() { echo "DIE: $*"; exit 1; }'
        echo 'apt_update_tolerant() { :; }; _install_temp_files=(); _APT_UPDATED=1'
        echo "AWG_ENSURE_HELPER=$T/bin/helper; _AWG_KMOD_T1=$2"
        _fn "$1" _pkg_present; _fn "$1" _pkg_installed_ok; _fn "$1" _pkgs_installed_ok; _fn "$1" install_packages
        echo 'install_packages "$@"'
    } > "$T/drv.sh"
}

@test "T1: a failed apt with the module package unpacked: helper --repair, dpkg --configure, packages checked" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/calls"; _st amneziawg-dkms "install ok unpacked"; _st qrencode "unknown ok not-installed"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms qrencode
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [[ "$(_calls)" == *"helper --repair"*"dpkg --configure -a"* ]] || { echo "$f: $(_calls)"; return 1; }
    done
}

@test "T1: enabled by the package state, not by the requested list" {
    _st amneziawg-dkms "install ok half-configured"; _st qrencode "unknown ok not-installed"
    _t1_driver install_amneziawg.sh 1
    run bash "$T/drv.sh" qrencode
    [ "$status" -eq 0 ]
    [[ "$(_calls)" == *"helper --repair"* ]]
}

@test "T1: off outside the PPA/DKMS path of step 2 (ARM prebuilt, pinned 2.0, other steps)" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/calls"; _st amneziawg-dkms "install ok unpacked"
        _t1_driver "$f" 0
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 1 ]; [[ "$output" == *DIE:* ]]
        [[ "$(_calls)" != *helper* ]] || { echo "$f: helper called"; return 1; }
    done
}

@test "T1: a package left as config-files does not enable it" {
    _st amneziawg-dkms "deinstall ok config-files"
    _t1_driver install_amneziawg.sh 1
    run bash "$T/drv.sh" amneziawg-dkms
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *helper* ]]
}

@test "T1: the running kernel without a module (helper exit 2) is a failure, configure is not run" {
    _st amneziawg-dkms "install ok unpacked"
    echo 2 > "$T/helper.rc.--repair"
    _t1_driver install_amneziawg.sh 1
    run bash "$T/drv.sh" amneziawg-dkms
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"--configure"* ]]
}

@test "T1: helper exit 1 (another kernel failed, the running one is fine) still finishes the install" {
    _st amneziawg-dkms "install ok unpacked"
    echo 1 > "$T/helper.rc.--repair"
    _t1_driver install_amneziawg.sh 1
    run bash "$T/drv.sh" amneziawg-dkms
    [ "$status" -eq 0 ]
}

@test "T1: the known-issue line gives the exact reason instead of the generic error" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _st amneziawg-dkms "install ok unpacked"
        echo 2 > "$T/helper.rc.--repair"
        echo "kernel 7.0.0-38-generic: NOT built [known-issue:kernel-70-udp-tunnel]: ..." > "$T/helper.out.--repair"
        _t1_driver "$f" 1
        run bash "$T/drv.sh" amneziawg-dkms
        [ "$status" -eq 1 ]
        [[ "$output" == *"DIE: "*"setup_udp_tunnel_sock"*"kernel-70-backport-adv"* ]] || { echo "$f: $output"; return 1; }
    done
}

@test "T1: configure succeeded but a requested package is still missing: failure" {
    _st amneziawg-dkms "install ok unpacked"; _st qrencode "unknown ok not-installed"; : > "$T/st/qrencode.keep"
    _t1_driver install_amneziawg.sh 1
    run bash "$T/drv.sh" amneziawg-dkms qrencode
    [ "$status" -eq 1 ]
    [[ "$output" == *DIE:* ]]
}

# ---------- step 2 wiring (structure) ----------

_step2() { _fn "$1" step2_install_amnezia; }
_line() { grep -n -m1 -F -- "$2" <<<"$1" | cut -d: -f1; }

@test "step 2: the helper is deployed before the first apt transaction of the DKMS path" {
    local f s dep gcc pk arm
    for f in "${INSTALLERS[@]}"; do
        s=$(_step2 "$f")
        dep=$(_line "$s" '    _awg_deploy_ensure_helper')
        gcc=$(_line "$s" 'apt install -y gcc-13')
        pk=$(_line "$s" '    install_packages "${packages[@]}"')
        arm=$(_line "$s" 'request_reboot 3')
        [ -n "$dep" ] && [ -n "$gcc" ] && [ -n "$pk" ] && [ -n "$arm" ]
        [ "$arm" -lt "$dep" ] && [ "$dep" -lt "$gcc" ] && [ "$dep" -lt "$pk" ] || { echo "$f: arm=$arm dep=$dep gcc=$gcc pk=$pk"; return 1; }
    done
}

@test "step 2: T1 is enabled only on the non-pinned path and switched off after the package install" {
    local f s on off
    for f in "${INSTALLERS[@]}"; do
        s=$(_step2 "$f")
        [ "$(grep -c '_AWG_KMOD_T1=1' <<<"$s")" -eq 1 ]
        on=$(_line "$s" '_AWG_KMOD_T1=1'); off=$(_line "$s" '_AWG_KMOD_T1=0')
        [ "$on" -lt "$off" ]
        # the line before the enable is inside the use_pinned_awg2 -eq 0 block
        sed -n "1,${on}p" <<<"$s" | grep -n 'if \[\[ "\$use_pinned_awg2" -eq 0 \]\]; then' | tail -n1 | grep -q .
    done
}

@test "step 2: the proactive --prepare (T2) runs after the packages and before the headers meta-package" {
    local f s pk meta blk
    for f in "${INSTALLERS[@]}"; do
        s=$(_step2 "$f")
        pk=$(_line "$s" '    install_packages "${packages[@]}"')
        meta=$(_line "$s" 'for meta in "${meta_candidates[@]}"')
        [ -n "$pk" ] && [ -n "$meta" ] && [ "$pk" -lt "$meta" ]
        # Right after the package install: the non-pinned guard, and the
        # --prepare call inside it (not merely a matching line somewhere).
        [ "$(sed -n "$((pk + 1))p" <<<"$s")" = '    if [[ "$use_pinned_awg2" -eq 0 ]]; then' ] || { echo "$f: no guard after install_packages"; return 1; }
        blk=$(sed -n "$((pk + 2)),\$p" <<<"$s" | sed '/^    fi$/q')
        [[ "$blk" == *'"$AWG_ENSURE_HELPER" --prepare'* ]] || { echo "$f: --prepare not in the block"; return 1; }
        # nothing before it in step 2 calls --prepare outside the early block
        [ "$(sed -n "1,${pk}p" <<<"$s" | grep -c -F '"$AWG_ENSURE_HELPER" --prepare')" -eq 1 ] || { echo "$f: extra --prepare before install"; return 1; }
    done
}

@test "step 2: the hook, logrotate and unit are still deployed in step 2" {
    local f
    for f in "${INSTALLERS[@]}"; do
        _step2 "$f" | grep -qx '    _awg_deploy_ensure_units || true'
    done
}

# ---------- --repair-module: arguments ----------

@test "--repair-module refuses any other argument before doing anything" {
    local f a
    for f in "${INSTALLERS[@]}"; do
        for a in --uninstall --force --yes --diagnostic --help --port=51820 --bogus; do
            run bash "$BATS_TEST_DIRNAME/../$f" --repair-module "$a"
            [ "$status" -eq 2 ] || { echo "$f $a: status $status"; return 1; }
            [[ "$output" == *"--repair-module"*"$a"* ]] || { echo "$f $a: $output"; return 1; }
            run bash "$BATS_TEST_DIRNAME/../$f" "$a" --repair-module
            [ "$status" -eq 2 ] || { echo "$f $a (before): status $status"; return 1; }
        done
    done
}

@test "--repair-module is dispatched before help, uninstall and diagnostic" {
    local f rm help
    for f in "${INSTALLERS[@]}"; do
        rm=$(grep -n -m1 '^if \[\[ "\$REPAIR_MODULE" -eq 1 \]\]; then repair_module_cmd; fi$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f1)
        help=$(grep -n -m1 '^if \[\[ "\$HELP" -eq 1 \]\]; then show_help; fi$' "$BATS_TEST_DIRNAME/../$f" | cut -d: -f1)
        [ -n "$rm" ] && [ "$rm" -lt "$help" ]
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
        echo '_awg_kmod_prebuilt_present() { [[ -e "$T/prebuilt" ]]; }'
        echo '_awg_pkg_held() { [[ -e "$T/held" ]]; }'
        echo '_awg_dpkg_busy() { [[ -e "$T/busy" ]]; }'
        echo '_awg_deploy_ensure_helper() { echo deploy-helper >> "$T/calls"; }'
        echo '_awg_deploy_ensure_units() { echo deploy-units >> "$T/calls"; [[ ! -e "$T/units.fail" ]]; }'
        echo 'dkms() { :; }'
        echo "AWG_ENSURE_HELPER=$T/bin/helper; DKMS_STATE_DIR=$T/dkms; DKMS_SRC_PREFIX=$T/src"
        _fn "$1" _pkg_present; _fn "$1" repair_module_cmd
        echo 'repair_module_cmd'
    } > "$T/drv.sh"
}
_rm_server() {
    mkdir -p "$T/dkms/amneziawg/1.0.0" "$T/src/amneziawg-1.0.0"
    ln -sfn "$T/src/amneziawg-1.0.0" "$T/dkms/amneziawg/1.0.0/source"
    _st amneziawg-dkms "install ok installed"
    echo "amneziawg-dkms: $T/src/amneziawg-1.0.0/dkms.conf" > "$T/owner"
}

@test "repair-module: deploys, repairs, then finishes; exit 0 only when all three succeed" {
    local f
    for f in "${INSTALLERS[@]}"; do
        rm -f "$T/calls"; _rm_server; _rm_driver "$f"
        run bash "$T/drv.sh"
        [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
        [ "$(_calls | tr '\n' ' ')" = "deploy-helper deploy-units helper --repair helper --finish " ] || { echo "$f: $(_calls)"; return 1; }
    done
}

@test "repair-module: a failed repair skips --finish (no dpkg --configure) and exits 1" {
    _rm_server; echo 1 > "$T/helper.rc.--repair"; _rm_driver install_amneziawg.sh
    run bash "$T/drv.sh"
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"--finish"* ]]
}

@test "repair-module: a failed --finish or a failed wiring stage is exit 1" {
    _rm_server; echo 1 > "$T/helper.rc.--finish"; _rm_driver install_amneziawg.sh
    run bash "$T/drv.sh"
    [ "$status" -eq 1 ]
    rm -f "$T/helper.rc.--finish" "$T/calls"; : > "$T/units.fail"
    run bash "$T/drv.sh"
    [ "$status" -eq 1 ]
    [[ "$(_calls)" == *"helper --repair"* ]]
}

@test "repair-module: refused without changes on a never-installed server, ARM prebuilt, pinned hold, busy apt" {
    local why
    for why in nopkg prebuilt held busy configfiles; do
        rm -rf "$T/calls" "$T/prebuilt" "$T/held" "$T/busy"
        _rm_server
        case "$why" in
            nopkg) rm -f "$T/st/amneziawg-dkms" ;;
            configfiles) _st amneziawg-dkms "deinstall ok config-files" ;;
            *) : > "$T/$why" ;;
        esac
        _rm_driver install_amneziawg.sh
        run bash "$T/drv.sh"
        [ "$status" -eq 1 ] || { echo "$why: status $status"; return 1; }
        [ -z "$(_calls)" ] || { echo "$why: $(_calls)"; return 1; }
    done
}

@test "repair-module: two registrations or a source not owned by the package are refused" {
    _rm_server
    mkdir -p "$T/dkms/amneziawg/1.0.1"; ln -s "$T/src/amneziawg-1.0.0" "$T/dkms/amneziawg/1.0.1/source"
    _rm_driver install_amneziawg.sh
    run bash "$T/drv.sh"
    [ "$status" -eq 1 ]; [ -z "$(_calls)" ]
    rm -rf "$T/dkms/amneziawg/1.0.1"
    echo "someone-else: $T/src/amneziawg-1.0.0/dkms.conf" > "$T/owner"
    run bash "$T/drv.sh"
    [ "$status" -eq 1 ]; [ -z "$(_calls)" ]
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
