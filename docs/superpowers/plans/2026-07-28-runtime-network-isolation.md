# 运行时网络隔离、DNS 与事务化 sing-box 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在不使用任何海外 WireGuard 的前提下，为现有 x86 OpenWrt 系统建立国内总部管理面、光猫路由/桥接双上联档案、限时本地恢复、fail-closed 业务面、事务化 sing-box 配置、分阶段 DNS/FakeIP、可回滚应用升级、明确的单 LAN profile 和受门禁的双栈能力，并用同机 A/B 数据证明升级没有引入不可接受的性能或复杂度回退。

**Architecture:** 继续使用一个 sing-box 进程；OpenWrt 内核 `wg-mgmt` 只承载国内总部到设备本机的 SSH/LuCI/升级命令；设备业务始终使用 direct 或 VLESS，禁止经过 WireGuard。`chb-network-profile` 将显式上联/LAN 档案投影到原生 netifd/UCI，`chb-apply-config` 只负责 sing-box candidate/active/last-good，两者和升级器共享 mutation lock。桥接迁移先 arm 候选和本地恢复入口，再由限时 watcher 切换；应用发布使用签名 GitHub Release、不可变版本目录和原子 `current` 链接，用户数据库、policies 和 uplink 档案永不包含在发布包中。

**Tech Stack:** OpenWrt 24.10、BusyBox `ash`、UCI/netifd、firewall4/nftables、procd、uhttpd、`ppp-mod-pppoe`/`kmod-pppoe`、`kmod-8021q`、odhcp6c/odhcpd、内核 WireGuard、sing-box 1.11.5、SQLite、jq、Lua/LuCI、GitHub Actions、usign。

**Spec:** `docs/superpowers/specs/2026-07-28-runtime-network-isolation-design.md`

## Global Constraints

- WireGuard 只允许“国内总部 Hub ↔ 设备 `wg-mgmt`”；日本、美国及其他海外 VPS 禁止成为 WireGuard peer。
- 设备 WireGuard `AllowedIPs` 禁止 `0.0.0.0/0`、`::/0`、业务 LAN、VLESS 节点和海外 VPS 地址。
- `mgmt` zone 永久 `forward=REJECT`；业务吞吐测试时 WireGuard 计数器不得随业务流量增长。
- 上联只支持显式 `ont-router` 或 `ont-bridge` 档案；不自动穷举协议、VLAN、MAC，不登录或修改运营商光猫。
- `ont-router` 只允许 DHCP/static；`ont-bridge` 允许 PPPoE、DHCP/IPoE、static；两者都保持逻辑接口名 `wan`。
- 光猫路由/桥接迁移先保存候选再 arm；外部光猫已经改变时不得把写回旧 UCI 宣传成必然恢复联网。
- 本地恢复地址只在 ARMED/RECOVERY_REQUIRED 窗口开放，完整 LuCI/SSH 永不监听该地址。
- IPv6 默认关闭；只有 Task 18 的双栈 fail-closed 门禁全部通过后才允许 `native-pd`。
- 本计划不实现 U 盘工厂刷机、磁盘重分区或 OpenWrt 基础固件 A/B OTA；这些在本计划全部验收后重新评审。
- 应用升级属于本计划：设备端升级器和总部批量脚本均为一次性进程，不新增常驻控制服务。
- 冻结 sing-box 1.11.5。FakeIP 金丝雀完成前不得同时升级 sing-box 版本。
- 不新增第二个 sing-box、第二个 DNS daemon、常驻 apply-manager、消息队列或通用网络插件框架。
- 默认采用现有 `auto_route`；只有 Task 11 的同机 A/B 证明 `auto_redirect` 更优且 firewall4 重载稳定，才允许切换。
- `local-dns` 的 `detour` 永远是 `direct`；不得添加无生产来源限制的全局 port 53 规则。
- 所有生产修改必须遵守 `AGENTS.md`：本地修改、commit、push，设备 `git pull` 后部署；禁止直接 scp 覆盖软路由代码。
- 每个 Task 独立提交；每个迁移阶段独立 tag、测试证据和回滚点。前一阶段未过门禁，不开始后一阶段。
- 权威用户数据位于 `/data/tiktokproxy/state`；应用包禁止包含或删除 `state/`、`runtime/`、`backups/`。`/etc/config/network` 中的 WAN 参数只是 active uplink 的原生投影。
- `chb-mgmt`、`chb-network-profile`、网络恢复 guard、`chb-update` 和 sing-box procd 脚本属于固定基础层，普通应用 Release 不得覆盖；当前先通过 Git 版本化部署，未来再进入工厂镜像。
- 网络 apply、sing-box apply、应用 update 共用 `/var/lock/chb-mutation.lock`；并发操作必须返回 BUSY，只有匹配的 parent operation 可嵌套调用。
- 本地测试不能替代实机 nft trace、tcpdump、吞吐和故障注入。

## Target Paths

| 本地文件 | 设备/HQ 路径 | 作用 |
|---|---|---|
| `openwrt/scripts/chb-mgmt.sh` | `/usr/bin/chb-mgmt`（固定基础层） | 设备 `wg-mgmt` 安装、检查、移除 |
| `openwrt/scripts/chb-apply-config.sh` | `/usr/bin/chb-apply-config` | 唯一配置 apply/rollback/status 入口 |
| `openwrt/scripts/chb-network-profile.sh` | `/usr/bin/chb-network-profile`（固定基础层） | 上联档案、LAN profile、UCI 事务、armed watcher |
| `openwrt/config/chb-runtime` | `/etc/config/chb-runtime`（固定基础层） | 国内健康目标和基础运行参数 |
| `openwrt/init.d/chb-network-guard` | `/etc/init.d/chb-network-guard`（固定基础层） | 只在 ARMED/RECOVERY_REQUIRED 时启动 watcher/恢复服务 |
| `openwrt/scripts/chb-recovery-cgi.sh` | `/www/chb-recovery/cgi-bin/recovery`（固定基础层） | 限时、token 保护的三动作恢复页 |
| `openwrt/scripts/chb-update.sh` | `/usr/bin/chb-update`（固定基础层） | 设备应用预检、安装、状态、回滚 |
| `openwrt/scripts/generate-config.sh` | `/etc/sing-box/generate-config.sh` | 只生成显式候选输出 |
| `openwrt/scripts/generate-config.jq` | `/etc/sing-box/generate-config.jq` | 单 sing-box 配置模板 |
| `openwrt/scripts/vps-db.sh` | `/usr/bin/vps-db.sh` | 数据库 CRUD，默认读取 DATA |
| `openwrt/init.d/sing-box` | `/etc/init.d/sing-box`（固定基础层） | procd 有限重启和 active 配置入口 |
| `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua` | `/usr/lib/lua/luci/controller/tiktokproxy.lua` | LuCI API，只调用统一 network/apply/update 入口 |
| `ops/mgmt/wg-hub.sh` | 国内总部 Hub | Hub 初始化、设备 peer 增删和审计 |
| `ops/fleet-upgrade.sh` | 国内总部运维机 | plan/apply/resume/status 分批升级 |
| `ops/runtime/benchmark.sh` | 测试机或设备 | 同机性能基线与 A/B |
| `tests/runtime/run.sh` | 开发机/CI | 最小 shell/JQ/Lua 契约测试 |

