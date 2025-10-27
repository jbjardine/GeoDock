#!/bin/sh
set -e

CERT_DIR=/etc/nginx/certs
CRT="$CERT_DIR/tls.crt"
KEY="$CERT_DIR/tls.key"
CN="${SERVER_NAME:-geodock.intra}"

if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
  echo "[proxy] Generating self-signed certificate for $CN"
  mkdir -p "$CERT_DIR"
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -subj "/CN=$CN" \
    -keyout "$KEY" -out "$CRT" >/dev/null 2>&1 || true
fi

