# Sing-box VPS Deployment Tool

This tool automates the deployment of [Sing-box](https://github.com/SagerNet/sing-box) on multiple VPS servers using the [233boy script](https://github.com/233boy/sing-box). It supports **VLESS-REALITY** and **Hysteria2** protocols, generating a unified **Clash Meta (Mihomo)** subscription link and QR code.

## Features

- **One-click Deployment**: Deploys Sing-box to all servers listed in `servers.json`.
- **Protocol Switching**: Support for `REALITY` (default) and `Hysteria2` via command line arguments.
- **Automatic Configuration**:
  - Installs/Updates Sing-box using the 233boy script.
  - Configures the selected protocol on port 443.
  - Cleans up legacy services (Hysteria2, Nginx) to prevent port conflicts.
- **Subscription Management**:
  - Generates a `clash_meta_config.yaml` compatible with Clash Meta.
  - Uploads the configuration to the first server for easy subscription.
  - Provides a subscription URL and QR code.

## Prerequisites

- Python 3.8+
- SSH access to your VPS servers (root or sudo user).
- `pip` installed.

## Setup

1. **Clone the repository**:
   ```bash
   git clone <repo-url>
   cd <repo-folder>
   ```

2. **Create Virtual Environment**:
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   pip install paramiko pyyaml qrcode[pil]
   ```

3. **Configure Servers**:
   Edit `servers.json` with your server details:
   ```json
   [
       {
           "alias": "Server-1-US",
           "ip": "1.2.3.4",
           "user": "root",
           "password": "your_password",
           "ssh_port": 22
       },
       ...
   ]
   ```

## Usage

### Deploy with REALITY (Default)
Run the script to deploy VLESS-REALITY protocol:
```bash
./venv/bin/python deploy_singbox.py
```
Or explicitly:
```bash
./venv/bin/python deploy_singbox.py --protocol reality
```

### Deploy with Hysteria2
Run the script to deploy Hysteria2 protocol:
```bash
./venv/bin/python deploy_singbox.py --protocol hysteria2
```

## Output

After running the script, you will get:
1. **Subscription URL**: `http://<First-Server-IP>/subscribe.yaml` (Import this into Clash Meta)
2. **QR Code**: `subscription_qr.png` (Scan with supported mobile apps)
3. **Raw Links**: Displayed in the terminal and saved to `subscriptions.txt`.

## 子网管理

子网的**网络层操作**(创建/删除)会断网, 只能通过 SSH 脚本执行, 不能在网页操作。
网页只负责展示子网状态 + 绑定/解绑链路(不会断网)。

### 脚本一览

部署到软路由 `/usr/bin/` 下, 本地源码在 `openwrt/scripts/`。

| 脚本 | 功能 | 会断网 |
|------|------|--------|
| `init-subnets.sh` | 批量初始化所有 LAN 口 / 回滚 | 是 |
| `subnet-add.sh <iface>` | 单个口拆出子网 | 是 |
| `subnet-del.sh <iface\|id>` | 删子网, 网口还回 br-lan | 是 |
| `subnet-list.sh` | 列出所有子网 | 否 |
| `subnet-inspect.sh <iface\|id>` | 查看单个子网详情 | 否 |

所有写操作共享 `_subnet-lib.sh` 库, 提供物理网口发现/CIDR 分配/UCI 操作/最后成员保护等公共函数。

### 典型流程

1. **系统初始化** (一次性):
   ```sh
   init-subnets.sh --dry-run        # 审核将要做什么
   init-subnets.sh --test eth0      # 单口测试
   init-subnets.sh                  # 全量执行
   ```
   执行完会打印所有可访问的 LuCI URL (如 `http://192.168.6.1/cgi-bin/luci`)。

2. **后期新增子网** (远程 SSH):
   ```sh
   subnet-add.sh eth3 --dry-run     # 预演
   subnet-add.sh eth3               # 执行
   ```

3. **后期删除子网** (远程 SSH):
   ```sh
   subnet-del.sh eth0 --dry-run     # 预演
   subnet-del.sh eth0               # 执行
   ```

4. **查看状态**:
   ```sh
   subnet-list.sh                   # 列出所有
   subnet-inspect.sh eth0           # 查看详情 (含 DHCP 租约/ARP)
   ```

### 安全机制

- 所有写操作支持 `--dry-run` 预演
- `init-subnets.sh --rollback` 一键回滚所有子网
- **br-lan 拆光时会警告但不阻止** (拆光后 br-lan IP 失联, 通过子网网关 IP 管理)
- 执行前自动备份 UCI 配置到 `/tmp/network.bak.<timestamp>`
- 写操作顺序: UCI 成功 -> vps.db (保证一致性)
- `init-subnets.sh` 执行完打印所有可访问的 LuCI URL, 防止拆光后找不到管理入口

### 设计原则

- **脚本是子网网络层操作的唯一真相源**: 创建/删除/批量初始化都走脚本
- **网页只读 + 换绑**: 展示子网状态、绑定/解绑链路(不会断网)在网页做
- **批量初始化只在系统初始化时跑一次**, 后期通过 SSH 单个增删

## License

MIT
