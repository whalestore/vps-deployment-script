# 子网初始化与网页只读化设计

## 背景

当前子网管理通过 LuCI 网页操作（创建/编辑/删除子网），用户可以直接在网页上拆分网络接口。这导致了灾难性事故：拆走 br-lan 最后一个成员后网络完全不可达。

根本问题是：子网拆分是网络基础设施操作，不应该由用户在网页上操作。应该由初始化脚本一次性完成，网页只负责展示和绑定链路。

## 目标

1. **初始化脚本**：通过 SSH 执行，一次性把所有 LAN 口拆出独立子网
2. **网页只读化**：移除子网增删改操作，只展示状态 + 绑定链路
3. **隐藏接口**：subnets_add/delete API 保留，用于远程调试
4. **安全测试**：dry-run 模式 + 单口测试 + 全量执行三步走

## 设计

### 1. 初始化脚本 `init-subnets.sh`

**路径**: `/usr/bin/init-subnets.sh`
**触发**: SSH 手动执行，不暴露在网页上
**前提**: dropbear 监听 `0.0.0.0:22`（已确保）

#### 执行模式

| 模式 | 命令 | 说明 |
|------|------|------|
| dry-run | `init-subnets.sh --dry-run` | 模拟整个过程，输出详细调试日志，不执行任何 UCI 命令 |
| 单口测试 | `init-subnets.sh --test eth0` | 只拆一个口，完整测试后可回滚 |
| 全量执行 | `init-subnets.sh` | 拆出所有 LAN 口子网 |

#### dry-run 模式详细设计

dry-run 模式**模拟整个拆分过程**，输出每一步将要执行的命令和预期结果，但不实际修改任何配置：

```
[dry-run] === 子网初始化模拟 ===
[dry-run] 发现物理网口: eth0, eth1, eth2
[dry-run] WAN 口识别: eth1 (uci get network.wan.ifname = eth1)
[dry-run] 待拆分 LAN 口: eth0, eth2

[dry-run] === 处理 eth0 ===
[dry-run] 当前 br-lan 成员: eth2 (uci get network.lan.ifname)
[dry-run] 将从 br-lan 移除: eth0
[dry-run]   命令: uci set network.lan.ifname='eth2'
[dry-run] 将创建 UCI 接口: lan0
[dry-run]   命令: uci set network.lan0=interface
[dry-run]   命令: uci set network.lan0.proto='static'
[dry-run]   命令: uci set network.lan0.ifname='eth0'
[dry-run]   命令: uci set network.lan0.ipaddr='192.168.6.1'
[dry-run]   命令: uci set network.lan0.netmask='255.255.255.0'
[dry-run] 将创建 DHCP 池: dhcp.lan0
[dry-run]   命令: uci set dhcp.lan0=dhcp
[dry-run]   命令: uci set dhcp.lan0.interface='lan0'
[dry-run]   命令: uci set dhcp.lan0.start='100'
[dry-run]   命令: uci set dhcp.lan0.limit='50'
[dry-run] 将加入防火墙: lan0 -> lan zone
[dry-run]   命令: uci add_list firewall.@zone[0].network='lan0'
[dry-run] 将写入 vps.db: add-subnet {name: "LAN0", interface: "eth0", cidr: "192.168.6.0/24"}

[dry-run] === 处理 eth2 ===
[dry-run] 当前 br-lan 成员: (空, eth0 已在上一步移除)
[dry-run] 将从 br-lan 移除: eth2
[dry-run]   命令: uci set network.lan.ifname=''
[dry-run] 警告: br-lan 将无物理成员! br-lan 接口 IP 192.168.5.1 将不可达
[dry-run] 警告: 但 SSH 通过子网网关 (192.168.6.1, 192.168.7.1) 仍可达
[dry-run] 将创建 UCI 接口: lan2
...

[dry-run] === 最终步骤 ===
[dry-run] 将执行: uci commit network; uci commit dhcp; uci commit firewall
[dry-run] 将执行: /etc/init.d/network reload; dnsmasq restart; firewall restart
[dry-run] 预期结果: eth0 -> 192.168.6.0/24, eth2 -> 192.168.7.0/24, br-lan 无成员

[dry-run] === 模拟完成, 未修改任何配置 ===
```

#### 全量执行流程

