#!/bin/bash

set -e

# Native (non-Docker) provisioning for the home server "hommy".
#
# Installs, on a fresh Debian/Raspbian/Ubuntu host:
#   - Homebridge (HomeKit bridge) via the official apt repository (repo.homebridge.io)
#   - Tailscale via tailscale.com/install.sh (install only; the user runs `tailscale up` to
#     join their self-hosted headscale control server afterwards)
#   - (optional) UniFi OS Server (Podman-based, x86_64 only) from a ui.com .bin installer
#
# Homebridge repos may be unreachable in some regions, so an optional HTTP proxy can be
# configured system-wide for apt (persists for future `apt upgrade`s) and is also exported
# for the script session so the Tailscale and UniFi downloads use it too.
#
# A summary of what was installed (URLs, node name, management commands) is written to
# <project-dir>/hommy-info.txt.

PROJECT_DIRECTORY="$HOME/hommy"
SKIP_BOOTSTRAP=false
HTTP_PROXY_URL=""

# Accumulated human-readable summary printed at the end and saved to hommy-info.txt.
hommy_info="Done! Here is your hommy setup summary:\n"

__add_to_info() {
    local name="$1"
    local value="$2"
    hommy_info="${hommy_info}\n${name}:\n${value}\n"
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
        return $?
    fi
    if command -v sudo >/dev/null 2>&1; then
        sudo "$@"
        return $?
    fi
    echo "This script needs root privileges for '$*'" >&2
    exit 1
}

# args:
#  --dir <project_directory> - directory to store the setup summary, default is $HOME/hommy
#  --skip-bootstrap          - skip base system prep (apt prerequisites + SSH hardening)
parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --dir)
                PROJECT_DIRECTORY="$2"
                shift 2
                ;;
            --skip-bootstrap)
                SKIP_BOOTSTRAP=true
                shift
                ;;
            *)
                echo "Unknown argument: $1"
                exit 1
                ;;
        esac
    done
}

# Ask for an optional HTTP proxy and, if given, configure it system-wide for apt and
# export it for the rest of this script (covers the tailscale and unifi downloads too).
configure_proxy() {
    read -r -p "Enter HTTP proxy for apt/downloads (e.g. http://10.0.0.1:3128), or leave empty: " HTTP_PROXY_URL
    if [ -z "$HTTP_PROXY_URL" ]; then
        echo "No proxy configured."
        return
    fi

    echo "Configuring system-wide apt proxy..."
    as_root sh -c "cat > /etc/apt/apt.conf.d/01proxy <<EOF
Acquire::http::Proxy \"${HTTP_PROXY_URL}\";
Acquire::https::Proxy \"${HTTP_PROXY_URL}\";
EOF"

    # Export for curl/wget invoked during this run (tailscale install.sh, unifi .bin).
    export http_proxy="$HTTP_PROXY_URL"
    export https_proxy="$HTTP_PROXY_URL"
    export HTTP_PROXY="$HTTP_PROXY_URL"
    export HTTPS_PROXY="$HTTP_PROXY_URL"

    __add_to_info "HTTP proxy (apt + setup downloads)" "$HTTP_PROXY_URL\nApt proxy file: /etc/apt/apt.conf.d/01proxy"
}

# Minimal base prep: prerequisites + SSH password hardening. No Docker.
system_prep() {
    if [ "$SKIP_BOOTSTRAP" = true ]; then
        echo "Skipping system bootstrap as per argument."
        return
    fi

    touch ~/.hushlogin || true

    echo "Installing prerequisites..."
    as_root apt-get update
    as_root apt-get install -y curl wget gnupg ca-certificates

    # SSH hardening: disable password auth only when key-based login is set up.
    local auth_keys="$HOME/.ssh/authorized_keys"
    if [ -s "$auth_keys" ] && [ -d /etc/ssh/sshd_config.d ]; then
        echo "Disabling SSH password authentication..."
        as_root sh -c "cat > /etc/ssh/sshd_config.d/60-disable-password.conf <<'EOF'
# Hardened by hommy setup.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF"
        as_root systemctl reload ssh 2>/dev/null || as_root systemctl reload sshd 2>/dev/null || true
    else
        echo "authorized_keys missing/empty or no sshd_config.d; skipping SSH password hardening."
    fi
}

# Homebridge via the official apt repository. Installs an hb-service systemd unit listening
# on :8581 and bundles its own Node runtime.
install_homebridge() {
    echo "Installing Homebridge from repo.homebridge.io..."
    curl -sSfL https://repo.homebridge.io/KEY.gpg | as_root gpg --dearmor -o /usr/share/keyrings/homebridge.gpg
    echo "deb [signed-by=/usr/share/keyrings/homebridge.gpg] https://repo.homebridge.io stable main" \
        | as_root tee /etc/apt/sources.list.d/homebridge.list > /dev/null
    as_root apt-get update
    as_root apt-get install -y homebridge

    __add_to_info "Homebridge" "Web UI: http://<this-host>:8581 (also reachable on the tailnet IP)\nManage: sudo hb-service {start|stop|restart|logs}\nConfig: /var/lib/homebridge/config.json\nUpdate later: sudo apt update && sudo apt install --only-upgrade homebridge"
}

