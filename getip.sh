#!/bin/bash
# 多发行版多网卡 DHCP + 策略路由配置脚本
# 支持: Ubuntu 16.04+, Debian, CentOS 6/7/8, RHEL, Fedora

# ============================================================
# 基础检查
# ============================================================
if [ "$EUID" -ne 0 ]; then
    echo "请使用 sudo 或 root 运行此脚本"
    exit 1
fi

# ============================================================
# 颜色输出
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================================
# 检测发行版信息
# ============================================================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION_ID=$VERSION_ID
        OS_VERSION_MAJOR=$(echo $VERSION_ID | cut -d. -f1)
        OS_VERSION_MINOR=$(echo $VERSION_ID | cut -d. -f2)
        OS_LIKE=$ID_LIKE
    elif [ -f /etc/redhat-release ]; then
        OS="centos"
        OS_VERSION_ID=$(grep -oE '[0-9]+\.[0-9]+' /etc/redhat-release | head -1)
        OS_VERSION_MAJOR=$(echo $OS_VERSION_ID | cut -d. -f1)
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        OS_VERSION_ID=$(cat /etc/debian_version)
        OS_VERSION_MAJOR=$(echo $OS_VERSION_ID | cut -d. -f1)
    else
        error "无法识别的操作系统"
    fi
    info "操作系统: $OS $OS_VERSION_ID"
}

