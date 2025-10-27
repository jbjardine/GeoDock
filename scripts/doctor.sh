#!/usr/bin/env bash
set -euo pipefail

ok()  { printf "[ OK ] %s\n" "$*"; }
warn(){ printf "[WARN] %s\n" "$*"; }
err() { printf "[ERR ] %s\n" "$*"; }

have(){ command -v "$1" >/dev/null 2>&1; }

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

# 1) Docker + Compose
if have docker; then
  ok "docker detected: $(docker --version | sed 's/,.*//')"
else
  err "docker not found in PATH"; exit 1
fi

if docker compose version >/dev/null 2>&1; then
  ok "docker compose detected: $(docker compose version | awk 'NR==1{print $1,$3}')"
else
  warn "docker compose plugin not detected (will try docker-compose if available)"
fi

# 2) Permissions (user in docker group)
if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
  ok "user is in docker group"
else
  warn "user is NOT in docker group (sudo may be required): sudo usermod -aG docker $(id -un)"
fi

# 3) Ports 80/443 availability
check_port(){
  local p="$1"; local busy=0
  if have ss; then
    ss -ltn | awk '{print $4}' | grep -Eq ":${p}$|:${p}[^0-9]" && busy=1 || true
  elif have netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${p}$|:${p}[^0-9]" && busy=1 || true
  else
    warn "no ss/netstat; skipping port ${p} check"; return 0
  fi
  if [ "$busy" -eq 0 ]; then ok "port ${p} free"; else warn "port ${p} busy"; fi
}
check_port 80
check_port 443

# 4) SERVER_NAME resolution (optional)
SERVER_NAME=$(grep -E '^SERVER_NAME=' .env 2>/dev/null | sed 's/.*=//') || SERVER_NAME=""
if [ -n "${SERVER_NAME}" ]; then
  if getent hosts "${SERVER_NAME}" >/dev/null 2>&1; then
    ok "SERVER_NAME resolves: ${SERVER_NAME}"
  else
    warn "SERVER_NAME does not resolve on host: ${SERVER_NAME}"
  fi
else
  warn "SERVER_NAME not set in .env (script will set it during bootstrap)"
fi

# 5) TLS certs presence (optional)
if [ -s proxy/certs/tls.crt ] && [ -s proxy/certs/tls.key ]; then
  ok "TLS certs found in proxy/certs"
else
  warn "no TLS certs found (self-signed will be generated)"
fi

echo "---"
ok "doctor completed"
