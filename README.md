# Cloudflare Tunnel Skill

A skill/instruction set for AI coding agents (Claude, Pi, Codex, OpenCode, Cursor, Gemini, etc.) to set up and manage Cloudflare Tunnels (`cloudflared`).

Expose local web services through Cloudflare's edge network without opening firewall ports.

## What it covers

- Installing `cloudflared`
- Token-based and login-based tunnel authentication
- Local origin server setup (Python, nginx)
- Systemd service persistence
- Self-signed TLS certs with SANs + CA trust
- DNS configuration via dashboard or CLI
- Troubleshooting 502, 521, and TLS cert errors

## Structure

```
cloudflare-tunnel-skill/
├── SKILL.md                   # Main workflow — load this into the agent
├── scripts/
│   ├── setup-tunnel.sh        # Automated setup script
│   └── verify-tunnel.sh       # Health check script
└── references/
    ├── troubleshooting.md     # Deep-dive error resolution
    └── architecture.md        # How Cloudflare Tunnels work
```

## Usage

Load `SKILL.md` into your agent's context, or reference it when asking about Cloudflare Tunnels. The agent will follow the steps for installation, configuration, and troubleshooting.

## Requirements

- A domain on Cloudflare (DNS managed by Cloudflare)
- `cloudflared` binary (install steps in SKILL.md)
- Linux (Ubuntu/Debian) — adapt scripts for other OS
