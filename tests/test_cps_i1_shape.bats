#!/usr/bin/env bats
# generate_cps_i1: the shape of the I1 concealment packet.
#
# 🔴 The defect this file guards against is a PRODUCTION one, measured on a live
# Russian cellular network on 10 sep 2026: an I1 made of pure random bytes
# (`<r 32..256>`, what the generator emitted until that day) prevents the
# handshake from ever completing on that route. The decisive pair was two
# profiles of the SAME 128-byte size - random failed, DNS-shaped succeeded - so
# the property under test is the packet's STRUCTURE, not a size bound.
#
# The tests are written to fail on the plausible wrong repairs too: going back
# to a bare `<r N>` under a smaller bound, freezing a static blob, or letting a
# declared count drift away from the bytes that follow it. A packet whose header
# disagrees with its body is worse than a random one - it is a marker.
#
# ⚠️ What these tests do NOT cover, so that nobody reads more into a green run:
# they check the STRING the installer writes into the config, not the bytes on
# the wire. Whether `<r>` and `<rc>` really expand per packet is a property of
# the kernel module and of amneziawg-go, and it is not observable from here.

I1_RE='^<r 2><b 0x([0-9a-f]+)><rc ([0-9]+)><b 0x([0-9a-f]+)>$'
QTAIL='0463646e730669636c6f756403636f6d0000010001'
RR=32          # hex characters per answer record: 16 bytes

gen() {  # gen <installer> [count]
    bash -c '
        eval "$(sed -n "/^rand_range()/,/^}/p" "$1")"
        eval "$(sed -n "/^generate_cps_i1()/,/^}/p" "$1")"
        for _ in $(seq 1 "$2"); do generate_cps_i1; done
    ' _ "$1" "${2:-1}"
}

gen_stub() {  # gen_stub <installer> <rand_range replacement>
    bash -c '
        eval "$(sed -n "/^generate_cps_i1()/,/^}/p" "$1")"
        eval "$2"
        generate_cps_i1
    ' _ "$1" "$2"
}

decoded_size() {  # decoded_size <string>
    bash -c 'source "$1" >/dev/null 2>&1 || true; awg_cps_decoded_size "$2"' _ "$COMMON" "$1"
}

setup() {
    RU="${BATS_TEST_DIRNAME}/../install_amneziawg.sh"
    EN="${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"
    COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
}

# ------------------------------------------------------------------- structure

@test "cps i1: the packet is DNS-shaped, not a bare random blob" {
    # The whole regression in one assertion: `<r 128>` does not match.
    local v; v=$(gen "$RU")
    [[ "$v" =~ $I1_RE ]]
}

@test "cps i1: the EN installer emits the same shape" {
    local v; v=$(gen "$EN")
    [[ "$v" =~ $I1_RE ]]
}

@test "cps i1: no lone random tag large enough to be the old generator" {
    # `<r 2>` is the DNS transaction id and must stay. Anything larger means the
    # random blob is back, possibly hidden under a smaller upper bound.
    local n line seen=0
    while read -r line; do
        [ -n "$line" ] || continue
        seen=$(( seen + 1 ))
        while [[ "$line" =~ \<r\ ([0-9]+)\> ]]; do
            n="${BASH_REMATCH[1]}"
            [ "$n" -le 2 ] || { echo "random tag of $n bytes in: $line"; false; }
            line="${line#*"${BASH_REMATCH[0]}"}"
        done
    done <<< "$(gen "$RU" 5)"
    # 🔴 Без счётчика тест пуст на нулевой выборке: подстановка команд внутри
    # here-string код возврата теряет, единственная пустая строка отсеивается
    # первым же continue, и тело не исполняется ни разу.
    [ "$seen" -eq 5 ] || { echo "generator produced $seen lines out of 5"; false; }
}

@test "cps i1: only tags both implementations understand" {
    # `<c>` exists in the kernel module and not in amneziawg-go; `<d>`/`<ds>`/
    # `<dz>` the other way round. Either one makes the profile non-portable and
    # the interface fails to come up on the side that does not know the tag.
    local v tag; v=$(gen "$RU" 3)
    # 🔴 Один разбор, а не два по очереди. Прежняя редакция пробовала сперва
    # "<тег пробел", и бесаргументный тег ПЕРЕД теговым с пробелом
    # перепрыгивался: на строке `<r 2><c><b 0x41>` она видела <r> и <b>, а <c>
    # не смотрела вовсе. То есть тест с таким именем не давал того, что обещал.
    # Форма ниже - та же, какой разбирает строку awg_cps_decoded_size.
    while [[ "$v" =~ \<[[:space:]]*([a-zA-Z]+)[[:space:]]*([^\>]*)\> ]]; do
        tag="${BASH_REMATCH[1]}"
        case "$tag" in
            b|r|rc|rd|t) : ;;
            *) echo "non-portable tag <$tag> in: $v"; false ;;
        esac
        v="${v#*"${BASH_REMATCH[0]}"}"
    done
}

