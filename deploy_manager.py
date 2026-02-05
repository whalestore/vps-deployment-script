import json
import paramiko
import os
import random
import string
import time
import yaml
import sys

# 配置
SERVERS_FILE = 'servers.json'
SUBS_FILE = 'subscriptions.txt'
AGGREGATED_CONFIG = 'nodes.yml'  # 统一使用 .yml
HY_BIN = '/usr/local/bin/hysteria'
HY_CONFIG = '/etc/hysteria/config.yaml'

# 统一凭据
AUTH_PASS = "ZAS1OXIaSsS0XV5M"
OBFS_PASS = "HN1CSlnV7WWpvQGJ"

def run_remote_command(ssh, command, timeout=120):
    stdin, stdout, stderr = ssh.exec_command(command, timeout=timeout)
    exit_status = stdout.channel.recv_exit_status()
    return exit_status, stdout.read().decode().strip(), stderr.read().decode().strip()

def connect_with_retry(ip, user, password, port=22, retries=5, delay=5):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    for i in range(retries):
        try:
            ssh.connect(ip, username=user, password=password, port=port, timeout=20, banner_timeout=60)
            return ssh
        except Exception as e:
            print(f"    [!] Connection attempt {i+1} failed for {ip}: {str(e)}")
            if i < retries - 1:
                time.sleep(delay)
            else:
                raise e
    return None

def deploy_node(server):
    ip = server['ip']
    user = server['user']
    password = server['password']
    alias = server['alias']
    ssh_port = server.get('ssh_port', 22)

    print(f"[*] Processing {alias} ({ip})...")
    
    try:
        ssh = connect_with_retry(ip, user, password, ssh_port)
        
        # 1. 开放防火墙 (443 UDP/TCP, 80 TCP, ICMP)
        print(f"    [+] Configuring firewall on {ip}...")
        firewall_cmds = [
            "ufw allow 443/udp",
            "ufw allow 443/tcp",
            "ufw allow 80/tcp",
            "iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT || true"
        ]
        for cmd in firewall_cmds:
            run_remote_command(ssh, cmd)
        
        # 2. 幂等性安装 Hysteria 2
        status, out, err = run_remote_command(ssh, f"test -f {HY_BIN} && echo 'EXISTS'")
        if out != 'EXISTS':
            print(f"    [+] Installing Hysteria 2 on {ip}...")
            run_remote_command(ssh, "export TERM=xterm; curl -fsSL https://github.com/missuo/Hysteria2/raw/main/hy2.sh | bash -s -- 1", timeout=300)
            run_remote_command(ssh, "openssl req -x509 -nodes -newkey rsa:2048 -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt -subj '/CN=www.bing.com' -days 3650")
            run_remote_command(ssh, "chown -R hysteria:hysteria /etc/hysteria && chmod 600 /etc/hysteria/server.key")

        # 3. 强制刷入统一配置
        config = f'''listen: :443
udpIdleTimeout: 60s
tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: "{AUTH_PASS}"
obfs:
  type: salamander
  salamander:
    password: "{OBFS_PASS}"
quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnectionReceiveWindow: 20971520
  maxConnectionReceiveWindow: 20971520
  maxIdleTimeout: 30s
  keepAlive: true
ignoreClientBandwidth: false
bandwidth:
  up: 100 mbps
  down: 200 mbps
'''
        run_remote_command(ssh, f"echo '{config}' > {HY_CONFIG}")
        run_remote_command(ssh, "systemctl restart hysteria-server && systemctl enable hysteria-server")

        # 4. 确保 Nginx 运行 (用于分发 nodes.yml)
        status, out, err = run_remote_command(ssh, "which nginx || echo 'MISSING'")
        if out == 'MISSING':
            print(f"    [+] Installing Nginx on {ip}...")
            run_remote_command(ssh, "apt-get update && apt-get install -y nginx", timeout=300)
            run_remote_command(ssh, "mkdir -p /var/www/html")

        ssh.close()
        print(f"    [SUCCESS] {ip} deployed.")
        return True
    except Exception as e:
        print(f"    [ERROR] Failed to deploy {ip}: {str(e)}")
        return False

def generate_clash_config(servers):
    proxies = []
    for s in servers:
        proxies.append({
            "name": s['alias'],
            "type": "hysteria2",
            "server": s['ip'],
            "port": 443,
            "password": AUTH_PASS,
            "obfs": "salamander",
            "obfs-password": OBFS_PASS,
            "sni": "www.bing.com",
            "skip-cert-verify": True,
            "insecure": True,
            "up": "100",
            "down": "200"
        })
    
    config = {
        "port": 7890,
        "socks-port": 7891,
        "allow-lan": True,
        "mode": "Rule",
        "log-level": "info",
        "dns": {
            "enable": True,
            "enhanced-mode": "fake-ip",
            "nameserver": ["8.8.8.8", "1.1.1.1", "119.29.29.29"]
        },
        "proxies": proxies,
        "proxy-groups": [
            {
                "name": "🚀 自动选择",
                "type": "url-test",
                "proxies": [s['alias'] for s in servers],
                "url": "http://www.gstatic.com/generate_204",
                "interval": 300
            },
            {
                "name": "🔰 节点选择",
                "type": "select",
                "proxies": ["🚀 自动选择"] + [s['alias'] for s in servers] + ["DIRECT"]
            }
        ],
        "rules": [
            "DOMAIN-SUFFIX,google.com,🔰 节点选择",
            "GEOIP,CN,DIRECT",
            "MATCH,🔰 节点选择"
        ]
    }
    
    with open(AGGREGATED_CONFIG, 'w', encoding='utf-8') as f:
        yaml.dump(config, f, allow_unicode=True, sort_keys=False)
    print(f"\n[+] Local {AGGREGATED_CONFIG} generated.")

def upload_and_generate_qr(servers):
    if not servers: return
    
    # 1. 上传配置
    print("\n[*] Syncing config to all nodes...")
    for s in servers:
        try:
            ssh = connect_with_retry(s['ip'], s['user'], s['password'], s.get('ssh_port', 22))
            sftp = ssh.open_sftp()
            sftp.put(AGGREGATED_CONFIG, f'/var/www/html/{AGGREGATED_CONFIG}')
            sftp.close()
            ssh.close()
            print(f"    [SUCCESS] {AGGREGATED_CONFIG} uploaded to {s['ip']}")
        except Exception as e:
            print(f"    [ERROR] Failed to upload to {s['ip']}: {str(e)}")

    # 2. 本地生成二维码 (始终基于第一台可用服务器 IP)
    try:
        import qrcode
        sub_link = f"http://{servers[0]['ip']}/{AGGREGATED_CONFIG}"
        qr_file = "final_sub_qr.png"
        img = qrcode.make(sub_link)
        img.save(qr_file)
        print(f"\n[+] New QR Code generated: {qr_file}")
        print(f"[+] Unified Subscription Link: {sub_link}")
    except ImportError:
        print("\n[!] qrcode library not found, skipping QR generation.")

def main():
    if not os.path.exists(SERVERS_FILE):
        print(f"Error: {SERVERS_FILE} not found!")
        return

    with open(SERVERS_FILE, 'r') as f:
        servers = json.load(f)

    successful_servers = []
    for server in servers:
        if deploy_node(server):
            successful_servers.append(server)

    if successful_servers:
        generate_clash_config(successful_servers)
        upload_and_generate_qr(successful_servers)
        print(f"\n[DONE] All nodes processed successfully.")

if __name__ == "__main__":
    main()
