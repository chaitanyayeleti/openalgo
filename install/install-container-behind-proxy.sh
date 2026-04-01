#!/bin/bash

# OpenAlgo Container Generator (Reverse-Proxy Mode)
# - Non-interactive, env-driven
# - No firewall changes
# - No nginx/certbot setup
# - Supports Docker or Podman runtime
# - Generates runtime .env + docker-compose for Traefik or any reverse proxy

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
    echo -e "${2}${1}${NC}"
}

die() {
    log "Error: $1" "$RED"
    exit 1
}

usage() {
    cat <<'EOF'
OpenAlgo reverse-proxy deployment generator

No environment variables are required to build image only.

Runtime values are required only if START_STACK=true and you are not
providing ENV_FILE_PATH.

Optional environment variables:
  REPO_URL                        (default: https://github.com/marketcalls/openalgo.git)
  INSTALL_PATH                    (default: /opt/openalgo-proxy)
  CONTAINER_RUNTIME               (docker|podman, default: auto-detect)
  OPENALGO_IMAGE_TAG              (default: openalgo:proxy)
    ENV_FILE_PATH                   (path to your runtime env file)
    BROKER_NAME                     (used only when generating env from variables)
    BROKER_API_KEY                  (used only when generating env from variables)
    BROKER_API_SECRET               (used only when generating env from variables)
  DOMAIN                          (example: algo.example.com)
  TLS_TERMINATED                  (true|false, default: true)
  ENABLE_TRAEFIK_LABELS           (true|false, default: false)
  PROXY_NETWORK                   (default: proxy)
  APP_KEY                         (auto-generated if missing)
  API_KEY_PEPPER                  (auto-generated if missing)
  BROKER_API_KEY_MARKET           (required only for XTS brokers)
  BROKER_API_SECRET_MARKET        (required only for XTS brokers)
  BUILD_IMAGE                     (true|false, default: true)
    START_STACK                     (true|false, default: false)
  RECREATE_PROJECT                (true|false, default: false)

Example:
    BUILD_IMAGE=true START_STACK=false \
    ./install-container-behind-proxy.sh

    ENV_FILE_PATH=/path/to/.env \
    START_STACK=true \
  ./install-container-behind-proxy.sh
EOF
}

generate_hex() {
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import secrets; print(secrets.token_hex(32))"
    elif command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32
    else
        die "python3 or openssl is required for secure key generation"
    fi
}

validate_broker() {
    local broker="$1"
    local valid_brokers="fivepaisa,fivepaisaxts,aliceblue,angel,compositedge,definedge,deltaexchange,dhan,dhan_sandbox,firstock,flattrade,fyers,groww,ibulls,iifl,indmoney,jainamxts,kotak,motilal,mstock,nubra,paytm,pocketful,rmoney,samco,shoonya,tradejini,upstox,wisdom,zebu,zerodha"
    [[ ",$valid_brokers," == *",$broker,"* ]]
}

is_xts_broker() {
    local broker="$1"
    local xts_brokers="fivepaisaxts,compositedge,ibulls,iifl,jainamxts,rmoney,wisdom"
    [[ ",$xts_brokers," == *",$broker,"* ]]
}

is_true() {
    local value="${1:-false}"
    [[ "$value" =~ ^([Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]|[Yy])$ ]]
}

escape_sed_replacement() {
    echo "$1" | sed -e 's/[\\&|]/\\\\&/g'
}

update_env_value() {
    local file="$1"
    local key="$2"
    local value="$3"
    local escaped
    escaped=$(escape_sed_replacement "$value")
    sed -i "s|^${key}[[:space:]]*=.*|${key} = '${escaped}'|" "$file"
}

append_domain_to_cors() {
    local file="$1"
    local domain_url="$2"
    local current
    current=$(grep "^CORS_ALLOWED_ORIGINS" "$file" | sed "s/^[^']*'\(.*\)'/\1/")

    if [[ ",$current," == *",$domain_url,"* ]]; then
        return 0
    fi

    if [ -n "$current" ]; then
        local merged
        merged=$(printf "%s\n%s\n" "$current" "$domain_url" | tr ',' '\n' | sed '/^$/d' | sort -u | paste -sd, -)
        update_env_value "$file" "CORS_ALLOWED_ORIGINS" "$merged"
    else
        update_env_value "$file" "CORS_ALLOWED_ORIGINS" "$domain_url"
    fi
}

detect_runtime() {
    local runtime="${CONTAINER_RUNTIME:-auto}"

    if [ "$runtime" = "docker" ]; then
        ENGINE="docker"
    elif [ "$runtime" = "podman" ]; then
        ENGINE="podman"
    else
        if command -v docker >/dev/null 2>&1; then
            ENGINE="docker"
        elif command -v podman >/dev/null 2>&1; then
            ENGINE="podman"
        else
            die "Neither docker nor podman was found. Install one runtime and retry."
        fi
    fi

    if [ "$ENGINE" = "docker" ]; then
        if docker compose version >/dev/null 2>&1; then
            COMPOSE_CMD=(docker compose)
        elif command -v docker-compose >/dev/null 2>&1; then
            COMPOSE_CMD=(docker-compose)
        else
            die "Docker Compose is required (docker compose or docker-compose)."
        fi
    else
        if podman compose version >/dev/null 2>&1; then
            COMPOSE_CMD=(podman compose)
        elif command -v podman-compose >/dev/null 2>&1; then
            COMPOSE_CMD=(podman-compose)
        else
            die "Podman Compose is required (podman compose or podman-compose)."
        fi
    fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

REPO_URL="${REPO_URL:-https://github.com/marketcalls/openalgo.git}"
INSTALL_PATH="${INSTALL_PATH:-/opt/openalgo-proxy}"
OPENALGO_IMAGE_TAG="${OPENALGO_IMAGE_TAG:-openalgo:proxy}"
ENV_FILE_PATH="${ENV_FILE_PATH:-}"
BROKER_NAME="${BROKER_NAME:-}"
BROKER_API_KEY="${BROKER_API_KEY:-}"
BROKER_API_SECRET="${BROKER_API_SECRET:-}"
DOMAIN="${DOMAIN:-}"
TLS_TERMINATED="${TLS_TERMINATED:-true}"
ENABLE_TRAEFIK_LABELS="${ENABLE_TRAEFIK_LABELS:-false}"
PROXY_NETWORK="${PROXY_NETWORK:-proxy}"
BUILD_IMAGE="${BUILD_IMAGE:-true}"
START_STACK="${START_STACK:-false}"
RECREATE_PROJECT="${RECREATE_PROJECT:-false}"
SCRIPT_CWD="$(pwd)"
ENV_FILE_PATH_RESOLVED=""

if [ -n "$BROKER_NAME" ] && ! validate_broker "$BROKER_NAME"; then
    die "Invalid BROKER_NAME '$BROKER_NAME'."
fi

if [ -n "$BROKER_NAME" ] && is_xts_broker "$BROKER_NAME"; then
    : "${BROKER_API_KEY_MARKET:?BROKER_API_KEY_MARKET is required for XTS brokers.}"
    : "${BROKER_API_SECRET_MARKET:?BROKER_API_SECRET_MARKET is required for XTS brokers.}"
fi

if is_true "$START_STACK" && [ -z "$ENV_FILE_PATH" ] && { [ -z "$BROKER_NAME" ] || [ -z "$BROKER_API_KEY" ] || [ -z "$BROKER_API_SECRET" ]; }; then
    die "For START_STACK=true, provide ENV_FILE_PATH or set BROKER_NAME/BROKER_API_KEY/BROKER_API_SECRET."
fi

if [ -n "$ENV_FILE_PATH" ]; then
    if [[ "$ENV_FILE_PATH" = /* ]]; then
        ENV_FILE_PATH_RESOLVED="$ENV_FILE_PATH"
    else
        ENV_FILE_PATH_RESOLVED="$SCRIPT_CWD/$ENV_FILE_PATH"
    fi
    [ -f "$ENV_FILE_PATH_RESOLVED" ] || die "ENV_FILE_PATH does not exist: $ENV_FILE_PATH"
fi

APP_KEY="${APP_KEY:-}"
API_KEY_PEPPER="${API_KEY_PEPPER:-}"

if [ -z "$ENV_FILE_PATH" ] && [ -n "$BROKER_NAME" ]; then
    APP_KEY="${APP_KEY:-$(generate_hex)}"
    API_KEY_PEPPER="${API_KEY_PEPPER:-$(generate_hex)}"
fi

detect_runtime
log "Detected runtime: $ENGINE" "$BLUE"
log "Compose command: ${COMPOSE_CMD[*]}" "$BLUE"

if [ -d "$INSTALL_PATH/.git" ] && ! is_true "$RECREATE_PROJECT"; then
    log "Using existing project at $INSTALL_PATH" "$BLUE"
    git -C "$INSTALL_PATH" pull --ff-only || die "Failed to update existing repository"
else
    if [ -d "$INSTALL_PATH" ]; then
        rm -rf "$INSTALL_PATH"
    fi
    git clone "$REPO_URL" "$INSTALL_PATH"
fi

cd "$INSTALL_PATH"

mkdir -p log logs keys db strategies/scripts strategies/examples tmp
chmod 700 keys

RUNTIME_ENV_FILE=".env.runtime"
COMPOSE_FILE="docker-compose.proxy.yaml"
INSTANCE_ID=$(basename "$INSTALL_PATH" | tr -cs 'a-zA-Z0-9' '-')

if [ -n "$ENV_FILE_PATH_RESOLVED" ]; then
    cp "$ENV_FILE_PATH_RESOLVED" "$RUNTIME_ENV_FILE"
else
    cp .sample.env "$RUNTIME_ENV_FILE"

    if [ -n "$BROKER_NAME" ]; then
        update_env_value "$RUNTIME_ENV_FILE" "BROKER_API_KEY" "$BROKER_API_KEY"
        update_env_value "$RUNTIME_ENV_FILE" "BROKER_API_SECRET" "$BROKER_API_SECRET"
        update_env_value "$RUNTIME_ENV_FILE" "APP_KEY" "$APP_KEY"
        update_env_value "$RUNTIME_ENV_FILE" "API_KEY_PEPPER" "$API_KEY_PEPPER"
    fi

    update_env_value "$RUNTIME_ENV_FILE" "FLASK_HOST_IP" "0.0.0.0"
    update_env_value "$RUNTIME_ENV_FILE" "WEBSOCKET_HOST" "0.0.0.0"
    update_env_value "$RUNTIME_ENV_FILE" "ZMQ_HOST" "0.0.0.0"

    if [ -n "$BROKER_NAME" ] && is_xts_broker "$BROKER_NAME"; then
        update_env_value "$RUNTIME_ENV_FILE" "BROKER_API_KEY_MARKET" "$BROKER_API_KEY_MARKET"
        update_env_value "$RUNTIME_ENV_FILE" "BROKER_API_SECRET_MARKET" "$BROKER_API_SECRET_MARKET"
    fi
fi

if [ -n "$DOMAIN" ]; then
    if is_true "$TLS_TERMINATED"; then
        PUBLIC_SCHEME="https"
        WS_SCHEME="wss"
    else
        PUBLIC_SCHEME="http"
        WS_SCHEME="ws"
    fi

    update_env_value "$RUNTIME_ENV_FILE" "HOST_SERVER" "${PUBLIC_SCHEME}://${DOMAIN}"
    if [ -n "$BROKER_NAME" ]; then
        update_env_value "$RUNTIME_ENV_FILE" "REDIRECT_URL" "${PUBLIC_SCHEME}://${DOMAIN}/${BROKER_NAME}/callback"
    fi
    update_env_value "$RUNTIME_ENV_FILE" "WEBSOCKET_URL" "${WS_SCHEME}://${DOMAIN}/ws"

    append_domain_to_cors "$RUNTIME_ENV_FILE" "${PUBLIC_SCHEME}://${DOMAIN}"

    sed -i '/^CSP_CONNECT_SRC/d' "$RUNTIME_ENV_FILE"
    echo "CSP_CONNECT_SRC = \"'self' wss: ws: https://cdn.socket.io ${PUBLIC_SCHEME}://${DOMAIN} ${WS_SCHEME}://${DOMAIN}\"" >> "$RUNTIME_ENV_FILE"
fi

TOTAL_RAM_MB=$(($(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024))
CPU_CORES=$(nproc 2>/dev/null || echo 2)

SHM_SIZE_MB=$((TOTAL_RAM_MB / 4))
[ "$SHM_SIZE_MB" -lt 256 ] && SHM_SIZE_MB=256
[ "$SHM_SIZE_MB" -gt 2048 ] && SHM_SIZE_MB=2048

if [ "$TOTAL_RAM_MB" -lt 3000 ]; then
    THREAD_LIMIT=1
elif [ "$TOTAL_RAM_MB" -lt 6000 ]; then
    THREAD_LIMIT=2
else
    THREAD_LIMIT=$((CPU_CORES < 4 ? CPU_CORES : 4))
fi

if [ "$TOTAL_RAM_MB" -lt 3000 ]; then
    STRATEGY_MEM_LIMIT=256
elif [ "$TOTAL_RAM_MB" -lt 6000 ]; then
    STRATEGY_MEM_LIMIT=512
else
    STRATEGY_MEM_LIMIT=1024
fi

cat > "$COMPOSE_FILE" <<EOF
services:
  openalgo:
    image: ${OPENALGO_IMAGE_TAG}
    build:
      context: .
      dockerfile: Dockerfile

    container_name: openalgo-${INSTANCE_ID}

    expose:
      - "5000"
      - "8765"

    env_file:
      - ./${RUNTIME_ENV_FILE}

    volumes:
      - openalgo_db:/app/db
      - openalgo_log:/app/log
      - openalgo_strategies:/app/strategies
      - openalgo_keys:/app/keys
      - openalgo_tmp:/app/tmp
      - ./${RUNTIME_ENV_FILE}:/app/.env:ro

    environment:
      - FLASK_ENV=production
      - FLASK_DEBUG=0
      - APP_MODE=standalone
      - TZ=Asia/Kolkata
      - OPENBLAS_NUM_THREADS=${THREAD_LIMIT}
      - OMP_NUM_THREADS=${THREAD_LIMIT}
      - MKL_NUM_THREADS=${THREAD_LIMIT}
      - NUMEXPR_NUM_THREADS=${THREAD_LIMIT}
      - NUMBA_NUM_THREADS=${THREAD_LIMIT}
      - STRATEGY_MEMORY_LIMIT_MB=${STRATEGY_MEM_LIMIT}

    shm_size: '${SHM_SIZE_MB}m'

    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:5000/auth/check-setup"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

    restart: unless-stopped

    networks:
      - openalgo_internal
      - ${PROXY_NETWORK}
EOF

if is_true "$ENABLE_TRAEFIK_LABELS"; then
    [ -n "$DOMAIN" ] || die "DOMAIN is required when ENABLE_TRAEFIK_LABELS=true"

    cat >> "$COMPOSE_FILE" <<EOF

    labels:
      - traefik.enable=true
      - traefik.docker.network=${PROXY_NETWORK}
      - traefik.http.routers.openalgo-${INSTANCE_ID}.rule=Host(\`${DOMAIN}\`)
      - traefik.http.routers.openalgo-${INSTANCE_ID}.entrypoints=websecure
      - traefik.http.routers.openalgo-${INSTANCE_ID}.service=openalgo-${INSTANCE_ID}
      - traefik.http.services.openalgo-${INSTANCE_ID}.loadbalancer.server.port=5000
      - traefik.http.routers.openalgo-ws-${INSTANCE_ID}.rule=Host(\`${DOMAIN}\`) && PathPrefix(\`/ws\`)
      - traefik.http.routers.openalgo-ws-${INSTANCE_ID}.entrypoints=websecure
      - traefik.http.routers.openalgo-ws-${INSTANCE_ID}.service=openalgo-ws-${INSTANCE_ID}
      - traefik.http.services.openalgo-ws-${INSTANCE_ID}.loadbalancer.server.port=8765
EOF
fi

cat >> "$COMPOSE_FILE" <<EOF

volumes:
  openalgo_db:
    driver: local
  openalgo_log:
    driver: local
  openalgo_strategies:
    driver: local
  openalgo_keys:
    driver: local
  openalgo_tmp:
    driver: local

networks:
  openalgo_internal:
    driver: bridge
  ${PROXY_NETWORK}:
    external: true
EOF

if [ "$ENGINE" = "docker" ]; then
    docker network inspect "$PROXY_NETWORK" >/dev/null 2>&1 || docker network create "$PROXY_NETWORK" >/dev/null
else
    podman network inspect "$PROXY_NETWORK" >/dev/null 2>&1 || podman network create "$PROXY_NETWORK" >/dev/null
fi

if is_true "$BUILD_IMAGE"; then
    log "Building image with ${COMPOSE_CMD[*]}..." "$BLUE"
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" build
else
    log "Skipping build because BUILD_IMAGE=false" "$YELLOW"
fi

if is_true "$START_STACK"; then
    log "Starting stack with ${COMPOSE_CMD[*]}..." "$BLUE"
    "${COMPOSE_CMD[@]}" -f "$COMPOSE_FILE" up -d
else
    log "Skipping startup because START_STACK=false" "$YELLOW"
fi

log "Generation complete." "$GREEN"
log "Project path: $INSTALL_PATH" "$BLUE"
log "Runtime env file: $INSTALL_PATH/$RUNTIME_ENV_FILE" "$BLUE"
log "Compose file: $INSTALL_PATH/$COMPOSE_FILE" "$BLUE"
log "Image tag: $OPENALGO_IMAGE_TAG" "$BLUE"

if [ -n "$DOMAIN" ]; then
    if is_true "$TLS_TERMINATED"; then
        log "Expected public URL: https://$DOMAIN" "$GREEN"
    else
        log "Expected public URL: http://$DOMAIN" "$GREEN"
    fi
fi

log "Useful commands:" "$YELLOW"
log "  ${COMPOSE_CMD[*]} -f $COMPOSE_FILE logs -f" "$BLUE"
log "  ${COMPOSE_CMD[*]} -f $COMPOSE_FILE restart" "$BLUE"
log "  ${COMPOSE_CMD[*]} -f $COMPOSE_FILE up -d" "$BLUE"
