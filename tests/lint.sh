#!/usr/bin/env bash
# 静态检查: bash 语法 + Python 语法 + 关键安全项自检
set -euo pipefail
cd "$(dirname "$0")/.."
fail=0

echo "== bash 语法 =="
for f in sb.sh tests/*.sh; do
    [ -f "$f" ] || continue
    if bash -n "$f" 2>/tmp/syn.err; then
        echo "  ok   $f"
    else
        echo "  FAIL $f"; cat /tmp/syn.err; fail=1
    fi
done

echo "== python 语法 =="
for f in subsrv.py; do
    if python3 -m py_compile "$f" 2>/tmp/py.err; then
        echo "  ok   $f"
    else
        echo "  FAIL $f"; cat /tmp/py.err; fail=1
    fi
done

echo "== 危险模式自检 =="
# 1) 不应出现 rm -rf / 或对 $HOME 的无保护删除
if grep -nE 'rm -rf +/(\s|$|")' sb.sh; then
    echo "  FAIL 发现 rm -rf /"; fail=1
else
    echo "  ok   无 rm -rf /"
fi
# 2) 不应修改 iptables 默认策略为 DROP/无条件 ACCEPT
if grep -nE 'iptables -P (INPUT|FORWARD|OUTPUT)' sb.sh; then
    echo "  WARN 存在 iptables 默认策略修改"
else
    echo "  ok   未修改 iptables 默认策略"
fi
# 3) 所有生成的链接不应包含明文 insecure 之外的降级(仅提示, 不算失败)
echo "  info insecure=1 出现次数: $(grep -c 'insecure=1\|allow_insecure=1\|allowInsecure=1' sb.sh || true)"

echo "== 占位符检查 =="
if grep -n 'USER/REPO' README.md sb.sh; then
    echo "  FAIL README/脚本仍含 USER/REPO 占位符"; fail=1
else
    echo "  ok   无遗留占位符"
fi

exit $fail
