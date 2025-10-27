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
# Optional helpers included in package
cp -a scripts/tools_up.sh "$PKG_DIR/scripts/" 2>/dev/null || true
cp -a scripts/certs_install.sh "$PKG_DIR/scripts/" 2>/dev/null || true

mkdir -p "$PKG_DIR/docs/install" "$PKG_DIR/docs/ops"
cp -a docs/install/proxy.md "$PKG_DIR/docs/install/"
cp -a docs/ops/*.md "$PKG_DIR/docs/ops/" 2>/dev/null || true

cp -a .env.proxy.example "$PKG_DIR/.env.example"

tar -C dist -czf "$PKG_FILE" "$(basename "$PKG_DIR")"
echo "[release] created $PKG_FILE"
