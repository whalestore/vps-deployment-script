# 链路分流策略管理实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把单一全局 `routing-rules.json` 升级成可创建多个的策略文件,在 LuCI 后台提供独立的「分流策略」管理页面,在链路卡片里增加策略下拉实现一对一绑定。

**Architecture:** 文件系统即真相(`/etc/sing-box/policies/<name>.json`);`chains` 表加 `policy_name` 字段;`generate-config.sh` 按链路读策略文件,内嵌到 `chain._policy_content`;新增 LuCI 页面 `policies.htm` + 6 个 controller API。

**Tech Stack:** Shell (busybox sh + jq),Lua (LuCI controller),HTM (LuCI view template + 原生 JS),SQLite (vps.db)

**Spec:** `docs/superpowers/specs/2026-07-21-chain-routing-policies-design.md`

**部署规则 (AGENTS.md 强制):** 所有代码改动在本地 `/Users/caoxuefei/Codes/xuefei/vps/` 改,`git commit` + `git push`,软路由上 `git pull` 后 `cp`/`ln -s` 到运行路径。**禁止 scp 覆盖**。LuCI controller 部署后必须清字节码缓存:
```sh
rm -rf /tmp/luci-modulecache/*
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart
```

**本地测试环境:** 本机无法 SSH 到软路由 (无密钥),所有测试在本地用 `jq` + `sh` 模拟;集成测试需用户在软路由上执行。

**路径映射表:**

| 本地路径 | 软路由路径 |
|---------|-----------|
| `openwrt/scripts/generate-config.sh` | `/etc/sing-box/generate-config.sh` |
| `openwrt/scripts/generate-config.jq` | `/etc/sing-box/generate-config.jq` |
| `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua` | `/usr/lib/lua/luci/controller/tiktokproxy/tiktokproxy.lua` |
| `openwrt/luci/view/tiktokproxy/policies.htm` (新建) | `/usr/lib/lua/luci/view/tiktokproxy/policies.htm` |

---

## File Structure

**新建:**
- `openwrt/luci/view/tiktokproxy/policies.htm` — 分流策略管理页面 (列表 + 表单/JSON 双模式编辑器)
- `openwrt/scripts/policy-migrate.sh` — 迁移脚本 (可独立执行,也被 generate-config.sh 调用)

**修改:**
- `openwrt/scripts/generate-config.sh` — 加 `ensure_policies_dir` + 按链路读策略
- `openwrt/scripts/generate-config.jq` — `chain_routing_rules` 从 `_policy_content` 取规则;DNS 用 default;rule_sets 去重合并
- `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua` — 加 6 个 API + 路由注册 + chain_fields 加 policy_name
- `openwrt/luci/view/tiktokproxy/vps.htm` — 链路卡片加策略下拉 + 编辑表单加策略字段
- `AGENTS.md` — 路径表 + 字节码缓存说明 (已存在,确认即可)

**vps-db.sh 不在本仓库** (软路由侧 `/usr/bin/vps-db.sh`):本计划只描述需要的改动,实际改 vps-db.sh 需要单独在软路由上操作。**本计划用 SQL 直接操作 SQLite 绕过 vps-db.sh**,避免依赖外部脚本改动。

---

## Task 1: 创建迁移脚本 policy-migrate.sh

**Files:**
- Create: `openwrt/scripts/policy-migrate.sh`

负责把旧 `routing-rules.json` 迁移到 `policies/default.json`,首次启动自动执行。可独立运行,也被 generate-config.sh source 调用。

- [ ] **Step 1: 创建脚本骨架**

创建 `openwrt/scripts/policy-migrate.sh`:

```sh
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

set -uo pipefail

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

# 独立执行入口
if [ "${1:-}" = "--check" ]; then
    [ -f "$DEFAULT_POLICY" ] && exit 0 || exit 1
fi

ensure_policies_dir
exit $?
```

- [ ] **Step 2: 本地赋可执行权限**

```sh
chmod +x openwrt/scripts/policy-migrate.sh
```

- [ ] **Step 3: 本地测试迁移逻辑 (旧文件存在场景)**

```sh
# 准备临时测试环境
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/etc/sing-box"
cp openwrt/scripts/routing-rules.json "$TEST_DIR/etc/sing-box/"

# 跑迁移
CONF_DIR="$TEST_DIR/etc/sing-box" sh openwrt/scripts/policy-migrate.sh

# 断言
test -f "$TEST_DIR/etc/sing-box/policies/default.json" && echo "PASS: default.json 已创建" || echo "FAIL"
test -f "$TEST_DIR/etc/sing-box/routing-rules.json.legacy" && echo "PASS: 旧文件已备份" || echo "FAIL"
jq -r '.name' "$TEST_DIR/etc/sing-box/policies/default.json" | grep -q "默认策略" && echo "PASS: name 已注入" || echo "FAIL"
jq -r '.direct_domain_suffix | length' "$TEST_DIR/etc/sing-box/policies/default.json" | grep -qE '^[0-9]+$' && echo "PASS: 规则字段保留" || echo "FAIL"

# 清理
rm -rf "$TEST_DIR"
```

Expected: 4 个 PASS。

- [ ] **Step 4: 本地测试 (default.json 已存在场景, 不覆盖)**

```sh
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/etc/sing-box/policies"
echo '{"name":"用户自定义","direct_domain_suffix":["test.com"]}' > "$TEST_DIR/etc/sing-box/policies/default.json"

# 跑迁移
CONF_DIR="$TEST_DIR/etc/sing-box" sh openwrt/scripts/policy-migrate.sh

# 断言: 用户的内容不被覆盖
jq -r '.name' "$TEST_DIR/etc/sing-box/policies/default.json" | grep -q "用户自定义" && echo "PASS: 未覆盖" || echo "FAIL"

rm -rf "$TEST_DIR"
```

Expected: PASS。

- [ ] **Step 5: 本地测试 (JSON 不合法场景)**

```sh
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/etc/sing-box"
echo "this is not json {{{" > "$TEST_DIR/etc/sing-box/routing-rules.json"

# 跑迁移
CONF_DIR="$TEST_DIR/etc/sing-box" sh openwrt/scripts/policy-migrate.sh 2>&1

# 断言
test -f "$TEST_DIR/etc/sing-box/routing-rules.json.legacy.bad" && echo "PASS: 坏文件已备份" || echo "FAIL"
test -f "$TEST_DIR/etc/sing-box/policies/default.json" && echo "PASS: 用内置默认创建" || echo "FAIL"
jq -e . "$TEST_DIR/etc/sing-box/policies/default.json" >/dev/null && echo "PASS: default.json 合法" || echo "FAIL"

rm -rf "$TEST_DIR"
```

Expected: 3 个 PASS。

- [ ] **Step 6: Commit**

```sh
git add openwrt/scripts/policy-migrate.sh
git commit -m "feat: 分流策略迁移脚本 policy-migrate.sh

首次启动时把旧 routing-rules.json 迁移到 policies/default.json,
旧文件改名 .legacy 备份。JSON 不合法时备份为 .legacy.bad 并用内置默认。

被 generate-config.sh source 调用 ensure_policies_dir 函数。"
```

---

## Task 2: 改 generate-config.sh 按链路读策略

**Files:**
- Modify: `openwrt/scripts/generate-config.sh`

把固定的 `ROUTING_RULES_FILE` 改成按链路 `policy_name` 读对应策略文件,内嵌到 `chain._policy_content`。

- [ ] **Step 1: 读取当前 generate-config.sh 全文确认改动点**

Run: `cat openwrt/scripts/generate-config.sh`

关注三处:
1. 第 22-26 行: `CONF_DIR` / `ROUTING_RULES_FILE` 定义
2. 第 54-58 行: `ROUTING_RULES_FILE` 不存在时创建空规则文件
3. 第 82-88 行: `--slurpfile routing "$ROUTING_RULES_FILE"` 传给 jq

- [ ] **Step 2: 改 CONF_DIR 定义段, 加 POLICIES_DIR**

Edit `openwrt/scripts/generate-config.sh`, 把:

```sh
CONF_DIR="/etc/sing-box"
DB_FILE="$CONF_DIR/vps.db"
ROUTING_RULES_FILE="$CONF_DIR/routing-rules.json"
JQ_SCRIPT="$CONF_DIR/generate-config.jq"
OUTPUT="$CONF_DIR/config.json"
```

替换为:

```sh
CONF_DIR="/etc/sing-box"
DB_FILE="$CONF_DIR/vps.db"
POLICIES_DIR="$CONF_DIR/policies"
DEFAULT_POLICY="$POLICIES_DIR/default.json"
JQ_SCRIPT="$CONF_DIR/generate-config.jq"
OUTPUT="$CONF_DIR/config.json"

# 迁移: 确保 policies 目录 + default.json 就绪 (首次启动自动迁移)
POLICY_MIGRATE="/usr/bin/policy-migrate.sh"
if [ ! -f "$POLICY_MIGRATE" ]; then
    POLICY_MIGRATE="$(dirname "$0")/policy-migrate.sh"
fi
if [ -f "$POLICY_MIGRATE" ]; then
    . "$POLICY_MIGRATE"
    ensure_policies_dir
else
    echo "WARN: policy-migrate.sh 未找到, 跳过迁移" >&2
    mkdir -p "$POLICIES_DIR" 2>/dev/null
fi
```

