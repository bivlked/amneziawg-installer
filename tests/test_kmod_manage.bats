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
    # In CI a missing jq must fail, not skip all of these silently.
    command -v jq >/dev/null || { [[ -z "${CI:-}" ]] || return 1; skip "jq not available"; }
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
# State one run leaves behind that the next must not inherit.
_fresh() { rm -f "$T/calls" "$T/status.n" "$T/svc.active"; rm -rf "$T/sys/module/amneziawg"; }
# Every repair-module case runs on both scripts: their branches differ in
# messages only, and a test of one language does not guard the other.
LANGS=(RU EN)
_scr() { if [[ "$1" == EN ]]; then SCR="$M_EN"; else SCR="$M"; fi; }

# ---------- the new path ----------

@test "new path: --status, --repair, depmod+modprobe, --finish, --status; no apt, no ensure; exit 0, JSON says so" {
    local l
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 0 ] || { echo "$l: $stderr"; return 1; }
        [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ] || { echo "$l: more than one document"; return 1; }
        _j '.command=="repair-module" and .ok==true and .module_loaded==true and .service_active==true and .rc==0'
        _j '.helper=="current" and .path=="helper" and .repair_rc==0 and .finish_rc==0 and .status_complete==true'
        _j '.packages=="empty" and .source=="patched" and .fix_disabled==false and .running_module_on_disk==true and .running_headers=="ok"'
        _j '.kernels_without_module==[] and .unfinished_without_module==[]'
        [ "$(_calls | grep -E '^(helper|depmod|modprobe)' | tr '\n' '|')" = "helper --status|helper --repair|depmod -a $RUN|modprobe amneziawg|helper --finish|helper --status|" ] || { echo "$l"; _calls; return 1; }
        [[ "$(_calls)" != *apt* && "$(_calls)" != *"dkms autoinstall"* ]] || { echo "$l: apt or autoinstall"; return 1; }
    done
}

@test "new path: a failed --repair skips --finish and fails; the JSON keeps finish_rc null" {
    local l
    echo 1 > "$T/helper.rc.--repair"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l"; return 1; }
        [[ "$(_calls)" != *"helper --finish"* ]] || { echo "$l: finish ran"; return 1; }
        _j '.ok==false and .repair_rc==1 and .finish_rc==null' || { echo "$l: $output"; return 1; }
        # --finish did not run and the audit is empty: nothing claims packages are unfinished.
        if [[ "$stderr" == *"apt починен"* || "$stderr" == *"apt is fixed"* ]]; then echo "$l: false claim: $stderr"; return 1; fi
    done
}

@test "new path: an already configured other kernel without a module warns by name, success stays" {
    local l
    _status "kernel release=$OLDK running=0 image=1 module=0 headers=missing package=installed" > "$T/helper.out.--status"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 0 ] || { echo "$l: $stderr"; return 1; }
        _j ".ok==true and .kernels_without_module==[\"$OLDK\"] and .unfinished_without_module==[]" || { echo "$l: $output"; return 1; }
        [[ "$stderr" == *"$OLDK"*"linux-headers-$OLDK"*"repair-module"* ]] || { echo "$l: $stderr"; return 1; }
    done
}

@test "success rule: unfinished packages after a clean --finish still fail" {
    local l
    AUDIT=unfinished _status > "$T/helper.out.--status.2"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l: $output"; return 1; }
        _j '.ok==false and .finish_rc==0 and .packages=="unfinished"' || { echo "$l: $output"; return 1; }
        # A working tunnel is not a fixed apt (the phrase itself: "apt" alone
        # is in the time-of-check line of every run).
        [[ "$stderr" == *"apt починен"* || "$stderr" == *"apt is fixed"* ]] || { echo "$l: $stderr"; return 1; }
    done
}

@test "success rule: an unfinished kernel without a module fails even with a clean --finish and an empty audit" {
    local l
    _status "kernel release=7.0.0-39-generic running=0 image=0 module=0 headers=missing package=unfinished" > "$T/helper.out.--status.2"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l: $output"; return 1; }
        _j '.ok==false and .finish_rc==0 and .packages=="empty" and .unfinished_without_module==["7.0.0-39-generic"] and .kernels_without_module==[]' || { echo "$l: $output"; return 1; }
        [[ "$stderr" == *"7.0.0-39-generic"* ]] || { echo "$l: $stderr"; return 1; }
    done
}

