#!/usr/bin/env bats
# awg31_environment_blocker: the environment gate for the AmneziaWG 3.1 profile.
#
# The gate answers with a REASON CODE rather than a boolean, because a single
# "3.1 is unavailable" would send the owner of a Debian 12 box and the owner of
# an ARM box into the same dead end while their ways out differ.
#
# EMPTY OUTPUT IS THE DANGEROUS VALUE: it is the one that means "install 3.1".
# Every property below exists to make sure it can only be produced deliberately,
# and each was checked to go red when its guard is removed. The mutation runs
# are listed in the pull request that introduced this file.
#
#   1. Both stages are self-contained verdicts. post CONTAINS pre, so a caller
#      that reaches step 3 without carrying the step 0 answer across the two
#      reboots still cannot be told "go ahead" on a platform pre refused.
#   2. Architecture and kernel are decided BEFORE the tools are probed. An ARM
#      box with old tools must hear "arm", the permanent reason, not "tools_old",
#      which would send the operator to upgrade tools that cannot help - and
#      would run an external binary on a platform we refuse to ship on.
#   3. Not knowing is not permission: an undetectable architecture blocks, and
#      an architecture we never measured blocks too. The allow list is the point;
#      "not ARM" is not the same as "amd64".
#   4. TOOLS SUPPORT IS PROBED BY CAPABILITY, NEVER BY VERSION - neither as a
#      replacement nor as a fallback. This is the regression guard for the
#      7 sep 2026 measurement: the PPA builds amneziawg-tools from tag
#      v3.1.20260812 while the package version stays 1.0.20210914
#      (wireguard-tools heritage). Every stub below reports an ancient version
#      except one, which claims 3.1 and must still be refused.
#   5. Only a consistent answer counts: the real probe prints the usage in its
#      FAILURE branch and exits 1, so neither a zero exit nor a timeout kill
#      (124) may be read as an answer.
#   6. A caller bug cannot produce the dangerous value. The stage has no default
#      precisely because an unset variable would otherwise degrade silently to
#      the weakest stage, and the refusal is carried by the printed code rather
#      than by die(), which would only kill a subshell.
#      NOTE: this file covers the gate as a FUNCTION. Its call sites - step 0
#      through _awg31_resolve_protocol, step 3 through step3_check_module - and
#      the refusal texts live in test_awg31_protocol_flag.bats. The callers
#      simulated below are deliberate: a failure here must mean "wrong verdict",
#      never "wrong call site".
#   7. The gate must work with nothing but the installer. awg_common.sh is
#      downloaded at step 5, while the gate answers at steps 0 and 3.
#
# Two details that look incidental and are not: the unknown-stage message goes
# to stderr (moving it to stdout turns the internal_error test red), and the
# probe records its argv so that an edit which starts naming an interface is
# caught.
#
# shellcheck disable=SC2154

load test_helper

INSTALL_RU="$BATS_TEST_DIRNAME/../install_amneziawg.sh"
INSTALL_EN="$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"

# Function body of $2 from script $1, without running the script.
func_from() { sed -n "/^$2()/,/^}/p" "$1"; }

# Load the gate and everything it calls, from the real installer.
load_gate() {
    local script="${1:-$INSTALL_RU}"
    eval "$(func_from "$script" _kernel_supports_awg3)"
    eval "$(func_from "$script" _awg31_host_arch)"
    eval "$(func_from "$script" awg31_tools_support)"
    eval "$(func_from "$script" awg31_environment_blocker)"
}

