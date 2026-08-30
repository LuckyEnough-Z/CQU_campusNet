#!/bin/sh
# leak_probe_router.sh —— 在【路由器】上跑的防检测体检脚本 (busybox ash 兼容)
# 用法: scp 到路由器后  sh leak_probe_router.sh
# 逐项检查 P0-P3 是否真的生效，以及还有哪些维度在泄露。

WAN=$(uci -q get network.wan.device || echo eth0.1)
LAN=$(uci -q get network.lan.ipaddr | sed 's/\.[0-9]*$/.0\/24/' || echo 192.168.1.0/24)
NF=/proc/net/nf_conntrack
GW=$(uci -q get network.lan.ipaddr || echo 192.168.1.1)
WANIP=$(ip -4 -o addr show "$WAN" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
ok(){ echo "  [OK]  $1"; }
bad(){ echo "  [!!]  $1"; }
echo "WAN=$WAN  LAN=$LAN"

echo "== [P0] IPv6 =="
# conntrack 把地址全展开写: 回环=0000:..:0001, 链路本地=fe80:.., 组播=ff0x:.. , 这些不算客户端泄露
V6=$(grep '^ipv6' $NF 2>/dev/null | grep -vE 'src=0000:0000:0000:0000:0000:0000:0000:0001|src=fe80:|src=ff0[0-9a-f]:' | grep -c .)
[ "${V6:-0}" = 0 ] && ok "无 IPv6 客户端连接(回环/链路本地不计)" || bad "存在 $V6 条 IPv6 客户端连接(P0 未净)"
[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = 1 ] && ok "disable_ipv6=1" || bad "disable_ipv6 未置1"

echo "== [P1] TPROXY 拦截 =="
TPR=$(nft list table inet tproxy_table 2>/dev/null)
if echo "$TPR" | grep -q 'tproxy ip to'; then
  if echo "$TPR" | grep -q 'dport != 443'; then
    ok "tproxy 在 (拓宽版: 除443外全劫 -> 非HTTP流量打爆ua3f, hev [E] 噪声大)"
  elif echo "$TPR" | grep -qE 'dport (80|\{ ?80)'; then
    ok "tproxy 在 (收窄版: 仅明文HTTP/80 -> 无hev噪声, 推荐)"
  else
    ok "tproxy 规则在 (自定义端口集)"
  fi
else
  bad "tproxy 规则缺失!"
fi
echo "  hev:1088 / ua3f:1080 监听:"; netstat -ltn 2>/dev/null | grep -E ':1080|:1088' | sed 's/^/    /'

echo "== [P2] TTL 统一 (关键: 受 flow offload 影响) =="
FO=$(uci -q get firewall.@defaults[0].flow_offloading)
FOH=$(uci -q get firewall.@defaults[0].flow_offloading_hw)
echo "  flow_offloading=$FO  flow_offloading_hw=$FOH"
if [ "$FO" = 1 ] || [ "$FOH" = 1 ]; then
  bad "flow offload 开启 -> 被 [OFFLOAD] 的转发连接跳过 postrouting, TTL set 64 失效!"
  echo -n "       当前被 OFFLOAD 的连接数: "; grep -c -i offload $NF 2>/dev/null
else
  ok "flow offload 已关, TTL 规则可作用于全部转发流"
fi
nft list table inet cqu_hardening 2>/dev/null | grep -q 'ttl set 64' && ok "存在 ttl set 64 规则" || bad "无 TTL 规则"

echo "== [P3] QUIC =="
# 端口要带词界, 否则 dport=443 会子串命中 dport=4437 / sport=44342 等临时端口
[ "$(grep -cE 'udp .*(dport=443|sport=443)([^0-9]|$)' $NF 2>/dev/null)" = 0 ] \
  && ok "无 QUIC(udp/443) 连接" || bad "存在 QUIC 连接(P3 未净)"

echo "== 其它泄露面 =="
# NTP: 真泄露 = LAN客户端发起的123, 且未被本地(网关)应答, 且不是路由器自身同步
nft list table inet cqu_hardening 2>/dev/null | grep -q 'dport 123 redirect' \
  && ok "NTP redirect 规则在 (客户端123 强制到本地ntpd)" || bad "无 NTP redirect 规则"
# 限定 udp + 词界: 否则 dport=123 会子串命中 TCP dport=12386 等 (NTP 仅 udp/123)
LEAK=$(grep -E 'udp .*dport=123([^0-9]|$)' $NF 2>/dev/null | grep 'src=192.168.1.' \
       | grep -v "src=$GW " | grep -v "src=$WANIP " | wc -l)
[ "$LEAK" = 0 ] && ok "无客户端 NTP 真泄露 (路由器自身 src=$WANIP 同步上游属正常)" \
  || bad "疑似 $LEAK 条客户端 NTP 未收敛(reply 非本地)"
N=$(grep -cE '(tcp|udp) .*dport=853([^0-9]|$)' $NF 2>/dev/null)
[ "$N" = 0 ] && ok "无 DoT(853) 直连" || bad "DoT 直连 $N 条 -> 客户端绕过路由器DNS"
# v3.x: 读 uci 配置的目标 UA (版本无关, 权威); 退回 logread 解析 (v3.x 走 procd 日志)
UA=$(uci -q get ua3f.main.ua)
[ -z "$UA" ] && UA=$(logread 2>/dev/null | grep -oE 'to \(Mozilla[^)]*\)' | tail -1 | sed -e 's/^to (//' -e 's/)$//')
[ -z "$UA" ] && UA=$(grep 'User-Agent:' /var/log/ua3f/*.log 2>/dev/null | tail -1 | sed 's/.*User-Agent: //')
MODE=$(pgrep -fa /usr/bin/ua3f | grep -oE '\-m [A-Z0-9]+' | head -1)
XMODE=$(pgrep -fa /usr/bin/ua3f | grep -oE '\-x [A-Z]+' | head -1)
echo "  ua3f 伪装UA: $UA  [$MODE $XMODE]"
echo "$UA" | grep -qiE 'CoolMarket|universal|[0-9]{6,}' \
  && bad "伪装UA含畸形特征(App尾巴/超长版本号), 建议换干净主流UA" \
  || ok "伪装UA 形态正常"
# v3.x RULE 模式: FINAL REPLACE 覆盖所有(含 curl/工具类, 闭合旧版泄露口); 微信/B站/Steam 走 DIRECT 放行
if pgrep -fa /usr/bin/ua3f | grep -q 'FINAL'; then
  ok "RULE ruleset 生效: 非白名单 UA 全改写(curl/工具类已闭合), 微信类二进制 DIRECT 放行"
else
  echo "  注: 非 RULE/FINAL 模式 -> 非浏览器类(curl/工具) UA 可能原样泄露(旧版 0.7.3 行为)"
fi
echo "  HTTPS(443) 整段为结构性残留: UA(TLS内)/JA3/JA4/IP-ID/TCP时间戳 路由器侧改不了"

echo "== 结论 =="
echo "  全 [OK] = P0-P3/NTP/UA 加固到位; 出现 [!!] 按对应项排查"
echo "  已知取舍: 收窄版 tproxy 下非80端口的明文HTTP UA 不改写 (换 hev 噪声为零)"
echo "  残留(成本高/无解): IP-ID(需kmod-rkp-ipid重编) / JA3-JA4 / TCP时间戳 / 连接数行为"
