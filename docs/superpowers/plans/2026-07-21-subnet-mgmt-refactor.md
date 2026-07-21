# 子网管理脚本化重构 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将子网网络层操作(增删改)从 LuCI API 彻底剥离到独立 SSH 脚本,controller 只保留只读展示 + 链路换绑;`init-subnets.sh` 执行完打印可访问的 LuCI URL。

**Architecture:** 6 个 shell 脚本(1 共享库 + 5 业务脚本)承担所有会断网的操作,通过 `vps-db.sh` 读写 SQLite;LuCI controller 删除 6 个网络层函数和 4 个路由,保留只读 + bind/unbind;前端 vps.htm 清理残留 URL 常量。

**Tech Stack:** POSIX shell (OpenWrt ash)、jq、uci、Lua (LuCI controller)、HTML/JS (LuCI view)

**参考文档:** `docs/superpowers/specs/2026-07-21-subnet-mgmt-refactor-design.md`

---

## 文件结构

### 新建文件

| 文件 | 职责 |
|------|------|
| `openwrt/scripts/_subnet-lib.sh` | 共享库,被其他脚本 source,提供发现网口/分配 CIDR/UCI 操作/DB 操作/打印 LuCI URL 等函数 |
| `openwrt/scripts/subnet-add.sh` | 单个创建:拆口+建接口+入库 |
| `openwrt/scripts/subnet-del.sh` | 单个删除:删接口+网口还 br-lan+删库 |
| `openwrt/scripts/subnet-list.sh` | 列出所有子网(表格) |
| `openwrt/scripts/subnet-inspect.sh` | 查看单个子网详情+实时状态+DHCP 租约+ARP |

### 修改文件

| 文件 | 改动 |
|------|------|
| `openwrt/scripts/init-subnets.sh` | 重构为复用 `_subnet-lib.sh`,末尾打印 LuCI URL |
| `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua` | 删 6 个函数(`apply_subnet_network`/`revert_subnet_network`/`action_subnets_get/add/update/delete`)+ 4 个路由注册 |
| `openwrt/luci/view/tiktokproxy/vps.htm` | 删 4 个残留 URL 常量(`SUB_GET/ADD/UPD/DEL_URL`) |
| `README.md` | 新增"子网管理"章节 |
| `AGENTS.md` | 部署路径表追加 5 个新脚本 |

---

## Task 1: 共享库 `_subnet-lib.sh`

**Files:**
- Create: `openwrt/scripts/_subnet-lib.sh`

- [ ] **Step 1: 写共享库**

完整内容:

```sh
#!/bin/sh
# ================================================================
#  _subnet-lib.sh - 子网管理共享库
#
#  定位: 被 init-subnets.sh / subnet-add.sh / subnet-del.sh /
#        subnet-list.sh / subnet-inspect.sh source 引入, 不直接执行
#
#  提供: 物理网口发现 / WAN 识别 / br-lan 管理 / CIDR 分配 /
#        UCI 接口三件套(network+dhcp+firewall) / vps.db 读写 /
#        LuCI URL 打印 / UCI 备份
# ================================================================

# ---------------------------------------------------------------
# 颜色 + 日志 (被 source 时不要 set -e, 让调用方控制)
# ---------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()    { echo -e "${GREEN}✓ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠ $1${NC}"; }
err()   { echo -e "${RED}✗ $1${NC}" >&2; }
info()  { echo -e "${CYAN}-> $1${NC}"; }
log()   { echo "[$(date '+%H:%M:%S')] $1"; }

# ---------------------------------------------------------------
# 物理网口发现
# ---------------------------------------------------------------

# 发现所有物理网口 (用 /sys/class/net/*/device 目录判断)
# 输出: 空格分隔的网口名, 如 "eth0 eth1 eth2"
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
# 输出: 单个网口名, 如 "eth1"; 找不到则输出空
get_wan_iface() {
    local wan_ifname=""
    for section in $(uci show network 2>/dev/null | grep '=interface' | cut -d. -f2 | cut -d= -f1); do
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

# 获取 br-lan 当前成员 (读 network.lan.ifname)
# 输出: 空格分隔的网口名
get_brlan_members() {
    uci get network.lan.ifname 2>/dev/null
}

# ---------------------------------------------------------------
# CIDR 分配
# ---------------------------------------------------------------

# 从 192.168.5 起递增分配 /24, 跳过已占用
# 参数: $1 = 已占用的第三段列表 (空格分隔), 如 "5 6"
# 输出: "192.168.X.0/24" 或空 (用完)
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

# UCI 接口名转换: eth0 -> lan0, eth2 -> lan2
# 参数: $1 = 物理网口名
uci_iface_name() {
    echo "$1" | sed 's/eth/lan/'
}

# ---------------------------------------------------------------
# br-lan 成员管理 (含安全红线)
# ---------------------------------------------------------------

# 计算 br-lan 移除某口后剩余成员数
# 参数: $1 = 要排除的网口名
# 输出: 数字
count_brlan_remaining() {
    local exclude="$1"
    local lan_ifname=$(get_brlan_members)
    local count=0
    for part in $lan_ifname; do
        if [ "$part" != "$exclude" ]; then count=$((count + 1)); fi
    done
    echo "$count"
}

# 安全红线: 从 br-lan 移除网口, 拒绝移除最后一个成员
# 参数: $1 = 要移除的网口名
# 返回: 0 成功 (已执行 uci set), 1 失败 (最后一个成员或出错)
# 注意: 调用方需自行 commit
safe_remove_from_brlan() {
    local iface="$1"
    if [ -z "$iface" ]; then
        err "safe_remove_from_brlan: iface 为空"
        return 1
    fi
    local remaining=$(count_brlan_remaining "$iface")
    if [ "$remaining" = "0" ]; then
        err "$iface 是 br-lan 最后一个成员, 拆出后 br-lan 将无物理口, 拒绝操作"
        warn "如确需拆出, 请先用 subnet-add.sh 拆另一个口, 或 init-subnets.sh --rollback 回滚所有"
        return 1
    fi
    local lan_ifname=$(get_brlan_members)
    local new_ifname=""
    for part in $lan_ifname; do
        if [ "$part" != "$iface" ]; then
            if [ -z "$new_ifname" ]; then
                new_ifname="$part"
            else
                new_ifname="$new_ifname $part"
            fi
        fi
    done
    uci set network.lan.ifname="$new_ifname"
    log "br-lan ifname 旧='$lan_ifname' 新='$new_ifname'"
    return 0
}

# 网口还回 br-lan (append, 无需安全检查, 还回不会让 br-lan 变空)
# 参数: $1 = 要还回的网口名
# 注意: 调用方需自行 commit
return_to_brlan() {
    local iface="$1"
    if [ -z "$iface" ]; then
        err "return_to_brlan: iface 为空"
        return 1
    fi
    local lan_ifname=$(get_brlan_members)
    # 检查是否已在
    local already_in=false
    for part in $lan_ifname; do
        if [ "$part" = "$iface" ]; then already_in=true; break; fi
    done
    if [ "$already_in" = "true" ]; then
        log "$iface 已在 br-lan, 跳过"
        return 0
    fi
    local new_ifname
    if [ -z "$lan_ifname" ]; then
        new_ifname="$iface"
    else
        new_ifname="$lan_ifname $iface"
    fi
    uci set network.lan.ifname="$new_ifname"
    log "br-lan ifname 旧='$lan_ifname' 新='$new_ifname'"
    return 0
}

# ---------------------------------------------------------------
# UCI 接口三件套 (network + dhcp + firewall)
# ---------------------------------------------------------------

# 创建 UCI 接口 + DHCP 池 + 防火墙 (加入 lan zone)
# 参数: $1=物理网口 $2=UCI接口名(lan0) $3=网关IP(192.168.6.1)
# 注意: 调用方需自行 commit
create_uci_interface() {
    local iface="$1"
    local uci_name="$2"
    local gateway="$3"
    if [ -z "$iface" ] || [ -z "$uci_name" ] || [ -z "$gateway" ]; then
        err "create_uci_interface: 参数缺失 (iface=$iface uci_name=$uci_name gateway=$gateway)"
        return 1
    fi
    # network
    uci set network.$uci_name=interface
    uci set network.$uci_name.proto='static'
    uci set network.$uci_name.ifname="$iface"
    uci set network.$uci_name.ipaddr="$gateway"
    uci set network.$uci_name.netmask='255.255.255.0'
    # dhcp
    uci set dhcp.$uci_name=dhcp
    uci set dhcp.$uci_name.interface="$uci_name"
    uci set dhcp.$uci_name.start='100'
    uci set dhcp.$uci_name.limit='50'
    uci set dhcp.$uci_name.leasetime='12h'
    # firewall (lan zone = @zone[0])
    uci add_list firewall.@zone[0].network="$uci_name"
    log "创建 UCI 接口 $uci_name (iface=$iface gw=$gateway) + DHCP + firewall"
    return 0
}

# 删除 UCI 接口 + DHCP + 防火墙
# 参数: $1=UCI接口名(lan0)
# 注意: 调用方需自行 commit
remove_uci_interface() {
    local uci_name="$1"
    if [ -z "$uci_name" ]; then
        err "remove_uci_interface: uci_name 为空"
        return 1
    fi
    uci delete network.$uci_name 2>/dev/null
    uci delete dhcp.$uci_name 2>/dev/null
    uci del_list firewall.@zone[0].network="$uci_name" 2>/dev/null
    log "删除 UCI 接口 $uci_name + DHCP + firewall"
    return 0
}

# commit + 后台 reload (同步 reload 会断 SSH, 放后台)
commit_and_reload() {
    uci commit network
    uci commit dhcp
    uci commit firewall
    (/etc/init.d/network reload; /etc/init.d/dnsmasq restart; /etc/init.d/firewall restart) >/tmp/subnet-reload.log 2>&1 &
    log "commit + reload 后台执行中"
}

# ---------------------------------------------------------------
# vps.db 读写 (依赖 vps-db.sh)
# ---------------------------------------------------------------

# 添加子网到 db
# 参数: $1 = JSON 字符串, 如 {"name":"LAN-eth0","interface":"eth0","cidr":"192.168.6.0/24","gateway":"192.168.6.1"}
# 输出: vps-db.sh 的输出 (含 id)
add_subnet_to_db() {
    vps-db.sh add-subnet "$1"
}

# 按 id 或 iface 删除子网
# 参数: $1 = id (数字) 或 iface (eth0)
delete_subnet_from_db() {
    local key="$1"
    # 如果是纯数字, 按 id 删
    if echo "$key" | grep -qE '^[0-9]+$'; then
        vps-db.sh delete-subnet "$key"
    else
        # 按 iface 查 id 再删
        local id=$(vps-db.sh list-subnets 2>/dev/null | jq -r --arg iface "$key" '.[] | select(.interface == $iface) | .id' 2>/dev/null | head -1)
        if [ -z "$id" ]; then
            err "delete_subnet_from_db: 找不到 interface=$key 的子网"
            return 1
        fi
        vps-db.sh delete-subnet "$id"
    fi
}

# 列出所有子网 (JSON)
list_subnets_from_db() {
    vps-db.sh list-subnets 2>/dev/null
}

# 按 id 或 iface 查单个子网 (JSON)
# 参数: $1 = id 或 iface
get_subnet_from_db() {
    local key="$1"
    if echo "$key" | grep -qE '^[0-9]+$'; then
        vps-db.sh get-subnet "$key" 2>/dev/null
    else
        vps-db.sh list-subnets 2>/dev/null | jq -c --arg iface "$key" '.[] | select(.interface == $iface)' 2>/dev/null | head -1
    fi
}

# ---------------------------------------------------------------
# UCI 备份
# ---------------------------------------------------------------

# 备份 UCI network 配置到 /tmp/network.bak.<timestamp>
# 输出: 备份文件路径
backup_uci() {
    local bak="/tmp/network.bak.$(date +%Y%m%d_%H%M%S)"
    uci show network > "$bak" 2>/dev/null
    uci show dhcp > "$bak.dhcp" 2>/dev/null
    uci show firewall > "$bak.firewall" 2>/dev/null
    echo "$bak"
}

# ---------------------------------------------------------------
# LuCI URL 打印
# ---------------------------------------------------------------

# 打印所有可访问的 LuCI URL (br-lan IP + 所有子网网关)
print_luci_urls() {
    echo ""
    echo -e "${GREEN}可访问的 LuCI 地址:${NC}"
    # br-lan IP (如果有物理成员)
    local brlan_ip=$(uci get network.lan.ipaddr 2>/dev/null)
    local brlan_members=$(get_brlan_members)
    if [ -n "$brlan_ip" ] && [ -n "$brlan_members" ]; then
        # 去掉 CIDR 后缀 (如果有)
        local ip_only=$(echo "$brlan_ip" | cut -d/ -f1)
        echo "  http://$ip_only/cgi-bin/luci"
    fi
    # 所有子网网关
    local subnets=$(list_subnets_from_db)
    if [ -n "$subnets" ] && [ "$subnets" != "[]" ]; then
        echo "$subnets" | jq -r '.[].gateway' 2>/dev/null | while read -r gw; do
            if [ -n "$gw" ]; then
                echo "  http://$gw/cgi-bin/luci"
            fi
        done
    fi
    echo ""
    echo -e "${GREEN}SSH 管理:${NC}"
    if [ -n "$brlan_ip" ] && [ -n "$brlan_members" ]; then
        local ip_only=$(echo "$brlan_ip" | cut -d/ -f1)
        echo "  ssh root@$ip_only"
    fi
    if [ -n "$subnets" ] && [ "$subnets" != "[]" ]; then
        echo "$subnets" | jq -r '.[].gateway' 2>/dev/null | while read -r gw; do
            if [ -n "$gw" ]; then
                echo "  ssh root@$gw"
            fi
        done
    fi
}

# ---------------------------------------------------------------
# 校验工具
# ---------------------------------------------------------------

# 校验网口是物理网口
# 参数: $1 = 网口名
# 返回: 0 是物理网口, 1 不是
is_phys_iface() {
    [ -d "/sys/class/net/$1/device" ]
}

# 校验网口是 WAN 口
# 参数: $1 = 网口名
# 返回: 0 是 WAN, 1 不是
is_wan_iface() {
    local wan=$(get_wan_iface)
    [ "$1" = "$wan" ]
}

# 校验网口当前在 br-lan 成员里
# 参数: $1 = 网口名
# 返回: 0 在, 1 不在
is_in_brlan() {
    local iface="$1"
    for part in $(get_brlan_members); do
        [ "$part" = "$iface" ] && return 0
    done
    return 1
}
```

