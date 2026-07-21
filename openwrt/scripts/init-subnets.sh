#!/bin/sh
# ================================================================
#  init-subnets.sh - 子网批量初始化脚本 (灾难级, 谨慎执行)
#
#  功能: 发现所有物理 LAN 口, 逐个拆出独立子网, 一次性 commit + reload
#
#  用法:
#    init-subnets.sh --dry-run          # 模拟, 输出调试日志, 不修改配置
#    init-subnets.sh --test <iface>     # 只拆一个口, 测试用
#    init-subnets.sh                    # 全量执行, 拆出所有 LAN 口
#    init-subnets.sh --rollback         # 回滚: 删除所有子网, 网口还回 br-lan
#
#  依赖: _subnet-lib.sh, uci, jq, vps-db.sh
# ================================================================

set -uo pipefail

SUBNET_LIB="/usr/bin/_subnet-lib.sh"
# 本地开发时回退到仓库路径
if [ ! -f "$SUBNET_LIB" ]; then
    SUBNET_LIB="$(dirname "$0")/_subnet-lib.sh"
fi
if [ ! -f "$SUBNET_LIB" ]; then
    echo "ERROR: _subnet-lib.sh not found (looked at /usr/bin/ and $(dirname "$0")/)" >&2
    exit 1
fi
. "$SUBNET_LIB"

# ---------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------
MODE="full"
TEST_IFACE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  MODE="dry-run"; shift ;;
        --test)     MODE="test"; shift; [ $# -gt 0 ] || { err "--test 需要指定网口"; exit 1; }; TEST_IFACE="$1"; shift ;;
        --rollback) MODE="rollback"; shift ;;
        *)          err "未知参数: $1"; exit 1 ;;
    esac
done

# dry-run 模式下的模拟执行
DRY_RUN=false
exec_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "  ${CYAN}[dry-run]${NC} $1"
    else
        eval "$1" || warn "命令失败: $1"
    fi
}

# ---------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------

echo "=========================================="
echo "  子网初始化脚本"
echo "  模式: $MODE"
echo "=========================================="
echo ""

# --- 步骤 1: 发现物理网口 ---
info "步骤 1: 发现物理网口"
PHYS_IFACES=$(discover_phys_ifaces)
echo "  物理网口: $PHYS_IFACES"

WAN_IFACE=$(get_wan_iface)
echo "  WAN 口: $WAN_IFACE"

# LAN 口 = 物理网口 - WAN 口
LAN_IFACES=""
for iface in $PHYS_IFACES; do
    if [ "$iface" != "$WAN_IFACE" ]; then
        LAN_IFACES="$LAN_IFACES $iface"
    fi
done
LAN_IFACES=$(echo "$LAN_IFACES" | sed 's/^ //')
echo "  LAN 口: $LAN_IFACES"

BRLAN_MEMBERS=$(get_brlan_members)
echo "  当前 br-lan 成员: $BRLAN_MEMBERS"
echo ""

# --- 根据模式处理 ---
if [ "$MODE" = "dry-run" ]; then
    DRY_RUN=true
    echo -e "${YELLOW}=== dry-run 模式: 模拟执行, 不修改任何配置 ===${NC}"
    echo ""
elif [ "$MODE" = "rollback" ]; then
    echo -e "${YELLOW}=== rollback 模式: 删除所有子网, 网口还回 br-lan ===${NC}"
    echo ""

    info "备份 UCI 配置"
    BAK=$(backup_uci)
    echo "  备份: $BAK"

    SUBNETS=$(list_subnets_from_db)
    SUBNET_COUNT=$(echo "$SUBNETS" | jq 'length' 2>/dev/null)

    if [ "$SUBNET_COUNT" = "0" ] || [ -z "$SUBNET_COUNT" ]; then
        ok "无子网需要回滚"
        print_luci_urls
        exit 0
    fi

    info "发现 $SUBNET_COUNT 个子网, 开始回滚..."

    echo "$SUBNETS" | jq -c '.[]' 2>/dev/null | while read -r subnet_json; do
        SUB_IFACE=$(echo "$subnet_json" | jq -r '.interface')
        SUB_ID=$(echo "$subnet_json" | jq -r '.id')
        UCI_NAME=$(uci_iface_name "$SUB_IFACE")

        log "回滚子网 #$SUB_ID ($SUB_IFACE -> $UCI_NAME)"

        exec_cmd "remove_uci_interface '$UCI_NAME'"
        exec_cmd "return_to_brlan '$SUB_IFACE'"
        exec_cmd "delete_subnet_from_db '$SUB_ID'"
    done

    if [ "$DRY_RUN" = "false" ]; then
        info "commit + reload..."
        commit_and_reload
        info "等待网络重载 (15秒)..."
        sleep 15
    fi

    ok "回滚完成"
    print_luci_urls
    exit 0
