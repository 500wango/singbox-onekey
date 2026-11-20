#!/usr/bin/env python3
"""sing-box 订阅服务

只暴露 /<token>/ 下的文件; 其它路径一律 404 (避免目录被枚举)。
  /<token>/            -> 索引页
  /<token>/auto         -> 按 User-Agent 自动返回对应格式
  /<token>/sub          -> base64 节点列表 (v2rayN / NekoBox / Shadowrocket)
  /<token>/clash.yaml   -> Clash.Meta / Mihomo
  /<token>/singbox.json -> sing-box 客户端配置
"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = sys.argv[1] if len(sys.argv) > 1 else ""
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
BIND = sys.argv[3] if len(sys.argv) > 3 else "0.0.0.0"
# 第 4 个参数为订阅根目录, 缺省为脚本所在目录
ROOT = sys.argv[4] if len(sys.argv) > 4 else os.path.dirname(os.path.abspath(__file__))


def pick_by_ua(ua: str) -> str:
    u = (ua or "").lower()
    if any(k in u for k in ("clash", "mihomo", "stash", "verge")):
        return "clash.yaml"
    if "sing-box" in u or "sfa" in u or "sfi" in u or "sfm" in u:
        return "singbox.json"
    return "sub"


class Handler(BaseHTTPRequestHandler):
    server_version = "sb-sub"
    sys_version = ""

    def log_message(self, format, *args):  # 静默访问日志 (noqa: A002)
        pass

    def _deny(self):
        body = b"404 not found\n"
        self.send_response(404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        dyn = pick_by_ua(self.headers.get("User-Agent", ""))
        if path in ("/", ""):
            return self._deny()

        parts = path.strip("/").split("/")
        if not parts or parts[0] != TOKEN:
            return self._deny()

        rel = "/".join(parts[1:])
        if dyn and rel in ("auto", "dyn"):
            rel = dyn
        if rel == "":
            rel = "index.html"

        # 防目录穿越
        if ".." in rel or rel.startswith("/"):
            return self._deny()

        base = os.path.realpath(os.path.join(ROOT, TOKEN))
        target = os.path.realpath(os.path.join(base, rel))
        if not target.startswith(base + os.sep) or not os.path.isfile(target):
            return self._deny()

        try:
            with open(target, "rb") as f:
                data = f.read()
        except OSError:
            return self._deny()

        ctype = {
            ".yaml": "text/yaml; charset=utf-8",
            ".json": "application/json; charset=utf-8",
            ".html": "text/html; charset=utf-8",
            ".txt": "text/plain; charset=utf-8",
        }.get(os.path.splitext(target)[1], "text/plain; charset=utf-8")

        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Profile-Update-Interval", "6")
        # Clash / sing-box 客户端会读取这两个响应头作为订阅流量信息
        self.send_header("Subscription-Userinfo", "upload=0; download=0; total=0; expire=0")
        self.end_headers()
        self.wfile.write(data)


def main():
    if not TOKEN or not os.path.isdir(ROOT):
        print("usage: subsrv.py <token> <port> [bind] [root]", file=sys.stderr)
        return 2
    httpd = ThreadingHTTPServer((BIND, PORT), Handler)
    print("serving %s on %s:%d/%s/" % (os.path.join(ROOT, TOKEN), BIND, PORT, TOKEN), flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
