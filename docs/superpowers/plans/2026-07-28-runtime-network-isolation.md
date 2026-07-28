# 运行时网络隔离、DNS 与事务化 sing-box 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不使用任何海外 WireGuard 的前提下，为现有 x86 OpenWrt 系统建立国内总部管理面、fail-closed 业务面、事务化 sing-box 配置、分阶段 DNS/FakeIP、可回滚应用升级和明确的单 LAN 部署 profile，并用同机 A/B 数据证明升级没有引入不可接受的性能或复杂度回退。

**Architecture:** 继续使用一个 sing-box 进程；OpenWrt 内核 `wg-mgmt` 只承载国内总部到设备本机的 SSH/LuCI/升级命令；设备业务始终使用 direct 或 VLESS，禁止经过 WireGuard。所有 LuCI/CLI 变更统一调用一次性 `chb-apply-config`，候选配置在 DATA 同一文件系统生成，经过不变量、`sing-box check` 和本地健康门禁后原子切换，失败恢复 last-good。应用发布使用签名 GitHub Release、不可变版本目录和原子 `current` 链接，用户数据库与 policies 永不包含在发布包中。

**Tech Stack:** OpenWrt 24.10、BusyBox `ash`、UCI/netifd、firewall4/nftables、procd、内核 WireGuard、sing-box 1.11.5、SQLite、jq、Lua/LuCI、GitHub Actions、usign。

**Spec:** `docs/superpowers/specs/2026-07-28-runtime-network-isolation-design.md`

## Global Constraints

- WireGuard 只允许“国内总部 Hub ↔ 设备 `wg-mgmt`”；日本、美国及其他海外 VPS 禁止成为 WireGuard peer。
- 设备 WireGuard `AllowedIPs` 禁止 `0.0.0.0/0`、`::/0`、业务 LAN、VLESS 节点和海外 VPS 地址。
- `mgmt` zone 永久 `forward=REJECT`；业务吞吐测试时 WireGuard 计数器不得随业务流量增长。
- 本计划不实现 U 盘工厂刷机、磁盘重分区或 OpenWrt 基础固件 A/B OTA；这些在本计划全部验收后重新评审。
- 应用升级属于本计划：设备端升级器和总部批量脚本均为一次性进程，不新增常驻控制服务。
- 冻结 sing-box 1.11.5。FakeIP 金丝雀完成前不得同时升级 sing-box 版本。
- 不新增第二个 sing-box、第二个 DNS daemon、常驻 apply-manager、消息队列或通用网络插件框架。
- 默认采用现有 `auto_route`；只有 Task 9 的同机 A/B 证明 `auto_redirect` 更优且 firewall4 重载稳定，才允许切换。
- `local-dns` 的 `detour` 永远是 `direct`；不得添加无生产来源限制的全局 port 53 规则。
- 所有生产修改必须遵守 `AGENTS.md`：本地修改、commit、push，设备 `git pull` 后部署；禁止直接 scp 覆盖软路由代码。
- 每个 Task 独立提交；每个迁移阶段独立 tag、测试证据和回滚点。前一阶段未过门禁，不开始后一阶段。
- 用户数据只位于 `/data/tiktokproxy/state`；应用包禁止包含或删除 `state/`、`runtime/`、`backups/`。
- `chb-mgmt`、`chb-update` 和 sing-box procd 脚本属于固定基础层，普通应用 Release 不得覆盖；当前先通过 Git 版本化部署，未来再进入工厂镜像。
- 本地测试不能替代实机 nft trace、tcpdump、吞吐和故障注入。

## Target Paths

| 本地文件 | 设备/HQ 路径 | 作用 |
|---|---|---|
| `openwrt/scripts/chb-mgmt.sh` | `/usr/bin/chb-mgmt`（固定基础层） | 设备 `wg-mgmt` 安装、检查、移除 |
| `openwrt/scripts/chb-apply-config.sh` | `/usr/bin/chb-apply-config` | 唯一配置 apply/rollback/status 入口 |
| `openwrt/scripts/chb-network-profile.sh` | `/usr/bin/chb-network-profile` | 显式应用 mode-a/mode-b/mode-c；不自动探测网口 |
| `openwrt/scripts/chb-update.sh` | `/usr/bin/chb-update`（固定基础层） | 设备应用预检、安装、状态、回滚 |
| `openwrt/scripts/generate-config.sh` | `/etc/sing-box/generate-config.sh` | 只生成显式候选输出 |
| `openwrt/scripts/generate-config.jq` | `/etc/sing-box/generate-config.jq` | 单 sing-box 配置模板 |
| `openwrt/scripts/vps-db.sh` | `/usr/bin/vps-db.sh` | 数据库 CRUD，默认读取 DATA |
| `openwrt/init.d/sing-box` | `/etc/init.d/sing-box`（固定基础层） | procd 有限重启和 active 配置入口 |
| `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua` | `/usr/lib/lua/luci/controller/tiktokproxy.lua` | LuCI API，只调用统一 apply/update |
| `ops/mgmt/wg-hub.sh` | 国内总部 Hub | Hub 初始化、设备 peer 增删和审计 |
| `ops/fleet-upgrade.sh` | 国内总部运维机 | plan/apply/resume/status 分批升级 |
| `ops/runtime/benchmark.sh` | 测试机或设备 | 同机性能基线与 A/B |
| `tests/runtime/run.sh` | 开发机/CI | 最小 shell/JQ/Lua 契约测试 |

## Current Defects That This Plan Must Remove

| 当前位置 | 缺陷 | 处理 Task |
|---|---|---|
| `generate-config.sh` | 直接写 `/etc/sing-box/config.json`，候选失败可能先污染 active | 4、5 |
| `generate-config.sh` / `generate-config.jq` | `route.final=direct`，解绑/禁用可能隐式泄漏 | 7 |
| `generate-config.jq` | 生产日志为 `debug`，rule-set 为远程下载 | 4、8 |
| `tiktokproxy.lua` | `apply_config`、`action_on`、`action_chains_apply`、`action_chains_activate`、首次向导等重复生成/重启 | 6 |
| `tiktokproxy.lua` | 固定 sleep、`killall -9`、手工删除 TUN | 5、6 |
| `action_status` | 每次页面轮询同步访问公网出口 IP | 6、8 |
| traffic API | 每次请求全量 grep `/var/log/sing-box.log` | 2、8 |
| controller route | 引用缺失的 settings/traffic/update 页面和 `chb-update` | 2、12 |
| node lifecycle | 引用缺失的 `chb-init-node.sh`、`vps-init.sh`、`speedtest-api.sh` | 2 |
| `init-subnets.sh` | 动态拆桥/网口，不适合单 WAN/单 LAN 量产路径 | 7、15 |
| test suite | 没有可重复的配置、回滚、DNS、网络性能门禁 | 全部 |