- [ ] **Step 3: 删除旧的 ROUTING_RULES_FILE 检查段**

Edit `openwrt/scripts/generate-config.sh`, 删除这段 (原第 54-58 行):

```sh
# 检查分流规则文件
if [ ! -f "$ROUTING_RULES_FILE" ]; then
    echo '{"rule_sets":[],"direct_domain_suffix":[],"proxy_domain_suffix":[]}' > /tmp/empty-rules.json
    ROUTING_RULES_FILE="/tmp/empty-rules.json"
fi
```

替换为:

```sh
# default.json 必须存在 (迁移已保证, 这里二次校验)
if [ ! -f "$DEFAULT_POLICY" ]; then
    echo "ERROR: $DEFAULT_POLICY 不存在, 迁移失败" >&2
    exit 1
fi
```

- [ ] **Step 4: 改 CHAINS_JSON 处理, 按链路读策略内嵌 _policy_content**

在 `CHAINS_JSON=$(echo "$CHAINS_JSON" | jq -c '... resolve_cidrs ...')` 这段之后 (即 `FINAL_TAG="direct"` 之前), 插入策略加载逻辑。

找到:
```sh
# 关键设计: 无论单链路还是多链路, final 和 dns.detour 都走 direct
```

在它**前面**插入:

```sh
# 按链路 policy_name 读策略文件, 内嵌到 chain._policy_content
# 未绑定或文件缺失时回退 default.json
POLICY_LOAD_FAILED=0
CHAINS_JSON=$(echo "$CHAINS_JSON" | jq -c '.[]' | while read -r chain; do
    chain_name=$(echo "$chain" | jq -r '.name // "?"')
    policy_name=$(echo "$chain" | jq -r '.policy_name // "default"')
    # 空字符串当 default
    [ -z "$policy_name" ] && policy_name="default"
    policy_file="$POLICIES_DIR/$policy_name.json"

    if [ ! -f "$policy_file" ]; then
        echo "[warn] 链路 $chain_name 策略 $policy_name 文件不存在, 回退 default" >&2
        policy_name="default"
        policy_file="$DEFAULT_POLICY"
    fi
    # 校验 JSON 合法 (非法则整个 generate 失败, 保留旧 config.json)
    if ! jq -e . "$policy_file" >/dev/null 2>&1; then
        echo "[error] 链路 $chain_name 策略文件 $policy_file JSON 不合法, 中止生成" >&2
        exit 1
    fi
    # 内嵌策略内容到 chain 对象
    echo "$chain" | jq -c --slurpfile p "$policy_file" \
        '. + {_policy_content: $p[0], _policy_name: "'"$policy_name"'"}'
done | jq -s '.')

# while 子shell 退出码拿不到, 用空结果判断失败
if [ -z "$CHAINS_JSON" ] || [ "$CHAINS_JSON" = "[]" ]; then
    echo "ERROR: 策略加载失败或链路为空" >&2
    exit 1
fi
```

- [ ] **Step 5: 改 jq 调用, 用临时文件传 chains 和 default**

找到现在的 jq 调用段:

```sh
# 用独立的 jq 脚本文件生成配置 (避免 shell 转义问题)
echo "$CHAINS_JSON" | jq -n \
    --slurpfile chains /dev/stdin \
    --slurpfile routing "$ROUTING_RULES_FILE" \
    --arg dns_detour "$DNS_DETOUR" \
    --arg final_tag "$FINAL_TAG" \
    -f "$JQ_SCRIPT" > "$OUTPUT" 2>/tmp/jq-error.log
```

替换为:

```sh
# 用独立的 jq 脚本文件生成配置
# busybox sh 不支持进程替换 <(...), --slurpfile 不能用 /dev/stdin (管道占用), 都用临时文件
CHAINS_TMP=$(mktemp)
DEFAULT_TMP=$(mktemp)
echo "$CHAINS_JSON" > "$CHAINS_TMP"
cp "$DEFAULT_POLICY" "$DEFAULT_TMP"
jq -n \
    --slurpfile chains "$CHAINS_TMP" \
    --slurpfile default "$DEFAULT_TMP" \
    --arg dns_detour "$DNS_DETOUR" \
    --arg final_tag "$FINAL_TAG" \
    -f "$JQ_SCRIPT" > "$OUTPUT" 2>/tmp/jq-error.log
JQ_EXIT=$?
rm -f "$CHAINS_TMP" "$DEFAULT_TMP"
if [ $JQ_EXIT -ne 0 ]; then
    echo "ERROR: jq config generation failed"
    echo "jq error:"
    cat /tmp/jq-error.log
    exit 1
fi
```

同时删除原来紧跟其后的这段 (已合并到上面):
```sh
if [ $? -ne 0 ]; then
    echo "ERROR: jq config generation failed"
    echo "jq error:"
    cat /tmp/jq-error.log
    exit 1
fi
```

- [ ] **Step 6: 改最后的日志输出, 加策略加载信息**

找到 `echo "[OpenWrt] 生成 $CHAIN_COUNT 条链路 -> $OUTPUT"` 这段, 在 `echo "Route rules..."` 之前插入:

```sh
echo "策略加载:"
echo "$CHAINS_JSON" | jq -r '.[] | "  链路 \(.name) -> 策略 \(_policy_name)"' 2>/dev/null
echo ""
```

- [ ] **Step 7: 本地测试 generate-config.sh (mock 数据)**

```sh
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/etc/sing-box/policies"

# 准备 default 策略
cat > "$TEST_DIR/etc/sing-box/policies/default.json" <<'EOF'
{
  "name": "默认",
  "rule_sets": [
    {"tag":"geosite-cn","type":"remote","format":"binary","url":"https://example/geosite-cn.srs","download_detour":"direct"}
  ],
  "direct_domain_suffix": ["baidu.com"],
  "proxy_domain_suffix": ["google.com"]
}
EOF

# 准备 tiktok-priority 策略
cat > "$TEST_DIR/etc/sing-box/policies/tiktok-priority.json" <<'EOF'
{
  "name": "TikTok优先",
  "rule_sets": [],
  "direct_domain_suffix": [],
  "proxy_domain_suffix": ["tiktok.com","google.com"]
}
EOF

# mock chains JSON (模拟 vps-db 输出, 含 hops + resolved_cidrs + policy_name)
cat > "$TEST_DIR/chains.json" <<'EOF'
[
  {
    "id": 1, "name": "tiktok-us", "enabled": 1, "hop_path": "1",
    "policy_name": "tiktok-priority",
    "hops": [{"ip":"1.2.3.4","vless_uuid":"abc","reality_sni":"www.paypal.com","reality_public_key":"xyz","init_port":443}],
    "resolved_cidrs": ["192.168.7.0/24"]
  },
  {
    "id": 2, "name": "cn-direct", "enabled": 1, "hop_path": "2",
    "policy_name": null,
    "hops": [{"ip":"5.6.7.8","vless_uuid":"def","reality_sni":"www.paypal.com","reality_public_key":"uvw","init_port":443}],
    "resolved_cidrs": ["192.168.8.0/24"]
  }
]
EOF

# mock vps-db.sh (输出 chains.json)
cat > "$TEST_DIR/vps-db.sh" <<'EOF'
#!/bin/sh
if [ "$1" = "get-active-config" ] || [ "$1" = "get-chain-config" ]; then
    cat "$MOCK_CHAINS_FILE"
fi
EOF
chmod +x "$TEST_DIR/vps-db.sh"

# 跑 generate-config.sh (用环境变量覆盖路径)
PATH="$TEST_DIR:$PATH" \
CONF_DIR="$TEST_DIR/etc/sing-box" \
DB_FILE="$TEST_DIR/fake.db" \
MOCK_CHAINS_FILE="$TEST_DIR/chains.json" \
    sh openwrt/scripts/generate-config.sh 2>&1

# 断言
test -s "$TEST_DIR/etc/sing-box/config.json" && echo "PASS: config.json 已生成" || echo "FAIL"
jq -r '.route.rules | length' "$TEST_DIR/etc/sing-box/config.json" | grep -qE '^[0-9]+$' && echo "PASS: route.rules 存在" || echo "FAIL"

# 验证: tiktok-us 链路用 tiktok-priority 策略 (proxy_domain_suffix 含 tiktok.com)
jq -r '.route.rules[] | select(.source_ip_cidr | index("192.168.7.0/24")) | .domain_suffix // [] | .[]' "$TEST_DIR/etc/sing-box/config.json" | grep -q "tiktok.com" && echo "PASS: tiktok-us 链路用了 tiktok-priority 策略" || echo "FAIL"

# 验证: cn-direct 链路用 default 策略 (direct_domain_suffix 含 baidu.com)
jq -r '.route.rules[] | select(.source_ip_cidr | index("192.168.8.0/24")) | select(.outbound=="direct") | .domain_suffix // [] | .[]' "$TEST_DIR/etc/sing-box/config.json" | grep -q "baidu.com" && echo "PASS: cn-direct 链路用了 default 策略" || echo "FAIL"

rm -rf "$TEST_DIR"
```

Expected: 4 个 PASS。

- [ ] **Step 8: Commit**

