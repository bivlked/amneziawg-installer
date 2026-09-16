#!/usr/bin/env bats
# A 3.1 client set made by the real library passes the real set check.
#
# Step 6 of a 3.1 install renders the server config, creates the default clients
# and then checks every set; a refused set undoes the install. The pieces are
# tested one by one elsewhere, and the set check there runs against a set built
# by hand with the parameters loaded beforehand. This file runs the chain as the
# installer does, in one shell and without loading anything first: if the
# renderers ever wrote the profile in a form the check does not accept, every
# first 3.1 install would undo itself, and only a server would show it.
#
# Two limits worth knowing. generate_client reloads the parameters from the
# server config it has just rendered, so the padding the check compares against
# is the rendered one; the check's own normalization is covered by
# test_awg31_artifacts.bats. And the set check only looks at the start of the
# link, so this file decodes the link itself to see the profile went into it.
#
# External tools are stubbed: awg (keys), qrencode (the QR file). perl is real,
# because it builds the link, and python3 decodes the link for the check.

KEY_OK="QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQA="

require_perl_zlib() { perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null || skip "perl Compress::Zlib/MIME::Base64 not available"; }

# e2e_run <lib> <padding> <snippet>
e2e_run() {
    local lib="$1" cpa="$2" snippet="$3" d
    d="$BATS_TEST_TMPDIR/e-$(basename "$lib" .sh)"
    rm -rf "$d"; mkdir -p "$d/keys" "$d/bin"
    {
        printf "export AWG_PORT=39743\nexport AWG_TUNNEL_SUBNET='10.9.9.1/24'\nexport DISABLE_IPV6=1\n"
        printf "export ALLOWED_IPS_MODE=1\nexport AWG_PROTOCOL='3.1'\nexport AWG_CPA='%s'\n" "$cpa"
        printf "export AWG_Jc=6\nexport AWG_Jmin=55\nexport AWG_Jmax=380\n"
        printf "export AWG_S1=72\nexport AWG_S2=56\nexport AWG_S3=32\nexport AWG_S4=16\n"
        printf "export AWG_H1='1'\nexport AWG_H2='2'\nexport AWG_H3='3'\nexport AWG_H4='4'\n"
        printf "export AWG_I1='<r 128>'\nexport AWG_APPLY_MODE='syncconf'\nexport AWG_ENDPOINT='203.0.113.10'\n"
    } > "$d/awgsetup_cfg.init"
    printf 'SRVPRIVAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' > "$d/server_private.key"
    printf 'SRVPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' > "$d/server_public.key"
    printf '%s\n' "$KEY_OK" > "$d/server_hpk.key"
    cat > "$d/bin/awg" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    genkey) echo "CLIPRIVAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    pubkey) cat >/dev/null; echo "CLIPUBAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    genpsk) echo "PSKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ;;
    *) exit 0 ;;
esac
EOF
    cat > "$d/bin/qrencode" <<'EOF'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
    if [ "$1" = "-o" ]; then out="$2"; shift; fi
    shift
done
cat >/dev/null
[ -n "$out" ] && printf 'PNG' > "$out"
exit 0
EOF
    chmod +x "$d/bin/awg" "$d/bin/qrencode"
    AWG_DIR="$d" timeout 120 bash -c '
        export PATH="$AWG_DIR/bin:$PATH"
        export CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init" SERVER_CONF_FILE="$AWG_DIR/awg0.conf"
        export KEYS_DIR="$AWG_DIR/keys" EXPIRY_DIR="$AWG_DIR/expiry"
        log() { :; }; log_warn() { echo "WARN: $*"; }; log_error() { echo "ERR: $*"; }; log_debug() { :; }
        source "$1" >/dev/null 2>&1 || true
        get_main_nic() { echo eth0; }
        eval "$2"
    ' _ "$BATS_TEST_DIRNAME/../$lib" "$snippet"
}

both() {
    local seen=0 lib
    for lib in awg_common.sh awg_common_en.sh; do
        "$1" "$lib" || return 1
        seen=$((seen + 1))
    done
    [ "$seen" -eq 2 ]
}

e_chain() {
    local lib="$1" cpa out fields
    # The second padding carries a comment and spaces, the way a hand-edited init
    # may: the renderers write the checked form, and the check has to agree.
    for cpa in "32-128" "32 - 128 # set by hand"; do
        out=$(e2e_run "$lib" "$cpa" '
            render_server_config || { echo "RENDER_FAILED"; exit 0; }
            generate_client c1 || { echo "CLIENT_FAILED"; exit 0; }
            awg_client_artifacts_check c1; echo "RC=$?"')
        [[ "$out" != *RENDER_FAILED* && "$out" != *CLIENT_FAILED* ]] || { echo "the chain broke before the check ($lib, '$cpa'): $out"; return 1; }
        [[ "$out" == *"RC=0"* ]] || { echo "a set made by the library was refused by its own check ($lib, '$cpa'): $out"; return 1; }
        fields=$(link_fields "$BATS_TEST_TMPDIR/e-$(basename "$lib" .sh)/c1.vpnuri") || { echo "the link does not decode ($lib, '$cpa')"; return 1; }
        grep -qxF "HeaderProtectionKey=$KEY_OK" <<< "$fields" || { echo "the link lost the key ($lib, '$cpa'): $fields"; return 1; }
        grep -qxF "ContentPaddingAddition=32-128" <<< "$fields" || { echo "the link lost the padding ($lib, '$cpa'): $fields"; return 1; }
    done
}

# link_fields <uri file> : top-level keys of the inner config JSON, parsed.
link_fields() {
    python3 - "$1" <<'PY'
import base64, json, sys, zlib
uri = open(sys.argv[1], encoding="utf-8").read().strip().replace("vpn://", "")
raw = base64.urlsafe_b64decode(uri + "=" * (-len(uri) % 4))
outer = json.loads(zlib.decompress(raw[4:]))
inner = json.loads(outer["containers"][0]["awg"]["last_config"])
for k in sorted(inner):
    v = inner[k]
    print("%s=%s" % (k, v if isinstance(v, str) else json.dumps(v)))
PY
}
@test "set 3.1: a client made by the real library passes the real set check, both twins" {
    require_perl_zlib
    command -v python3 &>/dev/null || skip "python3 not available"
    both e_chain
}