@test "success rule: an unfinished running kernel without a module is listed as unfinished" {
    local l
    sed "s/^kernel release=$RUN running=1 image=1 module=1 headers=ok package=installed/kernel release=$RUN running=1 image=1 module=0 headers=ok package=unfinished/" \
        <(_status) > "$T/helper.out.--status.2"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l: $output"; return 1; }
        _j ".unfinished_without_module==[\"$RUN\"] and .running_module_on_disk==false" || { echo "$l: $output"; return 1; }
    done
}

@test "new path: no module and no headers for the running kernel: the exact command, exit 1, nothing built, no apt" {
    local l
    RMOD=0 RHDR=missing _status > "$T/helper.out.--status"
    rm -f "$T/lib/modules/$RUN/updates/amneziawg.ko"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l"; return 1; }
        [[ "$stderr" == *"apt install linux-headers-$RUN"* ]] || { echo "$l: $stderr"; return 1; }
        [[ "$(_calls)" != *"helper --repair"* && "$(_calls)" != *apt* ]] || { echo "$l: $(_calls)"; return 1; }
        _j '.ok==false and .path=="refused"' || { echo "$l: $output"; return 1; }
    done
}

@test "new path: module load fails while the service would start: rc 1, not loaded, the service is not claimed" {
    local l
    : > "$T/modprobe.fail"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l"; return 1; }
        # The service was not looked at: null, not false.
        _j '.ok==false and .rc==1 and .module_loaded==false and .service_active==null' || { echo "$l: $output"; return 1; }
        [[ "$(_calls)" != *"systemctl start"* ]] || { echo "$l: service started"; return 1; }
    done
}

@test "new path: module loaded, service fails: rc 2" {
    local l
    : > "$T/svc.fail"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l"; return 1; }
        _j '.ok==false and .rc==2 and .module_loaded==true and .service_active==false' || { echo "$l: $output"; return 1; }
    done
}

@test "new path: an incomplete final status is not a success" {
    local l
    COMPLETE=0 _status > "$T/helper.out.--status.2"; echo 1 > "$T/helper.rc.--status.2"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l"; return 1; }
        _j '.ok==false and .status_complete==false' || { echo "$l: $output"; return 1; }
    done
}

@test "new path: an incomplete first status builds nothing" {
    local l
    COMPLETE=0 _status > "$T/helper.out.--status"; echo 1 > "$T/helper.rc.--status"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l"; return 1; }
        [ "$(_calls | tr '\n' '|')" = "helper --status|" ] || { echo "$l: $(_calls)"; return 1; }
        _j '.ok==false and .path=="refused"' || { echo "$l: $output"; return 1; }
    done
}

@test "new path: kernels whose module could not be checked are listed as unknown, not as fine" {
    local l
    COMPLETE=0 _status "kernel release=$OLDK running=0 image=1 module=unknown headers=ok package=installed" > "$T/helper.out.--status.2"
    echo 1 > "$T/helper.rc.--status.2"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l"; return 1; }
        _j ".kernels_unknown==[\"$OLDK\"] and .kernels_without_module==[] and .status_complete==false" || { echo "$l: $output"; return 1; }
    done
}

@test "new path: unknown headers and fix values are kept as unknown, not turned into facts" {
    local l
    RHDR=unknown FIX=unknown _status > "$T/helper.out.--status"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        _j '.running_headers=="unknown" and .fix_disabled==null' || { echo "$l: $output"; return 1; }
    done
}

@test "refused, unreadable or malformed status: nothing is built or configured" {
    local c l
    for l in "${LANGS[@]}"; do
        for c in refused malformed mismatch tworunning dup badvalue missingkey nopackages; do
            _fresh; rm -f "$T/helper.rc.--status"; _scr "$l"
            case "$c" in
                refused)    KIND=refused REASON=owner _status > "$T/helper.out.--status" ;;
                malformed)  _status | sed '/^status /d' > "$T/helper.out.--status" ;;
                mismatch)   _status > "$T/helper.out.--status"; echo 1 > "$T/helper.rc.--status" ;;
                tworunning) _status "kernel release=$OLDK running=1 image=1 module=1 headers=ok package=installed" > "$T/helper.out.--status" ;;
                dup)        _status "kernel release=$RUN running=0 image=0 module=1 headers=ok package=none" > "$T/helper.out.--status" ;;
                badvalue)   _status | sed 's/module=1 headers/module=maybe headers/' > "$T/helper.out.--status" ;;
                missingkey) _status | sed 's/ headers=ok//' > "$T/helper.out.--status" ;;
                nopackages) _status | sed '/^packages /d' > "$T/helper.out.--status" ;;
            esac
            _repair
            [ "$status" -eq 1 ] || { echo "$l $c: $status"; return 1; }
            [ "$(_calls | tr '\n' '|')" = "helper --status|" ] || { echo "$l $c: $(_calls)"; return 1; }
            _j '.ok==false and .path=="refused" and (.error|length>0)' || { echo "$l $c: $output"; return 1; }
        done
    done
}

