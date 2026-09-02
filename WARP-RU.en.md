# Routing the Russian segment through Cloudflare WARP via a BGP feed

[Русская версия](WARP-RU.md) · [Documentation](README.en.md) · [Project site](https://bivlked.github.io/amneziawg-installer/)

This guide adds a second exit to a normal `amneziawg-installer` setup. Client traffic destined for Russian networks leaves through Cloudflare WARP, everything else keeps going out directly from your server as before. The list of Russian networks arrives automatically over BGP from the antifilter.network service, so there is nothing to maintain by hand.

> The scheme was proposed by [@alexfiu4-cyber](https://github.com/alexfiu4-cyber) in [issue #103](https://github.com/bivlked/amneziawg-installer/issues/103). I tested it on a stand, fixed a few things, and wrote it up. Thanks for the breakdown.

> This is an add-on for an existing install. It is not part of the installer itself: a second exit plus a BGP daemon is a different class of task and does not belong inside one script. Hence this separate step-by-step guide.

<a id="toc"></a>
## Contents

- [What it gives you and when you need it](#what)
- [How it works](#how)
- [What you will need](#prereq)
- [Step 1. A WARP profile via wgcf](#step1)
- [Step 2. The warp interface and the routing rule](#step2)
- [Step 3. Subscribing to the BGP feed](#step3)
- [Step 4. Installing and configuring BIRD](#step4)
- [Verification](#verify)
- [What happens when things break](#failopen)
- [Troubleshooting](#trouble)
- [Security](#security)
- [Limitations and caveats](#limits)
- [How to remove it](#uninstall)

<a id="what"></a>
## What it gives you and when you need it

A normal install sends all client traffic into the tunnel, and it reaches the internet from your server's IP. For foreign sites that is fine. Russian sites are trickier: many of them block foreign data-center addresses in whole ranges, so a bank, a government portal or a marketplace may fail to open, throw a captcha, or refuse a transaction.

A related but different problem is when the hoster's autonomous system gets filtered and the tunnel itself breaks on the way to the server. That one is covered separately in [ADVANCED.en.md](ADVANCED.en.md#as-blocking-adv) and is not fixed by this scheme.

The scheme splits traffic by destination address:

- traffic to Russian networks exits through Cloudflare WARP, so Russian sites see a Cloudflare address instead of a data-center one;
- all other traffic goes out directly from your server, exactly as before.

Why not push everything through WARP: WARP addresses are shared by many users, and some foreign services greet them with captchas and geo restrictions. The selective scheme keeps your own clean exit for foreign traffic.

When you do NOT need this:

- if Russian sites already open, there is nothing to fix;
- if you have a second server in Russia, a cascade gives Russian sites a genuine Russian IP rather than a Cloudflare one - see [CASCADE.en.md](CASCADE.en.md);
- if excluding Russian addresses from the tunnel on the client side is enough, an `AllowedIPs` list is simpler ([split-tunnel in ADVANCED.en.md](ADVANCED.en.md#allowedips-adv)). Russian traffic then bypasses the VPN and uses the client's home address.

<a id="how"></a>
## How it works

Four independent pieces:

1. **A second interface, `warp`.** Cloudflare WARP is plain WireGuard. The `wgcf` utility issues a config for it. You do not need a separate `wireguard-tools` package: `amneziawg-tools`, already installed on the server, understands plain WireGuard too, so the interface comes up with the same `awg-quick`.
2. **A separate routing table, 200.** It holds routes to Russian networks, all of them pointing at the `warp` interface.
3. **A policy-routing rule.** `ip rule` makes traffic that arrived on `awg0` (that is, your clients' traffic) consult table 200 first. If the destination is there, the packet leaves through WARP. If it is not, the rule simply does not match and the packet takes the usual path via the `main` table, straight to the internet.
4. **BIRD.** The BGP daemon subscribes to the antifilter.network feed and fills table 200 with Russian networks. At the time of testing that was about 11800 prefixes, and they update themselves.

One consequence of this design matters a lot: table 200 holds no default route. Anything not found there automatically takes the old path. See [What happens when things break](#failopen).

<a id="prereq"></a>
## What you will need

- A working `amneziawg-installer` setup with `awg0` up and clients connecting.
- Root access over SSH.
- Roughly 100 MB of free disk space and a little memory for BIRD; about 11800 routes fit comfortably.
- Willingness to register the server's public IP with the antifilter.network service - without that the BGP session will not come up.
- **A free routing table 200** and **a BIRD not already used for something else**. This guide assumes neither is in use on your server.

Check that before you start; both commands must come back empty:

```bash
ip rule show | grep 200          # there should be no rules pointing at table 200
ip route show table 200          # the table must be empty
```

If table 200 is taken on your machine, pick another free number and substitute it everywhere instead of 200. This matters more than it looks: if the table already holds someone else's default route, the rule from step 2 will immediately send all client traffic there.

If BIRD already runs on this server for another purpose, **do not replace its config wholesale** - in step 4 add the required blocks to the existing configuration and take a backup first. The [How to remove it](#uninstall) section does not apply in that case either: it purges BIRD along with the package.

Tested on Ubuntu 24.04 LTS (kernel 6.8) with `amneziawg-tools v1.0.20260618-2`, `wgcf` 2.2.32 and BIRD 2.14.

<a id="step1"></a>
## Step 1. A WARP profile via wgcf

`wgcf` registers a free WARP account and emits a ready WireGuard config. Grab the binary for your architecture (`amd64` or `arm64`) from the [releases page](https://github.com/ViRb3/wgcf/releases):

```bash
mkdir -p /root/warp && cd /root/warp
ARCH=amd64; [ "$(uname -m)" = "aarch64" ] && ARCH=arm64
curl -fsSL -o wgcf "https://github.com/ViRb3/wgcf/releases/download/v2.2.32/wgcf_2.2.32_linux_${ARCH}"
chmod +x wgcf
./wgcf register --accept-tos
./wgcf generate
```

This produces `wgcf-profile.conf`. You need three values from it: `PrivateKey`, `Address` and `PublicKey`. There is nothing to substitute for `Endpoint` - WARP always uses the same one (`engage.cloudflareclient.com:2408`), and it is already in the template below.

<a id="step2"></a>
## Step 2. The warp interface and the routing rule

Create `/etc/amnezia/amneziawg/warp.conf`, substituting the values from `wgcf-profile.conf`:

```ini
[Interface]
PrivateKey = <PrivateKey from wgcf-profile.conf>
Address = <Address from wgcf-profile.conf, the IPv4 one only>
MTU = 1280
Table = off

PostUp = ip rule add iif awg0 lookup 200
PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE
PostUp = iptables -I FORWARD -i awg0 -o %i -j ACCEPT
PostUp = iptables -I FORWARD -i %i -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

PostDown = ip rule del iif awg0 lookup 200
PostDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -o %i -j ACCEPT
PostDown = iptables -D FORWARD -i %i -o awg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

[Peer]
PublicKey = <PublicKey from wgcf-profile.conf>
AllowedIPs = 0.0.0.0/0
Endpoint = engage.cloudflareclient.com:2408
```

What matters here, and why:

- **`Table = off` is mandatory.** Without it `awg-quick` would make WARP the default route for the whole server, including your SSH session. With it the main routing table is not touched at all.
- **Only the IPv4 address is carried over from the profile.** The `Address` line in `wgcf-profile.conf` also contains an IPv6 address; it is not needed here and only adds leak paths.
- **Do not carry over the `DNS` line from the profile.** It is meant for client-side use of the profile. On a server it would make `awg-quick` call `resolvconf` and attach a resolver to the interface - an extra dependency and an extra moving part, and there is no reason to touch the system resolver for a second exit.
- **The `iif awg0` rule does not depend on the client subnet.** A `from 10.9.9.0/24` variant would need editing whenever the subnet changes; `iif` is tied to the interface and survives that.
- **The `FORWARD` rules are inserted with `-I`, at the top of the chain.** That places them above UFW's own chains, so they do not depend on whatever shows up there later. The chain policy on a UFW server is deny, but a policy applies only after every rule has been evaluated, so the point is not that an appended rule "would not fire" - it is that its fate would depend on other people's rules. The installer inserts its own `awg0` rule with `-I` for the same reason.

Bring the interface up and enable it at boot:

```bash
chmod 600 /etc/amnezia/amneziawg/warp.conf
systemctl enable --now awg-quick@warp
```

Now check that the second exit actually works. Looking at `awg show warp` is not enough on its own: WireGuard only starts a handshake when it has something to send, and there is nothing to send yet because table 200 is still empty. So generate traffic explicitly and look at the result:

```bash
curl --interface warp https://api.ipify.org; echo
awg show warp
```

The first command should return a Cloudflare address, different from your server's. After it, `awg show warp` will show a `latest handshake` and a non-zero `transfer`. If no address came back there is no point going further - fix WARP first, not BGP.

> **About MSS.** The original recipe also carried a `TCPMSS --clamp-mss-to-pmtu` rule for traffic into `warp`. On an install from this repository it changes nothing: since version 5.17.0 the installer already clamps MSS to 1240 in both directions for `awg0`, and with a `warp` MTU of 1280 the IPv4 result is exactly the same 1240. You only need that rule if you lower the WARP MTU or build this on top of someone else's install with no MSS clamping.

> **Where to keep the `ip rule`.** Above it lives in `warp.conf` with an explicit `awg0`. The reverse also works: put `PostUp = ip rule add iif %i lookup 200` into `awg0.conf`, where `%i` expands to `awg0`, and both configs become generic. Either variant is fine; such a line in `awg0.conf` has been verified to survive the management script's `add`, `regen` and `remove` commands. What you must not do is write `iif %i` inside `warp.conf`: there `%i` expands to `warp`, and the rule would catch the wrong traffic.

<a id="step3"></a>
## Step 3. Subscribing to the BGP feed

The list of Russian networks is served by [antifilter.network](https://antifilter.network/bgp). For it to start announcing routes to your server, register the server at `https://antifilter.network/bgp`:

- **Your IP address** - the public address of your server;
- **Autonomous system number (ASN)** - `64999`;
- from the list of announcements tick only **addresses of the Russian segment**.

The form is captcha-protected, so it can only be filled in manually in a browser.

> ⚠️ The page prefills the IP field itself, and it prefills the address you are browsing from. If you are viewing the page through your own VPN, that will be the exit node's address, not the server you are configuring. Type the correct address by hand and double-check it before submitting.

Subscription parameters after submission: neighbor `45.148.244.55`, its AS `65444`, your AS `64999`. The service recommends a hold timer of 240 seconds. The Russian segment is tagged with BGP communities `65444:900` and `65445:643`; the second one is enough to select the routes you want.

<a id="step4"></a>
## Step 4. Installing and configuring BIRD

```bash
apt update && apt install -y bird2
```

The `bird2` package exists on Ubuntu, Debian 12 and Debian 13 alike. Debian 13 also ships `bird3`, but the config below is written for BIRD 2 syntax - install `bird2`.

Replace `/etc/bird/bird.conf` entirely. The only value to substitute is your server's public IP in the `router id` line:

```
log syslog all;
router id 203.0.113.10;              # your server's public IP

define COUNTRY_RU = (65445,643);

# Routes that will be pushed into the kernel (table 200).
ipv4 table warp_table;
# A separate table for resolving the neighbor's address: the session is multihop.
ipv4 table igp4;

filter warp_route {
    # The service's own address must not be routed into WARP.
    if 45.148.244.55 ~ net then reject;
    # A default route carrying the community would push all client traffic into WARP.
    if net = 0.0.0.0/0 then reject;
    if (COUNTRY_RU ~ bgp_community) then accept;
    reject;
}

filter warp_kernel {
    ifname = "warp";
    accept;
}

protocol device { scan time 10; }

# Kernel routes are needed only to resolve the neighbor's address.
# BIRD writes nothing into the main table: export none.
protocol kernel kernel_main {
    learn;
    ipv4 { table igp4; import all; export none; };
}

protocol pipe main_to_warp {
    table master4;
    peer table warp_table;
    import none;
    export all;
}

protocol kernel kernel_warp {
    ipv4 { table warp_table; import none; export filter warp_kernel; };
    kernel table 200;
}

protocol bgp antifilter {
    ipv4 {
        import filter warp_route;
        export none;
        igp table igp4;
        import limit 50000 action block;
    };
    local as 64999;
    neighbor 45.148.244.55 as 65444;
    multihop;
    hold time 240;
}
```

Check the config and start the daemon:

```bash
bird -p -c /etc/bird/bird.conf && echo "config is valid"
systemctl enable bird
systemctl restart bird
```

Note `restart`, not `enable --now`: if BIRD was already running on this server, `--now` does nothing, the daemon keeps using the old config, and the new one takes effect only at the next reboot - so you would be verifying something other than what you configured.

A few choices in this config deserve an explanation, otherwise they look arbitrary:

- **`import filter warp_route` on the session itself rather than on the `pipe`.** Community filtering happens as early as possible, so routes from other groups never reach BIRD's memory at all. If you later add other sets to your subscription, they will not spread across tables on their own.
- **Two guards in the filter.** Rejecting `0.0.0.0/0` prevents all client traffic from being pushed into WARP should a default route ever arrive carrying the community. Rejecting the network holding the service's own address serves a different purpose: the BGP session itself cannot end up in WARP anyway (it originates on the server, while the rule only catches transit from `awg0`), but client traffic to that network could, and there is no reason to send it there. Neither is present in the feed today - that was verified - but both lines cost nothing.
- **`import limit 50000 action block`** bounds the blast radius if the feed one day sends an order of magnitude more than expected. The threshold has roughly a fourfold margin over today's 11800.
- **A separate `igp4` table with `learn`.** The session with the service is multihop, and BIRD resolves the neighbor's address recursively. With no kernel routes there is nothing to resolve against, and the received routes get marked `unreachable`. Oddly enough this does not affect the end result: the `warp_kernel` filter overrides the next hop with the `warp` interface anyway, and the routes still install into table 200 correctly. But such a setup is awkward to diagnose - `birdc show route` reports `unreachable` instead of a meaningful state. With `igp4` the routes are plain `unicast` and everything reads as it should.
- **`ifname = "warp"` in `warp_kernel`** is an assignment, not a comparison. It replaces the route's next hop with the interface and produces exactly what `ip route add <prefix> dev warp table 200` would.

<a id="verify"></a>
## Verification

**On the server.** The session should be `Established` and table 200 should not be empty:

```bash
birdc show protocols antifilter          # expect Established
ip route show table 200 | wc -l          # expect roughly 11800
ip route show table 200 | head -3        # every line should read "... dev warp"
```

You can ask the kernel how it would route a client packet to a Russian address without sending any traffic. Substitute a client address from your own subnet:

```bash
ip route get 5.255.255.242 from 10.9.9.2 iif awg0
```

The answer should contain `dev warp table 200`. For a foreign address the same command should show the server's ordinary uplink interface:

```bash
ip route get 8.8.8.8 from 10.9.9.2 iif awg0
```

**From a client.** Connect to the VPN and compare how a Russian and a foreign service see you:

- a Russian one, for example `https://yandex.ru/internet` or `2ip.ru`, should show a Cloudflare address;
- a foreign one, for example `ifconfig.me`, should show your server's address.

> ⚠️ Testing with `curl` on the server itself is pointless, and this is not a nitpick about methodology. The routing rule is written as `iif awg0`, so it only matches transit traffic arriving from clients. Requests the server makes on its own behalf never match it and always take the direct path. The only honest check is from a client behind the tunnel.

<a id="failopen"></a>
## What happens when things break

Do not be lulled by the phrase "fail-open" here. Failures fall into two groups and they behave differently. Everything in the tables below was verified on a stand.

**Feed failures - traffic returns to the direct exit, connectivity is not lost:**

| Event | What happens |
|---|---|
| BIRD stopped deliberately | Routes are withdrawn, table 200 is empty, Russian traffic goes out directly from the server |
| BGP session dropped | The same: BIRD withdraws the routes and Russian sites see the data-center address again |
| `warp` interface restarted | Table 200 empties immediately - the kernel drops routes together with the vanished device. BIRD puts them back in about 20 seconds on its next kernel scan, no intervention needed |
| Server rebooted | Both interfaces come up on their own and the rules are restored from `PostUp` |

**Failures that do stop Russian traffic:**

| Event | What happens |
|---|---|
| 🔴 **The WARP peer stopped responding while the interface stayed up** | The routes in table 200 are still there and still point at `warp`, but there is no exit behind it any more. Russian addresses stop opening entirely while foreign ones carry on as if nothing happened. There is NO automatic fallback to the direct exit in this case |
| ⚠️ **BIRD killed abruptly** (`SIGKILL`, OOM, panic) | The routes stay in table 200: the kernel does not tie them to the process lifetime, and there is nobody left to withdraw them. As long as `warp` is alive Russian traffic keeps flowing through it, so the scheme still works, but the network list freezes and stops updating. Systemd brings the daemon back and it resynchronises the table |

Hence the practical point about monitoring. Session state and route count are **not enough**: in the nastiest scenario the session is up, the routes are all there, and Russian sites do not open because WARP itself is dead. If this scheme is more than an experiment for you, watch the second exit's reachability too - for example, a periodic `curl --interface warp` with a check that any answer came back at all.

<a id="trouble"></a>
## Troubleshooting

- **`awg show warp` shows no `latest handshake`.** On its own that is not yet a fault: an idle WireGuard interface does not initiate a handshake. Send some traffic first - `curl --interface warp https://api.ipify.org` - then look again. If after that no address came back and there is still no handshake, WARP really did not come up: check that outbound `2408/udp` is not blocked and that `warp.conf` carries the values from `wgcf-profile.conf`.
- 🔴 **Russian sites stopped opening entirely while foreign ones work.** That looks like a dead second exit with live routes. Check it directly: `curl --interface warp https://api.ipify.org`. If there is no answer, the problem is WARP rather than the feed, and table 200 is currently sending Russian traffic into a void. Quick remedy: `systemctl stop awg-quick@warp` - the routes go away with the interface and Russian traffic falls back to the direct exit while you investigate.
- **The BGP session sits in `Active` with `Connection reset by peer`.** The service does not know your address: either the form was not submitted, or it carries the wrong IP. That is exactly what an unregistered server looks like.
- **Session is `Established` but table 200 is empty.** Check the counters: `birdc show protocols all antifilter`. If `imported` is zero, the routes are not passing the filter - verify that the Russian segment is ticked in your subscription. If `imported` is non-zero but the kernel is empty, the problem is on export: `birdc show protocols all kernel_warp`.
- **A Russian site still opens from the data-center address.** It is most likely not hosted on a Russian IP - behind a foreign CDN or at a foreign hoster. The split is by destination address, so such a site takes the direct exit, and that is expected.
- **A Russian site goes through WARP and still behaves as if it saw a datacenter address.** It may well have seen one, just not from the connection. A script on the page can ask a third-party IP lookup service, and almost every service of that kind I checked turned out to be foreign - so if a particular one is not in the feed, the request leaves through the direct exit rather than `warp`. The script then reports the server's own address to the site, exactly the one the scheme was routing around. Whether an address is in the feed is easy to see: `ip route show table 200 match 77.88.55.242` - empty means it bypasses WARP. Writing such services into table 200 by hand is an unreliable path: their addresses depend on the resolver and change on their own. The numbers are in [ADVANCED.en.md](ADVANCED.en.md#split-detect-adv); they were measured against the snapshot of networks the cascade uses, and the feed has a list of its own.
- **It works, but not after a reboot.** Check that all three units are enabled: `systemctl is-enabled awg-quick@awg0 awg-quick@warp bird`.
- **Handshake is there but traffic to Russian addresses does not flow.** Check `sysctl net.ipv4.conf.all.rp_filter`. In strict mode (value `1`) replies arriving over `warp` are dropped silently: the reverse route to the Russian address points at the main uplink while the packet came in on a different interface. The installer from this repository sets `2`, but on a server it did not configure this is worth checking.
- **You edited `PostUp`/`PostDown`, restarted the interface, and stale rules are still in the chains.** On restart `awg-quick` runs `PostDown` from the NEW config, so rules added by the previous revision have nobody to remove them. Delete them once by hand (`iptables -D ...` with the old rule text) or reboot the server.
- **Useful raw commands.** `birdc show route table warp_table count` - how many routes were selected; `birdc show route for <address> table master4 all` - whether a specific address arrived and with which communities.

<a id="security"></a>
## Security

- The `FORWARD` rules above are narrowed to the `awg0` and `warp` pair. In the original recipe they were wider and accepted traffic into `warp` from any interface. On a typical install the difference is invisible, because only client traffic ever reaches table 200, but the narrow rule states the intent more precisely.
- Cloudflare sees the contents of your connections to exactly the same extent any other exit provider would. This changes who you trust with the exit, it does not add encryption.
- The WARP account `wgcf` issues is free and anonymous, but it is still an account: `wgcf-account.toml` and `wgcf-profile.conf` contain keys, so keep them at mode `600` and do not publish them.
- The BGP feed is an external source that influences your routing. The `import limit` and the two rejecting rules in the filter exist for precisely that reason.

<a id="limits"></a>
## Limitations and caveats

- The scheme is not part of the installer and is not managed by it. Updating the scripts will not touch it, but it will not restore it either if you break it.
- It works over IPv4: both the feed and table 200 carry IPv4 routes only. The installer keeps IPv6 disabled on the server by default; if you enabled it, the server's IPv6 traffic will bypass the split.
- IPv6 on the client device is a separate layer, and this scheme does not touch it. These instructions go on top of an existing install and do not change the client's mode. Where IPv6 goes is decided by the client's `AllowedIPs`: since v5.31.0 a full tunnel (the default "Amnezia" mode included) gets `::/0`, so IPv6 goes into the tunnel and dies there; profiles issued earlier, and real split routing (`--route-custom`), get no `::/0`, and then the device's IPv6 goes around the tunnel and a Russian site sees your real home address directly, with no scripts involved. To check from the device: `curl -6 ifconfig.co` - if your home address comes back, IPv6 is going around. Details in [ADVANCED.en.md](ADVANCED.en.md#split-detect-adv).
- Splitting by destination is visible from outside: a site can compare the connection's address with whatever a script on its page reports. That is a property of any split - see [Troubleshooting](#trouble).
- Russian sites will see a Cloudflare address, not a Russian one. For services that specifically require a Russian IP this may not be enough - that calls for a cascade with a server in Russia, see [CASCADE.en.md](CASCADE.en.md).
- WARP addresses are shared. Some Russian services treat them with suspicion, and on certain sites you may see a captcha.
- Double encapsulation adds a few milliseconds to Russian traffic and a little CPU load. Foreign traffic is unaffected - it takes the old path.
- The network list is maintained by a third party. It can be wrong in both directions: missing a Russian network, or handing you one that does not belong.

<a id="uninstall"></a>
## How to remove it

```bash
systemctl disable --now bird
systemctl disable --now awg-quick@warp
apt purge -y bird2                      # only if BIRD is not used for anything else
rm -f /etc/amnezia/amneziawg/warp.conf
rm -rf /root/warp
```

Stopping `awg-quick@warp` removes the `ip rule` and the `iptables` rules by itself - they are declared in `PostDown`. To confirm nothing is left:

```bash
ip rule show | grep 200        # empty
ip route show table 200        # empty
```

Your `amneziawg-installer` setup is unaffected: clients keep working and all traffic goes back to the direct exit.

---

The scheme was proposed by [@alexfiu4-cyber](https://github.com/alexfiu4-cyber) in [#103](https://github.com/bivlked/amneziawg-installer/issues/103). Questions and improvements - there, or in [Issues](https://github.com/bivlked/amneziawg-installer/issues).
