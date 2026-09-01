#!/usr/bin/env bats
# awg_cps_decoded_size and the diagnose-time warning built on it.
#
# The defect being guarded against is upstream
# amneziawg-linux-kernel-module#228: once the I1-I5 attributes fill most of the
# netlink dump buffer, the first peer no longer fits, `wg_get_device_dump`
# neither advances nor fails, and the same message repeats forever. The reader
# spins; on a router that is enough to take the box down.
#
# 🔴 Two properties matter and are tested separately, because passing one while
# failing the other still leaves the user with a hung command:
#   1. the size is DECODED, not the length of the string - `<r 1000>` is nine
#      characters and a thousand bytes;
#   2. the warning is computed from the FILE and printed BEFORE any `awg show`,
#      since that call is the one that hangs.

setup() {
    COMMON="${BATS_TEST_DIRNAME}/../awg_common.sh"
    COMMON_EN="${BATS_TEST_DIRNAME}/../awg_common_en.sh"
    MANAGE="${BATS_TEST_DIRNAME}/../manage_amneziawg.sh"
    MANAGE_EN="${BATS_TEST_DIRNAME}/../manage_amneziawg_en.sh"
}

size() {  # size <lib> <args...>
    local lib="$1"; shift
    bash -c 'source "$1" >/dev/null 2>&1 || true; shift; awg_cps_decoded_size "$@"' \
        _ "$lib" "$@"
}

# ---------------------------------------------------------------- decoded size

@test "cps size: a random tag counts its byte count, not its text length" {
    run size "$COMMON" '<r 1000>'
    [ "$status" -eq 0 ]
    [ "$output" = "1000" ]
}

@test "cps size: a literal tag counts two hex characters per byte" {
    run size "$COMMON" '<b 0xdeadbeef>'
    [ "$output" = "4" ]
}

@test "cps size: letters and digits count like random bytes" {
    run size "$COMMON" '<rc 10><rd 5>'
    [ "$output" = "15" ]
}

@test "cps size: timestamp and counter tags are four bytes each" {
    run size "$COMMON" '<t><c>'
    [ "$output" = "8" ]
}

@test "cps size: a tag without a space is accepted too" {
    run size "$COMMON" '<r64>'
    [ "$output" = "64" ]
}

@test "cps size: the documented DNS-shaped recipe stays small" {
    # The recipe published in ADVANCED. If a future edit inflates it, this
    # reddens rather than the users' routers.
    run size "$COMMON" '<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>'
    [ "$status" -eq 0 ]
    [ "$output" -lt 128 ]
}

@test "cps size: I1 through I5 add up" {
    run size "$COMMON" '<r 100>' '<r 200>' '' '<b 0xaabb>' '<t>'
    [ "$output" = "306" ]
}

@test "cps size: empty input is zero, not an error" {
    run size "$COMMON" ''
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
}

@test "cps size: the generator's own upper bound stays far below the threshold" {
    # generate_cps_i1 emits <r 32..256>. The guard warns above 1024.
    run size "$COMMON" '<r 256>'
    [ "$status" -eq 0 ]
    [ "$output" -lt 1024 ]
}

@test "cps size: a leading-zero count is decimal, not octal" {
    # 🔴 `<r 08>` is octal to bash. Before `10#` was added the arithmetic failed
    # outright, the function returned an EMPTY string, and every threshold
    # comparison built on it silently stopped firing - the guard was off and
    # said nothing. Tested ALONE on purpose: paired with a large tag the sum
    # survives on the neighbour's value and the test passes while broken, which
    # is exactly what an earlier version of this file did.
    run size "$COMMON" '<r 08>'
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
}

@test "cps size: a leading-zero count in the EN library too" {
    run size "$COMMON_EN" '<r 09>'
    [ "$status" -eq 0 ]
    [ "$output" = "9" ]
}

@test "cps size: the EN library computes the same number" {
    run size "$COMMON_EN" '<r 100>' '<b 0xaabb>'
    [ "$output" = "102" ]
}

# ------------------------------------------------------- ordering in diagnose

