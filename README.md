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

This script bootstraps vps, installs docker and sets up compose with VLESS only, hidden behind nginx:

```
client --TLS:443--> nginx --/<ws-path>-------> xray (VLESS over WebSocket)
                          --/<xhttp-path>/...-> xray (VLESS over XHTTP)
                          --anything else-----> decoy one-page site
```

nginx terminates TLS (Let's Encrypt certificate, renewed by the certbot container), xray has no published
ports and only gets plain traffic on two random secret paths. Connections to the server IP without the
right SNI are rejected at the TLS handshake.

Before running you need:
- a separate domain not linked to you, with an A record pointing to the vps
- ports 80 and 443 free and open (80 is used for certificate issuing and renewal)

At the end the script prints two links (WebSocket and XHTTP) and saves them to `credentials.txt`
in the project directory. The decoy site lives in `site/` there, replace `site/index.html` with anything you like.

Options are:
```
--dir <dir> - directory for compose files, default is /home/username/proxy
--skip-bootstrap
```
