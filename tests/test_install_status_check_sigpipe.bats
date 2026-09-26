#!/usr/bin/env bats
# check_service_status (step 7 of both installers) used to read
# `awg show | grep -q "interface: awg0"`, `ss -lunp | grep -q ":PORT "` and
# `awg show awg0 | grep -q "jc:"`.
# awg prints the interface block first and the peers after it, grep -q quits at
# the first match, and with hundreds of peers the next write of awg gets
# SIGPIPE: under pipefail the pipeline fails and the check reports a working
# interface as missing. On a --force reinstall of a server with many clients
# the step then dies with "awg show cannot see interface".
# These tests run the function lifted from each installer under pipefail with
# SIGPIPE at its default (a parent that ignores it would hide the failure) and a
# stub awg that writes the interface block, then many peers, one write per line.

INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

setup() {
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    # awg show [awg0]: interface block first, then PEERS peer lines.
    cat > "$BIN/awg" <<'EOF'
#!/usr/bin/env bash
[ "$1" = show ] || exit 0
printf 'interface: awg0\n'
printf '  listening port: 39743\n'
printf '  jc: 4\n'
i=0
while [ "$i" -lt "${PEERS:-0}" ]; do
    printf 'peer: %043d=\n  allowed ips: 10.9.9.2/32\n' "$i"
    i=$((i + 1))
done
exit 0
EOF
    # ss -lunp: our port first, then LISTENERS more sockets, one write per line.
    cat > "$BIN/ss" <<'EOF'
#!/usr/bin/env bash
printf 'UNCONN 0 0 0.0.0.0:39743 0.0.0.0:*\n'
i=0
while [ "$i" -lt "${LISTENERS:-0}" ]; do
    printf 'UNCONN 0 0 10.0.%d.%d:%d 0.0.0.0:*\n' $((i / 250)) $((i % 250)) $((20000 + i))
    i=$((i + 1))
done
exit 0
EOF
    # systemctl is-failed: not failed; ip addr show awg0: present.
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/systemctl"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/ip"
    chmod +x "$BIN/awg" "$BIN/systemctl" "$BIN/ip" "$BIN/ss"
}

# status <installer> <peers> [listeners] : check_service_status from the
# installer under pipefail with the stubs first on PATH; prints the log lines
# and the code.
status() {
    local src="$BATS_TEST_DIRNAME/../$1" body
    body=$(sed -n '/^check_service_status() {$/,/^}$/p' "$src")
    [[ -n "$body" ]] || { echo "NO_FUNCTION in $1"; return 3; }
    PEERS="$2" LISTENERS="${3:-0}" PATH="$BIN:$PATH" AWG_PORT=39743 \
    env --default-signal=PIPE timeout 60 bash -c '
        set -o pipefail
        log()       { echo "INFO: $*"; }
        log_warn()  { echo "WARN: $*"; }
        log_error() { echo "ERR: $*"; }
        log_debug() { :; }
        eval "$1"
        check_service_status
        echo "rc=$?"
    ' _ "$body"
}

@test "status check: a working interface with many peers passes, both twins" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run status "$f" 5000
        [[ "$output" != *NO_FUNCTION* ]] || { echo "$output"; return 1; }
        if [[ "$output" != *"rc=0"* ]]; then
            echo "$f: check refused a working interface with 5000 peers: $output"
            return 1
        fi
        if [[ "$output" == *"WARN:"* ]]; then
            echo "$f: AWG 2.0 parameters reported missing with 5000 peers: $output"
            return 1
        fi
    done
}

@test "status check: a listening port among many UDP sockets passes, both twins" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run status "$f" 0 5000
        [[ "$output" != *NO_FUNCTION* ]] || { echo "$output"; return 1; }
        if [[ "$output" != *"rc=0"* ]]; then
            echo "$f: check refused a listening port among 5000 UDP sockets: $output"
            return 1
        fi
    done
}

@test "status check: a working interface with no peers passes, both twins" {
    local f
    for f in "${INSTALLERS[@]}"; do
        run status "$f" 0
        if [[ "$output" != *"rc=0"* ]]; then
            echo "$f: $output"
            return 1
        fi
    done
}

@test "status check: awg show without the interface still refuses, both twins" {
    local f
    printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/awg"
    for f in "${INSTALLERS[@]}"; do
        run status "$f" 0
        if [[ "$output" != *"rc=1"* ]]; then
            echo "$f: a failing awg show was not a refusal: $output"
            return 1
        fi
    done
}
