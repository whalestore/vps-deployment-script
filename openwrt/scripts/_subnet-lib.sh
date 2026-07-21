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

# 从 br-lan 移除网口 (允许拆光, 拆光时 br-lan IP 失联但子网网关可达)
# 参数: $1 = 要移除的网口名
# 返回: 0 成功 (已执行 uci set), 1 失败 (iface 为空或出错)
# 注意: 调用方需自行 commit
# 设计变更 (2026-07-21): 之前版本会拒绝拆最后一个成员, 但这与"全量拆分"
#   目标矛盾。用户明确通过子网网关 IP 管理, 不依赖 br-lan IP, 所以移除拒绝逻辑,
#   只在拆光时给警告。失联的是 br-lan IP, 不是软路由本身。
safe_remove_from_brlan() {
    local iface="$1"
    if [ -z "$iface" ]; then
        err "safe_remove_from_brlan: iface 为空"
        return 1
    fi
    local remaining=$(count_brlan_remaining "$iface")
    if [ "$remaining" = "0" ]; then
        warn "$iface 是 br-lan 最后一个成员, 拆出后 br-lan IP 将不可达"
        warn "SSH/LuCI 通过子网网关 IP 仍可访问 (见脚本末尾 print_luci_urls 输出)"
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