```sh
git add openwrt/scripts/generate-config.sh
git commit -m "feat: generate-config.sh 按链路读策略文件

- source policy-migrate.sh 调用 ensure_policies_dir
- 为每条链路读 policies/<policy_name>.json, 内嵌到 _policy_content
- 策略文件缺失回退 default.json, JSON 非法则中止生成
- --slurpfile 用临时文件 (busybox sh 无进程替换)
- jq 脚本传 chains + default 两个 slurpfile"
```

---

## Task 3: 改 generate-config.jq 从 _policy_content 取规则

**Files:**
- Modify: `openwrt/scripts/generate-config.jq`

把 `chain_routing_rules` 从全局 `routing` 取规则改成从 `chain._policy_content` 取;DNS 用 `default`;`route.rule_set` 去重合并所有链路策略。

- [ ] **Step 1: 改 jq 脚本头部变量定义**

Edit `openwrt/scripts/generate-config.jq`, 把开头:

```jq
# 输入: chains 数组 (含 hops + resolved_cidrs) + routing rules
def chains: $chains[0];
def routing: $routing[0];
```

替换为:

```jq
# 输入: chains 数组 (含 hops + resolved_cidrs + _policy_content) + default 策略
def chains: $chains[0];
def default_policy: $default[0];
```

- [ ] **Step 2: 改 chain_routing_rules 函数**

找到 `def chain_routing_rules(chain):` 整个函数 (约 30 行), 替换为:

```jq
def chain_routing_rules(chain):
    chain as $c |
    (chain_final_tag($c)) as $tag |
    # 过滤无效 cidr: 只保留有效的 "x.x.x.x/n" 前缀
    ($c.resolved_cidrs | map(select(is_valid_cidr))) as $valid_cidrs |
    # 从链路内嵌的策略内容取规则 (不再用全局 routing)
    ($c._policy_content.rule_sets // []) as $rule_sets |
    ($c._policy_content.direct_domain_suffix // []) as $direct_domains |
    ($c._policy_content.proxy_domain_suffix // []) as $proxy_domains |
    # 没有有效 cidr 时返回空数组 (不生成分流规则, 链路 outbound 仍存在)
    if ($valid_cidrs | length) == 0 then []
    else
        ($valid_cidrs) as $cidrs |
        # 1. 强制代理域名 (优先级最高, 确保这些域名一定走链路)
        (if ($proxy_domains | length) > 0 then
            [{source_ip_cidr: $cidrs, domain_suffix: $proxy_domains, outbound: $tag}]
           else [] end)
        # 2. geosite-cn 直连 (国内域名走直连, 不走 VLESS)
        + (if ($rule_sets | any(.tag == "geosite-cn")) then
            [{source_ip_cidr: $cidrs, rule_set: "geosite-cn", outbound: "direct"}]
         else [] end)
        # 3. geoip-cn 直连 (国内 IP 走直连)
        + (if ($rule_sets | any(.tag == "geoip-cn")) then
            [{source_ip_cidr: $cidrs, rule_set: "geoip-cn", outbound: "direct"}]
           else [] end)
        # 4. 自定义直连域名
        + (if ($direct_domains | length) > 0 then
            [{source_ip_cidr: $cidrs, domain_suffix: $direct_domains, outbound: "direct"}]
           else [] end)
        # 5. 默认走链路 (绑定了链路的子网流量默认走 VLESS)
        + [{source_ip_cidr: $cidrs, outbound: $tag}]
    end;
```

- [ ] **Step 3: 改 DNS 部分, 用 default_policy**

找到 dns 块 (约第 97-113 行), 把:

```jq
    dns: {
        # strategy=ipv4_only: 只解析 A 记录, 避免 VPS 无 IPv6 上行时 AAAA 导致 no route to host
        strategy: "ipv4_only",
        servers: [
            # 本地 DNS (走直连, 用于国内域名解析)
            { tag: "local-dns", address: "223.5.5.5", detour: "direct" },
            # 远程 DNS (走直连, 用于国外域名解析, 避免 DNS 污染)
            { tag: "proxy-dns", address: "8.8.8.8", detour: "direct" }
        ],
        rules: [
            # 国内域名用本地 DNS 解析 (快速)
            { rule_set: "geosite-cn", server: "local-dns" },
            # 其他域名用 8.8.8.8 解析 (避免污染)
            { domain_suffix: (routing.proxy_domain_suffix // []), server: "proxy-dns" }
        ],
        final: "proxy-dns"
    },
```

替换为:

```jq
    dns: {
        # strategy=ipv4_only: 只解析 A 记录, 避免 VPS 无 IPv6 上行时 AAAA 导致 no route to host
        strategy: "ipv4_only",
        servers: [
            # 本地 DNS (走直连, 用于国内域名解析)
            { tag: "local-dns", address: "223.5.5.5", detour: "direct" },
            # 远程 DNS (走直连, 用于国外域名解析, 避免 DNS 污染)
            { tag: "proxy-dns", address: "8.8.8.8", detour: "direct" }
        ],
        rules: [
            # 国内域名用本地 DNS 解析 (快速)
            { rule_set: "geosite-cn", server: "local-dns" },
            # 其他域名用 8.8.8.8 解析 (避免污染)
            # DNS 分流用 default 策略 (全局 DNS 不按链路分)
            { domain_suffix: (default_policy.proxy_domain_suffix // []), server: "proxy-dns" }
        ],
        final: "proxy-dns"
    },
```

- [ ] **Step 4: 改 route.rule_set, 去重合并所有链路策略的 rule_sets**

找到:

```jq
    route: {
        rule_set: (routing.rule_sets // []),
        rules: all_routing_rules,
        final: $final_tag,
        auto_detect_interface: true
    }
```

替换为:

```jq
    route: {
        # 去重合并所有链路策略的 rule_sets (按 tag 去重)
        rule_set: ([chains[] | ._policy_content.rule_sets // [] | .[]] | unique_by(.tag)),
        rules: all_routing_rules,
        final: $final_tag,
        auto_detect_interface: true
    }
```

- [ ] **Step 5: 本地测试 generate-config.jq (用 Task 2 的 mock 数据)**

```sh
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/policies"
cat > "$TEST_DIR/policies/default.json" <<'EOF'
{"name":"默认","rule_sets":[{"tag":"geosite-cn","type":"remote","format":"binary","url":"https://x/geosite-cn.srs","download_detour":"direct"}],"direct_domain_suffix":["baidu.com"],"proxy_domain_suffix":["google.com"]}
EOF
cat > "$TEST_DIR/policies/tiktok-priority.json" <<'EOF'
{"name":"TikTok优先","rule_sets":[],"direct_domain_suffix":[],"proxy_domain_suffix":["tiktok.com"]}
EOF

# 准备 chains JSON (含 _policy_content, 模拟 generate-config.sh 处理后的数据)
cat > "$TEST_DIR/chains.json" <<'EOF'
[
  {
    "id": 1, "name": "tiktok-us", "hop_path": "1", "policy_name": "tiktok-priority",
    "_policy_name": "tiktok-priority",
    "_policy_content": {"name":"TikTok优先","rule_sets":[],"direct_domain_suffix":[],"proxy_domain_suffix":["tiktok.com"]},
    "hops": [{"ip":"1.2.3.4","vless_uuid":"abc","reality_sni":"www.paypal.com","reality_public_key":"xyz","init_port":443}],
    "resolved_cidrs": ["192.168.7.0/24"]
  },
  {
    "id": 2, "name": "cn-direct", "hop_path": "2", "policy_name": "default",
    "_policy_name": "default",
    "_policy_content": {"name":"默认","rule_sets":[{"tag":"geosite-cn","type":"remote","format":"binary","url":"https://x/geosite-cn.srs","download_detour":"direct"}],"direct_domain_suffix":["baidu.com"],"proxy_domain_suffix":["google.com"]},
    "hops": [{"ip":"5.6.7.8","vless_uuid":"def","reality_sni":"www.paypal.com","reality_public_key":"uvw","init_port":443}],
    "resolved_cidrs": ["192.168.8.0/24"]
  }
]
EOF

# 跑 jq 生成 config.json
jq -n \
    --slurpfile chains "$TEST_DIR/chains.json" \
    --slurpfile default "$TEST_DIR/policies/default.json" \
    --arg dns_detour "direct" \
    --arg final_tag "direct" \
    -f openwrt/scripts/generate-config.jq > "$TEST_DIR/config.json" 2>"$TEST_DIR/jq-error.log"
JQ_EXIT=$?

# 断言
[ $JQ_EXIT -eq 0 ] && echo "PASS: jq 生成成功" || (echo "FAIL: jq 错误:"; cat "$TEST_DIR/jq-error.log")
test -s "$TEST_DIR/config.json" && echo "PASS: config.json 非空" || echo "FAIL"

# tiktok-us (192.168.7.0/24) 应有 tiktok.com 在 proxy_domain_suffix 规则里
jq -r '.route.rules[] | select(.source_ip_cidr | index("192.168.7.0/24")) | .domain_suffix // [] | .[]' "$TEST_DIR/config.json" | grep -q "tiktok.com" && echo "PASS: tiktok-us 用 tiktok-priority 策略" || echo "FAIL"

# cn-direct (192.168.8.0/24) 应有 baidu.com 在 direct 规则里 (default 策略)
jq -r '.route.rules[] | select(.source_ip_cidr | index("192.168.8.0/24")) | select(.outbound=="direct") | .domain_suffix // [] | .[]' "$TEST_DIR/config.json" | grep -q "baidu.com" && echo "PASS: cn-direct 用 default 策略" || echo "FAIL"

# DNS rules 应含 google.com (default 策略的 proxy_domain_suffix)
jq -r '.dns.rules[] | select(.server=="proxy-dns") | .domain_suffix // [] | .[]' "$TEST_DIR/config.json" | grep -q "google.com" && echo "PASS: DNS 用 default 策略" || echo "FAIL"

# route.rule_set 应含 geosite-cn (来自 default 策略, tiktok-priority 没有)
jq -r '.route.rule_set[] | .tag' "$TEST_DIR/config.json" | grep -q "geosite-cn" && echo "PASS: rule_set 合并去重" || echo "FAIL"

rm -rf "$TEST_DIR"
```

