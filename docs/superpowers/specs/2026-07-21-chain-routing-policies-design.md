# 链路分流策略管理设计

> 状态: 设计中
> 日期: 2026-07-21
> 关联: `openwrt/scripts/routing-rules.json` + `openwrt/scripts/generate-config.sh` + `openwrt/scripts/generate-config.jq`

## 背景与问题

当前分流策略是**单一全局文件** `/etc/sing-box/routing-rules.json`,所有链路共用这份规则。sing-box 在软路由本地用 `generate-config.sh` + `generate-config.jq` 读取该文件,按域名把流量分成「走链路 VLESS 多跳」和「直连」两类:

```
Mac -> 软路由 sing-box -> routing-rules.json 域名匹配
                          ├─ 国内域名 -> direct (CN 出口)
                          └─ 国外域名 -> chain VLESS 多跳 (US 出口)
```

`ip.net.coffee` 上看到的 `cn 183.192.111.19` 和 `us 216.36.109.10` 两个出口正是这套规则在工作,不是异常。

**痛点**: 全局单一规则无法按链路定制。例如:
- `tiktok-us-double` 链路想用「TikTok 优先走链路」策略
- `mmlive-cn` 链路想用「全直连」策略
- 测试链路想用「全部强制走链路(无直连兜底)」策略

目前所有链路共用一份规则,改了影响所有链路。

## 目标

1. 把单一 `routing-rules.json` 升级成**可创建多个**的策略文件
2. 在 LuCI 后台提供独立的「分流策略」管理页面:创建/编辑/删除/复制
3. 在「节点与链路管理」页面的**链路卡片**里增加策略下拉,一条链路绑定一个策略
4. 完全向后兼容:现有部署无需手动迁移,首次启动自动迁移
5. 编辑器同时支持「表单分组」和「原始 JSON」双模式

## 非目标 (Out of Scope)

- 不扩展策略 schema(不加 `domain_keyword` / `ip_cidr` / `process_name` 等新字段,沿用现有 `rule_sets` / `direct_domain_suffix` / `proxy_domain_suffix`)
- 不支持一条链路绑定多个策略(一对一)
- 不把策略内容存入 vps.db(文件系统即真相)
- 不支持策略版本/历史/回滚(YAGNI)
- 不修改 DNS 分流逻辑(`generate-config.jq` 里的 `dns.rules` 保持不变)

## 架构

### 分层

```
┌────────────────────────────────────────────────────────────────┐
│  LuCI 网页层 (不会断网)                                         │
│    ├─ /admin/services/tiktokproxy/policies  新页面: 策略 CRUD  │
│    └─ /admin/services/tiktokproxy/vps       链路卡片加策略下拉 │
└────────────────────────────────────────────────────────────────┘
                          ↓
┌────────────────────────────────────────────────────────────────┐
│  Controller 层 (tiktokproxy.lua)                               │
│    ├─ action_policies_list / get / add / update / delete       │
│    └─ action_chains_bind_policy (链路绑策略)                   │
└────────────────────────────────────────────────────────────────┘
                          ↓
┌────────────────────────────────────────────────────────────────┐
│  策略文件层 (文件系统即真相)                                    │
│  /etc/sing-box/policies/                                       │
│    ├─ default.json             (默认, 可编辑不可删)             │
│    ├─ tiktok-priority.json     (用户创建)                       │
│    └─ cn-direct.json           (用户创建)                       │
└────────────────────────────────────────────────────────────────┘
                          ↓ 读
┌────────────────────────────────────────────────────────────────┐
│  生成器 (generate-config.sh + generate-config.jq)              │
│    每条链路按 policy_name 读取对应策略文件                      │
│    未绑定 -> 回退 default.json                                  │
└────────────────────────────────────────────────────────────────┘
                          ↓
┌────────────────────────────────────────────────────────────────┐
│  vps.db  chains 表新增 policy_name 字段                        │
└────────────────────────────────────────────────────────────────┘
```

### 数据流

```
1. 用户在「分流策略」页面创建策略 tiktok-priority.json
2. 用户在「链路管理」页面的 tiktok-us-double 链路卡片选 tiktok-priority
3. Controller: db_cmd("update-chain <id> '{\"policy_name\":\"tiktok-priority\"}'")
4. Controller: apply_config() -> generate-config.sh
5. generate-config.sh: 读 chain.policy_name -> 读 /etc/sing-box/policies/tiktok-priority.json
6. generate-config.jq: 用该策略为此链路生成 route.rules
7. sing-box 重启生效
```

## 详细设计

### 1. 策略文件格式

**路径**: `/etc/sing-box/policies/<name>.json`

**Schema** (沿用现有字段, 加 `name`/`notes` 元数据):

