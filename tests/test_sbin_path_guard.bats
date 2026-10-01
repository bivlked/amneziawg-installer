#!/usr/bin/env bats
# PATH without the sbin directories.
#
# "su" without "-" on Debian keeps the caller's PATH
# (/usr/local/bin:/usr/bin:/bin:/usr/games), and cron runs with /usr/bin:/bin.
# The installer and manage call dkms, reboot, ufw, sysctl and modprobe by name,
# so from such a shell the install died on "dkms: command not found" and then on
# a failed reboot. Each entry point now appends the missing sbin directories to
# PATH before it does anything else.
#
# The scripts are not sourceable as a whole, so the cases below run the real
# head of each script, from line 1 to the guard call, in a clean environment.

load test_helper

SCRIPTS=(install_amneziawg.sh install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh)

# Runs the head of script $1 with PATH=$2 and prints the resulting PATH.
_head_path() {
    local script="$BATS_TEST_DIRNAME/../$1" head
    head=$(sed -n '1,/^_awg_ensure_sbin_path$/p' "$script")
    [[ "$head" == *$'\n_awg_ensure_sbin_path' ]] || { echo "no guard call in $1"; return 1; }
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
        head=$(sed -n '1,/^_awg_ensure_sbin_path$/p' "$BATS_TEST_DIRNAME/../$s")
        out=$(env -i PATH="/usr/bin:/bin" /bin/bash -c "$head"$'\n/bin/bash -c \'printf "%s" "$PATH"\'')
        [[ "$out" == *":/usr/sbin:/sbin" ]] || { echo "$s: $out"; return 1; }
    done
}

@test "sbin guard: with no PATH in the environment children still get one" {
    # bash sets a default PATH but does not export it, so without the export a
    # child process (awg-quick is a bash script) would start with no PATH at all.
    local s out head
    for s in "${SCRIPTS[@]}"; do
        head=$(sed -n '1,/^_awg_ensure_sbin_path$/p' "$BATS_TEST_DIRNAME/../$s")
        out=$(env -i /bin/bash -c "$head"$'\n/usr/bin/env')
        [[ "$out" == *$'PATH='*'/usr/sbin'* ]] || { echo "$s: no PATH exported"; return 1; }
    done
}

@test "sbin guard: the call comes before the first command that could need sbin" {
    # Everything above the call must be comments, set/export, assignments, the
    # builtin-only Bash version check or the guard function itself; anything
    # else could run with the short PATH.
    local s line
    for s in "${SCRIPTS[@]}"; do
        while IFS= read -r line; do
            case "$line" in
                ''|'#'*|'set -o pipefail'|'export WG_COLOR_MODE=never'|[A-Z_]*=*) ;;
                'if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then'|'    echo "'*'" >&2; exit 1'|'fi') ;;
                '_awg_ensure_sbin_path() {') ;;
                *) echo "$s: unexpected top-level line before the guard: $line"; return 1 ;;
            esac
        done < <(sed -n '1,/^_awg_ensure_sbin_path$/p' "$BATS_TEST_DIRNAME/../$s" \
                 | sed '/^_awg_ensure_sbin_path() {$/,/^}$/{/^_awg_ensure_sbin_path() {$/!d}' \
                 | sed '$d')
    done
}