---

## Task 1: M0 — 建立可重复测试入口、运行资产清单和现网基线

**Files:**

- Create: `tests/runtime/run.sh`
- Create: `release/app-files.tsv`
- Create: `ops/runtime/benchmark.sh`
- Modify: `AGENTS.md`
- Modify: `README.md`

- [ ] **Step 1: 先写会失败的资产清单测试**

`tests/runtime/run.sh` 首批检查：

```sh
#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
MANIFEST="$ROOT/release/app-files.tsv"

test -f "$MANIFEST"
while IFS="$(printf '\t')" read -r src dst mode layer; do
    case "$src" in ''|'#'*) continue ;; esac
    test -f "$ROOT/$src" || {
        echo "missing release asset: $src -> $dst" >&2
        exit 1
    }
    case "$layer" in app|base) ;; *) exit 1 ;; esac
    case "$dst" in
        /data/tiktokproxy/state/*|/data/tiktokproxy/runtime/*|/data/tiktokproxy/backups/*)
            echo "release manifest touches user/runtime data: $dst" >&2
            exit 1
            ;;
    esac
done < "$MANIFEST"

! grep -Eq '(^|[[:space:]])(0\.0\.0\.0/0|::/0)([[:space:]]|$)' \
    "$ROOT"/ops/mgmt/*.conf 2>/dev/null
```

Run:

```sh
sh tests/runtime/run.sh
```

Expected: FAIL because `release/app-files.tsv` does not exist.

- [ ] **Step 2: 建立唯一应用文件清单**

`release/app-files.tsv` 使用四列：仓库源路径、设备目标路径、八进制权限、层级 `app|base`。只列 Git 管理的代码和静态资产，不列 `vps.db`、policies、运行配置、设备密钥或更新状态。

初始清单必须包含当前真实存在的 controller、views、scripts；Task 2 补齐或删除坏引用后再补充对应项。明确不包含 `openwrt/scripts/init-subnets.sh`。`chb-mgmt`、`chb-update` 和 sing-box init 标记为 `base`；应用构建只选择 `app`。

- [ ] **Step 3: 创建只读性能采集脚本**

`ops/runtime/benchmark.sh` 只接受：

```text
benchmark.sh collect --label <name> --output <file.json>
benchmark.sh compare --before <file.json> --after <file.json>
```

`collect` 记录：

- `sing-box version` 和 Git commit；
- `nproc`、CPU 型号、内存、内核版本；
- `ip -j route`、`ip -j rule`、`nft list ruleset` 哈希；
- sing-box RSS/CPU；
- direct、单跳、双跳三种 iperf3 中位数；
- DNS p50/p95；
- LuCI status API 本地 p50/p95；
- WireGuard 收发计数器；
- 采样时间和 WAN/VPS 标识。

缺少 iperf3、目标地址或设备访问权限时必须返回 `SKIPPED` 和原因，不伪造 0。

- [ ] **Step 4: 在同一台当前生产硬件保存基线**

```sh
ops/runtime/benchmark.sh collect \
  --label before-runtime-isolation \
  --output docs/runtime-baselines/<device-id>-before.json
```

Expected: direct、单跳、双跳均至少三轮，JSON 中保留中位数；若当前 SSH 未打通，本 Task 停在这里，不进入 M1。

- [ ] **Step 5: 更新部署规则**

在 `AGENTS.md` 增加本计划新文件映射、DATA 不可覆盖红线、`chb-apply-config` 唯一 apply 入口和应用发布包禁区。在 `README.md` 把 `init-subnets.sh` 标为 legacy/实验工具，删除“量产初始化推荐”表述。

- [ ] **Step 6: 验证并提交**

```sh
sh -n tests/runtime/run.sh ops/runtime/benchmark.sh
sh tests/runtime/run.sh
git diff --check
git add tests/runtime/run.sh release/app-files.tsv ops/runtime/benchmark.sh AGENTS.md README.md
git commit -m "test: add runtime release and performance gates"
```

**M0 gate:** 资产清单测试通过，现网基线文件存在，且没有把用户数据纳入发布物。

---

## Task 2: M0 — 关闭当前缺失资产和高成本死路径

**Files:**

- Create: `openwrt/scripts/vps-init.sh`
- Create: `openwrt/scripts/speedtest-api.sh`
- Create: `openwrt/luci/view/tiktokproxy/settings.htm`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/header.htm`
- Modify: `openwrt/luci/view/themes/argone/header.htm`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 写缺失引用测试**

向 `tests/runtime/run.sh` 增加：

```sh
for f in \
  openwrt/scripts/vps-init.sh \
  openwrt/scripts/speedtest-api.sh \
  openwrt/luci/view/tiktokproxy/settings.htm
do
    test -f "$ROOT/$f" || exit 1
done

! grep -q 'chb-init-node.sh' \
  "$ROOT/openwrt/luci/controller/tiktokproxy/tiktokproxy.lua"
! grep -q 'template("tiktokproxy/traffic")' \
  "$ROOT/openwrt/luci/controller/tiktokproxy/tiktokproxy.lua"
```

Run and confirm failure.

- [ ] **Step 2: 复用现有 Lua 节点初始化，不再新增重复 orchestrator**

在 controller 添加一个 `nixio.fork()` 后关闭标准输入输出并执行函数的最小 `spawn_job(fn)`；把四处 `/usr/bin/chb-init-node.sh init|uninit` 替换为调用现有 `init_node()` / `uninit_node()`。子进程异常必须把节点 `init_status` 写为 `failed`。

不新增 `chb-init-node.sh`，因为 controller 已经有完整七步流程；复制一套只会制造第二实现。

- [ ] **Step 3: 补齐唯一的 VPS 端安装脚本**

`vps-init.sh` 必须精确支持 controller 已调用的八个命令：

```text
step1-check-connection
step2-install-singbox
step3-find-port
step4-gen-reality
step5-write-config
step6-start-service
step7-health-check
uninstall
```

要求：

- 所有参数做 allowlist 校验；
- 每次只操作 `/etc/chb-sing-box-<8位hex uuid>` 和对应 systemd unit；
- `step5` 写候选并执行目标版本 `sing-box check` 后才替换；
- `uninstall` 拒绝空 UUID、`/`、通配符和非 8 位十六进制；
- 标准输出只有一个 JSON 对象，日志写 stderr；
- 不安装或配置 WireGuard。

- [ ] **Step 4: 补齐最小测速 API**

`speedtest-api.sh` 只提供 controller 当前需要的 `/ping?host=<IPv4>` 和有上限的 `/download?bytes=N`。host 必须是 IPv4 字面量，bytes 上限固定 100 MiB；禁止执行任意 shell 参数。

- [ ] **Step 5: 补齐 settings 页面，删除 traffic 死路径**

创建只包含现有 `settings_get/settings_save` 字段的 settings 页面，不新增新表。删除 controller 中 traffic 页面路由与两个全量日志 grep API，同时从两个 header 删除“流量监控”。状态总览继续保留按需测速。

update 页面和 `chb-update` 在 Task 12 实现前不注册路由，避免 404。

- [ ] **Step 6: 测试与提交**

```sh
sh -n openwrt/scripts/vps-init.sh openwrt/scripts/speedtest-api.sh
! openwrt/scripts/vps-init.sh uninstall --uuid / >/dev/null 2>&1
openwrt/scripts/speedtest-api.sh --self-test
! rg 'rm -rf[[:space:]]+/(?:[[:space:]]|;|$)' \
  openwrt/scripts/vps-init.sh openwrt/scripts/speedtest-api.sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/vps-init.sh openwrt/scripts/speedtest-api.sh \
  openwrt/luci/controller/tiktokproxy/tiktokproxy.lua \
  openwrt/luci/view/tiktokproxy/settings.htm \
  openwrt/luci/view/header.htm openwrt/luci/view/themes/argone/header.htm \
  release/app-files.tsv tests/runtime/run.sh
