# router/ — 路由器上的运维文件（不属于 ipk）

这些文件跑在路由器上，但**不在 `luci-app-cquauth` 包里**，所以 `sysupgrade`
（哪怕勾了保留配置）会把它们连同后装的软件包一起清掉。放在这里是为了刷机后
能照着恢复，而不是靠回忆。

路径按机器上的真实位置组织，`router/` 就是 `/` 。

| 文件 | 位置 | 作用 |
|---|---|---|
| `usr/bin/netwatch.sh` | `/usr/bin/` | 每分钟对照「门户说在线」与「真的能上网」，抓 PHANTOM 幽灵态。cron `* * * * *` |
| `usr/bin/netwatch-report.sh` | `/usr/bin/` | 读 netwatch 日志出统计表，判断断网与门户会话字段是否相关 |
| `etc/init.d/tproxy_service` | `/etc/init.d/` | 装 nft 规则 + ip rule/route，拉起 `hev-socks5-tproxy`。`reassert` 子命令做幂等自愈，cron `*/2 * * * *` |
| `etc/init.d/ua3f` | `/etc/init.d/` | 拉起 ua3f（UA 改写 SOCKS5 代理），参数从 uci `ua3f` 读 |
| `etc/nfts/100-tproxy.nft` | `/etc/nfts/` | 只把 LAN→外网的明文 HTTP(80) tproxy 进 hev→ua3f；其余 TCP 与全部 UDP 直连 |
| `etc/nfts/110-cqu-hardening.nft` | `/etc/nfts/` | 防检测加固：出 WAN 统一 TTL=64、封 LAN 的 QUIC(udp/443)、丢 IPv6、NTP 重定向到本机 |
| `etc/hevproxy.yml` | `/etc/` | hev-socks5-tproxy 配置：tproxy 收 1088，转发到本机 socks5 1080（即 ua3f） |

## 刻意没有收进来的

- **`/etc/config/*`** —— uci 运行时配置。`cquauth` 里有账号密码，其余是设备相关的，
  不进版本库。刷机后用 sysupgrade 的配置备份恢复，或在 LuCI 里重填。
- **`/usr/bin/ua3f` 二进制**（约 17 MB）—— 从 ua3f 上游 release 下载，不适合进 git。
- **`/etc/nfts/20-http-tproxy.nft`** —— 机器上还留着的一份**失效旧配置**：它建的是
  `table ip tproxy_table`（family 是 `ip`，不是现在用的 `inet`），还引用着换端点前的
  老认证服务器 `10.254.7.4`。`tproxy_service` 不加载它，当前 ruleset 里也没有它。
  留在机器上是历史残留，可以删。

## 刷机后的恢复顺序

```sh
# 1. 装回软件包
opkg update && opkg install jq uclient-fetch hev-socks5-tproxy \
    kmod-nf-tproxy kmod-nft-tproxy kmod-nf-conntrack-netlink \
    luci-compat luci-lua-runtime lua libubus-lua

# 2. ua3f 二进制从上游 release 下载后放到 /usr/bin/ua3f 并 chmod 0755

# 3. 铺开本目录 (注意保持 LF, 见仓库根 .gitattributes)
scp -r router/etc/* root@192.168.1.1:/etc/
scp -r router/usr/* root@192.168.1.1:/usr/
ssh root@192.168.1.1 'chmod 0755 /etc/init.d/tproxy_service /etc/init.d/ua3f \
    /usr/bin/netwatch.sh /usr/bin/netwatch-report.sh'

# 4. 装 cquauth ipk
opkg install --force-reinstall luci-app-cquauth_*.ipk
killall -9 rpcd; /etc/init.d/rpcd start     # restart 不会重扫 ucode 目录

# 5. 开机自启 + 定时任务
/etc/init.d/tproxy_service enable && /etc/init.d/ua3f enable
crontab -e   # 加:
#   */2 * * * * /etc/init.d/tproxy_service reassert >/dev/null 2>&1
#   *   * * * * /usr/bin/netwatch.sh
```

恢复完的验收：`ubus call cquauth get_status '{"interface":"wan"}'` 要有 `uid` 和
`reachable: true`；`nft list tables` 要能看到 `inet tproxy_table` 和 `inet cqu_hardening`。
