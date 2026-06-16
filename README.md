# My typical servers templates

Here i'm storing bootstrap scripts for my typical servers, home with homebrisge, proxy, vpn, etc.

For now there is home server and proxy server. They are located in their dirs:

```
.
├── hommy
└── proxy
```

# Hommy server

Native (non-Docker) home-server provisioning: installs Homebridge from its apt repo,
Tailscale joined to a self-hosted headscale control server, and optionally UniFi OS Server.

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/hommy/setup.sh)"
```

The script prompts for an optional system-wide apt HTTP proxy (useful where the Homebridge
repos are blocked, so future `apt upgrade`s still work), the headscale login server URL +
pre-auth key, and the UniFi OS Server `.bin` download URL.

Options are:
```
--dir <dir>       - directory for the setup summary (hommy-info.txt), default is /home/username/hommy
--skip-bootstrap  - skip base prep (apt prerequisites + SSH password hardening)
```

# Proxy/VPN server

I usally use vps for this task with debian

```sh
bash -c "$(curl -fsSL https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/proxy/setup.sh)"
```

This script bootstraps vps installs docker and setups compose for mtproxy, vless and socks5 proxies. 

Options are:
```
--dir <dir> - directory for compose files, default is /home/username/proxy
--skip-bootstrap
```