git commit -m "fix: close runtime asset gaps"
```

---

## Task 3: M1 — 建立仅限国内总部的内核 WireGuard 管理面

**Files:**

- Create: `ops/mgmt/wg-hub.sh`
- Create: `ops/mgmt/inventory.example.tsv`
- Create: `openwrt/scripts/chb-mgmt.sh`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`
- Modify: `AGENTS.md`

- [ ] **Step 1: 写 WireGuard 边界失败测试**

测试至少断言：

```sh
test "$(grep -R 'AllowedIPs' tests/runtime/tmp/mgmt-device.conf |
  grep -Ec '0\.0\.0\.0/0|::/0')" -eq 0
grep -q '10.254.0.0/24' tests/runtime/tmp/mgmt-device.conf
! grep -Eq 'AllowedIPs.*(192\.168\.|172\.19\.)' tests/runtime/tmp/mgmt-device.conf
grep -q "option forward 'REJECT'" tests/runtime/tmp/mgmt-firewall.uci
```

Run and confirm failure before scripts exist.

- [ ] **Step 2: 实现总部 Hub 脚本**

`wg-hub.sh` 只支持：

```text
init --endpoint <国内固定IPv4:port> --country CN
add-operator --operator-id <id> --address <10.254.0.x/32> --public-key <key>
revoke-operator --operator-id <id>
add-device --device-id <id> --address <10.254.x.y/32> --public-key <key>
revoke-device --device-id <id>
render
check
```

约束：

- `--country` 不是 `CN` 时拒绝；
- 每台总部运维机使用 `10.254.0.0/24` 中唯一的 `/32` ops peer；
- Hub 为每台设备只写唯一 `/32`；
- ops 管理池固定 `10.254.0.0/24`，设备池为 `10.254.1.0/24` 至 `10.254.255.0/24`；
- Hub 只允许 ops 池转发到设备池和回包，拒绝设备间横向访问；
- 脚本不配置任何海外 VPS peer；
- 私钥权限 0600，inventory 只保存设备 ID、管理 IP、公钥和状态。

代码中的 `country=CN` 是操作门禁，不替代对 Hub 机房、IP 和运营商归属的人工验收。

- [ ] **Step 3: 实现设备管理接口脚本**

`chb-mgmt` 只支持：

```text
install --address <device/32> --hub-public-key-file <file> \
        --private-key-file <file> --endpoint <domestic-ip:port>
check
remove
```

使用 UCI/netifd 创建 `wg-mgmt`，`PersistentKeepalive=25`。设备 peer `AllowedIPs` 只写 `10.254.0.0/24`；endpoint 为 IPv4 字面量。创建 `mgmt` zone：

```text
input=REJECT output=ACCEPT forward=REJECT
允许 source=10.254.0.0/24 到设备本机 TCP 22/443
禁止 mgmt → prod/wan/tun forwarding
```

用 UCI interface route 固定 endpoint `/32` 走 `wan`。不得创建 sing-box WireGuard outbound。

- [ ] **Step 4: 在一台 canary 验证业务路径完全不变**

```sh
chb-mgmt check
wg show wg-mgmt
ip route get <国内Hub公网IPv4>
ip route get <日本VPS IPv4>
ip route get <美国VPS IPv4>
nft list ruleset
```

Expected:

- Hub endpoint、日本 VPS、美国 VPS 都通过物理 WAN 到达；
- 只有管理地址经 `wg-mgmt`；
- 总部可 SSH/LuCI；
- 停止 sing-box 后 SSH/LuCI 不断；
- 生产压测前后 WireGuard 增量只对应管理操作。

- [ ] **Step 5: 提交**

```sh
sh -n ops/mgmt/wg-hub.sh openwrt/scripts/chb-mgmt.sh
sh tests/runtime/run.sh
git diff --check
git add ops/mgmt openwrt/scripts/chb-mgmt.sh \
  release/app-files.tsv tests/runtime/run.sh AGENTS.md
git commit -m "feat: add domestic-only management tunnel"
```

**M1 rollback:** `chb-mgmt remove` 只删除 `wg-mgmt` 和 `mgmt` zone，不修改 WAN、LAN、sing-box 或用户数据库。

---

## Task 4: M2 — 把用户数据迁到 DATA，并让生成器只写显式候选

**Files:**

- Modify: `openwrt/scripts/vps-db.sh`
- Modify: `openwrt/scripts/policy-migrate.sh`
- Modify: `openwrt/scripts/generate-config.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Create: `openwrt/rules/SHA256SUMS`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 写候选生成失败测试**

测试使用临时目录和临时 SQLite：

```sh
CHB_DB_FILE="$TMP/state/vps.db" openwrt/scripts/vps-db.sh init
CHB_DB_FILE="$TMP/state/vps.db" openwrt/scripts/vps-db.sh add-node \
  '{"name":"jp","ip":"203.0.113.10","vless_uuid":"00000000-0000-0000-0000-000000000001"}'
CHB_DB_FILE="$TMP/state/vps.db" openwrt/scripts/vps-db.sh add-chain \
  '{"name":"chain-a","source_cidr":"192.168.20.11/32","hop_path":"1"}'

openwrt/scripts/generate-config.sh \
  --db "$TMP/state/vps.db" \
  --policies "$TMP/state/policies" \
  --rules "$TMP/rules" \
  --output "$TMP/candidate/config.json"

