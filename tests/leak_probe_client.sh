#!/bin/bash
# leak_probe_client.sh —— 多设备防检测「泄露面」客户端探测脚本
#
# 在【连着该路由器的电脑/手机(termux)】上运行，运行前务必关闭本机一切代理
# (系统代理 / Clash / v2ray / WSL 代理)，否则结果不可信。
# 思路同 ua_test.sh：构造不同维度的请求，看外部服务器实际看到的值，
# 判断哪一维度的真实设备指纹还在泄露。
#
# 判定口径：服务器看到的 == 我们注入的伪装值 → 该维度已被链路收敛(好)
#           服务器看到的 == 本机真实值/能直连外部 → 该维度仍在泄露(坏)

set -u
SEP() { echo "==================================================================="; }
FAKE_UA="ProbeUA-UNIQUE-9F3X (this string must NOT reach the server verbatim)"

SEP; echo "[0] 出口 IP / 是否误走了代理"
curl -s --max-time 8 http://ip.sb 2>/dev/null || curl -s --max-time 8 http://ifconfig.me 2>/dev/null
echo

SEP; echo "[1] 明文 HTTP(80) UA 改写 —— 期望: 返回的不是上面的 ProbeUA, 而是统一伪装UA"
curl -s --max-time 8 -A "$FAKE_UA" http://httpbin.org/user-agent 2>/dev/null
echo "   多个不同 UA 应被收敛成同一个:"
for u in "Mozilla/5.0 DEVICE-A-WIN" "Mozilla/5.0 DEVICE-B-MAC" "Mozilla/5.0 DEVICE-C-ANDROID"; do
  printf '   ['"$u"'] -> '; curl -s --max-time 8 -A "$u" http://httpbin.org/user-agent 2>/dev/null | tr -d '\n'; echo
done

SEP; echo "[2] HTTPS(443) UA —— 已知残留: 期望服务器原样收到 ProbeUA(链路改不了TLS内的UA)"
curl -s --max-time 8 -A "$FAKE_UA" https://httpbin.org/user-agent 2>/dev/null
echo

SEP; echo "[3] 非标准端口明文 HTTP —— 需要一个公网回显服务. 若无可跳过."
echo "   用法: 在一台公网 VPS 上跑  ncat -lk -p 1234 -c 'printf \"HTTP/1.1 200 OK\\r\\n\\r\\n\"; cat'"
echo "   然后:  PROBE_HOST=<vps-ip> PROBE_PORTS='80 1234 2333 8000 8443' bash $0 portcheck"
if [ "${1:-}" = "portcheck" ] && [ -n "${PROBE_HOST:-}" ]; then
  for p in ${PROBE_PORTS:-80 1234 2333 8000}; do
    printf '   :%s -> ' "$p"
    curl -s --max-time 6 -A "$FAKE_UA" "http://$PROBE_HOST:$p/" 2>/dev/null | grep -i 'user-agent' | tr -d '\n'
    echo
  done
fi

SEP; echo "[4] QUIC/HTTP3 —— 期望: 失败/回退(P3 已封 UDP443)"
if curl --version 2>/dev/null | grep -qi HTTP3; then
  curl -s --max-time 8 --http3-only https://www.cloudflare.com/cdn-cgi/trace 2>&1 | grep -qiE 'h3|http/3' \
    && echo "   !! QUIC 仍可用 = P3 未生效(泄露)" || echo "   QUIC 不可用 = P3 生效(好)"
else
  echo "   本机 curl 不支持 http3, 改用浏览器访问 https://quic.nginx.org/ 看是否显示 HTTP/3"
fi

SEP; echo "[5] IPv6 —— 期望: 失败(P0 已关 v6)"
curl -s -6 --max-time 8 https://ifconfig.co 2>/dev/null \
  && echo "   !! 拿到 v6 出口 = P0 未生效(泄露)" || echo "   无 IPv6 出口 = P0 生效(好)"

SEP; echo "[6] NTP —— 期望(加固后): 无法直连外部 NTP(被重定向到路由器本地)"
if command -v ntpdate >/dev/null 2>&1; then
  ntpdate -q -t 5 time.apple.com 2>&1 | tail -2
elif command -v sntp >/dev/null 2>&1; then
  sntp -t 5 time.apple.com 2>&1 | tail -2
else
  echo "   无 ntpdate/sntp; Windows 上用:  w32tm /stripchart /computer:time.windows.com /samples:1"
fi
echo "   能成功对时 = NTP 直连外网(每台设备特征泄露); 失败/被本地应答 = 已收敛"

SEP; echo "[7] DNS 旁路 —— 期望: 客户端无法绕过路由器用外部 DNS"
nslookup -timeout=4 example.com 8.8.8.8 2>/dev/null | grep -iE 'Address|Name' | tail -2
echo "   若能从 8.8.8.8 拿到应答 = 客户端可绕过路由器DNS(各设备DNS指纹泄露)"

SEP; echo "完成。重点看 [1] 是否收敛、[3]非标端口、[6]NTP、[7]DNS。"