Expected: 6 个 PASS。

- [ ] **Step 6: Commit**

```sh
git add openwrt/scripts/generate-config.jq
git commit -m "feat: generate-config.jq 从链路 _policy_content 取分流规则

- chain_routing_rules 改成从 chain._policy_content 取 rule_sets/domains
- DNS rules 用 default_policy (全局 DNS 不按链路分)
- route.rule_set 去重合并所有链路策略的 rule_sets (unique_by tag)"
```

---

## Task 4: chains 表加 policy_name 列 (SQL 迁移脚本)

**Files:**
- Create: `openwrt/scripts/migrate-chain-policy.sh`

vps-db.sh 不在本仓库,用独立 SQL 迁移脚本直接操作 vps.db,避免依赖外部脚本改动。

- [ ] **Step 1: 创建迁移脚本**

Create `openwrt/scripts/migrate-chain-policy.sh`:

```sh
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
```

- [ ] **Step 2: 赋可执行权限**

```sh
chmod +x openwrt/scripts/migrate-chain-policy.sh
```

- [ ] **Step 3: 本地测试 (用 sqlite3 mock)**

```sh
TEST_DB=$(mktemp -d)/test.db
# 创建 mock chains 表 (模拟 vps-db.sh 原始 schema)
sqlite3 "$TEST_DB" "CREATE TABLE chains (id INTEGER PRIMARY KEY, name TEXT, hop_path TEXT, source_cidr TEXT, enabled INTEGER);"
sqlite3 "$TEST_DB" "INSERT INTO chains (id, name, hop_path, enabled) VALUES (1, 'test', '1', 1);"

# 第一次跑: 应加列
sh openwrt/scripts/migrate-chain-policy.sh "$TEST_DB"
sqlite3 "$TEST_DB" "PRAGMA table_info(chains);" | cut -d'|' -f2 | grep -qx "policy_name" && echo "PASS: 首次迁移成功" || echo "FAIL"

# 第二次跑: 应跳过 (幂等)
sh openwrt/scripts/migrate-chain-policy.sh "$TEST_DB" 2>&1 | grep -q "已存在" && echo "PASS: 幂等" || echo "FAIL"

# 验证已有数据 policy_name 为 NULL
sqlite3 "$TEST_DB" "SELECT policy_name FROM chains WHERE id=1;" | grep -qx "" && echo "PASS: 旧数据 policy_name=NULL" || echo "FAIL"

rm -rf "$(dirname "$TEST_DB")"
```

Expected: 3 个 PASS。

- [ ] **Step 4: Commit**

```sh
git add openwrt/scripts/migrate-chain-policy.sh
git commit -m "feat: chains 表加 policy_name 列的迁移脚本

幂等: 检查列已存在则跳过。ALTER TABLE ADD COLUMN policy_name TEXT,
旧链路 policy_name=NULL (等价于用 default 策略)。

vps-db.sh 不在本仓库, 用独立 SQL 迁移脚本绕过。"
```

---

## Task 5: Controller 加策略管理 API

**Files:**
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`

新增 6 个 API action 函数 + 路由注册。`action_chains_add` / `action_chains_update` 的 `chain_fields` 加 `policy_name`。

- [ ] **Step 1: 在 index() 函数加路由注册**

找到 `entry({"admin", "services", "tiktokproxy", "traffic"}, ...)` 这行 (约第 396 行), 在它**前面**插入分流策略菜单和 API 注册:

```lua
    entry({"admin", "services", "tiktokproxy", "policies"}, template("tiktokproxy/policies"), _("分流策略"), 18)
```

然后在 `entry({"admin", "services", "tiktokproxy", "chains_disable"}, call("action_chains_disable"))` 这行后面 (约第 417 行), 插入策略 API 注册:

```lua
    -- 分流策略管理 API
    entry({"admin", "services", "tiktokproxy", "policies_list"}, call("action_policies_list"))
    entry({"admin", "services", "tiktokproxy", "policies_get"}, call("action_policies_get"))
    entry({"admin", "services", "tiktokproxy", "policies_save"}, call("action_policies_save"))
    entry({"admin", "services", "tiktokproxy", "policies_delete"}, call("action_policies_delete"))
    entry({"admin", "services", "tiktokproxy", "policies_clone"}, call("action_policies_clone"))
    -- 链路绑策略 API
    entry({"admin", "services", "tiktokproxy", "chains_bind_policy"}, call("action_chains_bind_policy"))
```

- [ ] **Step 2: 在 action_chains_add 的 chain_fields 加 policy_name**

找到 `action_chains_add` 函数里的 (约第 734 行):

```lua
    local chain_fields = {"name", "enabled", "wifi_ssid", "ap_mac", "ap_ip"}
```

改为:

```lua
    local chain_fields = {"name", "enabled", "wifi_ssid", "ap_mac", "ap_ip", "policy_name"}
```

- [ ] **Step 3: 在 action_chains_update 的 chain_fields 加 policy_name**

找到 `action_chains_update` 函数里的 (约第 940 行):

```lua
    local chain_fields = {"name", "enabled", "source_cidr", "wifi_ssid", "ap_mac", "ap_ip"}
```

改为:

```lua
    local chain_fields = {"name", "enabled", "source_cidr", "wifi_ssid", "ap_mac", "ap_ip", "policy_name"}
```

- [ ] **Step 4: 在文件末尾添加 6 个 action 函数**

在 `action_update_config` 函数后面 (文件末尾, `index()` 之前的位置不合适, 应该在所有 action 函数后面), 找到文件最后一个 function, 在它后面添加。先确认文件最后一行:

Run: `tail -20 openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`

然后追加 6 个函数:

```lua
-- ---------------------------------------------------------------
-- 分流策略管理 API
-- ---------------------------------------------------------------
POLICIES_DIR = "/etc/sing-box/policies"

function action_policies_list()
    log_api("policies_list", "")
    local result = {}
    local f = io.popen("ls " .. POLICIES_DIR .. "/*.json 2>/dev/null")
    if f then
        for line in f:lines() do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            -- 提取文件名 (去掉路径和 .json)
            local fname = line:match("([^/]+)%.json$")
            if fname then
                -- 读 name/notes
                local content = shell_exec("cat " .. line .. " 2>/dev/null")
                local parsed = parse_json(content) or {}
                result[#result+1] = {
                    name = fname,
                    display_name = parsed.name or fname,
                    notes = parsed.notes or "",
                    is_default = (fname == "default")
                }
            end
        end
        f:close()
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({policies = result})
end

function action_policies_get()
    local name = luci.http.formvalue("name") or ""
    if not name:match("^[a-z0-9-]+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid name"})
        return
    end
    local file_path = POLICIES_DIR .. "/" .. name .. ".json"
    if not nixio.fs.access(file_path) then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "policy not found"})
        return
    end
    local content = shell_exec("cat " .. file_path)
    local parsed = parse_json(content)
    if not parsed then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "policy JSON invalid"})
        return
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        name = name,
        display_name = parsed.name or name,
        notes = parsed.notes or "",
        rule_sets = parsed.rule_sets or {},
        direct_domain_suffix = parsed.direct_domain_suffix or {},
        proxy_domain_suffix = parsed.proxy_domain_suffix or {},
        is_default = (name == "default")
    })
end

function action_policies_save()
    local name = luci.http.formvalue("name") or ""
    local display_name = luci.http.formvalue("display_name") or ""
    local notes = luci.http.formvalue("notes") or ""
    local content = luci.http.formvalue("content") or ""

    -- 1. 校验 name 格式
    if not name:match("^[a-z0-9-]+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "name 只允许小写字母/数字/连字符"})
        return
    end
    if #name < 1 or #name > 32 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "name 长度 1-32"})
        return
    end

    -- 2. 校验 content 是合法 JSON
    local parsed = parse_json(content)
    if not parsed then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "content 不是合法 JSON"})
        return
    end
    -- 注入/覆盖 name/notes (以表单字段为准)
    parsed.name = display_name
    parsed.notes = notes

    -- 3. 确保 policies 目录存在
    os.execute("mkdir -p " .. POLICIES_DIR)

    -- 4. 原子写: 临时文件 + rename
    local file_path = POLICIES_DIR .. "/" .. name .. ".json"
    local tmp_path = file_path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "无法写入文件"})
        return
    end
    f:write(require("luci.jsonc").stringify(parsed))
    f:close()
    if os.execute("mv " .. tmp_path .. " " .. file_path) ~= 0 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "文件重命名失败"})
        return
    end

    log_api("policies_save", "name=" .. name .. " display=" .. display_name)
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = "ok", name = name})
end

