# 子网管理脚本化重构设计

> 本设计取代 `2026-07-21-subnet-init-design.md` 中"API 保留为远程调试"的部分。
> 核心变化: 子网网络层操作(增删改)从 LuCI API **彻底剥离**, 改由独立 SSH 脚本承担。

## 背景

当前子网管理的网络层操作(创建/删除子网会断网)散落在两处:

1. `init-subnets.sh` - 批量初始化(SSH 执行)
2. `tiktokproxy.lua` 的 `action_subnets_add/delete/update` + `apply_subnet_network/revert_subnet_network` - LuCI API, 前端已只读不调用, 但函数仍在

问题:
- 网络层操作有两个入口, 职责不清
- controller 文件 1400+ 行臃肿, 混杂了"会断网"和"不会断网"两类逻辑
- 单个子网的增删改没有 SSH 脚本, 理论上只能通过已被前端废弃的 API 调用

## 目标

**脚本作为子网网络层操作的唯一真相源。**

- 批量初始化: `init-subnets.sh` (系统初始化时跑一次)
- 单个增删查: 4 个独立 SSH 脚本
- controller 删除所有"会断网"的子网逻辑, 只保留只读展示 + 链路换绑(不会断网)
- `init-subnets.sh` 执行完打印可访问的 LuCI URL

## 架构

```
┌─────────────────────────────────────────────────────────────┐
│  脚本层 (SSH 执行, 网络层操作, 会断网)                       │
│  /usr/bin/                                                   │
│    ├─ _subnet-lib.sh         共享库 (source 引入)            │
│    ├─ init-subnets.sh        批量初始化 + --rollback         │
│    ├─ subnet-add.sh          单个创建                        │
│    ├─ subnet-del.sh          单个删除                        │
│    ├─ subnet-list.sh         列出所有子网                    │
│    └─ subnet-inspect.sh      查看单个子网详情                │
└─────────────────────────────────────────────────────────────┘
                          ↓ 读写 (vps-db.sh)
┌─────────────────────────────────────────────────────────────┐
│  数据层 /etc/sing-box/vps.db                                │
└─────────────────────────────────────────────────────────────┘
                          ↑ 只读 + 链路换绑
┌─────────────────────────────────────────────────────────────┐
│  网页层 (LuCI, 不会断网)                                    │
│    ├─ controller: 只读查询 + bind/unbind API                │
│    └─ view: 展示网口/子网/设备 + 更换链路按钮               │
└─────────────────────────────────────────────────────────────┘
```

## 详细设计

### 1. 共享库 `_subnet-lib.sh`

**路径**: `/usr/bin/_subnet-lib.sh` (本地 `openwrt/scripts/_subnet-lib.sh`)
**定位**: 被 5 个脚本 `source` 引入, 不直接执行
**内容**:

| 函数 | 功能 |
|------|------|
| `discover_phys_ifaces` | 遍历 `/sys/class/net/*/device` 发现物理网卡 |
| `get_wan_iface` | 遍历 UCI network 识别 WAN 口 |
| `get_brlan_members` | 读 `network.lan.ifname` 当前 br-lan 成员 |
| `allocate_cidr <used>` | 从 192.168.5 起递增分配 /24, 跳过已占用 |
| `uci_iface_name <eth>` | eth0 -> lan0 命名转换 |
| `count_brlan_remaining <exclude>` | 计算 br-lan 移除某口后剩余成员数 |
| `safe_remove_from_brlan <iface>` | 从 br-lan 移除口, **拒绝移除最后一个成员** |
| `create_uci_interface <iface> <uci_name> <gateway>` | 建 network/dhcp/firewall 三件套 |
| `remove_uci_interface <uci_name>` | 删 network/dhcp/firewall 三件套 |
| `add_subnet_to_db <json>` | 调 `vps-db.sh add-subnet` |
| `delete_subnet_from_db <id_or_iface>` | 调 `vps-db.sh delete-subnet` |
| `list_subnets_from_db` | 调 `vps-db.sh list-subnets` |
| `print_luci_urls` | 打印所有可访问的 LuCI URL (br-lan IP + 所有子网网关) |
| `backup_uci` | 备份 UCI 配置到 `/tmp/network.bak.<timestamp>` |
| 颜色常量 | RED/GREEN/YELLOW/CYAN/NC + ok/warn/err/info/log 函数 |

**安全红线** (内置在 `safe_remove_from_brlan`):
- 计算 br-lan 移除该口后剩余成员数
- 如果剩余 0, 拒绝操作并报错退出
- 调用方无需重复实现这个检查

### 2. `init-subnets.sh` (批量初始化)

**路径**: `/usr/bin/init-subnets.sh`
**命令**:
```
init-subnets.sh [--dry-run | --test <iface> | --rollback]
```