- [ ] **Step 2: 语法校验**

Run: `sh -n openwrt/scripts/_subnet-lib.sh`
Expected: 无输出 (语法正确)

- [ ] **Step 3: shellcheck 静态检查 (如可用)**

Run: `shellcheck openwrt/scripts/_subnet-lib.sh 2>&1 | head -20 || echo "shellcheck 不可用, 跳过"`
Expected: 无严重 error,或提示 shellcheck 未安装

- [ ] **Step 4: Commit**

```bash
git add openwrt/scripts/_subnet-lib.sh
git commit -m "feat: 添加子网管理共享库 _subnet-lib.sh

提供物理网口发现/WAN识别/br-lan管理(含最后成员保护)/CIDR分配/
UCI三件套创建删除/vps.db读写/UCI备份/LuCI URL打印等函数,
被 init-subnets/subnet-add/del/list/inspect 5 个脚本 source 引入"
```

---

## Task 2: 重构 `init-subnets.sh`

**Files:**
- Modify: `openwrt/scripts/init-subnets.sh` (整体重写,复用共享库)

- [ ] **Step 1: 重写 init-subnets.sh**

完整内容:

```sh
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
```

- [ ] **Step 2: 语法校验**

Run: `sh -n openwrt/scripts/init-subnets.sh`
Expected: 无输出

