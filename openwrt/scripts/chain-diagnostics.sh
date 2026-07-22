#!/bin/sh
# ================================================================
#  chain-diagnostics.sh — 网络诊断 + 分段测速后端脚本
#  被 LuCI controller (tiktokproxy.lua) 调用
#
#  用法:
#    chain-diagnostics.sh network              → 网口/链路状态 JSON
#    chain-diagnostics.sh speedtest leg1       → 段1延迟 (移动→东京)
#    chain-diagnostics.sh speedtest leg2       → 段2延迟 (东京→美国)
#    chain-diagnostics.sh speedtest full       → 全链路带宽+延迟
#    chain-diagnostics.sh speedtest vps_tokyo  → 东京VPS带宽(参考)
#    chain-diagnostics.sh speedtest vps_us     → 美国VPS带宽(参考)
#
#  依赖: jq, curl, ping, sshpass, ip, brctl (OpenWrt 标准工具)
#  无 python3 依赖
# ================================================================

LEASES_FILE="/tmp/dhcp.leases"
LOG_FILE="/var/log/sing-box.log"

# ---------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------

# 获取网口的 IPv4 地址 (不含 CIDR)
get_iface_ip() {
    local iface="$1"
    ip -4 addr show "$iface" 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1
}

# 获取设备名 (从 dhcp.leases)
get_device_name() {
    local mac="$1"
    local name
    name=$(grep -i "$mac" "$LEASES_FILE" 2>/dev/null | awk '{print $4}' | head -1)
    if [ -z "$name" ] || [ "$name" = "*" ]; then
        name=""
    fi
    echo "$name"
}

