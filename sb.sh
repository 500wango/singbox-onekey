#!/bin/bash
#==============================================================================
#  sing-box 一键安装脚本  (single-file installer)
#  协议: VLESS-Reality / Hysteria2 / TUIC v5 / AnyTLS / Shadowsocks-2022
#        / Trojan / VMess-WS-TLS(Cloudflare Argo)
#  订阅: 内置 HTTP 订阅服务 (v2ray base64 / Clash-Mihomo / sing-box 客户端)
#  系统: Debian Ubuntu Rocky Alma CentOS Fedora Alpine (systemd / openrc)
#
#  安装: bash <(curl -Ls https://raw.githubusercontent.com/500wango/singbox-onekey/main/sb.sh)
#  管理: sb
#==============================================================================

export LANG=en_US.UTF-8
umask 022

# ------------------------------ 基本常量 ------------------------------
SB_RAW_URL="${SB_RAW_URL:-https://raw.githubusercontent.com/500wango/singbox-onekey/main/sb.sh}"
WORK_DIR="${WORK_DIR:-/etc/sing-box}"
BIN="${WORK_DIR}/sing-box"
CONF="${WORK_DIR}/config.json"
META="${WORK_DIR}/meta.json"
SUB_DIR="${WORK_DIR}/sub"
LOG_DIR="${WORK_DIR}/logs"
SB_VERSION="${SB_VERSION:-latest}"

# 环境变量:
#   PORT=起始端口(连续占用 8 个) SNI=Reality伪装域名 UUID=指定UUID
#   ENABLE_ARGO=1 ARGO_DOMAIN=xx ARGO_AUTH=token|json
#   SUB_PORT=订阅端口 DISABLE_SUB=1 不装订阅 OPEN_PORTS=1 自动放行防火墙
#   CFIP/CFPORT=Argo 优选域名/端口   SB_VERSION=1.14.4 固定内核版本

# ------------------------------ 输出函数 ------------------------------
if [ -t 1 ]; then
    C_R=$'\033[1;91m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
    C_P=$'\033[1;35m'; C_B=$'\033[1;36m'; C_N=$'\033[0m'
else
    C_R=""; C_G=""; C_Y=""; C_P=""; C_B=""; C_N=""
fi
info()  { printf '%s %s\n' "${C_B}[信息]${C_N}" "$*"; }
ok()    { printf '%s %s\n' "${C_G}[完成]${C_N}" "$*"; }
warn()  { printf '%s %s\n' "${C_Y}[注意]${C_N}" "$*"; }
err()   { printf '%s %s\n' "${C_R}[错误]${C_N}" "$*" >&2; }
die()   { err "$*"; exit 1; }
title() { printf '%s\n' "${C_P}$*${C_N}"; }
line()  { printf '%s\n' "${C_Y}----------------------------------------------------------------${C_N}"; }
need()  { command -v "$1" >/dev/null 2>&1; }
ask() {
    local q=$1 d=$2 a
    printf '%s' "${C_Y}${q}${C_N}${d:+ [$d]}: " >&2
    if ! read -r a; then
        # 标准输入已关闭(如 CI/管道结束), 直接退出, 避免死循环
        printf '\n' >&2
        exit 0
    fi
    printf '%s' "${a:-$d}"
}

# ------------------------------ 环境检测 ------------------------------
detect_os() {
    OS_ID=unknown; PKG=""; INIT=nohup
    if [ -r /etc/os-release ]; then . /etc/os-release; OS_ID=${ID:-unknown}; fi
    if need apk;        then PKG=apk
    elif need apt-get;  then PKG=apt
    elif need dnf;      then PKG=dnf
    elif need yum;      then PKG=yum
    fi
    [ -n "$PKG" ] || die "无法识别包管理器 (apt / dnf / yum / apk 均不存在)"
    if need systemctl && systemctl show-environment >/dev/null 2>&1; then
        INIT=systemd
    elif need rc-service && [ -d /etc/init.d ]; then
        INIT=openrc
    else
        INIT=nohup
    fi
}

pkg_install() {
    local p missing=()
    for p in "$@"; do need "$p" || missing+=("$p"); done
    [ ${#missing[@]} -eq 0 ] && return 0
    info "安装依赖: ${missing[*]}"
    case "$PKG" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
             DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null 2>&1 ;;
        dnf) dnf install -y -q "${missing[@]}" >/dev/null 2>&1 ;;
        yum) yum install -y -q "${missing[@]}" >/dev/null 2>&1 ;;
        apk) apk add --no-cache "${missing[@]}" >/dev/null 2>&1 ;;
    esac
    return 0
}
require_root() { [ "$(id -u)" -eq 0 ] || die "请用 root 运行: su - 或 sudo -i"; }

arch_detect() {
    ARCH_RAW=$(uname -m)
    case "$ARCH_RAW" in
        x86_64|amd64)   ARCH=amd64 ;;
        i386|i686|x86)  ARCH=386 ;;
        aarch64|arm64)  ARCH=arm64 ;;
        armv7l|armv7)   ARCH=armv7 ;;
        armv6l)         ARCH=armv6 ;;
        armv5tel)       ARCH=armv5 ;;
        s390x)          ARCH=s390x ;;
        riscv64)        ARCH=riscv64 ;;
        loongarch64)    ARCH=loong64 ;;
        *) die "不支持的架构: $(uname -m)" ;;
    esac
    LIBC=""
    if [ -f /etc/alpine-release ] || (ldd /bin/sh 2>/dev/null | grep -qi musl); then LIBC="-musl"; fi
}

# ------------------------------ 网络/下载 ------------------------------
dl() {
    if need curl; then
        curl -fL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 900 -o "$2" "$1" 2>/dev/null
    elif need wget; then
        wget -q -T 25 -t 2 -O "$2" "$1" 2>/dev/null
    else
        return 1
    fi
}

dl_mirror() {
    local u
    for u in \
        "https://github.com/$1" \
        "https://ghfast.top/https://github.com/$1" \
        "https://gh-proxy.com/https://github.com/$1" \
        "https://ghproxy.net/https://github.com/$1"
    do
        dl "$u" "$2" && [ -s "$2" ] && return 0
    done
    return 1
}

api_json() {
    if need curl; then curl -fsSL --connect-timeout 10 --max-time 30 "$1" 2>/dev/null
    else wget -q -T 15 -O - "$1" 2>/dev/null; fi
}