@test "prebuilt, pinned or no package per --status: the previous path, no helper build" {
    local k l
    for l in "${LANGS[@]}"; do
        for k in prebuilt pinned none; do
            _fresh; _scr "$l"
            KIND=$k _status > "$T/helper.out.--status"
            : > "$T/lsmod.loaded"; : > "$T/svc.active"
            _repair
            [ "$status" -eq 0 ] || { echo "$l $k: $stderr"; return 1; }
            _j '.path=="legacy" and .helper=="current" and .repair_rc==null' || { echo "$l $k: $output"; return 1; }
            [ "$(_calls | grep '^helper' | tr '\n' '|')" = "helper --status|" ] || { echo "$l $k: $(_calls)"; return 1; }
        done
    done
}

@test "an old or missing helper: the previous path, with a warning only where amneziawg-dkms is installed" {
    local l
    printf 'amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)\n' > "$T/helper.verr"
    : > "$T/helper.version"; echo 2 > "$T/helper.vrc"
    for l in "${LANGS[@]}"; do
        _st amneziawg-dkms "install ok installed"; _fresh; _scr "$l"
        : > "$T/lsmod.loaded"; : > "$T/svc.active"
        _repair
        [ "$status" -eq 0 ] || { echo "$l: $stderr"; return 1; }
        _j '.helper=="outdated" and .path=="legacy"' || { echo "$l: $output"; return 1; }
        [[ "$stderr" == *"--repair-module"* ]] || { echo "$l: no warning"; return 1; }
        [[ "$(_calls)" != *"helper --"* ]] || { echo "$l: helper used"; return 1; }
        rm -f "$T/st/amneziawg-dkms"; _fresh; : > "$T/svc.active"
        _repair
        [ "$status" -eq 0 ] || { echo "$l nopkg: $stderr"; return 1; }
        [[ "$stderr" != *"--repair-module"* ]] || { echo "$l: warned without the package"; return 1; }
    done
    # No helper file at all, with amneziawg-dkms installed: the same warning.
    mv "$T/helper" "$T/helper.gone"
    for l in "${LANGS[@]}"; do
        _st amneziawg-dkms "install ok installed"; _fresh; _scr "$l"; : > "$T/svc.active"
        _repair
        _j '.helper=="absent" and .path=="legacy"' || { echo "$l: $output"; return 1; }
        [[ "$stderr" == *"--repair-module"* ]] || { echo "$l absent: no warning"; return 1; }
    done
}

@test "a version 2 helper (no --status) is outdated: the previous path, never --status" {
    local l
    echo "amneziawg-ensure-module 2" > "$T/helper.version"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; : > "$T/lsmod.loaded"; : > "$T/svc.active"
        _repair
        [ "$status" -eq 0 ] || { echo "$l: $stderr"; return 1; }
        _j '.helper=="outdated" and .path=="legacy"' || { echo "$l: $output"; return 1; }
        [[ "$(_calls)" != *"helper --"* ]] || { echo "$l: $(_calls)"; return 1; }
    done
}

@test "a broken helper or a failed dpkg query: refused for that reason, nothing repaired" {
    local l
    for l in "${LANGS[@]}"; do
        echo "garbage" > "$T/helper.version"; _fresh; _scr "$l"
        _repair
        [ "$status" -eq 1 ] || { echo "$l broken"; return 1; }
        [[ "$stderr" == *"$T/helper"* ]] || { echo "$l broken: reason not named: $stderr"; return 1; }
        _j '.ok==false and .helper=="broken" and .path=="refused" and (.error|length>0)' || { echo "$l broken: $output"; return 1; }
        [[ "$(_calls)" != *"helper --"* && "$(_calls)" != *dkms* && "$(_calls)" != *modprobe* && "$(_calls)" != *systemctl* ]] || { echo "$l broken: $(_calls)"; return 1; }
        rm -f "$T/helper.version"
    done
    mv "$T/helper" "$T/helper.gone"; : > "$T/dq.fail"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"
        _repair
        [ "$status" -eq 1 ] || { echo "$l query"; return 1; }
        [[ "$stderr" == *dpkg* ]] || { echo "$l query: reason not named: $stderr"; return 1; }
        _j '.ok==false and .helper=="absent" and .path=="refused"' || { echo "$l query: $output"; return 1; }
        [[ "$(_calls)" != *dkms* && "$(_calls)" != *modprobe* && "$(_calls)" != *systemctl* ]] || { echo "$l query: $(_calls)"; return 1; }
    done
}