## Current Defects That This Plan Must Remove

| 当前位置 | 缺陷 | 处理 Task |
|---|---|---|
| `generate-config.sh` | 直接写 `/etc/sing-box/config.json`，候选失败可能先污染 active | 6、7 |
| `generate-config.sh` / `generate-config.jq` | `route.final=direct`，解绑/禁用可能隐式泄漏 | 9 |
| `generate-config.jq` | 生产日志为 `debug`，rule-set 为远程下载 | 6、10 |
| `generate-config.jq` | TUN MTU 固定 1500，未验证 PPPoE/VLAN+PPPoE | 11 |
| `tiktokproxy.lua` | `apply_config`、`action_on`、`action_chains_apply`、`action_chains_activate`、首次向导等重复生成/重启 | 8 |
| `tiktokproxy.lua` | 固定 sleep、`killall -9`、手工删除 TUN | 7、8 |
| `action_status` | 每次页面轮询同步访问公网出口 IP | 8、10 |
| traffic API | 每次请求全量 grep `/var/log/sing-box.log` | 2、10 |
| controller route | 引用缺失的 settings/traffic/update 页面和 `chb-update` | 2、15 |
| node lifecycle | 引用缺失的 `chb-init-node.sh`、`vps-init.sh`、`speedtest-api.sh` | 2 |
| `network.htm` / controller | 只有 WAN 状态，没有模式、协议、candidate/active/last-good | 4、5 |
| `chain-diagnostics.sh` | 把 WAN 当成固定物理设备，不能表达 PPPoE/VLAN 逻辑 WAN | 4、5 |
| `init-subnets.sh` | 动态拆桥/网口，不适合单 WAN/单 LAN 量产路径 | 4、9、17 |
| UCI/apply/update | 没有跨操作互斥，可能并发重载网络和 sing-box | 4、7、15 |
| test suite | 没有可重复的配置、回滚、DNS、网络性能门禁 | 全部 |

## Cross-Task Interface Contracts

| Producer | Stable output consumed later |
|---|---|
| Task 1 | `release/app-files.tsv`、`tests/runtime/run.sh`、`benchmark.sh collect|compare` |
| Task 2 | 可发布资产集合；被删除的死路由不得被后续 Task 重新注册 |
| Task 3 | `wg-mgmt`、`mgmt` zone、Hub inventory 和设备唯一 `/32` |
| Task 4 | uplink schema 1、逻辑 `wan`、mutation lock、uplink active/last-good |
| Task 5 | `ARMED/RECOVERY_REQUIRED` 状态、限时 guard、三个固定 recovery 动作 |
| Task 6 | DATA 下 `vps.db/policies` 和纯候选 `generate-config.sh --output` |
| Task 7 | `chb-apply-config apply|check|block|rollback|status` 和 sing-box active/last-good |
| Task 8 | controller 的唯一 sing-box apply helper、desired/applied/last-good UI |
| Task 9 | `lan mode-b`、prod fail-closed、防火墙边界 |
| Task 10 | 有界 logd 与显式 diagnostics cache |
| Task 11 | TUN/MTU 基准证据和唯一生产选择 |
| Task 12 | scoped DNS capture、专用 TUN DNS 地址、explicit `hijack-dns` |
| Task 13 | sing-box 1.11.5 IPv4 FakeIP 合同 |
| Task 14 | 已签名、不可变、只包含 `layer=app` 的 Release |
| Task 15 | `chb-update preflight|apply|status|rollback` 和 upgrade journal |
| Task 16 | fleet `plan|apply|resume|status`、波次与停波状态 |
| Task 17 | `lan mode-a/mode-b/mode-c`，不改变 uplink active hash |
| Task 18 | 受门禁的 `ipv6.mode=native-pd`；门禁失败则生产仍只有 `off` |
| Task 19 | 最终基线、故障注入证据和 rollout report |

---

## Task 1: M0 — 建立可重复测试入口、运行资产清单和现网基线

**Files:**

- Create: `tests/runtime/run.sh`
- Create: `release/app-files.tsv`
- Create: `ops/runtime/benchmark.sh`
- Modify: `AGENTS.md`
- Modify: `README.md`

**Interfaces:**

- Consumes: 当前 Git 工作树和认证 x86 测试机。
- Produces: 后续全部 Task 复用的资产 manifest、测试入口和 `benchmark.sh collect|compare`。

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

初始清单只包含当前真实存在的 controller、views、scripts；Task 2 补齐或删除坏引用后再补充对应项，后续 Task 创建新文件时同步追加。明确不包含 `openwrt/scripts/init-subnets.sh`。后续加入的 `chb-mgmt`、`chb-network-profile`、`chb-network-guard`、恢复 CGI、`chb-update` 和 sing-box init 必须标记为 `base`；应用构建只选择 `app`。

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

在 `AGENTS.md` 增加本计划新文件映射、DATA 不可覆盖红线、`chb-network-profile`/`chb-apply-config` 两个职责分离的唯一写入口和应用发布包禁区。在 `README.md` 把 `init-subnets.sh` 标为 legacy/实验工具，删除“量产初始化推荐”表述。

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

**Interfaces:**

- Consumes: Task 1 manifest；当前 controller 的节点初始化和路由注册。
- Produces: 可追踪的节点运行资产；被删除的 traffic/update 死路由在对应 Task 前保持不可见。

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

update 页面和 `chb-update` 在 Task 15 实现前不注册路由，避免 404。

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

**Interfaces:**

- Consumes: Task 1 测试/manifest；国内固定 IPv4 Hub。
- Produces: `wg-mgmt`、`mgmt` zone、Hub/device inventory，供 Task 4 之后所有远程操作使用。

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

## Task 4: M2 — 建立双上联档案、原生 UCI 投影和普通事务

**Files:**

- Create: `openwrt/scripts/chb-network-profile.sh`
- Create: `openwrt/config/chb-runtime`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`
- Modify: `AGENTS.md`

**Interfaces:**

- Consumes: schema 1 的 `/data/tiktokproxy/state/uplink.json`；OpenWrt `uci`、`ubus`、netifd；Task 3 的逻辑 `wg-mgmt`。
- Produces: `chb-network-profile uplink validate|save|plan|apply|status|rollback`；`runtime/uplink/{active,last-good,state}.json`；逻辑接口名始终为 `wan`。

- [ ] **Step 1: 写上联 schema 与脱敏失败测试**

在 `tests/runtime/fixtures/uplink/` 内写三个候选：

```json
{
  "schema": 1,
  "mode": "ont-router",
  "protocol": "dhcp",
  "device": "eth1",
  "vlan_id": null,
  "mac_clone": null,
  "mtu": null,
  "mru": null,
  "dns": {"peerdns": true, "servers": []},
  "dhcp": {"hostname": "", "client_id": "", "vendor_class": ""},
  "pppoe": {"username": "", "password": "", "service_name": "", "ac_name": "", "host_uniq": ""},
  "static": {"address": "", "gateway": ""},
  "ipv6": {"mode": "off"},
  "recovery_cidr": "192.168.255.1/24"
}
```

另建 `bridge-pppoe.json`，只把 `mode` 改为 `ont-bridge`、`protocol` 改为 `pppoe` 并填入测试用户名/密码；`invalid-router-pppoe.json` 使用 `ont-router+pppoe`。

向 `tests/runtime/run.sh` 增加：

```sh
PROFILE="$ROOT/openwrt/scripts/chb-network-profile.sh"
"$PROFILE" uplink validate --input "$FIX/uplink/router-dhcp.json"
"$PROFILE" uplink validate --input "$FIX/uplink/bridge-pppoe.json"
! "$PROFILE" uplink validate --input "$FIX/uplink/invalid-router-pppoe.json"