```json
{
  "name": "默认策略",
  "notes": "国内直连 + 国外走链路, 迁移自 routing-rules.json",
  "rule_sets": [
    {
      "tag": "geosite-cn",
      "type": "remote",
      "format": "binary",
      "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs",
      "download_detour": "direct"
    },
    {
      "tag": "geoip-cn",
      "type": "remote",
      "format": "binary",
      "url": "https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs",
      "download_detour": "direct"
    }
  ],
  "direct_domain_suffix": [
    "baidu.com", "qq.com", "bilibili.com", "taobao.com"
  ],
  "proxy_domain_suffix": [
    "google.com", "youtube.com", "tiktok.com", "github.com"
  ]
}
```

**字段说明**:

| 字段 | 类型 | 必填 | 说明 |
|------|------|------|------|
| `name` | string | 是 | 展示名 (中文可), 用于 UI 显示 |
| `notes` | string | 否 | 备注, UI 显示 |
| `rule_sets` | array | 否 | sing-box 远程规则集, 空数组等同不使用 geosite/geoip |
| `direct_domain_suffix` | array | 否 | 匹配后缀走 direct (链路内直连) |
| `proxy_domain_suffix` | array | 否 | 匹配后缀强制走链路 (优先级最高) |

**文件名约束**:
- 正则: `^[a-z0-9-]+$` (只允许小写字母/数字/连字符)
- 长度: 1-32 字符
- 保留名: `default` (默认策略, 可编辑不可删除)
- 扩展名: 存盘自动补 `.json`, DB 里存不带后缀的 name

### 2. 迁移逻辑 (首次启动)

**触发点**: `generate-config.sh` 启动时执行 `ensure_policies_dir` 函数

**逻辑**:
```
1. 若 /etc/sing-box/policies/ 不存在 -> mkdir -p
2. 若 policies/default.json 不存在:
   a. 若 /etc/sing-box/routing-rules.json 存在 (旧部署):
      - 读取旧文件
      - 注入 name="默认策略", notes="迁移自 routing-rules.json"
      - 写入 policies/default.json
      - 旧文件改名为 routing-rules.json.legacy (保留备份, 不删)
   b. 若旧文件也不存在 (全新部署):
      - 写入内置默认 (就是当前 routing-rules.json 的内容)
3. 若 default.json 已存在 -> 跳过 (不覆盖用户修改)
```

**向后兼容保证**: 升级后第一次跑 `generate-config.sh` 就会自动迁移,无需人工介入。

### 3. chains 表扩展

**新字段**: `policy_name TEXT` (NULL 或空字符串 = 用 `default`)

**vps-db.sh 改动**:
- 现有 `add-chain` / `update-chain` 是通用 JSON 字段透传 (从 controller 传 `{"policy_name":"xxx"}` 进来, vps-db.sh 用 SQLite 的 JSON 函数提取字段写入), **不需要改 vps-db.sh 的 add/update 逻辑**, 只需保证 `policy_name` 列存在
- `list-chains` / `get-chain`: `SELECT *` 自动带出新列, **不需要改**
- **唯一要改的**: vps-db.sh 启动时的表初始化/migration 逻辑, 加一行 `ALTER TABLE`

**migration (vps-db.sh 启动时)**:
```sh
# 检查 chains 表是否有 policy_name 列, 没有则加
if ! sqlite3 "$DB_FILE" "PRAGMA table_info(chains)" | grep -q "^policy_name|"; then
    sqlite3 "$DB_FILE" "ALTER TABLE chains ADD COLUMN policy_name TEXT"
    echo "[vps-db] chains 表已加 policy_name 列" >&2
fi
```

**向后兼容**: 已有链路 `policy_name = NULL`, generate-config.sh 里用 `// "default"` 兜底, 行为与升级前完全一致

**Controller 改动**:
- `action_chains_add` / `action_chains_update`: `chain_fields` 数组加 `"policy_name"` (透传, 不需特殊处理)
- `action_chains_list`: 自动带出 `policy_name` (SELECT * 已含)
- 新增 `action_chains_bind_policy(id, policy_name)`: 单独的链路绑策略 API (与 `subnets_bind` 对称)

### 4. generate-config.sh 改动

**当前逻辑** (单一全局文件):
```sh
ROUTING_RULES_FILE="$CONF_DIR/routing-rules.json"
# ...
echo "$CHAINS_JSON" | jq -n \
    --slurpfile chains /dev/stdin \
    --slurpfile routing "$ROUTING_RULES_FILE" \  # <-- 单一文件
    ...
```

