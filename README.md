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
| `OPEN_PORTS` | `auto` | `auto`=自动放行本机所有会拦入站的防火墙；`1`=连没有 drop 策略的也建显式白名单；`0`=完全跳过 |
| `CFIP` / `CFPORT` | `cdns.doon.eu.org` / `443` | Argo 节点优选域名与端口 |
| `SB_VERSION` | `latest` | 固定内核版本，如 `1.14.4` |

示例：

```bash
# 指定端口段（防火墙有 ufw/firewalld 会自动放行）
PORT=22000 bash <(curl -Ls .../sb.sh)

# 没有任何防火墙管理工具时，也强制直插 iptables/nft 放行
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
- **不做系统级破坏**。不修改任何防火墙的默认策略，不改 hosts，不装 nginx。只追加 ACCEPT 放行规则，不加任何拒绝规则、不删任何现有规则。
- **放行覆盖四层防火墙**。ufw / firewalld / nftables 独立表 / iptables。尤其 nftables 的独立 `inet` 表（如第三方项目自建的 policy drop 表）用 `iptables -L` 完全看不到，是最容易被忽略的一层，脚本会解析 `nft -j list ruleset` 找出所有 `hook input + policy drop` 的链并插入规则，写完后回读验证，失败会明确报错而不是假报成功。
- **装完会自检端口**。光看进程在跑不代表外部能连，所以安装结束会逐端口检查监听/本机连通，并提示如何从外部验证。

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

## 排障: 装完了但客户端连不上

先跑 `sb -p`（端口自检），它会逐端口告诉你是哪种情况:

| 自检结果 | 含义 | 处理 |
| --- | --- | --- |
| `未监听` | 进程没在听这个端口 | 看 `/etc/sing-box/logs/sing-box.log`，多为配置或端口占用 |
| `本机拒连` | 回环都连不上 | 服务异常，`sb -r` 重启后看日志 |
| `仅内网` | 本机公网 IP 连不上自己 | NAT 型机器，需在商家面板做端口映射 |
| `正常` | 本机侧没问题 | 拦截在上游，看下面 |

**本机正常但外部连不上**，按顺序查:

1. 云厂商安全组 / 防火墙面板。脚本只能改机器内部防火墙，改不了控制台。阿里云、腾讯云、AWS、GCP、Contabo 都要在面板单独放行，TCP 和 UDP 要分别放。
2. 上游机房端口过滤。在另一台机器上从外部验证:
   ```bash
   curl -m 5 http://<VPS_IP>:<订阅端口>/    # 返回 404 说明通了; 超时=被拦
   nc -vz <VPS_IP> <节点端口>
   ```
   注意区分:**超时**说明数据包被丢弃（防火墙/上游拦截）；**connection refused** 说明包到了但没人监听（本地问题）。
3. NAT 型机器要在商家面板把端口映射出来，并把映射后的端口传给 `PORT`。

**Hysteria2 / TUIC 显示延迟 -1** 不一定是故障: 这两个协议走 UDP，而多数客户端（如 v2rayN 的 TCP 测速）测不到 UDP。判断这两个节点要看能否实际上网，不要看延迟数字。

**REALITY: processed invalid connection** 是 Reality 的正常行为: 探测到非客户端流量时回落到伪装站点，不是错误。

### Contabo 用户特别注意

Contabo 的 Firewall 面板默认策略是 **丢弃所有入站流量**，即使显示 `No firewall assigned` 也一样（只有 22 端口被放行防锁死）。所以装完脚本后节点全部超时，不是脚本问题。

在 Contabo 控制台: 服务器 → Firewall → Assign firewall（没有就 Create firewall），添加入站规则:

| 方向 | 协议 | 端口 | 用途 |
| --- | --- | --- | --- |
| Inbound | TCP | 22 | SSH（**必须保留**，删掉会失去服务器） |
| Inbound | TCP | 20338 | VLESS-Reality |
| Inbound | UDP | 20339 | Hysteria2 |
| Inbound | UDP | 20340 | TUIC |
| Inbound | TCP | 20341 | AnyTLS |
| Inbound | TCP | 20344 | 订阅服务 |

省事做法: 直接放行 `TCP 20338-20347` 与 `UDP 20338-20347` 整段 + `TCP 22`，以后加 trojan / ss2022 / vmess 就不用回来改规则。

规则保存后立即生效，无需重启服务器。Assign 前请再次确认列表里有 22 端口。