# ----------------------------------------------------- header agrees with body

@test "cps i1: the header declares one question and no authority records" {
    local v hdr; v=$(gen "$RU")
    [[ "$v" =~ $I1_RE ]]
    hdr="${BASH_REMATCH[1]}"
    [ "${#hdr}" -eq 22 ]                 # 10 header bytes + the label length
    [ "${hdr:0:4}" = "8580" ]            # the vendor's own flag word
    [ "${hdr:4:4}" = "0001" ]            # exactly one question
    [ "${hdr:12:8}" = "00000000" ]       # no authority, no additional
}

@test "cps i1: the declared label length matches the label that follows" {
    # 🔴 The failure mode this catches is silent: a name whose length byte lies
    # about the bytes after it stops being a DNS message and becomes a marker.
    local v hdr label declared
    for _ in 1 2 3 4 5; do
        v=$(gen "$RU")
        [[ "$v" =~ $I1_RE ]]
        hdr="${BASH_REMATCH[1]}"; label="${BASH_REMATCH[2]}"
        declared=$((16#${hdr:20:2}))
        [ "$declared" -eq "$label" ] || { echo "length byte $declared, label $label"; false; }
        [ "$label" -le 63 ] || { echo "label $label exceeds the DNS limit"; false; }
    done
}

@test "cps i1: every answer record is a well-formed A record for the question" {
    # 🔴 Counting records is not enough: a pointer to an offset outside the
    # packet, or an RDLENGTH that disagrees with the bytes present, keeps every
    # length intact and still produces something no resolver would emit. Both
    # were named by an outside review as mutations the first version of this
    # file let through, so each field is now read rather than assumed.
    local v hdr body an bytes records rec off ttl first o1 o4
    for _ in 1 2 3 4 5; do
        v=$(gen "$RU")
        [[ "$v" =~ $I1_RE ]]
        hdr="${BASH_REMATCH[1]}"; body="${BASH_REMATCH[3]}"
        [ "${body:0:${#QTAIL}}" = "$QTAIL" ]
        an=$((16#${hdr:8:4}))
        bytes=$(( (${#body} - ${#QTAIL}) / 2 ))
        [ $(( bytes % 16 )) -eq 0 ] || { echo "answer section $bytes bytes, not a multiple of 16"; false; }
        records=$(( bytes / 16 ))
        [ "$records" -eq "$an" ] || { echo "ancount=$an, records=$records"; false; }
        [ "$an" -ge 1 ]
        first=""
        for (( off = ${#QTAIL}; off < ${#body}; off += RR )); do
            rec="${body:off:RR}"
            [ "${rec:0:4}"  = "c00c" ] || { echo "pointer ${rec:0:4}, expected c00c"; false; }
            [ "${rec:4:4}"  = "0001" ] || { echo "type ${rec:4:4}, expected A"; false; }
            [ "${rec:8:4}"  = "0001" ] || { echo "class ${rec:8:4}, expected IN"; false; }
            [ "${rec:20:4}" = "0004" ] || { echo "rdlength ${rec:20:4}, expected 0004"; false; }
            ttl="${rec:12:8}"
            # Мутационный замер показал, что одного сравнения TTL между
            # записями мало: нулевой TTL и 0xffffffff проходили молча, а это
            # ровно примета, от которой уходили. Значение обязано быть одним из
            # разыгрываемых генератором.
            case "$ttl" in
                0000003c|0000012c|00000384|00000e10) : ;;
                *) echo "implausible TTL $ttl"; false ;;
            esac
            [ -n "$first" ] || first="$ttl"
            # Records of one set share a TTL. An independent draw per record is
            # the kind of detail a forgery is spotted by.
            [ "$ttl" = "$first" ] || { echo "TTLs differ inside one answer set: $first vs $ttl"; false; }
            o1=$((16#${rec:24:2}))
            [ "$o1" -ge 1 ] && [ "$o1" -le 223 ] && [ "$o1" -ne 10 ] && [ "$o1" -ne 127 ] \
                || { echo "implausible first octet $o1"; false; }
            # Последний октет не должен быть адресом сети или широковещательным.
            o4=$((16#${rec:30:2}))
            [ "$o4" -ge 1 ] && [ "$o4" -le 254 ] \
                || { echo "implausible last octet $o4"; false; }
        done
    done
}

@test "cps i1: every literal tag carries whole bytes" {
    # An odd number of hex characters is rejected by both implementations, and
    # our own size accounting marks it as unparsed rather than guessing.
    local v; v=$(gen "$RU")
    [[ "$v" =~ $I1_RE ]]
    [ $(( ${#BASH_REMATCH[1]} % 2 )) -eq 0 ]
    [ $(( ${#BASH_REMATCH[3]} % 2 )) -eq 0 ]
}

# ----------------------------------------------- deterministic range endpoints

@test "cps i1: the smallest packet the generator can emit is 70 bytes" {
    # Random sampling never proves an endpoint was reached. Pinning rand_range
    # to its lower argument does.
    local v n
    v=$(gen_stub "$RU" 'rand_range() { echo "$1"; }')
    [[ "$v" =~ $I1_RE ]]
    n=$(decoded_size "$v")
    [ "$n" -eq 70 ] || { echo "lower endpoint is $n, expected 70: $v"; false; }
    # The last octet must never be .0: with the draw pinned to its minimum this
    # is deterministic, whereas random sampling hits the endpoint about once in
    # two hundred runs and a widened range slips through unnoticed.
    [ "${BASH_REMATCH[3]:${#QTAIL}+30:2}" = "01" ] \
        || { echo "last octet at the lower endpoint is ${BASH_REMATCH[3]:${#QTAIL}+30:2}, expected 01"; false; }
    # The TTL arm is likewise pinned here. Sampling the real draw catches a bad
    # TTL only about three runs in four, which is a flaky guard rather than one.
    [ "${BASH_REMATCH[3]:${#QTAIL}+12:8}" = "0000003c" ] \
        || { echo "first TTL arm is ${BASH_REMATCH[3]:${#QTAIL}+12:8}, expected 0000003c"; false; }
}

@test "cps i1: the largest packet the generator can emit is 128 bytes" {
    # 128 is what the measurement covered. Above it nothing was tested, so the
    # generator must not be able to go there on its own.
    local v n
    v=$(gen_stub "$RU" 'rand_range() { echo "$2"; }')
    [[ "$v" =~ $I1_RE ]]
    n=$(decoded_size "$v")
    [ "$n" -eq 128 ] || { echo "upper endpoint is $n, expected 128: $v"; false; }
    # And never .255 at the other end.
    [ "${BASH_REMATCH[3]:${#QTAIL}+30:2}" = "fe" ] \
        || { echo "last octet at the upper endpoint is ${BASH_REMATCH[3]:${#QTAIL}+30:2}, expected fe"; false; }
    # The default arm of the TTL case, reached when the draw is pinned high.
    [ "${BASH_REMATCH[3]:${#QTAIL}+12:8}" = "00000e10" ] \
        || { echo "default TTL arm is ${BASH_REMATCH[3]:${#QTAIL}+12:8}, expected 00000e10"; false; }
}

@test "cps i1: a first octet of 10 is remapped onto 222, not left private" {
    # The two special values are remapped one-to-one rather than redrawn or
    # collapsed onto a single constant. A constant would occur twice as often as
    # any other value and would become a marker of its own; a redraw loop would
    # be state inside a subshell, which is what made an earlier version of this
    # very test hang forever.
    local v rec
    v=$(gen_stub "$RU" 'rand_range() { if [ "$1" = "1" ] && [ "$2" = "221" ]; then echo 10; else echo "$1"; fi; }')
    [[ "$v" =~ $I1_RE ]]
    rec="${BASH_REMATCH[3]:${#QTAIL}:RR}"
    [ "${rec:24:2}" = "de" ] || { echo "first octet ${rec:24:2}, expected de (222)"; false; }
}

@test "cps i1: a first octet of 127 is remapped onto 223, not left loopback" {
    local v rec
    v=$(gen_stub "$RU" 'rand_range() { if [ "$1" = "1" ] && [ "$2" = "221" ]; then echo 127; else echo "$1"; fi; }')
    [[ "$v" =~ $I1_RE ]]
    rec="${BASH_REMATCH[3]:${#QTAIL}:RR}"
    [ "${rec:24:2}" = "df" ] || { echo "first octet ${rec:24:2}, expected df (223)"; false; }
}

@test "cps i1: an ordinary first octet is passed through untouched" {
    # Proves the remap is a mapping and not a filter that rewrites everything.
    local v rec
    v=$(gen_stub "$RU" 'rand_range() { if [ "$1" = "1" ] && [ "$2" = "221" ]; then echo 42; else echo "$1"; fi; }')
    [[ "$v" =~ $I1_RE ]]
    rec="${BASH_REMATCH[3]:${#QTAIL}:RR}"
    [ "${rec:24:2}" = "2a" ] || { echo "first octet ${rec:24:2}, expected 2a (42)"; false; }
}

# ------------------------------------------------------------ size and change

@test "cps i1: the measured size window holds across a run of samples" {
    # 🔴 The bounds alone are not a test: with no samples at all an untouched
    # minimum and a zero maximum satisfy both of them, so an empty generator
    # would pass. The sample count is asserted first for exactly that reason.
    local n rc lo=9999 hi=0 seen=0 line
    while read -r line; do
        [ -n "$line" ] || continue
        n=$(decoded_size "$line")
        rc=$?
        [ "$rc" -eq 0 ] || { echo "our own decoder could not parse: $line"; false; }
        seen=$(( seen + 1 ))
        # `if` rather than `&&`: a trailing AND-list that evaluates false is the
        # last command of the loop body, and under the errexit bats runs tests
        # with that aborts the whole test on an ordinary sample.
        if [ "$n" -lt "$lo" ]; then lo="$n"; fi
        if [ "$n" -gt "$hi" ]; then hi="$n"; fi
    done <<< "$(gen "$RU" 20)"
    [ "$seen" -eq 20 ] || { echo "generator produced $seen lines out of 20"; false; }
    [ "$lo" -le "$hi" ]
    echo "size range $lo..$hi over $seen samples"
    [ "$lo" -ge 70 ]
    [ "$hi" -le 128 ]
}

@test "cps i1: two installations do not get the same string" {
    # A static blob is what upstream objects to: it becomes a signature of every
    # server that ships it. ⚠️ This says nothing about per-packet variation on
    # the wire - that comes from the `<r>`/`<rc>` tags, whose presence the shape
    # test asserts, and it is not observable from here.
    local a b c
    a=$(gen "$RU"); b=$(gen "$RU"); c=$(gen "$RU")
    [ "$a" != "$b" ] || [ "$b" != "$c" ]
}

@test "cps i1: the two installers agree on the generator, comments aside" {
    # Comments are stripped and indentation normalised, but whitespace INSIDE
    # the code is kept: collapsing it would hide a difference in a quoted hex
    # string, which is the one place where a stray space changes the packet.
    local ru en
    ru=$(sed -n '/^generate_cps_i1()/,/^}/p' "$RU" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')
    en=$(sed -n '/^generate_cps_i1()/,/^}/p' "$EN" | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')
    [ "$ru" = "$en" ]
}

# ---------------------------------------------- the diagnostic and the default

# 🔴 Why this section exists. `manage_*.sh diagnose` compares the installed I1
# against a per-carrier profile, and for the carriers whose profile says
# `random` it used to accept only a bare `<r N>`. The moment the generator
# started emitting a shaped packet, that check began calling our OWN fresh
# default an "unusual format" and pointing the user back at random bytes -
# the exact thing measured as not working on MTS. A wrong signal from our own
# diagnostic is worse than no signal, so the branch is exercised here directly.

diag_random() {  # diag_random <manage script> <i1 value> -> "ok=N warn=N"
    # awg_common.sh is sourced because the branch calls awg_cps_decoded_size,
    # exactly as the real diagnose does. A harness without it would take the
    # else path and the test would pass for the wrong reason.
    bash -c '
        source "$3" >/dev/null 2>&1 || true
        block=$(sed -n "/^            random)$/,/^                ;;$/p" "$1")
        [ -n "$block" ] || { echo "case block not found in $1"; exit 1; }
        i1="$2"; carrier="beeline_msk"; ok=0; warn=0
        _diag_line() { :; }
        eval "case random in
$block
esac" >/dev/null
        printf "ok=%s warn=%s" "$ok" "$warn"
    ' _ "$1" "$2" "$COMMON"
}

@test "cps i1 diag: the carrier check does not scold the generator's own output" {
    local v out
    v=$(gen "$RU")
    out=$(diag_random "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" "$v")
    [ "$out" = "ok=1 warn=0" ] || { echo "$out for $v"; false; }
}

@test "cps i1 diag: the EN management script agrees" {
    local v out
    v=$(gen "$EN")
    out=$(diag_random "${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh" "$v")
    [ "$out" = "ok=1 warn=0" ] || { echo "$out for $v"; false; }
}

@test "cps i1 diag: a bare random I1 is still accepted where the profile expects it" {
    # The carrier profiles were measured on `<r N>`. Accepting the shaped packet
    # must not quietly stop accepting the form the profile was built on.
    local out
    out=$(diag_random "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" '<r 128>')
    [ "$out" = "ok=1 warn=0" ] || { echo "$out"; false; }
}

@test "cps i1 diag: the check can still warn" {
    # Without this the section above would pass on a branch that accepts
    # everything, which is the same silence it was written to remove.
    local out
    out=$(diag_random "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" 'not-a-tag')
    [ "$out" = "ok=0 warn=1" ] || { echo "$out for garbage"; false; }
    out=$(diag_random "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" '')
    [ "$out" = "ok=0 warn=1" ] || { echo "$out for empty"; false; }
}

@test "cps i1 diag: a random blob with a literal tail is not blessed as shaped" {
    # 🔴 The first version of the branch matched `<b 0x...>` as a SUBSTRING, so
    # `<r 200><b 0xaa>` - two hundred random bytes with a one-byte tail - was
    # reported as a shaped packet. That is the very case the measurement ruled
    # out, and the diagnostic would have told the user it was fine. Caught by an
    # outside review, not by the first version of these tests.
    local out
    for bad in '<r 200><b 0xaa>' '<b 0xf1>' 'junk<b 0x0463646e730669636c6f756403636f6d>tail'; do
        out=$(diag_random "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" "$bad")
        [ "$out" = "ok=0 warn=1" ] || { echo "$out for $bad"; false; }
    done
}

@test "cps i1 diag: a structured but unparsable value is not blessed either" {
    # Odd hex: both implementations reject the tag and our own counter marks it
    # as unparsed. It matches the shape prefix, so only the parse check catches
    # it - which is why the branch requires both.
    local out
    out=$(diag_random "${BATS_TEST_DIRNAME}/../manage_amneziawg.sh" '<r 2><b 0x858000010002000000003>')
    [ "$out" = "ok=0 warn=1" ] || { echo "$out"; false; }
}

# ------------------------------------------------------ the documented sample

@test "cps i1 docs: the I1 samples in ADVANCED are packets the generator could emit" {
    # 🔴 They were not. The sample first published here carried two answer
    # records with DIFFERENT TTLs - the exact defect the generator was changed
    # to avoid, printed in six places as "what the installer writes now". A
    # reader copying it would install a slightly implausible packet, and the
    # docs would contradict the code comment three lines away.
    local doc line body off rec first seen=0
    for doc in "${BATS_TEST_DIRNAME}/../ADVANCED.md" "${BATS_TEST_DIRNAME}/../ADVANCED.en.md"; do
        while read -r line; do
            [ -n "$line" ] || continue
            seen=$(( seen + 1 ))
            [[ "$line" =~ $I1_RE ]] || { echo "not generator-shaped in $doc: $line"; false; }
            body="${BASH_REMATCH[3]}"
            [ "${body:0:${#QTAIL}}" = "$QTAIL" ] || { echo "question tail differs in $doc"; false; }
            first=""
            for (( off = ${#QTAIL}; off < ${#body}; off += RR )); do
                rec="${body:off:RR}"
                [ "${rec:0:4}"  = "c00c" ] || { echo "pointer ${rec:0:4} in $doc"; false; }
                [ "${rec:20:4}" = "0004" ] || { echo "rdlength ${rec:20:4} in $doc"; false; }
                [ -n "$first" ] || first="${rec:12:8}"
                [ "${rec:12:8}" = "$first" ] || { echo "TTLs differ in the $doc sample"; false; }
            done
        done <<< "$(grep -hoP "(?<=^I1 = ).*|(?<=export AWG_I1=').*(?=')" "$doc" || true)"
    done
    # If the samples ever move or get renamed, this test must not quietly stop
    # checking anything at all.
    [ "$seen" -ge 6 ] || { echo "found only $seen I1 samples in ADVANCED, expected at least 6"; false; }
}

# ---------------------------------------------------------- the vpn:// budget

@test "cps i1 budget: the vpn:// URI keeps headroom under the QR byte-mode cap" {
    # 🔴 Why a budget test exists at all. Issue #72 was a real qrencode refusal:
    # the URI reached about 2929 bytes against the 2953-byte ceiling of version
    # 40 byte-mode at error-correction level L, that is 24 bytes of headroom.
    # The default I1 grew from 7 characters to about 150, and it lands in the
    # payload TWICE - as the `I1` field and inside the embedded config - so the
    # change spends roughly a hundred of those bytes. The existing QR test
    # replaces qrencode with a shim that only inspects flags, so nothing was
    # watching the size itself. This test needs neither qrencode nor a network.
    command -v perl >/dev/null || skip "perl not available"
    perl -MCompress::Zlib -MMIME::Base64 -e 1 2>/dev/null || skip "perl zlib/base64 not available"

    local dir i1 uri len
    dir=$(mktemp -d)
    i1=$(gen_stub "$RU" 'rand_range() { echo "$2"; }')          # the largest I1 possible
    echo "ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210zyxwvut=" > "$dir/server_public.key"
    {
        echo "export AWG_PORT='51830'"
        echo "export AWG_Jc='6'"; echo "export AWG_Jmin='55'"; echo "export AWG_Jmax='205'"
        echo "export AWG_S1='72'"; echo "export AWG_S2='56'"; echo "export AWG_S3='32'"; echo "export AWG_S4='16'"
        echo "export AWG_H1='234567-345678'"; echo "export AWG_H2='3456789-4567890'"
        echo "export AWG_H3='56789012-67890123'"; echo "export AWG_H4='456789012-567890123'"
        echo "export AWG_I1='$i1'"
        echo "export AWG_SERVER_NAME='AWG Server'"
    } > "$dir/awgsetup_cfg.init"
    {
        echo "[Interface]"
        echo "PrivateKey = aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789abcdefg="
        echo "Address = 10.9.9.2/32"
        echo "DNS = 1.1.1.1, 8.8.8.8"
        echo "MTU = 1280"
        echo "I1 = $i1"
        echo ""
        echo "[Peer]"
        echo "PublicKey = ZyXwVuTsRqPoNmLkJiHgFeDcBa9876543210zyxwvut="
        echo "PresharedKey = QwErTyUiOpAsDfGhJkLzXcVbNm1234567890qwertyu="
        echo "Endpoint = 203.0.113.10:51830"
        echo "AllowedIPs = 0.0.0.0/0, ::/0"
        echo "PersistentKeepalive = 25"
    } > "$dir/probe.conf"

    uri=$(bash -c '
        source "$1" >/dev/null 2>&1 || true
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        export AWG_DIR="$2" CONFIG_FILE="$2/awgsetup_cfg.init" KEYS_DIR="$2/keys"
        generate_vpn_uri probe >/dev/null 2>&1
        cat "$2/probe.vpnuri" 2>/dev/null
    ' _ "$COMMON" "$dir")
    [ -n "$uri" ] || { rm -rf "$dir"; skip "vpn:// URI could not be generated in this environment"; }
    len=${#uri}
    rm -rf "$dir"
    echo "vpn:// URI is $len bytes, cap 2953"
    # A full-tunnel client with the largest I1 must stay far from the ceiling.
    # The number is asserted, not merely printed: a silent creep towards 2953 is
    # what produced #72 in the first place.
    [ "$len" -lt 1400 ] || { echo "URI grew to $len bytes - headroom under the 2953 cap is shrinking"; false; }
}

# --------------------------------------------------------- the round trip

@test "cps i1: the value survives the config files it travels through" {
    # The generated string carries angle brackets and spaces and is twenty times
    # longer than what used to live here. It is written into the init file as a
    # single-quoted export and into the server config as `I1 = ...`, then read
    # back by two different parsers. Nothing was watching that round trip: a
    # future packet containing a colon would truncate the diagnostic output, and
    # a single quote would tear the init file, both silently.
    local dir v back
    dir=$(mktemp -d)
    v=$(gen "$RU")

    printf "export AWG_I1='%s'
" "$v" > "$dir/awgsetup_cfg.init"
    back=$(bash -c '
        source "$1" >/dev/null 2>&1 || true
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        export CONFIG_FILE="$2" AWG_DIR="$(dirname "$2")"
        safe_load_config "$2" >/dev/null 2>&1
        printf "%s" "${AWG_I1:-}"
    ' _ "$COMMON" "$dir/awgsetup_cfg.init")
    [ "$back" = "$v" ] || { rm -rf "$dir"; echo "init round trip changed the value"; echo "in : $v"; echo "out: $back"; false; }

    # All eleven mandatory fields: the parser exports all-or-nothing and returns
    # 1 if any of them is missing, so a fixture carrying only I1 would fail for
    # the wrong reason. It did, the first time this test was written.
    {
        echo "[Interface]"
        echo "Jc = 6"; echo "Jmin = 55"; echo "Jmax = 205"
        echo "S1 = 72"; echo "S2 = 56"; echo "S3 = 32"; echo "S4 = 16"
        echo "H1 = 234567-345678"; echo "H2 = 3456789-4567890"
        echo "H3 = 56789012-67890123"; echo "H4 = 456789012-567890123"
        echo "I1 = $v"
    } > "$dir/awg0.conf"
    back=$(bash -c '
        source "$1" >/dev/null 2>&1 || true
        log() { :; }; log_warn() { :; }; log_error() { :; }; log_debug() { :; }
        load_awg_params_from_server_conf "$2" >/dev/null 2>&1
        printf "%s" "${AWG_I1:-}"
    ' _ "$COMMON" "$dir/awg0.conf")
    rm -rf "$dir"
    [ "$back" = "$v" ] || { echo "server config round trip changed the value"; echo "in : $v"; echo "out: $back"; false; }

    # No colon: the step-8 diagnostic splits its lines on ": ".
    [[ "$v" != *:* ]]
    # No single quote: the init file quotes the value with one.
    [[ "$v" != *"'"* ]]
}

# ------------------------------------------------ the shape predicate itself

shaped() {  # shaped <value> -> prints yes/no
    bash -c 'source "$1" >/dev/null 2>&1 || true; if awg_cps_is_shaped "$2"; then echo yes; else echo no; fi' _ "$COMMON" "$1"
}

@test "cps i1 shaped: the generator output is accepted at both ends of its range" {
    local lo hi
    lo=$(gen_stub "$RU" 'rand_range() { echo "$1"; }')
    hi=$(gen_stub "$RU" 'rand_range() { echo "$2"; }')
    [ "$(shaped "$lo")" = "yes" ] || { echo "smallest packet rejected: $lo"; false; }
    [ "$(shaped "$hi")" = "yes" ] || { echo "largest packet rejected: $hi"; false; }
}

@test "cps i1 shaped: a mostly-random value is rejected however it is dressed up" {
    # 🔴 Each of these was reported OK by an earlier version of the diagnostic.
    # The first is 99 random bytes with ten literal ones; the second hides a
    # 900-byte random tail behind a correct-looking DNS head and still stays
    # under the 1024-byte size guard, so BOTH guards were silent at once.
    local bad
    for bad in '<r 99><b 0x0102030405060708090a>' '<r 2><b 0x8580000100010000000027><rc 39><b 0x0463646e730669636c6f756403636f6d0000010001><r 900>'; do
        [ "$(shaped "$bad")" = "no" ] || { echo "accepted: $bad"; false; }
    done
}

@test "cps i1 shaped: a non-portable tag is rejected wherever it sits" {
    # `<c>` is kernel-only. A config carrying it does not bring the interface up
    # on amneziawg-go, which is what LXC, Docker, routers and macOS run.
    # 🔴 Строится ИЗ настоящего вывода генератора, а не из короткого огрызка.
    # Первая редакция подавала `<r 2><b 0x8580...><c>` - такое значение
    # отвергается и без правила про теги, просто потому что литеральных байт в
    # нём меньше тридцати. Мутация «перестать отвергать непереносимые теги» этот
    # тест не роняла: он проходил по ДРУГОЙ причине. Ниже к полноценному пакету
    # добавляется один `<c>`, и отвергнуть его может только правило про теги.
    local v bad
    v=$(gen "$RU")
    for bad in "$v<c>" "<c>$v" "${v/<rc /<c><rc }"; do
        [ "$(shaped "$bad")" = "no" ] || { echo "accepted: $bad"; false; }
    done
    # Контроль: без `<c>` тот же пакет принимается, иначе тест выше проходил бы
    # на чём угодно.
    [ "$(shaped "$v")" = "yes" ] || { echo "the control packet itself was rejected: $v"; false; }
}

@test "cps i1 shaped: truncation and garbage are rejected" {
    local bad
    for bad in '<r 2><b 0x858>' '<b 0xf1>' '<r 128>' 'junk<b 0x0463646e730669636c6f756403636f6d>tail' ''; do
        [ "$(shaped "$bad")" = "no" ] || { echo "accepted: ${bad:-(empty)}"; false; }
    done
}

@test "cps i1: answer addresses are not pinned to a constant" {
    # 🔴 A mutation that pinned the middle octets to zero survived the first
    # version of this file: every server in the fleet would have answered
    # x.0.0.y, which is precisely the marker the shaped packet exists to avoid.
    # One sample cannot show variation, so this walks a run of them.
    local line body off rec seen=0 mid=''
    while read -r line; do
        [ -n "$line" ] || continue
        seen=$(( seen + 1 ))
        [[ "$line" =~ $I1_RE ]]
        body="${BASH_REMATCH[3]}"
        for (( off = ${#QTAIL}; off < ${#body}; off += RR )); do
            rec="${body:off:RR}"
            mid="$mid ${rec:26:4}"
        done
    done <<< "$(gen "$RU" 12)"
    [ "$seen" -eq 12 ] || { echo "generator produced $seen lines out of 12"; false; }
    [ "$(printf "%s" "$mid" | tr " " "\n" | sort -u | grep -c .)" -ge 4 ] \
        || { echo "middle octets barely vary:$mid"; false; }
}

@test "cps i1: the generator refuses to emit a half-built packet" {
    # 🔴 Before the self-check the function had no failure signal at all: its
    # exit status was that of the final printf, which succeeds whatever it
    # printed. With rand_range degraded to an empty string it produced `<rc >`
    # with an empty count and ANCOUNT=0000 at status 0, and that value would
    # have reached the settings file, the server config and every client profile,
    # failing only at step 7 when the interface comes up.
    local out rc
    out=$(gen_stub "$RU" 'rand_range() { echo; }' 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || { echo "empty rand_range produced [$out] at status 0"; false; }
    [ -z "$out" ] || { echo "a rejected packet was printed anyway: $out"; false; }

    # %02x is a minimum width, not a truncation: a value above 255 yields an odd
    # number of hex characters, which both implementations reject.
    out=$(gen_stub "$RU" 'rand_range() { echo 300; }' 2>/dev/null) && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || { echo "out-of-range rand_range produced [$out] at status 0"; false; }
    [ -z "$out" ] || { echo "a rejected packet was printed anyway: $out"; false; }
}

# --------------------------------------------- the notice on an old install

# 🔴 The generator fix reaches NEW installations only: a reinstall over a live
# server deliberately keeps the stored parameters, because regenerating them
# would change a working installation without asking and would invalidate every
# client config already handed out. The decision (owner, 11 sep 2026) is to say
# it out loud rather than migrate, and to say it only to those it concerns.

legacy_notice() {  # legacy_notice <installer> <i1 value> -> number of warnings
    bash -c '
        block=$(sed -n "/^        # Установки, сделанные до сентября 2026/,/^        fi$/p;/^        # Installations made before September 2026/,/^        fi$/p" "$1")
        [ -n "$block" ] || { echo "notice block not found in $1"; exit 1; }
        AWG_I1="$2"
        log_warn() { echo "WARN"; }
        eval "$block"
    ' _ "$1" "$2" | grep -c WARN || true
    # `grep -c` returns 1 when the count is zero, and under the errexit
    # bats runs tests with that aborts the caller before it can compare
    # against the zero we are actually asserting.
}

@test "cps i1 notice: an install still carrying a random I1 is told about it" {
    local out
    out=$(legacy_notice "$RU" '<r 128>')
    [ "$out" -eq 2 ] || { echo "expected 2 warnings, got $out"; false; }
    out=$(legacy_notice "$EN" '<r 128>')
    [ "$out" -eq 2 ] || { echo "EN: expected 2 warnings, got $out"; false; }
}

@test "cps i1 notice: an install with the new packet is left alone" {
    # A notice that fires on a correct installation is noise, and noise is how a
    # real warning stops being read.
    local v out
    v=$(gen "$RU")
    out=$(legacy_notice "$RU" "$v")
    [ "$out" -eq 0 ] || { echo "expected silence, got $out warnings for $v"; false; }
    out=$(legacy_notice "$EN" "$v")
    [ "$out" -eq 0 ] || { echo "EN: expected silence, got $out warnings"; false; }
}

@test "cps i1 notice: an install without I1 at all is left alone" {
    # `--no-cps` is a supported choice, not a defect to warn about.
    local out
    out=$(legacy_notice "$RU" '')
    [ "$out" -eq 0 ] || { echo "expected silence for an empty I1, got $out"; false; }
}
