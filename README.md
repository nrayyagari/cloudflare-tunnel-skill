# cloudflare-tunnel-skill

Pi skill for setting up and managing [Cloudflare Tunnels](https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/) (`cloudflared`).

Expose local web services through Cloudflare's edge network without opening firewall ports.

## Installation

```bash
pi install git:github.com/nrayyagari/cloudflare-tunnel-skill
```

## Usage

Ask Pi to expose a local service:

> "Set up a Cloudflare tunnel for my docs on port 8080"
> "Create a tunnel and serve my app from localhost:3000"
> "My tunnel is returning 502, fix it"

Pi will load the skill automatically based on the description trigger.

## What it covers

- Installing `cloudflared`
- Token-based and login-based tunnels
- Local origin server setup (Python, nginx)
- Systemd service persistence
- Self-signed TLS certs with SANs + CA trust
- DNS configuration
- Troubleshooting common errors (502, 521, cert issues)

## Structure

```
cloudflare-tunnel-skill/
├── package.json
├── README.md
└── skills/
    └── cloudflare-tunnel/
        ├── SKILL.md
        ├── scripts/
        │   ├── setup-tunnel.sh
        │   └── verify-tunnel.sh
        └── references/
            ├── troubleshooting.md
            └── architecture.md
```

## License

MIT
