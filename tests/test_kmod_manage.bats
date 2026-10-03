#!/usr/bin/env bats
# shellcheck disable=SC2154  # $stderr is set by `run --separate-stderr`
# manage repair-module and diagnose on the kernel 7.0 module path (track K):
# the helper's --status decides the path, the new path builds, loads and
# configures through the helper and never calls apt or ensure's unlocked
# dkms autoinstall, the success rule and the JSON fields. The helper is a
# stub driven by files; both manage scripts run end to end from copies whose
# three path constants point into a temporary tree.

bats_require_minimum_version 1.5.0

RUN=7.0.0-38-generic
OLDK=6.8.0-100-generic

_stub() { printf '#!/bin/bash\n%s\n' "$2" > "$T/bin/$1"; chmod +x "$T/bin/$1"; }
_calls() { cat "$T/calls" 2>/dev/null || true; }
_st() { printf '%s' "$2" > "$T/st/$1"; }

# A healthy report: path ppa, the running kernel with its module.
_status() { # [extra records before "module"...]
    {
        echo "path kind=${KIND:-ppa} reason=${REASON:--}"
        echo "source state=patched version=1.0.0 fix=${FIX:-enabled}"
        echo "kernel release=$RUN running=1 image=1 module=${RMOD:-1} headers=${RHDR:-ok} package=installed"
        for r in "$@"; do echo "$r"; done
        echo "module loaded=0"
        echo "packages audit=${AUDIT:-empty}"
        echo "status complete=${COMPLETE:-1} time=1700000000"
    }
}

setup() {
    T=$(mktemp -d); export T RUN
    mkdir -p "$T/bin" "$T/st" "$T/awg/keys" "$T/sys/module" "$T/lib/modules/$RUN/updates"
    command -v jq >/dev/null || skip "jq not available"
    _stub awg 'case "$1" in genkey|genpsk) echo AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= ;; pubkey) cat >/dev/null; echo BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB= ;; esac; exit 0'
    _stub id 'if [[ "$1" == -u ]]; then cat "$T/uid" 2>/dev/null || echo 0; else /usr/bin/id "$@"; fi'
    _stub uname 'if [[ "$1" == -r ]]; then echo "$RUN"; else /bin/uname "$@"; fi'
    _stub depmod 'echo "depmod $*" >> "$T/calls"'
    _stub modprobe 'echo "modprobe $*" >> "$T/calls"; [[ -e "$T/modprobe.fail" ]] && exit 1; mkdir -p "$T/sys/module/amneziawg"'
    _stub lsmod '[[ -e "$T/lsmod.loaded" ]] && echo "amneziawg 40960 0"; exit 0'
    _stub systemctl 'echo "systemctl $*" >> "$T/calls"
case "$1" in
  is-active) [[ -e "$T/svc.active" ]] ;;
  start) [[ -e "$T/svc.fail" ]] && exit 1; : > "$T/svc.active" ;;
  *) exit 0 ;;
esac'
    _stub apt 'echo "apt $*" >> "$T/calls"; exit 100'
    _stub apt-get 'echo "apt-get $*" >> "$T/calls"; exit 100'
    _stub dkms 'echo "dkms $*" >> "$T/calls"; exit 0'
    _stub dpkg-query 'p="${*: -1}"
[[ -e "$T/dq.fail" ]] && { echo "dpkg-query: error: database locked" >&2; exit 2; }
if [[ "$p" == *"*"* ]]; then
  [[ -s "$T/kmodlist" ]] && { cat "$T/kmodlist"; exit 0; }
  echo "dpkg-query: no packages found matching $p" >&2; exit 1
fi
[[ -f "$T/st/$p" ]] || { echo "dpkg-query: no packages found matching $p" >&2; exit 1; }
cat "$T/st/$p"'
    # The helper: --version from helper.version (rc helper.vrc, stderr
    # helper.verr); --status serves helper.out.--status.<n> for its n-th
    # call if present, else helper.out.--status; other modes print
    # helper.out.<mode> and exit helper.rc.<mode>.
    cat > "$T/helper" <<'EOF'
