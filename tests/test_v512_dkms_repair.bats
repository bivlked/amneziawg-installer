#!/usr/bin/env bats
# v5.12.0 DKMS auto-repair regression tests.
#
# The v5.12.0 auto-repair change guarantees the amneziawg kernel module is
# rebuilt and loaded after a kernel upgrade, with three triggers:
#   - reactive: manage add/remove/restart pre-call ensure_amneziawg_kernel_module
#   - proactive: apt hook DPkg::Post-Invoke runs /usr/local/sbin/amneziawg-ensure-module --hook
#   - boot-time: systemd unit amneziawg-ensure-module.service Before=awg-quick@awg0
#
# Tests are structural (extract+grep against the source files) — same pattern
# as the v5.11.5 regen tests. Runtime verification is the Phase 7 VPS test.

# Helper: extract the helper script body from the installer here-doc.
_extract_helper() {
    awk "/AWG_ENSURE_HELPER_EOF'/,/^AWG_ENSURE_HELPER_EOF\$/" "$1" | sed '1d;$d'
}

# Helper: extract the systemd unit content from the installer here-doc.
_extract_unit() {
    awk "/AWG_SYSTEMD_UNIT_EOF'/,/^AWG_SYSTEMD_UNIT_EOF\$/" "$1" | sed '1d;$d'
}

# Helper: extract the apt hook content from the installer here-doc.
_extract_hook() {
    awk "/AWG_APT_HOOK_EOF'/,/^AWG_APT_HOOK_EOF\$/" "$1" | sed '1d;$d'
}

# Helper: extract the logrotate content from the installer here-doc.
_extract_logrotate() {
    awk "/AWG_LOGROTATE_EOF'/,/^AWG_LOGROTATE_EOF\$/" "$1" | sed '1d;$d'
}

# ---------- Phase 1: awg_common.sh baseline functions ----------

@test "v5.12: RU awg_common.sh defines _sanitize_awg_dkms_conf" {
    grep -qE '^_sanitize_awg_dkms_conf\(\) \{' "$BATS_TEST_DIRNAME/../awg_common.sh"
}

@test "v5.12: RU awg_common.sh defines _install_kernel_headers" {
    grep -qE '^_install_kernel_headers\(\) \{' "$BATS_TEST_DIRNAME/../awg_common.sh"
}

@test "v5.12: RU awg_common.sh defines _ensure_awg_quick_running" {
    grep -qE '^_ensure_awg_quick_running\(\) \{' "$BATS_TEST_DIRNAME/../awg_common.sh"
}

@test "v5.12: RU awg_common.sh defines ensure_amneziawg_kernel_module (master)" {
    grep -qE '^ensure_amneziawg_kernel_module\(\) \{' "$BATS_TEST_DIRNAME/../awg_common.sh"
}

@test "v5.12: AWG_ALLOW_APT_IN_ENSURE gate present in awg_common.sh + _en.sh" {
    grep -qF 'AWG_ALLOW_APT_IN_ENSURE' "$BATS_TEST_DIRNAME/../awg_common.sh"
    grep -qF 'AWG_ALLOW_APT_IN_ENSURE' "$BATS_TEST_DIRNAME/../awg_common_en.sh"
}

@test "v5.12: RU/EN awg_common function-count parity (4 DKMS-repair functions in each)" {
    ru_count=$(grep -cE '^(_sanitize_awg_dkms_conf|_install_kernel_headers|_ensure_awg_quick_running|ensure_amneziawg_kernel_module)\(\) \{' \
        "$BATS_TEST_DIRNAME/../awg_common.sh")
    en_count=$(grep -cE '^(_sanitize_awg_dkms_conf|_install_kernel_headers|_ensure_awg_quick_running|ensure_amneziawg_kernel_module)\(\) \{' \
        "$BATS_TEST_DIRNAME/../awg_common_en.sh")
    [ "$ru_count" -eq 4 ]
    [ "$en_count" -eq 4 ]
}

# ---------- Phase 2: manage integration ----------

