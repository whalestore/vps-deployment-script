#!/bin/sh
# ================================================================
#  policy-migrate.sh - 分流策略迁移脚本
#
#  功能: 确保 /etc/sing-box/policies/ 目录存在, default.json 就绪
#        首次执行时把旧 routing-rules.json 迁移成 default.json
#
#  用法:
#    policy-migrate.sh                  # 执行迁移
#    policy-migrate.sh --check          # 只检查不执行, 返回 0=已就绪 1=需迁移
#
#  被 generate-config.sh source 调用: ensure_policies_dir 函数
# ================================================================

CONF_DIR="${CONF_DIR:-/etc/sing-box}"
POLICIES_DIR="$CONF_DIR/policies"
DEFAULT_POLICY="$POLICIES_DIR/default.json"
LEGACY_ROUTING="$CONF_DIR/routing-rules.json"

# 内置默认策略 (全新部署或旧文件损坏时用)
BUILTIN_DEFAULT='{
  "name": "默认策略",
  "notes": "内置默认策略: 国内直连 + 国外走链路",
  "rule_sets": [
    {"tag":"geosite-cn","type":"remote","format":"binary","url":"https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs","download_detour":"direct"},
    {"tag":"geoip-cn","type":"remote","format":"binary","url":"https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs","download_detour":"direct"}
  ],
  "direct_domain_suffix": ["baidu.com","qq.com","bilibili.com","taobao.com","cn","com.cn"],
  "proxy_domain_suffix": ["google.com","youtube.com","tiktok.com","github.com","openai.com","claude.ai"]
}'

# 迁移主函数 (可被 source 后单独调用)
ensure_policies_dir() {
    mkdir -p "$POLICIES_DIR" 2>/dev/null || return 1

    # default.json 已存在, 不覆盖
    if [ -f "$DEFAULT_POLICY" ]; then
        return 0
    fi

    # 尝试从旧 routing-rules.json 迁移
    if [ -f "$LEGACY_ROUTING" ]; then
        # 校验旧文件 JSON 合法
        if jq -e . "$LEGACY_ROUTING" >/dev/null 2>&1; then
            # 注入 name/notes, 写入 default.json
            jq '. + {"name":"默认策略","notes":"迁移自 routing-rules.json"}' \
                "$LEGACY_ROUTING" > "$DEFAULT_POLICY" 2>/dev/null
            if [ $? -eq 0 ] && [ -s "$DEFAULT_POLICY" ]; then
                # 旧文件改名备份 (不删)
                mv "$LEGACY_ROUTING" "$LEGACY_ROUTING.legacy" 2>/dev/null
                echo "[policy-migrate] 已从 routing-rules.json 迁移到 policies/default.json, 旧文件备份为 .legacy" >&2
                return 0
            fi
        fi
        # 旧文件 JSON 不合法, 备份为 .legacy.bad, 用内置默认
        mv "$LEGACY_ROUTING" "$LEGACY_ROUTING.legacy.bad" 2>/dev/null
        echo "[policy-migrate] routing-rules.json JSON 不合法, 已备份为 .legacy.bad, 使用内置默认" >&2
    fi

    # 全新部署或旧文件损坏: 写入内置默认
    echo "$BUILTIN_DEFAULT" | jq '.' > "$DEFAULT_POLICY" 2>/dev/null
    if [ $? -ne 0 ] || [ ! -s "$DEFAULT_POLICY" ]; then
        echo "[policy-migrate] ERROR: 无法写入 default.json" >&2
        return 1
    fi
    echo "[policy-migrate] 已创建内置默认策略 policies/default.json" >&2
    return 0
}

# 仅在直接执行时运行, 不在 source 时运行
# 通过判断 $0 是否以 policy-migrate.sh 结尾来区分
case "${0##*/}" in
    policy-migrate.sh)
        set -uo pipefail
        if [ "${1:-}" = "--check" ]; then
            [ -f "$DEFAULT_POLICY" ] && exit 0 || exit 1
        fi
        ensure_policies_dir
        exit $?
        ;;
esac
