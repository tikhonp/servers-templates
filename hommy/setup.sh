#!/bin/bash

set -e

# SCHEME FOR .env file:
#
# TS_AUTHKEY=your_ts_authkey
# TS_EXTRA_ARGS=if needed
# NODE_NAME=your_node_name
# HTTP_PROXY=http://your_proxy:port
# HTTPS_PROXY=http://your_proxy:port
# SERVER_LAN_IP=10.220.1.4
# SERVER_LAN_IPV6=2a02:2168:ae5e:cf00:7b06:5a1c:698:adcb

ENV_FILE=".env"

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

# Args:
# Packages to install, e.g. "docker docker-compose"
install_packages() {
    local packages="$1"

    if [ -n "$packages" ]; then
        sudo apt update
        sudo apt install -y $packages
    fi
}

PROJECT_DIRECTORY="$HOME/hommy"
SKIP_BOOTSTRAP=false

# args:
#  --dir <project_directory> - directory to setup project in, default is $HOME/hommy
#  --skip-bootstrap - skip bootstrapping system, only setup hommy
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

ask_for_env_vars() {
    read -p "Enter TS_AUTHKEY: " TS_AUTHKEY
    read -p "Enter TS_EXTRA_ARGS (or leave empty): " TS_EXTRA_ARGS
    read -p "Enter NODE_NAME: " NODE_NAME
    read -p "Enter HTTP_PROXY: " HTTP_PROXY

    __add_to_env "TS_AUTHKEY" "$TS_AUTHKEY"
    if [ -n "$TS_EXTRA_ARGS" ]; then
        __add_to_env "TS_EXTRA_ARGS" "$TS_EXTRA_ARGS"
    fi
    __add_to_env "NODE_NAME" "$NODE_NAME"
    __add_to_env "HTTP_PROXY" "$HTTP_PROXY"
    __add_to_env "HTTPS_PROXY" "$HTTP_PROXY"

    local suggested_lan_ip
    suggested_lan_ip=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

    local suggested_lan_ipv6
    suggested_lan_ipv6=$(ip -6 addr show scope global | grep inet6 | awk '{print $2}' | cut -d/ -f1 | head -n1)

    read -e -i "$suggested_lan_ip" -p "Enter server LAN IP: " SERVER_LAN_IP
    read -e -i "$suggested_lan_ipv6" -p "Enter server LAN IPv6: " SERVER_LAN_IPV6

    __add_to_env "SERVER_LAN_IP" "$SERVER_LAN_IP"
    __add_to_env "SERVER_LAN_IPV6" "$SERVER_LAN_IPV6"
}

