#!/usr/bin/env bash
set -euo pipefail

# Health verification (proxy mode)

BASE_HTTP="http://localhost"
BASE_HTTPS="https://localhost"

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