function action_policies_delete()
    local name = luci.http.formvalue("name") or ""
    if name == "default" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "默认策略不可删除"})
        return
    end
    if not name:match("^[a-z0-9-]+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid name"})
        return
    end
    -- 检查是否有链路在用此策略
    local chains = parse_json(db_cmd("list-chains")) or {}
    for _, c in ipairs(chains) do
        if c.policy_name == name then
            luci.http.prepare_content("application/json")
            luci.http.write_json({error = "链路 #" .. c.id .. " (" .. (c.name or "?") .. ") 仍在使用此策略, 请先换绑"})
            return
        end
    end
    local file_path = POLICIES_DIR .. "/" .. name .. ".json"
    os.execute("rm -f " .. file_path)
    log_api("policies_delete", "name=" .. name)
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = "ok"})
end

function action_policies_clone()
    local src = luci.http.formvalue("src") or ""
    local dest = luci.http.formvalue("dest") or ""
    if not src:match("^[a-z0-9-]+$") or not dest:match("^[a-z0-9-]+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid src or dest name"})
        return
    end
    if #dest < 1 or #dest > 32 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "dest name 长度 1-32"})
        return
    end
    local src_path = POLICIES_DIR .. "/" .. src .. ".json"
    local dest_path = POLICIES_DIR .. "/" .. dest .. ".json"
    if not nixio.fs.access(src_path) then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "源策略不存在"})
        return
    end
    if nixio.fs.access(dest_path) then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "目标策略已存在"})
        return
    end
    os.execute("cp " .. src_path .. " " .. dest_path)
    log_api("policies_clone", "src=" .. src .. " dest=" .. dest)
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = "ok", name = dest})
end

function action_chains_bind_policy()
    local chain_id = luci.http.formvalue("chain_id") or ""
    local policy_name = luci.http.formvalue("policy_name") or ""
    if not chain_id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid chain_id"})
        return
    end
    -- 空 policy_name = 用 default
    if policy_name == "" then policy_name = "default" end
    if not policy_name:match("^[a-z0-9-]+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid policy_name"})
        return
    end
    -- 校验策略文件存在
    local file_path = POLICIES_DIR .. "/" .. policy_name .. ".json"
    if not nixio.fs.access(file_path) then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "策略文件不存在: " .. policy_name})
        return
    end
    log_api("chains_bind_policy", "chain=" .. chain_id .. " policy=" .. policy_name)
    db_cmd("update-chain " .. chain_id .. " '{\"policy_name\":\"" .. policy_name .. "\"}'")
    local ok = apply_config()
    log_api("chains_bind_policy", "apply_config=" .. tostring(ok))
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = ok and "ok" or "error", chain_id = tonumber(chain_id), policy_name = policy_name})
end
```

- [ ] **Step 5: Lua 语法检查**

Run: `luac -p openwrt/luci/controller/tiktokproxy/tiktokproxy.lua && echo "Lua syntax OK"`

Expected: 输出 `Lua syntax OK` (如果有语法错误 luac 会报行号)。

- [ ] **Step 6: Commit**

```sh
git add openwrt/luci/controller/tiktokproxy/tiktokproxy.lua
git commit -m "feat: controller 加分流策略管理 API

新增 6 个 action 函数:
- policies_list/get/save/delete/clone: 策略文件 CRUD
- chains_bind_policy: 链路绑策略 + apply_config

chain_fields 加 policy_name (chains_add/update 透传)
路由注册: /admin/services/tiktokproxy/policies 菜单 + 6 个 API"
```

---

## Task 6: 创建分流策略管理页面 policies.htm

**Files:**
- Create: `openwrt/luci/view/tiktokproxy/policies.htm`

新页面: 策略列表 + 表单/JSON 双模式编辑器。

- [ ] **Step 1: 创建 policies.htm**

Create `openwrt/luci/view/tiktokproxy/policies.htm`:

```html
<%+header%>
<h2 name="content">分流策略</h2>

<div class="chb-card">
  <div class="chb-card-body">
    <div class="chb-card-actions">
      <button type="button" class="chb-btn chb-btn-primary" onclick="showAddPolicy()">+ 新建策略</button>
      <button type="button" class="chb-btn chb-btn-ghost" onclick="loadPolicies()">刷新</button>
    </div>
    <div id="policies_list_area" class="chb-empty">加载中...</div>
  </div>
</div>

<!-- ===== 策略编辑表单 ===== -->
<div class="chb-card" id="policy_form" style="display:none;">
  <div class="chb-card-header">
    <h3 class="chb-card-title" id="policy_form_title">新建策略</h3>
  </div>
  <div class="chb-card-body">
    <input type="hidden" id="p_edit_name">
    <input type="hidden" id="p_is_default" value="0">
    <div class="chb-form-grid">
      <div class="chb-field">
        <label class="chb-label">文件名 (英文) <span class="chb-required">*</span></label>
        <input type="text" class="chb-input" id="p_name" placeholder="tiktok-priority">
        <div class="chb-stat-desc" style="font-size:11px;">小写字母/数字/连字符, 1-32 字符, 新建后不可改</div>
      </div>
      <div class="chb-field">
        <label class="chb-label">显示名</label>
        <input type="text" class="chb-input" id="p_display_name" placeholder="TikTok 优先">
      </div>
    </div>
    <div class="chb-field" style="margin-top:8px;">
      <label class="chb-label">备注</label>
      <input type="text" class="chb-input" id="p_notes" placeholder="策略说明">
    </div>

    <div class="chb-separator-text">
      <button type="button" class="chb-btn chb-btn-sm" id="tab_form_btn" onclick="switchTab('form')">表单模式</button>
      <button type="button" class="chb-btn chb-btn-sm" id="tab_json_btn" onclick="switchTab('json')">原始 JSON</button>
    </div>

    <!-- 表单模式 -->
    <div id="tab_form">
      <div class="chb-field" style="margin-top:8px;">
        <label class="chb-label">Rule Sets (远程规则集)</label>
        <div id="rule_sets_area">
          <label><input type="checkbox" id="rs_geosite_cn" value="geosite-cn"> geosite-cn (国内域名直连)</label><br>
          <label><input type="checkbox" id="rs_geoip_cn" value="geoip-cn"> geoip-cn (国内 IP 直连)</label>
        </div>
      </div>
      <div class="chb-field" style="margin-top:8px;">
        <label class="chb-label">Direct 域名后缀 (一行一个, 走直连)</label>
        <textarea class="chb-input" id="p_direct" rows="6" style="width:100%;font-family:monospace;" placeholder="baidu.com&#10;qq.com"></textarea>
      </div>
      <div class="chb-field" style="margin-top:8px;">
        <label class="chb-label">Proxy 域名后缀 (一行一个, 强制走链路)</label>
        <textarea class="chb-input" id="p_proxy" rows="6" style="width:100%;font-family:monospace;" placeholder="google.com&#10;tiktok.com"></textarea>
      </div>
    </div>

    <!-- JSON 模式 -->
    <div id="tab_json" style="display:none;margin-top:8px;">
      <textarea class="chb-input" id="p_json" rows="20" style="width:100%;font-family:monospace;font-size:12px;" placeholder='{"name":"...","notes":"...","rule_sets":[...],"direct_domain_suffix":[...],"proxy_domain_suffix":[...]}'></textarea>
    </div>

    <div class="chb-btn-group" style="margin-top:12px;">
      <button type="button" class="chb-btn chb-btn-primary" onclick="savePolicy()">保存</button>
      <button type="button" class="chb-btn" onclick="cancelPolicy()">取消</button>
    </div>
  </div>
</div>

<div id="result_msg" class="chb-msg" style="display:none;"></div>

<script type="text/javascript">
var POLICIES_LIST_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","policies_list")%>';
var POLICIES_GET_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","policies_get")%>';
var POLICIES_SAVE_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","policies_save")%>';
var POLICIES_DEL_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","policies_delete")%>';
var POLICIES_CLONE_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","policies_clone")%>';

var currentTab = 'form';