test ! -e "$TMP/etc/sing-box/config.json"
jq -e '.log.level == "info"' "$TMP/candidate/config.json"
jq -e '[.route.rule_set[]?.type] | all(. == "local")' "$TMP/candidate/config.json"
```

Expected: FAIL on current hard-coded paths and remote rule-set.

- [ ] **Step 2: 数据库和 policies 默认路径切到 DATA**

`vps-db.sh` 使用：

```sh
DB_FILE="${CHB_DB_FILE:-/data/tiktokproxy/state/vps.db}"
```

`policy-migrate.sh` 默认目标改为 `/data/tiktokproxy/state/policies`，同时保留显式环境变量供测试。首次迁移遵循：

1. 目标不存在且旧 `/etc/sing-box/vps.db` 存在时，用 SQLite `.backup` 复制；
2. `PRAGMA integrity_check` 必须为 `ok`；
3. 原文件改名 `.migrated`，不删除；
4. policies 逐文件复制并校验 JSON；
5. 重复执行幂等。

- [ ] **Step 3: 重构生成器 CLI**

生成器必须要求 `--output`，并支持显式 `--db`、`--policies`、`--rules`。它不得：

- 运行迁移；
- 写 `/etc/sing-box/config.json`；
- 重启服务；
- 访问网络；
- 在策略文件缺失时静默回退到另一份业务语义。

输出父目录不存在时失败，不自行猜测 active。

- [ ] **Step 4: 本地化 rule-set**

将 `geosite-cn.srs`、`geoip-cn.srs` 作为签名应用 Release 内容，`openwrt/rules/SHA256SUMS` 记录实际 SHA-256。生成配置只使用：

```json
{"tag":"geosite-cn","type":"local","format":"binary","path":"/data/tiktokproxy/current/rules/geosite-cn.srs"}
```

实现时从当前已验证上游取得一次规则文件并记录上游 commit、下载 URL、SHA-256；CI 只接受锁定哈希，不在设备启动时下载。

- [ ] **Step 5: 保持 M2 业务语义，先不启用 FakeIP**

本 Task 只做：

- 生产日志改 `info`，去掉长期文件 debug 输出，交给有界 logd；
- 显式排除 `wg-mgmt`、`10.254.0.0/16` 和 Hub endpoint；
- 仍使用当前 DNS 解析行为；
- 仍使用当前 `auto_route`；
- 不同时修改 DNS capture/FakeIP。

- [ ] **Step 6: 测试与提交**

```sh
sh -n openwrt/scripts/vps-db.sh openwrt/scripts/policy-migrate.sh \
  openwrt/scripts/generate-config.sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/vps-db.sh openwrt/scripts/policy-migrate.sh \
  openwrt/scripts/generate-config.sh openwrt/scripts/generate-config.jq \
  openwrt/rules release/app-files.tsv tests/runtime/run.sh
git commit -m "refactor: generate sing-box candidates from data snapshots"
```

---

## Task 5: M2 — 实现最小事务 apply、last-good 和有限 procd 恢复

**Files:**

- Create: `openwrt/scripts/chb-apply-config.sh`
- Create: `openwrt/init.d/sing-box`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`
- Modify: `AGENTS.md`

- [ ] **Step 1: 为失败原子性写测试**

`tests/runtime/run.sh` 使用 PATH mock 的 `sing-box` 和 service 命令，验证：

1. 候选 JSON 非法：active 哈希不变；
2. `sing-box check` 失败：active 哈希不变；
3. 启动后本地健康失败：active 恢复 last-good；
4. 成功：`applied_hash == candidate desired_hash`；
5. 同时两个 apply：第二个返回 `BUSY`，不并发切换；
6. 中断后：active/config.json 或 last-good/config.json 至少一份完整；
7. `rollback` 不修改 vps.db 或 policies。

Expected: FAIL because脚本不存在。

- [ ] **Step 2: 定义 CLI 和状态 JSON**

```text
chb-apply-config apply --initiator <luci|cli|upgrade>
chb-apply-config check
chb-apply-config block --initiator <luci|hq>
chb-apply-config rollback --initiator <...>
chb-apply-config status
```

标准输出为单个 JSON：

```json
{
  "state": "APPLIED",
  "apply_id": "20260728T120000Z-1234",
  "desired_hash": "...",
  "applied_hash": "...",
  "last_good_hash": "...",
  "last_error": null
}
```

退出码：0 成功，2 候选拒绝，3 本地健康失败且已回滚，4 lock busy，5 回滚本身失败。`block` 只停止业务服务、验证 prod 无 WAN 兜底并写 `BLOCKED`，不修改 desired 数据；下一次 `apply` 恢复业务。

- [ ] **Step 3: 实现一次性 apply**

最小算法：

```text
mkdir 原子获取 /var/lock/chb-config.lock，trap 释放
在 /data/tiktokproxy/runtime/.apply.<id>/ 创建 SQLite .backup 和 policies 快照
对快照计算 desired_hash
generate-config.sh 写 candidate/config.json
jq + 不变量 + sing-box check
把当前 active/config.json 原子复制/rename 为 last-good/config.json
把 candidate 先 fsync 到 active/config.json.new，再同目录 rename
procd restart sing-box
轮询本地进程、TUN、路由和阶段性 DNS，最长 3 秒
成功写 state.json.new 再 rename
失败恢复 last-good、重启、复检、记录 ROLLED_BACK
删除 .apply.<id>
```

lock 目录内记录 PID 和当前 boot ID。若 lock 已存在，只能在“boot ID 已变化”或“同一 boot 下 PID 明确不存在”时清理；不得仅按文件时间猜测并抢锁。

禁止固定 `sleep 3 + sleep 2 + sleep 5`；使用最多三次、每次 1 秒的有界轮询。禁止 `killall -9` 作为正常路径。

- [ ] **Step 4: 内联不变量，不创建第二套 validator 服务**

脚本用 jq/sqlite 检查：

- 每个启用链路有 hop；
- source CIDR 经 OpenWrt `ipcalc.sh` 验证且不重叠；
- final 不是 direct；
- 未登记来源最终 reject/block；
- `local-dns.detour == direct`；
- 没有无 source/inbound/destination 限定的 port 53；
- 所有 rule-set 为 local 且文件/哈希存在；
- 所有 outbound 引用存在；
- `wg-mgmt`、管理网和 Hub endpoint 被 TUN 排除；
- 数据库 schema 可读、`integrity_check=ok`。

错误必须包含精确不变量编号，不能只返回“启动失败”。

- [ ] **Step 5: 版本化 sing-box procd 脚本**

init script 只读取 `/data/tiktokproxy/runtime/active/config.json`。启动前先 `sing-box check`；procd 使用有限 respawn，连续失败后保持业务阻断，不自动改用户数据。总部可执行：

```sh
chb-apply-config rollback --initiator hq
```

- [ ] **Step 6: 测试与提交**

```sh
sh -n openwrt/scripts/chb-apply-config.sh openwrt/init.d/sing-box
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-apply-config.sh openwrt/init.d/sing-box \
  release/app-files.tsv tests/runtime/run.sh AGENTS.md
git commit -m "feat: apply sing-box config transactionally"
```

