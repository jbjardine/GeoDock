#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 -c <tls.crt> -k <tls.key>" >&2
  exit 2
}

CRT=""; KEY=""
while getopts ":c:k:" opt; do
  case "$opt" in
    c) CRT="$OPTARG" ;;
    k) KEY="$OPTARG" ;;
    *) usage ;;
  esac
done

[ -n "$CRT" ] && [ -n "$KEY" ] || usage

if [ ! -f "$CRT" ] || [ ! -f "$KEY" ]; then
  echo "[certs] ERROR: missing files (crt/key)" >&2; exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DEST_DIR="proxy/certs"
mkdir -p "$DEST_DIR"

echo "[certs] Verifying key/cert match"
crt_pub="$(openssl x509 -in "$CRT" -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform pem 2>/dev/null | sha256sum | awk '{print $1}')" || true
key_pub="$(openssl pkey -in "$KEY" -pubout 2>/dev/null | sha256sum | awk '{print $1}')" || true
if [ -n "$crt_pub" ] && [ -n "$key_pub" ] && [ "$crt_pub" != "$key_pub" ]; then
  echo "[certs] ERROR: certificate and key do not match" >&2; exit 1
fi

ts="$(date -u +%Y%m%d%H%M%S)"
if [ -f "$DEST_DIR/tls.crt" ] || [ -f "$DEST_DIR/tls.key" ]; then
  backup_dir="$DEST_DIR/backup-$ts"
  if ! mkdir -p "$backup_dir" 2>/dev/null; then
    backup_dir="$(pwd)/.backup/certs-$ts"
    echo "[certs] WARN: cannot create $DEST_DIR/backup; using $backup_dir"
    mkdir -p "$backup_dir" || true
  fi
  echo "[certs] Backing up existing certs -> $backup_dir/"
  for f in tls.crt tls.key; do
    if [ -e "$DEST_DIR/$f" ]; then
      if [ -r "$DEST_DIR/$f" ]; then
        cp -a "$DEST_DIR/$f" "$backup_dir/" || true
      else
        # Fichier non lisible (p.ex. créé root:600 via bind mount) — renomme sans lecture
        mv -f "$DEST_DIR/$f" "$backup_dir/" || true
      fi
    fi
  done
fi

echo "[certs] Installing new certs"
COMPOSE_FILE="docker-compose.proxy.yml"
if ! command -v docker >/dev/null 2>&1; then
  echo "[certs] ERROR: docker not found" >&2; exit 1
fi

# Hint if Docker is present but current user has no access to the daemon
if ! docker ps >/dev/null 2>&1; then
  echo "[certs] Note: no access to Docker daemon (docker ps). If the proxy is running, run this script with sudo or add your user to the docker group." >&2
fi

# Prefer install inside container if running (avoid host permission/ownership issues)
cid="$(docker compose -f "$COMPOSE_FILE" ps -q proxy 2>/dev/null || true)"
reloaded=0
if [ -n "$cid" ]; then
  echo "[certs] Installing inside container"
  docker exec -i "$cid" /bin/sh -lc 'cat > /etc/nginx/certs/tls.crt' < "$CRT"
  docker exec -i "$cid" /bin/sh -lc 'cat > /etc/nginx/certs/tls.key' < "$KEY"
  docker exec "$cid" /bin/sh -lc 'chmod 600 /etc/nginx/certs/tls.key'
  docker exec "$cid" nginx -s reload || true
  reloaded=1
else
  # Container not running: attempt host install, then (re)create service
  echo "[certs] Container not running; installing on host and starting proxy"
  if ! cp -a "$CRT" "$DEST_DIR/tls.crt" || ! cp -a "$KEY" "$DEST_DIR/tls.key"; then
    echo "[certs] ERROR: cannot write to $DEST_DIR; start proxy first or adjust permissions" >&2
    exit 1
  fi
  chmod 600 "$DEST_DIR/tls.key" || true
  if [ -f .env ]; then sed -i 's/\r$//' .env || true; fi
  docker compose -f "$COMPOSE_FILE" up -d --build proxy
fi

echo "[certs] Checking HTTPS health"
for i in 1 2 3 4 5; do
  if curl -ksSf https://localhost/_health >/dev/null; then
    echo "[certs] OK: HTTPS endpoint responds"; break
  fi
  sleep 1
done
if ! curl -ksSf https://localhost/_health >/dev/null; then
  echo "[certs] WARN: HTTPS health not verified (trust/chain?) — check logs" >&2
  docker compose -f "$COMPOSE_FILE" logs --no-color --tail=200 proxy || true
fi

echo "[certs] Done"
