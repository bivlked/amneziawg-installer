#!/usr/bin/env bats
# A server on an ARM prebuilt module package after a kernel change (measured on
# a stand on 3 nov 2026): the VPN does not come up, the old dkms recipe cannot
# run because dkms is not installed, and a plain second run of the installer
# brings the module back with the keys and client profiles kept. These cases pin
# when the library recognises that state (awg_prebuilt_needs_rerun) and that the
# texts which used to lead nowhere now name the working recipe.

setup() {
    ROOT="${BATS_TEST_DIRNAME}/.."
    T="$BATS_TEST_TMPDIR"
    mkdir -p "$T/bin" "$T/modules/6.8.0-149-generic" "$T/modules/6.8.0-147-generic/extra"
    : > "$T/modules/6.8.0-147-generic/extra/amneziawg.ko.xz"
}

# _need <library> : run awg_prebuilt_needs_rerun for kernel 6.8.0-149-generic
# with dpkg-query answering from $KMOD ("name status" lines; KMOD_FAIL=1 = dpkg
# could not be asked: it still prints the package line, then fails, so the
# rc check is what has to stop it), the dkms command present when DKMS=1 and
# amneziawg registered in DKMS when DKMS_REG=1. Prints rc=N.
_need() {
    local lib="$1" k="${2:-6.8.0-149-generic}"
    rm -rf "$T/bin/dkms" "$T/dkmsstate"; mkdir -p "$T/dkmsstate"
    if [ "${DKMS:-0}" = 1 ]; then printf '#!/bin/sh\nexit 0\n' > "$T/bin/dkms"; chmod +x "$T/bin/dkms"; fi
    if [ "${DKMS_REG:-0}" = 1 ]; then mkdir -p "$T/dkmsstate/amneziawg/1.0.0"; fi
    KMOD="${KMOD:-}" KMOD_FAIL="${KMOD_FAIL:-0}" AWG_MODULES_DIR="$T/modules" AWG_DKMS_STATE_DIR="$T/dkmsstate" PATH="$T/bin:/usr/bin:/bin" bash -c '
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        dpkg-query() {
            [ "$KMOD_FAIL" = 1 ] && { printf "%s\n" "$KMOD"; echo "dpkg-query: error" >&2; return 2; }
            [ -z "$KMOD" ] && { echo "dpkg-query: no packages found matching amneziawg-kmod-*" >&2; return 1; }
            printf "%s\n" "$KMOD"
        }
        awg_prebuilt_needs_rerun "$2"; echo "rc=$?"
    ' _ "$lib" "$k"
}

LIBS=(awg_common.sh awg_common_en.sh)
PKG="amneziawg-kmod-ubuntu-2404-arm64 install ok installed"

@test "needs rerun: prebuilt installed, no dkms, no module for the kernel -> 0 (RU + EN)" {
    local l
    for l in "${LIBS[@]}"; do
        KMOD="$PKG" run _need "$ROOT/$l"
        [ "$output" = "rc=0" ] || { echo "$l: $output"; return 1; }
    done
}

@test "needs rerun: any of the three conditions missing -> 1 (RU + EN)" {
    local l
    for l in "${LIBS[@]}"; do
        # amneziawg registered in DKMS: the dkms way is real there, keep the usual texts
        DKMS=1 DKMS_REG=1 KMOD="$PKG" run _need "$ROOT/$l"
        [ "$output" = "rc=1" ] || { echo "$l dkms: $output"; return 1; }
        # purged packages (dpkg lists them as not-installed) do not count
        KMOD="amneziawg-kmod-x purge ok not-installed" run _need "$ROOT/$l"
        [ "$output" = "rc=1" ] || { echo "$l purged: $output"; return 1; }
        # no prebuilt package (or only removed ones)
        KMOD="" run _need "$ROOT/$l"
        [ "$output" = "rc=1" ] || { echo "$l nopkg: $output"; return 1; }
        KMOD="amneziawg-kmod-x deinstall ok config-files" run _need "$ROOT/$l"
        [ "$output" = "rc=1" ] || { echo "$l removed: $output"; return 1; }
        # the module for this kernel is on disk: nothing to rerun for
        KMOD="$PKG" run _need "$ROOT/$l" 6.8.0-147-generic
        [ "$output" = "rc=1" ] || { echo "$l module present: $output"; return 1; }
    done
}

@test "needs rerun: the dkms command alone (another DKMS module) does not hide the advice (RU + EN)" {
    local l
    for l in "${LIBS[@]}"; do
        DKMS=1 KMOD="$PKG" run _need "$ROOT/$l"
        [ "$output" = "rc=0" ] || { echo "$l: $output"; return 1; }
    done
}

