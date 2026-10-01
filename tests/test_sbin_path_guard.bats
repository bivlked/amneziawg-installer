#!/usr/bin/env bats
# PATH without the sbin directories.
#
# On Debian "su" without "-" keeps the caller's PATH (for example
# /usr/local/bin:/usr/bin:/bin:/usr/local/games:/usr/games), and cron runs jobs
# with /usr/bin:/bin. There dpkg refuses to install packages (no ldconfig or
# start-stop-daemon in PATH) and reboot, dkms, sysctl, ufw and modprobe are not
# found by name, so the install stalled in step 1; manage check reported IP
# forwarding off and UFW missing. Each entry point now
# appends the missing sbin directories to PATH before it does anything else.
#
# The scripts are not sourceable as a whole, so the cases below run the real
# head of each script, from line 1 to the guard call, in a clean environment.
# The head is taken only through _head_of, which refuses when the call line is
# missing: otherwise sed would print the whole file and the case would run the
# full installer (as root on a stand).

load test_helper

SCRIPTS=(install_amneziawg.sh install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh)

# Prints script $1 from line 1 to the guard call, or fails if there is no call.
_head_of() {
    local head
    head=$(sed -n '1,/^_awg_ensure_sbin_path$/p' "$BATS_TEST_DIRNAME/../$1")
    [[ "$head" == *$'\n_awg_ensure_sbin_path' ]] || { echo "no guard call in $1"; return 1; }
    printf '%s\n' "$head"
}

# Runs the head of script $1 with PATH=$2 and prints the resulting PATH.
_head_path() {
    local head
    head=$(_head_of "$1") || { echo "$head"; return 1; }
    env -i PATH="$2" /bin/bash -c "$head"$'\nprintf "%s" "$PATH"'
}

@test "sbin guard: each entry point appends the sbin directories to a cron PATH" {
    local s out
    for s in "${SCRIPTS[@]}"; do
        out=$(_head_path "$s" "/usr/bin:/bin") || { echo "$out"; return 1; }
        [[ "$out" == "/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin" ]] || { echo "$s: $out"; return 1; }
    done
}

@test "sbin guard: the PATH of su without a dash gets sbin, user order kept" {
    local s out
    for s in "${SCRIPTS[@]}"; do
        out=$(_head_path "$s" "/usr/local/bin:/usr/bin:/bin:/usr/games") || { echo "$out"; return 1; }
        [[ "$out" == "/usr/local/bin:/usr/bin:/bin:/usr/games:/usr/local/sbin:/usr/sbin:/sbin" ]] || { echo "$s: $out"; return 1; }
    done
}

@test "sbin guard: a full root PATH is left exactly as it was" {
    local s out full="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    for s in "${SCRIPTS[@]}"; do
        out=$(_head_path "$s" "$full") || { echo "$out"; return 1; }
        [[ "$out" == "$full" ]] || { echo "$s: $out"; return 1; }
    done
}

@test "sbin guard: only the missing directories are added, never twice" {
    local s out
    for s in "${SCRIPTS[@]}"; do
        out=$(_head_path "$s" "/usr/sbin:/usr/bin:/bin") || { echo "$out"; return 1; }
        [[ "$out" == "/usr/sbin:/usr/bin:/bin:/usr/local/sbin:/sbin" ]] || { echo "$s: $out"; return 1; }
    done
}

@test "sbin guard: an empty PATH gets no leading colon" {
    local s out
    for s in "${SCRIPTS[@]}"; do
        out=$(_head_path "$s" "") || { echo "$out"; return 1; }
        [[ "$out" == "/usr/local/sbin:/usr/sbin:/sbin" ]] || { echo "$s: $out"; return 1; }
    done
}

