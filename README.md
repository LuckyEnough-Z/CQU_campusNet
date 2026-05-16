# CQU CampusNet

重庆大学校园网认证绕过方案 —— 基于 OpenWrt 的 TPROXY 透明代理 + UA3F User-Agent 伪装

## 工作原理

```
客户端 → nftables(TPROXY拦截) → hev-socks5-proxy → ua3f(UA伪装) → 校园网认证
```

- **nftables**：将指定端口的 HTTP 流量透明拦截，转发到本地 TPROXY 端口
- **hev-socks5-proxy**：接收 TPROXY 流量，转发给 ua3f 的 SOCKS5 代理
- **ua3f**：修改 HTTP 请求的 User-Agent，绕过校园网的路由器检测

## 前提条件

- OpenWrt 路由器（nftables ≥ 1.1.1）
- 已安装校园网认证插件 [luci-app-cquauth](./luci-app-cquauth/)（本仓库内子目录, 适配 login.cqu.edu.cn 新认证端点的 fork）

## 部署步骤

### 第一步：安装依赖

```bash
opkg update

# 安装 hev-socks5-proxy
opkg install hev-socks5-proxy

# 安装 ua3f 依赖
opkg install curl libcurl luci-compat

# 安装 ua3f
export url='https://blog.sunbk201.site/cdn' && sh -c "$(curl -kfsSl $url/install.sh)"
```

> **注意**：如果 `hev-socks5-proxy` 在 opkg 源中找不到，手动下载对应架构的二进制文件并 scp 到路由器：
> ```bash
> scp hev-socks5-tproxy-linux-mips32elsf root@192.168.1.1:/usr/bin/hev-socks5-tproxy
> ```

### 第二步：配置 ua3f

1. 登录 LuCI 界面，进入 ua3f 设置页面
2. 启用服务，User-Agent 填写 `FFF` 或自定义 UA
3. 记下 ua3f 的本地 SOCKS5 监听端口（默认 `1080`）

### 第三步：配置 hev-socks5-proxy

创建配置文件 `/etc/hevproxy.yml`：

```yaml
main:
  workers: 1

socks5:
  port: 1080
  address: 127.0.0.1
  udp: 'udp'
  mark: 0x438

tcp:
  port: 1088
  address: '0.0.0.0'

udp:
  port: 1088
  address: '0.0.0.0'

dns:
  port: 1053
  address: '::'
  upstream: 127.0.0.1
```

> `socks5` 段的 `port`/`address` 需与 ua3f 的监听地址一致。`tcp` 段的 `1088` 是 TPROXY 监听端口。

### 第四步：配置 nftables 防火墙规则

创建 `/etc/nfts/100-tproxy.nft`：

```bash
mkdir -p /etc/nfts
cat > /etc/nfts/100-tproxy.nft << 'EOF'
#!/usr/sbin/nft -f

table inet tproxy_table {
    chain prerouting {
        type filter hook prerouting priority -100; policy accept;
        ip iifname "br-lan" tcp dport { 80, 8080, 7777, 6969, 2710, 1096 } \
            tproxy ip to 127.0.0.1:1088 mark set 1
    }
}
EOF
```

> 端口列表根据实际需要拦截的认证端口调整。
>
> **建议**：单纯按端口白名单拦截会漏掉任意端口的明文 HTTP 流量（实测见过 `:8000` 泄露），
> 强烈建议直接采用下文「多设备防检测加固（P0–P3）」中的拓宽规则替代本步的端口白名单。

### 第五步：配置路由表和策略路由

```bash
# 添加路由表
echo "100 tproxy" >> /etc/iproute2/rt_tables

# 添加策略路由规则
ip rule add fwmark 1 lookup tproxy

# 添加本地路由
ip route add local 0.0.0.0/0 dev lo table tproxy
```

### 第六步：创建系统服务

创建 `/etc/init.d/tproxy_service`：

```bash
cat > /etc/init.d/tproxy_service << 'EOF'
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=95

setup_tproxy() {
    nft delete table inet tproxy_table
    nft -f /etc/nfts/100-tproxy.nft

    if ! grep -q "^100.*tproxy$" /etc/iproute2/rt_tables; then
        echo "100 tproxy" >> /etc/iproute2/rt_tables
    fi

    if ! ip rule show | grep -q "fwmark 1 lookup tproxy"; then
        ip rule add fwmark 1 lookup tproxy
    fi

    if ! ip route show table tproxy | grep -q "local 0.0.0.0/0"; then
        ip route add local 0.0.0.0/0 dev lo table tproxy
    fi
}

cleanup_tproxy() {
    nft delete table inet tproxy_table 2>/dev/null
    ip route del local 0.0.0.0/0 dev lo table tproxy 2>/dev/null
    ip rule del fwmark 1 lookup tproxy 2>/dev/null
}

start_service() {
    setup_tproxy
    procd_open_instance
    procd_set_param command /usr/bin/hev-socks5-tproxy /etc/hevproxy.yml
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    cleanup_tproxy
    killall hev-socks5-tproxy
}
EOF

chmod +x /etc/init.d/tproxy_service
```

