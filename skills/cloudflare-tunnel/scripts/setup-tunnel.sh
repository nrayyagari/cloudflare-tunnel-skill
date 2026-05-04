#!/usr/bin/env bash
# setup-tunnel.sh — Install cloudflared and set up a basic tunnel
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Usage: sudo $0 [--token TOKEN] [--port PORT] [--dir DIR]"
  echo "  --token TOKEN  Cloudflare tunnel token (required for token-based auth)"
  echo "  --port  PORT   Local origin port (default: 8080)"
  echo "  --dir    DIR   Directory to serve (default: /var/www/tunnel)"
  exit 1
fi

TOKEN="${TOKEN:-}"
PORT="${PORT:-8080}"
DIR="${DIR:-/var/www/tunnel}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --port)  PORT="$2";  shift 2 ;;
    --dir)   DIR="$2";   shift 2 ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

echo "==> Installing cloudflared..."
if ! command -v cloudflared &>/dev/null; then
  curl -sL https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -o /tmp/cloudflared.deb
  dpkg -i /tmp/cloudflared.deb
fi
echo "cloudflared $(cloudflared version)"

echo "==> Creating serve directory: $DIR"
mkdir -p "$DIR"
echo "<h1>It works!</h1>" > "$DIR/index.html"

echo "==> Setting up origin server service..."
cat > /etc/systemd/system/origin.service <<UNIT
[Unit]
Description=Origin server for Cloudflare Tunnel
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=$DIR
ExecStart=/usr/bin/python3 -m http.server $PORT --bind 127.0.0.1
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now origin.service
echo "   origin.service active on port $PORT"

if [[ -n "$TOKEN" ]]; then
  echo "==> Setting up cloudflared service (token-based)..."
  cat > /etc/systemd/system/cloudflared.service <<UNIT
[Unit]
Description=cloudflared
After=network-online.target
Wants=network-online.target

[Service]
TimeoutStartSec=15
Type=notify
ExecStart=/usr/bin/cloudflared --no-autoupdate tunnel run --token $TOKEN
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now cloudflared.service
  echo "   cloudflared.service active (token-based)"
  echo ""
  echo "Next: Configure public hostname in Cloudflare Zero Trust dashboard:"
  echo "  Networks -> Tunnels -> your-tunnel -> Public Hostnames"
  echo "  Service: http://localhost:$PORT"
else
  echo ""
  echo "No --token provided. Run 'cloudflared tunnel login' then:"
  echo "  cloudflared tunnel create my-tunnel"
  echo "  cloudflared tunnel route dns my-tunnel demo.example.com"
  echo "  vim /etc/cloudflared/config.yml   # Add ingress rules"
  echo "  systemctl enable --now cloudflared"
fi

echo ""
echo "==> Done. Verify with:"
echo "  curl -s -o /dev/null -w '%{http_code}' http://localhost:$PORT/"
echo "  systemctl status cloudflared --no-pager | head -5"