---

## Task 6: M2 — 收敛所有 LuCI/CLI apply 路径并显示真实运行状态

**Files:**

- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/tiktokproxy/vps.htm`
- Modify: `openwrt/luci/view/admin_status/index.htm`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 写单入口静态测试**

```sh
CTRL="$ROOT/openwrt/luci/controller/tiktokproxy/tiktokproxy.lua"
test "$(grep -c '/usr/bin/chb-apply-config' "$CTRL")" -ge 1
! grep -q 'GENERATOR .. " 2>&1' "$CTRL"
! grep -q '/etc/init.d/sing-box stop' "$CTRL"
! grep -q 'killall -9 sing-box' "$CTRL"
! grep -q 'sleep [235]' "$CTRL"
! grep -q 'http://ifconfig.me' "$CTRL"
```

Run and confirm failure.

- [ ] **Step 2: controller 只保留一个 apply helper**

把 `apply_config()` 改为调用：

```text
/usr/bin/chb-apply-config apply --initiator luci
```

删除 controller 内 `do_stop/do_start` 和直接 generator/check/restart。以下入口全部复用同一 helper：

- `action_on`
- `action_chains_apply`
- `action_chains_activate`
- `action_subnets_bind`
- `action_subnets_unbind`
- `action_chains_disable`
- `action_chains_bind_policy`
- 首次向导最终 apply

后台 apply 只允许启动 `chb-apply-config`；状态通过 `status` 读取，不再依赖固定等待时间。

`action_off` 调用 `chb-apply-config block --initiator luci`，`action_on` 调用 apply；toggle 只在这两个动作之间选择，不直接操作 init script。

- [ ] **Step 3: status API 只读本地状态**

`action_status` 合并：

- PID/TUN 本地状态；
- `/data/tiktokproxy/runtime/state.json`；
- desired/applied/last-good hash；
- `last_error`；
- 链路数据库信息。

删除同步公网出口 IP请求。页面需要出口诊断时由用户显式点击诊断按钮，不放入轮询路径。

- [ ] **Step 4: UI 不再显示幽灵状态**

页面状态规则：

```text
desired_hash == applied_hash && process/tun 正常 → 运行中
desired_hash != applied_hash                    → 待应用
last_error 非空                                → 应用失败/已回滚
sing-box 停止                                  → 业务已阻断
```

不得因为 DB 中 `enabled=1` 就单独显示“已生效”。

- [ ] **Step 5: 实机响应时间测试**

```sh
for i in $(seq 1 30); do
  curl -sk -o /dev/null -w '%{time_total}\n' \
    https://<wg-mgmt-ip>/cgi-bin/luci/admin/services/tiktokproxy/status
done
```

Expected: p95 ≤ 300 ms，命令期间无公网 HTTP/DNS。

- [ ] **Step 6: 提交**

```sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/luci/controller/tiktokproxy/tiktokproxy.lua \
  openwrt/luci/view/tiktokproxy/vps.htm \
  openwrt/luci/view/admin_status/index.htm tests/runtime/run.sh
git commit -m "refactor: route all runtime changes through one apply path"
```

---

## Task 7: M3 — 固化 fail-closed 和 mode-b 默认生产入口

**Files:**

- Create: `openwrt/scripts/chb-network-profile.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/tiktokproxy/vps.htm`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`
- Modify: `README.md`

- [ ] **Step 1: 写泄漏失败测试**

生成配置后断言：

```sh
jq -e '.route.final != "direct"' "$CONFIG"
jq -e '[.outbounds[].tag] | index("block") != null' "$CONFIG"
jq -e '
  [.route.rules[] | select(.outbound == "direct")] |
  all(has("source_ip_cidr") and
      (has("rule_set") or has("domain_suffix")))
' "$CONFIG"
```

网络 profile dry-run 断言不存在通用 `prod -> wan` forwarding。

- [ ] **Step 2: 生成配置改为显式 block final**

增加 `block` outbound，`route.final="block"`。只保留两类 direct：

1. 路由器基础流量，不进入业务 TUN；
2. 同时有生产来源和 CN/自定义 direct 策略的业务规则。

链路禁用、子网解绑、未登记 source 都落到 block，不回落 direct。

- [ ] **Step 3: 实现明确的网络 profile CLI**

首批只开放推荐 mode-b：

```text
chb-network-profile plan mode-b --wan <if> --lan <if> --cidr 192.168.20.1/24
chb-network-profile apply mode-b --wan <if> --lan <if> --cidr 192.168.20.1/24
chb-network-profile check
chb-network-profile rollback
```

脚本不得自动枚举并拆分网卡；WAN/LAN 参数必须显式且不同。应用前使用 `uci export network/firewall/dhcp` 备份，`uci batch` 全部校验后提交。规则：

- `prod -> wan` 不存在；
- `prod -> mgmt` 不存在；
- `mgmt` forward REJECT；
- prod input 只允许 DHCP、必要 ICMP；DNS 在 Task 10 前仍按当前路径；
- 下游路由器通过 MAC 获得保留 IP；
- `chains.source_cidr=<保留IP>/32`、`ap_ip`、`ap_mac` 是唯一分组数据，不新增表。

- [ ] **Step 4: 修改 UI 破坏性语义**

把“未绑定（直连）”“关闭后临时直连”等文案改为“未绑定（业务阻断）”“关闭后业务阻断”。解绑、禁用、关闭代理前都明确提示 fail-closed。

不实现 maintenance-direct；等出现真实运营需求再独立设计。

- [ ] **Step 5: 故障注入**

在 canary：

```sh
/etc/init.d/sing-box stop
ip netns exec <prod-client> curl --max-time 5 https://ifconfig.me
ssh root@<wg-mgmt-ip> true
nft monitor trace
```

Expected: 生产 curl 失败，总部 SSH 成功，nft trace 中没有 prod→wan。

- [ ] **Step 6: 提交**

```sh
sh -n openwrt/scripts/chb-network-profile.sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-network-profile.sh \
  openwrt/scripts/generate-config.jq \
  openwrt/luci/controller/tiktokproxy/tiktokproxy.lua \
  openwrt/luci/view/tiktokproxy/vps.htm \
  release/app-files.tsv tests/runtime/run.sh README.md
git commit -m "feat: make production routing fail closed"
```

**M3 rollback:** 恢复上一 UCI export 和上一应用 release；用户数据库不回滚、不删除。

---

## Task 8: M3 — 收紧日志和运行状态开销

**Files:**

- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/scripts/chain-diagnostics.sh`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/admin_status/index.htm`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 写性能反模式测试**

```sh
! grep -R 'level: "debug"' openwrt/scripts
! grep -q 'grep .*sing-box.log' openwrt/luci/controller/tiktokproxy/tiktokproxy.lua
! grep -q 'ifconfig.me' openwrt/luci/controller/tiktokproxy/tiktokproxy.lua
```