status=$("$PROFILE" uplink status)
! printf '%s' "$status" | grep -q 'test-pppoe-password'
jq -e '.desired.pppoe.credential_configured == true' <<EOF
$status
EOF
```

同时覆盖非法/不存在 WAN 设备、WAN=LAN、VLAN 0/4095、非法 MAC、static 缺网关、恢复网段与 LAN/TUN/WG 重叠。Run and confirm failure because脚本不存在。

- [ ] **Step 2: 实现最小 CLI、状态机和原子保存**

CLI 固定为：

```text
chb-network-profile uplink validate --input <profile.json>
chb-network-profile uplink save     --input <profile.json>
chb-network-profile uplink plan     --input <profile.json>
chb-network-profile uplink apply    --input <profile.json> --initiator <luci|hq|cli|recovery>
chb-network-profile uplink status
chb-network-profile uplink rollback --initiator <luci|hq|cli|recovery>
```

要求：

- `--input` 必须是普通文件，不能是目录、symlink、FIFO 或 `/proc` 路径；
- 所有 JSON 字段用 jq 读取，不 `eval`、不 `source` 用户文件、不接受原始 UCI 文本；
- `save` 先写同目录临时文件，`fsync` 后 rename 到 `state/uplink.json`，权限 0600；
- `save` 只更新 desired，不 reload 网络；
- `status` 返回单个 JSON：`desired/active/last_good/switch_state/last_error`；
- password、Client ID、Host-Uniq、MAC 只返回是否配置，不返回原值；
- 状态文件同目录 rename，日志不得包含候选全文。

- [ ] **Step 3: 只渲染脚本拥有的 UCI section**

`plan` 输出将执行的 UCI batch，但不提交。渲染规则：

```text
logical interface: network.wan
optional VLAN device: network.chb_wan_vlan
IPv6 first release: network.wan.ipv6=0 and no managed wan6
```

协议映射：

```text
dhcp   → proto=dhcp + hostname/clientid/vendorid + peerdns/dns
pppoe  → proto=pppoe + username/password/service/ac/host_uniq + peerdns/dns
static → proto=static + ipaddr/netmask/gateway + dns
```

无 VLAN 时 `network.wan.device=<physical>`；有 VLAN 时创建命名 802.1Q device 并令 `network.wan.device=<physical>.<vid>`。MAC clone 和 MTU 只写到实际承载 WAN 的 device；空高级字段必须删除旧 UCI option，不能残留上一个档案。

脚本不得修改 LAN、prod、mgmt、TUN、节点数据库或整个匿名 firewall zone；`wan` firewall zone 继续引用逻辑 `wan`。

- [ ] **Step 4: 实现普通网络事务和共享 mutation lock**

`openwrt/config/chb-runtime` 初始健康目标固定为两个不同国内 DNS 提供方：

```text
config health 'network'
        list dns_server '223.5.5.5'
        list dns_server '119.29.29.29'
        option probe_name 'www.baidu.com'
```

允许后续由总部改成自有国内探测地址，但至少保留两个不同地址。脚本不在 apply 时动态下载目标列表。

能力预检精确检查 `ppp-mod-pppoe`/`kmod-pppoe`、`kmod-8021q`、`jq`、`curl`、CA bundle 和 netifd 协议脚本。缺少能力时返回 `CAPABILITY_MISSING`，不得在网络切换过程中临时 `opkg install`。

`apply` 的顺序固定：

```text
acquire /var/lock/chb-mutation.lock
validate candidate and base package capabilities
verify current WAN and wg-mgmt route as preflight
copy network/firewall/dhcp to runtime/uplink/.apply.<id>/
render and validate UCI batch
save active as last-good
recheck network/firewall/dhcp hashes; abort on external change
uci batch + commit only managed changes
ubus call network reload
poll local WAN health
success → write active/state atomically
failure → restore exact config snapshots, reload, verify last-good
release lock
```

锁目录记录 `operation_id`、PID、boot ID；只在 boot ID 改变或 PID 明确不存在时清理。并发第二个网络/apply/update 操作返回 JSON `{"state":"BUSY"}`。

健康检查接受 WAN 私网/CGNAT 地址，要求：

- carrier up；
- `ubus call network.interface.wan status` 的 `up=true`；
- 至少一个 IPv4 地址和默认路由；
- l3 device 可解析；
- bootstrap DNS 可用；
- 对两个国内 DNS 分别执行指定域名查询，至少一个 UDP 和一个 TCP DNS 检查成功；
- Hub endpoint 的 `ip route get` 仍指向逻辑 WAN，不指向 TUN。

海外 VPS、GitHub 和业务链路不参加普通 WAN 成功判定。Hub handshake 记为 manageability 状态，Hub 故障本身不反复改 WAN。

- [ ] **Step 5: 覆盖三种协议和回滚**

PATH mock 与 UCI fixture 至少验证：

```text
ont-router + DHCP
ont-router + static
ont-bridge + PPPoE
ont-bridge + DHCP/IPoE
无 VLAN / VLAN 35
MAC clone / DHCP clientid / vendorid
manual DNS / peerdns
错误密码、错误网关、健康超时、reload 失败
快照后外部 UCI 改动 → CONCURRENT_UCI_CHANGE
apply 过程中 TERM/断电模拟
```

每个失败用例断言 `state/uplink.json` 仍保留用户候选、UCI 和 active 恢复 last-good、`vps.db`/policies 哈希不变。

- [ ] **Step 6: 实机完成同模式 canary**

先只在当前光猫路由模式验证：

```sh
chb-network-profile uplink save --input /tmp/router-dhcp.json
chb-network-profile uplink plan --input /tmp/router-dhcp.json
chb-network-profile uplink apply --input /tmp/router-dhcp.json --initiator hq
chb-network-profile uplink status
ubus call network.interface.wan status
ip route get <国内Hub IPv4>
wg show wg-mgmt
```

Expected: OpenWrt LAN 业务保持、光猫上的其他设备不受影响、总部 SSH 恢复、用户数据哈希不变。

- [ ] **Step 7: 验证并提交**

```sh
sh -n openwrt/scripts/chb-network-profile.sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-network-profile.sh openwrt/config/chb-runtime \
  release/app-files.tsv tests/runtime/run.sh AGENTS.md
