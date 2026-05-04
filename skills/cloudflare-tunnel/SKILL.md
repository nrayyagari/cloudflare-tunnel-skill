---
name: cloudflare-tunnel
description: Set up, configure, and troubleshoot Cloudflare Tunnels (cloudflared) to expose local services through Cloudflare's edge. Use when the user says they want to expose a local web server, create a tunnel, access a dev environment behind NAT, or fix tunnel errors like 502/521.
license: MIT
---

# Cloudflare Tunnel Skill

Expose local HTTP/HTTPS services through Cloudflare's edge using `cloudflared`. No open ports, no public IP.

## How It Works

```
User → https://your.domain.com
  ↓ DNS CNAME → <tunnel-id>.cfargotunnel.com
Cloudflare Edge (TLS termination, DDoS protection, WAF)
  ↓ Encrypted QUIC tunnel (4 connections per default)
cloudflared daemon (local)
  ↓ Forward to origin (HTTP or HTTPS)
Local server (Python/nginx/Caddy) on localhost:PORT
```

`cloudflared` opens outbound QUIC connections to Cloudflare's edge. No inbound firewall rules needed. The edge routes requests from your domain down the tunnel to your local origin server.

## Workflow

### 1. Install cloudflared

```bash
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb
cloudflared version
```

For other platforms, see [official docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/install-and-setup/installation).

### 2. Choose auth method

**Token-based** (simplest, config managed in Zero Trust dashboard):
- Create a tunnel in Cloudflare Zero Trust dashboard (Networks → Tunnels → Create)
- Copy the token
- Run: `cloudflared tunnel run --token <TOKEN>`
- Configure public hostnames in the dashboard (Networks → Tunnels → your tunnel → Public Hostnames)

**Login-based** (more control, local config.yml):
```bash
cloudflared tunnel login          # Opens browser to authenticate your domain
cloudflared tunnel create my-tunnel  # Creates tunnel, outputs UUID + credentials
cloudflared tunnel route dns my-tunnel demo.example.com  # DNS CNAME
```

### 3. Set up the origin server

**Quick — Python http.server:**
```bash
python3 -m http.server 8080 --bind 127.0.0.1 --directory /path/to/docs
```

**Production — nginx:**
```nginx
server {
    listen 127.0.0.1:8080;
    root /var/www/docs;
    index index.html;
}
```

### 4. Configure tunnel routing

**Token-based:** The remote config from the dashboard takes precedence. Local config.yml is ignored for ingress rules. To override TLS behavior, use `originRequest` in config.yml (rarely needed for HTTP origins).

**Login-based:** Create `/etc/cloudflared/config.yml`:
```yaml
tunnel: <tunnel-uuid>
credentials-file: /root/.cloudflared/<tunnel-uuid>.json
ingress:
  - hostname: demo.example.com
    service: http://localhost:8080
  - service: http_status:404
```

### 5. Systemd services for persistence

**Origin server** (`/etc/systemd/system/origin.service`):
```ini
[Unit]
Description=Origin server
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

**cloudflared** (`/etc/systemd/system/cloudflared.service`):
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

> `--config` flag must come **before** `tunnel` subcommand. `--url` overrides the default origin port (`http://localhost:8080`).

### 6. TLS for the origin

If the remote dashboard config or config.yml specifies `service: https://localhost:PORT`, you need a valid TLS handshake between cloudflared and your origin.

**Self-signed cert with SANs (required by Go TLS):**

```bash
# 1. Create a local CA
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -days 3650 -out ca.crt -subj "/CN=TunnelCA"

# 2. Create server cert signed by the CA
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=localhost"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1")

# 3. Trust the CA system-wide so cloudflared accepts the cert
sudo cp ca.crt /usr/local/share/ca-certificates/tunnel-ca.crt
sudo update-ca-certificates

# 4. Use the cert in your origin server (Python example)
cat > server.py << 'EOF'
import http.server, ssl, os
PORT = 8080; DIR = "/path/to/docs"
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw): super().__init__(*a, directory=DIR, **kw)
httpd = http.server.HTTPServer(("127.0.0.1", PORT), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(certfile=os.path.join(DIR, "server.crt"), keyfile=os.path.join(DIR, "server.key"))
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
EOF
```

### 7. Verification

```bash
# Local origin
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/        # → 200
curl -sk -o /dev/null -w "%{http_code}" https://localhost:8080/       # → 200

# Tunnel health
sudo systemctl status cloudflared.service --no-pager | head -5
sudo journalctl -u cloudflared.service --no-pager | grep "Registered tunnel"

# End-to-end (replaces localhost with public URL)
curl -sk -w "%{http_code}" https://demo.example.com/                  # → 403 (challenge) or 200

# Check for origin errors
sudo journalctl -u cloudflared.service --no-pager | grep -i "originService\|certificate" | tail -5
```

## Troubleshooting Quick Reference

| Error | Cause | Fix |
|-------|-------|-----|
| **502 Bad Gateway** | Origin unreachable or TLS cert failure | Check origin is running on the right port. See TLS section above |
| **521 Web Server Down** | Tunnel disconnected | `systemctl status cloudflared` — check network |
| **403 Forbidden** | Cloudflare WAF challenge | Normal for bots. Open in a real browser |
| `certificate relies on legacy Common Name` | Cert missing SANs | Regenerate with `-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"` |
| `certificate signed by unknown authority` | Self-signed cert not trusted | Add CA to `/usr/local/share/ca-certificates/` + `update-ca-certificates` |
| Remote config overrides `--url` / config.yml | Token tunnel pulls config from dashboard | Trust the self-signed cert system-wide, or change origin to HTTP in dashboard |

## References (load on demand)

- `scripts/setup-tunnel.sh` — Automated setup: installs cloudflared, creates service, generates certs
- `scripts/verify-tunnel.sh` — Health check: tests local origin, tunnel status, and public URL
- `references/troubleshooting.md` — Deep dive: each error with diagnosis steps and resolution
- `references/architecture.md` — How tunnels work: QUIC connections, connection pooling, failover