- [ ] **Step 2: 日志交给 logd**

生产默认 `info`，不把完整流量日志持续写 `/var/log/sing-box.log`。诊断 debug 通过显式、最长 15 分钟的临时配置开启，到期恢复 info。

- [ ] **Step 3: 诊断改为显式操作**

`chain-diagnostics.sh` 只在用户点击时执行 ping/带宽测试；普通 status API 不调用它。返回值写 `/tmp/chb-diagnostics/<chain>.json`，页面显示采集时间，不把缓存当实时。

- [ ] **Step 4: A/B 复测**

用 Task 1 脚本生成 `after-m3.json`，确认：

- status API p95 ≤ 300 ms；
- 页面开/关不影响吞吐；
- CPU/RSS 在预算内；
- 24 小时 logd/flash 写入有界。

- [ ] **Step 5: 提交**

```sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/generate-config.jq \
  openwrt/scripts/chain-diagnostics.sh \
  openwrt/luci/controller/tiktokproxy/tiktokproxy.lua \
  openwrt/luci/view/admin_status/index.htm tests/runtime/run.sh
git commit -m "perf: remove synchronous and unbounded status work"
```

---

## Task 9: M4 — 用实测决定保留 auto_route 还是切 auto_redirect

**Files:**

- Modify: `ops/runtime/benchmark.sh`
- Conditional Modify: `openwrt/scripts/generate-config.jq`
- Create: `docs/runtime-baselines/<device-id>-tun-ab.json`

- [ ] **Step 1: 为同配置生成两个仅 TUN 模式不同的候选**

除 `auto_redirect` 开关外，节点、规则、DNS、MTU、日志完全一致。每个候选先 `sing-box check`。

- [ ] **Step 2: 每种模式预热后测三轮**

顺序使用 ABBA，避免时间偏差：

```text
auto_route → auto_redirect → auto_redirect → auto_route
```

每轮记录 direct、单跳、双跳吞吐，CPU、RSS、丢包、连接建立时间、firewall4 reload 前后连接和 nft 规则。

- [ ] **Step 3: 执行硬门槛**

候选必须同时满足：

- 任一吞吐相对当前下降不超过 5%；
- 相同吞吐 CPU 增幅不超过 10%；
- RSS 增幅不超过 15%；
- firewall4 reload 后 TUN 和 fail-closed 仍正确；
- `wg-mgmt` 与 Hub endpoint 始终不被捕获。

若 `auto_redirect` 没有可重复的吞吐/CPU优势，保留 `auto_route`，只提交 A/B 证据，不改生产 JQ。

- [ ] **Step 4: 提交决策**

```sh
git add ops/runtime/benchmark.sh docs/runtime-baselines/<device-id>-tun-ab.json
git add openwrt/scripts/generate-config.jq  # 仅在门槛通过且决定切换时
git commit -m "perf: record tun routing benchmark decision"
```

**M4 gate:** 没有数据就没有 TUN 模式切换。

---

## Task 10: M5 — 上线限定生产入口的 DNS 捕获，保持当前解析策略

**Files:**

- Modify: `openwrt/scripts/chb-network-profile.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/scripts/chb-apply-config.sh`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 写 DNS 范围失败测试**

配置必须存在显式 `hijack-dns`，并同时具备：

```text
inbound = tun-in
source_ip_cidr = 已登记生产来源
destination = 专用 TUN DNS 地址
port = 53
network = tcp,udp
```

测试拒绝：

- 只有 `port=53`；
- 没有 source；
- 没有 destination；
- local-dns detour 非 direct。

- [ ] **Step 2: 使用固定专用地址**

TUN 保持 `172.19.0.1/30`，客户端 DNS 专用地址固定 `172.19.0.2`。DHCP option 6 下发该地址；firewall4 只在 prod ingress 将客户端任意 TCP/UDP 53 定向到该地址。

路由器 OUTPUT、dnsmasq、`wg-mgmt`、Hub endpoint 和升级器不命中捕获。

- [ ] **Step 3: 只改变捕获路径**

本 Task 不启用 FakeIP，不升级 sing-box，不改变 CN/国外解析策略。目的是用 nft trace 和抓包证明“谁被捕获、谁未被捕获”。

- [ ] **Step 4: 抓包验收**

同时执行：

```sh
nft monitor trace
tcpdump -ni <wan> port 53
tcpdump -ni singbox-tun port 53
```

用例：

- prod 客户端系统 DNS；
- prod 客户端手工 `8.8.8.8:53`；
- 路由器自身 NTP/GitHub DNS；
- WireGuard endpoint；
- sing-box 自身 local-dns。

Expected: 前两项进入专用路径；后三项不进入客户端捕获。

- [ ] **Step 5: 提交**

```sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-network-profile.sh \
  openwrt/scripts/generate-config.jq \
  openwrt/scripts/chb-apply-config.sh tests/runtime/run.sh
git commit -m "feat: scope client dns capture to production ingress"
```

---

## Task 11: M6 — 独立金丝雀启用 sing-box 1.11.5 FakeIP

**Files:**

- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/scripts/chb-apply-config.sh`
- Modify: `tests/runtime/run.sh`
- Create: `docs/runtime-baselines/<device-id>-fakeip-canary.json`

- [ ] **Step 1: 写 FakeIP 契约测试**

断言：

- `dns.fakeip.enabled == true`；
- IPv4 池为保留测试网段 `198.18.0.0/15`；
- 非 CN A/AAAA 使用 `address: "fakeip"` server；
- CN A/AAAA 仍走 `local-dns` direct；
- 非 A/AAAA 按 source 绑定链路查询；
- route 可将 FakeIP 映射恢复为域名；
- 没有远程 rule-set。

- [ ] **Step 2: 只改 FakeIP，不改其他大项**

保持 M5 的 TUN 模式、捕获规则、sing-box 1.11.5、VLESS 链路和日志级别。不要在此 commit 升级 sing-box 或切换 TUN 模式。

- [ ] **Step 3: 扩展 apply 本地 DNS 门禁**

候选启动后本地验证：

- CN 测试域名返回非 198.18/15 地址；
- 国外测试域名 A/AAAA 返回 198.18/15；
- 路由器自身 bootstrap DNS 仍返回真实地址；
- 无 client source 限定的 DNS 规则被拒绝。

公网/VPS 临时不可达只记 degraded，不触发配置回滚。

- [ ] **Step 4: 金丝雀兼容性矩阵**

至少验证：

- A、AAAA、HTTPS/SVCB；
- TCP、UDP、QUIC；
- TikTok、直播推流、STUN；
- DoH/DoT 绕过策略；
- 私有域名、短域名、缓存和重连；
- WAN 抓包无国外 A/AAAA 明文查询；
- 24 小时映射和内存无持续增长。

- [ ] **Step 5: 提交和单机发布**

```sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/generate-config.jq \
  openwrt/scripts/chb-apply-config.sh tests/runtime/run.sh \
  docs/runtime-baselines/<device-id>-fakeip-canary.json
