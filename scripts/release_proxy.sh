#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

TS="$(date -u +%Y%m%d%H%M%S)"
OUT_DIR="dist"
PKG_DIR="dist/geodock-proxy-${TS}"
PKG_FILE="dist/geodock-proxy-${TS}.tar.gz"

rm -rf "$PKG_DIR" && mkdir -p "$PKG_DIR" "$OUT_DIR"

# Minimal payload for proxy-only deploy
cp -a docker-compose.proxy.yml "$PKG_DIR/"
mkdir -p "$PKG_DIR/proxy"
cp -a proxy/Dockerfile "$PKG_DIR/proxy/"
cp -a proxy/default.conf.template "$PKG_DIR/proxy/" 2>/dev/null || true
cp -a proxy/templates "$PKG_DIR/proxy/" 2>/dev/null || true
cp -a proxy/docker-entrypoint.d "$PKG_DIR/proxy/"
mkdir -p "$PKG_DIR/proxy/certs" && cp -a proxy/certs/.gitkeep "$PKG_DIR/proxy/certs/.gitkeep"

mkdir -p "$PKG_DIR/scripts"
cp -a scripts/proxy_up.sh scripts/proxy_verify.sh scripts/stack_stop.sh scripts/doctor.sh "$PKG_DIR/scripts/"
cp -a scripts/tools_up.sh "$PKG_DIR/scripts/" 2>/dev/null || true
cp -a scripts/certs_install.sh "$PKG_DIR/scripts/" 2>/dev/null || true

mkdir -p "$PKG_DIR/docs/install" "$PKG_DIR/docs/ops"
cp -a docs/install/proxy.md "$PKG_DIR/docs/install/"
cp -a docs/ops/*.md "$PKG_DIR/docs/ops/" 2>/dev/null || true

# Env example: prefer .env.proxy.example, fallback to .env.example, else generate minimal
ENV_SRC='.env.proxy.example'
if [ -f '.env.example' ] && [ ! -f '.env.proxy.example' ]; then ENV_SRC='.env.example'; fi
if [ -f "$ENV_SRC" ]; then
  cp -a "$ENV_SRC" "$PKG_DIR/.env.example"
else
  cat > "$PKG_DIR/.env.example" <<'EOF'
MODE=remote
SERVER_NAME=geodock.intra
UPSTREAM_BAN=https://api-adresse.data.gouv.fr
UPSTREAM_HOST=api-adresse.data.gouv.fr
HOST_PORT_HTTP=80
HOST_PORT_HTTPS=443
SSL_PROTOCOLS=TLSv1.2 TLSv1.3
UPSTREAM_SSL_PROTOCOLS=TLSv1.3
FALLBACK_ON_404=false
REDIRECT_HTTP_TO_HTTPS=false
EXPOSE_HEALTH_ON_HTTP=true
EOF
fi

tar -C dist -czf "$PKG_FILE" "$(basename "$PKG_DIR")"
echo "[release] created $PKG_FILE"