### 第七步：启动服务

```bash
# 启动 hev-socks5-tproxy + nftables 规则
service tproxy_service start

# 开机自启
service tproxy_service enable

# 重启防火墙（应用 nftables 规则）
service firewall restart
```

## 多设备防检测加固（P0–P3，推荐）

> **原理**：ua3f 是 SOCKS5 *终结点*——凡是进入代理的流量都由路由器单一 TCP/IP 栈
> 重新发起，L3/L4 指纹（TTL、IP-ID、TCP options/timestamps、端口行为）统一，并叠加
> HTTP UA 改写，对外等效"一台主机"。检测只能抓**漏出代理**的流量，因此加固 =
> 最大化进代理的流量 + 抑制进不了代理的流量。

### P0：关闭 IPv6（最关键）

TPROXY 只处理 IPv4（`tproxy ip to`）。客户端的全局 IPv6 地址会绕过 NAT 与代理，
直接把每台设备暴露给服务器，彻底破坏"一台主机"的伪装。

```bash
uci set dhcp.lan.ra_slaac='0'
uci set dhcp.lan.ra='disabled'
uci set dhcp.lan.dhcpv6='disabled'
uci -q delete network.wan6
uci commit
grep -q disable_ipv6 /etc/sysctl.conf || {
  echo 'net.ipv6.conf.all.disable_ipv6=1'     >> /etc/sysctl.conf
  echo 'net.ipv6.conf.default.disable_ipv6=1' >> /etc/sysctl.conf
}
sysctl -p
/etc/init.d/odhcpd restart; /etc/init.d/network reload
```

> `network reload` 会瞬断 WAN，校园门户掉线几十秒，luci-app-cquauth 的守护进程会自动重认证。

### P1：拓宽 TPROXY 拦截范围（替代第四步的端口白名单）

把"按端口白名单拦截"改为"拦截除 443 与 LAN 网段外的全部 TCP"，堵住任意端口
明文 HTTP 泄露。覆盖 `/etc/nfts/100-tproxy.nft`：

```bash
cat > /etc/nfts/100-tproxy.nft << 'EOF'
#!/usr/sbin/nft -f

table inet tproxy_table {
    chain prerouting {
        type filter hook prerouting priority -100; policy accept;
        iifname "br-lan" ip daddr != 192.168.1.0/24 tcp dport != 443 \
            tproxy ip to 127.0.0.1:1088 mark set 1
    }
}
EOF
```

> - 排除 `192.168.1.0/24`：避免劫持本机 SSH/LuCI 与内网互访（**防锁死**，按你的 LAN 网段改）。
> - 排除 `dport 443`：HTTPS 直连，避免把 TLS 大流量压到弱 CPU（**变体 a**，平衡）。
> - **不要**排除 `10.0.0.0/8`：校园认证/内网是 `10.x`，必须继续走代理改写。
> - 残留：443 仍直连，客户端 443 的 TCP options/timestamps 指纹仍会泄露（弱信号）。
>   想彻底闭合可去掉 `tcp dport != 443`（**变体 b**，CPU 代价更高），或在各客户端关闭 TCP 时间戳。

### P2 + P3：固定 TTL + 封禁 QUIC

新增 `/etc/nfts/110-cqu-hardening.nft`（`oifname` 按实际 WAN 接口改，本例 `eth0.1`）：

```bash
cat > /etc/nfts/110-cqu-hardening.nft << 'EOF'
#!/usr/sbin/nft -f

table inet cqu_hardening {
    chain cqu_post {
        type filter hook postrouting priority mangle; policy accept;
        oifname "eth0.1" ip ttl set 64
    }
    chain cqu_forward {
        type filter hook forward priority -10; policy accept;
        iifname "br-lan" oifname "eth0.1" udp dport 443 reject
        iifname "br-lan" meta nfproto ipv6 counter drop
    }
}
EOF
```

> - P2：归一出口 TTL，避免多种客户端 OS 的 TTL 差异暴露多设备。
> - P3：`reject` 掉 UDP/443（QUIC），HTTP/3 回落到 TCP 从而被 ua3f 处理；并兜底 `drop` 转发的 IPv6（配合 P0）。
> - `chain` 不能命名为 `fwd`——它是 nft 保留字。

### 让加固随 tproxy_service 持久化