**改后逻辑** (按链路读策略):
```sh
POLICIES_DIR="$CONF_DIR/policies"
DEFAULT_POLICY="$POLICIES_DIR/default.json"

ensure_policies_dir  # 见 §2 迁移逻辑

# 为每条链路解析 policy_name, 读取对应策略文件内容, 注入到 chain 对象
CHAINS_JSON=$(echo "$CHAINS_JSON" | jq -c --slurpfile default "$DEFAULT_POLICY" '
  map(. + {
    policy_name: (.policy_name // "default"),
    # 读不到对应策略文件时回退 default
    policy_content: (
      (.policy_name // "default") as $pn |
      (input_filename? // "") as $_ |  # 占位, jq 不能直接读文件
      ($default[0])  # 简化: 实际在 shell 层读文件
    )
  })
')
```

**实现细节** (jq 不能直接读外部文件, 需 shell 层循环):

shell 层为每条链路读对应策略文件,把策略内容内嵌到 chain 对象的 `_policy_content` 字段,这样 generate-config.jq 只需要从 `chain._policy_content` 取规则即可,不用关心文件读取。

```sh
POLICIES_DIR="$CONF_DIR/policies"
DEFAULT_POLICY="$POLICIES_DIR/default.json"

# 1. 迁移: 确保 policies 目录 + default.json 存在
ensure_policies_dir  # 见 §2 迁移逻辑

# 2. 读 default 策略内容 (用于 DNS 分流, 见 §5)
DEFAULT_POLICY_JSON=$(cat "$DEFAULT_POLICY")

# 3. 为每条链路读策略文件, 内嵌到 chain._policy_content
#    未绑定或文件缺失时回退 default
CHAINS_JSON=$(echo "$CHAINS_JSON" | jq -c '.[]' | while read -r chain; do
    policy_name=$(echo "$chain" | jq -r '.policy_name // "default"')
    policy_file="$POLICIES_DIR/$policy_name.json"
    if [ ! -f "$policy_file" ]; then
        echo "[warn] 链路 $(echo "$chain" | jq -r '.name') 策略文件 $policy_file 不存在, 回退 default" >&2
        policy_name="default"
        policy_file="$DEFAULT_POLICY"
    fi
    # 校验 JSON 合法 (非法则整个 generate 失败, 保留旧 config.json)
    if ! jq -e . "$policy_file" >/dev/null 2>&1; then
        echo "[error] 策略文件 $policy_file JSON 不合法, 中止生成" >&2
        exit 1
    fi
    # 内嵌策略内容到 chain 对象
    echo "$chain" | jq -c --slurpfile p "$policy_file" \
        '. + {_policy_content: $p[0], _policy_name: "'"$policy_name"'"}'
done | jq -s '.')

# 4. 传给 jq 脚本: chains (含 _policy_content) + default 策略 (用于 DNS)
#    注意: busybox sh 不支持进程替换 <(...), 用临时文件
#    注意: --slurpfile 不能用 /dev/stdin (管道已占用 stdin), 用临时文件
CHAINS_TMP=$(mktemp)
DEFAULT_TMP=$(mktemp)
echo "$CHAINS_JSON" > "$CHAINS_TMP"
echo "$DEFAULT_POLICY_JSON" > "$DEFAULT_TMP"
jq -n \
    --slurpfile chains "$CHAINS_TMP" \
    --slurpfile default "$DEFAULT_TMP" \
    -f "$JQ_SCRIPT" > "$OUTPUT"
rm -f "$CHAINS_TMP" "$DEFAULT_TMP"
```

**日志增强**: 生成完成后打印每条链路实际使用的策略:
```sh
echo "策略加载:"
echo "$CHAINS_JSON" | jq -r '.[] | "  链路 \(.name) -> 策略 \(_policy_name)"' 2>/dev/null
```

### 5. generate-config.jq 改动

**当前** (第 58-88 行 `chain_routing_rules`): 从全局 `$routing[0]` 取规则

**改后**: 从 `chain._policy_content` 取规则 (每条链路独立)