git commit -m "feat: add transactional uplink profiles"
```

**M2 ordinary-apply gate:** DHCP/static/PPPoE/IPoE 的 UCI 生成、脱敏、互斥和 last-good 恢复全部通过；尚不允许运营商修改光猫为桥接。

---

## Task 5: M2 — 增加桥接预置切换、只读探测和限时本地恢复

**Files:**

- Modify: `openwrt/scripts/chb-network-profile.sh`
- Create: `openwrt/init.d/chb-network-guard`
- Create: `openwrt/scripts/chb-recovery-cgi.sh`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/tiktokproxy/network.htm`
- Modify: `openwrt/luci/view/header.htm`
- Modify: `openwrt/luci/view/themes/argone/header.htm`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`
- Modify: `AGENTS.md`

**Interfaces:**

- Consumes: Task 4 的 uplink schema、mutation lock、active/last-good；Task 3 的 `wg-mgmt`。
- Produces: `uplink probe|arm|watch-armed|cancel`；后台 desired/active/last-good 状态；只在窗口内可用的 `https://<recovery-ip>:8443/cgi-bin/recovery`。

- [ ] **Step 1: 写 probe 不改 active 的失败测试**

扩展 CLI：

```text
chb-network-profile uplink probe --input <profile.json>
chb-network-profile uplink arm --input <profile.json> --window 1800 --initiator <luci|hq|cli>
chb-network-profile uplink watch-armed
chb-network-profile uplink cancel --initiator <luci|hq|cli>
```

测试使用 PATH mock 记录命令，断言：

```sh
before=$(sha256sum "$TMP/etc/config/network")
result=$("$PROFILE" uplink probe --input "$FIX/uplink/bridge-pppoe.json")
after=$(sha256sum "$TMP/etc/config/network")
test "$before" = "$after"
jq -e '.carrier == true and .pppoe_pado == true' <<EOF
$result
EOF
```

DHCP probe 使用不执行配置脚本的 Discover；PPPoE probe 只运行 discovery；VLAN probe 只创建用户指定 VID 的临时 netdev并用 trap 删除。测试明确拒绝循环扫描 VID、自动保存、自动 apply 和凭据推断。

- [ ] **Step 2: 实现 ARMED 状态和限时 watcher**

`arm` 必须先：

1. 校验当前 active 上联健康且最近有 `wg-mgmt` handshake；
2. 校验候选、依赖包、恢复网段和磁盘空间；
3. 保存候选，备份 UCI 与 last-good；
4. 创建 1800 秒窗口和一次性恢复 token；
5. 启动 `chb-network-guard`。

guard 只在 `ARMED` 或 `RECOVERY_REQUIRED` 时启动子进程。`watch-armed` 每 5 秒检查一次，满足“当前上联连续三次失败”且“候选协议在指定设备/VLAN 有信号”才调用 Task 4 的 apply。单次丢包、Hub 不握手或海外 VPS 失败不能触发。

成功、取消或到期后 watcher 退出；到期写 `EXPIRED` 并删除临时入口。重启时 guard 读取持久状态：未过期 ARMED 可继续，过期状态只清理，不猜测或自动切换。

- [ ] **Step 3: 实现不占物理口的恢复服务**

`arm` 在现有 LAN device 上增加 profile 指定的逻辑地址，默认 `192.168.255.1/24`。若该网段与任何 route/address 重叠则拒绝 arm。

guard 使用现有 uhttpd 二进制启动独立实例：

```text
bind: recovery IPv4 only
port: 8443 TLS
docroot: /www/chb-recovery
CGI: /www/chb-recovery/cgi-bin/recovery
```

不得开放现有 LuCI docroot、Dropbear 或 shell。防火墙只允许物理 LAN ingress 到恢复地址 TCP 8443。

一次性 token 流程：

```text
arm 生成 256-bit token，只显示一次，runtime 只存 SHA-256
POST login 验证成功 → 原子删除 token hash
生成短 session，绑定 client IPv4，HttpOnly + SameSite=Strict
session 到 armed window 结束时失效
每个 POST 使用独立 CSRF nonce
```

CGI 只接受固定动作：

```text
status  → 只读 carrier、协议、地址、路由、错误
retry   → 用固定 WAN 表单字段生成 0600 candidate JSON，validate + save + apply --initiator recovery
restore → chb-network-profile uplink rollback --initiator recovery
```

retry 只接受 schema 1 中的 mode/protocol/device/VLAN/MAC、DHCP、PPPoE、static、DNS、MTU/MRU 字段；密码不预填，空密码保留已存凭据。CGI 生成的路径由程序固定，不接受用户 path、command、原始 UCI 或 shell 参数。成功、取消、restore 完成或超时后删除恢复 IP、firewall rule、token/session 和 uhttpd PID。

- [ ] **Step 4: 将现有网络页改成唯一后台**

在 `network.htm` 保留现有端口状态并增加四个区块：

```text
当前运行
上联配置
LAN profile
切换与恢复
```

普通字段展示 mode/protocol/device；高级区展示 VLAN、MAC、DHCP 标识、PPPoE Service/AC/Host-Uniq、MTU/MRU、DNS。密码永不回显，空值保留，显式复选框才清除。

controller 只增加三个 API：

```text
uplink_status  GET
uplink_save    POST profile JSON
uplink_action  POST action=probe|apply|arm|cancel|rollback
```

Lua 把 JSON 写入固定临时目录的 0600 普通文件后调用脚本，不把表单值拼到 shell。脚本再次做全部校验。UI 必须把 `SAVED` 显示为“待激活”，不能因为保存成功显示“运行中”。

两个 header 默认隐藏标准 LuCI 网络写菜单，产品后台成为唯一受支持的 WAN/LAN 写入口。root 仍可经 SSH 修改 UCI，因此 Task 4 事务必须在快照后、commit 前复核 network/firewall/dhcp 哈希，变化时返回 `CONCURRENT_UCI_CHANGE`，不能覆盖外部修改。

- [ ] **Step 5: 写恢复入口安全和清理测试**

测试至少断言：

- token 首次登录成功、第二次失败；
- session 从另一源 IP 使用失败；
- 缺少/错误 CSRF 的 retry/restore 失败；
- action 不是三个枚举时失败；
- retry 中非法 VLAN、接口、MAC、CIDR 和附加未知字段被主脚本拒绝；
- CGI 不包含 `eval`、`sh -c`、反引号或用户可控命令拼接；
- 完整 LuCI、SSH、文件上传路径在恢复端口不可达；
- EXPIRED/ACTIVE/CANCELLED 后 uhttpd、IP alias、firewall rule、token/session 全部消失；
- `vps.db`、policies 和 sing-box active 哈希在所有恢复动作中不被删除。

- [ ] **Step 6: 实机演练两种外部结果**

演练 A 不修改光猫：

```text
arm bridge candidate
模拟一次/两次 WAN health 失败 → 不切换
等待到期 → EXPIRED + 清理
```

演练 B 由运营商人员修改光猫：

```text
arm bridge candidate
运营商改桥接
watcher 激活 PPPoE/IPoE
WAN 门禁通过
wg-mgmt 恢复
状态 ACTIVE，恢复入口关闭
```