@test "cps guard: the check reads the config file, not awg show" {
    # If it ever reads the size out of `awg show`, it inherits the hang it is
    # meant to warn about.
    run grep -n 'awg_cps_decoded_size' "$MANAGE"
    [ "$status" -eq 0 ]
    grep -A2 '_cps_vals+=' "$MANAGE" | grep -q 'SERVER_CONF_FILE'
}

@test "cps guard: the guard runs before the first awg show in diagnose" {
    # The whole point of the ordering, measured by line numbers inside
    # diagnose_server: the guard must come first, or it never prints for the
    # user who needs it.
    #
    # Two kinds of line are skipped, and both were learned the hard way here:
    # comments, because the guard's own comment explains that it precedes
    # `awg show` and matching that sentence made the check fail on its own
    # documentation; and _diag_line calls, because the failure messages quote
    # the command name too. A guard that trips over its own explanation is a
    # pattern this repository has now paid for twice.
    for f in "$MANAGE" "$MANAGE_EN"; do
        start=$(grep -n '^diagnose_server() {' "$f" | cut -d: -f1)
        guard=$(awk -v s="$start" 'NR>s && /_diag_cps_guard/ && !/^[[:space:]]*#/ {print NR; exit}' "$f")
        show=$(awk -v s="$start" 'NR>s && /awg show/ && !/^[[:space:]]*#/ && !/_diag_line/ {print NR; exit}' "$f")
        [ -n "$guard" ]
        [ -n "$show" ]
        [ "$guard" -lt "$show" ]
    done
}

@test "cps guard: awg show inside diagnose is bounded by a timeout" {
    # A bounded call fails loudly; an unbounded one hangs silently, and a hung
    # diagnostic is the worst outcome here - the user cannot even report it.
    for f in "$MANAGE" "$MANAGE_EN"; do
        start=$(grep -n '^diagnose_server() {' "$f" | cut -d: -f1)
        end=$(awk -v s="$start" 'NR>s && /^}/ {print NR; exit}' "$f")
        bare=$(awk -v s="$start" -v e="$end" \
            'NR>s && NR<e && /awg show/ && !/timeout [0-9]+ awg show/ && !/^[[:space:]]*#/ && !/_diag_line/' "$f" | wc -l)
        [ "$bare" -eq 0 ]
    done
}

@test "cps guard: the threshold is stated once per language and matches" {
    ru=$(grep -c '_cps_total" -gt 1024' "$MANAGE")
    en=$(grep -c '_cps_total" -gt 1024' "$MANAGE_EN")
    [ "$ru" -eq 1 ]
    [ "$en" -eq 1 ]
}

# ------------------------------------------------------ behaviour, not grep
#
# The checks above read the source. These run it. The difference matters: a
# call that stays in place while its result stops mattering, a threshold line
# turned into dead code, or a `timeout` present in the text while its exit code
# is discarded - all of that passes a source scan and fails a user.
#
# The guard is extracted by awk range and eval'd, the way this suite already
# handles diagnose helpers. Sourcing the whole script is not an option: it runs
# main and prints the usage text.

# guard_out <manage script> <lib> <I1 value>
# Prints the guard's output, then a final line "unsafe=N" carrying the flag it
# sets in its caller.
guard_out() {
    local script="$1" lib="$2" i1="$3"
    local dir="$BATS_TEST_TMPDIR/g"
    rm -rf "$dir"; mkdir -p "$dir"
    printf '[Interface]\nPrivateKey = x\nI1 = %s\n' "$i1" > "$dir/awg0.conf"

    bash -c '
        SERVER_CONF_FILE="$1/awg0.conf"
        warn=0
        _cps_unsafe=0
        # Minimal stand-ins: the guard only needs a way to print a line.
        _diag_line() { echo "[$1] ${*:2}"; }
        eval "$(awk "/^awg_cps_decoded_size\\(\\) \\{/,/^}\$/" "$3")"
        eval "$(awk "/^_diag_cps_guard\\(\\) \\{/,/^}\$/" "$2")"
        _diag_cps_guard
        echo "unsafe=$_cps_unsafe"
    ' _ "$dir" "$script" "$lib"
}

