#!/usr/bin/env bash
set -euo pipefail

# Proxy bring-up (MODE=remote)
# - Creates .env if missing (from .env.proxy.example or .env.example)
# - Forces MODE=remote and SERVER_NAME=$(hostname -f)
# - Builds and starts proxy service only

UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
UNAME_M="$(uname -m 2>/dev/null || echo unknown)"
if [ "${UNAME_S}" != "Linux" ] || ! echo "${UNAME_M}" | grep -Eq 'x86_64|amd64'; then
  echo "[proxy_up] WARNING: intended for Linux x86_64. Current: ${UNAME_S}/${UNAME_M}" >&2
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[proxy_up] ERROR: docker not found in PATH" >&2
  exit 1
fi

# Ensure .env exists
if [ ! -f .env ]; then
  if [ -f .env.proxy.example ]; then
    cp .env.proxy.example .env
  elif [ -f .env.example ]; then
    cp .env.example .env
  else
    echo "[proxy_up] ERROR: missing .env and no example found (.env.proxy.example or .env.example)" >&2
    exit 1
  fi
fi

# Force minimal config for proxy mode
HOSTNAME_FQDN=$(hostname -f 2>/dev/null || hostname)
sed -i \
  -e 's/^MODE=.*/MODE=remote/' \
  -e "s/^SERVER_NAME=.*/SERVER_NAME=${HOSTNAME_FQDN}/" \
  .env || true

echo "[proxy_up] MODE=remote SERVER_NAME=${HOSTNAME_FQDN}"

COMPOSE_FILE="docker-compose.proxy.yml"
if [ ! -f "$COMPOSE_FILE" ]; then COMPOSE_FILE="docker-compose.yml"; fi
docker compose -f "$COMPOSE_FILE" up -d --build proxy

echo "[proxy_up] Proxy starting (compose: $COMPOSE_FILE). Run scripts/proxy_verify.sh to validate."