```jq
# 旧:
def routing: $routing[0];
def chain_routing_rules(chain):
    chain as $c |
    (routing.rule_sets // []) as $rule_sets |
    (routing.direct_domain_suffix // []) as $direct_domains |
    (routing.proxy_domain_suffix // []) as $proxy_domains |
    ...

# 新:
def chain_routing_rules(chain):
    chain as $c |
    ($c._policy_content.rule_sets // []) as $rule_sets |
    ($c._policy_content.direct_domain_suffix // []) as $direct_domains |
    ($c._policy_content.proxy_domain_suffix // []) as $proxy_domains |
    (chain_final_tag($c)) as $tag |
    # 过滤无效 cidr
    ($c.resolved_cidrs | map(select(is_valid_cidr))) as $valid_cidrs |
    if ($valid_cidrs | length) == 0 then []
    else
        ($valid_cidrs) as $cidrs |
        # 1. 强制代理域名
        (if ($proxy_domains | length) > 0 then
            [{source_ip_cidr: $cidrs, domain_suffix: $proxy_domains, outbound: $tag}]
         else [] end)
        # 2. geosite-cn 直连
        + (if ($rule_sets | any(.tag == "geosite-cn")) then
            [{source_ip_cidr: $cidrs, rule_set: "geosite-cn", outbound: "direct"}]
         else [] end)
        # 3. geoip-cn 直连
        + (if ($rule_sets | any(.tag == "geoip-cn")) then
            [{source_ip_cidr: $cidrs, rule_set: "geoip-cn", outbound: "direct"}]
           else [] end)
        # 4. 自定义直连域名
        + (if ($direct_domains | length) > 0 then
            [{source_ip_cidr: $cidrs, domain_suffix: $direct_domains, outbound: "direct"}]
           else [] end)
        # 5. 默认走链路
        + [{source_ip_cidr: $cidrs, outbound: $tag}]
    end;
```

**DNS 部分改动**: 当前 DNS 用全局 `routing.proxy_domain_suffix` 决定哪些域名用 8.8.8.8 解析。改后用 **default 策略** (通过 `$default[0]` 传入, 见 §4 shell 层的 `--slurpfile default`)。

**设计决策**: DNS 分流规则用 **default 策略** (全局 DNS 不再按链路分)。原因:
- DNS 在 sing-box 里是全局的, 不按 source_ip_cidr 分链路
- 各链路策略如果不同, DNS 服务器无法同时满足
- default 策略代表了「系统默认期望的 DNS 分流」, 足够用

```jq
def default_policy: $default[0];

# ...
dns: {
    strategy: "ipv4_only",
    servers: [
        { tag: "local-dns", address: "223.5.5.5", detour: "direct" },
        { tag: "proxy-dns", address: "8.8.8.8", detour: "direct" }
    ],
    rules: [
        { rule_set: "geosite-cn", server: "local-dns" },
        # DNS 分流用 default 策略的 proxy_domain_suffix
        { domain_suffix: (default_policy.proxy_domain_suffix // []), server: "proxy-dns" }
    ],
    final: "proxy-dns"
}
```

**`route.rule_set` 改动**: 多条链路可能用不同策略, 各策略的 `rule_sets` URL 可能不同。sing-box 的 `route.rule_set` 是全局的, 需要去重合并所有链路策略的 rule_sets:

```jq
# 收集所有链路策略里用到的 rule_sets, 按 tag 去重
def merged_rule_sets:
    [chains[] | ._policy_content.rule_sets // [] | .[]]
    | unique_by(.tag);
```

### 6. Controller 新增 API

**路径**: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`

**新增路由注册**:
```lua
entry({"admin", "services", "tiktokproxy", "policies"}, template("tiktokproxy/policies"), _("分流策略"), 18)
-- 策略管理 API
entry({"admin", "services", "tiktokproxy", "policies_list"}, call("action_policies_list"))
entry({"admin", "services", "tiktokproxy", "policies_get"}, call("action_policies_get"))
entry({"admin", "services", "tiktokproxy", "policies_save"}, call("action_policies_save"))
entry({"admin", "services", "tiktokproxy", "policies_delete"}, call("action_policies_delete"))
entry({"admin", "services", "tiktokproxy", "policies_clone"}, call("action_policies_clone"))
-- 链路绑策略 API (单独, 与 subnets_bind 对称)
entry({"admin", "services", "tiktokproxy", "chains_bind_policy"}, call("action_chains_bind_policy"))
```

**API 设计**:

| API | 方法 | 参数 | 返回 | 功能 |
|-----|------|------|------|------|
| `policies_list` | GET | - | `[{name, display_name, notes, is_default}]` | 列出所有策略 |
| `policies_get` | GET | `name` | 策略 JSON | 读取单个策略 |
| `policies_save` | POST | `name, display_name, notes, content` | `{status, name}` | 新建或更新策略 |
| `policies_delete` | POST | `name` | `{status}` | 删除策略 (default 不可删) |
| `policies_clone` | POST | `src, dest` | `{status, name}` | 复制策略 |
| `chains_bind_policy` | POST | `chain_id, policy_name` | `{status}` | 链路绑策略 (并 apply_config) |

**action_policies_save 实现**:
```lua
function action_policies_save()
    local name = luci.http.formvalue("name") or ""
    local display_name = luci.http.formvalue("display_name") or ""
    local notes = luci.http.formvalue("notes") or ""
    local content = luci.http.formvalue("content") or ""  -- JSON 字符串

    -- 1. 校验 name 格式
    if not name:match("^[a-z0-9-]+$") then
        luci.http.write_json({error = "name 只允许小写字母/数字/连字符"})
        return
    end
    if #name < 1 or #name > 32 then
        luci.http.write_json({error = "name 长度 1-32"})
        return
    end

    -- 2. 校验 content 是合法 JSON 且包含必需字段
    local parsed = parse_json(content)
    if not parsed then
        luci.http.write_json({error = "content 不是合法 JSON"})
        return
    end
    -- 注入/覆盖 name/notes (以表单字段为准, 不信 content 里的)
    parsed.name = display_name
    parsed.notes = notes

    -- 3. 确保 policies 目录存在 (首次保存)
    local policies_dir = "/etc/sing-box/policies"
    os.execute("mkdir -p " .. policies_dir)

    -- 4. 原子写: 临时文件 + rename
    local file_path = policies_dir .. "/" .. name .. ".json"
    local tmp_path = file_path .. ".tmp"
    local f = io.open(tmp_path, "w")
    if not f then
        luci.http.write_json({error = "无法写入文件"})
        return
    end
    f:write(require("luci.jsonc").stringify(parsed))
    f:close()
    if os.execute("mv " .. tmp_path .. " " .. file_path) ~= 0 then
        luci.http.write_json({error = "文件重命名失败"})
        return
    end

    log_api("policies_save", "name=" .. name .. " display=" .. display_name)
    luci.http.write_json({status = "ok", name = name})
