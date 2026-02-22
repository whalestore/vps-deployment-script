import json
import paramiko
import os
import time
import sys
import yaml
import qrcode
import argparse
from urllib.parse import urlparse, parse_qs, unquote

# Configuration
SERVERS_FILE = 'servers.json'
SUBS_FILE = 'subscriptions.txt'
CLASH_CONFIG_FILE = 'clash_meta_config.yaml'
REMOTE_SUB_PATH = '/var/www/html/subscribe.yaml'

# Protocol mappings for 'sb' command
PROTOCOL_MAP = {
    'reality': 'reality',
    'hysteria2': 'hy2',
    'hy2': 'hy2',
    'vmess-ws': 'ws',
    'vmess-tcp': 'tcp'
}

def connect_with_retry(ip, user, password, port=22, retries=3, delay=5):
    """Establishes an SSH connection with retry logic."""
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
                return None
    return None

def run_remote_command(ssh, command, timeout=300):
    """Runs a remote command and returns exit status, stdout, stderr."""
    stdin, stdout, stderr = ssh.exec_command(command, timeout=timeout)
    exit_status = stdout.channel.recv_exit_status()
    return exit_status, stdout.read().decode().strip(), stderr.read().decode().strip()

def cleanup_legacy_services(ssh, ip):
    """Stops legacy services (Hysteria2) but ensures Nginx is available for subscription hosting."""
    print(f"    [+] Cleaning up legacy services on {ip}...")
    
    # Stop and disable Hysteria2
    run_remote_command(ssh, "systemctl stop hysteria-server && systemctl disable hysteria-server")
    
    # We want Nginx for subscription hosting, so we don't disable it blindly.
    # Instead, we check if it's running on port 80. If it is, great.
    # If not, we might need it later. For now, just ensure port 443 is free.
    
    # Kill any process on port 443 just in case
    # run_remote_command(ssh, "fuser -k 443/tcp || true")
    # run_remote_command(ssh, "fuser -k 443/udp || true")

def ensure_nginx(ssh, ip):
    """Ensures Nginx is installed and running on port 80 to serve subscription file."""
    print(f"    [+] Ensuring Nginx is running on {ip}...")
    status, out, err = run_remote_command(ssh, "which nginx")
    if status != 0:
        print(f"    [+] Installing Nginx on {ip}...")
        run_remote_command(ssh, "apt-get update && apt-get install -y nginx", timeout=300)
    
    run_remote_command(ssh, "systemctl start nginx && systemctl enable nginx")
    run_remote_command(ssh, "mkdir -p /var/www/html")
    # Open port 80 if ufw is active
    run_remote_command(ssh, "ufw allow 80/tcp || true")
    return True

def parse_link(link, alias, protocol_type):
    """Parses a link (vless:// or hysteria2://) into a Clash Meta proxy dictionary."""
    try:
        parsed = urlparse(link)
        
        # VLESS-REALITY
        if parsed.scheme == 'vless':
            uuid = parsed.username
            ip = parsed.hostname
            port = parsed.port
            params = parse_qs(parsed.query)
            
            proxy = {
                "name": alias,
                "type": "vless",
                "server": ip,
                "port": port,
                "uuid": uuid,
                "network": params.get('type', ['tcp'])[0],
                "tls": True,
                "udp": True,
                "flow": params.get('flow', ['xtls-rprx-vision'])[0],
                "servername": params.get('sni', [''])[0],
                "reality-opts": {
                    "public-key": params.get('pbk', [''])[0],
                    "short-id": params.get('sid', [''])[0] if 'sid' in params else '',
                },
                "client-fingerprint": params.get('fp', ['chrome'])[0]
            }
            return proxy
            
        # Hysteria2
        elif parsed.scheme == 'hysteria2' or parsed.scheme == 'hy2':
            # Format: hysteria2://password@host:port?params#name
            password = parsed.username
            ip = parsed.hostname
            port = parsed.port
            params = parse_qs(parsed.query)
            
            proxy = {
                "name": alias,
                "type": "hysteria2",
                "server": ip,
                "port": port,
                "password": password,
                "sni": params.get('sni', [''])[0],
                "skip-cert-verify": params.get('insecure', ['0'])[0] == '1',
                "udp": True,
                "obfs": params.get('obfs', ['salamander'])[0],
                "obfs-password": params.get('obfs-password', [''])[0]
            }
            return proxy
            
        return None
    except Exception as e:
        print(f"Error parsing link {link}: {e}")
        return None

