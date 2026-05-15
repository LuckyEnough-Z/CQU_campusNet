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
    echo "--- hint ---"
    echo "* High 'http=' count → that client is sending plaintext HTTP, the"
    echo "  easiest signal for UA-based sharing detection. Consider UA3F or"
    echo "  blocking port 80 for that client."
    echo "* Very high 'uniq_sport' or wide 'sport_range' on a single client →"
    echo "  multiple OS stacks behind a NAT (which is exactly what the portal"
    echo "  is looking for)."
} > "$OUT" 2>&1

echo "$OUT"
