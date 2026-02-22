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

## License

MIT