- [ ] **Step 3: shellcheck (如可用)**

Run: `shellcheck openwrt/scripts/init-subnets.sh 2>&1 | head -20 || echo "shellcheck 不可用, 跳过"`
Expected: 无严重 error

- [ ] **Step 4: Commit**

```bash
git add openwrt/scripts/init-subnets.sh
git commit -m "refactor: init-subnets.sh 复用 _subnet-lib.sh + 末尾打印 LuCI URL

- 移除内联的 discover_phys_ifaces/get_wan_iface/allocate_cidr 等函数, 改为 source 共享库
- 复用 safe_remove_from_brlan (含最后成员保护) / create_uci_interface / commit_and_reload
- 执行完调用 print_luci_urls 打印所有可访问的 LuCI 地址 + SSH 命令
- dry-run/test/full/rollback 四种模式逻辑不变"
```

---

## Task 3: `subnet-add.sh` (单个创建)

**Files:**
- Create: `openwrt/scripts/subnet-add.sh`

- [ ] **Step 1: 写脚本**

完整内容:

```sh
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
```

- [ ] **Step 2: 语法校验**

Run: `sh -n openwrt/scripts/subnet-add.sh`
Expected: 无输出

- [ ] **Step 3: Commit**

```bash
git add openwrt/scripts/subnet-add.sh
git commit -m "feat: 添加 subnet-add.sh 单个子网创建脚本

用法: subnet-add.sh <iface> [--name <name>] [--cidr <cidr>] [--dry-run]
- 校验物理网口/WAN/br-lan成员/已有子网/最后成员保护
- 支持 --dry-run 预演
- 失败时自动回滚 UCI 和 DB
- 末尾打印 LuCI URL"
```

---

## Task 4: `subnet-del.sh` (单个删除)

**Files:**
- Create: `openwrt/scripts/subnet-del.sh`

- [ ] **Step 1: 写脚本**

完整内容:

```sh
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
```

- [ ] **Step 2: 语法校验**

Run: `sh -n openwrt/scripts/subnet-del.sh`
Expected: 无输出

- [ ] **Step 3: Commit**

```bash
git add openwrt/scripts/subnet-del.sh
git commit -m "feat: 添加 subnet-del.sh 单个子网删除脚本

用法: subnet-del.sh <iface|subnet_id> [--dry-run]
- 支持按网口名或子网 ID 删除
- 删 UCI 接口+DHCP+防火墙, 网口还回 br-lan, 删 vps.db 记录
- 支持 --dry-run 预演
- 末尾打印剩余可访问 LuCI URL"
```

---

## Task 5: `subnet-list.sh` (列出所有子网)

**Files:**
- Create: `openwrt/scripts/subnet-list.sh`

- [ ] **Step 1: 写脚本**

完整内容:

```sh
#!/bin/sh
# ================================================================
#  subnet-list.sh - 列出所有子网 (不会断网, SSH 执行)
#
#  功能: 以表格形式列出 vps.db 中所有子网, 含链路名映射
#
#  用法:
#    subnet-list.sh                # 表格形式
#    subnet-list.sh --json         # JSON 原始输出
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

OUTPUT_FORMAT="table"
[ "$1" = "--json" ] 2>/dev/null && OUTPUT_FORMAT="json"

SUBNETS=$(list_subnets_from_db)
CHAINS=$(vps-db.sh list-chains 2>/dev/null)

if [ "$OUTPUT_FORMAT" = "json" ]; then
    # JSON 输出: 把 chain_id 映射成 chain_name
    echo "$SUBNETS" | jq -c --argjson chains "$CHAINS" '
        map(. + {
            chain_name: (.chain_id as $cid | $chains | map(select(.id == $cid)) | .[0].name // "未绑定")
        })
    ' 2>/dev/null
    exit 0
fi

# 表格输出
SUB_COUNT=$(echo "$SUBNETS" | jq 'length' 2>/dev/null)
if [ -z "$SUB_COUNT" ] || [ "$SUB_COUNT" = "0" ]; then
    echo "无子网"
    echo ""
    echo "创建子网: subnet-add.sh <iface>"
    echo "批量初始化: init-subnets.sh --dry-run"
    exit 0
fi

echo "共 $SUB_COUNT 个子网:"
echo ""
# 表头
printf "%-4s %-12s %-12s %-20s %-16s %-20s\n" "ID" "NAME" "INTERFACE" "CIDR" "GATEWAY" "CHAIN"
printf "%-4s %-12s %-12s %-20s %-16s %-20s\n" "--" "----" "---------" "----" "-------" "-----"

echo "$SUBNETS" | jq -c '.[]' 2>/dev/null | while read -r sub; do
    ID=$(echo "$sub" | jq -r '.id')
    NAME=$(echo "$sub" | jq -r '.name')
    IFACE=$(echo "$sub" | jq -r '.interface')
    CIDR=$(echo "$sub" | jq -r '.cidr')
    GW=$(echo "$sub" | jq -r '.gateway')
    CHAIN_ID=$(echo "$sub" | jq -r '.chain_id // empty')
    CHAIN_NAME="未绑定"
    if [ -n "$CHAIN_ID" ]; then
        CHAIN_NAME=$(echo "$CHAINS" | jq -r --argjson cid "$CHAIN_ID" '.[] | select(.id == $cid) | .name' 2>/dev/null | head -1)
        [ -z "$CHAIN_NAME" ] && CHAIN_NAME="未绑定(id=$CHAIN_ID)"
    fi
    # 截断长名字
    [ ${#NAME} -gt 12 ] && NAME="${NAME:0:11}.."
    [ ${#CHAIN_NAME} -gt 20 ] && CHAIN_NAME="${CHAIN_NAME:0:19}.."
    printf "%-4s %-12s %-12s %-20s %-16s %-20s\n" "$ID" "$NAME" "$IFACE" "$CIDR" "$GW" "$CHAIN_NAME"
done

echo ""
echo "查看详情: subnet-inspect.sh <iface|id>"
echo "创建子网: subnet-add.sh <iface>"
echo "删除子网: subnet-del.sh <iface|id>"
```

- [ ] **Step 2: 语法校验**

Run: `sh -n openwrt/scripts/subnet-list.sh`
Expected: 无输出

- [ ] **Step 3: Commit**

```bash
git add openwrt/scripts/subnet-list.sh
git commit -m "feat: 添加 subnet-list.sh 列出所有子网脚本

用法: subnet-list.sh [--json]
- 默认表格输出 (ID/NAME/INTERFACE/CIDR/GATEWAY/CHAIN)
- --json 输出原始 JSON (含 chain_name 映射)
- 无子网时提示创建命令"
```

---

## Task 6: `subnet-inspect.sh` (查看单个详情)

**Files:**
- Create: `openwrt/scripts/subnet-inspect.sh`

- [ ] **Step 1: 写脚本**

完整内容:

```sh
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
    [ -z "$SPEED" ] || [ "$CARRIER" = "0" ] && SPEED="-"
    [ -z "$DUPLEX" ] || [ "$CARRIER" = "0" ] && DUPLEX="-"
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
ARP_COUNT=0
ip neigh show 2>/dev/null | while IFS= read -r line; do
    IP=$(echo "$line" | awk '{print $1}')
    if echo "$IP" | grep -q "^192\.168\.$SUB_THIRD\."; then
        STATE=$(echo "$line" | grep -oE 'REACHABLE|STALE|FAILED|DELAY|PERMANENT')
        [ -z "$STATE" ] && STATE="UNKNOWN"
        echo "  $IP  $STATE"
    fi
done | tee /tmp/arp_tmp.$$
ARP_COUNT=$(wc -l < /tmp/arp_tmp.$$ 2>/dev/null)
rm -f /tmp/arp_tmp.$$
[ "$ARP_COUNT" = "0" ] && echo "  (无邻居)"
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
```

- [ ] **Step 2: 语法校验**

Run: `sh -n openwrt/scripts/subnet-inspect.sh`
Expected: 无输出

- [ ] **Step 3: Commit**

```bash
git add openwrt/scripts/subnet-inspect.sh
git commit -m "feat: 添加 subnet-inspect.sh 查看单个子网详情脚本

用法: subnet-inspect.sh <iface|subnet_id>
- 显示子网 DB 记录 (id/name/interface/cidr/gateway/chain)
- 显示物理网口实时状态 (carrier/speed/duplex/MAC/IP)
- 显示本子网 DHCP 租约
- 显示本子网 ARP 邻居
- 检查 br-lan 桥成员一致性"
```

---

## Task 7: 清理 controller `tiktokproxy.lua`

**Files:**
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`

- [ ] **Step 1: 删除 4 个路由注册 (525-528 行)**

用 Edit 工具,old_string 为:

```
    entry({"admin", "services", "tiktokproxy", "subnets_list"}, call("action_subnets_list"))
    entry({"admin", "services", "tiktokproxy", "network_topology"}, call("action_network_topology"))
    entry({"admin", "services", "tiktokproxy", "subnets_get"}, call("action_subnets_get"))
    entry({"admin", "services", "tiktokproxy", "subnets_add"}, call("action_subnets_add"))
    entry({"admin", "services", "tiktokproxy", "subnets_update"}, call("action_subnets_update"))
    entry({"admin", "services", "tiktokproxy", "subnets_delete"}, call("action_subnets_delete"))
    entry({"admin", "services", "tiktokproxy", "subnets_bind"}, call("action_subnets_bind"))
    entry({"admin", "services", "tiktokproxy", "subnets_unbind"}, call("action_subnets_unbind"))
    entry({"admin", "services", "tiktokproxy", "interfaces_list"}, call("action_interfaces_list"))
