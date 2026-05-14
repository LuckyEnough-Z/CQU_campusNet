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
- 已安装校园网认证插件 [luci-app-cquauth](https://github.com/lurenjiamax/luci-app-cquauth/tree/main)

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

## 可选：固定 TTL 防检测

使用 nftables：

```bash
nft add table inet ttl64
nft add chain inet ttl64 postrouting { type filter hook postrouting priority -150\; policy accept\; }
nft add rule inet ttl64 postrouting counter ip ttl set 64
```

使用 iptables：

```bash
iptables -t mangle -A POSTROUTING -j TTL --ttl-set 64
```

## 参考链接

- [luci-app-cquauth 认证插件](https://github.com/lurenjiamax/luci-app-cquauth)
- [UA3F 项目](https://github.com/SunBK201/UA3F)
- [UA3F 与 Clash 全教程](https://blog.sunbk201.site/posts/ua3f/)
- [hev-socks5-tproxy](https://github.com/heiher/hev-socks5-tproxy)
- [使用 UA2F](https://blog.krytro.com/blogs/daily/240322.html)
- [为什么路由器会被检测到](https://catalog.chn.moe/技术/OpenWrt/为啥我的路由器会被检测到/)
- [cqu-net-auth Python 认证脚本](https://github.com/haowang02/cqu-net-auth)

## 致谢

[@lurenjiamax](https://github.com/lurenjiamax)
[@haowang02](https://github.com/haowang02)

## License

[MIT](LICENSE)
