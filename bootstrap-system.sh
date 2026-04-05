#!/bin/bash

set -e

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

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        echo "Docker already installed; skipping installer"
        return
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is required to fetch get.docker.com; please install it and rerun" >&2
        exit 1
    fi

    tmp_script=$(mktemp /tmp/get-docker.XXXXXX.sh)
    echo "Downloading Docker installer..."
    curl -fsSL https://get.docker.com -o "$tmp_script"
    echo "Running Docker installer..."
    as_root sh "$tmp_script"
    rm -f "$tmp_script"
}

ensure_docker_group() {
    if ! getent group docker >/dev/null 2>&1; then
        as_root groupadd docker
    fi
}

add_user_to_docker() {
    target_user=${TARGET_USER:-${SUDO_USER:-$(id -un)}}
    if id -nG "$target_user" | grep -qw docker; then
        echo "User '$target_user' already in docker group"
        return 1
    fi

    echo "Adding '$target_user' to docker group..."
    as_root usermod -aG docker "$target_user"
    printf "User '%s' added to docker group\n" "$target_user"
    if [ "$target_user" = "$(id -un)" ]; then
        activate_group_for_current_shell=true
    fi
    return 0
}

activate_docker_group() {
    if [ "${activate_group_for_current_shell:-false}" != "true" ]; then
        echo "Log out and back in (or run 'newgrp docker') to use docker without sudo."
        return
    fi

    if command -v newgrp >/dev/null 2>&1; then
        echo "Starting a new shell with docker group active. Exit to return." >&2
        exec newgrp docker
    fi
}

disable_ssh_password_auth() {
    target_user=${TARGET_USER:-${SUDO_USER:-$(id -un)}}
    user_home=$(getent passwd "$target_user" | awk -F: '{print $6}')
    [ -n "$user_home" ] || user_home=$HOME
    auth_keys="$user_home/.ssh/authorized_keys"

    if [ ! -s "$auth_keys" ]; then
        echo "authorized_keys not found or empty at $auth_keys; skipping SSH password hardening."
        return
    fi

    if [ -d /etc/ssh/sshd_config.d ]; then
        ssh_conf=/etc/ssh/sshd_config.d/60-disable-password.conf
        as_root sh -c "cat > '$ssh_conf' <<'EOF'
# Hardened by bootstrap-system.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF"
    else
        ssh_conf=/etc/ssh/sshd_config
        if [ ! -f ${ssh_conf}.bak ]; then
            as_root cp "$ssh_conf" "${ssh_conf}.bak"
        fi
        as_root sh -c "
            awk '
                BEGIN {pa=0;ki=0;cr=0}
                /^PasswordAuthentication/ {print "PasswordAuthentication no"; pa=1; next}
                /^KbdInteractiveAuthentication/ {print "KbdInteractiveAuthentication no"; ki=1; next}
                /^ChallengeResponseAuthentication/ {print "ChallengeResponseAuthentication no"; cr=1; next}
                {print}
                END {
                    if (!pa) print "PasswordAuthentication no";
                    if (!ki) print "KbdInteractiveAuthentication no";
                    if (!cr) print "ChallengeResponseAuthentication no";
                }
            ' "$ssh_conf" > "${ssh_conf}.tmp"
        "
        as_root mv "${ssh_conf}.tmp" "$ssh_conf"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        as_root systemctl reload sshd 2>/dev/null || as_root systemctl reload ssh || true
    elif command -v service >/dev/null 2>&1; then
        as_root service ssh reload 2>/dev/null || as_root service sshd reload 2>/dev/null || true
    else
        echo "Could not reload sshd; please reload it manually."
    fi
}

main() {
    install_docker
    ensure_docker_group
    add_user_to_docker || true
    disable_ssh_password_auth
    activate_docker_group
}

main "$@"
