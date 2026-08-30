#!/bin/sh
# netwatch-report: 统计 "门户报的 lip 归属" 与 "真实连通性" 的相关性。
# 用途: 判定 PHANTOM(门户在线但没网) 是否源于门户返回了别处会话的状态。
#   lipm=self  门户报的 lip == 本机 WAN IP
#   lipm=OTHER 门户报的 lip != 本机 WAN IP   <-- 若 PHANTOM 集中在这里, 假设成立
#   lipm=na    门户判定未认证 (真掉线, 不参与相关性)
# 只统计 v2 格式的行 (含 ok= 与 lipm=), 旧格式行自动跳过。
LOG=${1:-/tmp/netwatch.log}
[ -f "$LOG" ] || { echo "找不到日志: $LOG"; exit 1; }

N=$(grep -c 'lipm=' "$LOG")
echo "日志: $LOG"
echo "v2 格式样本: $N 分钟"
if [ "$N" = 0 ]; then
  echo "还没有 v2 格式的数据 —— 新版 netwatch.sh 刚装上? 等几分钟再看。"
  OLD=$(grep -c 'portal=' "$LOG")
  [ "$OLD" -gt 0 ] && echo "(日志里有 $OLD 行旧格式, 不含 lip 字段, 无法参与统计)"
  exit 0
fi
grep 'lipm=' "$LOG" | head -1 | cut -c1-14 | sed 's/^/  最早: /'
grep 'lipm=' "$LOG" | tail -1 | cut -c1-14 | sed 's/^/  最新: /'
echo
echo "=== 交叉表: lip 归属 x 连通性 ==="
awk '
/lipm=/ {
  ok=""; lipm=""
  for (i = 1; i <= NF; i++) {
    if ($i ~ /^ok=/)   { split($i, a, "="); ok   = a[2] }
    if ($i ~ /^lipm=/) { split($i, a, "="); lipm = a[2] }
  }
  if (ok == "" || lipm == "") next
  n[lipm]++; tot++
  if (ok == "0") { bad[lipm]++; totbad++ }
}
END {
  printf "  %-8s %8s %8s %10s\n", "lipm", "samples", "no-net", "rate"
  printf "  %-8s %8s %8s %10s\n", "--------", "------", "------", "--------"
  split("self OTHER na", order, " ")
  for (i = 1; i <= 3; i++) {
    k = order[i]
    if (k in n) printf "  %-8s %8d %8d %9.1f%%\n", k, n[k], bad[k]+0, (bad[k]+0)*100/n[k]
  }
  printf "  %-8s %8d %8d %9.1f%%\n", "TOTAL", tot, totbad+0, (tot ? totbad*100/tot : 0)
  print ""
  if (("OTHER" in n) && ("self" in n)) {
    ro = (bad["OTHER"]+0)*100/n["OTHER"]; rs = (bad["self"]+0)*100/n["self"]
    printf "  OTHER 不通率 %.1f%%  vs  self 不通率 %.1f%%\n", ro, rs
    if (n["OTHER"] < 30)
      print "  -> OTHER 样本还太少(<30), 结论不可靠, 继续攒。"
    else if (ro > rs * 3 && ro > 10)
      print "  -> 强相关: PHANTOM 明显集中在 lip 不属于本机时。假设成立。"
    else if (ro < rs * 1.5)
      print "  -> 无相关: 断网与 lip 归属无关, 应转向查上游链路/tproxy。"
    else
      print "  -> 弱相关, 样本再多些才好判断。"
  } else if ("OTHER" in n) {
    print "  -> 目前所有样本 lip 都不属于本机, 无对照组。"
  } else {
    print "  -> 目前所有样本 lip 都属于本机 (lipm=OTHER 尚未出现)。"
    print "     若期间仍发生 PHANTOM, 说明与 lip 归属无关。"
  }
}' "$LOG"
echo
echo "=== 不通的分钟明细 (最多 20 条) ==="
grep 'lipm=' "$LOG" | grep 'ok=0' | tail -20 | cut -c1-120
grep 'lipm=' "$LOG" | grep -c 'ok=0' | sed 's/^/  共 /;s/$/ 条/'
echo
echo "=== 出现过的 lip 取值分布 ==="
grep -o 'lip=[0-9.-]*' "$LOG" | sort | uniq -c | sort -rn | head -10
echo
echo "=== 持久化事件日志 (/root/netwatch-events.log) ==="
if [ -f /root/netwatch-events.log ]; then
  grep -cE 'PHANTOM|OFFLINE' /root/netwatch-events.log | sed 's/^/  事件数: /'
  grep -E 'PHANTOM|OFFLINE' /root/netwatch-events.log | tail -8 | cut -c1-130
else
  echo "  尚无事件 (好事)"
fi