```

new_string 为:

```
    entry({"admin", "services", "tiktokproxy", "subnets_list"}, call("action_subnets_list"))
    entry({"admin", "services", "tiktokproxy", "network_topology"}, call("action_network_topology"))
    entry({"admin", "services", "tiktokproxy", "subnets_bind"}, call("action_subnets_bind"))
    entry({"admin", "services", "tiktokproxy", "subnets_unbind"}, call("action_subnets_unbind"))
    entry({"admin", "services", "tiktokproxy", "interfaces_list"}, call("action_interfaces_list"))
```

- [ ] **Step 2: 删除 `action_subnets_get` 函数 (1313-1325 行)**

用 Edit 工具,old_string 为:

```lua
function action_subnets_get()
    local id = luci.http.formvalue("id") or ""
    log_api("subnets_get", "id=" .. id)
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    local output = db_cmd("get-subnet " .. id)
    local data = parse_json(output) or {}
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
```

new_string 为空字符串 (即删除整段)。

- [ ] **Step 3: 删除 `action_subnets_add` 函数 (1333-1388 行)**

用 Edit 工具,old_string 为整个 `action_subnets_add` 函数 (从 `function action_subnets_add()` 到对应的 `end`),new_string 为空。

- [ ] **Step 4: 删除 `action_subnets_update` 函数 (1389-1428 行)**

用 Edit 工具,old_string 为整个 `action_subnets_update` 函数,new_string 为空。

- [ ] **Step 5: 删除 `action_subnets_delete` 函数 (1429-1455 行)**

用 Edit 工具,old_string 为整个 `action_subnets_delete` 函数,new_string 为空。

- [ ] **Step 6: 删除 `apply_subnet_network` 函数 (167-227 行)**

用 Edit 工具,old_string 为整个 `apply_subnet_network` 函数 (从注释 `-- 为子网配置网络:` 到 `end`),new_string 为空。

- [ ] **Step 7: 删除 `revert_subnet_network` 函数 (228-265 行附近)**

用 Edit 工具,old_string 为整个 `revert_subnet_network` 函数,new_string 为空。

- [ ] **Step 8: Lua 语法校验**

Run: `lua5.1 -e 'loadfile("openwrt/luci/controller/tiktokproxy/tiktokproxy.lua")' 2>&1 || luac5.1 -p openwrt/luci/controller/tiktokproxy/tiktokproxy.lua 2>&1 || echo "lua 不在本地, 跳过语法校验, 部署后软路由上用 lua -p 校验"`
Expected: 无语法错误

- [ ] **Step 9: 确认无残留引用**

Run: `grep -n "apply_subnet_network\|revert_subnet_network\|action_subnets_add\|action_subnets_update\|action_subnets_delete\|action_subnets_get" openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
Expected: 无输出 (所有引用都已删除)

- [ ] **Step 10: Commit**

```bash
git add openwrt/luci/controller/tiktokproxy/tiktokproxy.lua
git commit -m "refactor: controller 删除子网增删改逻辑, 网络层操作挪到脚本

删除 6 个函数:
- apply_subnet_network / revert_subnet_network (网络层操作, 挪到 subnet-add/del.sh)
- action_subnets_get / add / update / delete (API 入口)

删除 4 个路由注册: subnets_get/add/update/delete

保留: action_network_topology / action_subnets_list /
      action_interfaces_list (只读展示)
      action_subnets_bind / unbind (页面换绑链路, 不会断网)

符合设计: 脚本是子网网络层操作唯一真相源, 网页只读+换绑"
```

---

## Task 8: 清理 vps.htm 残留 URL 常量

**Files:**
- Modify: `openwrt/luci/view/tiktokproxy/vps.htm` (134-138 行)

- [ ] **Step 1: 删除 4 个残留 URL 常量**

用 Edit 工具,old_string 为:

```
var SUB_LIST_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_list")%>';
var SUB_GET_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_get")%>';
var SUB_ADD_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_add")%>';
var SUB_UPD_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_update")%>';
var SUB_DEL_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_delete")%>';
var SUB_BIND_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_bind")%>';
var SUB_UNBIND_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_unbind")%>';
```

new_string 为:

```
var SUB_LIST_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_list")%>';
var SUB_BIND_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_bind")%>';
var SUB_UNBIND_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","subnets_unbind")%>';
```

- [ ] **Step 2: 确认无残留引用**

Run: `grep -n "SUB_GET_URL\|SUB_ADD_URL\|SUB_UPD_URL\|SUB_DEL_URL" openwrt/luci/view/tiktokproxy/vps.htm`
Expected: 无输出

- [ ] **Step 3: Commit**

```bash
git add openwrt/luci/view/tiktokproxy/vps.htm
git commit -m "chore: vps.htm 删除已废弃的子网增删改 URL 常量

删除 SUB_GET_URL / SUB_ADD_URL / SUB_UPD_URL / SUB_DEL_URL
(对应的后端 API 已在上一 commit 删除)
保留 SUB_LIST_URL (只读) / SUB_BIND_URL / SUB_UNBIND_URL (换绑链路)"
```

