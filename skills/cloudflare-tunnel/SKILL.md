---
name: cloudflare-tunnel
description: "Use when setting up Cloudflare Tunnel (cloudflared) to expose local HTTP/HTTPS services through Cloudflare's edge. Covers token-based and login-based auth, TLS certificate setup for origin servers, systemd service configuration, DNS routing, and troubleshooting (502, 521, 403, cert errors). No open ports or public IP needed."
---
# Cloudflare Tunnel Skill

Expose local HTTP/HTTPS services through Cloudflare's edge using `cloudflared`. No open ports, no public IP needed.

## How It Works

```
User -> https://your.domain.com
  |  DNS CNAME -> <tunnel-id>.cfargotunnel.com
Cloudflare Edge (TLS, DDoS, WAF)
  |  Encrypted QUIC tunnel (4 connections)
cloudflared daemon (local machine)
  |  Forward to origin
Local server (Python/nginx) on localhost:PORT
```

cloudflared opens **outbound-only** QUIC connections to Cloudflare's edge. No inbound firewall rules needed. The edge routes requests from your domain down the tunnel to your local origin server.

## Installation

```bash
# Debian/Ubuntu
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
cloudflared version
```

## Auth Methods

### Token-based (simplest)

1. Create a tunnel in Cloudflare Zero Trust dashboard: **Networks -> Tunnets -> Create a tunnel**
2. Copy the token
3. Run: `cloudflared tunnel run --token <TOKEN>` (defaults to proxying `http://localhost:8080`)
4. Configure public hostnames in the dashboard: **Networks -> Tunnels -> your tunnel -> Public Hostnames**

The dashboard's remote config **overrides** local settings, including `--url` and config.yml ingress rules.

### Login-based (more control)

```bash
cloudflared tunnel login                    # Opens browser to authenticate
cloudflared tunnel create my-tunnel         # Creates tunnel + credentials
cloudflared tunnel route dns my-tunnel demo.example.com  # DNS CNAME
```

Create `/etc/cloudflared/config.yml`:

```yaml
tunnel: <tunnel-uuid>
credentials-file: /root/.cloudflared/<tunnel-uuid>.json
ingress:
  - hostname: demo.example.com
    service: http://localhost:8080
  - hostname: api.example.com
    service: http://localhost:3000
  - service: http_status:404
```

## Local Origin Server

### Option A: Python (quick, no deps)

```bash
# HTTP
python3 -m http.server 8080 --bind 127.0.0.1 --directory /path/to/docs

# HTTPS (self-signed)
cat > server.py << 'EOF'
import http.server, ssl, os
PORT = 8080
DIR = "/path/to/docs"
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw): super().__init__(*a, directory=DIR, **kw)
httpd = http.server.HTTPServer(("127.0.0.1", PORT), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile=os.path.join(DIR, "server.crt"), keyfile=os.path.join(DIR, "server.key"))
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
EOF
python3 server.py
```

### Option B: nginx (production)

```nginx
server {
    listen 127.0.0.1:8080;
    root /var/www/docs;
    index index.html;
}
```

## Systemd Services

### Origin server (`/etc/systemd/system/origin.service`)

```ini
[Unit]
Description=Origin server for Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/path/to/docs
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 127.0.0.1
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

### cloudflared (`/etc/systemd/system/cloudflared.service`)

```ini
[Unit]
Description=cloudflared
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token <TOKEN>
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now origin.service cloudflared.service
```

**Notes:**
- `--config` flag must come **before** `tunnel` subcommand
- `--url http://localhost:PORT` overrides the default origin port (8080)
- Remote dashboard config overrides `--url` if public hostnames are configured there

## TLS for the Origin (When Dashboard Forces HTTPS)

If the Cloudflare dashboard has the origin set to HTTPS, cloudflared validates the origin TLS certificate. Go's TLS (used by cloudflared) requires **Subject Alternative Names (SANs)** and a trusted CA.

```bash
# 1. Create a local CA
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -days 3650 -out ca.crt -subj "/CN=TunnelCA"

# 2. Create a server cert signed by the CA (with SANs)
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=localhost"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1")

# 3. Trust the CA system-wide
sudo cp ca.crt /usr/local/share/ca-certificates/tunnel-ca.crt
sudo update-ca-certificates

# 4. Point your origin server to server.crt / server.key (see Python HTTPS server above)
```

## DNS

- **Token-based:** Cloudflare creates the CNAME automatically when you add a public hostname in the dashboard
- **Login-based:** `cloudflared tunnel route dns <tunnel-name> demo.example.com`
- DNS record: `<hostname> CNAME <tunnel-id>.cfargotunnel.com`

## Verification

```bash
# Local origin
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/         # 200
curl -sk -o /dev/null -w "%{http_code}" https://localhost:8080/       # 200

# Tunnel health
sudo systemctl status cloudflared.service --no-pager | head -5
sudo journalctl -u cloudflared.service --no-pager | grep "Registered tunnel"

# End-to-end
curl -sk -w "%{http_code}" https://demo.example.com/                  # 403 (challenge) or 200

# Check for TLS errors
sudo journalctl -u cloudflared.service --no-pager | grep -i "originService\|certificate" | tail -5
```

## Troubleshooting

| Error | Likely Cause | Fix |
|-------|-------------|-----|
| **502** | Origin unreachable or TLS failure | Check local server + port. Fix TLS cert (SANs + CA trust) |
| **521** | Tunnel disconnected | `systemctl status cloudflared`, check network |
| **403** | Cloudflare WAF challenge | Normal for bots. Open in a real browser |
| `certificate relies on legacy Common Name` | Cert missing SANs | Regenerate with `-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"` |
| `certificate signed by unknown authority` | Self-signed cert not trusted | Add CA to `/usr/local/share/ca-certificates/` + `update-ca-certificates` |
| Local config ignored | Token tunnel uses remote config | Fix TLS cert, or change dashboard origin to HTTP |

## Files in this skill

| File | Purpose |
|------|---------|
| `scripts/setup-tunnel.sh` | Automated setup: installs cloudflared, creates services, generates certs |
| `scripts/verify-tunnel.sh` | Health check: tests origin, tunnel, and public URL |
| `references/troubleshooting.md` | Deep-dive: each error with diagnosis steps |
| `references/architecture.md` | How tunnels work: QUIC, connection pooling, failover |
