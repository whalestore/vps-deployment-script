# AGENTS.md - 开发规则

## 版本追踪流程（强制）

**禁止直接 scp 覆盖软路由上的文件。** 所有代码修改必须通过 git 版本追踪：

1. 在本地代码库 `/Users/caoxuefei/Codes/xuefei/vps/` 修改代码
2. `git commit` 提交到本地
3. `git push` 推送到 GitHub (`git@github.com:whalestore/vps-deployment-script.git`)
4. 在 OpenWrt 软路由上 `git pull` 拉取最新代码
5. 部署到对应路径（如 LuCI controller / view / 脚本等）

**绝对禁止**用 `cat file | ssh ... 'cat > /path'` 或 `scp` 直接覆盖软路由上的文件。这种操作：
- 没有版本记录，出问题无法回滚
- 本地和远程代码不一致，无法追踪改了什么
- 多次覆盖后不知道当前运行的是哪个版本

## 软路由文件部署路径

| 本地路径 | 软路由路径 | 备注 |
|---------|-----------|------|
| `openwrt/luci/controller/tiktokproxy/tiktokproxy.lua` | `/usr/lib/lua/luci/controller/tiktokproxy.lua` | 注意: 运行路径是单文件, 不是 `tiktokproxy/` 子目录, `cp` 时需改名 |
| `openwrt/luci/view/tiktokproxy/vps.htm` | `/usr/lib/lua/luci/view/tiktokproxy/vps.htm` | |
| `openwrt/luci/view/tiktokproxy/policies.htm` | `/usr/lib/lua/luci/view/tiktokproxy/policies.htm` | |
| `openwrt/luci/view/themes/argone/header.htm` | `/usr/lib/lua/luci/view/themes/argone/header.htm` | 定制主题 (备用), 侧栏菜单硬编码在 chb_pages 数组里 |
| `openwrt/luci/view/header.htm` | `/usr/lib/lua/luci/view/header.htm` | **实际渲染的侧栏菜单** (LuCI 优先用 view/header.htm 而非 themes/*/header.htm), 新增页面要改这里 |
| `openwrt/luci/view/admin_status/index.htm` | `/usr/lib/lua/luci/view/admin_status/index.htm` | 系统总览页面 (链路状态/测速/流量), 含链路卡片渲染逻辑 |
| `openwrt/scripts/init-subnets.sh` | `/usr/bin/init-subnets.sh` | |
| `openwrt/scripts/_subnet-lib.sh` | `/usr/bin/_subnet-lib.sh` | |
| `openwrt/scripts/subnet-add.sh` | `/usr/bin/subnet-add.sh` | |
| `openwrt/scripts/subnet-del.sh` | `/usr/bin/subnet-del.sh` | |
| `openwrt/scripts/subnet-list.sh` | `/usr/bin/subnet-list.sh` | |
| `openwrt/scripts/subnet-inspect.sh` | `/usr/bin/subnet-inspect.sh` | |
| `openwrt/scripts/generate-config.sh` | `/etc/sing-box/generate-config.sh` | |
| `openwrt/scripts/generate-config.jq` | `/etc/sing-box/generate-config.jq` | |
| `openwrt/scripts/policy-migrate.sh` | `/usr/bin/policy-migrate.sh` | |
| `openwrt/scripts/migrate-chain-policy.sh` | `/usr/bin/migrate-chain-policy.sh` | |
| `openwrt/scripts/vps-db.sh` | `/usr/bin/vps-db.sh` | vps.db 读写工具 (节点/链路/子网/策略 CRUD)。注意: 运行路径是 `/usr/bin/`, 不是 `/etc/sing-box/` |
| `openwrt/scripts/routing-rules.json` | `/etc/sing-box/routing-rules.json` | 升级后自动迁移到 `policies/default.json`, 旧文件改名 `.legacy` |

部署方式：在软路由上 `git pull` 后，用 `cp` 或 `ln -s` 从 git 仓库复制/链接到运行路径。

### LuCI 字节码缓存清除（重要）

**每次部署 controller 后，必须清除 LuCI 字节码缓存，否则新代码不生效：**

```sh
rm -rf /tmp/luci-modulecache/*
rm -f /tmp/luci-indexcache
/etc/init.d/uhttpd restart
```

原因：LuCI 把 controller 编译成字节码缓存在 `/tmp/luci-modulecache/`，文件名是模块名的十六进制（如 `6C756369...` 对应 `luci.controller.tiktokproxy`）。即使源文件改了，LuCI 仍然用旧字节码，导致修改不生效。

## 代码质量要求

- 修改前端/后端代码后，必须验证前后端数据一致性
- 页面展示的数据必须与数据库实际数据对应
- 不得有"页面显示了但数据库没有"的幽灵数据

## sing-box 配置修改红线（强制）

**修改 `generate-config.jq` 的 DNS / route 配置前，必读 [`docs/postmortem-2026-07-23-dns-disaster.md`](docs/postmortem-2026-07-23-dns-disaster.md)。**

该文档记录了 2026-07-23 的 DNS 配置灾难事故：错误修改 DNS detour 导致 sing-box 崩溃、整个子网断联。以下红线不可违反：

1. **`local-dns` (223.5.5.5) 的 `detour` 必须是 `direct`** — 这是 sing-box 启动的基础设施，走链路会导致循环依赖崩溃
2. **不要加全局 `port: 53` 规则** — 会误伤 sing-box 自身 DNS 查询导致崩溃；如需拦截手机 DNS，用 `source_ip_cidr` 限定范围
3. **DNS 走 direct ≠ 流量泄露** — DNS 查询走 CN 直连不影响后续 TCP/UDP 流量走链路
4. **部署前先本地验证** — `jq` 语法通过不等于配置逻辑正确，必须模拟启动场景测试
5. **一次只改一个东西** — 连续改多个配置项会雪崩式故障，无法定位根因
