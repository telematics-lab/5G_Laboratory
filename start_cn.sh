#!/bin/bash

# Wrapper for docker-compose_cn.yaml
# Passes .env.cn to Docker Compose for YAML-level variable substitution
# (${AMF_IP}, ${TEST_NETWORK}, etc.)
#
# Usage:
#   ./start_cn.sh up -d          # start all CN services
#   ./start_cn.sh up -d amf smf  # start specific services
#   ./start_cn.sh down           # stop and remove containers
#   ./start_cn.sh ps             # show status
#   ./start_cn.sh logs -f amf    # follow AMF logs

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env.cn"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose_cn.yaml"

if [ ! -f "$ENV_FILE" ]; then
    echo -e "\033[0;31mError: $ENV_FILE not found.\033[0m"
    exit 1
fi

if [ ! -f "$COMPOSE_FILE" ]; then
    echo -e "\033[0;31mError: $COMPOSE_FILE not found.\033[0m"
    exit 1
fi

exec docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