# A fake awg on PATH. The production code has no injection seam on purpose: a
# root installer must not pick the binary it probes out of an inherited
# variable, so the tests substitute the command the ordinary way.
#
# Variants:
#   31       usage with the key on stderr, exit 1        -> supported
#   20       usage without the key                       -> not supported
#   stdout   key, but printed on stdout                  -> supported
#   zero     key, but exit 0                             -> refused
#   t124     key, but exit 124 (what timeout returns)    -> refused
#   verclaim no key in usage, but --version claims 3.1   -> refused
# Every invocation appends its full argv to $TEST_DIR/awg.argv.
make_awg_stub() {
    local variant="$1" path="$TEST_DIR/bin/awg" usage stream="2" code="1"
    local version="awg-tools v1.0.20210914"
    mkdir -p "$TEST_DIR/bin"
    usage="Usage: awg set <interface> [listen-port <port>] [jc <n>] [s1 <n>]"
    case "$variant" in
        20)       : ;;
        verclaim) version="awg-tools v3.1.20260812" ;;
        stdout)   usage="$usage [header-protection-key <key>]"; stream="1" ;;
        zero)     usage="$usage [header-protection-key <key>]"; code="0" ;;
        t124)     usage="$usage [header-protection-key <key>]"; code="124" ;;
        *)        usage="$usage [header-protection-key <key>]" ;;
    esac
    {
        echo "#!/usr/bin/env bash"
        echo "echo \"\$*\" >> \"$TEST_DIR/awg.argv\""
        echo "if [ \"\$1\" = \"--version\" ]; then echo \"$version\"; exit 0; fi"
        echo "if [ \"\$1\" = \"set\" ]; then"
        echo "  echo \"$usage\" >&$stream"
        echo "  exit $code"
        echo "fi"
        echo "exit 0"
    } > "$path"
    chmod +x "$path"
    PATH="$TEST_DIR/bin:$PATH"
    export PATH
}

# Make architecture detection answer with a fixed value, exercising the path
# production actually uses (no architecture argument).
fake_arch_detection() {
    local value="$1"
    mkdir -p "$TEST_DIR/bin"
    printf '#!/usr/bin/env bash\nprintf %%s "%s"\n' "$value" > "$TEST_DIR/bin/dpkg"
    chmod +x "$TEST_DIR/bin/dpkg"
    PATH="$TEST_DIR/bin:$PATH"
    export PATH
}

# Make architecture undetectable: both probes fail.
break_arch_detection() {
    mkdir -p "$TEST_DIR/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_DIR/bin/dpkg"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_DIR/bin/uname"
    chmod +x "$TEST_DIR/bin/dpkg" "$TEST_DIR/bin/uname"
    PATH="$TEST_DIR/bin:$PATH"
    export PATH
}

# ---------------------------------------------------- architecture and kernel

@test "ARM is blocked whatever the architecture is called" {
    load_gate
    for arch in arm64 armhf armel aarch64 armv7l aarch64_be; do
        run awg31_environment_blocker pre "$arch" "6.14.0-generic"
        [ "$status" -eq 0 ]
        [ "$output" = "arm" ]
    done
}

@test "ARM wins over an old kernel - the reason given is the permanent one" {
    # A modern kernel on ARM passes the kernel check, so without the arm branch
    # the answer would be not_implemented_yet today and empty after phase 3 -
    # that is, it would ship on ARM. And on an old kernel the arm code must still
    # win, because upgrading the kernel would not make ARM shippable.
    load_gate
    run awg31_environment_blocker pre "arm64" "6.1.0-18-arm64"
    [ "$output" = "arm" ]
}

@test "the kernel decides on amd64: 6.6 blocks, 6.7 passes, garbage blocks" {
    load_gate
    run awg31_environment_blocker pre "amd64" "6.6.99-generic"
    [ "$output" = "kernel" ]
    run awg31_environment_blocker pre "amd64" "6.7.0-generic"
    [ "$output" = "not_implemented_yet" ]
    run awg31_environment_blocker pre "amd64" "not-a-version"
    [ "$output" = "kernel" ]
}

@test "an architecture we never measured blocks, rather than falling through" {
    # The allow list is the point. The PPA builds the dkms package for these
    # too, so a deny list would hand them a 3.1 profile after phase 3.
    load_gate
    for arch in riscv64 ppc64el s390x i386 loong64; do
        run awg31_environment_blocker pre "$arch" "6.14.0-generic"
        [ "$status" -eq 0 ]
        [ "$output" = "arch_unsupported" ]
    done
}

