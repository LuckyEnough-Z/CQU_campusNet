#!/bin/sh
# Dump a diagnostic snapshot of LAN-side traffic when the campus portal
# returns "sharing detected" / "请勿使用代理" / "等待5分钟". The goal is to
# narrow down which LAN client (or which traffic pattern) the upstream
# fingerprint flagged on.
#
# Usage: diag-sharing.sh [iface]
#   iface — informational only, written to the report header.
#
# Output: /tmp/cquauth-sharing-<ts>.log; path printed on stdout.

set -u
IFACE="${1:-unknown}"
TS=$(date +%Y%m%d-%H%M%S)
OUT="/tmp/cquauth-sharing-${TS}.log"

# Figure out the LAN /24 prefix from br-lan. Fall back to 192.168.1.
LAN_PREFIX=$(ip -o -4 addr show dev br-lan 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 \
    | awk -F. 'NF==4{print $1"."$2"."$3}')
[ -z "$LAN_PREFIX" ] && LAN_PREFIX="192.168.1"

{
    echo "=== cquauth sharing-detection diagnostic ==="
    echo "timestamp: $(date)"
    echo "iface:     $IFACE"
    echo "lan net:   ${LAN_PREFIX}.0/24"
    echo
    echo "--- per-LAN-client connection summary (sorted by conn count) ---"
    echo "format: ip  conns  http(80)  https(443)  dns(53)  other  uniq_sport  sport_range"
    awk -v p="${LAN_PREFIX}." '
        {
            src=""; sport=""; dport=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^src=/ && src == "")   { sub("src=","",$i);   src = $i }
                else if ($i ~ /^sport=/ && sport == "") { sub("sport=","",$i); sport = $i+0 }
                else if ($i ~ /^dport=/ && dport == "") { sub("dport=","",$i); dport = $i+0 }
            }
            if (index(src, p) != 1) next
            total[src]++
            if      (dport == 80)  http[src]++
            else if (dport == 443) https[src]++
            else if (dport == 53)  dns[src]++
            else                    other[src]++
            key = src "|" sport
            if (!(key in seen)) { seen[key]=1; uniq_sport[src]++ }
            if (min_s[src] == "" || sport+0 < min_s[src]+0) min_s[src] = sport
            if (sport+0 > max_s[src]+0) max_s[src] = sport
        }
        END {
            for (ip in total) {
                printf "%-15s  conns=%-4d  http=%-3d  https=%-3d  dns=%-3d  other=%-3d  uniq_sport=%-4d  sport_range=%s-%s\n",
                    ip, total[ip], http[ip]+0, https[ip]+0, dns[ip]+0, other[ip]+0,
                    uniq_sport[ip], min_s[ip], max_s[ip]
            }
        }
    ' /proc/net/nf_conntrack 2>/dev/null | sort -t= -k2 -nr

    echo
    echo "--- DHCP leases (hostname hints for the IPs above) ---"
    if [ -r /tmp/dhcp.leases ]; then
        awk '{printf "%-15s  %s  (mac %s)\n", $3, $4, $2}' /tmp/dhcp.leases
    else
        echo "(none)"
    fi

    echo
    echo "--- top 10 outbound destinations from LAN clients ---"
    awk -v p="${LAN_PREFIX}." '
        {
            src=""; dst=""; dport=""
            for (i=1; i<=NF; i++) {
                if ($i ~ /^src=/ && src == "") { sub("src=","",$i); src = $i }
                else if ($i ~ /^dst=/ && dst == "") { sub("dst=","",$i); dst = $i }
                else if ($i ~ /^dport=/ && dport == "") { sub("dport=","",$i); dport = $i+0 }
            }
            if (index(src, p) == 1) cnt[dst ":" dport]++
        }
        END { for (k in cnt) printf "%6d  %s\n", cnt[k], k }
    ' /proc/net/nf_conntrack 2>/dev/null | sort -nr | head -10

    echo
    echo "--- per-LAN-client top-10 TCP dst-ports (HTTP-likely / LEAK? tagged) ---"
    echo "  HTTP-likely = port plausibly carrying plaintext HTTP (UA exposure)"
    echo "  caught      = dst port is currently rerouted via TPROXY → ua3f"
    echo "  LEAK?       = HTTP-likely AND not in the TPROXY catch set"
    echo

    # Detect TPROXY catch ports from running nftables rules; fall back to the
    # set in luci-app-cquauth/http_tproxy.md.
    TPROXY_PORTS=$(nft -a list ruleset 2>/dev/null \
        | awk '/tproxy ip to/{print}' \
        | grep -oE 'dport \{[^}]+\}' | head -1 \
        | tr -d '{}' | sed 's/dport//' | tr ',' ' ' | tr -s ' ')
    [ -z "$(echo $TPROXY_PORTS | tr -d ' ')" ] && TPROXY_PORTS="80 8080 7777 6969 2710 1096"
    HTTP_LIKELY="80 8000 8001 8080 8081 8082 8088 8443 8800 8888 9000 9080 9090"
    echo "  TPROXY catch set (detected): $(echo $TPROXY_PORTS)"
    echo "  HTTP-likely port set:        $HTTP_LIKELY"
    echo

    awk -v p="${LAN_PREFIX}." '
        {
            proto=""; src=""; dport=""
            for (i=1; i<=NF; i++) {
                if (i == 3 && proto == "") proto = $i
                else if ($i ~ /^src=/ && src == "")   { sub("src=","",$i);   src = $i }
                else if ($i ~ /^dport=/ && dport == "") { sub("dport=","",$i); dport = $i+0 }
            }
            if (proto != "tcp") next
            if (index(src, p) != 1) next
            print src, dport
        }
    ' /proc/net/nf_conntrack 2>/dev/null \
        | sort | uniq -c \
        | awk -v tproxy="$TPROXY_PORTS" -v hlikely="$HTTP_LIKELY" '
            BEGIN {
                n = split(tproxy, t, " "); for (i=1; i<=n; i++) if (t[i] != "") is_tproxy[t[i]+0] = 1
                n = split(hlikely, h, " "); for (i=1; i<=n; i++) is_http[h[i]+0] = 1
            }
            { rows[++r] = $1 "|" $2 "|" $3 }
            END {
                # group by src, sort each groups ports by count desc
                for (i=1; i<=r; i++) {
                    split(rows[i], a, "|")
                    src = a[2]; cnt = a[1]+0; port = a[3]+0
                    src_seen[src] = 1
                    grp[src "|" port] = cnt
                }
                for (s in src_seen) {
                    # collect ports for this src into arr, sort by count
                    n = 0
                    for (k in grp) {
                        if (index(k, s "|") == 1) { n++; p_port[n] = substr(k, length(s)+2)+0; p_cnt[n] = grp[k] }
                    }
                    # simple insertion sort by p_cnt desc
                    for (i=2; i<=n; i++) {
                        for (j=i; j>1 && p_cnt[j] > p_cnt[j-1]; j--) {
                            t = p_cnt[j]; p_cnt[j] = p_cnt[j-1]; p_cnt[j-1] = t
                            t = p_port[j]; p_port[j] = p_port[j-1]; p_port[j-1] = t
                        }
                    }
                    printf "%s:\n", s
                    lim = (n > 10 ? 10 : n)
                    for (i=1; i<=lim; i++) {
                        tag = ""
                        if (is_http[p_port[i]]) {
                            if (is_tproxy[p_port[i]]) tag = "[HTTP-likely, caught]"
                            else                       tag = "[HTTP-likely, LEAK?]"
                        }
                        printf "  %5d/tcp  %4d conns  %s\n", p_port[i], p_cnt[i], tag
                    }
                    print ""
                    delete p_port; delete p_cnt
                }
            }
        '

    echo "--- hint ---"
    echo "* High 'http=' count → that client is sending plaintext HTTP, the"
    echo "  easiest signal for UA-based sharing detection. Consider UA3F or"
    echo "  blocking port 80 for that client."
    echo "* Very high 'uniq_sport' or wide 'sport_range' on a single client →"
    echo "  multiple OS stacks behind a NAT (which is exactly what the portal"
    echo "  is looking for)."
    echo "* [HTTP-likely, LEAK?] tags above flag dst ports plausibly carrying"
    echo "  HTTP that your TPROXY rule does NOT currently redirect, so any UA"
    echo "  on those ports reaches the campus net raw. Either add those ports"
    echo "  to the TPROXY catch set in /etc/nfts/100-tproxy.nft, or block them"
    echo "  for that client."
} > "$OUT" 2>&1

echo "$OUT"
