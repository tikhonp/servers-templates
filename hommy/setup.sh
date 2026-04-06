#!/bin/bash

set -e

# SCHEME FOR .env file:
#
# TS_AUTHKEY=your_ts_authkey
# NODE_NAME=your_node_name
# HTTP_PROXY=http://your_proxy:port
# HTTPS_PROXY=http://your_proxy:port

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
    read -p "Enter NODE_NAME: " NODE_NAME
    read -p "Enter HTTP_PROXY: " HTTP_PROXY

    __add_to_env "TS_AUTHKEY" "$TS_AUTHKEY"
    __add_to_env "NODE_NAME" "$NODE_NAME"
    __add_to_env "HTTP_PROXY" "$HTTP_PROXY"
    __add_to_env "HTTPS_PROXY" "$HTTP_PROXY"
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

    curl -L -o ./compose.yaml "https://raw.githubusercontent.com/tikhonp/servers-templates/refs/heads/master/hommy/compose.yaml" || exit 1

    ask_for_env_vars

    printf "$boostrapped_credentials\n"

    printf "$boostrapped_credentials" > credentials.txt
    echo "All credentials have been saved to credentials.txt in the project directory."

    echo "Setup complete! Now run:

    cd $PROJECT_DIRECTORY
    docker compose up -d

to start your hommy."
}

main "$@"
