#!/bin/bash

set -e

# SCHEME FOR .env file:
#
# SERVER_DOMAIN=vpn.example.com
# SERVER_IP=123.45.678.90
#
# MTPROTO_PORT=443
# MTPROTO_SECRET=ee...
#
# VLESS_PORT=8443
#
# PROXY_USERNAME=some_random_username
# PROXY_PASSWORD=some_random_password
# PROXY_SOCKS5_PORT=1080
# PROXY_HTTTP_PORT=8080
#
# XRAY_SUBNET=
# XRAY_IP=
# CONTAINER_POSTFIX=

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

# Script generates mtproto secret based on fake domain for fake tls.
# Args:
#  $1 - fake domain for fake tls
# Output:
#  mtproto secret for fake tls
generate_mtproto_secret() {
    local fake_domain="$1"

    if [ -z "$fake_domain" ]; then
        return 1
    fi

    local domain_hex random_hex needed secret
    domain_hex=$(printf '%s' "$fake_domain" | xxd -ps | tr -d '\n')

    if [ "${#domain_hex}" -gt 30 ]; then
        domain_hex=${domain_hex:0:30}
    fi

    needed=$((30 - ${#domain_hex}))
        if [ "$needed" -gt 0 ]; then
            random_hex=$(openssl rand -hex 16 | head -c "$needed")
        else
            random_hex=""
        fi

        secret="ee${domain_hex}${random_hex}"

        echo "$secret"
    }

# Asks user for fake domain for mtproto, generates secret,
# adds secret and mtproto port to .env file,
# gererates credentials string in this format:
#    https://t.me/proxy?server=<server-domain>&port=<mt-proto-port>&secret=<generated-secret>
# and adds it to credentials string to print at the end.
# Args:
#  $1 - server domain
#  $2 - mtproto port
bootstrap_mtproto() {
    echo "Bootstrapping MTProto proxy..."

    local server_domain="$1"
    local mtproto_port="$2"
    local fake_domain mtproto_secret

    if [ -z "$server_domain" ] || [ -z "$mtproto_port" ]; then
        return 1
    fi

    printf "Enter fake domain for MTProto (used for Fake TLS): "
    read -r fake_domain

    mtproto_secret=$(generate_mtproto_secret "$fake_domain") || return 1

    __add_to_env "MTPROTO_PORT" "$mtproto_port"
    __add_to_env "MTPROTO_SECRET" "$mtproto_secret"

    local credentials
    credentials="https://t.me/proxy?server=${server_domain}&port=${mtproto_port}&secret=${mtproto_secret}"
    __add_to_credentials "MTProto (telegram-proxy)" "$credentials"
}

generate_xray_short_id() {
    openssl rand -hex 8
}

generate_xray_uuid() {
    uuidgen --time-v7
}

# outputs private key, public key and hash32 for x25519 in this format:
# <private_key> <public_key> <hash32>
generate_x25519_key_pair() {
    local data
    data=$(docker run --rm ghcr.io/xtls/xray-core x25519)

    # data contains something like:
    # 
    # PrivateKey: -AB-FsyY-Bxf1Y9FsTBDrBC-RSa2wKgJ3Jfk-Ev1oVs
    # Password (PublicKey): I8dJ46slbzxLouqc5IaDT5iOtmZ9uqptEWa_dsCP6HM
    # Hash32: 91M-4YOEUz3HSsReTeHwMbWdNPEYIm75zaap94wz1Pw
    #
    # We need to extract private and public keys from this output.

    local private_key public_key hash32
    private_key=$(echo "$data" | grep "PrivateKey:" | awk '{print $2}')
    public_key=$(echo "$data" | grep "Password (PublicKey):" | awk '{print $3}')
    hash32=$(echo "$data" | grep "Hash32:" | awk '{print $2}')

    echo "$private_key" "$public_key" "$hash32"
}

# args:
# $1 - server domain
# $2 - vless port
#
# Script generates xray-config.json file
generate_xray_config() {
    echo "Generating xray config for VLESS..."

    local server_domain="$1"
    local vless_port="$2"
    local vless_listen_ip="$3"

    local fake_domain private_key public_key hash32 uuid short_id

    printf "Enter fake domain for VLESS (used for Fake TLS): "
    read -r fake_domain
    read -r private_key public_key hash32 < <(generate_x25519_key_pair)
    uuid=$(generate_xray_uuid)
    short_id=$(generate_xray_short_id)

    curl -L -o ./xray-config.json "https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/proxy/xray-config.json" || exit 1

    sed -i \
        -e "s|VLESS_LISTEN_IP|${vless_listen_ip}|g" \
        -e "s|VLESS_PORT|${vless_port}|g" \
        -e "s|VLESS_CLIENT_UUID|${uuid}|g" \
        -e "s|VLESS_FAKE_DOMAIN|${fake_domain}|g" \
        -e "s|VLESS_SERVER_DOMAIN|${server_domain}|g" \
        -e "s|VLESS_PRIVATE_KEY|${private_key}|g" \
        -e "s|VLESS_SHORT_ID|${short_id}|g" ./xray-config.json

    __add_to_env "VLESS_PORT" "$vless_port"

    # generate url with following format:
    # vless://OjAxOWQ0ZWUxLWFmMzItN2E3Mi1hYjNlLWE2ZmM4N2UwNzI5OEBmbC52cG4udGlraG9ubm5ubi5jb206MTAyMzc?tls=1&peer=yandex.ru&allowInsecure=1&xtls=2&pbk=aW6sys6gClRliMAu-GeWXyQ0ND6ndsiJ5POeILE30hs&sid=7e160f7da913b19a

    # :019d4ee1-af32-7a72-ab3e-a6fc87e07298@fl.vpn.tikhonnnn.com:10237
    local server_data server_data_encoded_base64
    server_data=":${uuid}@${server_domain}:${vless_port}"
    server_data_encoded_base64=$(printf "%s" "$server_data" | base64 -w 0)

    local vless_credentials
    vless_credentials="vless://${server_data_encoded_base64}?tls=1&peer=${fake_domain}&allowInsecure=1&xtls=2&pbk=${public_key}&sid=${short_id}"
    __add_to_credentials "VLESS (xray) shadowrocket url:" "$vless_credentials"

    local vless_raw_credentials
    vless_raw_credentials="server: ${server_domain}\nport: ${vless_port}\nuuid: ${uuid}\nfake domain for fake tls: ${fake_domain}\npublic key for x25519: ${public_key}\nshort id for xray: ${short_id}"
    __add_to_credentials "VLESS (raw parameters)" "$vless_raw_credentials"
}

# args:
# $1 - server domain
# $2 - socks5 port
# $2 - http port
setup_proxy() {
    echo "Setting up HTTP/SOCKS5 proxy with authentication..."

    local server_domain="$1"
    local socks5_port="$2"
    local http_port="$3"

    local username password
    username=$(openssl rand -hex 8)
    password=$(openssl rand -hex 16)

    __add_to_env "PROXY_USERNAME" "$username"
    __add_to_env "PROXY_PASSWORD" "$password"
    __add_to_env "PROXY_SOCKS5_PORT" "$socks5_port"
    __add_to_env "PROXY_HTTP_PORT" "$http_port"

    local socks5_credentials
    socks5_credentials="socks5://${username}:${password}@${server_domain}:${socks5_port}"
    __add_to_credentials "SOCKS5 proxy" "$socks5_credentials"

    local http_credentials
    http_credentials="http://${username}:${password}@${server_domain}:${http_port}"
    __add_to_credentials "HTTP proxy" "$http_credentials"
}

SERVER_DOMAIN=""
SERVER_IP=""

# Asks user for server domain and ip, adds them to .env file.
# Also stores them in global variables for later use.
ask_for_server_domain_and_ip() {
    local suggested_public_ip
    suggested_public_ip=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

    printf "Seems like your server's public IP as: %s\n" "$suggested_public_ip"

    printf "Enter server domain or public ip (e.g. vpn.example.com): "
    read -r SERVER_DOMAIN

    read -e -i "$suggested_public_ip" -p "Enter server public IP: " SERVER_IP

    __add_to_env "SERVER_DOMAIN" "$SERVER_DOMAIN"
    __add_to_env "SERVER_IP" "$SERVER_IP"
}

MTPROTO_PORT=
VLESS_PORT=
SOCKS5_PORT=
HTTP_PORT=

generate_random_ports() {
    echo "Generating random ports for MTProto, VLESS, SOCKS5 and HTTP..."

    ports=($(shuf -i 20000-65535 -n 4))

    MTPROTO_PORT=${ports[0]}
    VLESS_PORT=${ports[1]}
    SOCKS5_PORT=${ports[2]}
    HTTP_PORT=${ports[3]}
}

XRAY_SUBNET=""
XRAY_IP=""
CONTAINER_POSTFIX=""

generate_random_subnet_and_ip() {
    local subnet_octet host_octet

    subnet_octet=$(shuf -i 16-31 -n 1)
    host_octet=$(shuf -i 2-254 -n 1)

    XRAY_SUBNET="172.${subnet_octet}.0.0/16"
    XRAY_IP="172.${subnet_octet}.0.${host_octet}"

    __add_to_env "XRAY_SUBNET" "$XRAY_SUBNET"
    __add_to_env "XRAY_IP" "$XRAY_IP"
}

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

main() {
    parse_arguments "$@"

    generate_random_ports

    if [ "$SKIP_BOOTSTRAP" = false ]; then
        echo "Bootstrapping system..."
        curl -fsSL https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/bootstrap-system.sh | sh -s --
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

    generate_random_subnet_and_ip
    generate_container_postfix

    curl -L -o ./compose.yaml "https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/proxy/compose.yaml" || exit 1

    ask_for_server_domain_and_ip

    bootstrap_mtproto "$SERVER_DOMAIN" "$MTPROTO_PORT"

    generate_xray_config "$SERVER_DOMAIN" "$VLESS_PORT" "$XRAY_IP"

    setup_proxy "$SERVER_DOMAIN" "$SOCKS5_PORT" "$HTTP_PORT"

    printf "$boostrapped_credentials\n"

    printf "$boostrapped_credentials" > credentials.txt
    echo "All credentials have been saved to credentials.txt in the project directory."

    echo "Setup complete! Now run:

    cd $PROJECT_DIRECTORY
    docker compose up -d

to start your proxy."
}

main "$@"
