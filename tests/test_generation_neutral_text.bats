#!/usr/bin/env bats
# Texts that a 3.1 server prints must not name a fixed generation, and --help and
# the automatic fallback warning must describe the fallback to 2.0 as the
# installer's choice, not as a protocol limit.
#
# Since v6.0.0 a new install is 3.1, but --diagnostic still opened its report with
# "AMNEZIAWG 2.0 DIAGNOSTIC REPORT", and --help said 2.0 is used "where 3.1 cannot
# run". The kernel gate (6.7) and the ARM gate are caution of the installer. The
# generation of a given server is in the report anyway, through the AWG_PROTOCOL
# line of the init file.
#
# Messages for a missing awg command, tools that are too old, or a module that
# refused the 2.0 set describe a real limit of the machine at that moment and keep
# their wording, which is why the checks look inside named functions only.
#
# ADVANCED quotes the --protocol paragraph of --help verbatim, so the last cases
# hold the copy to the source.
#
# The helpers return explicitly: a bare "! grep" in the middle of a function does
# not fail a bats test.

R="$BATS_TEST_DIRNAME/.."

_func() {
    # Body of a top-level function: $1 file, $2 function name.
    awk -v n="$2" '$0 ~ "^" n "\\(\\)" {on=1} on {print} on && /^}/ {exit}' "$1"
}

_protocol_paragraph() {
    # From the --protocol option line up to the next option line.
    awk '/^  --protocol=2\.0\|3\.1/ {on=1} on && /^  -/ && !/^  --protocol=/ {exit} on' "$1"
}

_check_report_header() {
    local body
    body=$(_func "$1" create_diagnostic_report)
    [ -n "$body" ] || return 1
    grep -qF 'echo "=== AMNEZIAWG DIAGNOSTIC REPORT ==="' <<<"$body" || return 1
    if grep -qE 'AMNEZIAWG [0-9.]+ DIAGNOSTIC' <<<"$body"; then return 1; fi
}

_check_text() {
    # $1 file, $2 function, $3 old wording, $4 new wording, $5 minimum count of $4
    local body
    body=$(_func "$1" "$2")
    [ -n "$body" ] || return 1
    if grep -qF -- "$3" <<<"$body"; then return 1; fi
    [ "$(grep -cF -- "$4" <<<"$body")" -ge "$5" ]
}

@test "RU: diagnostic report header names no generation" {
    _check_report_header "$R/install_amneziawg.sh"
}

@test "EN: diagnostic report header names no generation" {
    _check_report_header "$R/install_amneziawg_en.sh"
}

@test "RU: --help presents the 2.0 fallback as the installer's choice" {
    _check_text "$R/install_amneziawg.sh" show_help 'не поднять' 'установщик 3.1 не ставит' 2
}

@test "EN: --help presents the 2.0 fallback as the installer's choice" {
    _check_text "$R/install_amneziawg_en.sh" show_help 'cannot run' 'the installer does not set up 3.1' 2
}

@test "RU: fallback warning presents 2.0 as the installer's choice" {
    _check_text "$R/install_amneziawg.sh" _awg31_announce_fallback 'не поднять' 'установщик 3.1 не ставит' 1
}

@test "EN: fallback warning presents 2.0 as the installer's choice" {
    _check_text "$R/install_amneziawg_en.sh" _awg31_announce_fallback 'cannot run' 'the installer does not set up 3.1' 1
}

# The 5.15 floor is about building the module at all, whatever the generation:
# a 3.1 install printed "OK for the AmneziaWG 2.0 module" (quoted in I#352).
@test "RU: the kernel floor check names no generation" {
    _check_text "$R/install_amneziawg.sh" check_kernel_version 'AmneziaWG 2.0' 'сборки модуля AmneziaWG' 3
}

@test "EN: the kernel floor check names no generation" {
    _check_text "$R/install_amneziawg_en.sh" check_kernel_version 'AmneziaWG 2.0' 'build the AmneziaWG module' 3
}

@test "both: the kernel floor check names no generation number at all" {
    local f body
    for f in "$R/install_amneziawg.sh" "$R/install_amneziawg_en.sh"; do
        body=$(_func "$f" check_kernel_version)
        [ -n "$body" ]
        if grep -qE 'AmneziaWG [0-9]' <<<"$body"; then return 1; fi
    done
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
