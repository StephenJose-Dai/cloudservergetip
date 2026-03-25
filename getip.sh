#!/bin/bash

# 1. 定义文件路径
CONF_FILE="/etc/netplan/50-cloud-init.yaml"

# 2. 基础环境检查
if [ "$EUID" -ne 0 ]; then 
  echo "请使用 sudo 运行此脚本"
  exit 1
fi

# 获取所有物理网卡（排除 lo），并按名称自然排序
IFACES=$(ls /sys/class/net | grep -v lo | sort -V)

echo "--- 步骤 1: 生成临时配置以激活 DHCP 获取 IP ---"
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

# 应用临时配置
netplan apply
echo "等待 8 秒让 15 块网卡完成 DHCP 协商..."
sleep 8

echo "--- 步骤 2: 抓取真实数据并生成最终 15 段完整配置 ---"

# 重新写文件头
cat <<EOF > $CONF_FILE
network:
  version: 2
  ethernets:
EOF

T_ID=100
METRIC=100

for IF in $IFACES; do
    MAC=$(cat /sys/class/net/$IF/address)
    # 动态抓取当前网卡的 IP 和 网关
    IP=$(ip -4 addr show $IF | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    GW=$(ip route show dev $IF | grep default | awk '{print $3}' | head -n 1)

    if [ -z "$IP" ] || [ -z "$GW" ]; then
        echo "警告: 网卡 $IF 没拿到 IP，将写入基础 DHCP 配置"
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
        echo "写入网卡 $IF: IP=$IP, Table=$T_ID"
        cat <<EOF >> $CONF_FILE
    $IF:
      match:
        macaddress: "$MAC"
      set-name: "$IF"
      dhcp4: true
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
EOF
    fi

    # 核心逻辑：Table 间隔 2，Metric 间隔 100
    T_ID=$((T_ID + 2))
    METRIC=$((METRIC + 100))
done

echo "--- 步骤 3: 应用最终配置 ---"
netplan apply

echo "成功！请执行 'cat $CONF_FILE' 查看生成的 15 段完整配置。"
