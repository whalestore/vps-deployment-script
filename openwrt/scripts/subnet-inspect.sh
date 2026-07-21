#!/bin/sh
# ================================================================
#  subnet-inspect.sh - 查看单个子网详情 (不会断网, SSH 执行)
#
#  功能: 显示子网 DB 记录 + 物理网口实时状态 + DHCP 租约 + ARP 邻居
#
#  用法:
#    subnet-inspect.sh <iface|subnet_id>
#
#  示例:
#    subnet-inspect.sh eth0
#    subnet-inspect.sh 2
#
#  依赖: _subnet-lib.sh, jq, vps-db.sh
# ================================================================

set -uo pipefail

SUBNET_LIB="/usr/bin/_subnet-lib.sh"
if [ ! -f "$SUBNET_LIB" ]; then
    SUBNET_LIB="$(dirname "$0")/_subnet-lib.sh"
fi
if [ ! -f "$SUBNET_LIB" ]; then
    echo "ERROR: _subnet-lib.sh not found" >&2
    exit 1
fi
. "$SUBNET_LIB"

KEY="$1"
if [ -z "$KEY" ]; then
    err "用法: subnet-inspect.sh <iface|subnet_id>"
    exit 1
fi

# ---------------------------------------------------------------
# 查找子网
# ---------------------------------------------------------------
SUBNET_JSON=$(get_subnet_from_db "$KEY")
if [ -z "$SUBNET_JSON" ] || [ "$SUBNET_JSON" = "null" ]; then
    err "找不到子网: $KEY"
    info "查看当前子网: subnet-list.sh"
    exit 1
fi

SUB_ID=$(echo "$SUBNET_JSON" | jq -r '.id')
SUB_NAME=$(echo "$SUBNET_JSON" | jq -r '.name')
SUB_IFACE=$(echo "$SUBNET_JSON" | jq -r '.interface')
SUB_CIDR=$(echo "$SUBNET_JSON" | jq -r '.cidr')
SUB_GW=$(echo "$SUBNET_JSON" | jq -r '.gateway')
SUB_CHAIN_ID=$(echo "$SUBNET_JSON" | jq -r '.chain_id // empty')

# 链路名
SUB_CHAIN_NAME="未绑定"
if [ -n "$SUB_CHAIN_ID" ]; then
    SUB_CHAIN_NAME=$(vps-db.sh list-chains 2>/dev/null | jq -r --argjson cid "$SUB_CHAIN_ID" '.[] | select(.id == $cid) | .name' 2>/dev/null | head -1)
    [ -z "$SUB_CHAIN_NAME" ] && SUB_CHAIN_NAME="未绑定(id=$SUB_CHAIN_ID)"
fi

# ---------------------------------------------------------------
# 输出
# ---------------------------------------------------------------
echo "=========================================="
echo "  子网 #$SUB_ID $SUB_NAME"
echo "=========================================="
echo ""
echo "接口: $SUB_IFACE"
echo "CIDR: $SUB_CIDR"
echo "网关: $SUB_GW"
echo "链路: $SUB_CHAIN_NAME"
[ -n "$SUB_CHAIN_ID" ] && echo "  (chain_id=$SUB_CHAIN_ID)"
echo ""

echo "=== 实时状态 ==="
if [ -d "/sys/class/net/$SUB_IFACE" ]; then
    CARRIER=$(cat "/sys/class/net/$SUB_IFACE/carrier" 2>/dev/null)
    SPEED=$(cat "/sys/class/net/$SUB_IFACE/speed" 2>/dev/null)
    DUPLEX=$(cat "/sys/class/net/$SUB_IFACE/duplex" 2>/dev/null)
    MAC=$(cat "/sys/class/net/$SUB_IFACE/address" 2>/dev/null)
    [ -z "$CARRIER" ] && CARRIER="-"
    if [ -z "$SPEED" ] || [ "$CARRIER" = "0" ]; then SPEED="-"; fi
    if [ -z "$DUPLEX" ] || [ "$CARRIER" = "0" ]; then DUPLEX="-"; fi
    [ -z "$MAC" ] && MAC="-"
    echo "  carrier: $CARRIER $([ "$CARRIER" = "1" ] && echo "(已连接)" || echo "(未连接)")"
    echo "  speed: $SPEED Mbps"
    echo "  duplex: $DUPLEX"
    echo "  MAC: $MAC"
    # 接口 IP
    IFACE_IP=$(ip -br addr show "$SUB_IFACE" 2>/dev/null | awk '{print $3}')
    echo "  接口 IP: ${IFACE_IP:--}"
else
    echo "  (网口 $SUB_IFACE 不存在)"
fi
echo ""

# 提取子网第三段用于过滤 DHCP/ARP
SUB_THIRD=$(echo "$SUB_CIDR" | grep -oE '192\.168\.[0-9]+' | cut -d. -f3)

echo "=== DHCP 租约 (本子网 192.168.$SUB_THIRD.x) ==="
LEASES_FILE="/tmp/dhcp.leases"
if [ -f "$LEASES_FILE" ]; then
    LEASE_COUNT=0
    while IFS= read -r line; do
        IP=$(echo "$line" | awk '{print $3}')
        if echo "$IP" | grep -q "^192\.168\.$SUB_THIRD\."; then
            MAC=$(echo "$line" | awk '{print $2}')
            HOST=$(echo "$line" | awk '{print $4}')
            [ "$HOST" = "*" ] || [ -z "$HOST" ] && HOST="unknown"
            echo "  $IP  $MAC  $HOST"
            LEASE_COUNT=$((LEASE_COUNT + 1))
        fi
    done < "$LEASES_FILE"
    [ "$LEASE_COUNT" = "0" ] && echo "  (无租约)"
else
    echo "  (无 leases 文件)"
fi
echo ""

echo "=== ARP 邻居 (本子网 192.168.$SUB_THIRD.x) ==="
ARP_OUT=$(ip neigh show 2>/dev/null | while IFS= read -r line; do
    IP=$(echo "$line" | awk '{print $1}')
    if echo "$IP" | grep -q "^192\.168\.$SUB_THIRD\."; then
        STATE=$(echo "$line" | grep -oE 'REACHABLE|STALE|FAILED|DELAY|PERMANENT')
        [ -z "$STATE" ] && STATE="UNKNOWN"
        echo "  $IP  $STATE"
    fi
done)
if [ -z "$ARP_OUT" ]; then
    echo "  (无邻居)"
else
    echo "$ARP_OUT"
fi
echo ""

echo "=== br-lan 桥成员检查 ==="
if is_in_brlan "$SUB_IFACE"; then
    warn "$SUB_IFACE 当前还在 br-lan 里! (子网记录与网络状态不一致)"
    info "可能是手动改过 UCI, 或 init-subnets.sh 执行中断"
else
    ok "$SUB_IFACE 已从 br-lan 拆出, 状态正常"
fi
echo ""
echo "操作:"
echo "  删除: subnet-del.sh $SUB_IFACE"
echo "  换绑链路: 通过 LuCI 页面 -> 网口管理 -> 更换"
