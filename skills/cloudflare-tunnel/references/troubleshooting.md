# Troubleshooting Cloudflare Tunnels

## 502 Bad Gateway

The tunnel is connected but the origin is unreachable or rejecting the connection.

### Check origin is running
```bash
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/   # expected: 200
systemctl status origin.service --no-pager | head -5
journalctl -u origin.service --no-pager | tail -10
```

### Check for TLS errors
```bash
journalctl -u cloudflared.service --no-pager | grep -i "originService\|certificate" | tail -5
```

### Common causes
- **Wrong port**: Origin runs on port X but tunnel expects Y
- **TLS cert invalid**: Remote config forces HTTPS but cert is self-signed with missing SANs or untrusted CA
- **Protocol mismatch**: Tunnel expects HTTPS but origin speaks HTTP (or vice versa)

### Fix TLS cert issues

```bash
# Regenerate with SANs
openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

# Or create a proper CA-signed cert
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -days 3650 -out ca.crt -subj "/CN=TunnelCA"
openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -subj "/CN=localhost"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 \
  -extfile <(printf "subjectAltName=DNS:localhost,IP:127.0.0.1")

# Trust the CA
sudo cp ca.crt /usr/local/share/ca-certificates/tunnel-ca.crt
sudo update-ca-certificates
```

## 521 Web Server Down

The tunnel has no active connection to the Cloudflare edge.

```bash
systemctl status cloudflared.service
journalctl -u cloudflared.service --no-pager | tail -20
```

Check:
- Network connectivity: `ping 1.1.1.1`
- Token validity: If token was revoked, get a new one from the dashboard
- Outbound connectivity: Cloudflare edge IPs (198.41.192.0/24, 198.41.200.0/24) must be reachable

## 403 Forbidden / Challenge Page

Cloudflare WAF is blocking the request.

- Normal for curl/automation from datacenter IPs
- Open in a real browser to pass the "Verify you are human" challenge
- To reduce challenge frequency: Cloudflare dashboard → Security → Settings → Security Level → "Low"
- Whitelist your IP: Security → WAF → Tools → IP Access Rules → Allow

## Remote config overrides local settings

When using `--token`, cloudflared fetches its config from the Cloudflare Zero Trust dashboard. This means:

1. **`--url` flag is ignored** if the dashboard has ingress rules configured
2. **config.yml ingress is overridden** by the dashboard config
3. **`originRequest` settings** in config.yml may still apply (test with current version)

Fix: Change the origin protocol in the dashboard (HTTPS → HTTP) or trust the self-signed cert system-wide.

## Certificate: "legacy Common Name"

Go 1.15+ requires Subject Alternative Names (SANs) in certificates. CN-only certs are rejected.

Fix: Regenerate with `-addext "subjectAltName=DNS:localhost,IP:127.0.0.1"`.

## Certificate: "signed by unknown authority"

Self-signed certs are not trusted by default. cloudflared's Go TLS client validates the certificate chain.

Fix: Add the CA to the system trust store:
```bash
sudo cp ca.crt /usr/local/share/ca-certificates/tunnel-ca.crt
sudo update-ca-certificates
```
Then restart cloudflared.

## Logs reference

```bash
# All tunnel errors
journalctl -u cloudflared.service --no-pager | grep -i error

# All origin connection attempts
journalctl -u cloudflared.service --no-pager | grep -i "originService\|status_code=200"

# Watch live
journalctl -u cloudflared.service -f

# Last 5 minutes
journalctl -u cloudflared.service --since "5 min ago"
```