#!/bin/bash
m="$1"
if [[ "$m" == --version ]]; then
  [[ -e "$T/helper.verr" ]] && cat "$T/helper.verr" >&2
  [[ -e "$T/helper.version" ]] && cat "$T/helper.version" || echo "amneziawg-ensure-module 3"
  exit "$(cat "$T/helper.vrc" 2>/dev/null || echo 0)"
fi
echo "helper $m" >> "$T/calls"
if [[ "$m" == --status ]]; then
  n=$(( $(cat "$T/status.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$T/status.n"
  f="$T/helper.out.--status"; [[ -e "$f.$n" ]] && f="$f.$n"
  cat "$f"; exit "$(cat "$T/helper.rc.--status.$n" 2>/dev/null || cat "$T/helper.rc.--status" 2>/dev/null || echo 0)"
fi
echo "[ts] [$m] chatter on stdout"
[[ "$m" == --repair && -e "$T/repair.builds" ]] && : > "$T/lib/modules/$RUN/updates/amneziawg.ko"
exit "$(cat "$T/helper.rc.$m" 2>/dev/null || echo 0)"
EOF
    chmod +x "$T/helper"
    export PATH="$T/bin:$PATH"
    cp "$BATS_TEST_DIRNAME/../awg_common.sh" "$T/awg/awg_common.sh"
    printf 'export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET=10.9.9.1/24\nexport AWG_PROTOCOL=2\n' > "$T/awg/awgsetup_cfg.init"
    printf '[Interface]\nPrivateKey = TESTKEY\nAddress = 10.9.9.1/24\nListenPort = 39743\n' > "$T/awg/awg0.conf"
    local f n
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        sed -e "s#^AWG_ENSURE_HELPER=/usr/local/sbin/amneziawg-ensure-module\$#AWG_ENSURE_HELPER=$T/helper#" \
            -e "s#^KMOD_MODULES_DIR=/lib/modules\$#KMOD_MODULES_DIR=$T/lib/modules#" \
            -e "s#^KMOD_SYS_DIR=/sys/module\$#KMOD_SYS_DIR=$T/sys/module#" \
            "$BATS_TEST_DIRNAME/../$f" > "$T/$f"
        n=$(grep -c "^AWG_ENSURE_HELPER=$T/\|^KMOD_MODULES_DIR=$T/\|^KMOD_SYS_DIR=$T/" "$T/$f")
        [ "$n" -eq 3 ] || { echo "$f: path constants rewritten: $n of 3"; return 1; }
    done
    M="$T/manage_amneziawg.sh"; M_EN="$T/manage_amneziawg_en.sh"
    ARGS=(--conf-dir="$T/awg" --server-conf="$T/awg/awg0.conf")
    _st amneziawg-dkms "install ok installed"
    _status > "$T/helper.out.--status"
    : > "$T/lib/modules/$RUN/updates/amneziawg.ko"
    echo ko > "$T/lib/modules/$RUN/updates/amneziawg.ko"
}

teardown() { rm -rf "$T"; }

_repair() { run --separate-stderr bash "${SCR:-$M}" repair-module --json "${ARGS[@]}"; }
_j() { printf '%s' "$output" | jq -e "$1" >/dev/null; }

# ---------- the new path ----------

@test "new path: --status, --repair, depmod+modprobe, --finish, --status; no apt, no ensure; exit 0, JSON says so" {
    _repair
    [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
    _j '.command=="repair-module" and .ok==true and .module_loaded==true and .service_active==true and .rc==0'
    _j '.helper=="current" and .path=="helper" and .repair_rc==0 and .finish_rc==0 and .status_complete==true'
    _j '.packages=="empty" and .source=="patched" and .fix_disabled==false and .running_module_on_disk==true and .running_headers=="ok"'
    _j '.kernels_without_module==[] and .unfinished_without_module==[]'
    [ "$(_calls | grep -E '^(helper|depmod|modprobe)' | tr '\n' '|')" = "helper --status|helper --repair|depmod -a $RUN|modprobe amneziawg|helper --finish|helper --status|" ] || { _calls; return 1; }
    [[ "$(_calls)" != *apt* && "$(_calls)" != *"dkms autoinstall"* ]]
}

@test "new path: a failed --repair skips --finish and fails; the JSON keeps finish_rc null" {
    echo 1 > "$T/helper.rc.--repair"
    _repair
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"helper --finish"* ]]
    _j '.ok==false and .repair_rc==1 and .finish_rc==null'
}

@test "new path: an already configured other kernel without a module warns by name, success stays" {
    _status "kernel release=$OLDK running=0 image=1 module=0 headers=missing package=installed" > "$T/helper.out.--status"
    _repair
    [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
    _j ".ok==true and .kernels_without_module==[\"$OLDK\"]"
    [[ "$stderr" == *"$OLDK"*"linux-headers-$OLDK"*"repair-module"* ]]
}

@test "new path: an unfinished kernel without a module fails, the running kernel counts too" {
    _status "kernel release=7.0.0-39-generic running=0 image=1 module=0 headers=missing package=unfinished" > "$T/helper.out.--status.2"
    _status > "$T/helper.out.--status.1"
    sed -i 's/packages audit=empty/packages audit=unfinished/' "$T/helper.out.--status.2"
    echo 1 > "$T/helper.rc.--finish"
    _repair
    [ "$status" -eq 1 ]
    _j '.ok==false and .unfinished_without_module==["7.0.0-39-generic"] and .packages=="unfinished"'
    [[ "$stderr" == *"7.0.0-39-generic"* ]]
    # A working tunnel is not a fixed apt.
    [[ "$stderr" == *"apt"* ]]
}

@test "new path: no module and no headers for the running kernel: the exact command, exit 1, nothing built, no apt" {
    RMOD=0 RHDR=missing _status > "$T/helper.out.--status"
    rm -f "$T/lib/modules/$RUN/updates/amneziawg.ko"
    _repair
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"apt install linux-headers-$RUN"* ]]
    [[ "$(_calls)" != *"helper --repair"* && "$(_calls)" != *apt* ]]
    _j '.ok==false and .path=="refused"'
}