# JSON 字符串转义 (处理特殊字符)
json_escape() {
    local str="$1"
    # 转义反斜杠和双引号, 去掉换行
    printf '%s' "$str" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

# ---------------------------------------------------------------
# network 子命令: 采集网口状态、网桥、设备、AP 映射
# 输出 JSON
# ---------------------------------------------------------------

cmd_network() {
    local wan_dev
    # UCI 里 WAN 口可能用 ifname 或 device, 两个都试
    wan_dev=$(uci get network.wan.device 2>/dev/null || uci get network.wan.ifname 2>/dev/null || echo "")

    # 采集网桥成员
    local bridge_members
    bridge_members=$(ls /sys/class/net/br-lan/brif/ 2>/dev/null | tr '\n' ' ' | sed 's/ $//')

    # 采集所有物理网口 (eth*, 排除 br-*, lo, tun*, wg*, pppoe*)
    local ifaces
    ifaces=$(ls /sys/class/net/ 2>/dev/null | grep -E '^eth[0-9]+$' | sort -V)

    # 构建 interfaces JSON 数组
    local iface_json=""
    local first_iface=1

    for iface in $ifaces; do
        local operstate speed duplex role ip qualified note bridge
        operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        speed=$(cat "/sys/class/net/$iface/speed" 2>/dev/null 2>&1 || echo "-1")
        duplex=$(cat "/sys/class/net/$iface/duplex" 2>/dev/null || echo "unknown")
        ip=$(get_iface_ip "$iface")

        # 判断角色
        if [ "$iface" = "$wan_dev" ]; then
            role="wan"
            note="WAN (上行)"
        else
            role="lan"
            note="LAN"
            # 检查是否在网桥中
            if echo " $bridge_members " | grep -q " $iface "; then
                bridge="br-lan"
            fi
        fi

        # 达标判断
        if [ "$operstate" != "up" ]; then
            qualified=false
            note="$note — 未插线"
        elif [ "$speed" -ge 1000 ] 2>/dev/null; then
            qualified=true
        elif [ "$speed" -eq 100 ] 2>/dev/null; then
            qualified=false
            note="$note — 百兆(检查网线是否Cat5e+)"
        elif [ "$speed" -gt 0 ] && [ "$speed" -lt 100 ] 2>/dev/null; then
            # 低速但有链路：检测是否设备休眠（2s 流量差分）
            local rx1
            rx1=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
            sleep 2
            local rx2
            rx2=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
            if [ "$rx1" = "$rx2" ]; then
                # 2秒内无流量 → 设备待机/休眠
                qualified=false
                note="$note — 设备待机/休眠(协商${speed}Mbps)"
                speed=0
            else
                qualified=false
                note="$note — ${speed}Mbps极慢(检查网线/交换机)"
            fi
        else
            qualified=false
        fi

        # 速度数值处理 (无链路时 speed 可能是 -1 或文件不存在)
        if [ "$operstate" != "up" ] || [ "$speed" = "-1" ] || [ -z "$speed" ]; then
            speed=0
        fi

        # JSON 对象
        local obj
        obj=$(cat <<EOF
{"name":"$iface","role":"$role","link":"$operstate","speed":$speed,"duplex":"$duplex","qualified":$qualified,"ip":"$ip","bridge":"${bridge:-}","note":"$(json_escape "$note")"}
EOF
)

        if [ "$first_iface" = "1" ]; then
            iface_json="$obj"
            first_iface=0
        else
            iface_json="$iface_json,$obj"
        fi
    done

    # 采集已连接设备 (DHCP 租约 + 网桥 MAC 表)
    local devices_json=""
    local first_dev=1

    if [ -f "$LEASES_FILE" ]; then
        # dhcp.leases 格式: timestamp mac ip hostname clientid
        while IFS= read -r line; do
            local mac ip name
            mac=$(echo "$line" | awk '{print $2}')
            ip=$(echo "$line" | awk '{print $3}')
            name=$(echo "$line" | awk '{print $4}')
            if [ -z "$name" ] || [ "$name" = "*" ]; then
                name=""
            fi

            # 查找设备在哪个网口
            # 优先用 brctl showmacs (br-lan 桥接模式), 回退用 ip neigh (独立子网模式)
            local port=""
            if [ -n "$mac" ] && command -v brctl >/dev/null 2>&1; then
                port=$(brctl showmacs br-lan 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
                if [ -n "$port" ] && [ -n "$bridge_members" ]; then
                    port=$(echo "$bridge_members" | cut -d' ' -f$((port + 1)) 2>/dev/null || echo "$port")
                fi
            fi
            # br-lan 不存在或没找到, 用 ip neigh 查设备所在接口 (独立子网模式)
            if [ -z "$port" ] && [ -n "$ip" ]; then
                port=$(ip neigh show 2>/dev/null | grep "^$ip " | grep -oE 'dev [a-z0-9]+' | awk '{print $2}' | head -1)
            fi

            local dev_obj
            dev_obj=$(cat <<EOF
{"ip":"$ip","mac":"$mac","name":"$(json_escape "$name")","port":"${port:-}"}
EOF
)
            if [ "$first_dev" = "1" ]; then
                devices_json="$dev_obj"
                first_dev=0
            else
                devices_json="$devices_json,$dev_obj"
            fi
        done < "$LEASES_FILE"
    fi

    # 采集 AP 映射 (从 vps.db)
    local ap_json=""
    local first_ap=1
    if command -v vps-db.sh >/dev/null 2>&1; then
        local chains_out
        chains_out=$(vps-db.sh list-chains 2>/dev/null)
        if [ -n "$chains_out" ] && [ "$chains_out" != "[]" ]; then
            local chain_count
            chain_count=$(echo "$chains_out" | jq 'length' 2>/dev/null || echo 0)
            local ci
            for ci in $(seq 0 $((chain_count - 1))); do
                local cid ssid ap_mac ap_ip source_ip hop_path last_hop_id us_ip
                cid=$(echo "$chains_out" | jq -r ".[$ci].id")
                ssid=$(echo "$chains_out" | jq -r ".[$ci].wifi_ssid // empty")
                ap_mac=$(echo "$chains_out" | jq -r ".[$ci].ap_mac // empty")
                ap_ip=$(echo "$chains_out" | jq -r ".[$ci].ap_ip // empty")
                source_ip=$(echo "$chains_out" | jq -r ".[$ci].source_ip // empty")
                hop_path=$(echo "$chains_out" | jq -r ".[$ci].hop_path // empty")
                # 获取最后一跳的 VPS IP 作为落地 IP
                last_hop_id=$(echo "$hop_path" | tr ',' '\n' | tail -1)
                us_ip=""
                if [ -n "$last_hop_id" ]; then
                    us_ip=$(vps-db.sh get-node "$last_hop_id" 2>/dev/null | jq -r '.ip // empty' 2>/dev/null)
                fi

                # 查找 AP 接在哪个端口
                local port=""
                if [ -n "$ap_mac" ] && command -v brctl >/dev/null 2>&1; then
                    local port_idx
                    port_idx=$(brctl showmacs br-lan 2>/dev/null | grep -i "$ap_mac" | awk '{print $1}' | head -1)
                    if [ -n "$port_idx" ] && [ -n "$bridge_members" ]; then
                        port=$(echo "$bridge_members" | cut -d' ' -f$((port_idx + 1)) 2>/dev/null || echo "")
                    fi
                fi

                local ap_obj
                ap_obj=$(cat <<EOF
{"chain_id":$cid,"ssid":"$(json_escape "$ssid")","ap_mac":"$ap_mac","ap_ip":"$ap_ip","source_ip":"$source_ip","us_ip":"$us_ip","port":"${port:-}","online":$([ -n "$ap_ip" ] && ping -c1 -W1 "$ap_ip" >/dev/null 2>&1 && echo true || echo false)}
EOF
)
                if [ "$first_ap" = "1" ]; then
                    ap_json="$ap_obj"
                    first_ap=0
                else
                    ap_json="$ap_json,$ap_obj"
                fi
            done
        fi
    fi

    # 输出完整 JSON
    cat <<EOF
{"interfaces":[$iface_json],"bridge_members":"$bridge_members","devices":[$devices_json],"aps":[$ap_json]}
EOF
}

# ---------------------------------------------------------------
# speedtest 子命令: 分段测速
# ---------------------------------------------------------------

# ping 测试: 返回 JSON 键值对 "latency_ms":X,"loss_pct":Y (无外层大括号)
do_ping() {
    local target="$1"
    local count="${2:-10}"
    local result
    result=$(ping -c "$count" -W 2 "$target" 2>&1)
    # 兼容 OpenWrt (round-trip) 和 Ubuntu (rtt)
    local avg loss
    avg=$(echo "$result" | grep -E "rtt|round-trip" | awk -F'/' '{print $5}' | awk '{printf "%.1f", $1}' 2>/dev/null)
    loss=$(echo "$result" | grep "packet loss" | grep -oE '[0-9]+\.?[0-9]*%' | head -1 | tr -d '%')

    [ -z "$avg" ] && avg=0
    [ -z "$loss" ] && loss="100"

    echo "\"latency_ms\":$avg,\"loss_pct\":$loss"
}

# SSH 执行远程命令
ssh_exec() {
    local host="$1"
    local port="$2"
    local user="$3"
    local password="$4"
    local cmd="$5"
    sshpass -p "$password" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -p "$port" "$user@$host" "$cmd" 2>/dev/null
}

# curl 带宽测试: 下载指定大小文件, 返回 Mbps
do_bandwidth() {
    local url="$1"
    local bytes="${2:-100000000}"  # 默认 100MB
    local result
    result=$(curl -s -o /dev/null -w "%{speed_download} %{time_total}" --max-time 30 "${url}?bytes=${bytes}" 2>/dev/null)
    local speed_bps time_total
    speed_bps=$(echo "$result" | awk '{print $1}')
    time_total=$(echo "$result" | awk '{print $2}')

    if [ -z "$speed_bps" ] || [ "$speed_bps" = "0" ]; then
        echo "{\"bandwidth_mbps\":0,\"time_sec\":0,\"status\":\"failed\"}"
        return
    fi

    # speed_download 是 bytes/sec, 转换为 Mbps
    local mbps
    mbps=$(echo "$speed_bps" | awk '{printf "%.1f", $1 * 8 / 1000000}')
    echo "{\"bandwidth_mbps\":$mbps,\"time_sec\":$time_total,\"status\":\"ok\"}"
}

# Cloudflare speed test URL (全球 CDN, 覆盖美国出口)
CLOUDFLARE_DOWN="https://speed.cloudflare.com/__down"

cmd_speedtest() {
    local stage="$1"

    # 从 vps.db 读取 VPS 节点信息
    # 找 relay 节点 (东京) 和 landing 节点 (美国)
    local tokyo_json us_json
    tokyo_json=$(vps-db.sh list-nodes 2>/dev/null | jq -c '[.[] | select(.role=="relay")][0] // empty' 2>/dev/null)
    us_json=$(vps-db.sh list-nodes 2>/dev/null | jq -c '[.[] | select(.role=="landing")][0] // empty' 2>/dev/null)

    local tokyo_ip tokyo_api_port
    local us_ip

    if [ -n "$tokyo_json" ] && [ "$tokyo_json" != "null" ]; then
        tokyo_ip=$(echo "$tokyo_json" | jq -r '.ip // empty')
        tokyo_api_port=$(echo "$tokyo_json" | jq -r '.api_port // 8765')
    fi
    if [ -n "$us_json" ] && [ "$us_json" != "null" ]; then
        us_ip=$(echo "$us_json" | jq -r '.ip // empty')
    fi

    case "$stage" in
        leg1)
            # 段1: 移动→东京 延迟 (OpenWrt 直接 ping 东京 VPS)
            if [ -z "$tokyo_ip" ]; then
                echo '{"stage":"leg1","error":"tokyo VPS not configured in vps.db"}'
                return
            fi
            local ping_result
            ping_result=$(do_ping "$tokyo_ip" 10)
            echo "{\"stage\":\"leg1\",\"name\":\"移动→东京\",\"target\":\"$tokyo_ip\",$ping_result}"
            ;;

        leg2)
            # 段2: 东京→美国 延迟 (通过东京 VPS 测速 API)
            if [ -z "$tokyo_ip" ] || [ -z "$us_ip" ]; then
                echo '{"stage":"leg2","error":"tokyo or us VPS not configured"}'
                return
            fi
            # 调用东京 VPS 的测速 API
            local api_result
            api_result=$(curl -s --max-time 20 "http://${tokyo_ip}:${tokyo_api_port}/ping?host=${us_ip}" 2>/dev/null)
            if [ -z "$api_result" ]; then
                echo "{\"stage\":\"leg2\",\"name\":\"东京→美国\",\"target\":\"$us_ip\",\"error\":\"测速API未响应, 请先部署\"}"
            else
                echo "$api_result" | jq -c --arg s "leg2" --arg n "东京→美国" '. + {stage:$s, name:$n}' 2>/dev/null || echo "$api_result"
            fi
            ;;

        full)
            # 全链路: 延迟 (TTFB) + 带宽 (通过代理下载)
            local running
            running=$(pidof sing-box > /dev/null 2>&1 && echo true || echo false)
            if [ "$running" = "false" ]; then
                echo '{"stage":"full","error":"sing-box not running, please start proxy first"}'
                return
            fi

            # TTFB 测试 (到 Cloudflare)
            local ttfb_result
            ttfb_result=$(curl -s -o /dev/null -w "%{time_connect} %{time_starttransfer}" --max-time 10 \
                "https://speed.cloudflare.com/__down?bytes=1000" 2>/dev/null)
            local connect_ms ttfb_ms
            connect_ms=$(echo "$ttfb_result" | awk '{printf "%.0f", $1 * 1000}')
            ttfb_ms=$(echo "$ttfb_result" | awk '{printf "%.0f", $2 * 1000}')
            [ -z "$connect_ms" ] && connect_ms=0
            [ -z "$ttfb_ms" ] && ttfb_ms=0

            # 带宽测试 (下载 10MB — Cloudflare 对 100MB 返回 403)
            local bw_result
            bw_result=$(do_bandwidth "$CLOUDFLARE_DOWN" 10000000)

            echo "{\"stage\":\"full\",\"name\":\"全链路(代理)\",\"connect_ms\":$connect_ms,\"ttfb_ms\":$ttfb_ms,\"bw_result\":$bw_result}"
            ;;

        vps_tokyo)
            # 东京 VPS 带宽参考 (通过测速 HTTP API)
            if [ -z "$tokyo_ip" ]; then
                echo '{"stage":"vps_tokyo","error":"tokyo VPS not configured"}'
                return
            fi
            local api_result
            api_result=$(curl -s --max-time 40 "http://${tokyo_ip}:${tokyo_api_port}/speed" 2>/dev/null)
            if [ -z "$api_result" ]; then
                echo "{\"stage\":\"vps_tokyo\",\"name\":\"东京VPS带宽\",\"error\":\"测速API未响应, 请先部署\"}"
            else
                echo "$api_result" | jq -c --arg s "vps_tokyo" --arg n "东京VPS带宽" '. + {stage:$s, name:$n}' 2>/dev/null || echo "$api_result"
            fi
            ;;

        vps_us)
            # 美国 VPS 带宽参考 (通过全链路代理测试, 因美国VPS无测速API)
            # 直接 ping 美国 VPS 获取延迟
            if [ -z "$us_ip" ]; then
                echo '{"stage":"vps_us","error":"us VPS not configured"}'
                return
            fi
            local ping_result
            ping_result=$(do_ping "$us_ip" 10)
            echo "{\"stage\":\"vps_us\",\"name\":\"美国VPS延迟\",\"target\":\"$us_ip\",$ping_result}"
            ;;

        *)
            echo "{\"error\":\"unknown stage: $stage\"}"
            ;;
    esac
}

# ---------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------

case "${1:-}" in
    network)
        cmd_network
        ;;
    speedtest)
        if [ -z "${2:-}" ]; then
            echo '{"error":"missing stage argument. usage: chain-diagnostics.sh speedtest <leg1|leg2|full|vps_tokyo|vps_us>"}'
            exit 1
        fi
        cmd_speedtest "$2"
        ;;
    *)
        echo "用法: chain-diagnostics.sh <network|speedtest <stage>>"
        echo "  network             — 采集网口/链路状态"
        echo "  speedtest <stage>   — 测速 (leg1/leg2/full/vps_tokyo/vps_us)"
        exit 1
        ;;
esac