再用错误 PPPoE 密码演练：设备进入 `RECOVERY_REQUIRED`；现场电脑静态地址连接恢复页，修正候选后重试成功。报告必须明确旧 DHCP UCI 在光猫已经桥接时无法恢复外部网络。

- [ ] **Step 7: 验证并提交**

```sh
sh -n openwrt/scripts/chb-network-profile.sh \
  openwrt/init.d/chb-network-guard \
  openwrt/scripts/chb-recovery-cgi.sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-network-profile.sh \
  openwrt/init.d/chb-network-guard \
  openwrt/scripts/chb-recovery-cgi.sh \
  openwrt/luci/controller/tiktokproxy/tiktokproxy.lua \
  openwrt/luci/view/tiktokproxy/network.htm \
  openwrt/luci/view/header.htm openwrt/luci/view/themes/argone/header.htm \
  release/app-files.tsv tests/runtime/run.sh AGENTS.md
git commit -m "feat: add armed bridge cutover recovery"
```

**M2 bridge gate:** 正确候选能恢复国内管理隧道；错误候选可从现有 LAN 逻辑地址修正；没有永久 LAN 管理服务、自动 VLAN 扫描或海外 WireGuard。

---

## Task 6: M3 — 把用户数据迁到 DATA，并让生成器只写显式候选

**Files:**

- Modify: `openwrt/scripts/vps-db.sh`
- Modify: `openwrt/scripts/policy-migrate.sh`
- Modify: `openwrt/scripts/generate-config.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Create: `openwrt/rules/SHA256SUMS`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`

**Interfaces:**

- Consumes: Task 1 manifest、Task 4/5 已存在的 DATA 目录；当前 vps.db/policies。
- Produces: DATA 下权威节点数据和 `generate-config.sh --db --policies --rules --output`。

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

Task 4 已创建的 `state/uplink.json` 不参与旧 `/etc/sing-box` 迁移，任何数据库迁移都不得覆盖、重写或删除它。

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

- [ ] **Step 5: 保持 M3 业务语义，先不启用 FakeIP**

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

## Task 7: M3 — 实现最小事务 apply、last-good 和有限 procd 恢复

**Files:**

- Create: `openwrt/scripts/chb-apply-config.sh`
- Create: `openwrt/init.d/sing-box`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`
- Modify: `AGENTS.md`

**Interfaces:**

- Consumes: Task 4 mutation lock、Task 6 纯候选生成器。
- Produces: `chb-apply-config apply|check|block|rollback|status` 与 sing-box active/last-good。

- [ ] **Step 1: 为失败原子性写测试**

`tests/runtime/run.sh` 使用 PATH mock 的 `sing-box` 和 service 命令，验证：

1. 候选 JSON 非法：active 哈希不变；
2. `sing-box check` 失败：active 哈希不变；
3. 启动后本地健康失败：active 恢复 last-good；
4. 成功：`applied_hash == candidate desired_hash`；
5. 同时两个 apply：第二个返回 `BUSY`，不并发切换；
6. 中断后：active/config.json 或 last-good/config.json 至少一份完整；
7. `rollback` 不修改 vps.db、policies 或 uplink.json；
8. network apply 持有 mutation lock 时 sing-box apply 返回 `BUSY`；
9. 匹配 parent operation 的 updater 可调用 apply，不匹配 ID 被拒绝；
10. WAN 前置检查失败时 active 不变且不重启 sing-box。

Expected: FAIL because脚本不存在。

- [ ] **Step 2: 定义 CLI 和状态 JSON**

```text
chb-apply-config apply --initiator <luci|cli|upgrade> [--parent-operation <id>]
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

退出码：0 成功，2 候选拒绝，3 本地健康失败且已回滚，4 lock busy，5 回滚本身失败。`block` 只停止业务服务、验证 prod 无 WAN 兜底并写 `BLOCKED`，不修改 desired 数据；下一次 `apply` 恢复业务。`--parent-operation` 只允许与 mutation lock 元数据中的顶层 update operation 完全一致，不匹配时返回 4。

- [ ] **Step 3: 实现一次性 apply**

最小算法：

```text
mkdir 原子获取 /var/lock/chb-mutation.lock，trap 释放
检查基础 WAN/DATA/管理 endpoint 路由前置条件；失败则不改变 active
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

lock 目录内记录 operation ID、PID 和当前 boot ID。若 lock 已存在，只能在“boot ID 已变化”或“同一 boot 下 PID 明确不存在”时清理；不得仅按文件时间猜测并抢锁。

禁止固定 `sleep 3 + sleep 2 + sleep 5`；使用最多三次、每次 1 秒的有界轮询。禁止 `killall -9` 作为正常路径。

WAN 地址、默认路由、DATA 可用性和 Hub endpoint 路由是修改前置条件：失败时返回 `PRECONDITION_FAILED`，active 不变。切换后只有进程、TUN、捕获规则、本地 DNS 和候选不变量失败才恢复 sing-box last-good；海外 VPS、GitHub、Hub handshake 或运营商抖动只记 degraded，不做无因果关系的配置回滚。

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

## Task 8: M3 — 收敛所有 LuCI/CLI apply 路径并显示真实运行状态

**Files:**

- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/tiktokproxy/vps.htm`
- Modify: `openwrt/luci/view/tiktokproxy/network.htm`
- Modify: `openwrt/luci/view/admin_status/index.htm`
- Modify: `tests/runtime/run.sh`

**Interfaces:**

- Consumes: Task 7 CLI/state JSON；现有 LuCI controller/view。
- Produces: 唯一 sing-box apply helper 和 desired/applied/last-good 页面语义。

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

## Task 9: M4 — 固化 fail-closed 和 mode-b 默认生产入口

**Files:**

- Modify: `openwrt/scripts/chb-network-profile.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/tiktokproxy/vps.htm`
- Modify: `openwrt/luci/view/tiktokproxy/network.htm`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`
- Modify: `README.md`

**Interfaces:**

- Consumes: Task 4 的 active uplink、mutation lock 和 UCI snapshot；Task 7 的 sing-box apply；现有 chains/subnets。
- Produces: `/data/tiktokproxy/state/lan-profile.json`、`runtime/lan/{active,last-good,state}.json`、`chb-network-profile lan plan|apply|status|rollback`。

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
chb-network-profile lan plan mode-b --lan <if> --cidr 192.168.20.1/24
chb-network-profile lan apply mode-b --lan <if> --cidr 192.168.20.1/24
chb-network-profile lan status
chb-network-profile lan rollback
```

不保留旧式 `plan mode-b --wan ...` 兼容入口。脚本不得自动枚举并拆分网卡；LAN 参数必须显式，并与 Task 4 active uplink 的物理/VLAN device 不同。复用 mutation lock、UCI snapshot 和 last-good，不复制第二套事务函数。规则：

- `prod -> wan` 不存在；
- `prod -> mgmt` 不存在；
- `mgmt` forward REJECT；
- prod input 只允许 DHCP、必要 ICMP；DNS 在 Task 12 前仍按当前路径；
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
  openwrt/luci/view/tiktokproxy/network.htm \
  release/app-files.tsv tests/runtime/run.sh README.md
