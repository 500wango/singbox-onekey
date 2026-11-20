#!/bin/bash
# e2e 客户端连通性测试: 用 sing-box 自身作为客户端, 逐个协议走 socks 探测真实出网
set -u
W=/etc/sing-box
BIN=${W}/sing-box
# 用当前订阅路径(由 meta 决定), 不走旧目录
TOKEN=$(jq -r '.sub.token' ${W}/meta.json)
D="${W}/sub/${TOKEN}/"
APIBASE=19100
pass=0; fail=0
[ -f "${D}proxies.json" ] || { echo "缺少 ${D}proxies.json"; exit 1; }
LIST=$(jq -r '.[] | .tag' "${D}proxies.json")
echo "用例: $(echo $LIST | tr '\n' ' ')"
for t in $LIST; do
  APIBASE=$((APIBASE+2))
  if [ "$t" = "proxy-argo" ]; then
    echo "[SKIP] $t  (依赖 Argo 隧道出网, 单独验证)"
    continue
  fi
  # 客户端连本机回环地址的同端口服务
  jq --arg t "$t" --argjson mp "$APIBASE" '
    { log:{level:"error"},
      inbounds:[{type:"mixed",tag:"in",listen:"127.0.0.1",listen_port:$mp}],
      outbounds: ([ .[] | select(.tag==$t) | .server="127.0.0.1" ] + [{type:"direct",tag:"direct"}]),
      route:{final:$t} }' "${D}proxies.json" > /tmp/c.json
  ${BIN} check -c /tmp/c.json || { echo "[FAIL] $t 客户端配置非法"; fail=$((fail+1)); continue; }
  ${BIN} run -c /tmp/c.json >/tmp/c.log 2>&1 &
  CPID=$!
  sleep 3
  out=$(curl -s --max-time 15 --socks5-hostname 127.0.0.1:$APIBASE https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^(ip|loc)=' | tr '\n' ' ')
  if [ -n "$out" ]; then
    echo "[ OK ] $t -> $out"
    pass=$((pass+1))
  else
    echo "[FAIL] $t  无出网流量"
    tail -2 /tmp/c.log | sed 's/^/       /'
    fail=$((fail+1))
  fi
  kill $CPID 2>/dev/null; wait $CPID 2>/dev/null
done
echo "----"
echo "通过 $pass / 失败 $fail"
[ "$fail" -eq 0 ]