@test "new path: module load fails while the service would start: rc 1, not loaded, the service is not claimed" {
    : > "$T/modprobe.fail"
    _repair
    [ "$status" -eq 1 ]
    _j '.ok==false and .rc==1 and .module_loaded==false and .service_active==false'
    [[ "$(_calls)" != *"systemctl start"* ]]
}

@test "new path: module loaded, service fails: rc 2" {
    : > "$T/svc.fail"
    _repair
    [ "$status" -eq 1 ]
    _j '.ok==false and .rc==2 and .module_loaded==true and .service_active==false'
}

@test "new path: an incomplete final status is not a success" {
    COMPLETE=0 _status > "$T/helper.out.--status.2"; echo 1 > "$T/helper.rc.--status.2"
    _repair
    [ "$status" -eq 1 ]
    _j '.ok==false and .status_complete==false'
}

@test "refused, unreadable or malformed status: nothing is built or configured" {
    local c
    for c in refused malformed mismatch; do
        rm -f "$T/calls" "$T/status.n" "$T/helper.rc.--status"
        case "$c" in
            refused) KIND=refused REASON=owner _status > "$T/helper.out.--status" ;;
            malformed) _status | sed '/^status /d' > "$T/helper.out.--status" ;;
            mismatch) _status > "$T/helper.out.--status"; echo 1 > "$T/helper.rc.--status" ;;
        esac
        _repair
        [ "$status" -eq 1 ] || { echo "$c: $status"; return 1; }
        [ "$(_calls | tr '\n' '|')" = "helper --status|" ] || { echo "$c: $(_calls)"; return 1; }
        _j '.ok==false and .path=="refused" and (.error|length>0)' || { echo "$c: $output"; return 1; }
    done
}

