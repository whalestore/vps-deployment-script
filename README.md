# VPS 节点部署管理器

一键部署 Hysteria 2 代理节点并生成 Clash 订阅配置的工具。

## 功能特性

- 🚀 自动部署 Hysteria 2 到多台服务器
- 🔧 自动配置防火墙、SSL 证书、Nginx
- 📦 生成 Clash 订阅配置文件 (`nodes.yml`)
- 🔄 自动同步配置到所有节点
- 📱 生成订阅链接二维码

## 环境要求

- Python 3.8+
- pip

## 安装

1. **克隆项目**

```bash
git clone <repository-url>
cd vps
```

2. **创建虚拟环境**

```bash
python3 -m venv venv
source venv/bin/activate  # Linux/macOS
# 或 Windows: venv\Scripts\activate
```

3. **安装依赖**

```bash
pip install paramiko pyyaml qrcode[pil]
```

## 配置

1. **复制示例配置文件**

```bash
cp servers_example.json servers.json
```

2. **编辑 `servers.json`**

配置你的服务器信息：

```json
[
    {
        "alias": "服务器别名-地区",
        "ip": "服务器IP地址",
        "user": "root",
        "password": "SSH密码",
        "ssh_port": 22
    }
]
```

| 字段 | 说明 |
|------|------|
| `alias` | 节点别名，会显示在 Clash 客户端中 |
| `ip` | 服务器 IP 地址 |
| `user` | SSH 用户名（通常为 root） |
| `password` | SSH 密码 |
| `ssh_port` | SSH 端口（默认 22） |

## 使用

运行部署脚本：

```bash
python deploy_manager.py
```

脚本将自动：
1. 连接到每台服务器
2. 配置防火墙规则
3. 安装并配置 Hysteria 2
4. 安装 Nginx
5. 生成 `nodes.yml` 配置文件
6. 上传配置到所有节点
7. 生成订阅二维码

## 输出文件

| 文件 | 说明 |
|------|------|
| `nodes.yml` | Clash 订阅配置文件 |
| `final_sub_qr.png` | 订阅链接二维码 |

## 客户端使用

部署完成后，使用以下方式导入订阅：

1. **订阅链接**: `http://<第一台服务器IP>/nodes.yml`
2. **扫描二维码**: 使用 Clash 客户端扫描 `final_sub_qr.png`

支持的客户端：
- Clash for Windows
- ClashX (macOS)
- Clash for Android
- Stash (iOS)

## 新增节点

1. 编辑 `servers.json`，添加新服务器信息
2. 重新运行 `python deploy_manager.py`
3. 脚本会自动部署新节点并更新订阅配置

## 许可证

MIT License