@test "cps behaviour: an oversized I1 warns and names the size" {
    run guard_out "$MANAGE" "$COMMON" '<r 4096>'
    [ "$status" -eq 0 ]
    [[ "$output" == *"4096"* ]]
    [[ "$output" == *"unsafe=1"* ]]
}

# 🔴 The property the whole change exists for. Warning and then walking into
# the very call that loops would protect nobody: a timeout bounds time, not the
# memory a spinning reader consumes.
@test "cps behaviour: an oversized I1 marks the interface read unsafe" {
    run guard_out "$MANAGE" "$COMMON" '<r 4096>'
    [[ "$output" == *"unsafe=1"* ]]
}

@test "cps behaviour: a normal I1 leaves the interface read enabled" {
    # The mirror. Without it a guard that always skips would look perfect while
    # breaking diagnostics for everyone.
    run guard_out "$MANAGE" "$COMMON" '<r 64>'
    [[ "$output" == *"unsafe=0"* ]]
}

@test "cps behaviour: an unparsable tag is reported, not counted as small" {
    run guard_out "$MANAGE" "$COMMON" '<nosuchtag 9>'
    [[ "$output" == *"unsafe=1"* ]]
    [[ "$output" == *"WARN"* ]]
}

@test "cps behaviour: a leading-zero count does not silently disable the guard" {
    # `<r 08>` is octal to bash. Before the fix the arithmetic failed, the
    # function returned an empty string, and the threshold comparison never
    # fired - the guard was off and said nothing.
    #
    # 🔴 The assertion is the SUM, not `unsafe=1`. Measured on a mutant with
    # `10#` removed: it also prints `unsafe=1`, by the "could not parse"
    # branch, so an assertion on the flag alone stays green on the defect it
    # names. 4104 = 8 + 4096, and only the fixed code can produce it.
    run guard_out "$MANAGE" "$COMMON" '<r 08><r 4096>'
    [[ "$output" == *"unsafe=1"* ]]
    [[ "$output" == *"4104"* ]]
}

@test "cps behaviour: an unreadable config is reported rather than passed over" {
    run bash -c '
        SERVER_CONF_FILE="/nonexistent/awg0.conf"
        warn=0
        _cps_unsafe=0
        _diag_line() { echo "[$1] ${*:2}"; }
        eval "$(awk "/^awg_cps_decoded_size\(\) \{/,/^}$/" "'"$COMMON"'")"
        eval "$(awk "/^_diag_cps_guard\(\) \{/,/^}$/" "'"$MANAGE"'")"
        _diag_cps_guard
        echo "unsafe=$_cps_unsafe"
    '
    [[ "$output" == *"unsafe=1"* ]]
    [[ "$output" == *"WARN"* ]]
}

@test "cps behaviour: the EN guard behaves the same" {
    run guard_out "$MANAGE_EN" "$COMMON_EN" '<r 4096>'
    [[ "$output" == *"4096"* ]]
    [[ "$output" == *"unsafe=1"* ]]
}

# ------------------------------------------- контракт «занижение не молчит»
#
# 🔴 Эти тесты проверяют КОД ВОЗВРАТА, а не только напечатанное число, и в этом
# всё дело. Прежний тест на неизвестный тег утверждал только `output = 0`:
# удали из библиотеки `return 2` - и он остался бы зелёным, хотя вызывающий
# перестал бы отличать «разобрал, размера нет» от «разобрать не смог». Ноль,
# полученный от неразобранной строки, ведёт диагностику прямиком в тот вызов,
# который зависает.

@test "cps size: an unknown tag is flagged, not merely under-counted" {
    run size "$COMMON" '<nosuchtag 99>'
    [ "$output" = "0" ]
    [ "$status" -eq 2 ]
}

@test "cps size: input with no tags at all is flagged rather than called empty" {
    # Measured before the fix: 0 with status 0, indistinguishable from an
    # absent I1 - and an absent I1 is exactly what makes the guard stand aside.
    run size "$COMMON" 'garbagewithnotags'
    [ "$status" -eq 2 ]
}

