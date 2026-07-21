#!/bin/sh
# ================================================================
#  init-subnets.sh - 子网初始化脚本 (灾难级, 谨慎执行)
#
#  功能: 发现所有物理 LAN 口, 逐个拆出独立子网, 一次性 commit + reload
#
#  用法:
#    init-subnets.sh --dry-run          # 模拟, 输出调试日志, 不修改配置
#    init-subnets.sh --test <iface>     # 只拆一个口, 测试用
#    init-subnets.sh                    # 全量执行, 拆出所有 LAN 口
#    init-subnets.sh --rollback         # 回滚: 删除所有子网, 网口还回 br-lan
#
#  安全:
#    - 执行前自动备份 UCI 配置
#    - dry-run 模式不修改任何配置
#    - 先写完所有 UCI 配置, 最后统一 commit + reload
#    - dropbear 监听 0.0.0.0:22, 任意子网网关可 SSH
#
#  依赖: uci, jq, vps-db.sh
# ================================================================

set -uo pipefail

DB_FILE="/etc/sing-box/vps.db"
BACKUP_FILE="/tmp/network.bak.$(date +%Y%m%d_%H%M%S)"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()    { echo -e "${GREEN}✓ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $1${NC}"; }
err()   { echo -e "${RED}✗ $1${NC}"; }
info()  { echo -e "${CYAN}→ $1${NC}"; }
log()   { echo "[$(date '+%H:%M:%S')] $1"; }

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

# ---------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------

# 发现所有物理网口 (用 /sys/class/net/*/device 目录判断)
discover_phys_ifaces() {
    local ifaces=""
    for iface in $(ls /sys/class/net/ 2>/dev/null); do
        if [ -d "/sys/class/net/$iface/device" ]; then
            ifaces="$ifaces $iface"
        fi
    done
    echo "$ifaces" | tr ' ' '\n' | grep -v '^$' | tr '\n' ' ' | sed 's/^ //'
}

# 识别 WAN 口 (遍历 UCI network, 匹配 wan 相关的 ifname/device)
get_wan_iface() {
    local wan_ifname=""
    # 遍历所有 UCI interface section
    for section in $(uci show network 2>/dev/null | grep '=interface' | cut -d. -f2 | cut -d= -f1); do
        # section 名包含 wan
        if echo "$section" | grep -qi "wan"; then
            local ifname=$(uci get "network.$section.ifname" 2>/dev/null || uci get "network.$section.device" 2>/dev/null)
            if [ -n "$ifname" ]; then
                wan_ifname="$ifname"
                break
            fi
        fi
    done
    echo "$wan_ifname"
}

# 获取当前 br-lan 成员
get_brlan_members() {
    local ifname=$(uci get network.lan.ifname 2>/dev/null)
    echo "$ifname"
}

# CIDR 自动分配 (从 192.168.5 起递增, 跳过已占用)
# 参数: 已占用的第三段列表 (空格分隔)
allocate_cidr() {
    local used="$1"
    for i in $(seq 5 254); do
        local occupied=false
        for u in $used; do
            if [ "$u" = "$i" ]; then occupied=true; break; fi
        done
        if [ "$occupied" = "false" ]; then
            echo "192.168.$i.0/24"
            return
        fi
    done
    echo ""
}

# UCI 接口名 (eth0 -> lan0, eth2 -> lan2)
uci_iface_name() {
    echo "$1" | sed 's/eth/lan/'
}

