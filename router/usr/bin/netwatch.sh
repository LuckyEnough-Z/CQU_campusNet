#!/bin/sh
# netwatch: 每分钟记 门户状态 vs 真实连通, 抓"已在线却没网"幽灵态
# v2 (2026-08-26): 每行增记门户会话身份字段 (lip/v4ip/olmac/fsele/aolno),
#   用于判定 PHANTOM 是否与"门户返回的是别处的会话"相关 (lipm=OTHER)。
#   PHANTOM / 真掉线 事件另写持久化日志 (重启不丢, 仅事件时写 flash)。
#   字段全部无空格, 便于 netwatch-report.sh 用 awk 统计; net 详情用逗号分隔。
LOG=/tmp/netwatch.log
EVT=/root/netwatch-events.log
KEEP=5000          # /tmp 是 tmpfs, 5000 行约 3.5 天
TS=$(date '+%m-%d %H:%M:%S')
WANIF=$(uci -q get network.wan.device || echo wan)
WANIP=$(ip -4 -o addr show "$WANIF" 2>/dev/null | sed -n 's#.*inet \([0-9.]*\)/.*#\1#p' | head -1)

CHK=$(uclient-fetch -q -T 6 -O - "http://login.cqu.edu.cn/drcom/chkstatus?callback=dr1002&v=5505" 2>/dev/null)
echo "$CHK" | grep -q '"uid"' && PORTAL=online || PORTAL=OFFLINE

# 取 JSONP 单字段 (payload 内字段名唯一, 贪婪匹配安全; 不取 uid, 避免落盘)
fs() { echo "$CHK" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1; }
fn() { echo "$CHK" | sed -n "s/.*\"$1\":\(-\?[0-9][0-9]*\).*/\1/p" | head -1; }
LIP=$(fs lip);     [ -n "$LIP" ]     || LIP=-
V4=$(fs v4ip);     [ -n "$V4" ]      || V4=-
OLMAC=$(fs olmac); [ -n "$OLMAC" ]   || OLMAC=-
FSELE=$(fn fsele); [ -n "$FSELE" ]   || FSELE=-
AOLNO=$(fn aolno); [ -n "$AOLNO" ]   || AOLNO=-

# 核心待验证信号: 门户报的 lip 是不是本机 WAN
if [ "$PORTAL" = OFFLINE ]; then
  LIPM=na
elif [ -n "$WANIP" ] && [ "$LIP" = "$WANIP" ]; then
  LIPM=self
else
  LIPM=OTHER
fi

C1=$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://www.baidu.com 2>/dev/null)
if [ "$C1" = 200 ]; then
  NET=200; OK=1
else
  C2=$(curl -s -o /dev/null -m 8 -w '%{http_code}' http://www.qq.com 2>/dev/null)
  if [ "$C2" = 200 ]; then NET="ok(qq)"; OK=1
  else NET="FAIL(baidu=$C1,qq=$C2)"; OK=0; fi
fi
CT=$(grep -c . /proc/net/nf_conntrack 2>/dev/null)
RT=$(ip route show default 2>/dev/null | head -1 | tr -s ' ')

echo "$TS portal=$PORTAL ok=$OK net=$NET lipm=$LIPM lip=$LIP v4=$V4 olmac=$OLMAC fsele=$FSELE aolno=$AOLNO ct=$CT route=[$RT]" >> "$LOG"

WROTE_EVT=0
if [ "$PORTAL" = online ] && [ "$OK" = 0 ]; then
  {
    echo "$TS *** PHANTOM: 门户在线但真实没网 ***  lipm=$LIPM lip=$LIP wan=$WANIP olmac=$OLMAC fsele=$FSELE aolno=$AOLNO ct=$CT net=$NET"
    echo "   snap routes:    $(ip route show table main 2>/dev/null | tr '\n' '|')"
    echo "   snap $WANIF:     $(ip -4 -o addr show "$WANIF" 2>/dev/null | sed -n 's#.*\(inet [0-9./]*\).*#\1#p' | tr '\n' ' ')"
    echo "   snap tproxy:    rule=$(ip rule show 2>/dev/null | grep -c 'fwmark 0x1 lookup tproxy') rt=$(ip route show table tproxy 2>/dev/null | grep -c 'local default') nft=$(nft list tables 2>/dev/null | grep -cE 'tproxy_table|cqu_hardening')"
    echo "   snap chkstatus: $(echo "$CHK" | sed -E 's/[0-9]{9,}[A-Za-z]?/N/g' | head -c 400)"
  } | tee -a "$EVT" >> "$LOG"
  logger -t netwatch "PHANTOM: portal online but no internet (baidu=$C1 lipm=$LIPM lip=$LIP)"
  WROTE_EVT=1
elif [ "$PORTAL" = OFFLINE ]; then
  echo "$TS --- OFFLINE: 门户判定未认证 (net=$NET wan=$WANIP) ---" >> "$EVT"
  WROTE_EVT=1
fi

tail -n "$KEEP" "$LOG" > "$LOG.t" 2>/dev/null && mv "$LOG.t" "$LOG"
# 事件日志在 overlay(flash) 上, 只在真写了事件时才轮转, 避免每分钟一次 flash 写
[ "$WROTE_EVT" = 1 ] && { tail -n 800 "$EVT" > "$EVT.t" 2>/dev/null && mv "$EVT.t" "$EVT"; }
exit 0
