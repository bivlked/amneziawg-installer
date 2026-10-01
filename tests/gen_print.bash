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
# required fields: a check that compares two sides passes when a field is gone
# from both, so presence is checked on its own
OBF = ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4")
def require(body, keys, label):
    for k in keys:
        if not body.get(k):
            fail(f"{label}: no {k}")
require(iface, ("PrivateKey", "Address", "ListenPort") + OBF, "srv")
for name in sorted(peers):
    require(peers[name], ("PublicKey", "AllowedIPs"), f"srv|peer:{name}")
if HPK in iface:
    hpk_values.append(("awg0.conf", iface[HPK]))
    if gen == "2.0":
        fail("2.0 server config carries HeaderProtectionKey")
elif gen == "3.1":
    fail("3.1 server config without HeaderProtectionKey")

# --- keys
keys = {}
kdir = os.path.join(awg_dir, "keys")
for f in sorted(os.listdir(kdir)) if os.path.isdir(kdir) else []:
    keys[f] = read(os.path.join(kdir, f)).strip()
    out.append(f"keys|{f}|{keys[f]}")
for f in ("server_private.key", "server_public.key"):
    p = os.path.join(awg_dir, f)
    if not os.path.exists(p):
        fail(f"no {f} next to a server config")
        continue
    keys[f] = read(p).strip()
    out.append(f"keys|{f}|{keys[f]}")
if "server_private.key" in keys and keys["server_private.key"] != iface.get("PrivateKey"):
    fail("server_private.key differs from PrivateKey in the server config")

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
# a link, a QR or an expiry mark without its .conf is a leftover
for f in sorted(os.listdir(awg_dir)):
    for suf in (".vpnuri.png", ".vpnuri", ".png"):
        if f.endswith(suf):
            if f[:-len(suf)] not in clients:
                fail(f"{f} without {f[:-len(suf)]}.conf")
            break
edir = os.path.join(awg_dir, "expiry")
for f in sorted(os.listdir(edir)) if os.path.isdir(edir) else []:
    out.append(f"expiry|{f}|{read(os.path.join(edir, f)).strip()}")
    if f not in clients:
        fail(f"expiry/{f} without {f}.conf")

shapes = {}
CPA = "ContentPaddingAddition"
for name in clients:
    label = f"client:{name}"
    csec = parse_conf(read(os.path.join(awg_dir, name + ".conf")), label)
    for sec, body in csec:
        for k in body:
            out.append(f"{label}|{sec}|{k}|{body[k]}")
    ci, cp = one(csec, "Interface", label), one(csec, "Peer", label)
    require(ci, ("PrivateKey", "Address", "DNS", "MTU") + OBF, label)
    require(cp, ("PublicKey", "Endpoint", "AllowedIPs"), label)
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
    # the fields of last_config the client reads on their own must agree with
    # the config text: a client that trusts them would get another key or peer
    def lv(k):
        v = last_obj.get(k)
        return "" if v is None else str(v)
    def addr(v):
        return (v or "").split(",")[0].strip().split("/")[0]
    pairs = [("client_priv_key", ci.get("PrivateKey", "")),
             ("server_pub_key", cp.get("PublicKey", "")),
             ("psk_key", cp.get("PresharedKey", "")),
             ("mtu", ci.get("MTU", "")),
             ("persistent_keep_alive", cp.get("PersistentKeepalive", ""))]
    for k, want in pairs:
        if lv(k) != want:
            fail(f"urilast:{name}: {k} {lv(k)!r} vs the config {want!r}")
    if addr(lv("client_ip")) != addr(ci.get("Address")):
        fail(f"urilast:{name}: client_ip {lv('client_ip')!r} vs Address {ci.get('Address')!r}")
    ep = cp.get("Endpoint", "")
    host, _, port = ep.rpartition(":")
    host = host.strip("[]")
    if lv("hostName") != host or lv("port") != port:
        fail(f"urilast:{name}: hostName/port {lv('hostName')!r}:{lv('port')!r} vs Endpoint {ep!r}")
    try:
        o_host = str(outer.get("hostName", ""))
        o_port = str(outer["containers"][0]["awg"].get("port", ""))
    except (KeyError, IndexError, TypeError):
        o_host, o_port = "", ""
    if o_host != host or o_port != port:
        fail(f"urimeta:{name}: hostName/port {o_host!r}:{o_port!r} vs Endpoint {ep!r}")
    def toks(v):
        # the link keeps a JSON list, the config a comma-separated line
        items = v if isinstance(v, list) else (v or "").split(",")
        return sorted(str(t).strip() for t in items if str(t).strip())
    if toks(last_obj.get("allowed_ips")) != toks(cp.get("AllowedIPs")):
        fail(f"urilast:{name}: allowed_ips {lv('allowed_ips')!r} vs AllowedIPs {cp.get('AllowedIPs')!r}")
    for k in ("Jc", "Jmin", "Jmax", "S1", "S2", "S3", "S4", "H1", "H2", "H3", "H4",
              "I1", "I2", "I3", "I4", "I5", "ContentPaddingAddition"):
        if lv(k) != ci.get(k, ""):
            fail(f"urilast:{name}: {k} {lv(k)!r} vs the config {ci.get(k, '')!r}")
    dns = [d.strip() for d in ci.get("DNS", "").split(",") if d.strip()]
    for i, key in enumerate(("dns1", "dns2")):
        want = dns[i] if i < len(dns) else ""
        # with one DNS the link repeats it as dns2 (awg_common.sh, generate_vpn_uri)
        if i == 1 and len(dns) == 1:
            want = dns[0]
        if str(outer.get(key, "")) != want:
            fail(f"urimeta:{name}: {key} {outer.get(key)!r} vs DNS {ci.get('DNS')!r}")
    # every client and every link has the same set of fields as the others
    shape = (tuple(sorted((s, k) for s, b in csec for k in b)),
             tuple(sorted(k for k in last_obj if k != "config")))
    shapes.setdefault(shape, []).append(name)
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