get_public_ip() {
    local ip
    ip=$(curl -4 -fsm 5 https://api.ipify.org 2>/dev/null || curl -4 -fsm 5 https://ip.sb 2>/dev/null)
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
    ip=$(curl -6 -fsm 5 https://api64.ipify.org 2>/dev/null)
    [ -n "$ip" ] && printf '[%s]' "$ip" || printf '127.0.0.1'
}

get_isp() {
    local j v
    # 依次尝试多个免费接口, 任一成功即返回
    j=$(api_json "https://ipwho.is/")
    if [ -n "$j" ]; then
        v=$(printf '%s' "$j" | jq -r 'select(.success==true) | (.country_code//"XX")+"-"+(.connection.isp//.connection.org//"ISP")' 2>/dev/null)
        [ -n "$v" ] && { printf '%s' "${v// /_}"; return; }
    fi
    v=$(curl -fsm 6 https://ipinfo.io/org 2>/dev/null)
    if [ -n "$v" ]; then
        local cc; cc=$(curl -fsm 6 https://ipinfo.io/country 2>/dev/null)
        printf '%s' "${cc:-XX}-${v// /_}" | tr -d '\n'; return
    fi
    j=$(api_json "http://ip-api.com/json/?fields=countryCode,isp")
    if [ -n "$j" ]; then
        v=$(printf '%s' "$j" | jq -r '(.countryCode//"XX")+"-"+(.isp//"ISP")' 2>/dev/null)
        [ -n "$v" ] && { printf '%s' "${v// /_}"; return; }
    fi
    j=$(api_json "https://api.ip.sb/geoip")
    if [ -n "$j" ]; then
        v=$(printf '%s' "$j" | jq -r '(.country_code//"XX")+"-"+(.isp//.organization//"ISP")' 2>/dev/null)
        [ -n "$v" ] && { printf '%s' "${v// /_}"; return; }
    fi
    printf 'NODE'
}

port_free() {
    local p=$1 proto=$2
    port_reserved "$p" && return 1
    need ss || return 0
    if [ "$proto" = udp ]; then
        ss -Hlun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && return 1
    else
        ss -Hltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && return 1
    fi
    return 0
}

# 判断端口是否已被本脚本占用 (仅统计已启用协议 + 预留的 vmess/订阅端口)
port_reserved() {
    local p=$1
    [ "${SB_RESERVING:-1}" = "1" ] || return 1
    [ "$p" = "${SB_ALLOW_PORT:-}" ] && return 1
    [ -f "$META" ] || return 1
    local used
    used=$(jq -r '
        (.enabled // []) as $en
        | [ (if ($en|index("reality")) then .reality.port else empty end),
            (if ($en|index("hy2")) then .hy2.port else empty end),
            (if ($en|index("tuic")) then .tuic.port else empty end),
            (if ($en|index("anytls")) then .anytls.port else empty end),
            (if ($en|index("trojan")) then .trojan.port else empty end),
            (if ($en|index("ss2022")) then .ss2022.port else empty end),
            .vmess.port, .sub.port ]
        | map(select(. != null and . != 0)) | join(" ")' "$META" 2>/dev/null)
    case " $used " in *" $p "*) return 0 ;; esac
    return 1
}

pick_block() { # 安装用: 从起始值向上找连续 8 个可用端口块
    local start=$1 i b
    for i in $(seq 0 500); do
        b=$((start + i))
        (( b < 1024 || b + 8 > 65535 )) && continue
        if port_free $b tcp && port_free $((b+1)) udp && port_free $((b+2)) udp \
           && port_free $((b+3)) tcp && port_free $((b+4)) tcp && port_free $((b+5)) tcp \
           && port_free $((b+6)) tcp && port_free $((b+7)) tcp; then
            printf '%s' "$b"; return 0
        fi
    done
    printf '%s' "$1"
}

pick_one() { # 单个新协议用: 从起始值向上找第一个空闲且未被占用的端口
    local start=$1 proto=$2 i p
    for i in $(seq 0 900); do
        p=$((start + i))
        (( p < 1024 || p > 65535 )) && continue
        port_free "$p" "$proto" && { printf '%s' "$p"; return 0; }
    done
    printf '%s' "$1"
}

open_firewall() { # open_firewall 20338/tcp 20339/udp ...
    # 策略: 把本机所有"会拦入站"的防火墙都放行, 覆盖四层
    #   1. ufw        2. firewalld
    #   3. nftables: 优先往"已存在且 hook input 且 policy drop"的表里插规则
    #      (这是最容易漏的一层: 独立 inet 表, iptables -L 完全看不到)
    #   4. iptables: policy drop 时才需要插
    # OPEN_PORTS=0 跳过; OPEN_PORTS=1 额外在无 drop 策略时也建规则(显式白名单)
    local mode=${OPEN_PORTS:-auto}
    if [ "$mode" = "0" ]; then
        info "已跳过防火墙配置 (OPEN_PORTS=0)"
        return 0
    fi

    local r p pr touched=0

    # ---------- 1. ufw ----------
    if need ufw && ufw status 2>/dev/null | grep -qi active; then
        for r in "$@"; do p=${r%/*}; pr=${r#*/}; ufw allow in "${p}/${pr}" >/dev/null 2>&1; done
        ok "ufw 已放行: $*"
        touched=1
    fi

    # ---------- 2. firewalld ----------
    if need firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
        for r in "$@"; do p=${r%/*}; pr=${r#*/}; firewall-cmd --permanent --add-port="${p}/${pr}" >/dev/null 2>&1; done
        firewall-cmd --reload >/dev/null 2>&1
        ok "firewalld 已放行: $*"
        touched=1
    fi

    # ---------- 3. nftables (含独立表) ----------
    local nft_chains=""
    if need nft; then
        # 找出所有 hook input 且 policy drop 的链; 注意 nft -j 里表名在 chain.table
        nft_chains=$(nft -j list ruleset 2>/dev/null | jq -r '
            .nftables[]?
            | select(has("chain"))
            | .chain
            | select((.hook // "") == "input" and (.policy // "accept") == "drop")
            | "\(.family)\u001f\(.table)\u001f\(.name)"' 2>/dev/null | sort -u)
    fi
    if [ -n "$nft_chains" ]; then
        local fam tbl chn added
        while IFS=$'\x1f' read -r fam tbl chn; do
            [ -n "$fam" ] && [ -n "$tbl" ] && [ -n "$chn" ] || continue
            added=0
            for r in "$@"; do
                p=${r%/*}; pr=${r#*/}
                # insert 默认加到链首, 保证先于 drop 命中
                if nft insert rule "$fam" "$tbl" "$chn" "$pr" dport "$p" counter accept 2>/tmp/nft_err; then
                    added=$((added+1))
                else
                    err "nft 放行失败 ($fam $tbl $chn $pr $p): $(tr -d '\n' </tmp/nft_err)"
                fi
            done
            if [ "$added" -gt 0 ]; then
                # 回读验证: 确认规则真的在链里
                if nft list chain "$fam" "$tbl" "$chn" 2>/dev/null | grep -q "dport"; then
                    ok "nftables 已放行 $added 条规则 (表: $fam $tbl, 链: $chn)"
                else
                    err "nft 规则写入后回读失败 (表: $fam $tbl)"
                fi
                touched=1
            fi
        done <<< "$nft_chains"
        warn "nft 规则是内存态, 重启后失效。持久化: nft list ruleset > /etc/nftables.conf && systemctl enable nftables"
    elif [ "$mode" = "1" ] && need nft && nft list chain inet filter input >/dev/null 2>&1; then
        for r in "$@"; do
            p=${r%/*}; pr=${r#*/}
            nft insert rule inet filter input "$pr" dport "$p" counter accept 2>/dev/null
        done
        ok "nftables(inet filter) 已放行: $*"
        touched=1
    fi

    # ---------- 4. iptables (policy drop 才需要) ----------
    if need iptables; then
        local pol
        pol=$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT/ {print $3; exit}')
        if [ "$pol" = "DROP" ]; then
            for r in "$@"; do
                p=${r%/*}; pr=${r#*/}
                iptables -C INPUT -p "$pr" --dport "$p" -j ACCEPT 2>/dev/null || \
                    iptables -I INPUT 1 -p "$pr" --dport "$p" -j ACCEPT 2>/dev/null
            done
            ok "iptables(INPUT policy drop) 已放行: $*"
            warn "iptables 规则重启后可能失效, 持久化: netfilter-persistent save 或 iptables-save > /etc/iptables/rules.v4"
            touched=1
        elif [ "$mode" = "1" ]; then
            for r in "$@"; do
                p=${r%/*}; pr=${r#*/}
                iptables -C INPUT -p "$pr" --dport "$p" -j ACCEPT 2>/dev/null || \
                    iptables -I INPUT 2 -p "$pr" --dport "$p" -j ACCEPT 2>/dev/null
            done
            ok "iptables 已放行: $*"
            touched=1
        fi
    fi

    [ "$touched" -eq 0 ] && info "本机未检测到会拦截入站的防火墙 (ufw/firewalld/nft/iptables 均放行)"
    # 云厂商安全组是另一层, 脚本改不了, 必须提醒
    printf '  %s注意%s: 云厂商安全组(AWS/阿里云/腾讯云/Contabo 等)需在控制台单独放行, 脚本无法修改。\n' "$C_Y" "$C_N"
    return 0
}

# ------------------------------ 端口可达性自检 ------------------------------
# 判断"本机在看/本机可连/外部可连", 把"配置错/防火墙拦/上游拦"三种情况区分开
public_ipv4() {
    local ip
    ip=$(curl -4 -fsm 5 https://api.ipify.org 2>/dev/null || curl -4 -fsm 5 https://ip.sb 2>/dev/null)
    printf '%s' "$ip"
}

port_reachable() { # port_reachable <port> <tcp|udp>
    local p=$1 pr=$2
    # 1) 本机是否在监听
    local listening=0
    if need ss; then
        if [ "$pr" = udp ]; then
            ss -Hlun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && listening=1
        else
            ss -Hltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$" && listening=1
        fi
    fi
    [ "$listening" -eq 1 ] || { printf 'notlistening'; return; }
    [ "$pr" = udp ] && { printf 'ok'; return; }   # UDP 无法用 TCP 探测, 监听即可
    # 2) 本机回环连通
    timeout 3 bash -c "echo > /dev/tcp/127.0.0.1/$p" 2>/dev/null || { printf 'localblocked'; return; }
    # 3) 用本机公网 IP 自连(能测出仅本机可达的 NAT 情况)
    local pub tgt
    pub=$(public_ipv4)
    [ -n "$pub" ] && tgt=$pub || tgt=127.0.0.1
    timeout 4 bash -c "echo > /dev/tcp/$tgt/$p" 2>/dev/null || { printf 'natonly'; return; }
    printf 'ok'
}

check_ports_report() { # check_ports_report <base> <subp>
    local base=$1 subp=$2 r res bad=0 pub pname
    pub=$(public_ipv4)
    line
    title "  端口自检"
    line
    printf '  %-7s %-5s %-10s %-8s %s\n' 端口 协议 用途 本机状态 结果
    for r in \
        "$base/tcp:$((base+0)):reality" \
        "$((base+1))/udp:$((base+1)):hy2" \
        "$((base+2))/udp:$((base+2)):tuic" \
        "$((base+3))/tcp:$((base+3)):anytls" \
        "$((base+4))/tcp:$((base+4)):trojan" \
        "$((base+5))/tcp:$((base+5)):ss2022" \
        "$((base+6))/tcp:$((base+6)):订阅" \
        "$((base+7))/tcp:$((base+7)):vmess/argo"
    do
        local rp=${r%%:*} rest=${r#*:}
        local pn=${rest%%:*} pname=${rest#*:}
        # 只检查已启用协议对应的端口; 未启用的跳过
        local noskip=0
        case "$pname" in
            reality|hy2|tuic|anytls|trojan|ss2022) proto_on "$pname" && noskip=1 ;;
            vmess/argo) proto_on vmess && noskip=1 ;;
            *) noskip=1 ;;
        esac
        [ "$noskip" -eq 0 ] && continue
        res=$(port_reachable "${rp%/*}" "${rp#*/}")
        case "$res" in
            ok)           printf '  %-7s %-5s %-10s %-8s %s\n' "${rp%/*}" "${rp#*/}" "$pname" "监听中" "${C_G}正常${C_N}" ;;
            notlistening) printf '  %-7s %-5s %-10s %-8s %s\n' "${rp%/*}" "${rp#*/}" "$pname" "未监听" "${C_R}异常${C_N}"; bad=1 ;;
            localblocked) printf '  %-7s %-5s %-10s %-8s %s\n' "${rp%/*}" "${rp#*/}" "$pname" "本机拒连" "${C_R}异常${C_N}"; bad=1 ;;
            natonly)      printf '  %-7s %-5s %-10s %-8s %s\n' "${rp%/*}" "${r#*/}" "$pname" "仅内网" "${C_Y}需映射${C_N}"; bad=1 ;;
        esac
    done
    line
    if [ "$bad" -ne 0 ]; then
        warn "存在异常端口。若上面显示'未监听'但服务在跑, 先看 $LOG_DIR/sing-box.log"
    else
        ok "已启用协议的端口在本机侧全部就绪"
    fi

    # 云厂商安全组放行清单(脚本改不到这一层, 直接给出可复制的规则)
    local need_tcp="" need_udp="" t
    for r in \
        "$base/tcp:$((base+0)):reality" \
        "$((base+1))/udp:$((base+1)):hy2" \
        "$((base+2))/udp:$((base+2)):tuic" \
        "$((base+3))/tcp:$((base+3)):anytls" \
        "$((base+4))/tcp:$((base+4)):trojan" \
        "$((base+5))/tcp:$((base+5)):ss2022" \
        "$((base+6))/tcp:$((base+6)):订阅" \
        "$((base+7))/tcp:$((base+7)):vmess/argo"
    do
        # 注意: local 不能在同一行给多个变量赋值(bash 陷阱), 分开写
        local rp2="${r%%:*}"
        local rest2="${r#*:}"
        local pname2="${rest2#*:}"
        local keep=0
        case "$pname2" in
            reality|hy2|tuic|anytls|trojan|ss2022) proto_on "$pname2" && keep=1 ;;
            vmess/argo) proto_on vmess && keep=1 ;;
            *) keep=1 ;;
        esac
        [ "$keep" -eq 1 ] || continue
        case "${rp2#*/}" in
            udp) need_udp="$need_udp ${rp2%/*}" ;;
            *)   need_tcp="$need_tcp ${rp2%/*}" ;;
        esac
    done
    printf '\n  %s云厂商安全组需要放行的端口%s (脚本改不到, 需在控制台手动加):\n' "$C_Y" "$C_N"
    [ -n "$(echo $need_tcp | tr -d ' ')" ] && \
        printf '    TCP  %s\n' "$(echo $need_tcp | tr ' ' ',' | sed 's/,/, /g')"
    [ -n "$(echo $need_udp | tr -d ' ')" ] && \
        printf '    UDP  %s\n' "$(echo $need_udp | tr ' ' ',' | sed 's/,/, /g')"
    printf '    省事做法: 直接放行 TCP %s-%s 与 UDP %s-%s 整段\n' "$base" "$((base+7))" "$base" "$((base+7))"
    printf '    别忘了保留 TCP 22 (SSH), 否则会把自己锁在外面\n'

    printf '\n  %s本机侧正常 ≠ 外部能连%s。从另一台机器验证:\n' "$C_Y" "$C_N"
    printf '    curl -m 5 http://%s:%s/     (订阅端口, 返回 404 正常; 超时=被拦)\n' "${pub:-你的公网IP}" "$subp"
    printf '    nc -vz %s %s\n' "${pub:-你的公网IP}" "$base"
    printf '  若外部超时而本机正常, 拦截在云厂商安全组或上游机房, 需在控制台放行或开工单。\n'
}

