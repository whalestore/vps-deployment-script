#!/bin/sh
# ================================================================
#  generate-config.sh - 多跳链路配置生成器 (OpenWrt 侧)
#  从 vps.db 读取链路定义, 从 routing-rules.json 读取分流策略
#  用 generate-config.jq 生成 sing-box config.json
#
#  数据流:
#    vps-db.sh get-active-config (JSON, 含 cidrs 聚合)
#      + routing-rules.json (分流策略)
#      -> generate-config.jq 生成 sing-box config.json
#        -> sing-box check 验证
#
#  设计:
#    - route.final = direct, dns.detour = direct (本地直连永远可用)
#    - 链路流量仅通过 route.rules 按 source_ip_cidr 匹配
#    - 链路内按域名分流: 国内直连, 国外走 VLESS 多跳
#    - 未绑定子网的链路不生成分流规则 (outbound 仍存在)
#
#  依赖: jq, vps-db.sh, sing-box
# ================================================================

CONF_DIR="/etc/sing-box"
DB_FILE="$CONF_DIR/vps.db"
ROUTING_RULES_FILE="$CONF_DIR/routing-rules.json"
JQ_SCRIPT="$CONF_DIR/generate-config.jq"
OUTPUT="$CONF_DIR/config.json"

# 检查数据库
if [ ! -f "$DB_FILE" ]; then
    echo "ERROR: vps.db not found at $DB_FILE"
    exit 1
fi

# 检查 jq 脚本
if [ ! -f "$JQ_SCRIPT" ]; then
    echo "ERROR: jq script not found at $JQ_SCRIPT"
    exit 1
fi

# 获取启用链路 (含 hops 展开 + subnets 聚合的 cidrs)
CHAINS_JSON=$(vps-db.sh get-active-config 2>/dev/null)
if [ -z "$CHAINS_JSON" ] || [ "$CHAINS_JSON" = "[]" ]; then
    CHAINS_JSON=$(vps-db.sh get-chain-config 2>/dev/null)
fi

if [ -z "$CHAINS_JSON" ] || [ "$CHAINS_JSON" = "[]" ]; then
    echo "ERROR: no enabled chains in vps.db"
    echo "Run: vps-db.sh add-chain '{\"name\":\"...\",\"hop_path\":\"1,2\"}'"
    exit 1
fi

CHAIN_COUNT=$(echo "$CHAINS_JSON" | jq 'length')

# 检查分流规则文件
if [ ! -f "$ROUTING_RULES_FILE" ]; then
    echo '{"rule_sets":[],"direct_domain_suffix":[],"proxy_domain_suffix":[]}' > /tmp/empty-rules.json
    ROUTING_RULES_FILE="/tmp/empty-rules.json"
fi

# 计算 cidrs 数组 (优先 get-active-config 聚合, 回退 source_cidr/source_ip)
CHAINS_JSON=$(echo "$CHAINS_JSON" | jq -c '
def resolve_cidrs:
    (.cidrs // []) as $arr |
    (if ($arr | length) > 0 then $arr
     else
       (.source_cidr // "") as $c |
       (.source_ip // "") as $ip |
       (if ($c | length) > 0 then [$c]
        elif ($ip | contains("/")) then [$ip]
        else [] end)
     end) as $final |
    . + {resolved_cidrs: $final};
map(resolve_cidrs)
')

# 关键设计: 无论单链路还是多链路, final 和 dns.detour 都走 direct
# 链路流量仅通过 route.rules 精准匹配 (source_ip_cidr)
# 本地网络永远可用, 代理断了不影响
FINAL_TAG="direct"
DNS_DETOUR="direct"

# 用独立的 jq 脚本文件生成配置 (避免 shell 转义问题)
echo "$CHAINS_JSON" | jq -n \
    --slurpfile chains /dev/stdin \
    --slurpfile routing "$ROUTING_RULES_FILE" \
    --arg dns_detour "$DNS_DETOUR" \
    --arg final_tag "$FINAL_TAG" \
    -f "$JQ_SCRIPT" > "$OUTPUT" 2>/tmp/jq-error.log

if [ $? -ne 0 ]; then
    echo "ERROR: jq config generation failed"
    echo "jq error:"
    cat /tmp/jq-error.log
    exit 1
fi

# 验证生成的配置
if [ ! -s "$OUTPUT" ]; then
    echo "ERROR: generated config is empty"
    exit 1
fi

echo "[OpenWrt] 生成 $CHAIN_COUNT 条链路 -> $OUTPUT"
echo ""
echo "Outbounds (VLESS):"
jq -r '.outbounds[] | "  \(.tag) (\(.type))\(if .detour then " detour=\(.detour)" else "" end)"' "$OUTPUT" 2>/dev/null
echo ""
echo "Route rules (链路内分流):"
RULES_COUNT=$(jq '.route.rules | length' "$OUTPUT" 2>/dev/null)
if [ "$RULES_COUNT" = "0" ] || [ -z "$RULES_COUNT" ]; then
    echo "  (无分流规则 - 链路未绑定子网)"
else
    jq -r '.route.rules[] | "  src=\(.source_ip_cidr|join(",")) \(if .rule_set then "rule_set=\(.rule_set)" elif .domain_suffix then "domains=\(.domain_suffix|length)" else "default" end) -> \(.outbound)"' "$OUTPUT" 2>/dev/null
fi
echo ""
echo "Rule sets:"
jq -r '.route.rule_set[]? | "  \(.tag) <- \(.url)"' "$OUTPUT" 2>/dev/null
echo ""
echo "Final: $(jq -r '.route.final' "$OUTPUT" 2>/dev/null)"
echo "DNS detour: $(jq -r '.dns.servers[0].detour' "$OUTPUT" 2>/dev/null)"
echo "DNS strategy: $(jq -r '.dns.strategy' "$OUTPUT" 2>/dev/null)"