end
```

**action_policies_delete 实现** (default 不可删):
```lua
function action_policies_delete()
    local name = luci.http.formvalue("name") or ""
    if name == "default" then
        luci.http.write_json({error = "默认策略不可删除"})
        return
    end
    if not name:match("^[a-z0-9-]+$") then
        luci.http.write_json({error = "invalid name"})
        return
    end
    -- 检查是否有链路在用此策略
    local chains = parse_json(db_cmd("list-chains")) or {}
    for _, c in ipairs(chains) do
        if c.policy_name == name then
            luci.http.write_json({error = "链路 #" .. c.id .. " (" .. c.name .. ") 仍在使用此策略, 请先换绑"})
            return
        end
    end
    local file_path = "/etc/sing-box/policies/" .. name .. ".json"
    os.execute("rm -f " .. file_path)
    log_api("policies_delete", "name=" .. name)
    luci.http.write_json({status = "ok"})
end
```

**action_chains_bind_policy 实现**:
```lua
function action_chains_bind_policy()
    local chain_id = luci.http.formvalue("chain_id") or ""
    local policy_name = luci.http.formvalue("policy_name") or ""
    if not chain_id:match("^%d+$") then
        luci.http.write_json({error = "invalid chain_id"})
        return
    end
    -- 空 policy_name = 用 default
    if policy_name == "" then policy_name = "default" end
    -- 校验策略文件存在
    local file_path = "/etc/sing-box/policies/" .. policy_name .. ".json"
    if not nixio.fs.access(file_path) then
        luci.http.write_json({error = "策略文件不存在: " .. policy_name})
        return
    end
    log_api("chains_bind_policy", "chain=" .. chain_id .. " policy=" .. policy_name)
    db_cmd("update-chain " .. chain_id .. " '{\"policy_name\":\"" .. policy_name .. "\"}'")
    local ok = apply_config()  -- 重新生成 + 重启 sing-box
    luci.http.write_json({status = ok and "ok" or "error", chain_id = tonumber(chain_id), policy_name = policy_name})
end
```

**action_chains_list / action_chains_get 改动**: 自动返回 `policy_name` 字段 (vps-db.sh 已改, controller 透传)

### 7. 新增 LuCI 页面: policies.htm

**路径**: `openwrt/luci/view/tiktokproxy/policies.htm`

**页面结构**:
```
┌────────────────────────────────────────────────────────────┐
│ 分流策略                                  [+ 新建] [刷新]   │
├────────────────────────────────────────────────────────────┤
│ ┌────────────────────────────────────────────────────────┐ │
│ │ 📄 default         默认策略 (迁移自 routing-rules)   │ │
│ │   国内直连 + 国外走链路              [编辑]          │ │
│ │   (默认策略, 不可删除)                                │ │
│ ├────────────────────────────────────────────────────────┤ │
│ │ 📄 tiktok-priority TikTok 优先                      │ │
│ │   TikTok/Instagram 强制走链路       [编辑] [复制] [删除] │
│ ├────────────────────────────────────────────────────────┤ │
│ │ 📄 cn-direct       全直连                            │ │
│ │   所有流量直连, 测试用              [编辑] [复制] [删除] │
│ └────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘

=== 编辑表单 (点击「新建」或「编辑」展开) ===