@test "an undetectable architecture blocks instead of passing" {
    # Not knowing is not permission. Both detection paths are broken here, which
    # is the only way to reach this branch: an empty argument means "detect it".
    load_gate
    break_arch_detection
    run awg31_environment_blocker pre "" "6.14.0-generic"
    [ "$status" -eq 0 ]
    [ "$output" = "arch_unknown" ]
}

@test "the detection path production uses is wired up" {
    # Every real call passes no architecture at all, so without this the whole
    # detection branch is untested and only its failure mode is pinned.
    load_gate
    fake_arch_detection "arm64"
    run awg31_environment_blocker pre "" "6.14.0-generic"
    [ "$output" = "arm" ]
}

@test "surrounding whitespace does not smuggle an ARM box through" {
    # Without the strip, " arm64 " misses the arm pattern, misses the allow list
    # and lands on arch_unsupported - safe today, but the strip is what makes the
    # answer correct rather than accidentally safe.
    load_gate
    run awg31_environment_blocker pre " arm64 " "6.14.0-generic"
    [ "$output" = "arm" ]
    run awg31_environment_blocker pre "   " "6.14.0-generic"
    [ "$output" = "arch_unknown" ]
}

@test "a suitable environment reports not_implemented_yet until phase 3" {
    # The tripwire for the phase 3 change. When the 3.1 generator lands, this
    # assertion MUST be rewritten to expect an empty string; if it is not, the
    # suite goes red and nobody ships a half-wired default.
    load_gate
    run awg31_environment_blocker pre "amd64" "6.14.0-generic"
    [ "$status" -eq 0 ]
    [ "$output" = "not_implemented_yet" ]
}

# --------------------------------------------------- stage ordering and scope

@test "post contains pre: ARM stays blocked, and hears arm rather than tools_old" {
    # Both halves matter. The old tools make the tools probe fail, so a gate that
    # probed first would answer tools_old and send the operator after an upgrade
    # that cannot help.
    load_gate
    make_awg_stub 20
    run awg31_environment_blocker post "arm64" "6.14.0-generic"
    [ "$output" = "arm" ]
}

@test "post contains pre: an old kernel stays blocked, and hears kernel" {
    load_gate
    make_awg_stub 20
    run awg31_environment_blocker post "amd64" "6.1.0-18-amd64"
    [ "$output" = "kernel" ]
}

@test "pre never runs the probe, even with capable tools on PATH" {
    # The invariant that justifies the two-stage split: step 0 runs before any
    # package is installed. Asserted by absence of the argv log, so it does not
    # depend on whether the test machine happens to have awg installed.
    load_gate
    make_awg_stub 31
    run awg31_environment_blocker pre "amd64" "6.14.0-generic"
    [ "$output" = "not_implemented_yet" ]
    [ ! -e "$TEST_DIR/awg.argv" ]
}

@test "post: a fully suitable environment still reports not_implemented_yet" {
    # The second half of the tripwire. If post ever answers empty before the
    # generator exists, the installer would be told to write a 3.1 profile it
    # cannot produce.
    load_gate
    make_awg_stub 31
    run awg31_environment_blocker post "amd64" "6.14.0-generic"
    [ "$status" -eq 0 ]
    [ "$output" = "not_implemented_yet" ]
}

@test "post: tools without the 3.1 usage are refused with tools_old" {
    load_gate
    make_awg_stub 20
    run awg31_environment_blocker post "amd64" "6.14.0-generic"
    [ "$status" -eq 0 ]
    [ "$output" = "tools_old" ]
}

@test "post: a missing awg binary yields tools_old" {
    # This pins the VERDICT for a missing binary, which is worth having. It does
    # not pin the `command -v awg` line: without it the probe still fails, just
    # more slowly, so both paths reach the same correct answer.
    load_gate
    local saved="$PATH"
    mkdir -p "$TEST_DIR/empty-bin"
    # An empty search path is enough for the gate itself: the architecture is
    # passed in, the kernel check is pure bash, and the probe stops at
    # `command -v awg`. It is put back before the assertion so that teardown
    # still has its tools.
    # shellcheck disable=SC2123  # replacing the search path wholesale is the
    # point: that is how a missing binary is simulated without deleting one.
    PATH="$TEST_DIR/empty-bin"; export PATH
    run awg31_environment_blocker post "amd64" "6.14.0-generic"
    PATH="$saved"; export PATH
    [ "$output" = "tools_old" ]
}