@test "new path needs root" {
    local l
    echo 1000 > "$T/uid"
    for l in "${LANGS[@]}"; do
        _fresh; _scr "$l"; _repair
        [ "$status" -eq 1 ] || { echo "$l"; return 1; }
        [[ "$stderr" == *root* ]] || { echo "$l: $stderr"; return 1; }
        [[ "$(_calls)" != *"helper --"* ]] || { echo "$l: $(_calls)"; return 1; }
        # A full envelope, not the generic emergency object.
        _j '.ok==false and .helper=="current" and .path=="refused" and has("kernels_unknown")' || { echo "$l: $output"; return 1; }
    done
}

@test "EN: the new path's envelope has the RU keys" {
    _fresh; _repair; local ru; ru=$(printf '%s' "$output" | jq -cS 'keys')
    _fresh; SCR="$M_EN" _repair; [ "$status" -eq 0 ] || { echo "$stderr"; return 1; }
    [ "$(printf '%s' "$output" | jq -cS 'keys')" = "$ru" ]
}

# ---------- diagnose ----------

_diag() { run bash "${SCR:-$M}" diagnose "${ARGS[@]}"; }

@test "diagnose: a configured kernel without a module and unfinished packages are warnings, not failures" {
    local l
    AUDIT=unfinished _status "kernel release=$OLDK running=0 image=1 module=0 headers=missing package=installed" > "$T/helper.out.--status"
    for l in "${LANGS[@]}"; do
        _scr "$l"; _diag
        [[ "$output" == *"WARN"*"$OLDK"*"linux-headers-$OLDK"* ]] || { echo "$l: $output"; return 1; }
        [[ "$output" == *"WARN"*"dpkg --audit"* ]] || { echo "$l: $output"; return 1; }
        if grep -E 'FAIL.*'"$OLDK" <<<"$output"; then echo "$l"; return 1; fi
    done
}

@test "diagnose: the running kernel's module file gone while it is still loaded is a warning, not OK" {
    RMOD=0 _status > "$T/helper.out.--status"
    _diag
    [[ "$output" == *"WARN"*"$RUN"*"на диске"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"всех загрузочных ядер"* ]]
    SCR="$M_EN" _diag
    [[ "$output" == *"WARN"*"$RUN"*"on disk"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"every boot kernel"* ]]
}

@test "diagnose: all kernels with the module is one OK line; non-root says root is needed" {
    _diag
    [[ "$output" == *"OK"*"всех загрузочных ядер"* ]] || { echo "$output"; return 1; }
    SCR="$M_EN" _diag
    [[ "$output" == *"every boot kernel"* ]] || { echo "$output"; return 1; }
    echo 1000 > "$T/uid"
    _diag
    [[ "$output" == *"INFO"*"требует root"* ]] || { echo "$output"; return 1; }
    SCR="$M_EN" _diag
    [[ "$output" == *"INFO"*"needs root"* ]] || { echo "$output"; return 1; }
}

@test "diagnose: an old helper and a failed dpkg query is a warning, not silence" {
    local l
    printf 'amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)\n' > "$T/helper.verr"
    : > "$T/helper.version"; echo 2 > "$T/helper.vrc"; : > "$T/dq.fail"
    for l in "${LANGS[@]}"; do
        _scr "$l"; _diag
        [[ "$output" == *"WARN"*"dpkg"* ]] || { echo "$l: $output"; return 1; }
    done
}

@test "diagnose: an outdated helper on a PPA server is named with the installer command" {
    local l
    printf 'amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)\n' > "$T/helper.verr"
    : > "$T/helper.version"; echo 2 > "$T/helper.vrc"
    for l in "${LANGS[@]}"; do
        _scr "$l"; _diag
        [[ "$output" == *"WARN"*"--repair-module"* ]] || { echo "$l: $output"; return 1; }
    done
}
