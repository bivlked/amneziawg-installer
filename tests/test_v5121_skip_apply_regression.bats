#!/usr/bin/env bats
# v5.12.1 regression test: AWG_SKIP_APPLY=1 must not trigger
# `ensure_amneziawg_kernel_module || die` in `manage add` / `manage remove`.
#
# Background: v5.12.0 added DKMS auto-repair and pre-called the module check
# unconditionally before add/remove. This regressed the documented offline /
# batch edit flow (AWG_SKIP_APPLY=1, see ADVANCED.md) which is supposed to
# work on a dev machine without the kernel module loaded — apply_config
# itself respects AWG_SKIP_APPLY=1 (early return 0).
#
# Fix: gate the pre-call on AWG_SKIP_APPLY for `add` and `remove` only.
# `restart` is intentionally NOT gated because it is an explicit apply
# operation (`systemctl restart`) — AWG_SKIP_APPLY has no meaningful semantics
# for restart and the existing post-mutation block in restart does not honour
# AWG_SKIP_APPLY either.

# ---------- add: gate present ----------

@test "v5.12.1: RU add gates ensure_amneziawg_kernel_module on AWG_SKIP_APPLY" {
    block=$(awk '/^    add\)/,/^[[:space:]]+;;[[:space:]]*$/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [[ "$block" == *'AWG_SKIP_APPLY'* ]]
    [[ "$block" == *'ensure_amneziawg_kernel_module'* ]]
    # Specifically: ensure_amneziawg_kernel_module is inside an if-block
    # that tests AWG_SKIP_APPLY != "1".
    [[ "$block" == *'"${AWG_SKIP_APPLY:-0}" != "1"'*'ensure_amneziawg_kernel_module'* ]]
}

@test "v5.12.1: EN add gates ensure_amneziawg_kernel_module on AWG_SKIP_APPLY" {
    block=$(awk '/^    add\)/,/^[[:space:]]+;;[[:space:]]*$/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [[ "$block" == *'AWG_SKIP_APPLY'* ]]
    [[ "$block" == *'ensure_amneziawg_kernel_module'* ]]
    [[ "$block" == *'"${AWG_SKIP_APPLY:-0}" != "1"'*'ensure_amneziawg_kernel_module'* ]]
}

# ---------- remove: gate present ----------

@test "v5.12.1: RU remove gates ensure_amneziawg_kernel_module on AWG_SKIP_APPLY" {
    block=$(awk '/^    remove\)/,/^[[:space:]]+;;[[:space:]]*$/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [[ "$block" == *'AWG_SKIP_APPLY'* ]]
    [[ "$block" == *'ensure_amneziawg_kernel_module'* ]]
    [[ "$block" == *'"${AWG_SKIP_APPLY:-0}" != "1"'*'ensure_amneziawg_kernel_module'* ]]
}

@test "v5.12.1: EN remove gates ensure_amneziawg_kernel_module on AWG_SKIP_APPLY" {
    block=$(awk '/^    remove\)/,/^[[:space:]]+;;[[:space:]]*$/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [[ "$block" == *'AWG_SKIP_APPLY'* ]]
    [[ "$block" == *'ensure_amneziawg_kernel_module'* ]]
    [[ "$block" == *'"${AWG_SKIP_APPLY:-0}" != "1"'*'ensure_amneziawg_kernel_module'* ]]
}

# ---------- restart: NOT gated (explicit apply) ----------

@test "v5.12.1: RU restart still calls ensure_amneziawg_kernel_module unconditionally" {
    block=$(awk '/^    restart\)/,/^[[:space:]]+;;[[:space:]]*$/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh")
    [[ "$block" == *'ensure_amneziawg_kernel_module module-only'* ]]
    [[ "$block" != *'"${AWG_SKIP_APPLY:-0}" != "1"'* ]]
}

@test "v5.12.1: EN restart still calls ensure_amneziawg_kernel_module unconditionally" {
    block=$(awk '/^    restart\)/,/^[[:space:]]+;;[[:space:]]*$/' \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh")
    [[ "$block" == *'ensure_amneziawg_kernel_module module-only'* ]]
    [[ "$block" != *'"${AWG_SKIP_APPLY:-0}" != "1"'* ]]
}

# ---------- syntax sanity ----------

@test "v5.12.1: manage scripts pass bash -n after gate edits" {
    bash -n "$BATS_TEST_DIRNAME/../manage_amneziawg.sh"
    bash -n "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"
}

# ---------- repair-module path remains explicit (sanity) ----------

@test "v5.12.1: repair-module path keeps AWG_ALLOW_APT_IN_ENSURE=1 invocation" {
    # repair-module is the user-explicit recovery path — it must still call
    # ensure_amneziawg_kernel_module with AWG_ALLOW_APT_IN_ENSURE=1 regardless
    # of AWG_SKIP_APPLY (the user is asking us to repair, that means apply).
    for f in manage_amneziawg.sh manage_amneziawg_en.sh; do
        block=$(awk '/^    repair-module\|repair\)/,/^[[:space:]]+;;[[:space:]]*$/' \
            "$BATS_TEST_DIRNAME/../$f")
        [[ "$block" == *'AWG_ALLOW_APT_IN_ENSURE=1 ensure_amneziawg_kernel_module full'* ]]
    done
}

# ---------- runtime gate semantics ----------
#
# The structural greps above prove the gate text is in the right block. These
# behaviour tests prove the gate evaluates as intended for every value the
# documentation talks about (=1 skip, anything-else run).
#
# We replay just the gate snippet in isolation — that's the contract being
# tested. Sourcing the full manage script is impractical (it kicks off
# `case $COMMAND in ...` with side effects on real /etc paths).

run_gate() {
    # Replays exactly the gate the production scripts use:
    #   if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then ensure_amneziawg_kernel_module; fi
    # Returns 0 when ensure was called, 1 when it was skipped.
    local called=0
    ensure_amneziawg_kernel_module() { called=1; return 0; }
    if [[ "${AWG_SKIP_APPLY:-0}" != "1" ]]; then
        ensure_amneziawg_kernel_module
    fi
    [ "$called" -eq 1 ]
}

@test "v5.12.1 runtime: AWG_SKIP_APPLY unset -> ensure_amneziawg_kernel_module is called" {
    unset AWG_SKIP_APPLY
    run_gate
}

@test "v5.12.1 runtime: AWG_SKIP_APPLY=0 -> ensure_amneziawg_kernel_module is called" {
    export AWG_SKIP_APPLY=0
    run_gate
}

@test "v5.12.1 runtime: AWG_SKIP_APPLY=1 -> ensure_amneziawg_kernel_module is skipped" {
    export AWG_SKIP_APPLY=1
    ! run_gate
}

@test "v5.12.1 runtime: AWG_SKIP_APPLY=yes (string non-1) -> ensure is called (string equality with literal 1)" {
    export AWG_SKIP_APPLY=yes
    run_gate
}

@test "v5.12.1 runtime: AWG_SKIP_APPLY=true (string non-1) -> ensure is called" {
    export AWG_SKIP_APPLY=true
    run_gate
}

@test "v5.12.1 runtime: AWG_SKIP_APPLY=YES (uppercase, string non-1) -> ensure is called" {
    export AWG_SKIP_APPLY=YES
    run_gate
}
