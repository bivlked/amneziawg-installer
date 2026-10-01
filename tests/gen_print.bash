# shellcheck shell=bash
# _gen_print <awg dir> <server conf> : the generation fingerprint of an
# installation, for lifecycle tests (slice E of phase F4).
#
# Prints one line per fact, in a fixed order, so a test can compare the
# fingerprint before and after an operation:
#   init|<KEY>|<value>                 every export in awgsetup_cfg.init
#   hpkfile|<value>                    server_hpk.key, when present
#   srv|Interface|<key>|<value>        server [Interface]
#   srv|peer:<name>|<key>|<value>      server [Peer] named by #_Name
#   keys|<file>|<value>                every file in keys/ and the server keys
#   client:<name>|<section>|<key>|<value>
#   uri:<name>|<section>|<key>|<value> the config inside the vpn:// link
#   urimeta:<name>|<path>|<value>      the other scalars of the link JSON
#
# Every fact is checked, not just collected. The helper fails (rc 3, reason on
# stderr) on a duplicate key in a section, a value line outside a section, a
# link that does not decode, a missing marker, a client without its link, keys
# or server peer, a client that disagrees with the server (keys, PSK, address,
# S1-S4, H1-H4), a link that disagrees with its .conf, and on the header
# protection key: on 3.1 it must be present and equal in server_hpk.key, the
# server config, every client and every link; on 2.0 it must be absent from the
# configs and the links (a leftover server_hpk.key is allowed there, the library
# only warns about it).