@test "cps size: an unterminated tag is flagged" {
    run size "$COMMON" '<r 5'
    [ "$status" -eq 2 ]
}

@test "cps size: junk after a valid tag is flagged" {
    run size "$COMMON" '<b 0xaa> tail'
    [ "$status" -eq 2 ]
}

@test "cps size: a stray bracket does not make a tag count twice" {
    # `${s#*>}` used to cut to the first `>` in the whole string, which could
    # sit before the match, so the same tag was consumed twice. Measured: 128
    # for a single `<r 64>`.
    run size "$COMMON" 'a>b<r 64>'
    [ "$output" = "64" ]
    [ "$status" -eq 2 ]
}

@test "cps size: a count too large for bash arithmetic does not wrap into safety" {
    # Measured before the fix: `<r 18446744073709551617>` overflowed to 1 with
    # status 0, so a plainly dangerous value passed under the threshold.
    run size "$COMMON" '<r 18446744073709551617>'
    [ "$status" -eq 2 ]
    [ "$output" -lt 1024 ]
}

@test "cps size: surrounding whitespace is not mistaken for junk" {
    # The mirror of the four tests above. Without it a parser that flagged
    # everything would pass them all and warn on every healthy config.
    run size "$COMMON" '  <r 64>  '
    [ "$output" = "64" ]
    [ "$status" -eq 0 ]
}

@test "cps size: the EN library enforces the same contract" {
    run size "$COMMON_EN" 'garbagewithnotags'
    [ "$status" -eq 2 ]
    run size "$COMMON_EN" 'a>b<r 64>'
    [ "$output" = "64" ]
    run size "$COMMON_EN" '  <r 64>  '
    [ "$status" -eq 0 ]
}

@test "cps behaviour: an I1 with no recognisable tag marks the read unsafe" {
    run guard_out "$MANAGE" "$COMMON" 'notatagatall'
    [[ "$output" == *"unsafe=1"* ]]
    [[ "$output" == *"WARN"* ]]
}

# ------------------------------------- «не прочитал» против «параметра нет»
#
# Шаг 8 diagnose печатал `I1=${i1:-absent}`. Пустая строка означает и «в
# конфиге параметра нет», и «до интерфейса мы не дошли», а это противоположные
# утверждения: сторож срабатывает ровно тогда, когда I1 огромен, и в этот
# момент прежний код печатал «I1 absent». Блок вырезается по комментариям-
# границам и исполняется с заглушками - так же, как guard_out выше.

step8() {  # step8 <manage> <cps_unsafe>
    bash -c '
        MANAGE="$1"; _cps_unsafe="$2"
        warn=0; fail=0
        _diag_line() { echo "[$1] ${*:2}"; }
        awg() { echo "  jc: 4"; echo "  i1: <r 171>"; }
        # `timeout` - внешний бинарь, и функцию-заглушку awg он не увидит.
        # Без этой строки зеркальный тест падал бы на харнессе, а читался
        # как провал кода.
        timeout() { shift; "$@"; }
        eval "$(awk "/# 8\. AWG params snapshot/,/# 9\. Carrier comparison/" "$MANAGE" | sed "\$d")"
        echo "warn=$warn fail=$fail"
    ' _ "$1" "$2"
}

@test "diagnose: a skipped interface read is not reported as an absent I1" {
    run step8 "$MANAGE" 1
    [[ "$output" == *"не прочитан"* ]]
    run bash -c 'echo "$1"' _ "$output"
    [[ "$output" != *"I1=absent"* ]]
}

@test "diagnose: a successful read still prints the parameters" {
    # The mirror. A branch that always says "not read" would pass the test
    # above while making diagnose useless on a healthy server.
    run step8 "$MANAGE" 0
    [[ "$output" == *"I1=<r 171>"* ]]
}

@test "diagnose: the EN version reports a skipped read the same way" {
    run step8 "$MANAGE_EN" 1
    [[ "$output" == *"not read"* ]]
}