1. **备份**: `uci show network > /tmp/network.bak.$(timestamp)`
2. **发现物理网口**: 遍历 `/sys/class/net/`，用 `device` 目录判断物理网卡
3. **识别 WAN 口**: 遍历 UCI network 配置，匹配 `ifname`/`device` 找到 WAN 口
4. **CIDR 自动分配**: 从 `192.168.5.0/24` 起递增（跳过 br-lan 默认网段和已占用网段）
5. **逐口写 UCI 配置**（不 commit，不 reload）:
   - 从 `network.lan.ifname` 移除该口
   - 建 `network.lanN` 独立接口（IP = `192.168.X.1/24`）
   - 建 `dhcp.lanN` DHCP 池（start=100, limit=50）
   - 加入 `firewall.@zone[0]` (lan zone)
6. **写入 vps.db**: 对每个口调 `vps-db.sh add-subnet`
7. **统一 commit + reload**: `uci commit network dhcp firewall` + 后台 `network reload`
8. **等待网络恢复**: sleep 10
9. **验证**: 检查每个子网接口的 IP 是否生效

#### 单口测试流程 (`--test eth0`)

1. 执行完整的拆分逻辑，但只针对一个口
2. 拆出后等待网络 reload
3. 验证:
   - 新子网接口 IP 生效
   - DHCP 正常分配
   - SSH 通过新子网网关可达
4. 测试完成后可选回滚: `init-subnets.sh --rollback eth0`

#### 回滚机制

- `init-subnets.sh --rollback`: 删除所有初始化创建的子网，网口还回 br-lan
- 每次执行前自动备份 UCI 配置到 `/tmp/network.bak.<timestamp>`
- 如果执行失败，脚本输出恢复命令: `uci import < /tmp/network.bak.<timestamp>`

### 2. 网页只读化改造

#### 移除的操作（前端 vps.htm）

- 移除「+ 拆出此口创建子网」按钮
- 移除「编辑子网」按钮
- 移除「删除子网」按钮
- 移除子网模态框（创建/编辑表单）
- 移除 `showAddSubnet()` / `editSubnet()` / `saveSubnet()` / `delSubnet()` / `closeSubnetModal()` 函数

#### 保留的操作

- 网口卡片展示（物理状态 + 子网信息 + 连接设备）
- 「更换链路」按钮 + 模态框（`showChainModal()` / `doChangeChain()`）
- 「刷新」按钮

#### 后端 API 保留

以下 API 保留但不被前端调用，仅供 SSH 远程调试:
- `subnets_add` / `subnets_update` / `subnets_delete`
- `subnets_bind` / `subnets_unbind`（前端「更换链路」调用）
- `subnets_list` / `subnets_get` / `interfaces_list` / `network_topology`

### 3. 安全红线

| # | 红线 | 实现 |
|---|------|------|
| 1 | dropbear 监听 `0.0.0.0:22` | 已完成 |
| 2 | `apply_subnet_network` 禁止拆走 br-lan 最后一个成员 | 已完成 |
| 3 | 初始化脚本必须先 dry-run 审核 | 脚本内置 dry-run 模式 |
| 4 | 初始化脚本必须先单口测试 | 脚本内置 --test 模式 |
| 5 | 初始化脚本执行前自动备份 UCI 配置 | 脚本内置备份逻辑 |

## 实施步骤

1. **编写 `init-subnets.sh` 脚本**（含 dry-run / --test / 全量 / --rollback 模式）
2. **单口测试**: `init-subnets.sh --dry-run` 审核 → `init-subnets.sh --test eth0` 测试
3. **全量执行**: `init-subnets.sh`
4. **网页只读化**: 修改 vps.htm 移除增删改操作
5. **验证**: 确认网页只显示状态 + 绑定链路，SSH 远程调试 API 可用

## 风险与缓解

| 风险 | 缓解 |
|------|------|
| 初始化脚本 bug 导致断网 | dry-run 审核逻辑 → 单口测试 → 全量执行 |
| br-lan 无成员后不可达 | dropbear 监听所有接口 + 任意子网网关 SSH |
| UCI 配置写错 | 脚本前自动备份 + --rollback 回滚 |
| vps.db 数据不一致 | 先写 UCI 成功后再写 vps.db |