git commit -m "feat: make production routing fail closed"
```

**M4 rollback:** 恢复上一 UCI snapshot 和上一应用 release；uplink、用户数据库和 policies 不回滚、不删除。

---

## Task 10: M4 — 收紧日志和运行状态开销

**Files:**

- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/scripts/chain-diagnostics.sh`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/admin_status/index.htm`
- Modify: `tests/runtime/run.sh`

**Interfaces:**

- Consumes: Task 8 本地状态 API、现有 diagnostics。
- Produces: 有界 logd、按需 diagnostics cache 和可重复的 M4 性能结果。

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

用 Task 1 脚本生成 `after-m4.json`，确认：

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

## Task 11: M5 — 用实测决定保留 auto_route 还是切 auto_redirect

**Files:**

- Modify: `ops/runtime/benchmark.sh`
- Conditional Modify: `openwrt/scripts/generate-config.jq`
- Create: `docs/runtime-baselines/<device-id>-tun-ab.json`

**Interfaces:**

- Consumes: Task 1 benchmark、Task 4 上联档案、Task 9 fail-closed。
- Produces: 唯一生产 TUN 模式与按上联验证的 MTU 决策证据。

- [ ] **Step 1: 为同配置生成两个仅 TUN 模式不同的候选**

除 `auto_redirect` 开关外，节点、规则、DNS、MTU、日志完全一致。每个候选先 `sing-box check`。TUN 模式和 MTU 是两个实验变量，不允许同一轮同时改变。

- [ ] **Step 2: 每种模式预热后测三轮**

顺序使用 ABBA，避免时间偏差：

```text
auto_route → auto_redirect → auto_redirect → auto_route
```

每轮记录 direct、单跳、双跳吞吐，CPU、RSS、丢包、连接建立时间、firewall4 reload 前后连接和 nft 规则。至少在光猫路由 DHCP 与光猫桥接 PPPoE 两种上联各完成一组；有运营商 VLAN 时再完成 VLAN+PPPoE。

在选定 TUN 模式后，单独比较 MTU 1500、1492、1420、1400，记录 TCP、UDP、QUIC、STUN、直播推流、PMTU 和分片。只允许把“同一种上联下全部关键业务通过且吞吐不回退”的值写入按 uplink protocol 选择的配置；否则保持当前 1500。

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

**M5 gate:** 没有数据就没有 TUN 模式切换。

---

## Task 12: M6 — 上线限定生产入口的 DNS 捕获，保持当前解析策略

**Files:**

- Modify: `openwrt/scripts/chb-network-profile.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/scripts/chb-apply-config.sh`
- Modify: `tests/runtime/run.sh`

**Interfaces:**

- Consumes: Task 9 prod ingress、Task 11 TUN 决策、Task 7 候选不变量。
- Produces: scoped TCP/UDP 53 capture、专用 TUN DNS 地址与 explicit `hijack-dns`。

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

## Task 13: M7 — 独立金丝雀启用 sing-box 1.11.5 FakeIP

**Files:**

- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/scripts/chb-apply-config.sh`
- Modify: `tests/runtime/run.sh`
- Create: `docs/runtime-baselines/<device-id>-fakeip-canary.json`

**Interfaces:**

- Consumes: Task 12 scoped capture、本地 rule-set 和 sing-box 1.11.5。
- Produces: IPv4 FakeIP、CN real-IP 与非 CN 无明文 A 查询的运行合同。

- [ ] **Step 1: 写 FakeIP 契约测试**

断言：

- `dns.fakeip.enabled == true`；
- IPv4 池为保留测试网段 `198.18.0.0/15`；
- 非 CN A 使用 `address: "fakeip"` server；
- CN A 仍走 `local-dns` direct；
- Task 18 前不启用生产 IPv6；非 CN AAAA 不得触发 WAN 真实查询；
- 非 A/AAAA 按 source 绑定链路查询；
- route 可将 FakeIP 映射恢复为域名；
- 没有远程 rule-set。

- [ ] **Step 2: 只改 FakeIP，不改其他大项**

保持 M6 的 DNS 捕获、M5 选定的 TUN 模式、sing-box 1.11.5、VLESS 链路和日志级别。不要在此 commit 升级 sing-box 或切换 TUN 模式。

- [ ] **Step 3: 扩展 apply 本地 DNS 门禁**

候选启动后本地验证：

- CN 测试域名 A 返回非 198.18/15 地址；
- 国外测试域名 A 返回 198.18/15；
- 国外测试域名 AAAA 不从 WAN 取得真实地址；
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

**M7 rollback:** 应用 last-good release；不改数据库 schema，不清理 DNS 用户数据，因为 FakeIP 映射是运行态。

---

## Task 14: M8 — 建立签名应用 Release

**Files:**

- Create: `release/build-app-release.sh`
- Create: `release/manifest.jq`
- Create: `release/keys/app-release.pub`
- Create: `.github/workflows/release-app.yml`
- Modify: `tests/runtime/run.sh`

**Interfaces:**

- Consumes: Task 1 manifest、Task 6 本地 rule-set、Task 1-13 测试。
- Produces: 精确 tag/commit、usign 签名且不含 base/state/runtime 的应用 Release。

- [ ] **Step 1: 写发布包禁区测试**

构建后检查：

```sh
tar -tf "$ARTIFACT" > "$TMP/list"
! grep -E '(^|/)(state|runtime|backups)(/|$)' "$TMP/list"
! grep -E '(^/|(^|/)\\.\\.(/|$))' "$TMP/list"
! grep -E '(^|/)(chb-mgmt|chb-network-profile|chb-network-guard|chb-recovery-cgi|chb-update|chb-runtime|etc/init.d/sing-box)$' "$TMP/list"
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

## Task 15: M8 — 实现设备端应用升级和用户数据保护

**Files:**

- Create: `openwrt/scripts/chb-update.sh`
- Create: `openwrt/luci/view/tiktokproxy/update.htm`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/header.htm`
- Modify: `openwrt/luci/view/themes/argone/header.htm`
- Modify: `release/app-files.tsv`
- Modify: `tests/runtime/run.sh`

**Interfaces:**

- Consumes: Task 14 签名 Release、Task 4 mutation lock、Task 7 parent operation apply。
- Produces: `chb-update preflight|apply|status|rollback|bootstrap-links` 和幂等 upgrade journal。

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
uplink.json SHA-256 不变
network/firewall/dhcp UCI 哈希不变
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

1. 从 `ubus call network.interface.wan status` 读取当前 `l3_device`，确认 `ip route get` 走该设备；
2. `curl --interface <l3_device>` 下载 manifest、签名和 artifact；不能把 UCI 名 `wan` 当成 Linux netdev；
3. usign 验签、SHA-256 校验；
4. 拒绝绝对路径、`..`、越界 symlink、state/runtime/backups；
5. 解包到唯一 `releases/app-vX.Y.Z`；
6. 仅 schema 变化时创建 `/data/tiktokproxy/backups/<upgrade-id>`；
7. 在数据库副本执行 expand-only 迁移；
8. 检查 integrity、关键表行数不减少、policies JSON；
9. 用新 release 生成候选并 `sing-box check`；
10. 写 upgrade journal，原子切换 `/data/tiktokproxy/current`；
11. 持有全局 mutation lock，并调用 `chb-apply-config apply --initiator upgrade --parent-operation <upgrade-id>`；
12. 清理 LuCI module/index cache，并只重启受影响的 uhttpd；
13. 健康失败恢复旧 current、数据库和 policies；
14. 成功后保留有界备份，绝不递归删除 DATA 根。