@test "needs rerun: several packages, one of them installed, counts as installed (RU + EN)" {
    local l
    for l in "${LIBS[@]}"; do
        KMOD="$PKG"$'\n'"amneziawg-kmod-old deinstall ok config-files" run _need "$ROOT/$l"
        [ "$output" = "rc=0" ] || { echo "$l: $output"; return 1; }
    done
}

@test "needs rerun: dpkg could not be asked -> 1, no confident prebuilt advice (RU + EN)" {
    local l
    for l in "${LIBS[@]}"; do
        KMOD="$PKG" KMOD_FAIL=1 run _need "$ROOT/$l"
        [ "$output" = "rc=1" ] || { echo "$l: $output"; return 1; }
    done
}

@test "the rerun hint names the installer of its own language, the download and the kept keys" {
    local l out
    for l in "${LIBS[@]}"; do
        out=$(bash -c 'say() { echo "SAY: $*"; }; log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
                       source "$1" >/dev/null 2>&1; awg_prebuilt_rerun_hint say' _ "$ROOT/$l")
        local inst=install_amneziawg.sh
        [ "$l" = awg_common_en.sh ] && inst=install_amneziawg_en.sh
        [[ "$out" == *"SAY:   wget -O $inst https://github.com/bivlked/amneziawg-installer/releases/latest/download/$inst"* ]] \
            || { echo "$l: no download line: $out"; return 1; }
        [[ "$out" == *"SAY:   sudo bash $inst"* ]] || { echo "$l: no run line: $out"; return 1; }
        [[ "$out" == *"ключи и профили клиентов сохраняются"* || "$out" == *"keys and the client profiles are kept"* ]] \
            || { echo "$l: keys not promised: $out"; return 1; }
        # every line goes through the given function, nothing straight to stdout
        [ "$(grep -vc '^SAY: ' <<<"$out")" = 0 ] || { echo "$l: stray output: $out"; return 1; }
    done
}

# The failing end of ensure_amneziawg_kernel_module on such a server: the hint
# replaces the dkms recipe; elsewhere the dkms recipe stays.
_ensure_fail() {
    local lib="$1"
    rm -rf "$T/bin/dkms" "$T/dkmsstate"; mkdir -p "$T/dkmsstate"
    # DKMS=1: a real DKMS server - the command AND the amneziawg registration
    if [ "${DKMS:-0}" = 1 ]; then printf '#!/bin/sh\nexit 1\n' > "$T/bin/dkms"; chmod +x "$T/bin/dkms"; mkdir -p "$T/dkmsstate/amneziawg/1.0.0"; fi
    KMOD="${KMOD:-}" AWG_MODULES_DIR="$T/modules" AWG_DKMS_STATE_DIR="$T/dkmsstate" PATH="$T/bin:/usr/bin:/bin" bash -c '
        log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        dpkg-query() { [ -z "$KMOD" ] && return 1; printf "%s\n" "$KMOD"; }
        uname() { [ "$1" = -r ] && { echo 6.8.0-149-generic; return 0; }; command uname "$@"; }
        lsmod() { :; }; modprobe() { return 1; }; depmod() { :; }
        _sanitize_awg_dkms_conf() { :; }
        ensure_amneziawg_kernel_module module-only; echo "rc=$?"
    ' _ "$lib"
}

@test "ensure: on a prebuilt server without dkms the failure prints the rerun recipe, not dkms (RU + EN)" {
    local l
    for l in "${LIBS[@]}"; do
        KMOD="$PKG" run _ensure_fail "$ROOT/$l"
        [[ "$output" == *"rc=1"* ]] || { echo "$l: $output"; return 1; }
        [[ "$output" == *"ERR:   sudo bash install_amneziawg"* ]] || { echo "$l: no recipe: $output"; return 1; }
        [[ "$output" != *"dkms autoinstall -k"* ]] || { echo "$l: dkms recipe still printed: $output"; return 1; }
    done
}

@test "ensure: with dkms installed the dkms recipe stays (RU + EN)" {
    local l
    for l in "${LIBS[@]}"; do
        DKMS=1 KMOD="$PKG" run _ensure_fail "$ROOT/$l"
        [[ "$output" == *"rc=1"* ]] || { echo "$l: $output"; return 1; }
        [[ "$output" == *"dkms autoinstall -k"* ]] || { echo "$l: dkms recipe gone: $output"; return 1; }
        [[ "$output" != *"sudo bash install_amneziawg"* ]] || { echo "$l: rerun advice on a dkms server: $output"; return 1; }
    done
}

# manage check on such a server: the module line names the recipe instead of
# "normal for userspace mode". The real check_server with system commands
# stubbed (the pattern of test_v5211_check_integration.bats), text output.
_check_text() {
    local src="$1" common_src="${1/manage_amneziawg/awg_common}" bin="$T/cbin"
    mkdir -p "$bin" "$T/awg"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/systemctl"
    printf '#!/usr/bin/env bash\necho "5: awg0: <UP>"\n' > "$bin/ip"
    printf '#!/usr/bin/env bash\necho "UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*"\n' > "$bin/ss"
    printf '#!/usr/bin/env bash\necho 1\n' > "$bin/sysctl"
    printf '#!/usr/bin/env bash\n:\n' > "$bin/lsmod"
    printf '#!/usr/bin/env bash\necho "Status: active"\n' > "$bin/ufw"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$bin/awg"
    printf '#!/usr/bin/env bash\n[ -z "$KMOD" ] && exit 1\nprintf "%%s\\n" "$KMOD"\n' > "$bin/dpkg-query"
    printf '#!/usr/bin/env bash\n[ "$1" = -r ] && { echo 6.8.0-149-generic; exit 0; }\nexec /bin/uname "$@"\n' > "$bin/uname"
    chmod +x "$bin"/*
    printf '[Interface]\n[Peer]\n' > "$T/awg/awg0.conf"
    KMOD="${KMOD:-}" AWG_MODULES_DIR="$T/modules" AWG_DKMS_STATE_DIR="$T/nodkms" PATH="$bin:/usr/bin:/bin" \
    AWG_DIR="$T/awg" CONFIG_FILE="$T/awg/awgsetup_cfg.init" SERVER_CONF_FILE="$T/awg/awg0.conf" \
    bash -c '
        log() { echo "LOG: $*"; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        safe_load_config() { AWG_PORT=39743; return 0; }
        awg_size_collision_warn() { :; }; awg_userns_module_warn() { :; }
        JSON_OUTPUT=0; _JSON_EMITTED=0
        for f in _sanitize_port awg_module_version awg_installed_protocol _awg_generation_from_init _mask_report_secrets awg_prebuilt_needs_rerun awg_prebuilt_rerun_hint; do
            eval "$(awk "/^$f\\(\\) \\{/,/^\\}/" "$2")"
        done
        for f in _json_utf8_sanitize json_escape json_out _ipopts_guard_report check_server; do
            eval "$(awk "/^$f\\(\\) \\{/,/^\\}/" "$1")"
        done
        check_server
    ' _ "$src" "$common_src"
}

@test "check: a prebuilt server without its module names the rerun recipe, not userspace (RU + EN)" {
    local m
    for m in manage_amneziawg.sh manage_amneziawg_en.sh; do
        KMOD="$PKG" run _check_text "$ROOT/$m"
        [[ "$output" == *"WARN:   sudo bash install_amneziawg"* ]] || { echo "$m: no recipe: $output"; return 1; }
        [[ "$output" != *"userspace"* ]] || { echo "$m: still says userspace: $output"; return 1; }
        [[ "$output" != *"command not found"* ]] || { echo "$m: harness gap: $output"; return 1; }
        # control: no prebuilt package -> the userspace line as before
        KMOD="" run _check_text "$ROOT/$m"
        [[ "$output" == *"userspace"* ]] || { echo "$m control: $output"; return 1; }
        [[ "$output" != *"sudo bash install_amneziawg"* ]] || { echo "$m control: recipe printed: $output"; return 1; }
    done
}
# The arm reason texts name the real architecture (since v6.2.0 the arm code is
# 32-bit ARM and aarch64_be only, so the text must say which one it saw), and
# arch_unsupported names both allowed architectures.
_reason() { # file function code
    bash -c '
        _awg31_host_arch() { echo armhf; }
        uname() { [ "$1" = -r ] && { echo 6.12.0; return 0; }; command uname "$@"; }
        eval "$(awk -v n="$2" "\$0 == n \"() {\" {on=1} on {print} on && /^}\$/ {exit}" "$1")"
        "$2" "$3"' _ "$1" "$2" "$3"
}

@test "arm reason texts name the architecture, arch_unsupported names x86_64 and arm64 (RU + EN)" {
    local f fn n=0
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        for fn in _awg31_blocker_message _awg31_fallback_reason; do
            run _reason "$ROOT/$f" "$fn" arm
            [[ "$output" == *"'armhf'"* ]] || { echo "$f $fn arm: $output"; return 1; }
            run _reason "$ROOT/$f" "$fn" arch_unsupported
            [[ "$output" == *"x86_64"*"arm64"* ]] || { echo "$f $fn arch_unsupported: $output"; return 1; }
            n=$((n + 1))
        done
    done
    for f in awg_common.sh awg_common_en.sh; do
        run _reason "$ROOT/$f" _awg31_restore_blocker_reason arm
        [[ "$output" == *"'armhf'"* ]] || { echo "$f restore arm: $output"; return 1; }
        run _reason "$ROOT/$f" _awg31_restore_blocker_reason arch_unsupported
        [[ "$output" == *"x86_64"*"arm64"* ]] || { echo "$f restore arch_unsupported: $output"; return 1; }
        n=$((n + 1))
    done
    [ "$n" -eq 6 ]
}