在 `/etc/init.d/tproxy_service` 的 `setup_tproxy()` 里追加加载、`cleanup_tproxy()` 里追加删除 110 表：

```sh
setup_tproxy() {
    nft delete table inet tproxy_table 2>/dev/null
    nft -f /etc/nfts/100-tproxy.nft
    nft delete table inet cqu_hardening 2>/dev/null
    nft -f /etc/nfts/110-cqu-hardening.nft
    # ...（路由表/ip rule/ip route 部分不变）
}

cleanup_tproxy() {
    nft delete table inet tproxy_table 2>/dev/null
    nft delete table inet cqu_hardening 2>/dev/null
    # ...
}
```

应用并自启：

```bash
service tproxy_service restart
service tproxy_service enable
```

### 回滚

```bash
cp /etc/nfts/100-tproxy.nft.cqu-bak-* /etc/nfts/100-tproxy.nft   # 还原端口白名单规则
rm -f /etc/nfts/110-cqu-hardening.nft
# 还原 tproxy_service（删掉新增的 110 两行）后：
service tproxy_service restart
# IPv6 如需恢复，按需 uci 还原 dhcp.lan/network.wan6 并去掉 sysctl 行
```

### 关于日志里的 hev-socks5-tproxy `[E]` 报错

```
daemon.err hev-socks5-tproxy[...]: [E] 0x... socks5 session handshake
daemon.err hev-socks5-tproxy[...]: [E] 0x... socks5 client read response
```

这是**上游（校园门户）短暂不可达**时，hev 把客户端连接交给 ua3f 但拨号失败造成的，
认证恢复后自动消失，**无需处理**。拓宽拦截后（P1）任何校园断网/重认证窗口都会出现
更多这类 `daemon.err`，仍属正常自愈噪音，可作为上游中断的信号。
（`uhttpd ... accepted login` 是正常的 LuCI 登录记录，非错误。）

## 替代部署：旁路由 + OpenClash

若不想把 OpenWrt 作为主路由，可作为**旁路由**（如 `lan` 设为 `192.168.1.2`、网关指向
主路由 `192.168.1.1`、DNS 指主路由 + `223.5.5.5`），用 **OpenClash（Redir-Host 模式）**
替代 hev-socks5-tproxy，后端仍接 ua3f。其设置与上面 P0–P3 原理一一对应：

| OpenClash 设置 | 对应本文加固 |
| --- | --- |
| 流量控制：禁用"仅允许常用端口流量" | **P1**（拦截全部端口而非白名单） |
| 模式：关闭 UDP 流量转发 | **P3**（抑制 QUIC/UDP） |
| 流量控制：本地 IPv4 绕过地址删除 `10.0.0.0` | 校园 `10.x` 必须走代理（本文 P1 规则也只排除 `192.168.1.0/24`） |
| DNS：禁用本地 DNS 劫持 / 关闭重绑定保护 | 旁路由需对接主路由 DNS；主路由部署下由插件的 `rebind_domain` 处理 |
| 开启旁路网关（旁路由）兼容 | 仅旁路由拓扑需要，主路由部署不涉及 |

IPv6 关闭（P0）、固定 TTL（P2）、单一 UA 同样适用于该拓扑。具体步骤参考
[UA3F/Clash 安装文档](https://sunbk201public.notion.site/UA3F-Clash-16d60a7b5f0e457a9ee97a3be7cbf557)
（另有《OpenWrt 旁路由配置.pdf》本地部署备忘，未纳入仓库）。

## 参考链接

- [luci-app-cquauth 认证插件](https://github.com/lurenjiamax/luci-app-cquauth)
- [UA3F 项目](https://github.com/SunBK201/UA3F)
- [UA3F 与 Clash 全教程](https://blog.sunbk201.site/posts/ua3f/)
- [hev-socks5-tproxy](https://github.com/heiher/hev-socks5-tproxy)
- [使用 UA2F](https://blog.krytro.com/blogs/daily/240322.html)
- [为什么路由器会被检测到](https://catalog.chn.moe/技术/OpenWrt/为啥我的路由器会被检测到/)
- [cqu-net-auth Python 认证脚本](https://github.com/haowang02/cqu-net-auth)
- [UA3F/Clash 安装文档（旁路由方案）](https://sunbk201public.notion.site/UA3F-Clash-16d60a7b5f0e457a9ee97a3be7cbf557)
- [OpenClash 项目](https://github.com/vernesong/OpenClash)
- 《OpenWrt 旁路由配置.pdf》（旁路由 + OpenClash 本地部署备忘，未纳入仓库）

## 致谢

[@lurenjiamax](https://github.com/lurenjiamax)
[@haowang02](https://github.com/haowang02)

## License

[MIT](LICENSE)
