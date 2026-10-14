#!/usr/bin/env bats
# Texts that a 3.1 server prints must not name a fixed generation, and --help must
# describe the fallback to 2.0 as the installer's choice, not as a protocol limit.
#
# Since v6.0.0 a new install is 3.1, but --diagnostic still opened its report with
# "AMNEZIAWG 2.0 DIAGNOSTIC REPORT", and --help said 2.0 is used "where 3.1 cannot
# run". The kernel gate (6.7) and the ARM gate are caution of the installer: the
# 3.x module builds on 6.1, and ARM was not measured. The generation of a given
# server is in the report anyway, through the AWG_PROTOCOL line of the init file.
#
# ADVANCED quotes the --protocol paragraph of --help verbatim, so the last cases
# hold the copy to the source.
#
# The help checks look only inside show_help: runtime messages such as "no awg
# command at all" or "tools older than the module" describe a real limit of the
# machine at that moment and keep their wording.

R="$BATS_TEST_DIRNAME/.."

_protocol_paragraph() {
    # From the --protocol option line up to the next option line.
    awk '/^  --protocol=2\.0\|3\.1/ {on=1} on && /^  -/ && !/^  --protocol=/ {exit} on' "$1"
}

@test "RU: diagnostic report header names no generation" {
    run grep -c 'AMNEZIAWG 2\.0 DIAGNOSTIC REPORT' "$R/install_amneziawg.sh"
    [ "$output" = "0" ]
    grep -q 'echo "=== AMNEZIAWG DIAGNOSTIC REPORT ==="' "$R/install_amneziawg.sh"
}

@test "EN: diagnostic report header names no generation" {
    run grep -c 'AMNEZIAWG 2\.0 DIAGNOSTIC REPORT' "$R/install_amneziawg_en.sh"
    [ "$output" = "0" ]
    grep -q 'echo "=== AMNEZIAWG DIAGNOSTIC REPORT ==="' "$R/install_amneziawg_en.sh"
}

@test "RU: --help does not present the 2.0 fallback as a protocol limit" {
    # Guard: an empty extract would make the count below a silent pass.
    awk '/^show_help\(\)/,/^}/' "$R/install_amneziawg.sh" | grep -q -- '--protocol=2.0|3.1'
    run bash -c "awk '/^show_help\(\)/,/^}/' \"$R/install_amneziawg.sh\" | grep -c 'не поднять'"
    [ "$output" = "0" ]
}

@test "EN: --help does not present the 2.0 fallback as a protocol limit" {
    # Guard: an empty extract would make the count below a silent pass.
    awk '/^show_help\(\)/,/^}/' "$R/install_amneziawg_en.sh" | grep -q -- '--protocol=2.0|3.1'
    run bash -c "awk '/^show_help\(\)/,/^}/' \"$R/install_amneziawg_en.sh\" | grep -c 'cannot run'"
    [ "$output" = "0" ]
}

@test "RU: ADVANCED quotes the --protocol paragraph of --help verbatim" {
    local src copy
    src=$(_protocol_paragraph "$R/install_amneziawg.sh")
    copy=$(_protocol_paragraph "$R/ADVANCED.md")
    [ -n "$src" ]
    [ "$src" = "$copy" ]
}

@test "EN: ADVANCED quotes the --protocol paragraph of --help verbatim" {
    local src copy
    src=$(_protocol_paragraph "$R/install_amneziawg_en.sh")
    copy=$(_protocol_paragraph "$R/ADVANCED.en.md")
    [ -n "$src" ]
    [ "$src" = "$copy" ]
}