# ------------------------------ 内核安装 ------------------------------
resolve_version() {
    if [ "$SB_VERSION" != "latest" ]; then VER=${SB_VERSION#v}; return 0; fi
    VER=$(api_json "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
          | jq -r '.tag_name//empty' 2>/dev/null | sed 's/^v//')
    [ -n "$VER" ] || VER=$(api_json "https://api.github.com/repos/SagerNet/sing-box/tags" \
          | jq -r '.[0].name//empty' 2>/dev/null | sed 's/^v//')
    [ -n "$VER" ] || die "无法获取 sing-box 版本, 请指定 SB_VERSION=1.14.4"
}

install_binary() {
    local name tar want got
    name="sing-box-${VER}-linux-${ARCH}${LIBC}"
    tar="${WORK_DIR}/${name}.tar.gz"
    info "下载 sing-box ${VER} (linux-${ARCH}${LIBC:-/glibc}) ..."
    if ! dl_mirror "SagerNet/sing-box/releases/download/v${VER}/${name}.tar.gz" "$tar"; then
        LIBC=""; name="sing-box-${VER}-linux-${ARCH}"; tar="${WORK_DIR}/${name}.tar.gz"
        info "改用通用包 ${name} ..."
        dl_mirror "SagerNet/sing-box/releases/download/v${VER}/${name}.tar.gz" "$tar" \
            || die "sing-box 下载失败 (网络受限), 可手动放入 ${BIN} 后重试"
    fi
    want=$(api_json "https://api.github.com/repos/SagerNet/sing-box/releases/tags/v${VER}" \
        | jq -r --arg n "${name}.tar.gz" '.assets[]?|select(.name==$n)|(.digest//"")' 2>/dev/null | sed 's/^sha256://')
    if [ "${#want}" -eq 64 ]; then
        got=$(sha256sum "$tar" | awk '{print $1}')
        [ "$got" = "$want" ] && ok "sha256 校验通过" || { rm -f "$tar"; die "sha256 校验失败, 已中止安装"; }
    else
        warn "未取到官方 sha256, 跳过校验"
    fi
    tar -xzf "$tar" -C "$WORK_DIR" || die "解压失败"
    install -m 0755 "${WORK_DIR}/${name}/sing-box" "$BIN" || die "安装内核失败"
    rm -rf "${WORK_DIR}/${name}" "$tar"
    info "内核版本: $("$BIN" version | head -1 | awk '{print $3}')"
}

install_cloudflared() {
    local out="${WORK_DIR}/cloudflared"
    case "$ARCH" in amd64|arm64|386|armv7) ;; *) warn "cloudflared 不支持 $ARCH"; return 1 ;; esac
    [ -x "$out" ] && return 0
    info "下载 cloudflared ..."
    dl_mirror "cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${ARCH}" "$out" \
        || { warn "cloudflared 下载失败"; return 1; }
    chmod +x "$out"
}

# ------------------------------ 密钥/证书 ------------------------------
gen_secret() {
    local l=${1:-24}
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$l"
}

new_uuid() {
    [ -r /proc/sys/kernel/random/uuid ] && { cat /proc/sys/kernel/random/uuid; return; }
    "$BIN" generate uuid 2>/dev/null || openssl rand -hex 16 \
        | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/'
}

make_cert() {
    mkdir -p "$WORK_DIR"
    openssl ecparam -genkey -name prime256v1 -out "${WORK_DIR}/private.key" 2>/dev/null
    openssl req -new -x509 -days 3650 -key "${WORK_DIR}/private.key" \
        -out "${WORK_DIR}/cert.pem" -subj "/CN=${1:-www.bing.com}" 2>/dev/null
    [ -s "${WORK_DIR}/cert.pem" ] || die "自签证书生成失败"
    chmod 600 "${WORK_DIR}/private.key"
    CERT_SHA=$(openssl x509 -noout -fingerprint -sha256 -in "${WORK_DIR}/cert.pem" \
               | cut -d'=' -f2 | tr 'A-Z' 'a-z' | tr -d ':')
}

reality_keypair() {
    local o; o=$("$BIN" generate reality-keypair)
    RK_PRIV=$(printf '%s' "$o" | awk '/PrivateKey/{print $2}')
    RK_PUB=$(printf '%s' "$o" | awk '/PublicKey/{print $2}')
    [ -n "$RK_PRIV" ] && [ -n "$RK_PUB" ] || die "Reality 密钥生成失败"
    RK_SID=$(openssl rand -hex 8)
}

ss_key() {
    local k; k=$(openssl rand -base64 16 | tr -d '\n')
    jq --arg k "$k" '.ss2022.password=$k' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
    printf '%s' "$k"
}

meta_get() { jq -r "$1 // empty" "$META" 2>/dev/null; }
proto_on() { jq -e --arg t "$1" '.enabled|index($t)!=null' "$META" >/dev/null 2>&1; }

# ------------------------------ 服务端配置 ------------------------------
write_config() {
    local tmp="${CONF}.new"
    jq -n \
      --argjson rp "$(meta_get .reality.port)" \
      --argjson hp "$(meta_get .hy2.port)" \
      --argjson tp "$(meta_get .tuic.port)" \
      --argjson ap "$(meta_get .anytls.port)" \
      --argjson sp "$(meta_get .ss2022.port)" \
      --argjson trp "$(meta_get .trojan.port)" \
      --argjson vp "$(meta_get .vmess.port)" \
      --arg uuid "$(meta_get .uuid)" \
      --arg sni "$(meta_get .reality.sni)" \
      --arg rpriv "$(meta_get .reality.private_key)" \
      --arg rsid "$(meta_get .reality.short_id)" \
      --arg hyp "$(meta_get .hy2.password)" \
      --arg tpw "$(meta_get .tuic.password)" \
      --arg apw "$(meta_get .anytls.password)" \
      --arg spw "$(meta_get .ss2022.password)" \
      --arg trpw "$(meta_get .trojan.password)" \
      --arg vpath "$(meta_get .vmess.path)" \
      --arg en "$(jq -r '.enabled|join(",")' "$META" 2>/dev/null)" \
      --arg cert "${WORK_DIR}/cert.pem" \
      --arg key "${WORK_DIR}/private.key" \
      --arg logf "${LOG_DIR}/sing-box.log" \
    '
    def on($n): ($en|split(",")|index($n)) != null;
    {
      log: { level:"warn", output:$logf, timestamp:true },
      inbounds: [
        (if on("reality") then {
            type:"vless", tag:"vless-reality", listen:"::", listen_port:$rp,
            users:[{uuid:$uuid, flow:"xtls-rprx-vision"}],
            tls:{ enabled:true, server_name:$sni,
                  reality:{ enabled:true, handshake:{server:$sni, server_port:443},
                            private_key:$rpriv, short_id:[$rsid] } }
        } else empty end),
        (if on("hy2") then {
            type:"hysteria2", tag:"hysteria2", listen:"::", listen_port:$hp,
            users:[{password:$hyp}],
            masquerade:"https://www.bing.com",
            tls:{ enabled:true, alpn:["h3"], min_version:"1.3", max_version:"1.3",
                  certificate_path:$cert, key_path:$key }
        } else empty end),
        (if on("tuic") then {
            type:"tuic", tag:"tuic", listen:"::", listen_port:$tp,
            users:[{uuid:$uuid, password:$tpw}],
            congestion_control:"bbr", auth_timeout:"3s",
            tls:{ enabled:true, alpn:["h3"], certificate_path:$cert, key_path:$key }
        } else empty end),
        (if on("anytls") then {
            type:"anytls", tag:"anytls", listen:"::", listen_port:$ap,
            users:[{password:$apw}],
            tls:{ enabled:true, certificate_path:$cert, key_path:$key }
        } else empty end),
        (if on("ss2022") then {
            type:"shadowsocks", tag:"ss2022", listen:"::", listen_port:$sp,
            method:"2022-blake3-aes-128-gcm", password:$spw
        } else empty end),
        (if on("trojan") then {
            type:"trojan", tag:"trojan", listen:"::", listen_port:$trp,
            users:[{password:$trpw}],
            tls:{ enabled:true, certificate_path:$cert, key_path:$key }
        } else empty end),
        (if on("vmess") then {
            type:"vmess", tag:"vmess-argo", listen:"::", listen_port:$vp,
            users:[{uuid:$uuid}],
            transport:{ type:"ws", path:$vpath, early_data_header_name:"Sec-WebSocket-Protocol" }
        } else empty end)
      ],
      outbounds:[{ type:"direct", tag:"direct" }],
      route:{ final:"direct" }
    }' >"$tmp" 2>/tmp/sb_jq.log

    if ! jq -e . "$tmp" >/dev/null 2>&1; then
        err "配置生成失败:"; sed 's/^/    /' /tmp/sb_jq.log | tail -5; rm -f "$tmp"; return 1
    fi
    if ! "$BIN" check -c "$tmp" >/tmp/sb_check.log 2>&1; then
        err "sing-box 配置校验失败:"; sed 's/^/    /' /tmp/sb_check.log | tail -10; rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$CONF"; chmod 600 "$CONF"
    return 0
}

