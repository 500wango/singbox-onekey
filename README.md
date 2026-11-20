# sing-box 一键安装脚本

单文件、无交互的一键部署脚本，把一个空白 Linux VPS 变成多协议代理服务器，并自带订阅服务。

```
bash <(curl -Ls https://raw.githubusercontent.com/500wango/singbox-onekey/main/sb.sh)
```

安装完成后输入 `sb` 进入管理菜单。

---

## 功能

| 能力 | 说明 |
| --- | --- |
| VLESS-Reality | XTLS-Vision，无需域名与证书，抗主动探测 |
| Hysteria2 | QUIC / UDP，弱网与跨境高丢包场景吞吐更好 |
| TUIC v5 | QUIC，BBR 拥塞控制 |
| AnyTLS | 复用式 TLS 代理，流量特征接近普通 HTTPS |
| Shadowsocks-2022 | 2022-blake3-aes-128-gcm |
| Trojan | TLS 伪装 |
| VMess-WS-TLS | 走 Cloudflare Argo 隧道，无需开放入站端口 |

默认安装前 4 个协议（Reality / Hysteria2 / TUIC / AnyTLS），其余按需在菜单里增删。

订阅服务内置，一条链接喂给客户端即可：

```
http://<ip>:<port>/<token>/auto          # 按 User-Agent 自动选择格式
http://<ip>:<port>/<token>/sub           # base64，v2rayN / NekoBox / Shadowrocket / Loon
http://<ip>:<port>/<token>/clash.yaml    # Clash.Meta / Mihomo / Stash
http://<ip>:<port>/<token>/singbox.json  # sing-box 客户端
```

`<token>` 为随机路径，访问其它路径一律 404，避免被扫描器枚举。

## 支持的系统

Debian / Ubuntu / Rocky / Alma / CentOS / Fedora / Alpine，x86_64、arm64、armv7、s390x、riscv64、loong64。

服务托管自动选择：systemd → openrc → nohup（容器、LXC 等无 init 环境）。

## 用法

```bash
sb                  # 交互菜单（未安装则直接进入安装）
sb -i               # 无交互安装
sb -c               # 查看节点信息、订阅链接、二维码
sb -r               # 重启服务
sb -v               # 内核版本
sb -u               # 卸载（配置备份到 /etc/sing-box.bak.<时间戳>）
sb -h               # 帮助
```

### 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `PORT` | 随机 | 起始端口，连续占用 8 个（各协议 + 订阅 + Argo） |
| `SNI` | `www.iij.ad.jp` | Reality 伪装目标站点 |
| `UUID` | 随机 | 指定用户 UUID |
| `ENABLE_ARGO` | `0` | 设为 `1` 同时安装 VMess-WS-TLS(Argo) 节点 |
| `ARGO_DOMAIN` | 空 | Argo 固定隧道域名，留空用临时隧道 |
| `ARGO_AUTH` | 空 | 固定隧道 Token 或 credentials JSON |
| `SUB_PORT` | `PORT+6` | 订阅服务端口 |
| `DISABLE_SUB` | `0` | 设为 `1` 不安装订阅服务 |
| `OPEN_PORTS` | `0` | 设为 `1` 自动放行 ufw / firewalld |
| `CFIP` / `CFPORT` | `cdns.doon.eu.org` / `443` | Argo 节点优选域名与端口 |
| `SB_VERSION` | `latest` | 固定内核版本，如 `1.14.4` |

示例：

```bash
# 指定端口段并自动放行防火墙
PORT=22000 OPEN_PORTS=1 bash <(curl -Ls .../sb.sh)

# 同时安装 Argo 节点（临时隧道）
ENABLE_ARGO=1 PORT=22000 bash <(curl -Ls .../sb.sh)

# 固定隧道
ENABLE_ARGO=1 ARGO_DOMAIN=node.example.com ARGO_AUTH=<token> PORT=22000 bash <(curl -Ls .../sb.sh)
```

## 设计取舍

- **每个配置写入前都跑 `sing-box check`**。校验不通过就不落盘、不重启，避免把可用的节点换成起不来的配置。
- **通配符证书自签 + `pinSHA256`**。Hysteria2 的节点链接里带证书指纹，客户端可开 `insecure=1` 同时校验指纹，比单纯跳过校验安全。
- **内置的 mmdb / rule-set 一个都不下载**。服务端只做 inbound → direct 转发，不在服务器上跑分流规则，减少外部依赖与失败点。
- **端口独占检查**。脚本维护已占用端口表，新增协议不会抢走预留端口。
- **重装幂等**。不带 `PORT` 重装时沿用原端口块、订阅端口、订阅 token 与已启用协议列表，客户端订阅不会失效。
- **不做系统级破坏**。不修改 iptables 默认策略，不改 hosts，不装 nginx，`OPEN_PORTS=1` 才动防火墙，且只加放行规则。

## 反向代理 / 已有 nginx

脚本不安装也不配置 nginx，订阅服务是独立的 Python 进程。要在 443 上复用请自行反代到 `127.0.0.1:<sub_port>`，或 `DISABLE_SUB=1` 后自行生成订阅文件（位于 `/etc/sing-box/sub/<token>/`）。

## 已验证范围

在 Debian 12、Alpine 3.20（musl）容器内实测：

- 6 个协议全部通过真实出网测试：用 sing-box 自身作客户端，经 socks 访问 `cloudflare.com/cdn-cgi/trace`，出口 IP 正确
- Clash 订阅经 mihomo v1.19.15 校验并实际连通 4 个协议
- 订阅服务的正常/错误 token、目录穿越、UA 自适应均已验证
- 重装幂等、协议增删、改端口、重置凭证、卸载均已执行

未验证：Argo / VMess 节点的端到端出网（测试网络到 Cloudflare edge 的 TLS 握手被阻断）；systemd 与 openrc 分支只核对了生成的 unit / init 脚本内容，未在真机 init 系统下运行。

## 文件说明

```
sb.sh               主脚本（安装、菜单、配置生成、订阅生成）
subsrv.py           订阅服务（token 校验、UA 自适应、防目录穿越）
tests/e2e_client.sh 协议连通性回归测试
tests/check_ports.sh 服务端监听端口检查（不依赖 ss/netstat）
```

`sb.sh` 会自动安装到 `/etc/sing-box/sb.sh` 并软链到 `/usr/local/bin/sb`；`subsrv.py` 从脚本同目录复制，缺失时回退为从本仓库下载。

## 免责声明

仅供学习与自用。请遵守所在国家/地区以及服务器所在地的法律法规，不得用于任何违法用途。因使用本脚本产生的一切后果由使用者自行承担。

## License

MIT
