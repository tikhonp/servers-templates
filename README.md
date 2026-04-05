# My typical servers templates

Here i'm storing bootstrap scripts for my typical servers, home with homebrisge, proxy, vpn, etc.

For now there is home server and proxy server. They are located in their dirs:

```
.
├── hommy
└── proxy
```

# Hommy server

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