---

## Task 9: 更新 README.md

**Files:**
- Modify: `README.md` (末尾追加章节)

- [ ] **Step 1: 追加子网管理章节**

用 Edit 工具,old_string 为 README.md 最后一节 `## License` 的开头:

```
## License

MIT
```

new_string 为:

```
## 子网管理

子网的**网络层操作**(创建/删除)会断网, 只能通过 SSH 脚本执行, 不能在网页操作。
网页只负责展示子网状态 + 绑定/解绑链路(不会断网)。

### 脚本一览

部署到软路由 `/usr/bin/` 下, 本地源码在 `openwrt/scripts/`。

| 脚本 | 功能 | 会断网 |
|------|------|--------|
| `init-subnets.sh` | 批量初始化所有 LAN 口 / 回滚 | 是 |
| `subnet-add.sh <iface>` | 单个口拆出子网 | 是 |
| `subnet-del.sh <iface\|id>` | 删子网, 网口还回 br-lan | 是 |
| `subnet-list.sh` | 列出所有子网 | 否 |
| `subnet-inspect.sh <iface\|id>` | 查看单个子网详情 | 否 |

所有写操作共享 `_subnet-lib.sh` 库, 提供物理网口发现/CIDR 分配/UCI 操作/最后成员保护等公共函数。

### 典型流程

1. **系统初始化** (一次性):
   ```sh
   init-subnets.sh --dry-run        # 审核将要做什么
   init-subnets.sh --test eth0      # 单口测试
   init-subnets.sh                  # 全量执行
   ```
   执行完会打印所有可访问的 LuCI URL (如 `http://192.168.6.1/cgi-bin/luci`)。

2. **后期新增子网** (远程 SSH):
   ```sh
   subnet-add.sh eth3 --dry-run     # 预演
   subnet-add.sh eth3               # 执行
   ```

3. **后期删除子网** (远程 SSH):
   ```sh
   subnet-del.sh eth0 --dry-run     # 预演
   subnet-del.sh eth0               # 执行
   ```

4. **查看状态**:
   ```sh
   subnet-list.sh                   # 列出所有
   subnet-inspect.sh eth0           # 查看详情 (含 DHCP 租约/ARP)
   ```

### 安全机制

- 所有写操作支持 `--dry-run` 预演
- `init-subnets.sh --rollback` 一键回滚所有子网
- **br-lan 最后一个成员禁止拆出** (内置安全红线, 拆出会导致管理 IP 失联)
- 执行前自动备份 UCI 配置到 `/tmp/network.bak.<timestamp>`
- 写操作顺序: UCI 成功 -> vps.db (保证一致性)

### 设计原则

- **脚本是子网网络层操作的唯一真相源**: 创建/删除/批量初始化都走脚本
- **网页只读 + 换绑**: 展示子网状态、绑定/解绑链路(不会断网)在网页做
- **批量初始化只在系统初始化时跑一次**, 后期通过 SSH 单个增删

## License

MIT
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README 添加子网管理章节

说明 5 个脚本的用法、典型流程、安全机制、设计原则
强调'脚本是子网网络层操作唯一真相源, 网页只读+换绑'"
```

---

## Task 10: 更新 AGENTS.md 部署路径表

**Files:**
- Modify: `AGENTS.md` (软路由文件部署路径表)

- [ ] **Step 1: 追加 5 个新脚本路径**

用 Edit 工具,old_string 为:

```
| `openwrt/scripts/init-subnets.sh` | `/usr/bin/init-subnets.sh` |
| `openwrt/scripts/generate-config.sh` | `/etc/sing-box/generate-config.sh` |
```

new_string 为:

```
| `openwrt/scripts/init-subnets.sh` | `/usr/bin/init-subnets.sh` |
| `openwrt/scripts/_subnet-lib.sh` | `/usr/bin/_subnet-lib.sh` |
| `openwrt/scripts/subnet-add.sh` | `/usr/bin/subnet-add.sh` |
| `openwrt/scripts/subnet-del.sh` | `/usr/bin/subnet-del.sh` |
| `openwrt/scripts/subnet-list.sh` | `/usr/bin/subnet-list.sh` |
| `openwrt/scripts/subnet-inspect.sh` | `/usr/bin/subnet-inspect.sh` |
| `openwrt/scripts/generate-config.sh` | `/etc/sing-box/generate-config.sh` |
```

- [ ] **Step 2: Commit**

```bash
git add AGENTS.md
git commit -m "docs: AGENTS.md 部署路径表追加 5 个子网管理脚本