def generate_clash_config(links, servers, protocol_type):
    """Generates a Clash Meta compatible YAML config."""
    proxies = []
    proxy_names = []
    
    for link in links:
        # Link format in list is "alias: link"
        parts = link.split(": ", 1)
        if len(parts) != 2:
            continue
        alias = parts[0]
        url = parts[1]
        
        proxy = parse_link(url, alias, protocol_type)
        if proxy:
            proxies.append(proxy)
            proxy_names.append(proxy['name'])
            
    config = {
        "port": 7890,
        "socks-port": 7891,
        "allow-lan": True,
        "mode": "Rule",
        "log-level": "info",
        "external-controller": "127.0.0.1:9090",
        "dns": {
            "enable": True,
            "listen": "0.0.0.0:53",
            "ipv6": False,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "nameserver": ["8.8.8.8", "1.1.1.1", "https://dns.google/dns-query"]
        },
        "proxies": proxies,
        "proxy-groups": [
            {
                "name": "🚀 节点选择",
                "type": "select",
                "proxies": ["♻️ 自动选择"] + proxy_names
            },
            {
                "name": "♻️ 自动选择",
                "type": "url-test",
                "url": "http://www.gstatic.com/generate_204",
                "interval": 300,
                "tolerance": 50,
                "proxies": proxy_names
            },
             {
                "name": "🌍 国外媒体",
                "type": "select",
                "proxies": ["🚀 节点选择"]
            },
            {
                "name": "🐟 漏网之鱼",
                "type": "select",
                "proxies": ["🚀 节点选择", "DIRECT"]
            }
        ],
        "rules": [
            "DOMAIN-SUFFIX,google.com,🚀 节点选择",
            "DOMAIN-KEYWORD,google,🚀 节点选择",
            "DOMAIN,google.com,🚀 节点选择",
            "DOMAIN-SUFFIX,github.com,🚀 节点选择",
            "DOMAIN-SUFFIX,twitter.com,🚀 节点选择",
            "DOMAIN-SUFFIX,youtube.com,🚀 节点选择",
            "DOMAIN-SUFFIX,facebook.com,🚀 节点选择",
            "DOMAIN-SUFFIX,instagram.com,🚀 节点选择",
            "DOMAIN-SUFFIX,netflix.com,🌍 国外媒体",
            "GEOIP,CN,DIRECT",
            "MATCH,🐟 漏网之鱼"
        ]
    }
    
    with open(CLASH_CONFIG_FILE, 'w', encoding='utf-8') as f:
        yaml.dump(config, f, allow_unicode=True, sort_keys=False)
    print(f"\n[+] Generated Clash Meta config: {CLASH_CONFIG_FILE}")
    return CLASH_CONFIG_FILE

def upload_subscription(servers, config_file):
    """Uploads the config file to the first server to serve as subscription."""
    if not servers:
        return None
        
    server = servers[0] # Use the first server
    ip = server['ip']
    print(f"[*] Uploading subscription file to {server['alias']} ({ip})...")
    
    ssh = connect_with_retry(ip, server['user'], server['password'], server.get('ssh_port', 22))
    if not ssh:
        print(f"    [ERROR] Could not connect to {ip} to upload subscription.")
        return None
        
    try:
        ensure_nginx(ssh, ip)
        
        sftp = ssh.open_sftp()
        sftp.put(config_file, REMOTE_SUB_PATH)
        sftp.close()
        
        # Set permissions
        run_remote_command(ssh, f"chmod 644 {REMOTE_SUB_PATH}")
        
        url = f"http://{ip}/subscribe.yaml"
        print(f"    [SUCCESS] Subscription URL: {url}")
        
        # Generate QR code
        qr = qrcode.QRCode()
        qr.add_data(url)
        qr.make()
        qr_file = "subscription_qr.png"
        img = qr.make_image()
        img.save(qr_file)
        print(f"    [SUCCESS] QR Code saved to {qr_file}")
        
        return url
    except Exception as e:
        print(f"    [ERROR] Upload failed: {e}")
        return None
    finally:
        ssh.close()

def install_singbox(ssh, ip):
    """Installs sing-box using the 233boy script."""
    print(f"    [+] Checking for existing installation on {ip}...")
    status, out, err = run_remote_command(ssh, "command -v sb")
    
    if status == 0:
        print(f"    [+] Sing-box already installed on {ip}.")
        return True

    print(f"    [+] Installing Sing-box on {ip}...")
    # Installation command from 233boy documentation
    # We pipe 'yes' to handle any confirmation prompts during installation
    # and use DEBIAN_FRONTEND=noninteractive for apt/dpkg
    # Also set TERM=xterm to avoid "TERM environment variable not set" errors
    install_cmd = "export TERM=xterm; export DEBIAN_FRONTEND=noninteractive; yes | bash <(wget -qO- -o- https://github.com/233boy/sing-box/raw/main/install.sh)"
    
    # Run the installation
    status, out, err = run_remote_command(ssh, install_cmd, timeout=600)
    
    if status == 0:
        print(f"    [SUCCESS] Sing-box installed on {ip}.")
        return True
    else:
        print(f"    [ERROR] Installation failed on {ip}: {err}")
        return False

