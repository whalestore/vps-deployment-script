#!/bin/sh
# ================================================================
#  subnet-add.sh - 单个子网创建 (会断网, SSH 执行)
#
#  功能: 把指定物理 LAN 口从 br-lan 拆出, 建独立子网
#
#  用法:
#    subnet-add.sh <iface> [--name <name>] [--cidr <cidr>] [--dry-run]
#
#  示例:
#    subnet-add.sh eth0                     # 自动分配 CIDR
#    subnet-add.sh eth3 --name 直播间A       # 指定名字
#    subnet-add.sh eth3 --cidr 192.168.10.0/24  # 指定 CIDR
#    subnet-add.sh eth0 --dry-run           # 预演
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
IFACE=""
NAME=""
CIDR=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --name)    shift; NAME="$1"; shift ;;
        --cidr)    shift; CIDR="$1"; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -*)        err "未知参数: $1"; exit 1 ;;
        *)         if [ -z "$IFACE" ]; then IFACE="$1"; else err "多余的参数: $1"; exit 1; fi; shift ;;
    esac
done

if [ -z "$IFACE" ]; then
    err "用法: subnet-add.sh <iface> [--name <name>] [--cidr <cidr>] [--dry-run]"
    exit 1
fi

# 默认名字
if [ -z "$NAME" ]; then
    NAME="LAN-$IFACE"
fi

echo "=========================================="
echo "  子网创建: $IFACE"
echo "  名字: $NAME"
[ -n "$CIDR" ] && echo "  指定 CIDR: $CIDR" || echo "  CIDR: 自动分配"
echo "  dry-run: $DRY_RUN"
echo "=========================================="
echo ""

# ---------------------------------------------------------------
# 校验
# ---------------------------------------------------------------
info "校验"

if ! is_phys_iface "$IFACE"; then
    err "$IFACE 不是物理网口"
    exit 1
fi
ok "是物理网口"

if is_wan_iface "$IFACE"; then
    err "$IFACE 是 WAN 口, 不能拆"
    exit 1
fi
ok "不是 WAN 口"

if ! is_in_brlan "$IFACE"; then
    err "$IFACE 不在 br-lan (可能已被拆出为子网)"
    info "查看当前子网: subnet-list.sh"
    exit 1
fi
ok "在 br-lan 成员里"

# 检查是否已有子网
EXISTING=$(get_subnet_from_db "$IFACE")
if [ -n "$EXISTING" ] && [ "$EXISTING" != "null" ]; then
    err "$IFACE 已有子网记录:"
    echo "$EXISTING" | jq '.' 2>/dev/null
    exit 1
fi
ok "尚无子网记录"
echo ""

# ---------------------------------------------------------------
# 检查 br-lan 最后成员保护
# ---------------------------------------------------------------
REMAINING=$(count_brlan_remaining "$IFACE")
if [ "$REMAINING" = "0" ]; then
    err "$IFACE 是 br-lan 最后一个成员, 拆出后 br-lan 将无物理口"
    warn "如确需拆出, 请先把另一个口加入 br-lan, 或用 init-subnets.sh --rollback 回滚所有子网"
    exit 1
fi
ok "拆出后 br-lan 还剩 $REMAINING 个成员"
echo ""

# ---------------------------------------------------------------
# 分配 CIDR
# ---------------------------------------------------------------
if [ -z "$CIDR" ]; then
    info "自动分配 CIDR"
    # 收集已占用
    USED_CIDRS=""
    BRLAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
    if [ -n "$BRLAN_IP" ]; then
        BRLAN_THIRD=$(echo "$BRLAN_IP" | cut -d. -f3)
        USED_CIDRS="$USED_CIDRS $BRLAN_THIRD"
    fi
    EXISTING_SUBNETS=$(list_subnets_from_db)
    if [ -n "$EXISTING_SUBNETS" ] && [ "$EXISTING_SUBNETS" != "[]" ]; then
        USED_CIDRS="$USED_CIDRS $(echo "$EXISTING_SUBNETS" | jq -r '.[].cidr' | grep -oE '192\.168\.[0-9]+' | cut -d. -f3 | tr '\n' ' ')"
    fi
    CIDR=$(allocate_cidr "$USED_CIDRS")
    if [ -z "$CIDR" ]; then
        err "无法分配 CIDR (网段 192.168.5-254 已用完)"
        exit 1
    fi
fi
THIRD=$(echo "$CIDR" | grep -oE '192\.168\.[0-9]+' | cut -d. -f3)
GATEWAY="192.168.$THIRD.1"
UCI_NAME=$(uci_iface_name "$IFACE")

echo "  CIDR: $CIDR"
echo "  网关: $GATEWAY"
echo "  UCI 接口: $UCI_NAME"
echo ""

# ---------------------------------------------------------------
# dry-run 预演
# ---------------------------------------------------------------
if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}=== dry-run 模式: 不修改任何配置 ===${NC}"
    echo ""
    echo "将执行:"
    echo "  1. safe_remove_from_brlan $IFACE   (从 br-lan 移除)"
    echo "  2. create_uci_interface $IFACE $UCI_NAME $GATEWAY  (建接口+DHCP+防火墙)"
    echo "  3. add_subnet_to_db {name:$NAME, interface:$IFACE, cidr:$CIDR, gateway:$GATEWAY}"
    echo "  4. commit_and_reload"
    echo ""
    echo "预期结果: $IFACE -> $CIDR (网关 $GATEWAY)"
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

info "步骤 1: 从 br-lan 移除 $IFACE"
if ! safe_remove_from_brlan "$IFACE"; then
    err "移除失败"
    exit 1
fi
ok "已移除"
echo ""

info "步骤 2: 创建 UCI 接口 $UCI_NAME"
if ! create_uci_interface "$IFACE" "$UCI_NAME" "$GATEWAY"; then
    err "创建 UCI 接口失败, 回滚 br-lan"
    return_to_brlan "$IFACE"
    uci commit network
    exit 1
fi
ok "已创建"
echo ""

info "步骤 3: 写入 vps.db"
SUBNET_JSON="{\"name\":\"$NAME\",\"interface\":\"$IFACE\",\"cidr\":\"$CIDR\",\"gateway\":\"$GATEWAY\"}"
DB_OUT=$(add_subnet_to_db "$SUBNET_JSON")
SUB_ID=$(echo "$DB_OUT" | jq -r '.id // empty' 2>/dev/null)
if [ -z "$SUB_ID" ]; then
    err "写入 vps.db 失败, 回滚 UCI: $DB_OUT"
    remove_uci_interface "$UCI_NAME"
    return_to_brlan "$IFACE"
    uci commit network
    exit 1
fi
ok "已写入, 子网 ID=$SUB_ID"
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
ip -br addr show "$IFACE" 2>/dev/null

echo ""
ok "子网创建成功!"
echo ""
echo "  ID: $SUB_ID"
echo "  名字: $NAME"
echo "  接口: $IFACE"
echo "  CIDR: $CIDR"
echo "  网关: $GATEWAY"
echo ""
print_luci_urls
echo ""
echo "如需删除: subnet-del.sh $IFACE"