git commit -m "feat: add canary fakeip dns routing"
```

**M6 rollback:** 应用 last-good release；不改数据库 schema，不清理 DNS 用户数据，因为 FakeIP 映射是运行态。

---

## Task 12: M7 — 建立签名应用 Release

**Files:**

- Create: `release/build-app-release.sh`
- Create: `release/manifest.jq`
- Create: `release/keys/app-release.pub`
- Create: `.github/workflows/release-app.yml`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 写发布包禁区测试**

构建后检查：

```sh
tar -tf "$ARTIFACT" > "$TMP/list"
! grep -E '(^|/)(state|runtime|backups)(/|$)' "$TMP/list"
! grep -E '(^/|(^|/)\\.\\.(/|$))' "$TMP/list"
sha256sum -c SHA256SUMS
usign -V -p release/keys/app-release.pub -m manifest.json -x manifest.json.sig
```

- [ ] **Step 2: 只从精确 commit 构建**

`build-app-release.sh` 接受 `app-vX.Y.Z` 和完整 commit SHA，只选择 `release/app-files.tsv` 中 `layer=app` 的文件复制到暂存根，设置权限，验证所有 rule-set 哈希，生成 tar.zst、manifest、SHA256SUMS。若包中出现 `layer=base` 文件则构建失败。

manifest 至少包含：

```json
{
  "release": "app-v1.0.0",
  "type": "app",
  "commit": "<40 hex>",
  "min_os_version": "runtime-v1",
  "schema_read_min": 1,
  "schema_read_max": 1,
  "schema_write": 1,
  "artifact": "app-v1.0.0.tar.zst",
  "sha256": "<64 hex>"
}
```

- [ ] **Step 3: CI 门禁后签名发布**

workflow 顺序：

```text
checkout exact tag
shell/JQ/Lua syntax
tests/runtime/run.sh
build artifact
verify archive boundaries
boot/integration job
usign manifest
publish immutable GitHub Release
```

签名密钥离线生成一次；私钥只进入 GitHub Actions secret 或离线签名环境，仓库只保存 `release/keys/app-release.pub`。

- [ ] **Step 4: 提交**

```sh
sh -n release/build-app-release.sh
sh tests/runtime/run.sh
git diff --check
git add release .github/workflows/release-app.yml tests/runtime/run.sh
git commit -m "build: create signed application releases"
```

---

## Task 13: M7 — 实现设备端应用升级和用户数据保护

**Files:**

- Create: `openwrt/scripts/chb-update.sh`
- Create: `openwrt/luci/view/tiktokproxy/update.htm`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/header.htm`
- Modify: `openwrt/luci/view/themes/argone/header.htm`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 写四类强制回滚测试**

PATH mock 测试：

- 签名错误；
- tar 路径穿越；
- schema 迁移失败；
- 新应用本地健康失败。

每种情况都断言：

```text
current 链接不变或恢复
vps.db SHA-256 不变或恢复
policies 树哈希不变或恢复
active/last-good 都是完整 JSON
upgrade state 有精确错误
```

- [ ] **Step 2: 定义设备 CLI**

```text
chb-update preflight --release app-vX.Y.Z
chb-update apply --release app-vX.Y.Z --upgrade-id <id>
chb-update status --upgrade-id <id>
chb-update rollback --upgrade-id <id>
chb-update bootstrap-links
```

不接受 `latest`、branch、裸 URL 或未签名 release。

- [ ] **Step 3: 实现可恢复事务**

设备端流程：

1. 确认 `ip route get` 走 WAN；
2. `curl --interface <wan>` 下载 manifest、签名和 artifact；
3. usign 验签、SHA-256 校验；
4. 拒绝绝对路径、`..`、越界 symlink、state/runtime/backups；
5. 解包到唯一 `releases/app-vX.Y.Z`；
6. 仅 schema 变化时创建 `/data/tiktokproxy/backups/<upgrade-id>`；
7. 在数据库副本执行 expand-only 迁移；
8. 检查 integrity、关键表行数不减少、policies JSON；
9. 用新 release 生成候选并 `sing-box check`；
10. 写 upgrade journal，原子切换 `/data/tiktokproxy/current`；
11. 调用 `chb-apply-config apply --initiator upgrade`；
12. 清理 LuCI module/index cache，并只重启受影响的 uhttpd；
13. 健康失败恢复旧 current、数据库和 policies；
14. 成功后保留有界备份，绝不递归删除 DATA 根。

重复相同 `upgrade-id` 必须从 journal 恢复或返回已有终态，不能重复迁移。

`bootstrap-links` 只创建一次固定运行 symlink，例如 `/usr/bin/chb-apply-config -> /data/tiktokproxy/current/usr/bin/chb-apply-config`；不得替换 `/usr/bin/chb-update`、`/usr/bin/chb-mgmt` 或 `/etc/init.d/sing-box`。普通 app 切换只移动 `current`，不会逐文件覆盖系统路径。

- [ ] **Step 4: 接入 LuCI**

恢复 update 路由和菜单。页面只接受精确 release；显示 preflight、当前版本、目标版本、阶段、错误和 rollback 结果。GitHub token 不回显，日志不输出 token。

- [ ] **Step 5: 测试和提交**

```sh
sh -n openwrt/scripts/chb-update.sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-update.sh \
  openwrt/luci/controller/tiktokproxy/tiktokproxy.lua \
  openwrt/luci/view/tiktokproxy/update.htm \
  openwrt/luci/view/header.htm openwrt/luci/view/themes/argone/header.htm \
  release/app-files.tsv tests/runtime/run.sh
git commit -m "feat: add recoverable application updates"
```

---

## Task 14: M7 — 实现总部确认、金丝雀和分批升级

**Files:**

- Create: `ops/fleet-upgrade.sh`
- Create: `ops/fleet.example.tsv`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 写总部地址边界测试**

inventory 只允许：

```text
device_id<TAB>10.254.x.y<TAB>site<TAB>wave
```

脚本必须拒绝 `10.254.0.0/24` 运维池、非 `10.254.0.0/16` 管理地址、重复 device_id/IP 和空 wave；不得 SSH 到海外 VPS 地址。

- [ ] **Step 2: 定义四个命令**

```text
fleet-upgrade.sh plan app-vX.Y.Z
fleet-upgrade.sh apply app-vX.Y.Z
fleet-upgrade.sh resume <run-id>
fleet-upgrade.sh status <run-id>
```