# ------------------------------ 服务 ------------------------------
# svc_state <name>   读取进程状态: running/stopped (nohup 模式用 pidfile)
svc_state() {
    local n=$1 pf="/run/${1}.pid"
    [ -f "$pf" ] || { printf 'stopped'; return; }
    local pid; pid=$(cat "$pf" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && printf 'running' || printf 'stopped'
}

svc_cmd_nohup() { # svc_cmd_nohup <name> <start|stop|restart> <cmdline>
    local n=$1 a=$2 pf="/run/${1}.pid" cmd=$3 pat
    case "$n" in
        sing-box) pat="${BIN} run -c ${CONF}" ;;
        sb-sub)   pat="subsrv.py" ;;
        sb-argo)  pat="cloudflared tunnel" ;;
    esac
    case "$a" in
        stop)
            if [ -f "$pf" ]; then
                local p; p=$(cat "$pf" 2>/dev/null)
                [ -n "$p" ] && { kill "$p" 2>/dev/null; sleep 1; kill -9 "$p" 2>/dev/null; }
                rm -f "$pf"
            fi
            # 兜底: 按 /proc 命令行匹配(无需 pkill/procps)
            local d pid cl
            for d in /proc/[0-9]*; do
                pid=${d#/proc/}
                [ "$pid" = "$$" ] && continue
                cl=$( { tr '\0' ' ' <"$d/cmdline"; } 2>/dev/null ) || continue
                case "$cl" in *"$pat"*) kill "$pid" 2>/dev/null ;; esac
            done
            ;;
        start|restart)
            [ "$a" = restart ] && svc_cmd_nohup "$n" stop
            # 已有 pidfile: 必须核对该进程确实是本服务且配置路径一致, 否则视为陈旧残留
            if [ -f "$pf" ]; then
                local oldpid oldcl
                oldpid=$(cat "$pf" 2>/dev/null)
                if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
                    oldcl=$( { tr '\0' ' ' <"/proc/${oldpid}/cmdline"; } 2>/dev/null )
                    case "$oldcl" in
                        *"$pat"*) return 0 ;;                 # 确实在跑, 不重复启动
                        *) kill "$oldpid" 2>/dev/null; sleep 1 ;;  # 陈旧 pidfile, 清掉
                    esac
                fi
                rm -f "$pf"
            fi
            mkdir -p "$LOG_DIR" /run
            setsid nohup sh -c "$cmd" >>"${LOG_DIR}/${n}.log" 2>&1 &
            echo $! >"$pf"
            sleep 1
            ;;
    esac
}

write_services() {
    local subp SUB_EXEC; subp=$(meta_get .sub.port)
    SUB_EXEC=$(sub_exec)
    if [ "$INIT" = systemd ]; then
        cat >/etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=${WORK_DIR}
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=${BIN} run -c ${CONF}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        if [ "${subp:-0}" != "0" ]; then
            cat >/etc/systemd/system/sb-sub.service <<EOF
[Unit]
Description=sing-box subscription server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${SUB_DIR}
ExecStart=/usr/bin/env ${SUB_EXEC}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
        fi
        systemctl daemon-reload >/dev/null 2>&1
    elif [ "$INIT" = openrc ]; then
        cat >/etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
description="sing-box service"
command="${BIN}"
command_args="run -c ${CONF}"
command_background=true
pidfile="/run/sing-box.pid"
output_log="${LOG_DIR}/openrc.log"
error_log="${LOG_DIR}/openrc.log"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box
        if [ "${subp:-0}" != "0" ]; then
            cat >/etc/init.d/sb-sub <<EOF
#!/sbin/openrc-run
description="sing-box subscription server"
command="/usr/bin/env"
command_args="${SUB_EXEC}"
directory="${SUB_DIR}"
command_background=true
pidfile="/run/sb-sub.pid"
depend() { need net; }
EOF
            chmod +x /etc/init.d/sb-sub
        fi
    fi
    # INIT=nohup 时无需服务文件, 由 svc() 直接 setsid 启动
}

svc() {
    local n=$1 a=$2
    if [ "$INIT" = systemd ]; then
        case $a in
            status) systemctl is-active "$n" >/dev/null 2>&1 && printf 'running' || printf 'stopped' ;;
            enable) systemctl enable --now "$n" >/dev/null 2>&1 ;;
            disable) systemctl disable --now "$n" >/dev/null 2>&1 ;;
            *) systemctl "$a" "$n" >/dev/null 2>&1 ;;
        esac
    elif [ "$INIT" = openrc ]; then
        case $a in
            status) rc-service "$n" status 2>/dev/null | grep -q started && printf 'running' || printf 'stopped' ;;
            enable) rc-update add "$n" default >/dev/null 2>&1; rc-service "$n" start >/dev/null 2>&1 ;;
            disable) rc-update del "$n" default >/dev/null 2>&1; rc-service "$n" stop >/dev/null 2>&1 ;;
            restart) rc-service "$n" restart >/dev/null 2>&1 ;;
            *) rc-service "$n" "$a" >/dev/null 2>&1 ;;
        esac
    else
        # nohup 模式 (容器 / 无 init 系统)
        case $n in
            sing-box) local c="exec ${BIN} run -c ${CONF}" ;;
            sb-sub)   local c="exec /usr/bin/env $(sub_exec)" ;;
            sb-argo)  local c="exec /bin/sh -c '$(argo_exec)'" ;;
            *) return 0 ;;
        esac
        case $a in
            status) svc_state "$n" ;;
            enable|start) svc_cmd_nohup "$n" start "$c" ;;
            disable|stop) svc_cmd_nohup "$n" stop ;;
            restart) svc_cmd_nohup "$n" restart "$c" ;;
        esac
    fi
}

reload_service() {
    if ! "$BIN" check -c "$CONF" >/tmp/sb_check.log 2>&1; then
        err "配置校验失败, 未重启:"; sed 's/^/    /' /tmp/sb_check.log | tail -10; return 1
    fi
    case "$INIT" in
        systemd) systemctl restart sing-box >/dev/null 2>&1 ;;
        openrc)  rc-service sing-box restart >/dev/null 2>&1 ;;
        *)       svc sing-box restart ;;
    esac
    local i
    for i in 1 2 3 4 5; do
        sleep 1
        [ "$(svc sing-box status)" = running ] && { ok "sing-box 已重启"; return 0; }
    done
    err "sing-box 启动失败, 最近日志:"
    tail -15 "${LOG_DIR}/sing-box.log" 2>/dev/null | sed 's/^/    /'
    journalctl -u sing-box -n 10 --no-pager 2>/dev/null | sed 's/^/    /'
    return 1
}

# ------------------------------ 客户端订阅 ------------------------------
argo_domain() {
    local d; d=$(meta_get .argo.domain)
    if [ -n "$d" ]; then printf '%s' "$d"; return 0; fi
    [ -f "${LOG_DIR}/argo.log" ] && \
        sed -n 's|.*https://\([a-z0-9][a-z0-9-]*\.trycloudflare\.com\).*|\1|p' "${LOG_DIR}/argo.log" | tail -1
}

sub_dir_of() { printf '%s/%s' "$SUB_DIR" "$(meta_get .sub.token)"; }

sub_exec() { printf 'python3 %s/subsrv.py %s %s 0.0.0.0 %s' "$WORK_DIR" "$(meta_get .sub.token)" "$(meta_get .sub.port)" "$SUB_DIR"; }

sub_urls() {
    local ip p t
    ip=$(meta_get .ip); p=$(meta_get .sub.port); t=$(meta_get .sub.token)
    [ -n "$p" ] && [ "$p" != "0" ] || return 0
    printf 'http://%s:%s/%s/' "$ip" "$p" "$t"
}

