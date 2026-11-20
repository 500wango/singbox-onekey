#!/bin/bash
# 服务端监听端口检查(不依赖 ss/netstat)
CT=${1:-sbtest}
docker exec "$CT" sh -c '
pids=$(cat /run/sing-box.pid 2>/dev/null)
if [ -n "$pids" ] && kill -0 "$pids" 2>/dev/null; then echo "sing-box: alive (pid $pids)"; else echo "sing-box: DEAD"; fi
echo "--- config ports ---"
jq -r ".inbounds[]|\"\(.tag) \(.listen_port)\"" /etc/sing-box/config.json 2>/dev/null
echo "--- listening (tcp/udp hex decode) ---"
awk "NR>1 {print \$2}" /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null \
 | awk -F: "{print strtonum(\"0x\" \$2)}" 2>/dev/null | sort -un | tr "\n" " "
echo
'