fi

# --- dry-run 或 实际执行 (test/full 模式) ---

if [ "$MODE" = "test" ]; then
    if [ -z "$TEST_IFACE" ]; then
        err "--test 需要指定网口, 如: init-subnets.sh --test eth0"
        exit 1
    fi
    if ! is_phys_iface "$TEST_IFACE"; then
        err "$TEST_IFACE 不是物理网口"
        exit 1
    fi
    if is_wan_iface "$TEST_IFACE"; then
        err "$TEST_IFACE 是 WAN 口, 不能拆"
        exit 1
    fi
    TARGET_IFACES="$TEST_IFACE"
    echo -e "${YELLOW}=== test 模式: 只处理 $TEST_IFACE ===${NC}"
    echo ""
else
    TARGET_IFACES="$LAN_IFACES"
    echo -e "${YELLOW}=== full 模式: 处理所有 LAN 口 ===${NC}"
    echo ""
fi

# --- 步骤 2: 备份 ---
if [ "$DRY_RUN" = "false" ]; then
    info "步骤 2: 备份 UCI 配置"
    BAK=$(backup_uci)
    ok "备份完成: $BAK"
    echo ""
else
    info "步骤 2: 备份 UCI 配置"
    echo -e "  ${CYAN}[dry-run]${NC} backup_uci"
    echo ""
fi

# --- 步骤 3: 收集已占用 CIDR ---
info "步骤 3: 收集已占用 CIDR"
USED_CIDRS=""

BRLAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
if [ -n "$BRLAN_IP" ]; then
    BRLAN_THIRD=$(echo "$BRLAN_IP" | cut -d. -f3)
    USED_CIDRS="$USED_CIDRS $BRLAN_THIRD"
    echo "  br-lan 网段: 192.168.$BRLAN_THIRD.0/24"
fi

EXISTING_SUBNETS=$(list_subnets_from_db)
if [ -n "$EXISTING_SUBNETS" ] && [ "$EXISTING_SUBNETS" != "[]" ]; then
    echo "$EXISTING_SUBNETS" | jq -c '.[]' 2>/dev/null | while read -r sub; do
        CIDR=$(echo "$sub" | jq -r '.cidr')
        IFACE=$(echo "$sub" | jq -r '.interface')
        echo "  已有子网: $CIDR ($IFACE)"
    done
    USED_CIDRS="$USED_CIDRS $(echo "$EXISTING_SUBNETS" | jq -r '.[].cidr' | grep -oE '192\.168\.[0-9]+' | cut -d. -f3 | tr '\n' ' ')"
fi
echo "  已占用网段: $USED_CIDRS"
echo ""

# --- 步骤 4: 逐口写 UCI 配置 ---
info "步骤 4: 逐口写 UCI 配置 (不 commit)"

ALLOCATED_COUNT=0