重复相同 `upgrade-id` 必须从 journal 恢复或返回已有终态，不能重复迁移。

`bootstrap-links` 只创建一次固定运行 symlink，例如 `/usr/bin/chb-apply-config -> /data/tiktokproxy/current/usr/bin/chb-apply-config`；不得替换 `/usr/bin/chb-update`、`/usr/bin/chb-mgmt`、`/usr/bin/chb-network-profile`、网络恢复 guard/CGI 或 `/etc/init.d/sing-box`。普通 app 切换只移动 `current`，不会逐文件覆盖系统路径。

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

## Task 16: M8 — 实现总部确认、金丝雀和分批升级

**Files:**

- Create: `ops/fleet-upgrade.sh`
- Create: `ops/fleet.example.tsv`
- Modify: `tests/runtime/run.sh`

**Interfaces:**

- Consumes: Task 3 mgmt inventory、Task 15 device updater/status。
- Produces: fleet `plan|apply|resume|status`、波次、停波和每设备 upgrade-id。

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

## Task 17: M9 — 扩展 mode-a 和 mode-c，不引入动态网口引擎

**Files:**

- Modify: `openwrt/scripts/chb-network-profile.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/luci/view/tiktokproxy/vps.htm`
- Modify: `openwrt/luci/view/tiktokproxy/network.htm`
- Modify: `tests/runtime/run.sh`
- Modify: `README.md`

**Interfaces:**

- Consumes: Task 4 active uplink、Task 9 mode-b/事务、Task 12 DNS capture。
- Produces: 同一 `lan` CLI 下的 mode-a/mode-b/mode-c，uplink active hash 不变。

- [ ] **Step 1: mode-a 单组桥接**

明确参数：

```text
chb-network-profile lan plan  mode-a --lan <if> --cidr 192.168.10.1/24
chb-network-profile lan apply mode-a --lan <if> --cidr 192.168.10.1/24
```

整个生产 CIDR 绑定一条链路；未绑定时 block。不得宣称按终端 IP 构成安全隔离。

- [ ] **Step 2: mode-b 多下游 NAT**

保持 Task 9 数据模型：每个下游 WAN MAC → 固定 IP → `source_cidr=/32` → 一条 chain。IP/MAC 不一致时阻断。

- [ ] **Step 3: mode-c 业务 VLAN**

明确传入 VLAN 列表，不自动猜测：

```text
chb-network-profile lan apply mode-c --lan <trunk-if> \
  --vlan 10,192.168.10.1/24 \
  --vlan 20,192.168.20.1/24
```

每个 VLAN 独立 prod interface；VLAN 间无 forwarding；日常管理地址仍只在 `wg-mgmt`，Task 5 的限时恢复地址不属于业务 VLAN。

- [ ] **Step 4: 三 profile 故障注入**

每种 profile 验证：

- 正确 source 命中正确 chain；
- 未登记 source block；
- sing-box 停止时 prod 无 WAN；
- SSH/LuCI 只在 `wg-mgmt`；
- DNS 捕获只命中对应 prod ingress；
- 海外 VPS 路由走 WAN/VLESS，不走 WireGuard。
- 在 `ont-router+dhcp` 和 `ont-bridge+pppoe` 下分别应用同一个 LAN profile，断言上联 active hash 不变；
- uplink apply 与 LAN apply 并发时只有一个获得 mutation lock，失败方不留下半 UCI。

- [ ] **Step 5: 提交**

```sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-network-profile.sh \
  openwrt/scripts/generate-config.jq \
  openwrt/luci/view/tiktokproxy/vps.htm \
  openwrt/luci/view/tiktokproxy/network.htm \
  tests/runtime/run.sh README.md
git commit -m "feat: add explicit single-lan deployment profiles"
```

---

## Task 18: M10 — 在完整 fail-closed 门禁下开放原生 IPv6 PD

**Files:**

- Modify: `openwrt/scripts/chb-network-profile.sh`
- Modify: `openwrt/scripts/generate-config.jq`
- Modify: `openwrt/scripts/chb-apply-config.sh`
- Modify: `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`
- Modify: `openwrt/luci/view/tiktokproxy/network.htm`
- Modify: `ops/runtime/benchmark.sh`
- Modify: `tests/runtime/run.sh`
- Create: `docs/runtime-baselines/<device-id>-ipv6-canary.json`

**Interfaces:**

- Consumes: Task 4 的 `uplink.ipv6.mode`、Task 9/17 的 prod 接口、Task 12 scoped DNS、Task 13 FakeIP。
- Produces: `ipv6.mode=off|native-pd`；逻辑 `wan6` 与 prod IPv6 TUN/FakeIP 路径；不改变国内-only `wg-mgmt` IPv4 管理。

- [ ] **Step 1: 先证明默认 off 没有 IPv6 旁路**

fixture 生成 `ipv6.mode=off` 后断言：

```sh
! uci -c "$TMP/etc/config" show network.wan6 2>/dev/null
! uci -c "$TMP/etc/config" show dhcp | grep -Eq 'ra=.server.|dhcpv6=.server.'
! jq -e '.inbounds[0].address[] | contains(":")' "$CONFIG"
! nft list ruleset | grep -q 'prod.*accept.*wan6'
```

在 namespace 客户端执行 `curl -6` 必须失败，IPv4 保持当前行为。Run and confirm current implementation fails at least one contract before adding native-pd support.

- [ ] **Step 2: 只实现运营商原生 DHCPv6-PD**

上联 schema 只增加已设计的：

```json
{"ipv6":{"mode":"native-pd"}}
```

不增加 DS-Lite、MAP-E、NAT66 或任意 UCI passthrough。UCI 投影：

```text
network.wan.ipv6=1
network.wan6.proto=dhcpv6
network.wan6.device=@wan
network.wan6.reqaddress=try
network.wan6.reqprefix=auto
```

LAN profile 为每个 prod interface 分配明确 `ip6assign`，odhcpd 只在对应 prod 提供 RA/DHCPv6；mgmt、recovery、WAN 不下发生产前缀。PD 缺失、前缀重叠或续租失败显示 `IPV6_DEGRADED`，不删除 IPv4 active。

- [ ] **Step 3: 给单 sing-box 增加 IPv6 TUN 和 FakeIP**

在保持 sing-box 1.11.5 的前提下：

```text
TUN address 增加固定 ULA /126
dns.fakeip.inet6_range = fc00::/18
非 CN AAAA → FakeIP IPv6
CN AAAA → local-dns direct
业务 IPv6 final → block
```

候选不变量必须拒绝：