build_client_configs() {
    [ -f "$META" ] || return 0
    local ip isp uuid sni rp hp tp ap sp trp vp rsid rpub csha d
    ip=$(meta_get .ip); isp=$(meta_get .isp); uuid=$(meta_get .uuid)
    sni=$(meta_get .reality.sni); rp=$(meta_get .reality.port); rsid=$(meta_get .reality.short_id)
    rpub=$(meta_get .reality.public_key); csha=$(meta_get .cert_sha256)
    hp=$(meta_get .hy2.port); tp=$(meta_get .tuic.port); ap=$(meta_get .anytls.port)
    sp=$(meta_get .ss2022.port); trp=$(meta_get .trojan.port); vp=$(meta_get .vmess.port)
    [ -n "$isp" ] || isp=node
    [ -n "$sni" ] || sni=www.iij.ad.jp
    d=$(sub_dir_of)
    mkdir -p "$d"; chmod 755 "$SUB_DIR" "$d"; : >"${d}/v2ray"
    # 清理遗留的旧订阅目录(重装/重置订阅路径后)
    local oldd
    for oldd in "$SUB_DIR"/*/; do
        [ -d "$oldd" ] || continue
        [ "$(cd "$oldd" && pwd)" = "$(cd "$d" && pwd)" ] || rm -rf "$oldd"
    done

    proto_on reality && printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&headerType=none#%s-reality\n' \
        "$uuid" "$ip" "$rp" "$sni" "$rpub" "$rsid" "$isp" >>"${d}/v2ray"

    proto_on hy2 && printf 'hysteria2://%s@%s:%s/?sni=www.bing.com&alpn=h3&insecure=1&pinSHA256=%s#%s-hy2\n' \
        "$(meta_get .hy2.password)" "$ip" "$hp" "$csha" "$isp" >>"${d}/v2ray"

    proto_on tuic && printf 'tuic://%s:%s@%s:%s?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=www.bing.com&allow_insecure=1#%s-tuic\n' \
        "$uuid" "$(meta_get .tuic.password)" "$ip" "$tp" "$isp" >>"${d}/v2ray"

    proto_on anytls && printf 'anytls://%s@%s:%s/?sni=www.bing.com&insecure=1&fp=chrome#%s-anytls\n' \
        "$(meta_get .anytls.password)" "$ip" "$ap" "$isp" >>"${d}/v2ray"

    proto_on ss2022 && printf 'ss://%s@%s:%s#%s-ss2022\n' \
        "$(printf '2022-blake3-aes-128-gcm:%s' "$(meta_get .ss2022.password)" | base64 -w0 2>/dev/null || printf '2022-blake3-aes-128-gcm:%s' "$(meta_get .ss2022.password)" | base64 | tr -d '\n')" \
        "$ip" "$sp" "$isp" >>"${d}/v2ray"

    proto_on trojan && printf 'trojan://%s@%s:%s?security=tls&sni=www.bing.com&allowInsecure=1&type=tcp#%s-trojan\n' \
        "$(meta_get .trojan.password)" "$ip" "$trp" "$isp" >>"${d}/v2ray"

    local ad=""
    if proto_on vmess; then
        ad=$(argo_domain)
        if [ -n "$ad" ]; then
            printf 'vmess://%s\n' "$(jq -cn --arg ps "${isp}-argo" --arg add "$(meta_get .cfip)" \
                --arg port "$(meta_get .cfport)" --arg id "$uuid" --arg host "$ad" \
                '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"ws",type:"none",
                  host:$host,path:"/vmess-argo?ed=2048",tls:"tls",sni:$host,alpn:"",fp:"chrome",allowInsecure:"false"}' \
                | base64 -w0)" >>"${d}/v2ray"
        fi
    fi

    base64 -w0 "${d}/v2ray" >"${d}/sub" 2>/dev/null || base64 "${d}/v2ray" | tr -d '\n' >"${d}/sub"
    cp "${d}/v2ray" "${d}/plain.txt"

    # ---------- Clash / Mihomo ----------
    {
        cat <<'EOF'
mixed-port: 7890
allow-lan: false
mode: rule
log-level: info
proxies:
EOF
        proto_on reality && cat <<EOF
  - name: "${isp}-reality"
    type: vless
    server: ${ip}
    port: ${rp}
    uuid: ${uuid}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${sni}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${rpub}
      short-id: ${rsid}
EOF
        proto_on hy2 && cat <<EOF
  - name: "${isp}-hy2"
    type: hysteria2
    server: ${ip}
    port: ${hp}
    password: $(meta_get .hy2.password)
    sni: www.bing.com
    skip-cert-verify: true
    alpn:
      - h3
EOF
        proto_on tuic && cat <<EOF
  - name: "${isp}-tuic"
    type: tuic
    server: ${ip}
    port: ${tp}
    uuid: ${uuid}
    password: $(meta_get .tuic.password)
    sni: www.bing.com
    alpn:
      - h3
    skip-cert-verify: true
    congestion-controller: bbr
    udp-relay-mode: native
EOF
        proto_on anytls && cat <<EOF
  - name: "${isp}-anytls"
    type: anytls
    server: ${ip}
    port: ${ap}
    password: $(meta_get .anytls.password)
    sni: www.bing.com
    skip-cert-verify: true
    client-fingerprint: chrome
EOF
        proto_on ss2022 && cat <<EOF
  - name: "${isp}-ss2022"
    type: ss
    server: ${ip}
    port: ${sp}
    cipher: 2022-blake3-aes-128-gcm
    password: "$(meta_get .ss2022.password)"
    udp: true
EOF
        proto_on trojan && cat <<EOF
  - name: "${isp}-trojan"
    type: trojan
    server: ${ip}
    port: ${trp}
    password: $(meta_get .trojan.password)
    sni: www.bing.com
    skip-cert-verify: true
    udp: true
EOF
        if proto_on vmess && [ -n "$ad" ]; then
            cat <<EOF
  - name: "${isp}-argo"
    type: vmess
    server: $(meta_get .cfip)
    port: $(meta_get .cfport)
    uuid: ${uuid}
    alterId: 0
    cipher: auto
    tls: true
    servername: ${ad}
    network: ws
    udp: true
    ws-opts:
      path: "/vmess-argo?ed=2048"
      headers:
        Host: ${ad}
EOF
        fi
        printf 'proxy-groups:\n  - name: Proxy\n    type: select\n    proxies:\n'
        proto_on reality && printf '      - "%s-reality"\n' "$isp"
        proto_on hy2     && printf '      - "%s-hy2"\n' "$isp"
        proto_on tuic    && printf '      - "%s-tuic"\n' "$isp"
        proto_on anytls  && printf '      - "%s-anytls"\n' "$isp"
        proto_on ss2022  && printf '      - "%s-ss2022"\n' "$isp"
        proto_on trojan  && printf '      - "%s-trojan"\n' "$isp"
        [ -n "$ad" ] && proto_on vmess && printf '      - "%s-argo"\n' "$isp"
        printf '      - DIRECT\nrules:\n  - MATCH,Proxy\n'
    } >"${d}/clash.yaml"

    # ---------- sing-box 客户端 ----------
    {
        echo '['
        local first=1 obj
        emit() { [ "$first" -eq 1 ] || printf ',\n'; first=0; printf '%s' "$1"; }
        if proto_on reality; then
            obj=$(jq -cn --arg s "$ip" --argjson p "${rp:-0}" --arg u "$uuid" --arg sni "$sni" --arg pbk "$rpub" --arg sid "$rsid" \
              '{type:"vless",tag:"proxy-reality",server:$s,server_port:$p,uuid:$u,flow:"xtls-rprx-vision",
                tls:{enabled:true,server_name:$sni,utls:{enabled:true,fingerprint:"chrome"},
                     reality:{enabled:true,public_key:$pbk,short_id:$sid}}}')
            emit "$obj"
        fi
        if proto_on hy2; then
            obj=$(jq -cn --arg s "$ip" --argjson p "${hp:-0}" --arg pw "$(meta_get .hy2.password)" \
              '{type:"hysteria2",tag:"proxy-hy2",server:$s,server_port:$p,password:$pw,
                tls:{enabled:true,server_name:"www.bing.com",alpn:["h3"],insecure:true}}')
            emit "$obj"
        fi
        if proto_on tuic; then
            obj=$(jq -cn --arg s "$ip" --argjson p "${tp:-0}" --arg u "$uuid" --arg pw "$(meta_get .tuic.password)" \
              '{type:"tuic",tag:"proxy-tuic",server:$s,server_port:$p,uuid:$u,password:$pw,
                congestion_control:"bbr",udp_relay_mode:"native",
                tls:{enabled:true,server_name:"www.bing.com",alpn:["h3"],insecure:true}}')
            emit "$obj"
        fi
        if proto_on anytls; then
            obj=$(jq -cn --arg s "$ip" --argjson p "${ap:-0}" --arg pw "$(meta_get .anytls.password)" \
              '{type:"anytls",tag:"proxy-anytls",server:$s,server_port:$p,password:$pw,
                tls:{enabled:true,server_name:"www.bing.com",utls:{enabled:true,fingerprint:"chrome"},insecure:true}}')
            emit "$obj"
        fi
        if proto_on ss2022; then
            obj=$(jq -cn --arg s "$ip" --argjson p "${sp:-0}" --arg pw "$(meta_get .ss2022.password)" \
              '{type:"shadowsocks",tag:"proxy-ss2022",server:$s,server_port:$p,method:"2022-blake3-aes-128-gcm",password:$pw}')
            emit "$obj"
        fi
        if proto_on trojan; then
            obj=$(jq -cn --arg s "$ip" --argjson p "${trp:-0}" --arg pw "$(meta_get .trojan.password)" \
              '{type:"trojan",tag:"proxy-trojan",server:$s,server_port:$p,password:$pw,
                tls:{enabled:true,server_name:"www.bing.com",insecure:true}}')
            emit "$obj"
        fi
        if proto_on vmess && [ -n "$ad" ]; then
            obj=$(jq -cn --arg s "$(meta_get .cfip)" --argjson p "$(meta_get .cfport)" --arg u "$uuid" --arg ad "$ad" \
              '{type:"vmess",tag:"proxy-argo",server:$s,server_port:$p,uuid:$u,
                tls:{enabled:true,server_name:$ad,utls:{enabled:true,fingerprint:"chrome"}},
                transport:{type:"ws",path:"/vmess-argo?ed=2048",headers:{Host:$ad}}}')
            emit "$obj"
        fi
        printf '\n]\n'
    } >"${d}/proxies.json"

    jq '{ log:{level:"info"},
          experimental:{ clash_api:{ external_controller:"127.0.0.1:9090" } },
          inbounds:[{type:"mixed",tag:"mixed-in",listen:"127.0.0.1",listen_port:2080}],
          outbounds:(. + [{type:"direct",tag:"direct"},{type:"block",tag:"block"}]),
          route:{ final:(.[0].tag) } }' "${d}/proxies.json" >"${d}/singbox.json" 2>/dev/null || {
        warn "sing-box 客户端配置生成失败(可能无节点)"; rm -f "${d}/singbox.json"; }

    cat >"${d}/index.html" <<EOF
<!doctype html><html><head><meta charset="utf-8"><title>$(meta_get .isp) sing-box</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:15px/1.8 -apple-system,"Segoe UI",Roboto,sans-serif;max-width:760px;margin:28px auto;padding:0 18px;color:#111}
h2{font-size:19px}a{display:block;padding:10px 0;color:#0a58ca;text-decoration:none;border-bottom:1px solid #eee}
pre{background:#f6f8fa;padding:12px;border-radius:8px;overflow:auto;font-size:12px;line-height:1.6}</style>
</head><body>
<h2>$(meta_get .isp) &middot; $(meta_get .ip)</h2>
<a href="sub">v2rayN / NekoBox / Shadowrocket / Loon (base64)</a>
<a href="clash.yaml">Clash.Meta / Mihomo (yaml)</a>
<a href="singbox.json">sing-box 客户端 (json)</a>
<a href="plain.txt">明文节点列表</a>
<h2 style="margin-top:28px">节点</h2><pre>$(sed 's/&/\&amp;/g;s/</\&lt;/g' "${d}/v2ray")</pre>
</body></html>
EOF
    chmod -R a+rX "$SUB_DIR" 2>/dev/null
}

# ------------------------------ 信息展示 ------------------------------
show_info() {
    [ -f "$META" ] || { err "尚未安装, 请先安装 (sb -i)"; return 1; }
    local d; d=$(sub_dir_of)
    build_client_configs >/dev/null 2>&1
    line
    title "  sing-box  $(meta_get .version)   状态: $(svc sing-box status)"
    line
    printf '  IP   : %s  (%s)\n' "$(meta_get .ip)" "$(meta_get .isp)"
    printf '  配置 : %s\n' "$CONF"
    printf '  订阅 : %s\n' "$(sub_urls)"
    line
    sed 's/^/  /' "${d}/v2ray" 2>/dev/null
    line
    if [ -n "$(sub_urls)" ] && need qrencode; then
        qrencode -t ANSIUTF8 "$(sub_urls)sub" 2>/dev/null
    fi
    warn "Hy2/TUIC/AnyTLS/Trojan 使用自签证书, 客户端需开启 '跳过证书验证'"
}

# ------------------------------ 端口/凭证 ------------------------------
set_ports() {
    local b; b=$(ask "起始端口 (将连续占用 8 个)" "$(meta_get .reality.port)")
    [[ "$b" =~ ^[0-9]+$ ]] || { err "端口必须为数字"; return 1; }
    (( b < 1024 || b + 7 > 65535 )) && { err "端口范围不合法"; return 1; }
    jq --argjson b "$b" '
      .reality.port=$b | .hy2.port=($b+1) | .tuic.port=($b+2) | .anytls.port=($b+3)
      | .trojan.port=($b+4) | .ss2022.port=($b+5) | .sub.port=($b+6) | .vmess.port=($b+7)' \
      "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
    write_config || return 1
    write_services
    reload_service
    [ "$(meta_get .sub.port)" != "0" ] && svc sb-sub restart
    build_client_configs
    show_info
}

regen_credentials() {
    info "重新生成 UUID / 各协议密码 / Reality 密钥 ..."
    reality_keypair
    tput civis 2>/dev/null
    jq --arg u "$(new_uuid)" --arg hy "$(gen_secret 24)" --arg tp "$(gen_secret 24)" \
       --arg ap "$(gen_secret 24)" --arg tr "$(gen_secret 24)" \
       --arg rk "$RK_PRIV" --arg rp "$RK_PUB" --arg rs "$RK_SID" \
       '.uuid=$u | .hy2.password=$hy | .tuic.password=$tp | .anytls.password=$ap
        | .trojan.password=$tr | .reality.private_key=$rk | .reality.public_key=$rp | .reality.short_id=$rs' \
       "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
    tput cnorm 2>/dev/null
    proto_on ss2022 && ss_key >/dev/null
    write_config && reload_service && build_client_configs
    warn "旧节点已全部失效, 请在客户端重新导入订阅"
    show_info
}

# ------------------------------ 协议增删 ------------------------------
meta_port() { meta_get ".$1.port"; }

add_proto() {
    local t=$1 b p
    proto_on "$t" && { warn "$t 已启用"; return 0; }
    b=$(meta_get .reality.port); b=${b:-30000}
    case "$t" in
        reality)
            reality_keypair; p=$(pick_one "$b" tcp)
            jq --argjson p "$p" --arg pk "$RK_PRIV" --arg pub "$RK_PUB" --arg sid "$RK_SID" --arg sni "${SNI:-www.iij.ad.jp}" \
               '.reality={port:$p,sni:$sni,private_key:$pk,public_key:$pub,short_id:$sid}' \
               "$META" >"${META}.tmp" && mv "${META}.tmp" "$META" ;;
        hy2)
            p=$(pick_one $((b+1)) udp)
            jq --argjson p "$p" --arg pw "$(gen_secret 24)" '.hy2={port:$p,password:$pw}' \
               "$META" >"${META}.tmp" && mv "${META}.tmp" "$META" ;;
        tuic)
            p=$(pick_one $((b+2)) udp)
            jq --argjson p "$p" --arg pw "$(gen_secret 24)" '.tuic={port:$p,password:$pw}' \
               "$META" >"${META}.tmp" && mv "${META}.tmp" "$META" ;;
        anytls)
            p=$(pick_one $((b+3)) tcp)
            jq --argjson p "$p" --arg pw "$(gen_secret 24)" '.anytls={port:$p,password:$pw}' \
               "$META" >"${META}.tmp" && mv "${META}.tmp" "$META" ;;
        trojan)
            p=$(pick_one $((b+4)) tcp)
            jq --argjson p "$p" --arg pw "$(gen_secret 24)" '.trojan={port:$p,password:$pw}' \
               "$META" >"${META}.tmp" && mv "${META}.tmp" "$META" ;;
        ss2022)
            p=$(pick_one $((b+5)) tcp)
            jq --argjson p "$p" '.ss2022={port:$p,password:""}' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
            ss_key >/dev/null ;;
        vmess)
            [ -z "${ARCH:-}" ] && arch_detect
            SB_ALLOW_PORT=$(meta_get .vmess.port)
            p=$(pick_one $((b+7)) tcp)
            SB_ALLOW_PORT="" 
            jq --argjson p "$p" '.vmess={port:$p,path:"/vmess-argo"}' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META" ;;
        *) err "未知协议: $t"; return 1 ;;
    esac
    jq --arg t "$t" '.enabled += [$t]|.enabled|=unique' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"

    if ! write_config; then
        jq --arg t "$t" '.enabled -= [$t]' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
        write_config >/dev/null 2>&1
        err "$t 启用失败, 已回滚"; return 1
    fi
    [ "$t" = vmess ] && enable_argo
    reload_service && build_client_configs && ok "$t 已启用 (端口 $p)"
}

del_proto() {
    local t=$1 n
    proto_on "$t" || { warn "$t 未启用"; return 0; }
    n=$(jq -r '.enabled|length' "$META")
    [ "$n" -le 1 ] && { err "至少需保留一个协议"; return 1; }
    jq --arg t "$t" '.enabled -= [$t]' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
    write_config && reload_service && build_client_configs && ok "$t 已移除"
}

# ------------------------------ Argo ------------------------------
argo_exec() {
    local port domain auth e
    port=$(meta_get .vmess.port); port=${port:-30007}
    domain=$(meta_get .argo.domain); auth=$(meta_get .argo.auth)
    if [ -n "$domain" ] && [ -n "$auth" ]; then
        case "$auth" in
            \{*) e="${WORK_DIR}/cloudflared tunnel --config /dev/null --no-autoupdate run --credentials-file ${WORK_DIR}/argo.json --url http://127.0.0.1:${port}" ;;
            *)   e="${WORK_DIR}/cloudflared tunnel --no-autoupdate run --token ${auth}" ;;
        esac
    else
        e="${WORK_DIR}/cloudflared tunnel --no-autoupdate --url http://127.0.0.1:${port} --edge-ip-version auto --protocol http2"
    fi
    printf '%s' "$e"
}

write_argo_service() {
    local port=$1 domain=$2 auth=$3 exec
    mkdir -p "$LOG_DIR"
    if [ -n "$domain" ] && [ -n "$auth" ]; then
        case "$auth" in
            \{*) printf '%s' "$auth" >"${WORK_DIR}/argo.json"; chmod 600 "${WORK_DIR}/argo.json" ;;
        esac
    fi
    exec=$(argo_exec)
    if [ "$INIT" = systemd ]; then
        cat >/etc/systemd/system/sb-argo.service <<EOF
[Unit]
Description=Cloudflare Tunnel for sing-box
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/bin/sh -c "${exec} >> ${LOG_DIR}/argo.log 2>&1"
Restart=on-failure
RestartSec=8s

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload >/dev/null 2>&1
        systemctl enable sb-argo >/dev/null 2>&1
        systemctl restart sb-argo >/dev/null 2>&1
    elif [ "$INIT" = openrc ]; then
        cat >/etc/init.d/sb-argo <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel for sing-box"
command="/bin/sh"
command_args="-c '${exec} >> ${LOG_DIR}/argo.log 2>&1'"
command_background=true
pidfile="/run/sb-argo.pid"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sb-argo
        rc-update add sb-argo default >/dev/null 2>&1
        rc-service sb-argo restart >/dev/null 2>&1
    else
        svc sb-argo restart
    fi
}

enable_argo() {
    install_cloudflared || return 1
    local port domain auth i d
    port=$(meta_get .vmess.port); port=${port:-30007}
    if [ "${ENABLE_ARGO:-0}" = "1" ] || [ -n "${ARGO_DOMAIN:-}" ] || [ -n "${ARGO_AUTH:-}" ]; then
        # 无人值守模式: 完全使用环境变量, 不再询问
        domain=${ARGO_DOMAIN:-}
        auth=${ARGO_AUTH:-}
    else
        domain=$(ask "Argo 固定隧道域名 (留空 = 临时隧道)" "$(meta_get .argo.domain)")
        auth=""
    fi
    if [ -n "$domain" ] && [ -z "$auth" ]; then
        auth=$(ask "Argo Tunnel Token 或 credentials JSON" "")
        [ -n "$auth" ] || { err "固定隧道必须提供 Token"; return 1; }
    fi
    jq --arg d "$domain" --arg a "$auth" '.argo={domain:$d,auth:$a}' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
    write_argo_service "$port" "$domain" "$auth"
    if [ -z "$domain" ]; then
        for i in $(seq 1 10); do
            sleep 3
            d=$(argo_domain)
            [ -n "$d" ] && { jq --arg d "$d" '.argo.domain=$d' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
                             ok "临时隧道域名: $d"; return 0; }
        done
        warn "未取得临时隧道域名(网络受限?), 稍后在 sb -> Argo 隧道 -> 重启隧道 重试"
    else
        ok "Argo 固定隧道已配置: $domain"
    fi
}

# ------------------------------ 安装/卸载 ------------------------------
install_shortcut() {
    local self="${BASH_SOURCE[0]}" shim basedir
    mkdir -p "$WORK_DIR"
    if [ -f "$self" ] && [ "$(stat -c%s "$self" 2>/dev/null || echo 0)" -gt 2000 ]; then
        cp -f "$self" "${WORK_DIR}/sb.sh" 2>/dev/null
        basedir=$(cd "$(dirname "$self")" && pwd)
        # 同目录下的订阅服务脚本一并安装
        if [ -f "${basedir}/subsrv.py" ]; then
            cp -f "${basedir}/subsrv.py" "${WORK_DIR}/subsrv.py" 2>/dev/null
        fi
    fi
    # 内嵌回退: 脚本本体未带 subsrv.py 时从仓库下载
    if [ ! -s "${WORK_DIR}/subsrv.py" ]; then
        dl "$(printf '%s' "$SB_RAW_URL" | sed 's#/sb\.sh$#/subsrv.py#')" "${WORK_DIR}/subsrv.py" 2>/dev/null || true
    fi
    if [ ! -s "${WORK_DIR}/subsrv.py" ]; then
        warn "订阅服务脚本缺失, 订阅功能不可用"
    fi
    if [ ! -s "${WORK_DIR}/sb.sh" ]; then
        dl "$SB_RAW_URL" "${WORK_DIR}/sb.sh" || true
    fi
    if [ -s "${WORK_DIR}/sb.sh" ]; then
        chmod +x "${WORK_DIR}/sb.sh"
        shim=/usr/local/bin/sb
        ln -sf "${WORK_DIR}/sb.sh" "$shim" 2>/dev/null || { shim=/usr/bin/sb; ln -sf "${WORK_DIR}/sb.sh" "$shim" 2>/dev/null; }
        ok "管理命令: sb"
    else
        cat >/usr/local/bin/sb <<EOF
#!/bin/sh
tmp=\$(mktemp)
curl -fsSL -o "\$tmp" "${SB_RAW_URL}" || { echo "下载脚本失败"; exit 1; }
bash "\$tmp" "\$@"; rm -f "\$tmp"
EOF
        chmod +x /usr/local/bin/sb
        warn "脚本未缓存到本地, sb 命令每次会重新下载"
    fi
}

do_install() {
    clear
    title "========== sing-box 一键安装 =========="
    mkdir -p "$WORK_DIR" "$SUB_DIR" "$LOG_DIR"; chmod 700 "$WORK_DIR"
    detect_os; arch_detect
    info "系统: ${OS_ID}  初始化: ${INIT}  架构: ${ARCH}${LIBC}"

    # 重装前先停掉旧实例, 否则旧进程继续占端口导致端口探测误判
    local KEEP_ENABLED="" OLD_BASE="" OLD_SUB="" KEEP_TOKEN=""
    if [ -f "$META" ]; then
        warn "检测到已安装, 将覆盖配置(原有节点信息会更新)"
        KEEP_ENABLED=$(jq -r '(.enabled // []) | join(",")' "$META" 2>/dev/null)
        OLD_BASE=$(jq -r '.reality.port // empty' "$META" 2>/dev/null)
        OLD_SUB=$(jq -r '.sub.port // empty' "$META" 2>/dev/null)
        KEEP_TOKEN=$(jq -r '.sub.token // empty' "$META" 2>/dev/null)
        SB_RESERVING=0
        svc sing-box stop >/dev/null 2>&1
        svc sb-sub stop >/dev/null 2>&1
        sleep 1
    fi

    pkg_install curl jq openssl tar gzip
    need ss || pkg_install iproute2
    need sha256sum || pkg_install coreutils
    need python3 || pkg_install python3
    need qrencode || pkg_install qrencode
    for c in curl jq openssl tar; do need "$c" || die "依赖缺失: $c"; done

    resolve_version
    install_binary
    make_cert www.bing.com
    reality_keypair

    local base
    if [[ "${PORT:-}" =~ ^[0-9]+$ ]]; then
        base=$PORT                                   # 显式指定, 优先
    elif [[ "$OLD_BASE" =~ ^[0-9]+$ ]]; then
        base=$OLD_BASE                               # 重装: 沿用原端口, 客户端订阅不失效
        info "沿用原端口块: ${base}-$((base+7))"
    else
        base=$((RANDOM + 10000))
    fi
    base=$(pick_block "$base")
    local subp=0
    if [ "${DISABLE_SUB:-0}" != "1" ] && need python3; then
        if [[ "${SUB_PORT:-}" =~ ^[0-9]+$ ]]; then subp=$SUB_PORT
        elif [[ "$OLD_SUB" =~ ^[0-9]+$ ]] && [ "$OLD_SUB" != "0" ] && [[ "$base" = "$OLD_BASE" ]]; then subp=$OLD_SUB
        else subp=$((base+6)); fi
    fi

    local ip isp uuid
    ip=$(get_public_ip); isp=$(get_isp); uuid=${UUID:-$(new_uuid)}
    ok "公网 IP: $ip  ($isp)"

    jq -n \
      --arg ver "$VER" --arg ip "$ip" --arg isp "$isp" --arg uuid "$uuid" \
      --argjson b "$base" --argjson subp "$subp" \
      --arg rk "$RK_PRIV" --arg rpub "$RK_PUB" --arg rsid "$RK_SID" \
      --arg hy "$(gen_secret 24)" --arg tp "$(gen_secret 24)" \
      --arg ap "$(gen_secret 24)" --arg tr "$(gen_secret 24)" \
      --arg sni "${SNI:-www.iij.ad.jp}" --arg csha "$CERT_SHA" \
      --arg cfip "${CFIP:-cdns.doon.eu.org}" --arg cfport "${CFPORT:-443}" \
      --arg tok "${KEEP_TOKEN:-$(gen_secret 20)}" --arg ts "$(date '+%F %T')" \
      --arg keep "${KEEP_ENABLED:-reality,hy2,tuic,anytls}" \
      '{version:$ver, installed_at:$ts, ip:$ip, isp:$isp, uuid:$uuid, cert_sha256:$csha,
        cfip:$cfip, cfport:$cfport,
        reality:{port:$b, sni:$sni, private_key:$rk, public_key:$rpub, short_id:$rsid},
        hy2:{port:($b+1), password:$hy},
        tuic:{port:($b+2), password:$tp},
        anytls:{port:($b+3), password:$ap},
        trojan:{port:($b+4), password:$tr},
        ss2022:{port:($b+5), password:""},
        sub:{port:$subp, token:$tok},
        vmess:{port:($b+7), path:"/vmess-argo"},
        argo:{domain:"", auth:""},
        enabled:($keep|split(",")|map(select(.!="")))}' >"$META"
    chmod 600 "$META"

    write_config || die "服务端配置生成失败"
    [ "$INIT" = nohup ] && warn "无 systemd/openrc, 使用 nohup 方式托管进程(重启服务器后需 sb -r 手动拉起)"
    write_services
    svc sing-box enable
    sleep 1
    if [ "$(svc sing-box status)" != running ]; then
        err "sing-box 启动失败:"; tail -20 "${LOG_DIR}/sing-box.log" 2>/dev/null | sed 's/^/    /'
        journalctl -u sing-box -n 15 --no-pager 2>/dev/null | sed 's/^/    /'
        die "请根据日志排查"
    fi
    ok "sing-box 已启动"

    open_firewall "$base/tcp" "$((base+1))/udp" "$((base+2))/udp" "$((base+3))/tcp" \
                  "$((base+4))/tcp" "$((base+5))/tcp" "$((base+6))/tcp" "$((base+7))/tcp"

    # 必须先落地 sb.sh / subsrv.py, 否则订阅服务(依赖 subsrv.py)起不来
    install_shortcut

    if [ "$subp" != "0" ]; then
        svc sb-sub enable
        sleep 1
        if [ "$(svc sb-sub status)" = running ]; then
            ok "订阅服务: $(sub_urls)"
        else
            warn "订阅服务未启动, 日志:"
            tail -5 "${LOG_DIR}/sb-sub.log" 2>/dev/null | sed 's/^/    /'
        fi
    fi

    if [ "${ENABLE_ARGO:-0}" = "1" ]; then
        add_proto vmess || warn "VMess-Argo 安装失败, 可稍后在菜单中重试"
    fi

    build_client_configs
    echo
    show_info
    echo
    check_ports_report "$base" "$subp"
    echo
    ok "安装完成, 输入 sb 管理"
}

do_uninstall() {
    local c s
    c=$(ask "确认卸载 sing-box? (y/N)" "N")
    [[ "$c" =~ ^[Yy]$ ]] || { info "已取消"; return 0; }
    for s in sing-box sb-sub sb-argo; do svc "$s" disable >/dev/null 2>&1; done
    if [ "$INIT" = systemd ]; then
        rm -f /etc/systemd/system/sing-box.service /etc/systemd/system/sb-sub.service /etc/systemd/system/sb-argo.service
        systemctl daemon-reload >/dev/null 2>&1
    else
        rm -f /etc/init.d/sing-box /etc/init.d/sb-sub /etc/init.d/sb-argo
        for s in sing-box sb-sub sb-argo; do rc-update del "$s" default >/dev/null 2>&1; done
    fi
    rm -f /usr/local/bin/sb /usr/bin/sb
    [ -d "$WORK_DIR" ] && mv "$WORK_DIR" "${WORK_DIR}.bak.$(date +%s)"
    ok "已卸载 (配置备份于 ${WORK_DIR}.bak.*)"
}

update_core() {
    local old; old=$("$BIN" version 2>/dev/null | head -1 | awk '{print $3}')
    SB_VERSION=latest; detect_os; arch_detect; resolve_version
    install_binary || return 1
    jq --arg v "$VER" '.version=$v' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
    reload_service && build_client_configs
    ok "内核更新: ${old:-?} -> ${VER}"
}

show_log() {
    line; title " sing-box 日志 (最近 40 行)"; line
    if [ -s "${LOG_DIR}/sing-box.log" ]; then tail -40 "${LOG_DIR}/sing-box.log"
    else journalctl -u sing-box -n 40 --no-pager 2>/dev/null || tail -40 "${LOG_DIR}/openrc.log" 2>/dev/null; fi
    if [ -s "${LOG_DIR}/argo.log" ]; then line; title " argo 日志"; line; tail -15 "${LOG_DIR}/argo.log"; fi
}

# ------------------------------ 菜单 ------------------------------
menu_protocols() {
    local c t
    while true; do
        clear; title "========== 协议管理 =========="
        for t in reality hy2 tuic anytls trojan ss2022 vmess; do
            printf '  %-8s %s\n' "$t" "$(proto_on "$t" && printf '%s已启用%s' "$C_G" "$C_N" || printf '未启用')"
        done
        line
        cat <<'EOM'
  1) 添加 VLESS-Reality        2) 添加 Hysteria2
  3) 添加 TUIC v5              4) 添加 AnyTLS
  5) 添加 Shadowsocks-2022     6) 添加 Trojan
  7) 添加 VMess-WS-TLS(Argo)   8) 删除协议
  0) 返回
EOM
        line
        c=$(ask "选择" "")
        case "$c" in
            1) add_proto reality ;; 2) add_proto hy2 ;; 3) add_proto tuic ;;
            4) add_proto anytls ;;  5) add_proto ss2022 ;; 6) add_proto trojan ;;
            7) add_proto vmess ;;
            8) t=$(ask "协议名 (reality/hy2/tuic/anytls/trojan/ss2022/vmess)" "")
               [ -n "$t" ] && del_proto "$t" ;;
            0) return ;;
        esac
        ask "回车继续" "" >/dev/null
    done
}

menu_sub() {
    local c p
    clear; title "========== 订阅服务 =========="
    printf '  状态: %s\n  地址: %s\n' "$(svc sb-sub status)" "$(sub_urls)"
    line
    cat <<'EOM'
  1) 重启订阅服务      2) 修改订阅端口
  3) 重置订阅路径      4) 停止/启动订阅服务
  0) 返回
EOM
    c=$(ask "选择" "")
    case "$c" in
        1) svc sb-sub restart; ok "已重启" ;;
        2) p=$(ask "新端口" "$(meta_get .sub.port)")
           if [[ "$p" =~ ^[0-9]+$ ]]; then
               jq --argjson p "$p" '.sub.port=$p' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
               write_services; svc sb-sub restart; ok "订阅端口: $p"
           fi ;;
        3) jq --arg t "$(gen_secret 20)" '.sub.token=$t' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
           find "$SUB_DIR" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null
           svc sb-sub restart; build_client_configs; ok "新订阅地址: $(sub_urls)" ;;
        4) if [ "$(svc sb-sub status)" = running ]; then svc sb-sub stop; ok "已停止"
           else svc sb-sub enable; ok "已启动"; fi ;;
        0) return ;;
    esac
    build_client_configs >/dev/null 2>&1
    ask "回车继续" "" >/dev/null
}

menu_argo() {
    local c
    clear; title "========== Argo 隧道 =========="
    printf '  状态: %s\n  域名: %s\n' "$(svc sb-argo status)" "$(argo_domain)"
    line
    printf '  1) 配置/更新隧道   2) 重启隧道   3) 移除 Argo 节点   0) 返回\n'
    c=$(ask "选择" "")
    case "$c" in
        1) enable_argo; build_client_configs ;;
        2) if [ "$INIT" = systemd ]; then systemctl restart sb-argo >/dev/null 2>&1; else rc-service sb-argo restart >/dev/null 2>&1; fi
           ok "已重启" ;;
        3) del_proto vmess
           if [ "$INIT" = systemd ]; then systemctl disable --now sb-argo >/dev/null 2>&1; else rc-service sb-argo stop >/dev/null 2>&1; fi ;;
        0) return ;;
    esac
    ask "回车继续" "" >/dev/null
}

menu() {
    local c a
    while true; do
        clear
        title "=============================================="
        title "   sing-box 管理   内核 $(meta_get .version)"
        title "=============================================="
        printf '  服务: %s   Argo: %s   订阅: %s\n' \
            "$(svc sing-box status)" "$(svc sb-argo status)" "$(svc sb-sub status)"
        line
        cat <<'EOM'
   1) 查看节点 / 订阅 / 二维码
   2) 服务管理 (start stop restart)
   3) 修改端口
   4) 重新生成凭证
   5) 协议管理
   6) Argo 隧道管理
   7) 订阅服务管理
   8) 更新 sing-box 内核
   9) 重新生成 TLS 证书
  10) 查看日志
  11) 端口自检 (排查连不上)
  12) 卸载 sing-box
   0) 退出
EOM
        line
        c=$(ask "请选择" "")
        case "$c" in
            1) show_info ;;
            2) a=$(ask "start/stop/restart/status" "status")
               case "$a" in
                   start|stop|restart) svc sing-box "$a"; ok "已执行 $a" ;;
                   *) ok "状态: $(svc sing-box status)" ;;
               esac ;;
            3) set_ports ;;
            4) regen_credentials ;;
            5) menu_protocols; continue ;;
            6) menu_argo; continue ;;
            7) menu_sub; continue ;;
            8) update_core ;;
            9) make_cert www.bing.com
               jq --arg s "$CERT_SHA" '.cert_sha256=$s' "$META" >"${META}.tmp" && mv "${META}.tmp" "$META"
               reload_service && build_client_configs && ok "证书已更新" ;;
            10) show_log ;;
            11) check_ports_report "$(meta_get .reality.port)" "$(meta_get .sub.port)" ;;
            12) do_uninstall; return ;;
            0) exit 0 ;;
            *) continue ;;
        esac
        ask "回车继续" "" >/dev/null
    done
}

usage() {
    cat <<EOF
sing-box 一键脚本

  sb                 交互菜单 (未安装则直接安装)
  sb -i              无交互安装
  sb -c              查看节点与订阅
  sb -p              端口自检 (装完连不上时先跑这个)
  sb -r              重启服务
  sb -v              内核版本
  sb -u              卸载
  sb -h              帮助

环境变量:
  PORT=起始端口        SNI=Reality伪装域名      UUID=指定UUID
  ENABLE_ARGO=1        ARGO_DOMAIN=xx           ARGO_AUTH=token|json
  SUB_PORT=端口        DISABLE_SUB=1
  OPEN_PORTS=auto|1|0 防火墙放行: auto=有ufw/firewalld才动(默认) 1=强制 0=跳过
  CFIP / CFPORT        SB_VERSION=固定内核版本

示例:
  PORT=22000 bash <(curl -Ls ${SB_RAW_URL})
  PORT=22000 OPEN_PORTS=1 bash <(curl -Ls ${SB_RAW_URL})   # 无 ufw/firewalld 时也直插 iptables
  ENABLE_ARGO=1 PORT=22000 bash <(curl -Ls ${SB_RAW_URL})
EOF
}

main() {
    case "${1:-}" in
        -i|--install)   require_root; do_install ;;
        -c|--check)     show_info ;;
        -p|--ports)     detect_os; check_ports_report "$(meta_get .reality.port)" "$(meta_get .sub.port)" ;;
        -r|--restart)   require_root; reload_service ;;
        -v|--version)   [ -x "$BIN" ] && "$BIN" version || err "未安装" ;;
        -u|--uninstall) require_root; detect_os; do_uninstall ;;
        -h|--help)      usage ;;
        '')
            if [ -f "$META" ]; then require_root; detect_os; arch_detect; menu
            else require_root; do_install; fi ;;
        *) usage ;;
    esac
}

main "$@"
