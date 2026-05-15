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

- `LOGIN_SERVER` constant switched from `10.254.7.4` to `login.cqu.edu.cn`.
- **Authentication-state detection rewritten.** Upstream pinged `223.5.5.5`
  (Alibaba public DNS) to decide whether re-auth was needed. On the new portal,
  Alibaba DNS is part of the pre-auth allowlist — the ping always succeeds and
  the daemon never re-authenticates. This fork adds `is_authenticated(conn, ifname)`
  which calls `ubus cquauth get_status` and treats the account as authenticated
  iff `uid` is present (and not `"N/A"`). This matches the behaviour of
  [`cqu-net-auth`](#acknowledgements)'s Python implementation, which uses the
  same `chkstatus` field for the decision.

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

### Notes on the unchanged surface

The UI (`htdocs/luci-static/resources/view/cquauth/*.js`), the ACL
(`root/usr/share/rpcd/acl.d/luci-app-cquauth.json`), the menu entry, the ECMP
routing logic and the multi-account / multi-interface configuration model are
all preserved as-is from upstream. If you've configured the upstream version
before, the same `/etc/config/cquauth` keeps working.

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
