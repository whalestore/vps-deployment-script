# sing-box DNS 配置灾难事故复盘

> 日期: 2026-07-23
> 严重度: P0 (网络完全断联, 用户被迫切换网络)
> 影响范围: LAN-eth2 (mmlive) 子网所有设备

## 事故经过

### 起点

用户要求「开启 tiktok-us-double 链路时不希望有任何流量泄露」,包括 DNS。怀疑飞书能收到消息通知是 DNS 泄露导致。

### 错误修复链 (4 个 commit, 每个都导致崩溃)

```
修复1 (commit 27694a0): proxy-dns detour 改为走链路
  -> sing-box 正常, 但发现 local-dns 仍走 direct

修复2 (commit 07e88e6): local-dns detour 也改为走链路
  -> 灾难开始: local-dns (223.5.5.5) 走日本 VPS, DNS 查询超时
  -> sing-box 启动时下载 rule-set 需要解析 cdn.jsdelivr.net
  -> DNS 解析失败 -> rule-set 下载失败 -> sing-box 崩溃 -> TUN 消失
  -> LAN-eth2 整个子网断联

修复3 (commit 028319a): local-dns 改回 direct
  -> sing-box 恢复了, 但手机原始 DNS 查询仍走 direct

修复4 (commit 43e58f6): route.rules 加全局 {port: 53} 规则强制走链路
  -> 灾难升级: port 53 规则拦截了 sing-box 自身 DNS 查询
  -> sing-box 对 223.5.5.5 和 8.8.8.8 的查询都被强制走日本 VPS
  -> 全部 DNS 超时 -> sing-box 再次崩溃 -> TUN 消失 -> 网络断联
  -> 用户被迫切换到 cmcc 网络

最终 (commit 4ba5825): 完全回滚, 恢复正常
```

## 根本问题

### 1. 没有理解 sing-box DNS 模块的工作机制

sing-box 的 DNS 模块 (dns.servers) 是**独立的 DNS 解析器**,它的 `detour` 控制的是 sing-box 内部发出的 DNS 查询走哪个出口。这和**手机原始 DNS 查询被 TUN 捕获后的路由**是两件事。

把两者混为一谈,以为改 DNS 模块的 detour 就能防止手机 DNS 泄露,实际上:
- DNS 模块的 detour 只影响 sing-box 自己的 DNS 查询
- 手机原始 DNS 查询 (到 192.168.1.1:53) 被 TUN 捕获后, 是按 route.rules 路由的

### 2. local-dns 走链路是致命错误

`local-dns` (223.5.5.5) 是阿里 DNS, **从国内直连最快最可靠**。改成走日本 VPS 后:
- 日本 VPS 访问 223.5.5.5 慢或被墙
- sing-box 启动时需要 DNS 解析才能下载 rule-set
- DNS 失败 -> rule-set 失败 -> 初始化失败 -> 崩溃

这是一个**循环依赖**: sing-box 需要 DNS 才能启动, DNS 需要链路才能工作, 链路需要 sing-box 才能建立。把 local-dns 改走链路就打破了这个循环, 导致 sing-box 无法启动。

### 3. 全局 port 53 规则是核弹级误伤

`{port: 53, outbound: chain26-hop1}` 拦截了**所有** 53 端口流量, 包括 sing-box 自身 DNS 模块发出的查询。这等于让 sing-box 的 DNS 解析器无法工作, 直接导致崩溃。

### 4. 没有在部署前充分测试

每次修改都是直接部署到软路由 + 重启 sing-box, 没有先在本地验证配置的可行性。特别是 DNS 这种**启动时就需要工作**的服务, 一旦配置错误就是 sing-box 崩溃 + 网络断联, 没有回退余地。

## 教训

| 教训 | 说明 |
|------|------|
| **不要动 local-dns 的 detour** | local-dns (223.5.5.5) 必须走 direct, 这是 sing-box 启动的基础设施 |
| **不要加全局 port 规则** | port 53 全局规则会误伤 sing-box 自身 DNS, 应该用 source_ip_cidr 限定范围 |
| **DNS 泄露 ≠ 流量泄露** | DNS 走 direct 只意味着 DNS 查询本身走 CN, 不影响后续 TCP/UDP 流量走链路。飞书能收到消息不是 DNS 泄露导致的, 是飞书有海外节点 |
| **部署前先本地验证** | jq 语法通过不等于配置逻辑正确, 应该模拟启动场景测试 |
| **一次只改一个东西** | 连续改了 4 个 commit, 每改一个就崩一次, 雪崩式灾难 |
| **sing-box DNS 是启动依赖** | sing-box 启动时需要 DNS 解析 rule-set 下载地址, DNS 不可用 = sing-box 不可启动 = 整个网络断联 |

## sing-box DNS 架构正确理解

```
手机发 DNS 查询 (到 192.168.1.1:53)
  ↓
TUN 捕获 (source: 172.19.0.1)
  ↓
route.rules 路由 (按 source_ip_cidr 匹配)
  -> 匹配 192.168.7.0/24 -> 走链路 (不走 direct)
  -> 不匹配 -> 走 final (direct) ← 这是泄露点, 但只影响 TUN 自身流量

sing-box DNS 模块 (独立于 route.rules)
  ↓
dns.servers 的 detour 控制
  -> local-dns (223.5.5.5) detour: direct ← 必须走 direct, 启动依赖
  -> proxy-dns (8.8.8.8) detour: direct ← 可改走链路, 但 8.8.8.8 从链路访问可能慢
  ↓
dns.rules 决定用哪个 server
  -> geosite-cn 域名 -> local-dns (direct, 快)
  -> proxy_domain_suffix 域名 -> proxy-dns
  -> 其他 -> final: proxy-dns
```

## 正确的 DNS 防泄露方案 (未实施, 仅供参考)

如果未来需要防 DNS 泄露, 正确方案是:

1. **local-dns 保持 direct** (绝对不能改)
2. **proxy-dns 保持 direct** (8.8.8.8 从国内直连可达, 虽然可能被污染但不影响启动)
3. **在 chain_routing_rules 里加 source_ip_cidr + port 53 规则** (只拦截手机子网的 DNS 查询走链路, 不影响 sing-box 自身)
4. **部署前在本地用 mock 数据验证 sing-box 能正常生成配置 + check 通过**
5. **部署后先观察 30 秒 sing-box 日志, 确认 rule-set 下载成功 + TUN 正常**

## 相关文件

- `openwrt/scripts/generate-config.jq` - sing-box 配置生成 (DNS + route 规则)
- `AGENTS.md` - 开发规则 (引用本文档)
