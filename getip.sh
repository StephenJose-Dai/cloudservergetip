#!/bin/bash
# getip.sh — 全平台多网卡 IP 自动配置脚本
# 支持: Ubuntu 16+, Debian 9+, CentOS/RHEL 7/8/9, Fedora, Rocky, AlmaLinux, openSUSE 等
# 策略: 检测发行版 → 选择网络栈 → DHCP 激活 → 抓取 IP/GW → 写入持久配置

set -euo pipefail

# ──────────────────────────────────────────────
# 0. 权限检查
# ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] 请使用 root 或 sudo 运行此脚本" >&2
    exit 1
fi

# ──────────────────────────────────────────────
# 1. 检测发行版 + 网络管理器
# ──────────────────────────────────────────────
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        DISTRO_ID="${ID,,}"          # 转小写: ubuntu / debian / centos / fedora ...
        DISTRO_VER="${VERSION_ID:-0}"
        DISTRO_LIKE="${ID_LIKE:-}"
    elif [ -f /etc/redhat-release ]; then
        DISTRO_ID="rhel"
        DISTRO_VER=$(grep -oP '\d+' /etc/redhat-release | head -1)
        DISTRO_LIKE="rhel"
    else
        DISTRO_ID="unknown"
        DISTRO_VER="0"
        DISTRO_LIKE=""
    fi
}

# 判断主网络栈类型
detect_network_stack() {
    # netplan: Ubuntu 17.10+ 默认；也可能出现在其他发行版
    if command -v netplan &>/dev/null && [ -d /etc/netplan ]; then
        NETWORK_STACK="netplan"
        return
    fi
    # NetworkManager: RHEL/CentOS/Fedora/Rocky/Alma 及部分桌面系统
    if command -v nmcli &>/dev/null && systemctl is-active NetworkManager &>/dev/null 2>&1; then
        NETWORK_STACK="networkmanager"
        return
    fi
    # systemd-networkd: 部分最小化 Debian/Ubuntu 或容器环境
    if systemctl is-active systemd-networkd &>/dev/null 2>&1; then
        NETWORK_STACK="systemd-networkd"
        return
    fi
    # ifupdown: Debian 传统方式
    if command -v ifup &>/dev/null && [ -f /etc/network/interfaces ]; then
        NETWORK_STACK="ifupdown"
        return
    fi
    # 兜底: 仅用 ip 命令操作，不写持久化配置
    NETWORK_STACK="iproute2-only"
}

