#!/usr/bin/env bash
set -euo pipefail

# Health verification (proxy mode)

read_env(){
  awk -F= -v key="$1" '$1==key{print substr($0, index($0,"=")+1)}' .env 2>/dev/null | tr -d '\r' | tail -n 1
}

HOST_PORT_HTTP="$(read_env HOST_PORT_HTTP)"
HOST_PORT_HTTPS="$(read_env HOST_PORT_HTTPS)"
HOST_PORT_HTTP="${HOST_PORT_HTTP:-80}"
HOST_PORT_HTTPS="${HOST_PORT_HTTPS:-443}"

BASE_HTTP="http://localhost:${HOST_PORT_HTTP}"
BASE_HTTPS="https://localhost:${HOST_PORT_HTTPS}"

curl_opts=(--max-time 5 -sS -L)

echo "[verify] GET ${BASE_HTTP}/_health"
curl "${curl_opts[@]}" -D - -o - "${BASE_HTTP}/_health" || true
echo

echo "[verify] GET ${BASE_HTTP}/search/?q=8%20bd%20du%20port,%20nanterre&limit=1"
curl "${curl_opts[@]}" -D - -o - "${BASE_HTTP}/search/?q=8%20bd%20du%20port,%20nanterre&limit=1" | head -n 40 || true
echo

echo "[verify] GET ${BASE_HTTPS}/_health (insecure)"
curl -k "${curl_opts[@]}" -D - -o - "${BASE_HTTPS}/_health" || true
echo

echo "[verify] Done"
