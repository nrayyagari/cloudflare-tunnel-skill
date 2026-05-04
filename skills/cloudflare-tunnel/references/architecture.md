# Cloudflare Tunnel Architecture

## Overview

Cloudflare Tunnel creates an encrypted tunnel between your origin server and Cloudflare's edge network. Unlike traditional reverse proxies (nginx, HAProxy) that accept inbound connections, cloudflared makes **outbound-only** connections to Cloudflare's edge. This eliminates the need for open firewall ports, public IPs, or VPNs.

## Connection Flow

```
                         ┌──────────────────────┐
                         │   Cloudflare Edge     │
                         │  ┌────┐ ┌────┐ ┌────┐│
                         │  │POP1│ │POP2│ │POP3││
                         │  └──┬─┘ └──┬─┘ └──┬─┘│
                         │     │      │      │   │
                         └─────┼──────┼──────┼───┘
                               │      │      │
                     QUIC ─────┘      │      └──── QUIC
                     (encrypted)      │           (encrypted)
                                      │ QUIC
                                      │
                         ┌────────────┴───────────┐
                         │    Your Server          │
                         │  cloudflared daemon      │
                         │    │                     │
                         │  localhost:PORT          │
                         │    │                     │
                         │  Origin (HTTP/HTTPS)     │
                         └─────────────────────────┘
```

### 1. DNS Resolution

When a user visits `https://demo.example.com`:
- DNS resolves to Cloudflare's anycast IPs (the domain is on Cloudflare's DNS)
- Cloudflare's edge receives the request

### 2. Tunnel Routing

Cloudflare checks if the domain has a tunnel configured:
- Looks up the tunnel ID associated with the hostname
- Routes the request to any active cloudflared connection for that tunnel

### 3. QUIC Connections

cloudflared establishes **4 parallel QUIC connections** to Cloudflare edge:

```bash
journalctl -u cloudflared.service | grep "Registered tunnel connection"
# → 4 connections to different edge locations (bom03, bom06, bom08, bom11)
```

- **QUIC** (HTTP/3 over UDP) is the default protocol
- Multiple connections provide redundancy and connection pooling
- If one edge location goes down, traffic routes through another

### 4. Ingress Matching

When a request arrives at the tunnel:

1. **Token-based:** The remote config from the Zero Trust dashboard is fetched and applied. The dashboard defines which hostnames map to which local services.
2. **Login-based:** The local `config.yml` is used. cloudflared matches the request's `Host` header against ingress rules and forwards to the matching service URL.

### 5. Origin Forwarding

cloudflared forwards the request to the configured origin:

```
https://demo.example.com/foo
  → cloudflared matches ingress hostname
  → forwards to http://localhost:8080/foo  (or https://...)
  → origin responds
  → response flows back through the tunnel
```

## Auth Methods Compared

| Aspect | Token-based | Login-based |
|--------|-------------|-------------|
| Setup | Dashboard → copy token | `cloudflared tunnel login` + `tunnel create` |
| Config management | Cloudflare Zero Trust dashboard | Local `config.yml` |
| Multiple origins | Dashboard UI | config.yml ingress rules |
| Credentials | Single token string | Credentials JSON file + cert.pem |
| Best for | Single service, quick setup | Advanced config, multiple hostnames |
| Config override | Remote config always wins | Local config fully controlled |

## Security Model

| Layer | Protection |
|-------|-----------|
| Transport | QUIC (TLS 1.3) end-to-end encrypted |
| Authentication | Token or client certificate per tunnel connection |
| Origin | No public IP, no open ports on the server |
| Edge | Cloudflare WAF, DDoS mitigation, bot management |
| Access (optional) | Cloudflare Access can add SSO before the request reaches the tunnel |

## Connection Lifecycle

1. cloudflared starts → reads config/token
2. Opens 4 QUIC connections to the nearest Cloudflare edge
3. Registers the tunnel, ready to accept requests
4. On incoming request: ingress matching → origin forwarding
5. On cloudflared restart: old connections drain, new connections establish
6. Persistent retry with backoff if edge is unreachable

## Performance Notes

- 4 parallel QUIC connections by default
- Connection pooling between cloudflared and origin (up to 100 keepalive connections)
- No additional latency beyond the QUIC overhead (~5-20ms)
- Metrics available at `http://127.0.0.1:20241/metrics`
- For high-traffic sites, tune `--proxy-keepalive-connections` and `--proxy-keepalive-timeout`
