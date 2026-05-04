#!/usr/bin/env bash
# verify-tunnel.sh — Check tunnel health end-to-end
set -euo pipefail

URL="${1:-}"
PORT="${2:-8080}"

echo "=== 1. Local origin ==="
if curl -s -o /dev/null -w "   HTTP %{http_code}\n" http://localhost:"$PORT"/; then
  echo "   ✓ Local server reachable"
else
  echo "   ✗ Local server unreachable — check origin.service"
fi

echo ""
echo "=== 2. Tunnel service ==="
if systemctl is-active --quiet cloudflared.service; then
  echo "   ✓ cloudflared.service is active"
else
  echo "   ✗ cloudflared.service is NOT active"
  systemctl status cloudflared.service --no-pager 2>&1 | head -5
fi

CONNS=$(journalctl -u cloudflared.service --no-pager 2>/dev/null | grep -c "Registered tunnel connection" || true)
echo "   Tunnel connections registered: $CONNS"

echo ""
echo "=== 3. TLS / Origin errors ==="
ERRS=$(journalctl -u cloudflared.service --no-pager 2>/dev/null | grep -c "originService\|certificate" || true)
if [[ "$ERRS" -eq 0 ]]; then
  echo "   ✓ No TLS/origin errors"
else
  echo "   ✗ Found $ERRS TLS/origin errors:"
  journalctl -u cloudflared.service --no-pager 2>/dev/null | grep "originService\|certificate" | tail -5
fi

echo ""
echo "=== 4. Public endpoint ==="
if [[ -n "$URL" ]]; then
  CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$URL" 2>/dev/null || echo "000")
  echo "   $URL → HTTP $CODE"
  case "$CODE" in
    200|301|302) echo "   ✓ Public endpoint reachable" ;;
    403)         echo "   ⚠ Cloudflare challenge (normal for bots)" ;;
    502)         echo "   ✗ 502 Bad Gateway — origin TLS error or server down" ;;
    521)         echo "   ✗ 521 — tunnel disconnected" ;;
    000)         echo "   ✗ Could not reach URL — check DNS" ;;
    *)           echo "   ? Unexpected status" ;;
  esac
else
  echo "   Pass a URL to check: $0 https://demo.example.com [port]"
fi

echo ""
echo "=== 5. System resources ==="
echo "   cloudflared: $(ps -eo rss,cmd | grep cloudflared | grep -v grep | awk '{sum+=$1} END {printf "%.0f MB", sum/1024}')"
echo "   origin:      $(ps -eo rss,cmd | grep -E "python3.*http|server.py" | grep -v grep | awk '{sum+=$1} END {printf "%.0f MB", sum/1024}')"