┌────────────────────────────────────────────────────────────┐
│ 编辑策略: tiktok-priority                                  │
├────────────────────────────────────────────────────────────┤
│ 文件名 (英文): [tiktok-priority        ] (新建后不可改)    │
│ 显示名:        [TikTok 优先            ]                  │
│ 备注:          [TikTok/Instagram 强制走链路]               │
│                                                            │
│ ┌──[表单模式]──[原始 JSON]──┐  <-- tab 切换               │
│ │                                                            │
│ │ === 表单模式 ===                                          │
│ │ Rule Sets (远程规则集):                                    │
│ │   [✓] geosite-cn  [✓] geoip-cn  [ ] 自定义...            │
│ │                                                            │
│ │ Direct 域名后缀 (一行一个, 走直连):                       │
│ │ ┌────────────────────────────────────────────────────┐  │
│ │ │ baidu.com                                            │  │
│ │ │ qq.com                                               │  │
│ │ │ bilibili.com                                         │  │
│ │ └────────────────────────────────────────────────────┘  │
│ │                                                            │
│ │ Proxy 域名后缀 (一行一个, 强制走链路):                    │
│ │ ┌────────────────────────────────────────────────────┐  │
│ │ │ tiktok.com                                           │  │
│ │ │ instagram.com                                        │  │
│ │ │ google.com                                           │  │
│ │ └────────────────────────────────────────────────────┘  │
│ │                                                            │
│ │ === 原始 JSON 模式 ===                                    │
│ │ ┌────────────────────────────────────────────────────┐  │
│ │ │ {                                                    │  │
│ │ │   "name": "TikTok 优先",                             │  │
│ │ │   "notes": "...",                                    │  │
│ │ │   "rule_sets": [...],                                │  │
│ │ │   "direct_domain_suffix": [...],                     │  │
│ │ │   "proxy_domain_suffix": [...]                       │  │
│ │ │ }                                                    │  │
│ │ └────────────────────────────────────────────────────┘  │
│ │                                                            │
│ │ [保存]  [取消]                                            │
│ └────────────────────────────────────────────────────────────┘
```

**双模式同步逻辑**:
- 切换 tab 时把当前模式的内容解析后注入到另一模式 (表单 <-> JSON)
- 表单 -> JSON: 把 textarea 按行切分成数组, 组装 JSON 对象
- JSON -> 表单: 解析 JSON, 数组拼成 textarea 文本
- 保存时以**当前激活模式**的内容为准 (避免双写同步问题)
- 切换时若解析失败 (JSON 不合法): **弹窗提示具体错误位置, 留在当前 tab 不切换**, 用户必须修正当前 JSON 后才能切到表单模式; 表单 -> JSON 方向不会失败 (表单数据总能序列化)

**双模式数据流**:
```
用户编辑表单 -> 点击「原始 JSON」tab
  -> JS 把表单字段组装成 JSON 对象
  -> JSON.stringify(json, null, 2) 填入 textarea
  -> 切到 JSON tab

用户编辑 JSON -> 点击「表单模式」tab
  -> JS 尝试 JSON.parse(textarea.value)
  -> 失败: alert(错误消息 + 行号), 留在 JSON tab
  -> 成功: 把数组字段 join('\n') 填入对应 textarea, 切到表单 tab

用户点击「保存」
  -> 读当前激活 tab 的内容
  -> 表单模式: 组装 JSON, 提交
  -> JSON 模式: 直接提交 textarea 内容 (controller 会 parse 校验)
```

**rule_sets 复选框**:
- 预置: `geosite-cn` / `geoip-cn` (URL 内置)
- 自定义: 允许添加任意 `tag` + `url` (高级用户)
- 表单模式下只显示预置两个 + 「自定义」入口; 原始 JSON 模式可任意编辑

### 8. vps.htm 链路卡片改动

**改动位置**: `openwrt/luci/view/tiktokproxy/vps.htm` 的 `loadChains()` 函数

**当前链路卡片**(简化):
```html
<div class="chb-card">
  <div class="chb-card-actions">
    <div><b>tiktok-us-double</b> <span>运行中</span></div>
    <div>... 编辑 删除</div>
  </div>
  <div>出海路径: ...</div>
  <div>服务子网: LAN-eth2</div>
</div>
```

**改后链路卡片**:
```html
<div class="chb-card">
  <div class="chb-card-actions">
    <div><b>tiktok-us-double</b> <span>运行中</span></div>
    <div>... 编辑 删除</div>
  </div>
  <div>出海路径: ...</div>
  <div>服务子网: LAN-eth2</div>
  <!-- 新增: 分流策略行 -->
  <div class="chb-stat-desc" style="margin-top:6px;">
    🎯 分流策略:
    <select onchange="bindPolicy(1, this.value)">
      <option value="default">默认策略</option>
      <option value="tiktok-priority" selected>TikTok 优先</option>
      <option value="cn-direct">全直连</option>
    </select>
  </div>