**流程** (复用 `_subnet-lib.sh`):
1. 发现所有物理网口
2. 识别 WAN 口, 排除
3. 备份 UCI 配置
4. 逐口: `safe_remove_from_brlan` + `create_uci_interface` + `add_subnet_to_db`
5. 统一 `uci commit` + 后台 reload
6. 等待网络恢复 (sleep 15)
7. 验证: `ip -br addr` + `vps-db.sh list-subnets`
8. **打印所有可访问的 LuCI URL**

**--rollback 流程**:
1. 读 `vps-db.sh list-subnets`
2. 逐个: `remove_uci_interface` + 网口还回 br-lan + `delete_subnet_from_db`
3. commit + reload
4. 打印 LuCI URL (此时主要是 br-lan 的 192.168.5.1)

**输出示例** (执行完后追加):
```
✓ 初始化完成!

可访问的 LuCI 地址:
  http://192.168.6.1/cgi-bin/luci
  http://192.168.8.1/cgi-bin/luci

SSH 管理:
  ssh root@192.168.6.1
  ssh root@192.168.8.1

如需回滚: init-subnets.sh --rollback
```

### 3. `subnet-add.sh` (单个创建)

**路径**: `/usr/bin/subnet-add.sh`
**命令**:
```
subnet-add.sh <iface> [--name <name>] [--cidr <cidr>] [--dry-run]
```

**参数**:
- `<iface>`: 必填, 物理网口名 (如 eth0)
- `--name`: 可选, 子网名 (默认 `LAN-<iface>`)
- `--cidr`: 可选, 指定 CIDR (默认自动分配)
- `--dry-run`: 预演模式

**流程**:
1. 校验 iface 是物理网口
2. 校验 iface 不是 WAN 口
3. 校验 iface 当前在 br-lan 成员里 (不在说明已被拆出)
4. 校验 iface 还没有子网 (查 vps.db)
5. 备份 UCI
6. `safe_remove_from_brlan` (内置最后成员保护)
7. 分配 CIDR (或用指定的)
8. `create_uci_interface`
9. `add_subnet_to_db`
10. commit + reload
11. 打印新子网信息 + LuCI URL

### 4. `subnet-del.sh` (单个删除)

**路径**: `/usr/bin/subnet-del.sh`
**命令**:
```
subnet-del.sh <iface|subnet_id> [--dry-run]
```

**参数**:
- `<iface|subnet_id>`: 必填, 按网口名或子网 ID 删除
- `--dry-run`: 预演模式

**流程**:
1. 从 vps.db 查到子网记录 (按 iface 或 id)
2. 备份 UCI
3. `remove_uci_interface` (删 network/dhcp/firewall)
4. 网口还回 br-lan (直接 append, 无需 safe_remove 检查)
5. `delete_subnet_from_db`
6. commit + reload
7. 打印剩余可访问 LuCI URL

### 5. `subnet-list.sh` (列出所有子网)

**路径**: `/usr/bin/subnet-list.sh`
**命令**:
```
subnet-list.sh
```

**输出** (表格):
```
ID  NAME      INTERFACE  CIDR              GATEWAY        CHAIN
1   LAN-eth0  eth0       192.168.6.0/24    192.168.6.1    东京->美西
2   LAN-eth2  eth2       192.168.8.0/24    192.168.8.1    未绑定
```

**实现**: 调 `vps-db.sh list-subnets` + `vps-db.sh list-chains` (映射 chain_id -> chain_name), 用 `jq` 格式化输出。

### 6. `subnet-inspect.sh` (查看单个详情)

**路径**: `/usr/bin/subnet-inspect.sh`
**命令**:
```
subnet-inspect.sh <iface|subnet_id>
```

**输出**:
```
=== 子网 #1 LAN-eth0 ===
接口: eth0
CIDR: 192.168.6.0/24
网关: 192.168.6.1
链路: 东京->美西 (chain_id=2)

=== 实时状态 ===
carrier: 1 (已连接)
speed: 1000Mbps
duplex: full
MAC: 00:11:22:33:44:55

=== DHCP 租约 (本子网) ===
192.168.6.100  aa:bb:cc:dd:ee:ff  iPhone-Xiaoming
192.168.6.101  11:22:33:44:55:66  unknown

=== ARP 邻居 ===
192.168.6.100  REACHABLE
192.168.6.101  STALE
```

**实现**: vps.db 子网记录 + `/sys/class/net/<iface>/*` 实时状态 + `/tmp/dhcp.leases` 过滤本网段 + `ip neigh` 过滤本网段。

### 7. controller 清理

**删除的函数** (`openwrt/luci/controller/tiktokproxy/tiktokproxy.lua`):
- `apply_subnet_network` (167 行附近) - 网络层操作, 挪到 `subnet-add.sh`
- `revert_subnet_network` (230 行附近) - 网络层操作, 挪到 `subnet-del.sh`
- `action_subnets_add` (1333 行附近) - API 入口
- `action_subnets_update` (1389 行附近) - API 入口
- `action_subnets_delete` (1429 行附近) - API 入口
- `action_subnets_get` (1313 行附近) - API 入口 (查询单个, 被 `subnet-inspect.sh` 取代)

