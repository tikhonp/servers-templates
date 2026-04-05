#!/bin/sh

set -e

# SCHEME FOR .env file:
#
# SERVER_DOMAIN=vpn.example.com
# SERVER_IP=123.45.678.90
#
# MTPROTO_PORT=443
# MTPROTO_SECRET=ee...

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

SERVER_DOMAIN=""
SERVER_IP=""

# Asks user for server domain and ip, adds them to .env file.
# Also stores them in global variables for later use.
ask_for_server_domain_and_ip() {
    local suggested_public_ip
    suggested_public_ip=$(ip -4 addr show scope global | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)

    printf "Enter server domain or public ip (e.g. vpn.example.com or 123.45.678.90): "
    read -r SERVER_DOMAIN

    printf "Enter server public IP (suggested: %s): " "$suggested_public_ip"
    read -r SERVER_IP

    __add_to_env "SERVER_DOMAIN" "$SERVER_DOMAIN"
    __add_to_env "SERVER_IP" "$SERVER_IP"
}

MTPROTO_PORT=
VLESS_PORT=
SOCKS5_PORT=

generate_random_ports() {
    MTPROTO_PORT=$(shuf -i 20000-65535 -n 1)
    VLESS_PORT=$(shuf -i 20000-65535 -n 1)
    SOCKS5_PORT=$(shuf -i 20000-65535 -n 1)

    # Ensure ports are unique
    while [ "$VLESS_PORT" = "$MTPROTO_PORT" ] || [ "$VLESS_PORT" = "$SOCKS5_PORT" ]; do
        VLESS_PORT=$(shuf -i 20000-65535 -n 1)
    done

    while [ "$SOCKS5_PORT" = "$MTPROTO_PORT" ] || [ "$SOCKS5_PORT" = "$VLESS_PORT" ]; do
        SOCKS5_PORT=$(shuf -i 20000-65535 -n 1)
    done
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

    generate_random_ports
}

main() {
    parse_arguments "$@"

    if [ "$SKIP_BOOTSTRAP" = false ]; then
        echo "Bootstrapping system..."
        curl -fsSL https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/bootstrap-system.sh | sh -s --
    else
        echo "Skipping system bootstrap as per argument."
    fi

    echo "Setting up proxy in $PROJECT_DIRECTORY"
    mkdir -p "$PROJECT_DIRECTORY"
    cd "$PROJECT_DIRECTORY" || exit 1

    curl -L -o ./compose.yaml "https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/proxy/compose.yaml" || exit 1

    ask_for_server_domain_and_ip

    # here we can add more bootstrapping functions for other services if needed
    bootstrap_mtproto "$SERVER_DOMAIN" "$MTPROTO_PORT"

    printf "$boostrapped_credentials\n"

    echo "Setup complete! Now run:

    cd $PROJECT_DIRECTORY
    docker compose up -d

to start your proxy."
}

main "$@"