# Tailscale install only. Joining a control server (`tailscale up`) is left to the user so
# they can supply their headscale login server, pre-auth key, and hostname at run time.
install_tailscale() {
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh

    __add_to_info "Tailscale" "Installed but NOT connected. To join your headscale control server, run:\n  sudo tailscale up --login-server=<https://headscale.example.com> --authkey=<headscale-pre-auth-key> --hostname=<node-name> --accept-dns=false\n(--accept-dns=false keeps the server's own DNS: headscale-pushed MagicDNS/nameservers would rewrite /etc/resolv.conf and can break local resolution and apt)\nThen check: tailscale status\nFind the tailnet IP with: tailscale ip -4\nHomebridge will then be reachable over the tailnet at http://<tailnet-ip>:8581"
}

# UniFi OS Server (optional). Podman-based (Docker unsupported); ships x64 and arm64 Linux
# builds. The installer is versioned per release with no stable URL, so we prompt the user to
# paste the current download link for their architecture.
install_unifi() {
    read -r -p "Do you want to install UniFi OS Server? (y/n) " enable_unifi
    if [[ ! "$enable_unifi" =~ ^[Yy]$ ]]; then
        return
    fi

    # Map the host arch to the UniFi download label (Linux x64 vs arm64) to guide the user.
    local arch uos_arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)         uos_arch="x64" ;;
        aarch64|arm64)  uos_arch="arm64" ;;
        *)              uos_arch="" ;;
    esac

    echo "Installing Podman (UniFi OS Server requires Podman >= 4.3.1; Docker is not supported)..."
    as_root apt-get update
    as_root apt-get install -y podman slirp4netns

    local podman_ver
    podman_ver=$(podman --version 2>/dev/null | awk '{print $3}')
    echo "Installed podman version: ${podman_ver:-unknown}"
    # Compare against 4.3.1 (sort -V): if the lowest version isn't 4.3.1, podman is too old.
    if [ -n "$podman_ver" ] && [ "$(printf '%s\n4.3.1\n' "$podman_ver" | sort -V | head -n1)" != "4.3.1" ]; then
        echo "WARNING: podman ${podman_ver} is older than 4.3.1. UniFi OS Server may not start."
        echo "Upgrade podman (e.g. from backports or the Kubic repo for your distro) and re-run the UniFi installer manually."
    fi

    echo
    echo "Open https://ui.com/download/software/unifi-os-server"
    if [ -n "$uos_arch" ]; then
        echo "Pick the latest 'UniFi OS Server ... for Linux (${uos_arch})' build (host arch: ${arch}) and copy its link address."
    else
        echo "WARNING: unrecognized host arch '${arch}'; pick the Linux build that matches it and copy its link address."
    fi
    read -r -p "Paste the UniFi OS Server installer download URL: " UNIFI_URL
    if [ -z "$UNIFI_URL" ]; then
        echo "No URL provided; skipping UniFi installation."
        __add_to_info "UniFi OS Server" "SKIPPED: no installer URL provided."
        return
    fi

    local unifi_dir="$PROJECT_DIRECTORY/unifi-os-server"
    mkdir -p "$unifi_dir"
    local installer="$unifi_dir/unifi-os-server-installer.bin"

    # The ui.com download may be faster/only reachable directly, so allow bypassing the
    # configured HTTP proxy just for this download. --noproxy '*' ignores the *_proxy env vars.
    local curl_proxy_opts=""
    if [ -n "$HTTP_PROXY_URL" ]; then
        read -r -p "Download the UniFi installer WITHOUT the HTTP proxy? (y/n) " unifi_no_proxy
        if [[ "$unifi_no_proxy" =~ ^[Yy]$ ]]; then
            curl_proxy_opts="--noproxy *"
            echo "Bypassing proxy for the UniFi download."
        fi
    fi

    echo "Downloading UniFi OS Server installer..."
    # shellcheck disable=SC2086
    curl $curl_proxy_opts -fL -o "$installer" "$UNIFI_URL"
    chmod +x "$installer"

    echo "Running UniFi OS Server installer (this can take a few minutes)..."
    as_root "$installer"

    __add_to_info "UniFi OS Server" "Web UI: https://<this-host>:11443 (also reachable on the tailnet IP)\nManage: sudo systemctl {start|stop|enable|disable} uosserver\nUpdates: via Update Manager / local Control Plane settings\nInstaller saved at: ${installer}"
}

main() {
    parse_arguments "$@"

    echo "Setting up hommy. Summary will be written to $PROJECT_DIRECTORY"
    if [ -d "$PROJECT_DIRECTORY" ]; then
        echo "Directory $PROJECT_DIRECTORY already exists. Please choose a different directory or remove it."
        exit 1
    fi
    mkdir -p "$PROJECT_DIRECTORY"
    cd "$PROJECT_DIRECTORY" || exit 1

    configure_proxy
    system_prep
    install_homebridge
    install_tailscale
    install_unifi

    printf "%b\n" "$hommy_info"
    printf "%b\n" "$hommy_info" > "$PROJECT_DIRECTORY/hommy-info.txt"
    echo "Summary saved to $PROJECT_DIRECTORY/hommy-info.txt"
}

main "$@"