# ContentPaddingAddition: everywhere on 3.1, nowhere (non-empty) on 2.0
cpa_places = [("srv", iface.get(CPA, ""))]
for line in out:
    m = re.match(r"(client|uri):([^|]+)\|Interface\|ContentPaddingAddition\|(.*)$", line)
    if m:
        cpa_places.append((f"{m.group(1)}:{m.group(2)}", m.group(3)))
if gen == "3.1":
    have = {p for p, v in cpa_places if v}
    for name in clients:
        for p in (f"client:{name}", f"uri:{name}"):
            if p not in have:
                fail(f"{p}: 3.1 without ContentPaddingAddition")
    if "srv" not in have:
        fail("srv: 3.1 without ContentPaddingAddition")
elif gen == "2.0":
    for p, v in cpa_places:
        if v:
            fail(f"{p}: 2.0 carries ContentPaddingAddition")
if len(shapes) > 1:
    fail("clients differ in their set of fields: " + "; ".join(",".join(v) for v in shapes.values()))

# file modes: secrets must stay 600
def mode_of(path):
    return oct(os.stat(path).st_mode & 0o777)[2:]
for root, dirs, files in os.walk(awg_dir):
    dirs[:] = sorted(d for d in dirs if d not in ("backups", "archive"))
    for f in sorted(files):
        # logs, locks, the scripts, the state file and the dot files (temp registries,
        # cached device parameters) are runtime state, not the installation
        if f.endswith((".log", ".lock")) or f.startswith(".") or f in ("awg_common.sh", "manage_amneziawg.sh", "setup_state"):
            continue
        p = os.path.join(root, f)
        rel = os.path.relpath(p, awg_dir)
        out.append(f"mode|{rel}|{mode_of(p)}")
        # everything that carries a private key: the key files, the client configs,
        # their links and both QR codes
        secret = (f in ("server_hpk.key", "server_private.key") or f.endswith((".private", ".conf", ".vpnuri", ".png")))
        if secret and f != "awgsetup_cfg.init" and mode_of(p) != "600":
            fail(f"{rel} has mode {mode_of(p)}, a secret must be 600")
out.append(f"mode|<server conf>|{mode_of(srv_conf)}")
if mode_of(srv_conf) != "600":
    fail(f"the server config has mode {mode_of(srv_conf)}, a secret must be 600")

# the init agrees with the server about the padding and the CPS packet
if "AWG_CPA" in init and init["AWG_CPA"] != iface.get(CPA, ""):
    fail(f"init AWG_CPA {init['AWG_CPA']!r} vs server {iface.get(CPA, '')!r}")
if init.get("NO_CPS") == "1" and iface.get("I1"):
    fail("init NO_CPS=1 but the server carries I1")

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
