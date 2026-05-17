#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

status_file="var/meta/status.json"

read_env(){
  awk -F= -v key="$1" '$1==key{print substr($0, index($0,"=")+1)}' .env 2>/dev/null | tr -d '\r' | tail -n 1
}

http_port="$(read_env HOST_PORT_HTTP)"
https_port="$(read_env HOST_PORT_HTTPS)"
http_port="${http_port:-80}"
https_port="${https_port:-443}"

payload=""
if command -v curl >/dev/null 2>&1; then
  payload="$(curl -fsS "http://localhost:${http_port}/_status" 2>/dev/null || true)"
  if [ -z "$payload" ]; then
    payload="$(curl -kfsS "https://localhost:${https_port}/_status" 2>/dev/null || true)"
  fi
fi

if [ -z "$payload" ] && [ -f "$status_file" ]; then
  payload="$(cat "$status_file")"
fi

if [ -z "$payload" ]; then
  echo "[geodock_status] Aucun statut disponible." >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  echo "$payload" | jq -r '
    "Etat      : \(.state)\nMode      : \(.mode)\nUpstream  : \(.upstream_active)\nScope     : \(.scope)\nEtape     : \(.current_step)\nProgress  : \(.progress.percent)% (\(.progress.current)/\(.progress.total))\nLocal     : address=\(.local_ready.address) parcel=\(.local_ready.parcel) poi=\(.local_ready.poi) api=\(.local_ready.api)\nMaj OK    : \(.last_successful_update_at // "n/a")\nErreur    : \(.last_error // "aucune")"'
else
  echo "$payload"
fi