# ------------------------------------------------------ the capability probe

@test "a version that claims 3.1 does not substitute for the usage" {
    # Kills the plausible future edit "accept it also when --version advertises
    # 3.1". A version claim is not confirmed by anything, and accepting it fails
    # in the dangerous direction. The replacement case is covered too: every
    # other stub reports the ancient version, so a version-only implementation
    # could not tell them apart.
    load_gate
    make_awg_stub verclaim
    run awg --version
    [[ "$output" == *"3.1"* ]]
    run awg31_tools_support
    [ "$status" -ne 0 ]
    run awg31_environment_blocker post "amd64" "6.14.0-generic"
    [ "$output" = "tools_old" ]
}

@test "the probe accepts usage printed on stdout as well as on stderr" {
    # Which stream the usage goes to is not part of any contract we control, so
    # the probe merges them. This pins that down.
    load_gate
    make_awg_stub stdout
    run awg31_tools_support
    [ "$status" -eq 0 ]
}

@test "the probe rejects a zero exit even when the key is printed" {
    # The real usage is printed in the failure branch. A command that prints the
    # key and succeeds is not awg answering - it is a wrapper with its own help,
    # or a stub.
    load_gate
    make_awg_stub zero
    run awg31_tools_support
    [ "$status" -ne 0 ]
}

@test "the probe rejects a timeout kill even when the key is printed" {
    # 124 is what timeout returns when it fires. Accepting any non-zero status
    # would count a wrapper that printed a plausible usage and then hung - which
    # is the exact case the timeout exists to defend against.
    load_gate
    make_awg_stub t124
    run awg31_tools_support
    [ "$status" -ne 0 ]
    run awg31_environment_blocker post "amd64" "6.14.0-generic"
    [ "$output" = "tools_old" ]
}

@test "the probe passes exactly one argument and never names an interface" {
    # Guards the claim that the probe touches nothing: the argc < 3 branch is
    # only reached while no device is opened. A future edit that starts passing
    # an interface name would turn this red.
    load_gate
    make_awg_stub 31
    run awg31_tools_support
    [ "$status" -eq 0 ]
    run cat "$TEST_DIR/awg.argv"
    [ "$output" = "set" ]
}

@test "the probe bounds the awg call itself in time, in both languages" {
    # A broken binary or a wrapper that never execs would otherwise stall an
    # installer step for good. Structural, because exercising it would mean
    # spending the timeout inside the suite; the pattern pins the timeout to the
    # awg call so that a stray timeout elsewhere in the function does not pass.
    local body
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        body=$(func_from "$f" awg31_tools_support)
        [[ "$body" == *"timeout "*"awg set"* ]]
    done
}

# ------------------------------------------------------------- loud failures

@test "an unknown stage cannot produce the dangerous empty value" {
    # The installer will call this through a command substitution, so die() would
    # only kill the subshell and leave the caller with an empty string, which is
    # exactly the value that means "3.1 is available". The code itself has to
    # carry the refusal. Sending the message to stdout instead of stderr also
    # turns this red, which is deliberate.
    load_gate
    local blocker status_seen=0
    blocker=$(awg31_environment_blocker sideways "amd64" "6.14.0-generic" 2>/dev/null) || status_seen=$?
    [ "$blocker" = "internal_error" ]
    [ "$status_seen" -ne 0 ]
}