for iface in $TARGET_IFACES; do
    echo ""
    log "处理 $iface:"

    # 校验: 物理网口
    if ! is_phys_iface "$iface"; then
        err "$iface 不是物理网口, 跳过"
        continue
    fi
    # 校验: 不是 WAN
    if is_wan_iface "$iface"; then
        warn "$iface 是 WAN 口, 跳过"
        continue
    fi
    # 校验: 当前在 br-lan (不在说明已被拆出)
    if ! is_in_brlan "$iface"; then
        warn "$iface 不在 br-lan (可能已拆出), 跳过"
        continue
    fi
    # 校验: 还没有子网
    HAS_SUBNET=false
    if [ -n "$EXISTING_SUBNETS" ] && [ "$EXISTING_SUBNETS" != "[]" ]; then
        HAS=$(echo "$EXISTING_SUBNETS" | jq -r --arg iface "$iface" '[.[] | select(.interface == $iface)] | length')
        if [ "$HAS" -gt 0 ]; then HAS_SUBNET=true; fi
    fi
    if [ "$HAS_SUBNET" = "true" ]; then
        warn "$iface 已有子网, 跳过"
        continue
    fi

    # 分配 CIDR
    CIDR=$(allocate_cidr "$USED_CIDRS")
    if [ -z "$CIDR" ]; then
        err "$iface 无法分配 CIDR (网段已用完)"
        continue
    fi
    THIRD=$(echo "$CIDR" | grep -oE '192\.168\.[0-9]+' | cut -d. -f3)
    GATEWAY="192.168.$THIRD.1"
    USED_CIDRS="$USED_CIDRS $THIRD"
    UCI_NAME=$(uci_iface_name "$iface")
    ALLOCATED_COUNT=$((ALLOCATED_COUNT + 1))

    echo "  CIDR: $CIDR"
    echo "  网关: $GATEWAY"
    echo "  UCI 接口: $UCI_NAME"

    # 从 br-lan 移除 (安全红线在 safe_remove_from_brlan 内)
    if [ "$DRY_RUN" = "true" ]; then
        remaining=$(count_brlan_remaining "$iface")
        if [ "$remaining" = "0" ]; then
            warn "[dry-run] $iface 是 br-lan 最后一个成员, 真实执行将被拒绝"
        else
            exec_cmd "safe_remove_from_brlan '$iface'"
        fi
    else
        if ! safe_remove_from_brlan "$iface"; then
            err "无法从 br-lan 移除 $iface, 跳过该口"
            continue
        fi
    fi

    # 建 UCI 接口
    exec_cmd "create_uci_interface '$iface' '$UCI_NAME' '$GATEWAY'"

    # 写入 vps.db
    SUBNET_JSON="{\"name\":\"LAN-$iface\",\"interface\":\"$iface\",\"cidr\":\"$CIDR\",\"gateway\":\"$GATEWAY\"}"
    exec_cmd "add_subnet_to_db '$SUBNET_JSON'"

    # 检查 br-lan 是否还有成员
    REMAINING=$(count_brlan_remaining "$iface")
    if [ "$REMAINING" = "0" ]; then
        warn "br-lan 将无物理成员! br-lan IP 不可达, 但 SSH 通过子网网关仍可达"
    fi
done

echo ""
info "共分配 $ALLOCATED_COUNT 个子网"
echo ""

# --- 步骤 5: commit + reload ---
if [ "$DRY_RUN" = "true" ]; then
    echo -e "${YELLOW}=== dry-run 完成, 未修改任何配置 ===${NC}"
    echo ""
    echo "审核确认后, 执行:"
    echo "  1. 单口测试: init-subnets.sh --test <iface>"
    echo "  2. 全量执行: init-subnets.sh"
    echo ""
    echo "如需回滚: init-subnets.sh --rollback"
    exit 0
fi

if [ "$ALLOCATED_COUNT" = "0" ]; then
    ok "无需操作 (所有口已有子网或无可用口)"
    print_luci_urls
    exit 0
fi

info "步骤 5: commit + reload"
commit_and_reload

echo ""
info "等待网络重载 (15秒)..."
sleep 15

# --- 步骤 6: 验证 ---
info "步骤 6: 验证"
echo ""
echo "=== 网络接口状态 ==="
ip -br addr | grep -E "eth|br-lan"

echo ""
echo "=== br-lan 成员 ==="
brctl show br-lan 2>/dev/null

echo ""
echo "=== 子网列表 ==="
list_subnets_from_db | jq '.[] | {id, name, interface, cidr}' 2>/dev/null

echo ""
echo "=== SSH 监听 ==="
netstat -lnp 2>/dev/null | grep ":22 "

ok "初始化完成!"
print_luci_urls
echo ""
echo "如需回滚: init-subnets.sh --rollback"