- 有 prod IPv6 默认路由但 TUN 没 IPv6 address；
- 有非 CN AAAA 真实 DNS upstream；
- IPv6 direct 没有 `source_ip_cidr` 和 CN/自定义 direct 策略；
- `::/0` 被加入 WireGuard AllowedIPs；
- FakeIP IPv6 池与 LAN ULA、delegated prefix 或 TUN IPv6 网段重叠。

- [ ] **Step 4: 固化 IPv6 firewall parity**

firewall4 规则必须满足：

```text
prod → wan/wan6 没有通用 forwarding
prod IPv6 只进入 TUN 捕获路径
sing-box 失败时 prod IPv4/IPv6 同时阻断
router bootstrap IPv6 不进入客户端 DNS capture
mgmt forward 仍 REJECT
recovery 服务仍只监听 IPv4 临时地址
```

ICMPv6 只允许 ND、RA/RS、Packet Too Big 等协议必需类型；不能用“全拒 ICMPv6”掩盖路径问题。

- [ ] **Step 5: 扩展健康检查和状态**

`chb-network-profile uplink status` 增加：

```json
{
  "ipv6": {
    "mode": "native-pd",
    "wan_address": true,
    "delegated_prefix": true,
    "prod_ra": true,
    "tun_route": true,
    "leak_test": "pass"
  }
}
```

只展示前缀是否存在和脱敏摘要，不把完整动态地址作为设备身份。IPv6 外部探测失败记 degraded；配置结构、PD 投影或 fail-closed 缺失才拒绝启用。

- [ ] **Step 6: 完成双上联 × 三 LAN 的双栈矩阵**

至少验证：

```text
ont-router DHCP + mode-a/mode-b/mode-c
ont-bridge PPPoE + mode-a/mode-b/mode-c
ont-bridge IPoE + mode-a/mode-b/mode-c
有/无 WAN VLAN
PD 初次获取、续租、WAN flap、PPPoE 重拨
国外 A/AAAA FakeIP、CN A/AAAA direct
TCP/UDP/QUIC/STUN/直播推流
sing-box stop、TUN 删除、DNS 错误
```

抓包必须证明国外 A/AAAA 没有从 WAN 明文外查；停止 sing-box 后 IPv6 客户端无法直出；`wg-mgmt` peer 和字节计数仍只有国内管理。

- [ ] **Step 7: 性能和 24 小时 canary**

用 Task 1 benchmark 保存：

```sh
ops/runtime/benchmark.sh collect \
  --label ipv6-native-pd-canary \
  --output docs/runtime-baselines/<device-id>-ipv6-canary.json
```

门槛与 IPv4 相同：吞吐下降 ≤5%、CPU 增幅 ≤10%、RSS 增幅 ≤15%，24 小时无前缀漂移、路由残留、内存/日志增长。任何一项失败时不提交生产 `native-pd` 变更，只提交失败证据和测试；全量设备继续 `off`。

- [ ] **Step 8: 门禁通过后提交**

```sh
sh -n openwrt/scripts/chb-network-profile.sh \
  openwrt/scripts/chb-apply-config.sh
sh tests/runtime/run.sh
git diff --check
git add openwrt/scripts/chb-network-profile.sh \
  openwrt/scripts/generate-config.jq \
  openwrt/scripts/chb-apply-config.sh \
  openwrt/luci/controller/tiktokproxy/tiktokproxy.lua \
  openwrt/luci/view/tiktokproxy/network.htm \
  ops/runtime/benchmark.sh tests/runtime/run.sh \
  docs/runtime-baselines/<device-id>-ipv6-canary.json
git commit -m "feat: gate native ipv6 through fail-closed routing"
```

**M10 gate:** 没有 PD 线路、IPv6 抓包和故障注入证据就不向生产后台开放 `native-pd`；IPv4 方案不受阻。

---

## Task 19: 全链路验收、24 小时 soak 和分阶段发布

**Files:**

- Create: `docs/runtime-baselines/<device-id>-final.json`
- Create: `docs/runtime-rollout/<release>-report.md`
- Modify: `tests/runtime/run.sh`

**Interfaces:**

- Consumes: Task 1-18 全部产物和各阶段证据。
- Produces: 最终基线、rollout report、可进入批量开发发布的 Definition of Done 证据。

- [ ] **Step 1: 本地/CI 全量测试**

```sh
sh tests/runtime/run.sh
git diff --check
```

必须覆盖上联/LAN UCI 事务、armed/recovery 清理、生成器不变量、sing-box apply rollback、update rollback、WG 边界、release 禁区和 IPv4/IPv6 fail-closed。

- [ ] **Step 2: 实机网络矩阵**

在认证 x86 硬件逐项验证：

- sing-box 退出；
- TUN 消失；
- 候选 JSON 错误；
- local-dns detour 错误；
- 全局 53 错误；
- rule-set 缺失；
- 光猫路由 DHCP、static；
- 光猫桥接 PPPoE、IPoE；
- WAN VLAN、MAC clone、错误账号、错误 VLAN；
- armed 单次抖动、窗口过期、成功切换和 `RECOVERY_REQUIRED`；
- 恢复 token 重放、跨源 IP 和超时清理；
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
- DHCP/IPoE 同模式恢复目标 ≤ 15 秒；
- PPPoE 恢复目标 ≤ 30 秒，或记录运营商侧超时证据；
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
M2 双上联档案、armed cutover、本地恢复
M3 sing-box 事务 apply
M4 fail-closed
M5 TUN/MTU 实测决策
M6 scoped DNS capture
M7 FakeIP canary
M8 应用升级
M9 LAN profiles
M10 IPv6 native-pd canary
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
- 光猫路由 DHCP/static 与光猫桥接 PPPoE/IPoE 都由后台显式档案管理；上联与 LAN profile 相互独立。
- 桥接切换可预置并 arm；外部状态不匹配时进入受限本地恢复，不谎报自动联网回滚。
- 恢复入口不占独立物理口，只在窗口内开放三个固定动作，token/session/端口按期清理。
- 网络写入统一经过 `chb-network-profile`，sing-box 写入统一经过 `chb-apply-config`，升级经过 `chb-update`；三者共享 mutation lock。
- sing-box 失败 active 不被污染，候选造成的本地健康失败恢复 last-good；运营商或海外抖动不触发无意义回滚。
- 解绑、禁用、停止和未登记来源全部 fail-closed，不隐式 direct。
- 路由器 bootstrap DNS 与生产客户端 DNS 分离；scoped capture 和 FakeIP 均有抓包证据。
- GitHub Release 已签名，设备通过 WAN 下载；升级失败恢复应用和用户数据。
- mode-a/mode-b/mode-c 都不占用物理管理口；日常管理地址只存在于 `wg-mgmt`，桥接切换窗口只有受限恢复地址。
- `ipv6.mode=off` 无旁路；只有双栈抓包、故障注入和性能门禁通过的版本才开放 `native-pd`。
- 最终性能满足全部预算，24 小时 soak 无持续资源增长。
- x86 工厂刷机与 OpenWrt 基础固件 OTA 仍未实现，并已明确留待运行时系统完成后重新评审。
