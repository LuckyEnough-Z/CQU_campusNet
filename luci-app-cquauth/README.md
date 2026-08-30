# luci-app-cquauth (login.cqu.edu.cn fork)

An unofficial LuCI client for Chongqing University's campus network authentication portal.
This fork adapts the original [luci-app-cquauth](#acknowledgements) to the new
`login.cqu.edu.cn` portal that replaced the legacy `10.254.7.4` endpoint.

## What changed vs upstream

The upstream `luci-app-cquauth` targeted the old DRCOM portal at the hard-coded IP
`10.254.7.4` and parsed the HTML status page with regular expressions. After CQU
switched the campus network to a new portal at `login.cqu.edu.cn`, the upstream
plugin stopped working. This fork rewrites the protocol layer to follow the new
JSONP-based API, and adds two small fixes that are required for the daemon to
actually work on a stock ImmortalWrt install.

### Protocol layer (`root/usr/share/rpcd/ucode/cquauth`)

| Aspect | Upstream | This fork |
| --- | --- | --- |
| Auth host | `10.254.7.4` (hard-coded IPv4) | `login.cqu.edu.cn` (DNS-resolved) |
| Status / IP probe | `GET http://10.254.7.4/a79.htm`, regex on HTML (`v46ip='…'`, `uid='…'`, etc.) | `GET http://login.cqu.edu.cn/drcom/chkstatus?callback=dr1002&jsVersion=4.X&v=5505&lang=zh`, parsed as JSONP `dr1002({"v46ip":"…","uid":"…","time":…,"flow":…})` |
| Login URL | `http://10.254.7.4:801/eportal/portal/login?callback=dr1004&…&ua=…&jsVersion=4.2&v=5899&lang=zh` | `http://login.cqu.edu.cn:801/eportal/portal/login?callback=dr1004&…&term_ua=…&jsVersion=4.2.2&v=1176&lang=zh-cn` |
| Login result | HTML page, matched against Chinese substrings (`认证成功`, `密码错误`, …) | JSONP `dr1004({"result":1,"msg":"…"})`, decision by `result` integer, classification by `msg` |
| `Referer` header | `http://10.254.7.4/` | `http://login.cqu.edu.cn/` |

### LuCI daemon (`root/usr/bin/cquauth_client`)

- Auth host switched from the hard-coded `10.254.7.4` to `login.cqu.edu.cn`
  (resolved via DNS; see the installer note about `rebind_domain` below).
- **Authentication-state detection rewritten.** Upstream pinged `223.5.5.5`
  (Alibaba public DNS) to decide whether re-auth was needed. On the new portal,
  Alibaba DNS is part of the pre-auth allowlist — the ping always succeeds and
  the daemon never re-authenticates. This fork instead calls
  `ubus cquauth get_status` and decides from the `chkstatus` response, matching
  the behaviour of [`cqu-net-auth`](#acknowledgements)'s Python implementation,
  which uses the same field.
- **Three-state portal check (1.0.9).** `portal_state(conn, ifname)` returns
  `online` / `offline` / `unreachable` instead of a bare boolean. The distinction
  matters: an empty `chkstatus` response means *the portal could not be reached*,
  which is not the same as *the portal says you are logged out*. Earlier versions
  conflated the two, so a single transient failure was read as "logged out".
- **`ifup` is no longer a reflex (1.0.9).** When the portal is unreachable the
  daemon first checks the link with `iface_link_ok()` (ubus
  `network.interface.<name>.status`: `up` + an IPv4 address + a default route)
  and does nothing if the link is healthy. `ifup` on a `proto=dhcp` interface
  *releases the current lease* before re-discovering, so calling it while the
  link is fine tears down working connectivity — observed in the field as a
  20-minute outage caused by one empty `chkstatus` response, with the 60-second
  retry loop interrupting each in-flight DHCP exchange. When `ifup` genuinely is
  needed it is rate-limited (`IFUP_MIN_INTERVAL`, 300 s) and followed by polling
  for readiness (`IFUP_WAIT`, 30 s) rather than an immediate auth attempt. As a
  safety net, a portal that stays unreachable while the link is healthy still
  triggers a blind login attempt every `UNREACH_AUTH_AFTER` (3) rounds.

### Installer (`root/etc/uci-defaults/80_cquauth`)

- Idempotently inserts `list rebind_domain 'cqu.edu.cn'` into the `config dnsmasq`
  block of `/etc/config/dhcp` and restarts dnsmasq on install. **This step is
  required**: the campus DNS resolves `login.cqu.edu.cn` to a private address
  (`10.10.8.162` at the time of writing), and dnsmasq's DNS-rebind protection
  (on by default in OpenWrt / ImmortalWrt) silently drops upstream answers in
  RFC1918 ranges. Without the whitelist, every `curl login.cqu.edu.cn` from
  the router fails with `Could not resolve host`, while
  `nslookup login.cqu.edu.cn 202.202.2.50` (asking the campus DNS directly)
  returns the address correctly. dnsmasq logs
  `DNS rebinding protection is active, will discard upstream RFC1918 responses!`
  when this triggers.
- The list line is patched into the file directly with awk rather than via
  `uci add_list`, because on the ImmortalWrt 24.10 mt76x8 image we tested
  against, `uci add_list dhcp.@dnsmasq[0].rebind_domain='cqu.edu.cn'` reports
  success but the entry is immediately reverted before commit writes the file
  (`uci changes dhcp` shows a matching `-=` next to our `+=` for the same value).
  Direct file edit sidesteps whatever uci hook / validator strips it.

### Packaging (`Makefile`)

- `postinst` now uses `chmod 0755` instead of `chmod +x` on the installed
  scripts. `rpcd` refuses to load `ucode` handlers that are world-writable
  (`Ignoring ucode script ... because it is world writable`); the old `chmod +x`
  preserved the world-write bit if it was already set on the source file.
- The `mv /tmp/cquauth.bak /etc/config/cquauth` restore step now guards on
  `-f /tmp/cquauth.bak` so a fresh install no longer prints `mv: can't rename
  '/tmp/cquauth.bak': No such file or directory`.

### Sharing-detection diagnostic (`root/usr/share/cquauth/diag-sharing.sh`)

The portal periodically returns one of `共享上网` / `请勿使用代理` /
`等待5分钟` when its server-side fingerprinting suspects multiple devices
behind a single account (TTL mix, port-range entropy, UA diversity, plaintext
HTTP, etc.). Upstream just retries; `cqu-net-auth` sleeps 300s. Neither
records *which* LAN client most likely tripped the detector.

When the new code sees that message in a login response (or when you call
`ubus call cquauth diagnose '{"interface":"eth0.1"}'` on demand), it runs
`/usr/share/cquauth/diag-sharing.sh`, which writes a snapshot to
`/tmp/cquauth-sharing-<timestamp>.log`. The snapshot is generated entirely
from `/proc/net/nf_conntrack` and `/tmp/dhcp.leases`, so there is no extra
runtime dependency and no packet capture overhead. The path is also echoed
to syslog (`logread -e cquauth`) so it's easy to find.

The report contains, for every LAN-side source IP active in conntrack:

- total conn count
- TCP/80 (plaintext HTTP), TCP/443, UDP/53 counts (high HTTP ⇒ the obvious
  signal for UA-based sharing detection)
- unique source-port count and observed source-port range (wide range or
  high uniqueness on one IP ⇒ multiple OS stacks NATed behind it)

…plus a top-10 of outbound destinations and a copy of the DHCP lease table
so each IP has a hostname/MAC next to it. The "hint" section at the bottom
spells out how to read the numbers.

Since 1.0.5 the report also contains a **per-LAN-client top-10 TCP dst-port
histogram** with two tags:

- `[HTTP-likely, caught]` — port is in the plaintext-HTTP-likely set
  (`{80, 8000, 8001, 8080, 8081, 8082, 8088, 8443, 8800, 8888, 9000,
  9080, 9090}`) **and** is currently rerouted through TPROXY → UA3F, so
  the original UA is rewritten before egress. Safe.
- `[HTTP-likely, LEAK?]` — port is in the same set but **not** in the
  TPROXY catch set, so any HTTP request on that port leaves the router
  with the client's real UA. Most likely sharing-detection trigger.

The TPROXY catch set is parsed at runtime from
`nft -a list ruleset | grep 'tproxy ip to'`, so it reflects the actual
rule currently loaded rather than a hard-coded list. With the catch set
documented in `luci-app-cquauth/http_tproxy.md` (`{80, 1096, 2710, 6969,
7777, 8080}`), any HTTP request to e.g. port 8000 / 8443 / 9090 on the
campus net will show up as `[LEAK?]` and is a likely cause when
`共享上网` fires.

Remediation paths the report does not pick between for you:

- extend the TPROXY rule to catch more ports (low-cost, but you cannot
  enumerate every HTTP variant by port alone — non-HTTP traffic on the
  added ports will be mis-routed);
- DPI-based marking (nftables matching on the first few payload bytes
  for `GET ` / `POST ` / `HEAD ` / `PUT ` — more accurate but adds CPU);
- block plaintext-HTTP for the flagged client outright;
- accept the leak (the threshold for sharing-detection is volume-based;
  one-off requests usually don't trip it).

### Notes on the unchanged surface

The UI (`htdocs/luci-static/resources/view/cquauth/*.js`), the ACL
(`root/usr/share/rpcd/acl.d/luci-app-cquauth.json` — extended only to grant
the new `diagnose` method), the menu entry, the ECMP routing logic and the
multi-account / multi-interface configuration model are all preserved as-is
from upstream. If you've configured the upstream version before, the same
`/etc/config/cquauth` keeps working.

A logout RPC method is not implemented yet, even though `cqu-net-auth` ships one
against `/eportal/portal/mac/unbind`. The upstream UI never called it, so this
fork doesn't either.

## Installing

Pre-built `.ipk` (per release) goes onto the router via:

```sh
scp luci-app-cquauth_*.ipk root@<router>:/tmp/
ssh root@<router> 'opkg install /tmp/luci-app-cquauth_*.ipk && /etc/init.d/rpcd restart'
```

Then open `http://<router>/cgi-bin/luci/admin/services/cquauth` and fill in
your student/staff ID and password against the WAN interface (typically
`eth0.1` or `wan` on a single-NIC router; pick whichever device DHCP'd the
campus IP).

Building from source against the matching ImmortalWrt SDK works as a normal
LuCI package (drop this directory under the SDK's `package/`, run
`make package/luci-app-cquauth/compile V=s`). The package only depends on
`curl`; `lua` and `ucode` are part of every stock LuCI install.

## Acknowledgements

This fork stands on two pieces of prior work:

- **[lurenjiamax/luci-app-cquauth](https://github.com/lurenjiamax)** — the
  original LuCI plugin. The UI, ACL, ECMP scheduler, multi-account model and
  daemon skeleton are all theirs; this fork only swaps out the protocol layer
  and the detection logic. Listed `PKG_MAINTAINER` in the upstream Makefile:
  `lurenjiamax <lurenjiamax@gmail.com>`.
- **[haowang02/cqu-net-auth](https://github.com/haowang02/cqu-net-auth)** —
  a clean Python implementation of the new `login.cqu.edu.cn` flow. The exact
  URL shape (parameter names, `jsVersion`, `v`, double `lang`), the JSONP
  response contract and the "check `uid` to decide re-auth" idiom in this fork
  are all taken from `login.py` / `whoami.py` / `logout.py` there. Without that
  project, working out the new portal's protocol from scratch would have been
  a much longer detour.

Thanks to both authors. Bugs in this fork are mine; the parts that work are
theirs.