@test "v5.12: RU manage has 3 pre-calls of ensure_amneziawg_kernel_module (add/remove/restart)" {
    # add (full default), remove (full default after confirm), restart (module-only).
    count=$(grep -cE '^[[:space:]]+ensure_amneziawg_kernel_module' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [ "$count" -ge 3 ]
}

@test "v5.12: EN manage has 3 pre-calls of ensure_amneziawg_kernel_module (add/remove/restart)" {
    count=$(grep -cE '^[[:space:]]+ensure_amneziawg_kernel_module' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [ "$count" -ge 3 ]
}

@test "v5.12: RU manage restart uses module-only mode (avoids apt installs in restart)" {
    grep -qE 'ensure_amneziawg_kernel_module module-only' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qE 'ensure_amneziawg_kernel_module module-only' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

@test "v5.12: RU manage exposes 'repair-module|repair' command (full mode with apt gate)" {
    grep -qE '^[[:space:]]+repair-module\|repair\)' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qE '^[[:space:]]+repair-module\|repair\)' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

@test "v5.12: repair-module sets AWG_ALLOW_APT_IN_ENSURE=1 (allows kernel-headers apt install)" {
    grep -qE 'AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module' "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    grep -qE 'AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module' "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

# ---------- Phase 3: kernel-headers meta candidates + helper + apt hook + logrotate ----------

@test "v5.12: meta_candidates loop has Ubuntu flavor extraction \${kernel_rel##*-}" {
    grep -qF '${kernel_rel##*-}' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF '${kernel_rel##*-}' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.12: meta_candidates loop has RPi guard (+rpt / -rpi suffix skip)" {
    # Match the kernel_rel == *+rpt* and kernel_rel == *-rpi* patterns separately —
    # Bash test joins them with ` || \"\$kernel_rel\" == ` which awk doesn't simplify.
    grep -qE 'kernel_rel.*\*\+rpt\*' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qE 'kernel_rel.*\*-rpi\*' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qE 'kernel_rel.*\*\+rpt\*' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qE 'kernel_rel.*\*-rpi\*' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.12: meta_candidates loop detects Debian cloud kernel (-cloud-)" {
    grep -qF 'linux-headers-cloud-' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF 'linux-headers-cloud-' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.12: meta_candidates fallback ordering - flavor BEFORE generic, cloud BEFORE arch" {
    # Ubuntu: linux-headers-${flavor} must precede linux-headers-generic so the
    # flavor-specific meta is tried first; only on its failure do we fall to generic.
    flavor_line=$(grep -nE 'meta_candidates\+=\("linux-headers-\$\{flavor\}"\)' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | cut -d: -f1)
    generic_line=$(grep -nE 'meta_candidates\+=\("linux-headers-generic"\)' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | cut -d: -f1)
    [ -n "$flavor_line" ] && [ -n "$generic_line" ]
    [ "$flavor_line" -lt "$generic_line" ]
    # Debian: linux-headers-cloud-${arch} must precede linux-headers-${arch}.
    cloud_line=$(grep -nE 'meta_candidates\+=\("linux-headers-cloud-\$\{arch_meta\}"\)' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | cut -d: -f1)
    arch_line=$(grep -nE 'meta_candidates\+=\("linux-headers-\$\{arch_meta\}"\)' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" | cut -d: -f1)
    [ -n "$cloud_line" ] && [ -n "$arch_line" ]
    [ "$cloud_line" -lt "$arch_line" ]
}

@test "v5.12: helper deployed via atomic staging dotfile + mv pattern" {
    # Phase 3 round-2 fix: install -> (stage in target dir + chmod + mv -f).
    grep -qF '/usr/local/sbin/.amneziawg-ensure-module.new' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF "mv -f \"\$_stage_helper\" /usr/local/sbin/amneziawg-ensure-module" \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.12: every staging+mv block has cleanup-on-failure tail (rm + die)" {
    # All four atomic deploys (helper, hook, logrotate, unit) must follow the
    # `mv -f "$_stage_*" /target ... || { rm -f "$_stage_*"; die "..."; }`
    # pattern so a failed rename leaves no orphan dotfile in the target dir.
    for stage_var in _stage_helper _stage_hook _stage_logrotate _stage_unit; do
        grep -qE "mv -f \"\\\$$stage_var\".*\\\\\$" "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
        grep -qE "rm -f \"\\\$$stage_var\"; die" "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
        grep -qE "rm -f \"\\\$$stage_var\"; die" "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    done
}

@test "v5.12: apt hook content has DPkg::Post-Invoke calling helper --hook" {
    hook=$(_extract_hook "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [[ "$hook" == *'DPkg::Post-Invoke'* ]]
    [[ "$hook" == *'amneziawg-ensure-module --hook'* ]]
    [[ "$hook" == *'/var/log/amneziawg-ensure-module.log'* ]]
    [[ "$hook" == *'|| true'* ]]
}

@test "v5.12: logrotate config has weekly + rotate 4 + copytruncate" {
    rot=$(_extract_logrotate "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [[ "$rot" == *'weekly'* ]]
    [[ "$rot" == *'rotate 4'* ]]
    [[ "$rot" == *'copytruncate'* ]]
    [[ "$rot" == *'missingok'* ]]
}

@test "v5.12: helper body byte-identical between RU and EN installers" {
    ru=$(_extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en=$(_extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru" = "$en" ]
}

@test "v5.12: apt hook + logrotate content byte-identical between RU and EN installers" {
    ru_h=$(_extract_hook "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en_h=$(_extract_hook "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru_h" = "$en_h" ]
    ru_l=$(_extract_logrotate "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en_l=$(_extract_logrotate "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru_l" = "$en_l" ]
}

# ---------- Phase 4: systemd unit + helper --systemd mode ----------

# Behaviour of every mode is covered in test_kmod_helper.bats (the helper is
# run there whole, with stubs); the checks below pin the structure.
_mode_body() { echo "$1" | awk -v f="^$2\\\\(\\\\) \\\\{\$" '$0 ~ f {p=1} p {print} p && /^}$/ {exit}'; }

@test "v5.12: helper case allows every mode" {
    helper=$(_extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [[ "$helper" == *'--hook|--systemd|--repair|--prepare|--prepare-locked|--finish|--status|--revert|--enable) ;;'* ]]
}

@test "v5.12: helper stamp fast-path lives in the --hook mode only (boot never skips)" {
    helper=$(_extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    hook=$(_mode_body "$helper" mode_hook); boot=$(_mode_body "$helper" mode_systemd)
    [ -n "$hook" ]; [ -n "$boot" ]
    [[ "$hook" == *'"$(cat "$STAMP_FILE" 2>/dev/null || true)" == "$state"'* ]]
    [[ "$boot" != *STAMP_FILE* && "$boot" != *stamp_write* ]]
}

# Loaded = /sys/module/amneziawg exists, not `lsmod | grep -q`: under pipefail
# grep -q can SIGPIPE lsmod and turn a loaded module into a failure. The exit
# codes of --systemd are covered by its behavioural tests.
@test "v5.12: helper --systemd loads with modprobe and verifies through /sys/module" {
    helper=$(_extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    boot=$(_mode_body "$helper" mode_systemd)
    [[ "$boot" == *'modprobe amneziawg'* ]]
    [[ "$boot" == *'[[ -d "${SYS_MODULE_DIR}/amneziawg" ]]'* ]]
    [[ "$helper" != *'lsmod'*'grep -q'* ]]
}

@test "v5.12: the --hook mode never calls modprobe, dpkg or systemctl" {
    helper=$(_extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    hook=$(_mode_body "$helper" mode_hook | grep -vE '^[[:space:]]*#' || true)
    [ -n "$hook" ]
    [[ "$hook" != *modprobe* && "$hook" != *'dpkg '* && "$hook" != *systemctl* && "$hook" != *mode_finish* ]]
}

@test "v5.12: helper does NOT call apt-get / apt install (apt-hook deadlock guard)" {
    # Critical: nested apt-get install inside DPkg::Post-Invoke would deadlock
    # on /var/lib/dpkg/lock-frontend held by the parent apt. The helper's
    # header comment legitimately mentions the constraint, so strip comment
    # lines before checking.
    helper=$(_extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    # `|| true` so a hypothetical all-comments helper doesn't make the test
    # abort under bats set -e (grep -v returns rc=1 when every line matched).
    code=$(echo "$helper" | grep -vE '^[[:space:]]*#' || true)
    [[ "$code" != *'apt-get install'* ]]
    [[ "$code" != *'apt install'* ]]
}

@test "v5.12: systemd unit has all required directives and ordering" {
    unit=$(_extract_unit "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    [[ "$unit" == *'[Unit]'* ]]
    [[ "$unit" == *'[Service]'* ]]
    [[ "$unit" == *'[Install]'* ]]
    [[ "$unit" == *'Before=awg-quick@awg0.service'* ]]
    [[ "$unit" == *'After=systemd-modules-load.service local-fs.target'* ]]
    [[ "$unit" == *'ConditionPathExists=/usr/local/sbin/amneziawg-ensure-module'* ]]
    [[ "$unit" == *'Type=oneshot'* ]]
    [[ "$unit" == *'RemainAfterExit=yes'* ]]
    [[ "$unit" == *'ExecStart=/usr/local/sbin/amneziawg-ensure-module --systemd'* ]]
    [[ "$unit" == *'TimeoutStartSec=300'* ]]
    [[ "$unit" == *'StandardOutput=journal'* ]]
    [[ "$unit" == *'WantedBy=multi-user.target'* ]]
}

@test "v5.12: systemd unit deployed via atomic staging dotfile + mv (apt-conf.d-ignored hidden)" {
    grep -qF '/etc/systemd/system/.amneziawg-ensure-module.service.new' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qF "mv -f \"\$_stage_unit\" /etc/systemd/system/amneziawg-ensure-module.service" \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
}

@test "v5.12: installer runs systemctl daemon-reload + enable for the unit" {
    grep -qE 'systemctl daemon-reload' "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qE 'systemctl enable amneziawg-ensure-module\.service' \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh"
    grep -qE 'systemctl daemon-reload' "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
    grep -qE 'systemctl enable amneziawg-ensure-module\.service' \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"
}

@test "v5.12: systemd unit content byte-identical between RU and EN installers" {
    ru=$(_extract_unit "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    en=$(_extract_unit "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh")
    [ "$ru" = "$en" ]
}

# ---------- Hygiene + parsing ----------

@test "v5.12: helper body has no AI markers" {
    helper=$(_extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh")
    ! echo "$helper" | grep -iE 'однако|таким образом|comprehensive|leveraging|seamless|tailored|delve|moreover|furthermore'
}

@test "v5.12: helper body parses with bash -n (extracted)" {
    tmpfile="$(mktemp)"
    _extract_helper "$BATS_TEST_DIRNAME/../install_amneziawg.sh" > "$tmpfile"
    bash -n "$tmpfile"
    rc=$?
    rm -f "$tmpfile"
    [ "$rc" -eq 0 ]
}