@test "prebuilt, pinned or no package per --status: the previous path, no helper build" {
    local k
    for k in prebuilt pinned none; do
        rm -f "$T/calls" "$T/status.n"
        KIND=$k _status > "$T/helper.out.--status"
        : > "$T/lsmod.loaded"; : > "$T/svc.active"
        _repair
        [ "$status" -eq 0 ] || { echo "$k: $stderr"; return 1; }
        _j '.path=="legacy" and .helper=="current" and .repair_rc==null'
        [ "$(_calls | grep '^helper' | tr '\n' '|')" = "helper --status|" ] || { echo "$k: $(_calls)"; return 1; }
    done
}

@test "an old or missing helper: the previous path, with a warning only where amneziawg-dkms is installed" {
    : > "$T/lsmod.loaded"; : > "$T/svc.active"
    printf 'amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)\n' > "$T/helper.verr"
    : > "$T/helper.version"; echo 2 > "$T/helper.vrc"
    _repair
    [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
    _j '.helper=="outdated" and .path=="legacy"'
    [[ "$stderr" == *"--repair-module"* ]]
    [[ "$(_calls)" != *"helper --"* ]]
    rm -f "$T/st/amneziawg-dkms"
    _repair
    [ "$status" -eq 0 ]
    [[ "$stderr" != *"--repair-module"* ]]
    rm -f "$T/helper"
    _repair
    _j '.helper=="absent" and .path=="legacy"'
}

@test "a broken helper or a failed dpkg query: refused without changes" {
    echo "garbage" > "$T/helper.version"
    _repair
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"helper --"* && "$(_calls)" != *dkms* ]]
    rm -f "$T/helper"; : > "$T/dq.fail"
    _repair
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *dkms* ]]
}

@test "new path needs root" {
    echo 1000 > "$T/uid"
    _repair
    [ "$status" -eq 1 ]
    [[ "$(_calls)" != *"helper --"* ]]
}

@test "EN: the new path's envelope has the RU keys" {
    _repair; local ru; ru=$(printf '%s' "$output" | jq -cS 'keys')
    rm -f "$T/status.n" "$T/calls"; rm -rf "$T/sys/module/amneziawg"
    SCR="$M_EN" _repair; [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
    [ "$(printf '%s' "$output" | jq -cS 'keys')" = "$ru" ]
}

# ---------- diagnose ----------

_diag() { run bash "${SCR:-$M}" diagnose "${ARGS[@]}"; }

@test "diagnose: a configured kernel without a module and unfinished packages are warnings, not failures" {
    AUDIT=unfinished _status "kernel release=$OLDK running=0 image=1 module=0 headers=missing package=installed" > "$T/helper.out.--status"
    _diag
    [[ "$output" == *"$OLDK"*"linux-headers-$OLDK"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"dpkg --audit"* ]]
    if grep -E 'FAIL.*'"$OLDK" <<<"$output"; then return 1; fi
}

@test "diagnose: the running kernel's module file gone while it is still loaded is a warning, not OK" {
    RMOD=0 _status > "$T/helper.out.--status"
    _diag
    [[ "$output" == *"WARN"*"$RUN"*"на диске"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"всех загрузочных ядер"* ]]
}

@test "new path: unknown headers and fix values are kept as unknown, not turned into facts" {
    RHDR=unknown FIX=unknown _status > "$T/helper.out.--status"
    _repair
    _j '.running_headers=="unknown" and .fix_disabled==null' || { echo "$output"; return 1; }
}

@test "diagnose: all kernels with the module is one OK line; non-root says root is needed" {
    _diag
    [[ "$output" == *"OK"*"всех загрузочных ядер"* ]] || { echo "$output"; return 1; }
    SCR="$M_EN" _diag
    [[ "$output" == *"every boot kernel"* ]] || { echo "$output"; return 1; }
    echo 1000 > "$T/uid"
    _diag
    [[ "$output" == *"root"* ]]
}

@test "diagnose: an outdated helper on a PPA server is named with the installer command" {
    printf 'amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)\n' > "$T/helper.verr"
    : > "$T/helper.version"; echo 2 > "$T/helper.vrc"
    _diag
    [[ "$output" == *"WARN"*"--repair-module"* ]] || { echo "$output"; return 1; }
}
