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
# $1 可能未传, 用 ${1:-} 避免 set -u 报错
[ "${1:-}" = "--json" ] && OUTPUT_FORMAT="json"

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