# args:
#  - $1 - shadowrocket link
setup_xray() {
    local shadowrocket_link="$1"

    if [ -z "$shadowrocket_link" ]; then
        read -p "Enter VLESS shadowrocket link: " shadowrocket_link
    fi

    local link_body base64_part query_string
    link_body="${shadowrocket_link#vless://}"
    base64_part="${link_body%%\?*}"
    query_string=""
    if [[ "$shadowrocket_link" == *\?* ]]; then
        query_string="${shadowrocket_link#*\?}"
    fi

    local decoded_server_data
    # normalize base64 (URL-safe → standard + fix padding)
    base64_part=$(printf "%s" "$base64_part" | tr '_-' '/+')
    pad=$((4 - ${#base64_part} % 4))
    [ $pad -lt 4 ] && base64_part="${base64_part}$(printf '=%.0s' $(seq 1 $pad))"
    decoded_server_data=$(printf "%s" "$base64_part" | base64 -d 2>/dev/null || true)
    if [ -z "$decoded_server_data" ]; then
        echo "Failed to decode shadowrocket link. Make sure it is valid." >&2
        exit 1
    fi

    decoded_server_data="${decoded_server_data#:}"

    if [[ "$decoded_server_data" != *@*:* ]]; then
        echo "Unexpected server data format in the shadowrocket link: $decoded_server_data" >&2
        exit 1
    fi

    local vless_server_uuid vless_server_address vless_server_port
    vless_server_uuid="${decoded_server_data%%@*}"
    local after_at="${decoded_server_data#*@}"
    vless_server_address="${after_at%:*}"
    vless_server_port="${after_at##*:}"

    local vless_fake_tls_host="" vless_public_key="" vless_short_id=""
    IFS='&' read -ra kv_pairs <<< "$query_string"
    for pair in "${kv_pairs[@]}"; do
        case "$pair" in
            peer=*) vless_fake_tls_host="${pair#peer=}" ;;
            pbk=*) vless_public_key="${pair#pbk=}" ;;
            sid=*) vless_short_id="${pair#sid=}" ;;
        esac
    done
    unset IFS

    if [ -z "$vless_fake_tls_host" ] || [ -z "$vless_public_key" ] || [ -z "$vless_short_id" ]; then
        echo "Shadowrocket link must contain peer, pbk and sid query parameters." >&2
        exit 1
    fi

    echo "Generating WireGuard keys..."
    local wg_private_key wg_public_key wg_peer_private_key wg_peer_public_key wg_listen_port
    wg_private_key=$(wg genkey)
    wg_public_key=$(printf "%s" "$wg_private_key" | wg pubkey)
    wg_peer_private_key=$(wg genkey)
    wg_peer_public_key=$(printf "%s" "$wg_peer_private_key" | wg pubkey)
    wg_listen_port=$(shuf -i 20000-65535 -n 1)

    curl -L -o ./xray-config.json "https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/hommy/xray-config.json" || exit 1

    sed -i \
        -e "s|WG_LISTEN_PORT|${wg_listen_port}|g" \
        -e "s|WG_PRIVATE_KEY|${wg_private_key}|g" \
        -e "s|WG_PEER_PUBLIC_KEY|${wg_peer_public_key}|g" \
        -e "s|VLESS_SERVER_ADDRESS|${vless_server_address}|g" \
        -e "s|VLESS_SERVER_PORT|${vless_server_port}|g" \
        -e "s|VLESS_SERVER_UUID|${vless_server_uuid}|g" \
        -e "s|VLESS_FAKE_TLS_HOST|${vless_fake_tls_host}|g" \
        -e "s|VLESS_PUBLIC_KEY|${vless_public_key}|g" \
        -e "s|VLESS_SHORT_ID|${vless_short_id}|g" ./xray-config.json

    local server_ip
    server_ip=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

    local wg_client_config
    wg_client_config="[Interface]\nPrivateKey = ${wg_peer_private_key}\nAddress = 10.0.0.3/32\nDNS = 1.1.1.1\n\n[Peer]\nPublicKey = ${wg_public_key}\nAllowedIPs = 0.0.0.0/0,::/0\nEndpoint = ${server_ip}:${wg_listen_port}\nPersistentKeepalive = 25"
    __add_to_credentials "WireGuard client config" "$wg_client_config"
}

main() {
    parse_arguments "$@"

    if [ "$SKIP_BOOTSTRAP" = false ]; then
        echo "Bootstrapping system..."
        curl -fsSL https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/bootstrap-system.sh | sh -s --
        install_packages "wireguard"
    else
        echo "Skipping system bootstrap as per argument."
    fi

    echo "Setting up proxy in $PROJECT_DIRECTORY"
    if [ -d "$PROJECT_DIRECTORY" ]; then
        echo "Directory $PROJECT_DIRECTORY already exists. Please choose a different directory or remove it."
        exit 1
    fi
    mkdir -p "$PROJECT_DIRECTORY"
    cd "$PROJECT_DIRECTORY" || exit 1

    curl -L -o ./compose.yaml "https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/hommy/compose.yaml" || exit 1

    curl -L -o ./dnsmasq.conf "https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/hommy/dnsmasq.conf" || exit 1

    ask_for_env_vars

    setup_xray

    printf "$boostrapped_credentials\n"

    printf "$boostrapped_credentials" > credentials.txt
    echo "All credentials have been saved to credentials.txt in the project directory."

    echo "Setup complete! Now run:

    cd $PROJECT_DIRECTORY
    docker compose up -d

to start your hommy."
}

main "$@"
