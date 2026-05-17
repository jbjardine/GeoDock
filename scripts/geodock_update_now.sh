#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

mode="$(awk -F= '$1=="MODE"{print substr($0, index($0,"=")+1)}' .env 2>/dev/null | tr -d '\r' | tail -n 1)"
mode="${mode:-hybrid}"
if [ "$mode" = "proxy" ] || [ "$mode" = "remote" ]; then
  echo "[geodock_update_now] MODE=${mode}: aucune mise a jour locale a lancer."
  exit 0
fi

docker compose -f docker-compose.yml -f docker-compose.git.yml --profile local exec -T local-maintainer \
  python /opt/geodock-runtime/scripts/local_maintainer.py refresh-once

echo "[geodock_update_now] Mise a jour locale terminee."