_gen_print() {
    python3 - "$1" "$2" <<'PY'
import base64, json, os, re, struct, sys, zlib

awg_dir, srv_conf = sys.argv[1], sys.argv[2]
out = []
errors = []

def fail(msg):
    errors.append(msg)

def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()

def parse_conf(text, label):
    """[(section, ordinal, {key: value})]; duplicate keys and stray lines fail."""
    sections, cur = [], None
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        m = re.fullmatch(r"\[(\w+)\]", line)
        if m:
            cur = (m.group(1), {})
            sections.append(cur)
            continue
        if line.startswith("#") and not line.startswith("#_Name"):
            continue
        if line.startswith("#_Name"):
            k, _, v = line.partition("=")
            k, v = "#_Name", v.strip()
        else:
            k, sep, v = line.partition("=")
            if not sep:
                fail(f"{label}: not a key = value line: {line!r}")
                continue
            k, v = k.strip(), v.strip()
        if cur is None:
            fail(f"{label}: {k} outside any section")
            continue
        if k in cur[1]:
            fail(f"{label}: duplicate {k} in [{cur[0]}]")
            continue
        if v == "":
            fail(f"{label}: empty {k} in [{cur[0]}]")
        cur[1][k] = v
    return sections

def one(sections, name, label):
    found = [s for s in sections if s[0] == name]
    if len(found) != 1:
        fail(f"{label}: expected one [{name}], found {len(found)}")
        return {}
    return found[0][1]

HPK = "HeaderProtectionKey"

# --- init and marker
init_path = os.path.join(awg_dir, "awgsetup_cfg.init")
init = {}
for raw in read(init_path).splitlines():
    m = re.fullmatch(r"export ([A-Za-z_][A-Za-z0-9_]*)=(.*)", raw.strip())
    if not m:
        continue
    k, v = m.group(1), m.group(2).strip("'\"")
    if k in init:
        fail(f"init: duplicate {k}")
    init[k] = v
for k in sorted(init):
    out.append(f"init|{k}|{init[k]}")
gen = init.get("AWG_PROTOCOL")
if gen not in ("2.0", "3.1"):
    fail(f"init: marker AWG_PROTOCOL is {gen!r}")

# --- server
hpk_values = []
hpk_file = os.path.join(awg_dir, "server_hpk.key")
if os.path.lexists(hpk_file):
    v = read(hpk_file).strip()
    out.append(f"hpkfile|{v}")
    if gen == "3.1":
        hpk_values.append(("server_hpk.key", v))
elif gen == "3.1":
    fail("3.1 without server_hpk.key")

srv = parse_conf(read(srv_conf), "srv")
iface = one(srv, "Interface", "srv")
for k in iface:
    out.append(f"srv|Interface|{k}|{iface[k]}")
peers = {}
for sec, body in srv:
    if sec != "Peer":
        continue
    name = body.get("#_Name")
    if not name:
        fail("srv: [Peer] without #_Name")
        continue
    if name in peers:
        fail(f"srv: two peers named {name}")
    peers[name] = body
for name in sorted(peers):
    for k in peers[name]:
        if k != "#_Name":
            out.append(f"srv|peer:{name}|{k}|{peers[name][k]}")
if HPK in iface:
    hpk_values.append(("awg0.conf", iface[HPK]))
    if gen == "2.0":
        fail("2.0 server config carries HeaderProtectionKey")

# --- keys
keys = {}
kdir = os.path.join(awg_dir, "keys")
for f in sorted(os.listdir(kdir)) if os.path.isdir(kdir) else []:
    keys[f] = read(os.path.join(kdir, f)).strip()
    out.append(f"keys|{f}|{keys[f]}")
for f in ("server_private.key", "server_public.key"):
    p = os.path.join(awg_dir, f)
    if os.path.exists(p):
        keys[f] = read(p).strip()
        out.append(f"keys|{f}|{keys[f]}")

# --- clients and links
def decode_uri(path, label):
    try:
        s = read(path).strip().replace("vpn://", "")
        raw = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
        struct.unpack(">I", raw[:4])
        return json.loads(zlib.decompress(raw[4:]))
    except Exception as e:  # any decoding problem is a finding
        fail(f"{label}: link does not decode: {e}")
        return None

def flatten(prefix, node, acc):
    if isinstance(node, dict):
        for k in sorted(node):
            if k == "last_config":
                continue
            flatten(f"{prefix}.{k}", node[k], acc)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            flatten(f"{prefix}[{i}]", v, acc)
    else:
        acc.append((prefix, node))

srv_conf_real = os.path.realpath(srv_conf)
clients = sorted(
    f[:-5] for f in os.listdir(awg_dir)
    if f.endswith(".conf") and os.path.realpath(os.path.join(awg_dir, f)) != srv_conf_real
)
for name in clients:
    label = f"client:{name}"
    csec = parse_conf(read(os.path.join(awg_dir, name + ".conf")), label)
    for sec, body in csec:
        for k in body:
            out.append(f"{label}|{sec}|{k}|{body[k]}")
    ci, cp = one(csec, "Interface", label), one(csec, "Peer", label)
    if HPK in ci:
        hpk_values.append((label, ci[HPK]))
        if gen == "2.0":
            fail(f"{label}: 2.0 client carries HeaderProtectionKey")
    elif gen == "3.1":
        fail(f"{label}: 3.1 client without HeaderProtectionKey")
    # agreement with the server
    peer = peers.get(name)
    if peer is None:
        fail(f"{label}: no server peer")
    else:
        if keys.get(f"{name}.public") != peer.get("PublicKey"):
            fail(f"{label}: keys/{name}.public differs from the server peer")
        if peer.get("PresharedKey") != cp.get("PresharedKey"):
            fail(f"{label}: PresharedKey differs from the server peer")
        caddr = ci.get("Address", "").split(",")[0].strip()
        paddr = peer.get("AllowedIPs", "").split(",")[0].strip()
        if not caddr or caddr != paddr:
            fail(f"{label}: Address {caddr!r} vs server AllowedIPs {paddr!r}")
    if keys.get(f"{name}.private") != ci.get("PrivateKey"):
        fail(f"{label}: PrivateKey differs from keys/{name}.private")
    if "server_public.key" in keys and keys["server_public.key"] != cp.get("PublicKey"):
        fail(f"{label}: peer PublicKey is not the server key")
    for k in ("S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4"):
        if ci.get(k) != iface.get(k):
            fail(f"{label}: {k} {ci.get(k)!r} vs server {iface.get(k)!r}")
    # the link
    upath = os.path.join(awg_dir, name + ".vpnuri")
    if not os.path.exists(upath):
        fail(f"{label}: no .vpnuri")
        continue
    outer = decode_uri(upath, f"uri:{name}")
    if outer is None:
        continue
    try:
        last = outer["containers"][0]["awg"]["last_config"]
    except (KeyError, IndexError, TypeError):
        fail(f"uri:{name}: no last_config")
        continue
    # last_config is JSON: the config text plus fields the client reads on
    # their own, the header protection key among them
    try:
        last_obj = json.loads(last)
        inner_text = last_obj["config"]
    except Exception as e:
        fail(f"uri:{name}: last_config is not JSON with a config: {e}")
        continue
    for k in sorted(last_obj):
        if k != "config":
            out.append(f"urilast:{name}|{k}|{last_obj[k]}")
    if HPK in last_obj:
        hpk_values.append((f"urilast:{name}", last_obj[HPK]))
        if gen == "2.0":
            fail(f"urilast:{name}: 2.0 link carries HeaderProtectionKey")
    elif gen == "3.1":
        fail(f"urilast:{name}: 3.1 link without HeaderProtectionKey field")
    usec = parse_conf(inner_text, f"uri:{name}")
    for sec, body in usec:
        for k in body:
            out.append(f"uri:{name}|{sec}|{k}|{body[k]}")
    ui = one(usec, "Interface", f"uri:{name}")
    if HPK in ui:
        hpk_values.append((f"uri:{name}", ui[HPK]))
        if gen == "2.0":
            fail(f"uri:{name}: 2.0 link carries HeaderProtectionKey")
    elif gen == "3.1":
        fail(f"uri:{name}: 3.1 link without HeaderProtectionKey")
    if [(s, b) for s, b in usec] != [(s, b) for s, b in csec]:
        fail(f"uri:{name}: the config in the link differs from {name}.conf")
    acc = []
    flatten("", outer, acc)
    for p, v in acc:
        out.append(f"urimeta:{name}|{p}|{v}")

if gen == "3.1":
    vals = {v for _, v in hpk_values}
    if len(vals) != 1 or "" in vals:
        fail("3.1 header protection key differs: " + ", ".join(f"{w}={v}" for w, v in hpk_values))

if errors:
    for e in errors:
        print("gen_print: " + e, file=sys.stderr)
    sys.exit(3)
print("\n".join(out))
PY
}