</div>
```

**下拉数据来源**: 页面加载时调用 `policies_list` API 填充 `<select>`

**bindPolicy JS**:
```js
function bindPolicy(chainId, policyName) {
    if (!confirm('切换分流策略? 将重新生成配置并重启 sing-box')) return;
    showMsg('正在应用策略...', 'info');
    xhrPost(CH_BIND_POLICY_URL,
        'chain_id=' + chainId + '&policy_name=' + encodeURIComponent(policyName),
        function(x, rv) {
            if (rv && rv.status == 'ok') {
                showMsg('策略已切换', 'success');
                loadChains();
            } else {
                showMsg('切换失败: ' + (rv && rv.error ? rv.error : ''), 'error');
            }
        });
}
```

### 9. 链路编辑表单改动

**改动位置**: `vps.htm` 的 `chain_form` 区块

**新增字段**: 在「子网 CIDR」下方加「分流策略」下拉 (可选, 留空 = default)

```html
<div class="chb-field">
  <label class="chb-label">分流策略</label>
  <div class="chb-select-wrap">
    <select class="chb-input" id="c_policy_name">
      <option value="">默认 (default)</option>
      <!-- 动态填充 -->
    </select>
  </div>
</div>
```

**JS 改动**:
- `showAddChain()` / `editChain()`: 填充 `c_policy_name` 下拉
- `saveChain()`: 收集 `policy_name` 加入 POST data
- `action_chains_add` / `action_chains_update`: `chain_fields` 数组加 `"policy_name"`

### 10. AGENTS.md 路径表更新

**新增路径映射**:
```
| openwrt/luci/view/tiktokproxy/policies.htm | /usr/lib/lua/luci/view/tiktokproxy/policies.htm |
```

## 错误处理

### 1. 策略文件不存在
- **场景**: 链路绑定的 `policy_name` 对应文件被手动删除
- **处理**: generate-config.sh 回退 `default.json`, 打印 warning 到日志
- **UI 反馈**: `action_chains_list` 时检查每个链路 `policy_name` 对应文件是否存在, 不存在在链路卡片显示 ⚠️ 红色标记

### 2. 策略文件 JSON 不合法
- **场景**: 用户手动编辑文件改坏了
- **处理**: generate-config.sh 失败, 退出码非 0, sing-box 保留旧配置不重启
- **UI 反馈**: `policies_get` 时校验 JSON, 不合法在编辑器显示错误位置; `policies_save` 时 `jq -e` 校验

### 3. 删除正在使用的策略
- **场景**: 链路 A 绑了 `tiktok-priority`, 用户想删它
- **处理**: `action_policies_delete` 检查 `chains.policy_name`, 有引用则拒绝, 返回「链路 #N (name) 仍在使用此策略, 请先换绑」
- **UI 反馈**: 弹窗显示具体哪些链路在用

### 4. 迁移失败
- **场景**: 旧 `routing-rules.json` JSON 不合法
- **处理**: generate-config.sh 打印 error 但不崩, 创建一份内置默认 `default.json` (硬编码内容), 旧文件改名 `.legacy.bad`
- **日志**: `[error] routing-rules.json 解析失败, 使用内置默认策略, 旧文件备份为 .legacy.bad`

### 5. 默认策略被删
- **场景**: 用户绕过 UI 手动 `rm default.json`
- **处理**: 下次 generate-config.sh 启动时检测到 default.json 缺失, 按 §2.b 逻辑重建 (内置默认)
- **UI**: `policies_delete` API 拒绝删除 default

## 测试策略

### 单元测试 (shell 层)

**测试 1: 迁移逻辑**
```sh
# 准备: 清空 policies 目录, 放一份旧 routing-rules.json
rm -rf /tmp/test-policies
mkdir -p /tmp/test-policies/etc/sing-box
cp openwrt/scripts/routing-rules.json /tmp/test-policies/etc/sing-box/
# 跑迁移函数
POLICIES_DIR=/tmp/test-policies/etc/sing-box/policies \
ROUTING_RULES_FILE=/tmp/test-policies/etc/sing-box/routing-rules.json \
    bash -c 'source generate-config.sh; ensure_policies_dir'
