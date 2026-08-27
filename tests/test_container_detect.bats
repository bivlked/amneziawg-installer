#!/usr/bin/env bats
# v5.20.0 container-detect - early container detection (LXC/OpenVZ/Docker/WSL).
#
# Installing inside a container used to reach step 3 and die with a raw
# 'modprobe: FATAL: Module amneziawg not found' with no explanation. Now
# check_container stops at step 0 with a clear message and a pointer to the
# userspace amneziawg-go path in ADVANCED.

load test_helper

extract_check_container() {
    awk '/^check_container\(\)/,/^}/' "$BATS_TEST_DIRNAME/../$1"
}

# Install a fake systemd-detect-virt into an isolated PATH entry.
mock_detect_virt() {
    local answer="$1" rc="${2:-0}"
    local bin="$TEST_DIR/bin"
    mkdir -p "$bin"
    cat > "$bin/systemd-detect-virt" <<SHIM
#!/bin/bash
echo "$answer"
exit $rc
SHIM
    chmod +x "$bin/systemd-detect-virt"
    export PATH="$bin:$PATH"
}

@test "container-detect functional: check_container dies with a clear message inside lxc" {
    fn=$(extract_check_container install_amneziawg.sh)
    [ -n "$fn" ]
    mock_detect_virt "lxc" 0
    run bash -c '
        log() { :; }; log_error() { echo "ERR:$*"; }; die() { echo "DIE:$*"; exit 1; }
        '"$fn"'
        check_container
        echo "unreachable"
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *'ERR:'*'lxc'* ]]
    [[ "$output" == *'DIE:'* ]]
    [[ "$output" == *'amneziawg-go'* ]]
    [[ "$output" != *'unreachable'* ]]
}

@test "container-detect functional: check_container passes on bare metal / KVM (none)" {
    fn=$(extract_check_container install_amneziawg.sh)
    mock_detect_virt "none" 1
    run bash -c '
        log() { :; }; log_error() { echo "ERR:$*"; }; die() { echo "DIE:$*"; exit 1; }
        '"$fn"'
        check_container && echo "passed"
    '
    [ "$status" -eq 0 ]
    [[ "$output" == *'passed'* ]]
    [[ "$output" != *'DIE:'* ]]
}

@test "container-detect functional: check_container is skipped when systemd-detect-virt is missing" {
    fn=$(extract_check_container install_amneziawg.sh)
    # A PATH with only core utils and no systemd-detect-virt.
    run bash -c '
        log() { :; }; log_error() { echo "ERR:$*"; }; die() { echo "DIE:$*"; exit 1; }
        '"$fn"'
        systemd_detect_virt_missing_dir=$(mktemp -d)
        cp /bin/bash "$systemd_detect_virt_missing_dir/" 2>/dev/null || true
        PATH="/usr/bin:/bin"
        command -v systemd-detect-virt &>/dev/null && exit 99  # env has it: skip scenario invalid
        check_container && echo "soft-skip"
    '
    # exit 99 means the test env itself has systemd-detect-virt in /usr/bin:/bin
    # (always true on Linux) - so instead assert via an empty PATH subshell.
    if [ "$status" -eq 99 ]; then
        run bash -c '
            log() { :; }; log_error() { echo "ERR:$*"; }; die() { echo "DIE:$*"; exit 1; }
            '"$fn"'
            PATH="/nonexistent"
            check_container && echo "soft-skip"
        '
    fi
    [ "$status" -eq 0 ]
    [[ "$output" == *'soft-skip'* ]]
}

@test "container-detect: check_container wired into step 0 right after check_os_version (RU/EN)" {
    for f in install_amneziawg.sh install_amneziawg_en.sh; do
        run grep -A1 '^    check_os_version$' "$BATS_TEST_DIRNAME/../$f"
        [ "$status" -eq 0 ]
        [[ "$output" == *'check_container'* ]]
    done
}

@test "container-detect: RU/EN check_container bodies are structurally identical (code lines)" {
    ru=$(extract_check_container install_amneziawg.sh | grep -vE '^\s*(#|log_error |die )')
    en=$(extract_check_container install_amneziawg_en.sh | grep -vE '^\s*(#|log_error |die )')
    [ -n "$ru" ]
    [ "$ru" = "$en" ]
}