def configure_protocol(ssh, ip, protocol):
    """Configures the specified protocol."""
    sb_proto = PROTOCOL_MAP.get(protocol, protocol)
    print(f"    [+] Configuring {protocol.upper()} on {ip}...")
    
    # Check if protocol is already configured
    # sb info lists configured protocols
    status, out, err = run_remote_command(ssh, "sb info")
    
    # Simple heuristic to check if protocol exists in output
    # The output of sb info usually lists protocols like "1. VLESS-REALITY-TCP" or "2. Hysteria2"
    if status == 0 and protocol.upper() in out.upper():
        print(f"    [+] {protocol.upper()} configuration found on {ip}.")
        
        # Enforce port 443
        cmd_port = f"sb change {sb_proto} port 443"
        s, o, e = run_remote_command(ssh, cmd_port)
        if s != 0:
             # Port change might fail if already 443 or specific error, just warn
             # print(f"    [WARNING] Failed to set port 443: {e}")
             pass
    else:
        print(f"    [+] Adding {protocol.upper()} configuration...")
        # Add protocol with default settings but force port 443
        # For REALITY/TLS, we need a domain. For others, auto might work.
        
        if sb_proto == 'reality':
            cmd = "sb add reality 443 auto www.microsoft.com"
        elif sb_proto == 'hy2':
            cmd = "sb add hy2 443"
        else:
            # Generic fallback
            cmd = f"sb add {sb_proto} 443"
            
        status, out, err = run_remote_command(ssh, cmd)
        if status != 0:
            print(f"    [ERROR] Failed to add {protocol}: {err}")
            return False
            
    return True

def get_subscription_link(ssh, ip, protocol):
    """Retrieves the link for the specified protocol."""
    sb_proto = PROTOCOL_MAP.get(protocol, protocol)
    print(f"    [+] Retrieving subscription link for {protocol} from {ip}...")
    
    cmd = f"sb url {sb_proto}"
    status, out, err = run_remote_command(ssh, cmd)
    
    if status == 0:
        # Strip ANSI codes first
        clean_out = strip_ansi_codes(out)
        
        lines = clean_out.split('\n')
        for line in lines:
            if "://" in line:
                return line.strip()
        
        # Fallback regex
        import re
        match = re.search(r'[a-z0-9]+://[a-zA-Z0-9@.:?=&%#_-]+', clean_out)
        if match:
            return match.group(0)
    
    print(f"    [ERROR] Could not retrieve link from {ip}: {err}")
    return None

def main():
    parser = argparse.ArgumentParser(description='Deploy Sing-box to VPS servers.')
    parser.add_argument('--protocol', type=str, default='reality', 
                        choices=['reality', 'hysteria2', 'hy2'],
                        help='Protocol to deploy (default: reality)')
    args = parser.parse_args()
    protocol = args.protocol
    
    if not os.path.exists(SERVERS_FILE):
        print(f"Error: {SERVERS_FILE} not found!")
        return

    with open(SERVERS_FILE, 'r') as f:
        servers = json.load(f)

    all_links = []
    
    print(f"[*] Starting deployment of {protocol.upper()} on {len(servers)} servers...")
    
    for server in servers:
        ip = server['ip']
        user = server['user']
        password = server['password']
        alias = server['alias']
        port = server.get('ssh_port', 22)
        
        print(f"\n[*] Processing {alias} ({ip})...")
        
        ssh = connect_with_retry(ip, user, password, port)
        if not ssh:
            print(f"    [ERROR] Failed to connect to {ip}")
            continue
            
        cleanup_legacy_services(ssh, ip)

        if install_singbox(ssh, ip):
            if configure_protocol(ssh, ip, protocol):
                link = get_subscription_link(ssh, ip, protocol)
                if link:
                    all_links.append(f"{alias}: {link}")
                    print(f"    [SUCCESS] Link retrieved for {alias}")
                else:
                    print(f"    [WARNING] No link retrieved for {alias}")
        
        ssh.close()
        
    if all_links:
        with open(SUBS_FILE, 'w') as f:
            f.write('\n'.join(all_links))
        print(f"\n[DONE] Deployment complete. Links saved to {SUBS_FILE}")
        
        # Generate Clash Config
        config_file = generate_clash_config(all_links, servers, protocol)
        
        # Upload Subscription
        sub_url = upload_subscription(servers, config_file)
        
        print("-" * 40)
        if sub_url:
            print(f"Subscription URL: {sub_url}")
        print("-" * 40)
        for link in all_links:
            print(link)
        print("-" * 40)
    else:
        print("\n[!] No links were retrieved.")

if __name__ == "__main__":
    main()