`plan` 只读并输出每台设备当前 release、schema、磁盘、管理隧道、兼容性。`apply` 要求操作者输入完整 release 标签确认。

- [ ] **Step 3: 固定波次和停波条件**

```text
全量 preflight
1 台 canary
观察窗口
每站点最多 1 台的小批量
其余在线设备分批
离线设备 pending
```

任一设备 `ROLLED_BACK` 或当前波失败率超过 5% 时停止下一波。每台设备使用唯一 upgrade-id；总部中断后 `resume` 不重复已完成事务。

- [ ] **Step 4: 验证下载不走 WireGuard**

总部只经 `wg-mgmt` 发送 SSH 命令和读取状态；artifact 由设备经 WAN 下载。升级大包期间：

```sh
wg show wg-mgmt transfer
ip route get <GitHub release resolved IP>
```

Expected: GitHub 流量不进入 WireGuard；WireGuard 只出现少量命令/状态字节。

- [ ] **Step 5: 提交**

```sh
sh -n ops/fleet-upgrade.sh
sh tests/runtime/run.sh
git diff --check
git add ops/fleet-upgrade.sh ops/fleet.example.tsv tests/runtime/run.sh
git commit -m "feat: add canary fleet application rollout"
```

---

## Task 15: M8 — 扩展 mode-a 和 mode-c，不引入动态网口引擎

**Files:**

- Modify: `openwrt/scripts/chb-network-profile.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/luci/view/tiktokproxy/vps.htm`
- Modify: `tests/runtime/run.sh`
- Modify: `README.md`

- [ ] **Step 1: mode-a 单组桥接**

明确参数：

```text
mode-a --wan <if> --lan <if> --cidr 192.168.10.1/24
```

整个生产 CIDR 绑定一条链路；未绑定时 block。不得宣称按终端 IP 构成安全隔离。

- [ ] **Step 2: mode-b 多下游 NAT**

保持 Task 7 数据模型：每个下游 WAN MAC → 固定 IP → `source_cidr=/32` → 一条 chain。IP/MAC 不一致时阻断。

- [ ] **Step 3: mode-c 业务 VLAN**

明确传入 VLAN 列表，不自动猜测：

```text
mode-c --wan <if> --lan <trunk-if> \
  --vlan 10,192.168.10.1/24 \
  --vlan 20,192.168.20.1/24
```

每个 VLAN 独立 prod interface；VLAN 间无 forwarding；管理地址仍只在 `wg-mgmt`。

- [ ] **Step 4: 三 profile 故障注入**

每种 profile 验证：

- 正确 source 命中正确 chain；
- 未登记 source block；
- sing-box 停止时 prod 无 WAN；
- SSH/LuCI 只在 `wg-mgmt`；
- DNS 捕获只命中对应 prod ingress；
- 海外 VPS 路由走 WAN/VLESS，不走 WireGuard。

- [ ] **Step 5: 提交**

```sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-network-profile.sh \
  openwrt/scripts/generate-config.jq \
  openwrt/luci/view/tiktokproxy/vps.htm tests/runtime/run.sh README.md
git commit -m "feat: add explicit single-lan deployment profiles"
```

---

## Task 16: 全链路验收、24 小时 soak 和分阶段发布

**Files:**

- Create: `docs/runtime-baselines/<device-id>-final.json`
- Create: `docs/runtime-rollout/<release>-report.md`
- Modify: `tests/runtime/run.sh`

- [ ] **Step 1: 本地/CI 全量测试**

```sh
sh tests/runtime/run.sh
git diff --check
```

必须覆盖生成器、不变量、apply rollback、update rollback、WG 边界、release 禁区。

- [ ] **Step 2: 实机网络矩阵**

在认证 x86 硬件逐项验证：

- sing-box 退出；
- TUN 消失；
- 候选 JSON 错误；
- local-dns detour 错误；
- 全局 53 错误；
- rule-set 缺失；
- WAN flap；
- Hub 暂时不可达；
- 海外 VPS 暂时不可达；
- apply 过程中断电；
- app current 切换中断电；
- 用户数据库迁移失败。

- [ ] **Step 3: 性能最终比较**

```sh
ops/runtime/benchmark.sh collect \
  --label final-runtime-isolation \
  --output docs/runtime-baselines/<device-id>-final.json
ops/runtime/benchmark.sh compare \
  --before docs/runtime-baselines/<device-id>-before.json \
  --after docs/runtime-baselines/<device-id>-final.json
```

硬门槛：

- direct/单跳/双跳任一吞吐下降 ≤ 5%；
- CPU 增幅 ≤ 10%；
- sing-box RSS 增幅 ≤ 15%；
- apply 业务中断目标 ≤ 3 秒；
- status API p95 ≤ 300 ms；
- 24 小时无内存、日志、路由或 flash 写入持续增长。

- [ ] **Step 4: 验证 WireGuard 零业务承载**

24 小时业务压测前后保存：

```sh
wg show wg-mgmt
ip route get <日本VPS>
ip route get <美国VPS>
nft list ruleset
```

报告必须证明：

- peer 只有国内总部；
- AllowedIPs 无默认路由；
- 海外 VPS 走 WAN/VLESS；
- WireGuard 字节数只对应管理操作。

- [ ] **Step 5: 按阶段发布，不跨阶段**

发布顺序固定：

```text
M1 管理面
M2 事务 apply
M3 fail-closed
M4 TUN 实测决策
M5 scoped DNS capture
M6 FakeIP canary
M7 应用升级
M8 LAN profiles
```

每一阶段先 1 台、再小批量、再扩大；报告记录 release、commit、设备、指标、失败和 rollback。

- [ ] **Step 6: 最终提交**

```sh
git add docs/runtime-baselines/<device-id>-final.json \
  docs/runtime-rollout/<release>-report.md tests/runtime/run.sh
git commit -m "test: record runtime isolation release evidence"
```

## Definition of Done

- 国内总部可通过固定 `wg-mgmt` 地址 SSH/LuCI，停止 sing-box 不影响管理。
- WireGuard 配置和流量证据中没有海外 peer、默认路由或业务吞吐。
- 所有配置写入口统一经过 `chb-apply-config`；失败 active 不被污染，健康失败恢复 last-good。
- 解绑、禁用、停止和未登记来源全部 fail-closed，不隐式 direct。
- 路由器 bootstrap DNS 与生产客户端 DNS 分离；scoped capture 和 FakeIP 均有抓包证据。
- GitHub Release 已签名，设备通过 WAN 下载；升级失败恢复应用和用户数据。
- mode-a/mode-b/mode-c 都不占用物理管理口，管理地址只存在于 `wg-mgmt`。
- 最终性能满足全部预算，24 小时 soak 无持续资源增长。
- x86 工厂刷机与 OpenWrt 基础固件 OTA 仍未实现，并已明确留待运行时系统完成后重新评审。