**删除的路由注册** (510-531 行附近):
- `subnets_get` / `subnets_add` / `subnets_update` / `subnets_delete`

**保留的函数**:
- `action_network_topology` (1127 行) - 网口拓扑总览, 页面用
- `action_subnets_list` (1306 行) - 子网列表, 页面用
- `action_interfaces_list` (1326 行) - 接口列表, 页面用
- `action_subnets_bind` (1456 行) - 链路绑定, 页面"更换"按钮用
- `action_subnets_unbind` (1475 行) - 链路解绑, 页面用
- `get_available_interfaces` (140 行) - 被 network_topology 使用

### 8. 前端 vps.htm

现状已是只读, 仅需清理检查:
- 确认无残留 `showAddSubnet/editSubnet/saveSubnet/delSubnet` 函数定义和引用
- 如有, 删除

### 9. README.md 改造

在现有 README.md 末尾新增一节:

```markdown
## 子网管理

子网的**网络层操作**(创建/删除)会断网, 只能通过 SSH 脚本执行, 不能在网页操作。
网页只负责展示子网状态 + 绑定/解绑链路(不会断网)。

### 脚本一览

| 脚本 | 功能 | 会断网 |
|------|------|--------|
| `init-subnets.sh` | 批量初始化所有 LAN 口 / 回滚 | 是 |
| `subnet-add.sh <iface>` | 单个口拆出子网 | 是 |
| `subnet-del.sh <iface\|id>` | 删子网, 网口还回 br-lan | 是 |
| `subnet-list.sh` | 列出所有子网 | 否 |
| `subnet-inspect.sh <iface\|id>` | 查看单个子网详情 | 否 |

### 典型流程

1. **系统初始化**: `init-subnets.sh --dry-run` 审核 -> `init-subnets.sh --test eth0` 单口测试 -> `init-subnets.sh` 全量
2. **后期新增子网**: `subnet-add.sh eth3`
3. **后期删除子网**: `subnet-del.sh eth0`
4. **查看状态**: `subnet-list.sh` / `subnet-inspect.sh eth0`

### 安全机制

- 所有写操作支持 `--dry-run` 预演
- `init-subnets.sh --rollback` 一键回滚所有子网
- br-lan 最后一个成员禁止拆出 (内置安全红线)
- 执行前自动备份 UCI 配置到 `/tmp/network.bak.<timestamp>`
```

### 10. AGENTS.md 更新

在"软路由文件部署路径"表追加:

| 本地路径 | 软路由路径 |
|---------|-----------|
| `openwrt/scripts/_subnet-lib.sh` | `/usr/bin/_subnet-lib.sh` |
| `openwrt/scripts/subnet-add.sh` | `/usr/bin/subnet-add.sh` |
| `openwrt/scripts/subnet-del.sh` | `/usr/bin/subnet-del.sh` |
| `openwrt/scripts/subnet-list.sh` | `/usr/bin/subnet-list.sh` |
| `openwrt/scripts/subnet-inspect.sh` | `/usr/bin/subnet-inspect.sh` |

## 实施步骤

1. 写 `_subnet-lib.sh` 共享库
2. 重构 `init-subnets.sh` 复用共享库 + 加 LuCI URL 输出
3. 写 `subnet-add.sh`
4. 写 `subnet-del.sh`
5. 写 `subnet-list.sh`
6. 写 `subnet-inspect.sh`
7. 清理 controller (删 6 个函数 + 4 个路由)
8. 清理 vps.htm (检查残留函数)
9. 更新 README.md
10. 更新 AGENTS.md
11. 本地 commit + push
12. 软路由 git pull + 部署
13. 软路由跑 `init-subnets.sh --dry-run` 审核
14. 软路由跑 `init-subnets.sh --test eth0` 单口测试
15. 软路由跑 `init-subnets.sh` 全量执行

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 共享库 source 路径错 | 所有脚本用绝对路径 `/usr/bin/_subnet-lib.sh` source |
| 脚本 bug 导致断网 | 全部支持 `--dry-run` + 执行前备份 UCI |
| br-lan 被拆空 | `safe_remove_from_brlan` 内置最后成员保护 |
| vps.db 与 UCI 不一致 | 写操作顺序: UCI 成功 -> vps.db; 删操作顺序: UCI 回滚 -> vps.db |
| controller 删除影响页面 | 只删"会断网"的函数, 保留只读 + bind/unbind |
| 前端残留调用已删 API | 清理 vps.htm 检查无残留引用 |

## 不做 (YAGNI)

- 子网 update 操作: 改 cidr/gateway 会断网, 改 name 不值得单独脚本, 要改就删了重建
- 脚本的 Web 管理界面: SSH 脚本就是管理界面
- 脚本自动定时执行: 子网初始化是一次性操作
- 多软路由批量管理: 当前只有一个软路由