_subnet-lib.sh / subnet-add.sh / subnet-del.sh /
subnet-list.sh / subnet-inspect.sh, 全部部署到 /usr/bin/"
```

---

## Task 11: 推送到 GitHub

**Files:** 无文件改动,纯 git 操作

- [ ] **Step 1: push 到 GitHub**

Run: `git push origin main`
Expected: 推送成功,显示所有 commit

- [ ] **Step 2: 确认远程最新**

Run: `git log --oneline -12`
Expected: 看到 10 个新 commit (1 spec + 6 脚本 + controller + vps.htm + README + AGENTS)

---

## Task 12: 软路由部署 + 执行 (人工操作, 需用户在软路由上跑)

**说明:** 此任务需要用户在软路由上操作, 我无法直接 SSH。以下为操作清单。

- [ ] **Step 1: SSH 登录软路由**

```sh
ssh root@192.168.5.1
```

- [ ] **Step 2: 拉取最新代码**

```sh
cd /path/to/vps-deployment-script   # 软路由上 git clone 的路径
git pull
```

- [ ] **Step 3: 部署脚本到 /usr/bin/**

```sh
cp openwrt/scripts/_subnet-lib.sh /usr/bin/
cp openwrt/scripts/init-subnets.sh /usr/bin/
cp openwrt/scripts/subnet-add.sh /usr/bin/
cp openwrt/scripts/subnet-del.sh /usr/bin/
cp openwrt/scripts/subnet-list.sh /usr/bin/
cp openwrt/scripts/subnet-inspect.sh /usr/bin/
chmod +x /usr/bin/init-subnets.sh /usr/bin/subnet-*.sh
```

- [ ] **Step 4: 部署 LuCI 文件**

```sh
cp openwrt/luci/controller/tiktokproxy/tiktokproxy.lua /usr/lib/lua/luci/controller/tiktokproxy.lua
cp openwrt/luci/view/tiktokproxy/vps.htm /usr/lib/lua/luci/view/tiktokproxy/vps.htm
```

- [ ] **Step 5: Lua 语法校验 (部署后)**

```sh
lua -p /usr/lib/lua/luci/controller/tiktokproxy/tiktokproxy.lua
```
Expected: 无输出 (语法正确)

- [ ] **Step 6: dry-run 审核**

```sh
init-subnets.sh --dry-run
```
Expected: 输出每个口将要执行的命令,最后显示 "dry-run 完成, 未修改任何配置"

- [ ] **Step 7: 单口测试 (推荐先测 eth0)**

```sh
init-subnets.sh --test eth0
```
Expected: 拆出 eth0,等待 15 秒,打印 LuCI URL,显示 `http://192.168.6.1/cgi-bin/luci`

- [ ] **Step 8: 验证单口测试结果**

从电脑浏览器访问 `http://192.168.6.1/cgi-bin/luci/admin/services/tiktokproxy/vps`,确认页面正常,eth0 卡片显示子网信息。

- [ ] **Step 9: 单口回滚 (可选, 确认无误后继续全量)**

```sh
init-subnets.sh --rollback
```

- [ ] **Step 10: 全量执行**

```sh
init-subnets.sh
```
Expected: 拆出所有 LAN 口,打印所有 LuCI URL

- [ ] **Step 11: 最终验证**

```sh
subnet-list.sh
```
Expected: 列出所有子网

```sh
subnet-inspect.sh eth0
```
Expected: 显示 eth0 子网详情

- [ ] **Step 12: 浏览器验证页面**

访问任一 LuCI URL,确认"网口管理"页面正常显示所有子网 + 链路绑定按钮可用。

---

## 自审清单

**Spec 覆盖检查:**
- ✅ 共享库 `_subnet-lib.sh` -> Task 1
- ✅ `init-subnets.sh` 重构 + LuCI URL 打印 -> Task 2
- ✅ `subnet-add.sh` -> Task 3
- ✅ `subnet-del.sh` -> Task 4
- ✅ `subnet-list.sh` -> Task 5
- ✅ `subnet-inspect.sh` -> Task 6
- ✅ controller 删 6 函数 + 4 路由 -> Task 7
- ✅ vps.htm 清理残留 URL -> Task 8
- ✅ README 子网管理章节 -> Task 9
- ✅ AGENTS.md 路径表 -> Task 10
- ✅ push + 软路由部署 + 执行 -> Task 11-12

**Placeholder 扫描:** 无 TBD/TODO,所有代码块完整。

**一致性检查:**
- `safe_remove_from_brlan` 在 Task 1 定义,Task 2/3 调用,签名一致 ✅
- `create_uci_interface` 在 Task 1 定义为 `(iface, uci_name, gateway)`,Task 2/3 调用参数顺序一致 ✅
- `commit_and_reload` 在 Task 1 定义,Task 2/3/4 调用,无参数 ✅
- `print_luci_urls` 在 Task 1 定义,Task 2/3/4 调用,无参数 ✅
- `backup_uci` 在 Task 1 定义,Task 2/3/4 调用,无参数 ✅
- `is_phys_iface` / `is_wan_iface` / `is_in_brlan` 在 Task 1 定义,Task 2/3 调用 ✅
- `count_brlan_remaining` 在 Task 1 定义,Task 2/3 调用 ✅
- `return_to_brlan` 在 Task 1 定义,Task 2/4 调用 ✅
- `remove_uci_interface` 在 Task 1 定义为 `(uci_name)`,Task 2/4 调用 ✅
- `add_subnet_to_db` / `delete_subnet_from_db` / `list_subnets_from_db` / `get_subnet_from_db` 签名一致 ✅
