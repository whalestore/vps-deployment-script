#!/bin/sh
# ================================================================
#  migrate-chain-policy.sh - chains 表加 policy_name 列
#
#  功能: 检查 vps.db 的 chains 表是否有 policy_name 列, 没有则 ALTER TABLE ADD
#        幂等: 已有列则跳过
#
#  用法: migrate-chain-policy.sh [vps.db 路径]
#  默认: /etc/sing-box/vps.db
# ================================================================

set -uo pipefail

DB_FILE="${1:-/etc/sing-box/vps.db}"

if [ ! -f "$DB_FILE" ]; then
    echo "ERROR: vps.db not found at $DB_FILE" >&2
    exit 1
fi

# 检查 chains 表是否有 policy_name 列
# PRAGMA table_info 输出格式: cid|name|type|notnull|dflt_value|pk
if sqlite3 "$DB_FILE" "PRAGMA table_info(chains);" 2>/dev/null | cut -d'|' -f2 | grep -qx "policy_name"; then
    echo "[migrate] chains.policy_name 列已存在, 跳过"
    exit 0
fi

# ALTER TABLE 加列
sqlite3 "$DB_FILE" "ALTER TABLE chains ADD COLUMN policy_name TEXT;" 2>/dev/null
if [ $? -ne 0 ]; then
    echo "ERROR: ALTER TABLE chains ADD COLUMN policy_name 失败" >&2
    exit 1
fi

echo "[migrate] chains 表已加 policy_name 列 (TEXT, 默认 NULL = 用 default 策略)"
exit 0