# ──────────────────────────────────────────────
# 2. 获取所有物理网卡（排除 lo、虚拟、docker 等）
# ──────────────────────────────────────────────
get_physical_ifaces() {
    local ifaces=()
    for dev in /sys/class/net/*; do
        local ifname
        ifname=$(basename "$dev")
        [ "$ifname" = "lo" ] && continue
        # 排除虚拟设备: docker、virbr、veth、tun、tap、bond、bridge 等
        [[ "$ifname" =~ ^(docker|virbr|veth|tun|tap|bond|br-|dummy|ovs-) ]] && continue
        # 判断是否为物理网卡（有实体 driver 链接）
        if [ -e "$dev/device" ] || [ -L "$dev/device" ]; then
            ifaces+=("$ifname")
        fi
    done
    # 按自然顺序排序
    printf '%s\n' "${ifaces[@]}" | sort -V
}

# ──────────────────────────────────────────────
# 3. DHCP 激活（跨平台通用）
# ──────────────────────────────────────────────
activate_dhcp_all() {
    local ifaces=("$@")
    echo "[INFO] 激活 ${#ifaces[@]} 块网卡的 DHCP..."
    for IF in "${ifaces[@]}"; do
        ip link set "$IF" up 2>/dev/null || true
        if command -v dhclient &>/dev/null; then
            dhclient -r "$IF" &>/dev/null || true
            dhclient "$IF" &>/dev/null &
        elif command -v dhcpcd &>/dev/null; then
            dhcpcd -n "$IF" &>/dev/null &
        else
            # 最后兜底: udhcpc (busybox 环境)
            udhcpc -i "$IF" -n -q &>/dev/null &
        fi
    done
    echo "[INFO] 等待 DHCP 协商完成（最长 60 秒）..."
    # 等待所有后台 DHCP 进程完成
    wait 2>/dev/null || true
    # 动态等待：轮询直到所有网卡都有 IP，或超时
    local deadline=$((SECONDS + 60))
    while [ $SECONDS -lt $deadline ]; do
        local pending=0
        for IF in "${ifaces[@]}"; do
            ip -4 addr show "$IF" 2>/dev/null | grep -q "inet " || pending=$((pending + 1))
        done
        [ "$pending" -eq 0 ] && break
        echo "[INFO] 还有 $pending 块网卡未获取到 IP，继续等待..."
        sleep 3
    done
}

# ──────────────────────────────────────────────
# 4. 抓取每块网卡的 IP + 网关（纯 iproute2，全平台通用）
# ──────────────────────────────────────────────
get_ip_gw() {
    local IF="$1"
    IP=$(ip -4 addr show "$IF" 2>/dev/null \
         | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || true)
    GW=$(ip route show dev "$IF" 2>/dev/null \
         | awk '/^default/{print $3; exit}' || true)
    PREFIX=$(ip -4 addr show "$IF" 2>/dev/null \
             | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' | grep -oP '\d+$' | head -n1 || true)
    PREFIX="${PREFIX:-24}"
}

# ──────────────────────────────────────────────
# 5. 写入配置 — netplan
# ──────────────────────────────────────────────
write_netplan() {
    local ifaces=("$@")
    local CONF_FILE="/etc/netplan/50-cloud-init.yaml"
    local T_ID=100
    local METRIC=100

    echo "[INFO] 使用 netplan 写入配置: $CONF_FILE"
    cat > "$CONF_FILE" << 'YAML_HEAD'
network:
  version: 2
  ethernets:
YAML_HEAD

    for IF in "${ifaces[@]}"; do
        local MAC IP GW PREFIX
        MAC=$(cat "/sys/class/net/$IF/address" 2>/dev/null || echo "")
        get_ip_gw "$IF"

        if [ -z "$IP" ] || [ -z "$GW" ]; then
            echo "[WARN] $IF 未获取到 IP/GW，写入基础 DHCP 配置"
            cat >> "$CONF_FILE" << YAML
    $IF:
      match:
        macaddress: "$MAC"
      set-name: "$IF"
      dhcp4: true
      dhcp6: false
      mtu: 1500
      dhcp4-overrides:
        route-metric: $METRIC
YAML
        else
            echo "[INFO] $IF  IP=$IP/$PREFIX  GW=$GW  table=$T_ID  metric=$METRIC"
            cat >> "$CONF_FILE" << YAML
    $IF:
      match:
        macaddress: "$MAC"
      set-name: "$IF"
      dhcp4: true
      dhcp6: false
      mtu: 1500
      dhcp4-overrides:
        route-metric: $METRIC
      routing-policy:
        - from: $IP
          table: $T_ID
      routes:
        - to: default
          via: $GW
          table: $T_ID
YAML
        fi
        T_ID=$((T_ID + 2))
        METRIC=$((METRIC + 100))
    done

    netplan apply
    echo "[OK] netplan 配置已应用"
}

# ──────────────────────────────────────────────
# 6. 写入配置 — NetworkManager (nmcli)
# ──────────────────────────────────────────────
write_networkmanager() {
    local ifaces=("$@")
    local METRIC=100

    echo "[INFO] 使用 NetworkManager (nmcli) 写入配置"
    for IF in "${ifaces[@]}"; do
        local IP GW PREFIX
        get_ip_gw "$IF"
        local CON_NAME="con-${IF}"

        # 删除旧连接（如有）
        nmcli con delete "$CON_NAME" &>/dev/null || true

        if [ -z "$IP" ] || [ -z "$GW" ]; then
            echo "[WARN] $IF 未获取到 IP/GW，创建 DHCP 连接"
            nmcli con add \
                type ethernet \
                ifname "$IF" \
                con-name "$CON_NAME" \
                ipv4.method auto \
                ipv4.route-metric "$METRIC" \
                connection.autoconnect yes
        else
            echo "[INFO] $IF  IP=$IP/$PREFIX  GW=$GW  metric=$METRIC"
            nmcli con add \
                type ethernet \
                ifname "$IF" \
                con-name "$CON_NAME" \
                ipv4.method auto \
                ipv4.route-metric "$METRIC" \
                connection.autoconnect yes
            # 对已获取到 IP 的接口，额外设置静态路由兜底
            nmcli con modify "$CON_NAME" \
                +ipv4.routes "0.0.0.0/0 $GW $METRIC" || true
        fi

        nmcli con up "$CON_NAME" &>/dev/null || true
        METRIC=$((METRIC + 100))
    done
    echo "[OK] NetworkManager 配置已应用"
}

# ──────────────────────────────────────────────
# 7. 写入配置 — systemd-networkd (.network 文件)
# ──────────────────────────────────────────────
write_systemd_networkd() {
    local ifaces=("$@")
    local METRIC=100

    echo "[INFO] 使用 systemd-networkd 写入配置"
    for IF in "${ifaces[@]}"; do
        local MAC IP GW PREFIX
        MAC=$(cat "/sys/class/net/$IF/address" 2>/dev/null || echo "")
        get_ip_gw "$IF"
        local CONF="/etc/systemd/network/10-${IF}.network"

        cat > "$CONF" << UNIT
[Match]
MACAddress=$MAC
Name=$IF

[Link]
MTUBytes=1500

[Network]
DHCP=ipv4

[DHCP]
RouteMetric=$METRIC
UseDNS=yes
UseNTP=yes
UNIT

        if [ -n "$IP" ] && [ -n "$GW" ]; then
            echo "[INFO] $IF  IP=$IP  GW=$GW  metric=$METRIC"
            # 追加策略路由
            cat >> "$CONF" << UNIT

[Route]
Destination=0.0.0.0/0
Gateway=$GW
Metric=$METRIC
UNIT
        else
            echo "[WARN] $IF 未获取到 IP/GW，仅写 DHCP 配置"
        fi

        METRIC=$((METRIC + 100))
    done

    systemctl restart systemd-networkd
    echo "[OK] systemd-networkd 配置已应用"
}

# ──────────────────────────────────────────────
# 8. 写入配置 — ifupdown (/etc/network/interfaces)
# ──────────────────────────────────────────────
write_ifupdown() {
    local ifaces=("$@")
    local INT_FILE="/etc/network/interfaces"

    echo "[INFO] 使用 ifupdown 写入配置: $INT_FILE"
    # 备份原始文件
    cp "$INT_FILE" "${INT_FILE}.bak.$(date +%s)" 2>/dev/null || true

    cat > "$INT_FILE" << 'EOF'
# Generated by getip.sh
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback
EOF

    local METRIC=100
    for IF in "${ifaces[@]}"; do
        local IP GW PREFIX
        get_ip_gw "$IF"

        cat >> "$INT_FILE" << IFACE

auto $IF
iface $IF inet dhcp
    metric $METRIC
IFACE

        if [ -n "$IP" ] && [ -n "$GW" ]; then
            echo "[INFO] $IF  IP=$IP  GW=$GW  metric=$METRIC"
            cat >> "$INT_FILE" << IFACE
    post-up ip route add default via $GW dev $IF metric $METRIC || true
IFACE
        else
            echo "[WARN] $IF 未获取到 IP/GW，仅写 DHCP"
        fi

        METRIC=$((METRIC + 100))
    done

    # 重启网络服务（兼容 sysvinit 和 systemd）
    if command -v systemctl &>/dev/null; then
        systemctl restart networking 2>/dev/null || ifdown -a --ignore-errors && ifup -a || true
    else
        /etc/init.d/networking restart || true
    fi
    echo "[OK] ifupdown 配置已应用"
}

# ──────────────────────────────────────────────
# 9. 兜底: 仅用 ip 命令临时配置（不写持久化）
# ──────────────────────────────────────────────
write_iproute2_only() {
    local ifaces=("$@")
    echo "[WARN] 未识别持久化网络栈，仅通过 ip 命令临时配置（重启后失效）"
    local METRIC=100
    for IF in "${ifaces[@]}"; do
        local IP GW PREFIX
        get_ip_gw "$IF"
        if [ -n "$IP" ] && [ -n "$GW" ]; then
            echo "[INFO] $IF  IP=$IP  GW=$GW  metric=$METRIC"
            ip route replace default via "$GW" dev "$IF" metric "$METRIC" 2>/dev/null || true
        fi
        METRIC=$((METRIC + 100))
    done
    echo "[OK] 临时路由已设置"
}

# ──────────────────────────────────────────────
# 主流程
# ──────────────────────────────────────────────
main() {
    cat << 'BANNER'
╔══════════════════════════════════════════════════════════════════════════╗
║              getip.sh — 全平台多网卡 IP 自动配置脚本                   ║
║                                                                          ║
║  支持的系统与版本 (按网络栈分组):                                        ║
║                                                                          ║
║  [netplan]         Ubuntu 17.10/18.04/20.04/22.04/24.04                 ║
║                    Ubuntu Server 18.04/20.04/22.04/24.04                ║
║                    Debian 12 (若已启用 netplan)                         ║
║                                                                          ║
║  [NetworkManager]  CentOS 7/8/8-Stream/9-Stream                         ║
║                    RHEL 7/8/9                                            ║
║                    Rocky Linux 8/9  |  AlmaLinux 8/9                    ║
║                    Fedora 36~41+    |  openSUSE Leap 15.x / Tumbleweed  ║
║                    SLES 15+                                              ║
║                                                                          ║
║  [systemd-networkd] Debian 10/11/12 (最小化安装)                        ║
║                     Ubuntu 16.04/18.04 (无 netplan 环境)                ║
║                     Arch Linux / Manjaro (rolling)                      ║
║                                                                          ║
║  [ifupdown]        Debian 9/10/11/12 (传统安装)                         ║
║                     Ubuntu 14.04/16.04                                  ║
║                     Raspbian / RPiOS (所有版本)                         ║
║                     Linux Mint 19/20/21  |  Kali Linux (rolling)        ║
║                                                                          ║
║  [iproute2-only]   任意 Linux 发行版 (兜底，临时生效，不持久化)         ║
║                                                                          ║
║  注意: 需要 bash 4.0+, root 权限, iproute2 工具集                       ║
╚══════════════════════════════════════════════════════════════════════════╝
BANNER
    echo ""

    detect_distro
    detect_network_stack

    echo "[INFO] 发行版:  ${DISTRO_ID} ${DISTRO_VER} (like: ${DISTRO_LIKE:-none})"
    echo "[INFO] 网络栈:  ${NETWORK_STACK}"

    # 收集物理网卡列表
    mapfile -t IFACES < <(get_physical_ifaces)
    if [ ${#IFACES[@]} -eq 0 ]; then
        echo "[ERROR] 未发现任何物理网卡，退出" >&2
        exit 1
    fi
    echo "[INFO] 发现网卡: ${IFACES[*]}"

    # 第一阶段：激活 DHCP 获取 IP
    echo ""
    echo "--- 阶段 1: DHCP 激活 ---"
    activate_dhcp_all "${IFACES[@]}"

    # 第二阶段：写入持久化配置
    echo ""
    echo "--- 阶段 2: 写入持久化配置 ---"
    case "$NETWORK_STACK" in
        netplan)            write_netplan           "${IFACES[@]}" ;;
        networkmanager)     write_networkmanager    "${IFACES[@]}" ;;
        systemd-networkd)   write_systemd_networkd  "${IFACES[@]}" ;;
        ifupdown)           write_ifupdown          "${IFACES[@]}" ;;
        *)                  write_iproute2_only     "${IFACES[@]}" ;;
    esac

    # 第三阶段：汇总结果
    echo ""
    echo "--- 阶段 3: 当前网卡状态汇总 ---"
    for IF in "${IFACES[@]}"; do
        local IP GW PREFIX
        get_ip_gw "$IF"
        if [ -n "$IP" ]; then
            printf "  %-12s  IP=%-18s GW=%s\n" "$IF" "${IP}/${PREFIX}" "${GW:-N/A}"
        else
            printf "  %-12s  [未获取到 IP]\n" "$IF"
        fi
    done

    echo ""
    echo "[DONE] 配置完成。"
}

main "$@"
