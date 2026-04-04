#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[unified_up] ERROR: docker not found in PATH" >&2
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
  echo "[unified_up] Created .env from .env.example"
fi

mode=$(awk -F= '$1=="MODE"{print $2}' .env | tr -d '\r' | tail -n 1)
mode=${mode:-hybrid}

if [ "${mode}" != "remote" ] && [ "${mode}" != "proxy" ]; then
  for key in ADDRESS_ARCHIVE_URL PARCEL_ARCHIVE_URL POI_ARCHIVE_URL ADDRESS_ARCHIVE_URL_RESOLVER PARCEL_ARCHIVE_URL_RESOLVER POI_ARCHIVE_URL_RESOLVER; do
    grep -Eq "^${key}=" .env || echo "${key}=" >> .env
  done
fi

echo "[unified_up] MODE=${mode}"

compose_args=(-f docker-compose.yml -f docker-compose.git.yml up -d --build)
case "${mode}" in
  local|hybrid|failback)
    compose_args=( -f docker-compose.yml -f docker-compose.git.yml --profile local up -d --build )
    ;;
esac

docker compose "${compose_args[@]}"

echo "[unified_up] Stack starting. Use scripts/mode_verify.sh to validate the active mode."