@test "sbin guard: the new PATH is exported to child processes" {
    local s out head
    for s in "${SCRIPTS[@]}"; do
        head=$(_head_of "$s") || { echo "$head"; return 1; }
        out=$(env -i PATH="/usr/bin:/bin" /bin/bash -c "$head"$'\n/usr/bin/env')
        [[ "$out" == *$'PATH=/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin'* ]] || { echo "$s: $out"; return 1; }
    done
}

@test "sbin guard: with no PATH in the environment children still get one" {
    # bash sets a default PATH but does not export it, so without the export a
    # child process would start with no PATH at all.
    local s out head
    for s in "${SCRIPTS[@]}"; do
        head=$(_head_of "$s") || { echo "$head"; return 1; }
        out=$(env -i /bin/bash -c "$head"$'\n/usr/bin/env')
        [[ "$out" == *$'PATH='*'/usr/sbin'* ]] || { echo "$s: no PATH exported"; return 1; }
    done
}

# The ensure-module helper the installer writes to /usr/local/sbin runs later on
# its own (apt hook, systemd), so the installer's PATH does not reach it. An apt
# started from su without "-" hands the hook a PATH without sbin, and the
# helper's "command -v dkms" would report dkms missing and exit 0.
_helper_head() {
    local body
    body=$(awk "/AWG_ENSURE_HELPER_EOF'/,/^AWG_ENSURE_HELPER_EOF\$/" "$BATS_TEST_DIRNAME/../$1" | sed '1d;$d')
    [[ -n "$body" ]] || { echo "no helper in $1"; return 1; }
    body=$(sed -n '1,/^export PATH$/p' <<<"$body")
    [[ "$body" == *$'\nexport PATH' ]] || { echo "no PATH guard in the helper of $1"; return 1; }
    printf '%s\n' "$body"
}

@test "sbin guard: the ensure-module helper appends sbin before it looks for dkms" {
    local s head out
    for s in install_amneziawg.sh install_amneziawg_en.sh; do
        head=$(_helper_head "$s") || { echo "$head"; return 1; }
        ! grep -v '^[[:space:]]*#' <<<"$head" | grep -q 'command -v' \
            || { echo "$s: command -v runs before the PATH guard"; return 1; }
        out=$(env -i PATH="/usr/local/bin:/usr/bin:/bin:/usr/games" /bin/bash -c "$head"$'\n/usr/bin/env')
        [[ "$out" == *$'PATH=/usr/local/bin:/usr/bin:/bin:/usr/games:/usr/local/sbin:/usr/sbin:/sbin'* ]] || { echo "$s: $out"; return 1; }
        out=$(env -i PATH="/usr/sbin:/usr/bin:/sbin:/bin" /bin/bash -c "$head"$'\nprintf "%s" "$PATH"')
        [[ "$out" == "/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin" ]] || { echo "$s: $out"; return 1; }
    done
}

@test "sbin guard: the call comes before the first command that could need sbin" {
    # Everything above the call must be comments, the two known set/export
    # lines, the builtin-only Bash version check, plain assignments with a
    # literal value, or the guard function itself; anything else could run with
    # the short PATH.
    local s line head assign='^[A-Z_][A-Z0-9_]*=("[^"`$]*"|[^[:space:]"`$;|&<>()]*)$'
    for s in "${SCRIPTS[@]}"; do
        head=$(_head_of "$s") || { echo "$head"; return 1; }
        while IFS= read -r line; do
            case "$line" in
                ''|'#'*|'set -o pipefail'|'export WG_COLOR_MODE=never') continue ;;
                'if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then'|'fi') continue ;;
                '    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1') continue ;;
                '    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1') continue ;;
                '_awg_ensure_sbin_path() {') continue ;;
            esac
            [[ "$line" =~ $assign ]] && continue
            echo "$s: unexpected top-level line before the guard: $line"
            return 1
        done < <(printf '%s\n' "$head" \
                 | sed '/^_awg_ensure_sbin_path() {$/,/^}$/{/^_awg_ensure_sbin_path() {$/!d}' \
                 | sed '$d')
    done
}