function xhrPost(url, data, callback) {
  var xhr = new XHR();
  xhr.post(url, data, function(x) {
    var json = null;
    if (x.getResponseHeader('Content-Type') == 'application/json') {
      try { json = JSON.parse(x.responseText); } catch(e) { json = null; }
    }
    callback(x, json);
  });
}
function esc(s){if(!s)return'';return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function showMsg(m, t) {
  var d = document.getElementById('result_msg');
  d.style.display = 'block';
  d.innerHTML = m;
  d.className = 'chb-msg ' + (t == 'success' ? 'chb-msg-success' : t == 'error' ? 'chb-msg-error' : 'chb-msg-info');
}

// ===== 策略列表 =====
function loadPolicies() {
  var area = document.getElementById('policies_list_area');
  area.innerHTML = '<div class="chb-empty">加载中...</div>';
  XHR.get(POLICIES_LIST_URL, null, function(x, rv) {
    if (!rv || !rv.policies) {
      area.innerHTML = '<div class="chb-empty">加载失败</div>';
      return;
    }
    if (!rv.policies.length) {
      area.innerHTML = '<div class="chb-empty">无策略, 点击「+ 新建策略」创建 (default 策略会在首次生成配置时自动创建)</div>';
      return;
    }
    var html = '';
    rv.policies.forEach(function(p) {
      html += '<div class="chb-card" style="margin-bottom:8px;">';
      html += '<div class="chb-card-body" style="padding:12px;">';
      html += '<div style="display:flex;justify-content:space-between;align-items:center;">';
      html += '<div><b>&#128196; ' + esc(p.name) + '</b>';
      if (p.display_name && p.display_name != p.name) html += ' <span style="color:#666;">(' + esc(p.display_name) + ')</span>';
      if (p.is_default) html += ' <span class="chb-badge chb-badge-gray">默认</span>';
      html += '</div>';
      html += '<div class="chb-card-actions">';
      html += '<button class="chb-btn chb-btn-sm" onclick="editPolicy(\'' + esc(p.name) + '\')">编辑</button>';
      if (!p.is_default) {
        html += ' <button class="chb-btn chb-btn-sm" onclick="clonePolicy(\'' + esc(p.name) + '\')">复制</button>';
        html += ' <button class="chb-btn chb-btn-sm chb-btn-danger" onclick="delPolicy(\'' + esc(p.name) + '\')">删除</button>';
      }
      html += '</div>';
      html += '</div>';
      if (p.notes) {
        html += '<div style="font-size:12px;color:#999;margin-top:4px;">' + esc(p.notes) + '</div>';
      }
      if (p.is_default) {
        html += '<div style="font-size:11px;color:#999;margin-top:4px;">默认策略, 不可删除; 未绑定策略的链路自动使用此策略</div>';
      }
      html += '</div></div>';
    });
    area.innerHTML = html;
  });
}

// ===== 编辑表单 =====
function showAddPolicy() {
  document.getElementById('policy_form_title').textContent = '新建策略';
  document.getElementById('p_edit_name').value = '';
  document.getElementById('p_is_default').value = '0';
  document.getElementById('p_name').value = '';
  document.getElementById('p_name').disabled = false;
  document.getElementById('p_display_name').value = '';
  document.getElementById('p_notes').value = '';
  document.getElementById('rs_geosite_cn').checked = true;
  document.getElementById('rs_geoip_cn').checked = true;
  document.getElementById('p_direct').value = '';
  document.getElementById('p_proxy').value = '';
  document.getElementById('p_json').value = '';
  switchTab('form');
  document.getElementById('policy_form').style.display = '';
}

function editPolicy(name) {
  XHR.get(POLICIES_GET_URL + '?name=' + encodeURIComponent(name), null, function(x, rv) {
    if (!rv || rv.error) { showMsg('获取失败: ' + (rv && rv.error ? rv.error : ''), 'error'); return; }
    document.getElementById('policy_form_title').textContent = '编辑: ' + name;
    document.getElementById('p_edit_name').value = name;
    document.getElementById('p_is_default').value = rv.is_default ? '1' : '0';
    document.getElementById('p_name').value = name;
    document.getElementById('p_name').disabled = true;  // 编辑时文件名不可改
    document.getElementById('p_display_name').value = rv.display_name || '';
    document.getElementById('p_notes').value = rv.notes || '';
    // rule_sets 复选
    var rsTags = (rv.rule_sets || []).map(function(r){return r.tag;});
    document.getElementById('rs_geosite_cn').checked = rsTags.indexOf('geosite-cn') >= 0;
    document.getElementById('rs_geoip_cn').checked = rsTags.indexOf('geoip-cn') >= 0;
    // domain suffix
    document.getElementById('p_direct').value = (rv.direct_domain_suffix || []).join('\n');
    document.getElementById('p_proxy').value = (rv.proxy_domain_suffix || []).join('\n');
    // JSON 模式内容
    var jsonObj = {
      name: rv.display_name || name,
      notes: rv.notes || '',
      rule_sets: rv.rule_sets || [],
      direct_domain_suffix: rv.direct_domain_suffix || [],
      proxy_domain_suffix: rv.proxy_domain_suffix || []
    };
    document.getElementById('p_json').value = JSON.stringify(jsonObj, null, 2);
    switchTab('form');
    document.getElementById('policy_form').style.display = '';
  });
}

function cancelPolicy() {
  document.getElementById('policy_form').style.display = 'none';
}

// ===== Tab 切换 (表单 <-> JSON) =====
function switchTab(tab) {
  if (tab === currentTab) return;
  // 切换前同步内容
  if (currentTab === 'form' && tab === 'json') {
    // 表单 -> JSON
    var json = formToJson();
    document.getElementById('p_json').value = JSON.stringify(json, null, 2);
  } else if (currentTab === 'json' && tab === 'form') {
    // JSON -> 表单, 解析失败则留在 JSON tab
    var raw = document.getElementById('p_json').value;
    try {
      var parsed = JSON.parse(raw);
      jsonToForm(parsed);
    } catch (e) {
      alert('JSON 解析失败, 无法切换到表单模式:\n' + e.message + '\n\n请修正 JSON 后再切换');
      return;  // 不切换
    }
  }
  currentTab = tab;
  document.getElementById('tab_form').style.display = (tab === 'form') ? '' : 'none';
  document.getElementById('tab_json').style.display = (tab === 'json') ? '' : 'none';
  document.getElementById('tab_form_btn').style.fontWeight = (tab === 'form') ? 'bold' : 'normal';
  document.getElementById('tab_json_btn').style.fontWeight = (tab === 'json') ? 'bold' : 'normal';
}

function formToJson() {
  var ruleSets = [];
  if (document.getElementById('rs_geosite_cn').checked) {
    ruleSets.push({tag:'geosite-cn',type:'remote',format:'binary',url:'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs',download_detour:'direct'});
  }
  if (document.getElementById('rs_geoip_cn').checked) {
    ruleSets.push({tag:'geoip-cn',type:'remote',format:'binary',url:'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs',download_detour:'direct'});
  }
  var directArr = document.getElementById('p_direct').value.split('\n').map(function(s){return s.trim();}).filter(function(s){return s.length > 0;});
  var proxyArr = document.getElementById('p_proxy').value.split('\n').map(function(s){return s.trim();}).filter(function(s){return s.length > 0;});
  return {
    name: document.getElementById('p_display_name').value || document.getElementById('p_name').value,
    notes: document.getElementById('p_notes').value,
    rule_sets: ruleSets,
    direct_domain_suffix: directArr,
    proxy_domain_suffix: proxyArr
  };
}

function jsonToForm(parsed) {
  document.getElementById('p_display_name').value = parsed.name || '';
  document.getElementById('p_notes').value = parsed.notes || '';
  var rsTags = (parsed.rule_sets || []).map(function(r){return r.tag;});
  document.getElementById('rs_geosite_cn').checked = rsTags.indexOf('geosite-cn') >= 0;
  document.getElementById('rs_geoip_cn').checked = rsTags.indexOf('geoip-cn') >= 0;
  document.getElementById('p_direct').value = (parsed.direct_domain_suffix || []).join('\n');
  document.getElementById('p_proxy').value = (parsed.proxy_domain_suffix || []).join('\n');
}

// ===== 保存 =====
function savePolicy() {
  var editName = document.getElementById('p_edit_name').value;
  var name = document.getElementById('p_name').value.trim();
  var displayName = document.getElementById('p_display_name').value.trim();
  var notes = document.getElementById('p_notes').value.trim();

  if (!name) { showMsg('文件名必填', 'error'); return; }
  if (!name.match(/^[a-z0-9-]+$/)) { showMsg('文件名只允许小写字母/数字/连字符', 'error'); return; }

  // 根据当前 tab 取 content
  var content;
  if (currentTab === 'form') {
    content = JSON.stringify(formToJson());
  } else {
    content = document.getElementById('p_json').value;
    // 校验 JSON 合法
    try { JSON.parse(content); } catch (e) {
      showMsg('JSON 不合法: ' + e.message, 'error');
      return;
    }
  }

  var params = 'name=' + encodeURIComponent(name) +
               '&display_name=' + encodeURIComponent(displayName) +
               '&notes=' + encodeURIComponent(notes) +
               '&content=' + encodeURIComponent(content);
  showMsg('正在保存...', 'info');
  xhrPost(POLICIES_SAVE_URL, params, function(x, rv) {
    if (rv && rv.status == 'ok') {
      showMsg('已保存', 'success');
      document.getElementById('policy_form').style.display = 'none';
      loadPolicies();
    } else {
      showMsg('保存失败: ' + (rv && rv.error ? rv.error : ''), 'error');
    }
  });
}

// ===== 复制 =====
function clonePolicy(srcName) {
  var destName = prompt('新策略文件名 (小写字母/数字/连字符):', srcName + '-copy');
  if (!destName) return;
  if (!destName.match(/^[a-z0-9-]+$/)) { showMsg('文件名格式错误', 'error'); return; }
  xhrPost(POLICIES_CLONE_URL, 'src=' + encodeURIComponent(srcName) + '&dest=' + encodeURIComponent(destName), function(x, rv) {
    if (rv && rv.status == 'ok') {
      showMsg('已复制为 ' + destName, 'success');
      loadPolicies();
    } else {
      showMsg('复制失败: ' + (rv && rv.error ? rv.error : ''), 'error');
    }
  });
}

// ===== 删除 =====
function delPolicy(name) {
  if (!confirm('确认删除策略 ' + name + '?\n如有链路在用会被拒绝')) return;
  xhrPost(POLICIES_DEL_URL, 'name=' + encodeURIComponent(name), function(x, rv) {
    if (rv && rv.status == 'ok') {
      showMsg('已删除', 'success');
      loadPolicies();
    } else {
      showMsg('删除失败: ' + (rv && rv.error ? rv.error : ''), 'error');
    }
  });
}

// 初始化
loadPolicies();
</script>
<%+footer%>
```

- [ ] **Step 2: HTM 语法检查 (人工浏览)**

Run: `head -20 openwrt/luci/view/tiktokproxy/policies.htm`

确认: `<%+header%>` 开头, `<%+footer%>` 结尾, JS 里 `var` 声明完整。

- [ ] **Step 3: Commit**

```sh
git add openwrt/luci/view/tiktokproxy/policies.htm
git commit -m "feat: 分流策略管理页面 policies.htm

- 策略列表 (文件名/显示名/备注/默认标记)
- 表单模式 + 原始 JSON 双模式编辑器 (tab 切换, 解析失败留原 tab)
- rule_sets 复选框 (geosite-cn / geoip-cn 预置)
- direct/proxy 域名后缀 textarea (一行一个)
- 新建/编辑/复制/删除 (default 不可删)"
```

---

## Task 7: vps.htm 链路卡片加策略下拉

**Files:**
- Modify: `openwrt/luci/view/tiktokproxy/vps.htm`

链路卡片显示当前策略 + 下拉切换;链路编辑表单加策略字段。

- [ ] **Step 1: 加 JS 变量声明 (URL + 缓存)**

找到 `vps.htm` 里 `var CH_DISABLE_URL=...` 这行 (约第 139 行), 在它后面加:

```js
var POLICIES_LIST_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","policies_list")%>';
var CH_BIND_POLICY_URL='<%=luci.dispatcher.build_url("admin","services","tiktokproxy","chains_bind_policy")%>';
var policiesCache = [];   // 策略列表缓存 (供链路卡片下拉)
```

- [ ] **Step 2: 在 chainsCache 初始化处加载策略**

找到文件末尾的初始化代码 (约第 668 行):

```js
// 先加载链路 (填充 chainsCache), 再加载拓扑 (网口卡片需要链路名映射)
XHR.get(CH_LIST_URL, null, function(x, rv) {
  chainsCache = (rv && rv.chains) ? rv.chains : [];
  loadTopology();
  loadChains();
});
```

替换为:

```js
// 先加载链路 (填充 chainsCache) + 策略 (填充 policiesCache), 再加载拓扑 + 链路卡片
XHR.get(CH_LIST_URL, null, function(x, rv) {
  chainsCache = (rv && rv.chains) ? rv.chains : [];
  XHR.get(POLICIES_LIST_URL, null, function(x2, pv) {
    policiesCache = (pv && pv.policies) ? pv.policies : [];
    loadTopology();
    loadChains();
  });
});
```

- [ ] **Step 3: 在 loadChains 的链路卡片加策略下拉**

找到 `loadChains` 函数里「服务子网显示」那段 (约第 351 行):

```js
        // 服务子网显示
        var servedSubnets = subnetsCache.filter(function(s){ return s.chain_id == c.id; });
        if (servedSubnets.length) {
          card += '<div class="chb-stat-desc">服务子网: ' + servedSubnets.map(function(s){ return esc(s.name + ' (' + s.interface + ')'); }).join(', ') + '</div>';
        }
```

在它**后面**插入策略下拉:

```js
        // 分流策略下拉
        var currentPolicy = c.policy_name || 'default';
        var policyOptions = policiesCache.map(function(p) {
          var sel = (p.name == currentPolicy) ? ' selected' : '';
          var label = p.name === p.display_name ? p.name : (p.name + ' (' + p.display_name + ')');
          return '<option value="' + esc(p.name) + '"' + sel + '>' + esc(label) + '</option>';
        }).join('');
        card += '<div class="chb-stat-desc" style="margin-top:6px;">&#127919; 分流策略: <select onchange="bindPolicy(' + c.id + ', this.value)" style="margin-left:4px;">' + policyOptions + '</select></div>';
```

- [ ] **Step 4: 加 bindPolicy JS 函数**

在 `delChain` 函数后面 (约第 615 行) 加:

```js
function bindPolicy(chainId, policyName) {
  if (!confirm('切换分流策略为 ' + policyName + '?\n将重新生成配置并重启 sing-box')) return;
  showMsg('正在应用策略...', 'info');
  xhrPost(CH_BIND_POLICY_URL, 'chain_id=' + chainId + '&policy_name=' + encodeURIComponent(policyName), function(x, rv) {
    if (rv && rv.status == 'ok') { showMsg('策略已切换', 'success'); loadChains(); }
    else showMsg('切换失败: ' + (rv && rv.error ? rv.error : ''), 'error');
  });
}
```

- [ ] **Step 5: 在链路编辑表单加策略字段**

找到链路编辑表单的 `chb-form-grid` (约第 39-45 行):

```html
    <div class="chb-form-grid">
      <div class="chb-field"><label class="chb-label">链路名称 <span class="chb-required">*</span></label><input type="text" class="chb-input" id="c_name" placeholder="mmlive-us1"></div>
      <div class="chb-field"><label class="chb-label">启用</label><div class="chb-select-wrap"><select class="chb-input" id="c_enabled"><option value="1">启用</option><option value="0">禁用</option></select></div></div>
      <div class="chb-field"><label class="chb-label">子网 CIDR</label><input type="text" class="chb-input" id="c_source_cidr" placeholder="留空自动分配"></div>
      <div class="chb-field"><label class="chb-label">AP MAC</label><input type="text" class="chb-input" id="c_ap_mac" placeholder="选填"></div>
      <div class="chb-field"><label class="chb-label">AP IP</label><input type="text" class="chb-input" id="c_ap_ip" placeholder="选填"></div>
    </div>
```

在最后一个 `chb-field` (AP IP) 后面加一个策略字段:

```html
      <div class="chb-field"><label class="chb-label">AP IP</label><input type="text" class="chb-input" id="c_ap_ip" placeholder="选填"></div>
      <div class="chb-field"><label class="chb-label">分流策略</label><div class="chb-select-wrap"><select class="chb-input" id="c_policy_name"><option value="">默认 (default)</option></select></div></div>
```

- [ ] **Step 6: 在 showAddChain / editChain 填充策略下拉**

找到 `showAddChain` 函数 (约第 415 行):

```js
function showAddChain() {
  document.getElementById('chain_form_title').textContent = '添加链路';
  document.getElementById('c_edit_id').value = '';
  ['c_name','c_source_cidr','c_ap_mac','c_ap_ip'].forEach(function(id) {
    document.getElementById(id).value = '';
  });
  document.getElementById('c_enabled').value = '1';
  hopCounter = 0;
  document.getElementById('hops_container').innerHTML = '';
  addHop();
  document.getElementById('chain_form').style.display = '';
}
```

替换为:

```js
function showAddChain() {
  document.getElementById('chain_form_title').textContent = '添加链路';
  document.getElementById('c_edit_id').value = '';
  ['c_name','c_source_cidr','c_ap_mac','c_ap_ip'].forEach(function(id) {
    document.getElementById(id).value = '';
  });
  document.getElementById('c_enabled').value = '1';
  // 填充策略下拉
  fillPolicySelect('');
  hopCounter = 0;
  document.getElementById('hops_container').innerHTML = '';
  addHop();
  document.getElementById('chain_form').style.display = '';
}

function fillPolicySelect(selectedName) {
  var sel = document.getElementById('c_policy_name');
  var html = '<option value="">默认 (default)</option>';
  policiesCache.forEach(function(p) {
    var isSel = (p.name == selectedName) ? ' selected' : '';
    html += '<option value="' + esc(p.name) + '"' + isSel + '>' + esc(p.name) + (p.display_name && p.display_name != p.name ? ' (' + esc(p.display_name) + ')' : '') + '</option>';
  });
  sel.innerHTML = html;
}
```

找到 `editChain` 函数里 `document.getElementById('c_enabled').value = rv.enabled ? '1' : '0';` 这行 (约第 437 行), 在它后面加:

```js
    // 填充策略下拉
    fillPolicySelect(rv.policy_name || '');
```

- [ ] **Step 7: 在 saveChain 收集 policy_name**

找到 `saveChain` 函数里的 `var d = {...}` (约第 561 行):

```js
  var d = {
    name: name,
    enabled: document.getElementById('c_enabled').value,
    source_cidr: cidr,
    ap_mac: document.getElementById('c_ap_mac').value.trim(),
    ap_ip: document.getElementById('c_ap_ip').value.trim(),
    hops: JSON.stringify(hops)
  };
```

加一行 `policy_name`:

```js
  var d = {
    name: name,
    enabled: document.getElementById('c_enabled').value,
    source_cidr: cidr,
    ap_mac: document.getElementById('c_ap_mac').value.trim(),
    ap_ip: document.getElementById('c_ap_ip').value.trim(),
    policy_name: document.getElementById('c_policy_name').value,
    hops: JSON.stringify(hops)
  };
```

- [ ] **Step 8: HTM 语法检查**

Run: `grep -c "function " openwrt/luci/view/tiktokproxy/vps.htm`

确认新增了 `bindPolicy` 和 `fillPolicySelect` 两个函数 (计数应比改动前多 2)。

- [ ] **Step 9: Commit**

```sh
git add openwrt/luci/view/tiktokproxy/vps.htm
git commit -m "feat: vps.htm 链路卡片加策略下拉 + 编辑表单加策略字段

- 链路卡片: 显示当前策略 + 下拉切换 (onchange 调 chains_bind_policy)
- 编辑表单: 加「分流策略」下拉 (留空 = default)
- showAddChain/editChain: 填充策略下拉
- saveChain: 收集 policy_name 一起提交
- 初始化: 加载 policiesCache 供下拉用"
```

---

## Task 8: 更新 AGENTS.md 路径表

**Files:**
- Modify: `AGENTS.md`

- [ ] **Step 1: 读取 AGENTS.md 当前路径表**

Run: `grep -A 20 "软路由文件部署路径" AGENTS.md`

- [ ] **Step 2: 在路径表加新文件**

找到路径表里 `openwrt/scripts/routing-rules.json` 这行, 在它后面加:

```
| `openwrt/scripts/policy-migrate.sh` | `/usr/bin/policy-migrate.sh` |
| `openwrt/scripts/migrate-chain-policy.sh` | `/usr/bin/migrate-chain-policy.sh` |
| `openwrt/luci/view/tiktokproxy/policies.htm` | `/usr/lib/lua/luci/view/tiktokproxy/policies.htm` |
```

- [ ] **Step 3: Commit**

```sh
git add AGENTS.md
git commit -m "docs: AGENTS.md 加分流策略相关文件路径

policy-migrate.sh / migrate-chain-policy.sh / policies.htm 的本地->软路由路径映射"
```

---

## Task 9: 集成测试清单 (软路由上执行, 人工验证)

**Files:**
- 无代码改动, 只是在软路由上验证

本机无法 SSH 到软路由 (无密钥), 这一步需要用户在软路由上执行。

- [ ] **Step 1: 推送代码到 GitHub**

```sh
git push origin main
```

- [ ] **Step 2: 软路由拉取 + 部署**

在软路由上执行 (用户操作):

```sh
cd /root/vps-deployment-script  # 或实际仓库路径
git pull

# 部署脚本
cp openwrt/scripts/policy-migrate.sh /usr/bin/policy-migrate.sh
cp openwrt/scripts/migrate-chain-policy.sh /usr/bin/migrate-chain-policy.sh
cp openwrt/scripts/generate-config.sh /etc/sing-box/generate-config.sh
cp openwrt/scripts/generate-config.jq /etc/sing-box/generate-config.jq
chmod +x /usr/bin/policy-migrate.sh /usr/bin/migrate-chain-policy.sh

# 部署 LuCI
cp openwrt/luci/controller/tiktokproxy/tiktokproxy.lua /usr/lib/lua/luci/controller/tiktokproxy/tiktokproxy.lua
cp openwrt/luci/view/tiktokproxy/policies.htm /usr/lib/lua/luci/view/tiktokproxy/policies.htm
cp openwrt/luci/view/tiktokproxy/vps.htm /usr/lib/lua/luci/view/tiktokproxy/vps.htm

# 清 LuCI 字节码缓存
rm -rf /tmp/luci-modulecache/*
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart
```

- [ ] **Step 3: 跑迁移 (chains 表加列 + 策略目录)**

```sh
# chains 表加 policy_name 列
/usr/bin/migrate-chain-policy.sh
# 期望: [migrate] chains 表已加 policy_name 列

# 验证列已加
sqlite3 /etc/sing-box/vps.db "PRAGMA table_info(chains);" | grep policy_name
# 期望: 看到 policy_name|TEXT

# 跑策略迁移 (会在首次 generate-config.sh 时自动跑, 也可手动)
/usr/bin/policy-migrate.sh
# 期望: [policy-migrate] 已从 routing-rules.json 迁移到 policies/default.json

ls /etc/sing-box/policies/
# 期望: default.json
ls /etc/sing-box/routing-rules.json.legacy
# 期望: 文件存在 (旧文件备份)
```

- [ ] **Step 4: 重新生成配置 + 重启 sing-box**

```sh
/etc/sing-box/generate-config.sh
# 期望: 看到 "策略加载:" 段, 每条链路 -> 策略 default
#       生成 config.json 成功

sing-box check -c /etc/sing-box/config.json
# 期望: 无输出 (校验通过)

/etc/init.d/sing-box restart
sleep 5
pidof sing-box
# 期望: 有 PID
```

- [ ] **Step 5: 验证 LuCI 页面可访问**

浏览器打开 `http://192.168.7.1/cgi-bin/luci/admin/services/tiktokproxy/policies`

期望:
- 看到「分流策略」页面
- 列表里有 `default` 一条, 标记「默认」
- 点击「编辑」能看到表单模式, 含 baidu.com/qq.com 等域名
- 切到「原始 JSON」能看到完整 JSON

- [ ] **Step 6: 验证链路卡片策略下拉**

浏览器打开 `http://192.168.7.1/cgi-bin/luci/admin/services/tiktokproxy/vps`

期望:
- 每条链路卡片下面有「🎯 分流策略: [下拉]」
- 下拉里至少有 `default`
- 当前选中的是 `default` (旧链路 policy_name=NULL 回退 default)

- [ ] **Step 7: 新建一个测试策略并验证**

在「分流策略」页面:
1. 点「+ 新建策略」
2. 文件名填 `test-policy`, 显示名 `测试策略`
3. Direct 域名填 `example.com`
4. Proxy 域名填 `test.com`
5. 保存

在链路页面:
1. 找一条链路, 下拉切到 `test-policy`
2. 确认切换
3. 等 15 秒, 刷新看状态是否运行中

在软路由上验证:
```sh
cat /etc/sing-box/policies/test-policy.json
# 期望: 含 example.com / test.com

jq -r '.route.rules[] | select(.source_ip_cidr | index("192.168.7.0/24")) | .domain_suffix // [] | .[]' /etc/sing-box/config.json | grep test.com
# 期望: 输出 test.com (说明该链路用了 test-policy 策略)
```

- [ ] **Step 8: 验证删除保护**

1. 在「分流策略」页面尝试删除 `default` -> 应被拒「默认策略不可删除」
2. 尝试删除 `test-policy` -> 应被拒「链路 #N 仍在使用此策略」
3. 先把链路下拉切回 `default`, 再删除 `test-policy` -> 应成功

- [ ] **Step 9: 回归测试 (旧行为不变)**

```sh
# 验证: 未绑定策略的链路 (= NULL) 走 default
curl -s https://myip.ipip.net
# 期望: 仍显示 CN 出口 (国内域名直连未变)

curl -s https://ifconfig.me
# 期望: 仍显示 US 出口 (国外域名走链路未变)
```

- [ ] **Step 10: 清理 (可选)**

如果测试通过, 把 test-policy 删掉, 所有链路切回 default。

---

## Self-Review

**1. Spec coverage 检查:**

| Spec 章节 | 对应 Task |
|-----------|-----------|
| §1 文件格式 | Task 1 (迁移脚本生成 default.json) + Task 5 (save API 校验) |
| §2 迁移逻辑 | Task 1 (policy-migrate.sh) |
| §3 chains 表扩展 | Task 4 (migrate-chain-policy.sh) |
| §4 generate-config.sh 改动 | Task 2 |
| §5 generate-config.jq 改动 | Task 3 |
| §6 Controller API | Task 5 |
| §7 policies.htm 页面 | Task 6 |
| §8 vps.htm 链路卡片 | Task 7 |
| §9 链路编辑表单 | Task 7 (Step 5-7) |
| §10 AGENTS.md | Task 8 |
| 错误处理 (策略缺失/JSON 非法/删除在用) | Task 2 (Step 4) + Task 5 (delete API) |
| 测试策略 | 每个 Task 的本地测试 + Task 9 集成测试 |

✅ 所有 spec 章节都有对应 Task。

**2. Placeholder 扫描:**

无 TBD/TODO/「类似上面」等占位符。每个 step 都有完整代码或命令。

**3. 类型一致性:**

- `_policy_content` / `_policy_name` 在 Task 2 (shell 生成) 和 Task 3 (jq 读取) 一致 ✅
- `policy_name` 在 Task 4 (DB 列) / Task 5 (controller 透传) / Task 7 (前端字段) 一致 ✅
- `action_policies_*` / `action_chains_bind_policy` 在 Task 5 (定义) 和 Task 6/7 (URL 引用) 一致 ✅
- `policiesCache` / `policiesCache` 在 Task 7 Step 2/3 一致 ✅

**4. 发现的一个小问题:** Task 5 Step 4 里 `POLICIES_DIR = "/etc/sing-box/policies"` 是全局变量, 但 Lua 的 `module(..., package.seeall)` 模式下全局变量 OK (与文件顶部 `GENERATOR` / `VPS_DB` 一致)。✅