# ------------------------------------------- структурные проверки-минимумы
#
# ⚠️ Ниже именно СТРУКТУРНЫЕ проверки, и это слабейший вид: они смотрят на
# форму кода, а не на его поведение. Стоят здесь потому, что оба места лежат
# внутри длинных функций, поведенческий вызов которых требует поднятого
# интерфейса. Заменить на поведенческие при первой возможности.

@test "list: the handshake default is unreachable when the dump was not read" {
    # Без этого условия непрочитанный дамп давал «Нет handshake» ВСЕМ
    # клиентам и то же самое в --json: правдоподобная и полностью неверная
    # таблица вместо заметного зависания.
    for f in "$MANAGE" "$MANAGE_EN"; do
        run grep -c '\-n "\$current_pk" && "\$_dump_ok" -ne 1' "$f"
        [ "$output" = "1" ]
        run grep -c '_dump_ok=1' "$f"
        [ "$output" = "1" ]
    done
}

@test "diagnose: the carrier comparison is skipped when nothing was read" {
    # Профиль со значением i1_mode=absent давал зелёный OK «I1 отсутствует»
    # на непрочитанном интерфейсе - галочку об условии, из-за которого мы
    # отказались смотреть.
    for f in "$MANAGE" "$MANAGE_EN"; do
        run grep -c '\-n "\$carrier" && "\$_awg_read" -ne 1' "$f"
        [ "$output" = "1" ]
    done
}

@test "diagnose: a timed-out peer read stops step 8 from trying again" {
    # Зацикливание живёт на интерфейсе, а сторож читает файл; после таймаута
    # повторный заход удваивал экспозицию, ради которой всё написано.
    for f in "$MANAGE" "$MANAGE_EN"; do
        run bash -c 'awk "/_show_rc\" -eq 124/,/^        else$/" "$1" | grep -c "_cps_unsafe=1"' _ "$f"
        [ "$output" = "1" ]
    done
}

@test "every awg show call site is bounded by a timeout" {
    # check, stats, show и --diagnostic оставались без границы вовсе, а
    # --diagnostic это ровно та команда, которую документация просит приложить
    # к обращению: попавший в дефект не собрал бы даже отчёт о нём.
    #
    # Считаем ВЫЗОВЫ, а не вхождения подстроки: строковые литералы вырезаются
    # (в них живут тексты сообщений и справка), комментарии отбрасываются.
    # Первая редакция этого теста считала всё подряд и краснела на уже
    # исправленном коде: проверка, не отличающая вызов от рассказа о нём,
    # бесполезна в обе стороны.
    for f in "$MANAGE" "$MANAGE_EN"              "${BATS_TEST_DIRNAME}/../install_amneziawg.sh"              "${BATS_TEST_DIRNAME}/../install_amneziawg_en.sh"; do
        run bash -c 'strip() { sed "s/\"[^\"]*\"//g" "$1" | grep -vE "^[[:space:]]*#"; }
            calls=$(strip "$1" | grep -cE "(^|[^_[:alnum:]-])awg show") || true
            bounded=$(strip "$1" | grep -E "(^|[^_[:alnum:]-])awg show" | grep -cE "timeout [0-9]+ awg show") || true
            echo "$calls $bounded"' _ "$f"
        # Печатаются оба числа нарочно: равенство при нуле означало бы, что
        # вызовов не нашли вовсе, то есть проверка сломалась, а не прошла.
        set -- $output
        [ "$1" -gt 0 ]
        [ "$1" = "$2" ]
    done
}

@test "cps size: a payload smuggled into a timestamp tag is flagged" {
    # `<t <r 4096>` matches as one `t` tag whose value is `<r 4096`. Before the
    # fix it counted four bytes and returned success: four thousand bytes
    # reported as four, and the caller walked into the dangerous read.
    run size "$COMMON" '<t <r 4096>'
    [ "$status" -eq 2 ]
    run size "$COMMON_EN" '<c junk>'
    [ "$status" -eq 2 ]
    run size "$COMMON" '<t><c>'
    [ "$output" = "8" ]
    [ "$status" -eq 0 ]
}