# ============================================================
# 检测网络管理方式 + 细化版本语法差异
# ============================================================
detect_network_manager() {
    # Ubuntu 17.10+ (netplan)
    if command -v netplan &>/dev/null && [ -d /etc/netplan ]; then
        NET_MANAGER="netplan"

        # 检测 netplan 版本
        NETPLAN_VER=$(netplan version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        NETPLAN_MAJOR=$(echo $NETPLAN_VER | cut -d. -f1)
        NETPLAN_MINOR=$(echo $NETPLAN_VER | cut -d. -f2)
        info "Netplan 版本: $NETPLAN_VER"

        # to: default 语法在 0.104+ 才支持，否则用 0.0.0.0/0
        if [ "${NETPLAN_MAJOR:-0}" -gt 0 ] || [ "${NETPLAN_MINOR:-0}" -ge 104 ]; then
            NETPLAN_ROUTE_TO="default"
        else
            NETPLAN_ROUTE_TO="0.0.0.0/0"
        fi

        # routing-policy priority 字段在 0.99+ 才支持
        if [ "${NETPLAN_MINOR:-0}" -ge 99 ] || [ "${NETPLAN_MAJOR:-0}" -gt 0 ]; then
            NETPLAN_SUPPORT_PRIORITY=true
        else
            NETPLAN_SUPPORT_PRIORITY=false
        fi

        # use-routes: false 在 0.100+ 支持
        if [ "${NETPLAN_MINOR:-0}" -ge 100 ] || [ "${NETPLAN_MAJOR:-0}" -gt 0 ]; then
            NETPLAN_SUPPORT_USE_ROUTES=true
        else
            NETPLAN_SUPPORT_USE_ROUTES=false
        fi

        info "路由语法: to=$NETPLAN_ROUTE_TO | priority支持=$NETPLAN_SUPPORT_PRIORITY | use-routes支持=$NETPLAN_SUPPORT_USE_ROUTES"

    # CentOS/RHEL/Fedora with NetworkManager
    elif command -v nmcli &>/dev/null && systemctl is-active NetworkManager &>/dev/null 2>&1; then
        NET_MANAGER="nmcli"

        # 检测 nmcli 版本，routing-rules 在 1.18+ 支持
        NMCLI_VER=$(nmcli --version | grep -oP '\d+\.\d+\.\d+' | head -1)
        NMCLI_MAJOR=$(echo $NMCLI_VER | cut -d. -f1)
        NMCLI_MINOR=$(echo $NMCLI_VER | cut -d. -f2)
        info "NetworkManager 版本: $NMCLI_VER"

        if [ "$NMCLI_MAJOR" -gt 1 ] || { [ "$NMCLI_MAJOR" -eq 1 ] && [ "$NMCLI_MINOR" -ge 18 ]; }; then
            NMCLI_SUPPORT_ROUTING_RULES=true
        else
            NMCLI_SUPPORT_ROUTING_RULES=false
        fi
        info "nmcli routing-rules支持: $NMCLI_SUPPORT_ROUTING_RULES"

    # CentOS 6 / 旧版 RHEL（无 NetworkManager 或未启动）
    elif [ -d /etc/sysconfig/network-scripts ]; then
        NET_MANAGER="network-scripts"
        info "使用传统 network-scripts 管理"

    # Ubuntu 16.04- / Debian
    elif [ -f /etc/network/interfaces ]; then
        NET_MANAGER="ifupdown"

        # ifupdown 版本检测
        IFUPDOWN_VER=$(dpkg -l ifupdown 2>/dev/null | grep '^ii' | awk '{print $3}' | cut -d. -f1)
        info "ifupdown 版本: $IFUPDOWN_VER"

    else
        error "无法识别网络管理方式"
    fi

    info "网络管理方式: $NET_MANAGER"
}

# ============================================================
# 获取物理网卡（排除 lo 和虚拟网卡）
# ============================================================
get_interfaces() {
    IFACES=""
    for IF in $(ls /sys/class/net | grep -v lo | sort -V); do
        # 排除虚拟接口：docker、virbr、veth、tun、tap、bond等
        if echo "$IF" | grep -qE '^(docker|virbr|veth|tun|tap|bond|dummy|br-)'; then
            warn "跳过虚拟网卡: $IF"
            continue
        fi
        # 检查是否有物理地址
        if [ -f /sys/class/net/$IF/address ]; then
            IFACES="$IFACES $IF"
        fi
    done
    IFACES=$(echo $IFACES | xargs)  # 去除首尾空格
    info "物理网卡列表: $IFACES"
}

# ============================================================
# 写入 iproute2 路由表（通用）
# ============================================================
add_rt_table() {
    local T_ID=$1
    local IF=$2
    if ! grep -q "^$T_ID " /etc/iproute2/rt_tables; then
        echo "$T_ID rt_$IF" >> /etc/iproute2/rt_tables
        info "添加路由表: $T_ID rt_$IF"
    fi
}

# ============================================================
# 方案一：Netplan（Ubuntu 17.10+）
# ============================================================
configure_netplan() {
    # 找到实际使用的 netplan 配置文件
    CONF_FILE=$(ls /etc/netplan/*.yaml 2>/dev/null | head -1)
    [ -z "$CONF_FILE" ] && CONF_FILE="/etc/netplan/50-cloud-init.yaml"
    cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
    info "配置文件: $CONF_FILE"

    info "--- [Netplan] 步骤 1: 生成临时 DHCP 配置 ---"
    cat <<EOF > $CONF_FILE
network:
  version: 2
  ethernets:
EOF
    for IF in $IFACES; do
        MAC=$(cat /sys/class/net/$IF/address)
        cat <<EOF >> $CONF_FILE
    $IF:
      match:
        macaddress: "$MAC"
      set-name: "$IF"
      dhcp4: true
      mtu: 1500
EOF
    done
    netplan apply
    info "等待 8 秒完成 DHCP 协商..."
    sleep 8

    info "--- [Netplan] 步骤 2: 生成最终策略路由配置 ---"
    cat <<EOF > $CONF_FILE
network:
  version: 2
  ethernets:
EOF
    T_ID=100
    METRIC=100
    for IF in $IFACES; do
        MAC=$(cat /sys/class/net/$IF/address)
        IP=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
        GW=$(ip route show dev $IF | grep default | awk '{print $3}' | head -n 1)

        if [ -z "$IP" ] || [ -z "$GW" ]; then
            warn "$IF 未获取到 IP/GW，写入基础 DHCP 配置"
            cat <<EOF >> $CONF_FILE
    $IF:
      match:
        macaddress: "$MAC"
      set-name: "$IF"
      dhcp4: true
      mtu: 1500
      dhcp4-overrides:
        route-metric: $METRIC
EOF
        else
            info "写入 $IF: IP=$IP GW=$GW Table=$T_ID Metric=$METRIC"

            # 根据版本决定是否写 use-routes
            DHCP_OVERRIDES="      dhcp4-overrides:
        route-metric: $METRIC"
            if [ "$NETPLAN_SUPPORT_USE_ROUTES" = true ]; then
                DHCP_OVERRIDES="$DHCP_OVERRIDES
        use-routes: false"
            fi

            # 根据版本决定是否写 priority
            ROUTING_POLICY="      routing-policy:
        - from: $IP
          table: $T_ID"
            if [ "$NETPLAN_SUPPORT_PRIORITY" = true ]; then
                ROUTING_POLICY="$ROUTING_POLICY
          priority: $METRIC"
            fi

            cat <<EOF >> $CONF_FILE
    $IF:
      match:
        macaddress: "$MAC"
      set-name: "$IF"
      dhcp4: true
      mtu: 1500
$DHCP_OVERRIDES
$ROUTING_POLICY
      routes:
        - to: $NETPLAN_ROUTE_TO
          via: $GW
          table: $T_ID
          metric: $METRIC
EOF
        fi
        T_ID=$((T_ID + 2))
        METRIC=$((METRIC + 100))
    done

    info "--- [Netplan] 步骤 3: 应用最终配置 ---"
    netplan apply && info "配置成功！" || error "netplan apply 失败，请检查 $CONF_FILE"
}

# ============================================================
# 方案二：nmcli（CentOS 7/8, RHEL, Fedora）
# ============================================================
configure_nmcli() {
    info "--- [nmcli] 步骤 1: 为每个网卡创建 DHCP 连接 ---"
    for IF in $IFACES; do
        CON_NAME="con-$IF"
        nmcli con delete "$CON_NAME" &>/dev/null || true
        nmcli con add type ethernet \
            con-name "$CON_NAME" \
            ifname "$IF" \
            ipv4.method auto \
            connection.autoconnect yes
        nmcli con up "$CON_NAME"
    done

    info "等待 8 秒完成 DHCP 协商..."
    sleep 8

    info "--- [nmcli] 步骤 2: 配置策略路由 ---"
    T_ID=100
    METRIC=100
    for IF in $IFACES; do
        CON_NAME="con-$IF"
        IP=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
        GW=$(ip route show dev $IF | grep default | awk '{print $3}' | head -n 1)

        if [ -z "$IP" ] || [ -z "$GW" ]; then
            warn "$IF 未获取到 IP/GW，跳过策略路由"
        else
            info "配置 $IF: IP=$IP GW=$GW Table=$T_ID Metric=$METRIC"
            nmcli con modify "$CON_NAME" ipv4.route-metric $METRIC

            if [ "$NMCLI_SUPPORT_ROUTING_RULES" = true ]; then
                # 1.18+ 支持 routing-rules
                nmcli con modify "$CON_NAME" \
                    ipv4.routing-rules "priority $METRIC from $IP table $T_ID" \
                    +ipv4.routes "0.0.0.0/0 $GW table=$T_ID metric=$METRIC"
            else
                # 旧版本用 dispatcher 脚本持久化
                add_rt_table $T_ID $IF
                DISP_DIR="/etc/NetworkManager/dispatcher.d"
                mkdir -p $DISP_DIR
                cat <<EOF > $DISP_DIR/99-policy-route-$IF
#!/bin/bash
IF=$IF
IP=$IP
GW=$GW
T_ID=$T_ID
METRIC=$METRIC
if [ "\$1" = "\$IF" ] && [ "\$2" = "up" ]; then
    ip rule add from \$IP table \$T_ID priority \$METRIC 2>/dev/null || true
    ip route add default via \$GW dev \$IF table \$T_ID metric \$METRIC 2>/dev/null || true
fi
EOF
                chmod +x $DISP_DIR/99-policy-route-$IF
                # 立即生效
                ip rule add from $IP table $T_ID priority $METRIC 2>/dev/null || true
                ip route add default via $GW dev $IF table $T_ID metric $METRIC 2>/dev/null || true
            fi
            nmcli con up "$CON_NAME"
        fi
        T_ID=$((T_ID + 2))
        METRIC=$((METRIC + 100))
    done
    info "完成！查看连接: nmcli con show"
}

# ============================================================
# 方案三：network-scripts（CentOS 6, 旧版 RHEL）
# ============================================================
configure_network_scripts() {
    SCRIPT_DIR="/etc/sysconfig/network-scripts"
    info "--- [network-scripts] 步骤 1: 生成网卡配置 ---"
    for IF in $IFACES; do
        MAC=$(cat /sys/class/net/$IF/address)
        cat <<EOF > $SCRIPT_DIR/ifcfg-$IF
DEVICE=$IF
HWADDR=$MAC
BOOTPROTO=dhcp
ONBOOT=yes
MTU=1500
NM_CONTROLLED=no
EOF
        info "生成: $SCRIPT_DIR/ifcfg-$IF"
    done

    if command -v systemctl &>/dev/null; then
        systemctl restart network 2>/dev/null || systemctl restart NetworkManager
    else
        service network restart
    fi

    info "等待 8 秒完成 DHCP 协商..."
    sleep 8

    info "--- [network-scripts] 步骤 2: 配置策略路由 ---"
    T_ID=100
    METRIC=100
    for IF in $IFACES; do
        IP=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
        GW=$(ip route show dev $IF | grep default | awk '{print $3}' | head -n 1)

        if [ -z "$IP" ] || [ -z "$GW" ]; then
            warn "$IF 未获取到 IP/GW，跳过"
        else
            info "配置 $IF: IP=$IP GW=$GW Table=$T_ID"
            add_rt_table $T_ID $IF
            echo "default via $GW dev $IF table $T_ID metric $METRIC" > $SCRIPT_DIR/route-$IF
            echo "from $IP table $T_ID priority $METRIC" > $SCRIPT_DIR/rule-$IF
        fi
        T_ID=$((T_ID + 2))
        METRIC=$((METRIC + 100))
    done

    if command -v systemctl &>/dev/null; then
        systemctl restart network 2>/dev/null || systemctl restart NetworkManager
    else
        service network restart
    fi
    info "完成！"
}

# ============================================================
# 方案四：ifupdown（Ubuntu 16.04-, Debian）
# ============================================================
configure_ifupdown() {
    CONF_FILE="/etc/network/interfaces"
    cp $CONF_FILE ${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)

    info "--- [ifupdown] 步骤 1: 生成临时 DHCP 配置 ---"
    cat <<EOF > $CONF_FILE
# 自动生成，原始配置见 .bak 文件
auto lo
iface lo inet loopback
EOF
    for IF in $IFACES; do
        cat <<EOF >> $CONF_FILE

auto $IF
iface $IF inet dhcp
    mtu 1500
EOF
    done

    ifdown -a --exclude=lo 2>/dev/null; ifup -a --exclude=lo
    info "等待 8 秒完成 DHCP 协商..."
    sleep 8

    info "--- [ifupdown] 步骤 2: 写入策略路由配置 ---"
    cat <<EOF > $CONF_FILE
# 自动生成（含策略路由），原始配置见 .bak 文件
auto lo
iface lo inet loopback
EOF
    T_ID=100
    METRIC=100
    for IF in $IFACES; do
        IP=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
        GW=$(ip route show dev $IF | grep default | awk '{print $3}' | head -n 1)

        if [ -z "$IP" ] || [ -z "$GW" ]; then
            warn "$IF 未获取到 IP/GW，写入基础 DHCP"
            cat <<EOF >> $CONF_FILE

auto $IF
iface $IF inet dhcp
    mtu 1500
EOF
        else
            info "配置 $IF: IP=$IP GW=$GW Table=$T_ID Metric=$METRIC"
            add_rt_table $T_ID $IF
            cat <<EOF >> $CONF_FILE

auto $IF
iface $IF inet dhcp
    mtu 1500
    metric $METRIC
    post-up ip rule add from $IP table $T_ID priority $METRIC || true
    post-up ip route add default via $GW dev $IF table $T_ID metric $METRIC || true
    pre-down ip rule del from $IP table $T_ID priority $METRIC || true
    pre-down ip route del default via $GW dev $IF table $T_ID || true
EOF
        fi
        T_ID=$((T_ID + 2))
        METRIC=$((METRIC + 100))
    done

    ifdown -a --exclude=lo 2>/dev/null; ifup -a --exclude=lo
    info "完成！查看配置: cat $CONF_FILE"
}

# ============================================================
# 主流程
# ============================================================
echo "================================================"
echo "  多发行版网络配置脚本"
echo "================================================"

detect_os
detect_network_manager
get_interfaces

[ -z "$IFACES" ] && error "未检测到任何物理网卡，退出"

case $NET_MANAGER in
    netplan)         configure_netplan ;;
    nmcli)           configure_nmcli ;;
    network-scripts) configure_network_scripts ;;
    ifupdown)        configure_ifupdown ;;
    *)               error "未知网络管理方式: $NET_MANAGER" ;;
esac

echo "================================================"
info "全部完成！当前网络状态："
ip -4 addr show | grep -E 'inet |^[0-9]'
echo "================================================"