# dry-run 模式下的模拟执行 (只打印命令)
DRY_RUN=false
exec_cmd() {
    if [ "$DRY_RUN" = "true" ]; then
        echo -e "  ${CYAN}[dry-run]${NC} $1"
    else
        eval "$1"
        if [ $? -ne 0 ]; then
            warn "命令失败: $1"
        fi
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

    # 备份
    info "备份 UCI 配置到 $BACKUP_FILE"
    exec_cmd "uci show network > $BACKUP_FILE"

    # 读取所有子网
    SUBNETS=$(vps-db.sh list-subnets 2>/dev/null)
    SUBNET_COUNT=$(echo "$SUBNETS" | jq 'length' 2>/dev/null)

    if [ "$SUBNET_COUNT" = "0" ] || [ -z "$SUBNET_COUNT" ]; then
        ok "无子网需要回滚"
        exit 0
    fi

    info "发现 $SUBNET_COUNT 个子网, 开始回滚..."

    # 逐个删除子网 (网口还回 br-lan)
    echo "$SUBNETS" | jq -c '.[]' 2>/dev/null | while read -r subnet_json; do
        SUB_ID=$(echo "$subnet_json" | jq -r '.id')
        SUB_IFACE=$(echo "$subnet_json" | jq -r '.interface')
        UCI_NAME=$(uci_iface_name "$SUB_IFACE")

        log "回滚子网 #$SUB_ID ($SUB_IFACE -> $UCI_NAME)"

        # 删 UCI 接口
        exec_cmd "uci delete network.$UCI_NAME"
        exec_cmd "uci delete dhcp.$UCI_NAME"
        exec_cmd "uci del_list firewall.@zone[0].network='$UCI_NAME'"

        # 网口还回 br-lan
        CURRENT_LAN_IFNAME=$(uci get network.lan.ifname 2>/dev/null)
        # 检查是否已在
        ALREADY_IN=false
        for part in $CURRENT_LAN_IFNAME; do
            if [ "$part" = "$SUB_IFACE" ]; then ALREADY_IN=true; break; fi
        done
        if [ "$ALREADY_IN" = "false" ]; then
            NEW_IFNAME="$CURRENT_LAN_IFNAME $SUB_IFACE"
            NEW_IFNAME=$(echo "$NEW_IFNAME" | sed 's/^ //')
            exec_cmd "uci set network.lan.ifname='$NEW_IFNAME'"
        fi

        # 删 vps.db 记录
        exec_cmd "vps-db.sh delete-subnet $SUB_ID"
    done

    # commit + reload
    info "commit + reload..."
    exec_cmd "uci commit network; uci commit dhcp; uci commit firewall"
    exec_cmd "(/etc/init.d/network reload; /etc/init.d/dnsmasq restart; /etc/init.d/firewall restart) >/tmp/subnet-rollback.log 2>&1 &"

    ok "回滚完成, 网络正在重载..."
    exit 0
fi

# --- dry-run 或 实际执行 (test/full 模式) ---

# 确定要处理的 LAN 口
if [ "$MODE" = "test" ]; then
    if [ -z "$TEST_IFACE" ]; then
        err "--test 需要指定网口, 如: init-subnets.sh --test eth0"
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

# --- 步骤 2: 备份 UCI 配置 ---
if [ "$DRY_RUN" = "false" ]; then
    info "步骤 2: 备份 UCI 配置到 $BACKUP_FILE"
    uci show network > "$BACKUP_FILE" 2>/dev/null
    ok "备份完成: $BACKUP_FILE"
    echo ""
else
    info "步骤 2: 备份 UCI 配置"
    echo -e "  ${CYAN}[dry-run]${NC} uci show network > $BACKUP_FILE"
    echo ""
fi

# --- 步骤 3: 收集已占用 CIDR ---
info "步骤 3: 收集已占用 CIDR"
USED_CIDRS=""

# br-lan 网段
BRLAN_IP=$(uci get network.lan.ipaddr 2>/dev/null)
if [ -n "$BRLAN_IP" ]; then
    BRLAN_THIRD=$(echo "$BRLAN_IP" | cut -d. -f3)
    USED_CIDRS="$USED_CIDRS $BRLAN_THIRD"
    echo "  br-lan 网段: 192.168.$BRLAN_THIRD.0/24"
fi

# 已有子网
EXISTING_SUBNETS=$(vps-db.sh list-subnets 2>/dev/null)
if [ -n "$EXISTING_SUBNETS" ] && [ "$EXISTING_SUBNETS" != "[]" ]; then
    echo "$EXISTING_SUBNETS" | jq -c '.[]' 2>/dev/null | while read -r sub; do
        CIDR=$(echo "$sub" | jq -r '.cidr')
        IFACE=$(echo "$sub" | jq -r '.interface')
        THIRD=$(echo "$CIDR" | grep -oE '192\.168\.[0-9]+' | cut -d. -f3)
        echo "  已有子网: $CIDR ($IFACE)"
    done
    # 收集到 USED_CIDRS (需要子 shell)
    USED_CIDRS="$USED_CIDRS $(echo "$EXISTING_SUBNETS" | jq -r '.[].cidr' | grep -oE '192\.168\.[0-9]+' | cut -d. -f3 | tr '\n' ' ')"
fi
echo "  已占用网段: $USED_CIDRS"
echo ""

# --- 步骤 4: 逐口写 UCI 配置 ---
info "步骤 4: 逐口写 UCI 配置 (不 commit)"

# 跟踪 br-lan ifname 的变化
CURRENT_BRLAN_IFNAME="$BRLAN_MEMBERS"
ALLOCATED_COUNT=0

for iface in $TARGET_IFACES; do
    echo ""
    log "处理 $iface:"

    # 检查是否已有子网
    HAS_SUBNET=false
    if [ -n "$EXISTING_SUBNETS" ] && [ "$EXISTING_SUBNETS" != "[]" ]; then
        HAS=$(echo "$EXISTING_SUBNETS" | jq -r --arg iface "$iface" '[.[] | select(.interface == $iface)] | length')
        if [ "$HAS" -gt 0 ]; then
            HAS_SUBNET=true
        fi
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

    # 从 br-lan 移除
    NEW_BRLAN_IFNAME=""
    for part in $CURRENT_BRLAN_IFNAME; do
        if [ "$part" != "$iface" ]; then
            if [ -z "$NEW_BRLAN_IFNAME" ]; then
                NEW_BRLAN_IFNAME="$part"
            else
                NEW_BRLAN_IFNAME="$NEW_BRLAN_IFNAME $part"
            fi
        fi
    done
    CURRENT_BRLAN_IFNAME="$NEW_BRLAN_IFNAME"

    echo "  br-lan 移除 $iface 后: '$CURRENT_BRLAN_IFNAME'"

    exec_cmd "uci set network.lan.ifname='$CURRENT_BRLAN_IFNAME'"

    # 建 UCI 接口
    exec_cmd "uci set network.$UCI_NAME=interface"
    exec_cmd "uci set network.$UCI_NAME.proto='static'"
    exec_cmd "uci set network.$UCI_NAME.ifname='$iface'"
    exec_cmd "uci set network.$UCI_NAME.ipaddr='$GATEWAY'"
    exec_cmd "uci set network.$UCI_NAME.netmask='255.255.255.0'"

    # DHCP 池
    exec_cmd "uci set dhcp.$UCI_NAME=dhcp"
    exec_cmd "uci set dhcp.$UCI_NAME.interface='$UCI_NAME'"
    exec_cmd "uci set dhcp.$UCI_NAME.start='100'"
    exec_cmd "uci set dhcp.$UCI_NAME.limit='50'"
    exec_cmd "uci set dhcp.$UCI_NAME.leasetime='12h'"

    # 防火墙
    exec_cmd "uci add_list firewall.@zone[0].network='$UCI_NAME'"

    # vps.db
    SUBNET_JSON="{\"name\":\"LAN-$iface\",\"interface\":\"$iface\",\"cidr\":\"$CIDR\",\"gateway\":\"$GATEWAY\"}"
    exec_cmd "vps-db.sh add-subnet '$SUBNET_JSON'"

    # 检查 br-lan 是否还有成员
    REMAINING=0
    for part in $CURRENT_BRLAN_IFNAME; do
        REMAINING=$((REMAINING + 1))
    done
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
    ok "无需操作 (所有口已有子网)"
    exit 0
fi

info "步骤 5: commit + reload"
exec_cmd "uci commit network; uci commit dhcp; uci commit firewall"
exec_cmd "(/etc/init.d/network reload; /etc/init.d/dnsmasq restart; /etc/init.d/firewall restart) >/tmp/subnet-init.log 2>&1 &"

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
vps-db.sh list-subnets 2>/dev/null | jq '.[] | {id, name, interface, cidr}' 2>/dev/null

echo ""
echo "=== SSH 监听 ==="
netstat -lnp 2>/dev/null | grep ":22 "

echo ""
ok "初始化完成!"
echo ""
echo "如需回滚: init-subnets.sh --rollback"
