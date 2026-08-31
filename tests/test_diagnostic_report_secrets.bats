#!/usr/bin/env bats
# _mask_report_secrets must strip key values from the diagnostic report, and must
# not damage anything else in it.
#
# The report exists to be pasted into a public issue: the bug report template asks
# for its contents. Until this guard existed it masked exactly one line,
# "PrivateKey = ...", and printed the rest of the server config verbatim, so a user
# who had created clients with --psk published the PresharedKey of every peer.
#
# SCOPE, so the header does not promise more than the file delivers: these checks
# exercise the FILTER, lifted out of the shipped installer, plus a textual check
# that the report is piped through it. create_diagnostic_report itself is not
# executed here (it shells out to awg, journalctl, systemctl, ip, ss, ufw, dkms and
# modinfo); it is covered by a live run on a real server instead.
#
# Every SECRET line in the sample carries its own SEC marker, so a failure names the
# exact form that leaked. KEEP markers are the negative controls: an earlier
# unanchored version of the filter stripped values wherever a key name appeared,
# which destroyed a server name, because that field is free text and may legitimately
# contain "PrivateKey = ...".
#
# The forms come from reading upstream amneziawg-tools, not from caution:
#   * config parsing is case insensitive (config.c, get_value -> strncasecmp);
#   * config parsing removes whitespace before parsing (config.c, config_read_line),
#     so a value split by spaces is a valid record and must be masked to end of line;
#   * on an unrecognized line awg prints it to stderr ALREADY CLEANED and wrapped in
#     a backtick and a quote: Line unrecognized: `PrivateKey=VALUE'
#     The report shows two variants: bare, because the journal section runs
#     journalctl --output=cat, and timestamped, because systemctl status -l adds its
#     own prefix;
#   * a malformed key produces "Key is not the correct length or format: `VALUE'",
#     which carries NO key name at all;
#   * awg show hides the private and preshared keys but prints the header protection
#     key in clear text (show.c: key() instead of masked_key()).

extract_filter() {
    awk '/^_mask_report_secrets\(\) \{/,/^\}/' "$1"
}

