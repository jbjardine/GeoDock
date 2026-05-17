#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

TS="$(date -u +%Y%m%d%H%M%S)"
OUT_DIR="dist"
RELEASE_VERSION="${GEODOCK_RELEASE_VERSION:-${GITHUB_REF_NAME:-v1.0.0}}"
SAFE_VERSION="$(printf '%s' "${RELEASE_VERSION}" | sed 's/[^A-Za-z0-9._-]/-/g')"
PKG_DIR="dist/GeoDock-${SAFE_VERSION}-${TS}"
PKG_FILE="dist/GeoDock-${SAFE_VERSION}-${TS}.tar.gz"

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR" "$OUT_DIR"

cp -a docker-compose.yml docker-compose.git.yml docker-compose.proxy.yml "$PKG_DIR/"
cp -a README.md LICENSE .env.example .env.proxy.example "$PKG_DIR/"

mkdir -p "$PKG_DIR/proxy" "$PKG_DIR/runtime" "$PKG_DIR/builder" "$PKG_DIR/scripts" "$PKG_DIR/docs/install" "$PKG_DIR/docs/ops" "$PKG_DIR/var/meta" "$PKG_DIR/var/artifacts"
cp -a proxy/Dockerfile proxy/default.conf.template "$PKG_DIR/proxy/"
cp -a proxy/docker-entrypoint.d "$PKG_DIR/proxy/"
mkdir -p "$PKG_DIR/proxy/certs"
cp -a proxy/certs/.gitkeep "$PKG_DIR/proxy/certs/.gitkeep" 2>/dev/null || true
cp -a runtime/Dockerfile.gpf-geocodeur "$PKG_DIR/runtime/"
cp -a runtime/scripts "$PKG_DIR/runtime/"
cp -a builder/*.py "$PKG_DIR/builder/"
cp -a scripts/*.sh "$PKG_DIR/scripts/"
cp -a scripts/*.py "$PKG_DIR/scripts/" 2>/dev/null || true
cp -a docs/install/unified.md "$PKG_DIR/docs/install/"
cp -a docs/install/proxy.md "$PKG_DIR/docs/install/" 2>/dev/null || true
cp -a docs/ops/v2-qualification.md "$PKG_DIR/docs/ops/" 2>/dev/null || true
touch "$PKG_DIR/var/meta/.gitkeep" "$PKG_DIR/var/artifacts/.gitkeep"

tar -C dist -czf "$PKG_FILE" "$(basename "$PKG_DIR")"
echo "[release] created $PKG_FILE"
