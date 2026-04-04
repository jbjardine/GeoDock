#!/usr/bin/env bash
set -euo pipefail

BASE="${BASE:-http://localhost}"
QUERY="${QUERY:-/search/?q=paris&limit=1}"
INSECURE_SSL="${INSECURE_SSL:-0}"

curl_args=(--max-time 10 -sS -L -D -)
if [ "${INSECURE_SSL}" = "1" ]; then
  curl_args=(-k "${curl_args[@]}")
fi

echo "[mode_verify] GET ${BASE}/_health"
curl "${curl_args[@]}" -o - "${BASE}/_health" || true
echo

echo "[mode_verify] GET ${BASE}${QUERY}"
curl "${curl_args[@]}" -o - "${BASE}${QUERY}" | head -n 60 || true
echo