RU_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg.sh"; }
EN_INSTALL() { echo "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; }
TEMPLATE()   { echo "$BATS_TEST_DIRNAME/../.github/ISSUE_TEMPLATE/bug_report.yml"; }

sample_report() {
    printf '%s\n' \
        '[Interface]' \
        'PrivateKey = SEC1AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        'presharedkey = SEC2AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        'PRESHAREDKEY=SEC3AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        '# PresharedKey = SEC4AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        'PrivateKey = SEC5AAAAAAAA SEC5BBBBBBBB SEC5CCCCCCCC==' \
        'HeaderProtectionKey = SEC6AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        "Line unrecognized: \`HeaderProtectionKey=SEC7AAAAAAAAAAAA='" \
        "Aug 25 07:00:00 h awg-quick[1]: Line unrecognized: \`PresharedKey=SEC12AAAAAAAA='" \
        "Key is not the correct length or format: \`SEC8AAAAAAAAAAAA='" \
        '  private key: SEC9AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        '  preshared key: SEC10AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        '  header protection key: SEC11AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        'PublicKey = KEEP1PUBLICAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        '  public key: KEEP2PUBLICAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
        '#_Name = KEEP3-ivan-iphone' \
        "export AWG_SERVER_NAME='KEEP4 PrivateKey = Office'" \
        'PrivateKeyFile = /root/awg/keys/KEEP5.key' \
        'AllowedIPs = 10.9.9.2/32' \
        'export AWG_I1=<b 0xKEEP6>' \
        'PresharedKey = '
}

run_filter() {
    local block
    block=$(extract_filter "$1")
    [ -n "$block" ] || return 1
    eval "$block"
    sample_report | _mask_report_secrets
}

# ===========================================================================
# static: the filter exists and the report is piped through it
# ===========================================================================

# The body of create_diagnostic_report, so a wiring check cannot be satisfied by a
# mention of the pipeline somewhere else in the file.
report_fn() {
    awk '/^create_diagnostic_report\(\) \{/,/^\}/' "$1"
}

# Two mutants motivate this being structural rather than textual, both of which a
# plain `grep -qF` accepted while the report went out unfiltered:
#   A. detach the pipeline and leave the old line in a comment;
#   B. keep the pipeline and append the raw server config to $rf afterwards.
assert_wiring() {
    local body
    body=$(report_fn "$1")
    [ -n "$body" ]
    # the pipeline must be executable code, not a comment
    grep -qE '^[[:space:]]*\} \| _mask_report_secrets > "\$rf"' <<< "$body"
    # and it must be the ONLY writer of the report file
    [ "$(grep -cE '>>?[[:space:]]*"\$rf"' <<< "$body")" -eq 1 ]
}

@test "diag secrets: RU install defines the filter and pipes the report through it" {
    grep -q '^_mask_report_secrets() {' "$(RU_INSTALL)"
    assert_wiring "$(RU_INSTALL)"
}

@test "diag secrets: EN install defines the filter and pipes the report through it" {
    grep -q '^_mask_report_secrets() {' "$(EN_INSTALL)"
    assert_wiring "$(EN_INSTALL)"
}

@test "diag secrets: a failed write or filter is fatal, not a logged warning" {
    # The report is meant to be pasted into a public issue. An empty or truncated
    # file announced with a success line and exit 0 is worse than a loud failure:
    # log_error returns success, so without die the branch ends with exit 0.
    # The `log_error` half is written with `run` and an explicit status check,
    # not as a bare `! grep`. Inside a loop an inverted command is checked by
    # `set -e` only on the FINAL iteration: a failure on the first one (the RU
    # installer) was silently discarded, so this assertion used to cover the EN
    # installer alone. `run` records the status instead of letting the shell
    # decide, which makes the check work in any position.
    for inst in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        body=$(report_fn "$inst")
        grep -qE '_mask_report_secrets > "\$rf" \|\| die ' <<< "$body"
        run grep -qE '_mask_report_secrets > "\$rf" \|\| log_error' <<< "$body"
        [ "$status" -ne 0 ]
    done
}

@test "diag secrets: the server config section runs through the same filter" {
    # Two enforcement points, one implementation: if the outer pipeline is ever
    # detached from the block, the raw server config stays covered.
    grep -qF '_mask_report_secrets < "$SERVER_CONF_FILE"' "$(RU_INSTALL)"
    grep -qF '_mask_report_secrets < "$SERVER_CONF_FILE"' "$(EN_INSTALL)"
}

# ===========================================================================
# functional: the shipped filter, executed
# ===========================================================================

@test "diag secrets: RU, every secret form is masked" {
    out=$(run_filter "$(RU_INSTALL)")
    # Positive assertions first, same reason as in the EN twin: a test made only of
    # negatives passes on empty output, and an accidental `sed -n` produces exactly
    # that with a zero exit status.
    grep -qx '\[Interface\]' <<< "$out"
    grep -qx 'PrivateKey = \[HIDDEN\]' <<< "$out"
    [[ "$out" == *KEEP1PUBLIC* ]]
    [[ "$out" != *SEC1* ]]    # plain config line
    [[ "$out" != *SEC2* ]]    # lowercase key name
    [[ "$out" != *SEC3* ]]    # uppercase, no spaces around =
    [[ "$out" != *SEC4* ]]    # commented out
    [[ "$out" != *SEC5* ]]    # value split by whitespace, still a valid record
    [[ "$out" != *SEC6* ]]    # HeaderProtectionKey in the config
    [[ "$out" != *SEC7* ]]    # journal, bare (journalctl --output=cat)
    [[ "$out" != *SEC12* ]]   # journal, with a systemctl status timestamp
    [[ "$out" != *SEC8* ]]    # journal, malformed key, message carries no key name
    [[ "$out" != *SEC9* ]]    # awg show, clear private key (WG_HIDE_KEYS=never)
    [[ "$out" != *SEC10* ]]   # awg show, preshared key
    [[ "$out" != *SEC11* ]]   # awg show, header protection key
}

@test "diag secrets: EN, every secret form is masked and the KEEP cases survive" {
    out=$(run_filter "$(EN_INSTALL)")
    # Positive assertions first: an all-negative test would pass on empty output.
    grep -qx '\[Interface\]' <<< "$out"
    grep -qx 'PrivateKey = \[HIDDEN\]' <<< "$out"
    grep -qx '  preshared key: (hidden)' <<< "$out"
    [[ "$out" == *KEEP1PUBLIC* ]]
    grep -qx '#_Name = KEEP3-ivan-iphone' <<< "$out"
    # The case the whole rewrite exists for, checked in EN too: the two installers
    # are edited separately, so a divergence would appear exactly here.
    grep -qxF "export AWG_SERVER_NAME='KEEP4 PrivateKey = Office'" <<< "$out"
    [[ "$out" != *SEC1* ]]
    [[ "$out" != *SEC2* ]]
    [[ "$out" != *SEC3* ]]
    [[ "$out" != *SEC4* ]]
    [[ "$out" != *SEC5* ]]
    [[ "$out" != *SEC6* ]]
    [[ "$out" != *SEC7* ]]
    [[ "$out" != *SEC12* ]]
    [[ "$out" != *SEC8* ]]
    [[ "$out" != *SEC9* ]]
    [[ "$out" != *SEC10* ]]
    [[ "$out" != *SEC11* ]]
}

@test "diag secrets: not one SEC marker of any kind is left" {
    # Backstop: if a form is added to the sample and its own assertion is
    # forgotten, this one still fails.
    out=$(run_filter "$(RU_INSTALL)")
    ! grep -q SEC <<< "$out"
}

@test "diag secrets: config-file spelling keeps its key name and marker" {
    out=$(run_filter "$(RU_INSTALL)")
    grep -qx 'PrivateKey = \[HIDDEN\]' <<< "$out"
    grep -qx 'presharedkey = \[HIDDEN\]' <<< "$out"
    grep -qx 'PRESHAREDKEY=\[HIDDEN\]' <<< "$out"
    grep -qx 'HeaderProtectionKey = \[HIDDEN\]' <<< "$out"
    # An empty value must still be marked, not silently left alone.
    grep -qx 'PresharedKey = \[HIDDEN\]' <<< "$out"
}

@test "diag secrets: awg show spelling keeps its label and marker" {
    out=$(run_filter "$(RU_INSTALL)")
    # The sample feeds CLEAR values here, not already hidden ones: otherwise
    # these checks would pass with no filter at all.
    grep -qx '  private key: (hidden)' <<< "$out"
    grep -qx '  preshared key: (hidden)' <<< "$out"
    grep -qx '  header protection key: (hidden)' <<< "$out"
}

@test "diag secrets: journal lines in the real upstream format are masked" {
    # The exact shape matters: upstream wraps the cleaned line in a backtick and a
    # quote. A fixture without the backtick would leave the one regex character
    # that exists for it untested, and removing that character would still keep
    # every check green while the real line leaked in full.
    out=$(run_filter "$(RU_INSTALL)")
    grep -q 'Line unrecognized: `HeaderProtectionKey=\[HIDDEN\]' <<< "$out"
    grep -q 'Line unrecognized: `PresharedKey=\[HIDDEN\]' <<< "$out"
    grep -q 'Key is not the correct length or format: \[HIDDEN\]' <<< "$out"
    # The timestamped variant must keep its prefix readable.
    grep -q 'awg-quick\[1\]: Line unrecognized:' <<< "$out"
}

@test "diag secrets: everything that is not a key survives untouched" {
    out=$(run_filter "$(RU_INSTALL)")
    # A public key is not a secret and peers cannot be correlated without it.
    [[ "$out" == *KEEP1PUBLIC* ]]
    [[ "$out" == *KEEP2PUBLIC* ]]
    grep -qx '#_Name = KEEP3-ivan-iphone' <<< "$out"
    # A server name is FREE TEXT and may contain "PrivateKey = ...". An earlier
    # unanchored filter ate this line together with its closing quote.
    grep -qxF "export AWG_SERVER_NAME='KEEP4 PrivateKey = Office'" <<< "$out"
    # A path is not a key: the pattern requires = right after the key name.
    grep -qx 'PrivateKeyFile = /root/awg/keys/KEEP5.key' <<< "$out"
    grep -qx 'AllowedIPs = 10.9.9.2/32' <<< "$out"
    [[ "$out" == *KEEP6* ]]
}

@test "diag secrets: filtering an already filtered report does not double the markers" {
    # Plain "once == twice" is satisfied by a filter that matches nothing, so it
    # proves little on its own. Assert the property that actually matters: the
    # markers already present are not wrapped again.
    block=$(extract_filter "$(RU_INSTALL)")
    eval "$block"
    once=$(sample_report | _mask_report_secrets)
    twice=$(sample_report | _mask_report_secrets | _mask_report_secrets)
    [ "$once" = "$twice" ]
    [[ "$once" == *"[HIDDEN]"* ]]
    [[ "$once" == *"(hidden)"* ]]
    [[ "$twice" != *"[HIDDEN][HIDDEN]"* ]]
    [[ "$twice" != *"(hidden)(hidden)"* ]]
}

@test "diag secrets: a CRLF line is masked in both installers" {
    for inst in "$(RU_INSTALL)" "$(EN_INSTALL)"; do
        block=$(extract_filter "$inst")
        eval "$block"
        out=$(printf 'PrivateKey = SECCRLFAAAAAAAAAAAA=\r\nPublicKey = KEEPCRLF=\r\n' | _mask_report_secrets)
        [[ "$out" != *SECCRLF* ]]
        [[ "$out" == *KEEPCRLF* ]]
    done
}

@test "diag secrets: the report warning and the issue template both name the keys" {
    # The old warning listed only IPs, ports and routes, so a reader concluded
    # nothing else was in there. The issue template had the same gap: it asked to
    # mask "public IPs, ports, routes" and never mentioned keys at all.
    # The guarantee must be NARROW: the mechanism recognises a key by its name or
    # by an awg show label, so an unlabelled value (a future `awg show all dump`
    # section, say) would not be covered and an unconditional promise would lie.
    grep -qF 'PresharedKey и HeaderProtectionKey' "$(RU_INSTALL)"
    grep -qF 'подписаны своим именем или меткой awg show' "$(RU_INSTALL)"
    grep -qF 'PresharedKey and HeaderProtectionKey' "$(EN_INSTALL)"
    grep -qF 'labelled by name or by an awg show label' "$(EN_INSTALL)"
    grep -qF 'PresharedKey' "$(TEMPLATE)"
    grep -qF 'HeaderProtectionKey' "$(TEMPLATE)"
    # and it must still name what is deliberately kept
    grep -qF 'client names' "$(TEMPLATE)"
    grep -qF 'public keys' "$(TEMPLATE)"
}