@test "an omitted stage is refused, not silently downgraded to pre" {
    # The stage has no default on purpose: an unset variable would otherwise
    # become pre, and the tools probe would be skipped without a word. With 2.0
    # tools present, a silent downgrade to pre would answer not_implemented_yet
    # while post answers tools_old, so this distinguishes the two.
    load_gate
    make_awg_stub 20
    local blocker status_seen=0
    blocker=$(awg31_environment_blocker "" "amd64" "6.14.0-generic" 2>/dev/null) || status_seen=$?
    [ "$blocker" = "internal_error" ]
    [ "$status_seen" -ne 0 ]
}

@test "an unknown stage says why on stderr" {
    load_gate
    run awg31_environment_blocker sideways "amd64" "6.14.0-generic"
    [ "$status" -ne 0 ]
    [[ "$output" == *"sideways"* ]]
}

# ------------------------------------------------------------ both languages

@test "the gate answers without awg_common.sh, in both languages" {
    # A stated design invariant with no other coverage: the library is downloaded
    # at step 5, while the gate answers at steps 0 and 3. The bats helper sources
    # awg_common.sh, so a new dependency on it would stay invisible here and kill
    # the installer on a real server.
    #
    # Both branches are exercised in isolation, not just the early return: with
    # explicit arguments the detection and probe paths are never reached, so a
    # dependency added there would slip through a one-call version of this test.
    # `run` merges stderr, so a "command not found" also turns this red.
    make_awg_stub 20
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        run bash --noprofile --norc -c '
            f=$1; fn(){ sed -n "/^$1()/,/^}/p" "$f"; }
            for n in _kernel_supports_awg3 _awg31_host_arch awg31_tools_support awg31_environment_blocker; do
                eval "$(fn $n)"
            done
            awg31_environment_blocker pre arm64 6.14.0-generic
            printf "|"
            awg31_environment_blocker post "" 6.14.0-generic' _ "$f"
        # arm from the explicit call; then the detection path resolves the real
        # architecture and the probe runs against the 2.0 stub on PATH.
        [ "$status" -eq 0 ]
        [[ "$output" == "arm|"* ]]
        [[ "$output" != *"not found"* ]]
        [[ "$output" == *"tools_old" || "$output" == *"arm" || "$output" == *"arch_unsupported" || "$output" == *"arch_unknown" ]]
    done
}

@test "both language versions answer identically on every branch" {
    for script in "$INSTALL_RU" "$INSTALL_EN"; do
        load_gate "$script"
        run awg31_environment_blocker pre "arm64" "6.14.0-generic"
        [ "$output" = "arm" ]
        run awg31_environment_blocker pre "amd64" "6.1.0-18-amd64"
        [ "$output" = "kernel" ]
        run awg31_environment_blocker pre "riscv64" "6.14.0-generic"
        [ "$output" = "arch_unsupported" ]
        run awg31_environment_blocker pre "amd64" "6.14.0-generic"
        [ "$output" = "not_implemented_yet" ]
        run awg31_environment_blocker sideways "amd64" "6.14.0-generic"
        [ "$status" -ne 0 ]
    done
}

@test "both language versions agree on the tools verdict and on arch_unknown" {
    for script in "$INSTALL_RU" "$INSTALL_EN"; do
        load_gate "$script"
        make_awg_stub 20
        run awg31_environment_blocker post "amd64" "6.14.0-generic"
        [ "$output" = "tools_old" ]
    done
    for script in "$INSTALL_RU" "$INSTALL_EN"; do
        load_gate "$script"
        break_arch_detection
        run awg31_environment_blocker pre "" "6.14.0-generic"
        [ "$output" = "arch_unknown" ]
    done
}

@test "the reason codes are spelled identically in both languages" {
    # A cheap structural backstop: codes are a contract with the caller and with
    # the documentation, and a translated code would be a silent break. It does
    # not replace the behavioural checks above - it cannot tell reachable code
    # from unreachable.
    local body
    for f in "$INSTALL_RU" "$INSTALL_EN"; do
        body=$(func_from "$f" awg31_environment_blocker)
        for code in arch_unknown arch_unsupported arm kernel tools_old not_implemented_yet internal_error; do
            [[ "$body" == *"printf '$code'"* ]]
        done
    done
}