# 断言
[ -f /tmp/test-policies/etc/sing-box/policies/default.json ] || fail
[ -f /tmp/test-policies/etc/sing-box/routing-rules.json.legacy ] || fail
jq -r '.name' /tmp/test-policies/etc/sing-box/policies/default.json | grep -q "默认策略"
```

**测试 2: 链路按策略生成**
- 准备: 2 条链路, 各绑不同策略, 各绑一个子网
- 期望: 生成的 config.json 的 route.rules 有两组规则, 各自走对应 outbound

**测试 3: 策略文件缺失回退**
- 准备: 链路绑 `nonexistent`, default 存在
- 期望: generate-config.sh 打印 warning, 用 default, 退出码 0

**测试 4: 策略 JSON 不合法**
- 准备: 写一份 `echo "not json" > policies/bad.json`, 链路绑 `bad`
- 期望: generate-config.sh 退出码 1, sing-box 不重启

### 集成测试 (UI 层)

1. 打开 `/admin/services/tiktokproxy/policies`, 看到默认策略 (default)
2. 新建策略 `test-policy`, 表单模式填几个域名, 保存
3. 切到「原始 JSON」模式, 看到内容正确
4. 回 `/admin/services/tiktokproxy/vps`, 链路卡片下拉选 `test-policy`
5. 点击「应用」, 等 15 秒, 状态变运行中
6. 在 Mac 上 `curl https://ifconfig.me` 看出口 IP 变化
7. 编辑 `test-policy` 加一个域名, 保存, 重新应用
8. 删除 `test-policy`, 应被拒 (链路在用); 先换绑到 default, 再删, 应成功

### 回归测试

- 现有部署升级后, 第一次跑 `generate-config.sh` 应自动迁移, 生成的 config.json 与升级前行为一致
- 未绑定策略的链路 (= NULL) 走 default, 与升级前一致
- DNS 分流行为不变 (用 default 策略的 proxy_domain_suffix)

## 部署清单

### 新增文件
- `openwrt/luci/view/tiktokproxy/policies.htm` (新页面)
- `openwrt/scripts/policy-lib.sh` (策略文件 CRUD 共享函数, 供 controller 和 CLI 共用 - 可选)

### 修改文件
- `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
  - 新增 6 个 API action 函数
  - 新增 1 个路由注册区块
  - `action_chains_add` / `action_chains_update`: `chain_fields` 加 `"policy_name"`
- `openwrt/luci/view/tiktokproxy/vps.htm`
  - 链路卡片加策略下拉
  - 链路编辑表单加策略字段
- `openwrt/scripts/generate-config.sh`
  - 新增 `ensure_policies_dir` 函数 (迁移逻辑)
  - 改 `CHAINS_JSON` 处理: 按链路读策略文件, 内嵌 `_policy_content`
  - 改 `--slurpfile routing`: 传 default 策略 (用于 DNS 分流)
- `openwrt/scripts/generate-config.jq`
  - `chain_routing_rules` 改成从 `chain._policy_content` 取规则
  - `route.rule_set` 改成所有链路策略的 rule_sets 去重合并
  - DNS rules 用 default 策略的 proxy_domain_suffix
- `AGENTS.md`
  - 路径表加 `policies.htm` 映射
  - 加一节「分流策略管理」说明

### 不变文件
- `openwrt/scripts/routing-rules.json` (保留为迁移源, 不删; 升级后改名 `.legacy`)
- `openwrt/scripts/_subnet-lib.sh` / `subnet-*.sh` / `init-subnets.sh` (与本特性无关)

## 实施顺序建议

1. **后端先行**: generate-config.sh + generate-config.jq + vps-db.sh 扩展
   - 这层改完, 手动 curl API 就能验证策略生效
2. **Controller API**: tiktokproxy.lua 加 6 个 action 函数
3. **策略管理页**: policies.htm (新页面, 表单 + JSON 双模式)
4. **链路卡片集成**: vps.htm 加下拉和绑定 JS
5. **迁移测试**: 模拟旧部署升级, 验证自动迁移
6. **AGENTS.md 更新**: 路径表 + 说明

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 迁移时旧 routing-rules.json 被覆盖 | 旧文件改名 `.legacy`, 不删; 迁移失败改名 `.legacy.bad` |
| 策略文件并发写冲突 | 原子写: 临时文件 + rename |
| generate-config.sh 读多个文件慢 | 策略文件本来就小 (< 10KB), 最多几条链路, 可忽略 |
| 用户手动 scp 覆盖文件 (违反 AGENTS.md) | AGENTS.md 明确禁止, 强调 git 追踪; 文件不在 git 里但可通过 LuCI 编辑 |
| 策略文件不在 git 里 | 设计如此 (文件即真相, 与 vps.db 同级); LuCI 是唯一编辑入口 |

## 未来扩展 (YAGNI, 不实现)

- 策略版本历史/回滚
- 策略导入导出 (JSON 文件本身就是导出格式)
- 策略模板库 (预置几种常见策略)
- 一条链路绑多个策略 (当前一对一)
- 策略继承 (default 作为基类, 其他策略只写差异)

这些都不做, 等真有需求再加。
