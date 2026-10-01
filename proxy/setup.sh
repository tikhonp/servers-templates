#!/bin/bash

set -e

# VLESS-only proxy behind nginx.
#
# nginx terminates TLS for your domain, serves a decoy one-page site at / and forwards
# only two secret paths to xray as plain unencrypted traffic:
#   https://<domain><ws-path>         -> xray VLESS over WebSocket (xray:10001)
#   https://<domain><xhttp-path>/...  -> xray VLESS over XHTTP     (xray:10002)
# The Let's Encrypt certificate is issued here once and then renewed by the certbot container.

# SCHEME FOR .env file:
#
# CONTAINER_POSTFIX=a1b2
# SERVER_DOMAIN=example.com
# VLESS_WS_PATH=/0123456789abcdef
# VLESS_XHTTP_PATH=/fedcba9876543210

ENV_FILE=".env"
RAW_BASE_URL="https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/proxy"

__add_to_env() {
    local name="$1"
    local value="$2"

    echo "${name}=${value}" >> "$ENV_FILE"
}

# here we will store all final credentials to print to user at the end
boostrapped_credentials="Done! Here is your credentials:\n"

__add_to_credentials() {
    local name="$1"
    local value="$2"

    boostrapped_credentials="${boostrapped_credentials}\n${name}:\n${value}\n"
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

generate_xray_uuid() {
    uuidgen
}

# Downloads compose file, xray config, nginx template and decoy site
# into the current directory.
download_templates() {
    echo "Downloading templates..."

    mkdir -p nginx site certbot/conf certbot/www

    local file
    for file in compose.yaml xray-config.json nginx/default.conf.template site/index.html; do
        curl -fsSL -o "./${file}" "${RAW_BASE_URL}/${file}" || exit 1
    done
}

SERVER_DOMAIN=""
LETSENCRYPT_EMAIL=""

# Asks user for server domain and email for Let's Encrypt, warns if the domain
# doesn't resolve to this server, adds domain to .env file.
# Also stores them in global variables for later use.
ask_for_domain_and_email() {
    local public_ip resolved_ips confirm
    public_ip=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

    printf "Seems like your server's public IP is: %s\n" "$public_ip"
    echo "Use a separate domain not linked to you; its A record must point to this server."

    printf "Enter server domain (e.g. example.com): "
    read -r SERVER_DOMAIN
    if [ -z "$SERVER_DOMAIN" ]; then
        echo "Domain is required."
        exit 1
    fi

    resolved_ips=$(getent ahostsv4 "$SERVER_DOMAIN" | awk '{print $1}' | sort -u | tr '\n' ' ')
    if [[ " $resolved_ips " != *" $public_ip "* ]]; then
        printf "WARNING: %s resolves to '%s', not to %s.\n" "$SERVER_DOMAIN" "${resolved_ips% }" "$public_ip"
        echo "Certificate issuing will fail unless the domain points to this server."
        read -r -p "Continue anyway? (y/n) " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    printf "Enter email for Let's Encrypt expiry notices (or leave empty): "
    read -r LETSENCRYPT_EMAIL

    __add_to_env "SERVER_DOMAIN" "$SERVER_DOMAIN"
}

# Issues the first certificate with a one-off certbot container in standalone mode
# (nginx can't start without a certificate). Renewals are done by the certbot service.
# args:
# $1 - server domain
# $2 - email, may be empty
issue_certificate() {
    local server_domain="$1"
    local email="$2"

    local email_args=(--register-unsafely-without-email)
    if [ -n "$email" ]; then
        email_args=(-m "$email" --no-eff-email)
    fi

    echo "Issuing Let's Encrypt certificate for ${server_domain}..."

    if ! as_root docker run --rm -p 80:80 \
        -v "$PWD/certbot/conf:/etc/letsencrypt" \
        certbot/certbot certonly --standalone --non-interactive --agree-tos \
        "${email_args[@]}" -d "$server_domain"; then
        echo "Failed to issue certificate. Check that the A record of ${server_domain} points to this server and port 80 is open and free."
        exit 1
    fi
}

VLESS_WS_PATH=""
VLESS_XHTTP_PATH=""

# Generates random secret paths for both xray inbounds, adds them to .env file.
generate_paths() {
    VLESS_WS_PATH="/$(openssl rand -hex 8)"
    VLESS_XHTTP_PATH="/$(openssl rand -hex 8)"

    __add_to_env "VLESS_WS_PATH" "$VLESS_WS_PATH"
    __add_to_env "VLESS_XHTTP_PATH" "$VLESS_XHTTP_PATH"
}

# args:
# $1 - server domain
# $2 - websocket path
# $3 - xhttp path
#
# Fills xray-config.json template and generates VLESS links.
generate_xray_config() {
    echo "Generating xray config for VLESS..."

    local server_domain="$1"
    local ws_path="$2"
    local xhttp_path="$3"

    local uuid
    uuid=$(generate_xray_uuid)

    sed -i \
        -e "s|VLESS_CLIENT_UUID|${uuid}|g" \
        -e "s|VLESS_WS_PATH|${ws_path}|g" \
        -e "s|VLESS_XHTTP_PATH|${xhttp_path}|g" ./xray-config.json

    local tag_name
    printf "Enter tag name for VLESS links: "
    read -r tag_name

    # Paths are hex, so only the leading slash needs URL-encoding.
    local common_params
    common_params="encryption=none&security=tls&sni=${server_domain}&fp=chrome&host=${server_domain}"

    local ws_credentials
    ws_credentials="vless://${uuid}@${server_domain}:443?${common_params}&alpn=http%2F1.1&type=ws&path=%2F${ws_path#/}#${tag_name}-ws"
    __add_to_credentials "VLESS WebSocket url" "$ws_credentials"

    # Client mode "auto" means packet-up over TLS (many small POSTs); stream-up keeps one
    # streaming POST through nginx grpc_pass. The server accepts any mode, so clients can
    # still switch to packet-up (e.g. behind a CDN).
    local xhttp_credentials
    xhttp_credentials="vless://${uuid}@${server_domain}:443?${common_params}&alpn=h2&type=xhttp&path=%2F${xhttp_path#/}&mode=stream-up#${tag_name}-xhttp"
    __add_to_credentials "VLESS XHTTP url" "$xhttp_credentials"

    local vless_raw_credentials
    vless_raw_credentials="server: ${server_domain}\nport: 443\nuuid: ${uuid}\nsecurity: tls (sni ${server_domain})\nwebsocket path: ${ws_path}\nxhttp path: ${xhttp_path}\nxhttp mode: stream-up"
    __add_to_credentials "VLESS (raw parameters)" "$vless_raw_credentials"
}

CONTAINER_POSTFIX=""

generate_container_postfix() {
    CONTAINER_POSTFIX=$(openssl rand -hex 2)
    __add_to_env "CONTAINER_POSTFIX" "$CONTAINER_POSTFIX"
}

PROJECT_DIRECTORY="$HOME/proxy"
SKIP_BOOTSTRAP=false

# args:
#  --dir <project_directory> - directory to setup proxy in, default is $HOME/proxy
#  --skip-bootstrap - skip bootstrapping system, only setup proxy
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

install_packets() {
    as_root apt update
    as_root apt install -y uuid-runtime
}

# Group membership granted during bootstrap only applies to new logins, so this process and the
# user's shell can't talk to docker yet. Replaces this script with a shell in the project directory
# that has the docker group active.
enter_docker_group_shell() {
    if id -nG | grep -qw docker; then
        return
    fi

    if id -nG "$(id -un)" | grep -qw docker && [ -t 0 ] && command -v newgrp >/dev/null 2>&1; then
        echo "Starting a shell in $PROJECT_DIRECTORY with the docker group active (exit to return)..."
        exec newgrp docker
    fi

    echo "Note: log out and back in (or run 'newgrp docker') before using docker without sudo."
}

main() {
    parse_arguments "$@"

    if [ "$SKIP_BOOTSTRAP" = false ]; then
        echo "Bootstrapping system..."
        curl -fsSL https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/bootstrap-system.sh | sh -s --
    else
        echo "Skipping system bootstrap as per argument."
    fi

    install_packets

    echo "Setting up proxy in $PROJECT_DIRECTORY"
    if [ -d "$PROJECT_DIRECTORY" ]; then
        echo "Directory $PROJECT_DIRECTORY already exists. Please choose a different directory or remove it."
        exit 1
    fi
    mkdir -p "$PROJECT_DIRECTORY"
    cd "$PROJECT_DIRECTORY" || exit 1

    generate_container_postfix

    download_templates

    ask_for_domain_and_email

    issue_certificate "$SERVER_DOMAIN" "$LETSENCRYPT_EMAIL"

    generate_paths

    generate_xray_config "$SERVER_DOMAIN" "$VLESS_WS_PATH" "$VLESS_XHTTP_PATH"

    printf "%b\n" "$boostrapped_credentials"

    printf "%b\n" "$boostrapped_credentials" > credentials.txt
    echo "All credentials have been saved to credentials.txt in the project directory."

    echo "Setup complete! To start your proxy run in $PROJECT_DIRECTORY:

    docker compose up -d

https://$SERVER_DOMAIN will show the decoy site from ./site."

    enter_docker_group_shell
}

main "$@"
