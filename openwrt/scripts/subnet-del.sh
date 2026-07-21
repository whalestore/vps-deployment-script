#!/bin/sh
# ================================================================
#  subnet-del.sh - 单个子网删除 (会断网, SSH 执行)
#
#  功能: 删除指定子网, 删 UCI 接口+DHCP+防火墙, 网口还回 br-lan
#
#  用法:
#    subnet-del.sh <iface|subnet_id> [--dry-run]
#
#  示例:
#    subnet-del.sh eth0         # 按网口名删
#    subnet-del.sh 2            # 按子网 ID 删
#    subnet-del.sh eth0 --dry-run  # 预演
#
#  依赖: _subnet-lib.sh, uci, jq, vps-db.sh
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

# ---------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------
KEY=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        -*)        err "未知参数: $1"; exit 1 ;;
        *)         if [ -z "$KEY" ]; then KEY="$1"; else err "多余的参数: $1"; exit 1; fi; shift ;;
    esac
done

if [ -z "$KEY" ]; then
    err "用法: subnet-del.sh <iface|subnet_id> [--dry-run]"
    exit 1
fi

echo "=========================================="
echo "  子网删除: $KEY"
echo "  dry-run: $DRY_RUN"
echo "=========================================="
echo ""

# ---------------------------------------------------------------
# 查找子网
# ---------------------------------------------------------------
info "查找子网"
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
UCI_NAME=$(uci_iface_name "$SUB_IFACE")

echo "  ID: $SUB_ID"
echo "  名字: $SUB_NAME"
echo "  接口: $SUB_IFACE"
echo "  CIDR: $SUB_CIDR"
echo "  网关: $SUB_GW"
echo "  UCI 接口: $UCI_NAME"
echo ""

# ---------------------------------------------------------------
# dry-run 预演
# ---------------------------------------------------------------
if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}=== dry-run 模式: 不修改任何配置 ===${NC}"
    echo ""
    echo "将执行:"
    echo "  1. remove_uci_interface $UCI_NAME   (删接口+DHCP+防火墙)"
    echo "  2. return_to_brlan $SUB_IFACE       (网口还回 br-lan)"
    echo "  3. delete_subnet_from_db $SUB_ID    (删 vps.db 记录)"
    echo "  4. commit_and_reload"
    echo ""
    echo "预期结果: $SUB_IFACE 还回 br-lan, 子网 #$SUB_ID 被删除"
    echo ""
    echo "去掉 --dry-run 实际执行"
    exit 0
fi

# ---------------------------------------------------------------
# 实际执行
# ---------------------------------------------------------------
info "备份 UCI 配置"
BAK=$(backup_uci)
ok "备份: $BAK"
echo ""

info "步骤 1: 删除 UCI 接口 $UCI_NAME"
remove_uci_interface "$UCI_NAME"
ok "已删除"
echo ""

info "步骤 2: 网口 $SUB_IFACE 还回 br-lan"
return_to_brlan "$SUB_IFACE"
ok "已还回"
echo ""

info "步骤 3: 删除 vps.db 记录 #$SUB_ID"
delete_subnet_from_db "$SUB_ID"
ok "已删除"
echo ""

info "步骤 4: commit + reload"
commit_and_reload

info "等待网络重载 (15秒)..."
sleep 15

# ---------------------------------------------------------------
# 验证 + 输出
# ---------------------------------------------------------------
echo ""
echo "=== 网络接口状态 ==="
ip -br addr show "$SUB_IFACE" 2>/dev/null

echo ""
ok "子网删除成功!"
echo ""
echo "  已删除: #$SUB_ID $SUB_NAME ($SUB_IFACE -> $SUB_CIDR)"
echo "  网口 $SUB_IFACE 已还回 br-lan"
echo ""
print_luci_urls
