#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

MODE_OVERRIDE=""
SERVER_NAME_OVERRIDE=""
SCOPE_OVERRIDE=""
DEPARTEMENTS_OVERRIDE=""
AUTO_UPDATE_OVERRIDE=""
LOCAL_SOURCE_OVERRIDE=""
USE_GHCR_OVERRIDE=""
NON_INTERACTIVE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --server-name)
      SERVER_NAME_OVERRIDE="${2:-}"
      shift 2
      ;;
    --scope)
      SCOPE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --departements)
      DEPARTEMENTS_OVERRIDE="${2:-}"
      shift 2
      ;;
    --auto-update)
      AUTO_UPDATE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --local-source)
      LOCAL_SOURCE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --use-ghcr)
      USE_GHCR_OVERRIDE="${2:-}"
      shift 2
      ;;
    --yes|--non-interactive)
      NON_INTERACTIVE=1
      shift
      ;;
    *)
      echo "[geodock_up] Argument inconnu: $1" >&2
      exit 1
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "[geodock_up] ERROR: docker not found in PATH" >&2
  exit 1
fi

if [ ! -f .env ]; then
  cp .env.example .env
  echo "[geodock_up] Created .env from .env.example"
fi

mkdir -p var/meta var/artifacts proxy/certs
[ -f proxy/certs/.gitkeep ] || touch proxy/certs/.gitkeep

get_env(){
  awk -F= -v key="$1" '$1==key{print substr($0, index($0,"=")+1)}' .env | tr -d '\r' | tail -n 1
}

set_env(){
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

prompt_default(){
  local label="$1"
  local default_value="$2"
  local answer
  read -r -p "${label} [${default_value}]: " answer
  if [ -z "$answer" ]; then
    printf '%s' "$default_value"
  else
    printf '%s' "$answer"
  fi
}

write_status_file(){
  local state="$1"
  local upstream_active="$2"
  local local_enabled="$3"
  local current_step="$4"
  local last_successful_update_at="${5:-null}"
  local departements_json="$6"
  local timestamp
  local tmp_status
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp_status="$(mktemp var/meta/status.json.XXXXXX)"
  cat > "$tmp_status" <<EOF
{
  "state": "${state}",
  "mode": "${mode}",
  "upstream_active": "${upstream_active}",
  "local_enabled": ${local_enabled},
  "local_ready": { "address": false, "parcel": false, "poi": false, "api": false },
  "scope": "${local_scope:-departements}",
  "departements": [${departements_json}],
  "current_step": "${current_step}",
  "progress": { "current": 0, "total": 0, "percent": 0 },
  "started_at": "${timestamp}",
  "updated_at": "${timestamp}",
  "last_error": null,
  "last_successful_update_at": ${last_successful_update_at}
}
EOF
  mv "$tmp_status" var/meta/status.json
  chmod 644 var/meta/status.json
}

wait_proxy_health(){
  local url="$1"
  local timeout="${2:-90}"
  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if curl --max-time 5 -fsS -o /dev/null "$url" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

mode_default="$(get_env MODE)"
mode_default="${mode_default:-hybrid}"
mode="${MODE_OVERRIDE:-$mode_default}"
if [ -z "$MODE_OVERRIDE" ] && [ "$NON_INTERACTIVE" -ne 1 ]; then
  mode="$(prompt_default 'Mode (proxy/local/hybrid/failback)' "$mode_default")"
fi

server_default="$(get_env SERVER_NAME)"
server_default="${server_default:-$(hostname -f 2>/dev/null || hostname)}"
server_name="${SERVER_NAME_OVERRIDE:-$server_default}"
if [ "$NON_INTERACTIVE" -ne 1 ] && [ -z "$SERVER_NAME_OVERRIDE" ]; then
  server_name="$(prompt_default 'Nom d hote / FQDN' "$server_default")"
fi

local_scope="$(get_env LOCAL_SCOPE)"
local_scope="${local_scope:-departements}"
local_departements="$(get_env LOCAL_DEPARTEMENTS)"
local_source="$(get_env LOCAL_SOURCE)"
local_source="${local_source:-build}"
local_auto_update="$(get_env LOCAL_AUTO_UPDATE)"
local_auto_update="${local_auto_update:-true}"
use_ghcr_default="$(get_env GEODOCK_USE_GHCR)"
use_ghcr_default="${use_ghcr_default:-true}"

if [ "$mode" != "proxy" ] && [ "$mode" != "remote" ]; then
  local_source="${LOCAL_SOURCE_OVERRIDE:-$local_source}"
  scope_answer="${SCOPE_OVERRIDE:-$local_scope}"
  if [ "$NON_INTERACTIVE" -ne 1 ] && [ -z "$SCOPE_OVERRIDE" ]; then
    scope_answer="$(prompt_default 'Portee locale (departements/france)' "$local_scope")"
  fi
  case "$scope_answer" in
    france)
      local_scope="france"
      local_departements=""
      ;;
    *)
      local_scope="departements"
      local_departements="${DEPARTEMENTS_OVERRIDE:-${local_departements:-11,75,92}}"
      if [ "$NON_INTERACTIVE" -ne 1 ] && [ -z "$DEPARTEMENTS_OVERRIDE" ]; then
        local_departements="$(prompt_default 'Departements (ex: 75,92,93,94)' "$local_departements")"
      fi
      ;;
  esac
  auto_answer="${AUTO_UPDATE_OVERRIDE:-$local_auto_update}"
  if [ "$NON_INTERACTIVE" -ne 1 ] && [ -z "$AUTO_UPDATE_OVERRIDE" ]; then
    auto_answer="$(prompt_default 'Mise a jour auto hebdo (true/false)' "$local_auto_update")"
  fi
  case "$auto_answer" in
    false|0|no|NO) local_auto_update="false" ;;
    *) local_auto_update="true" ;;
  esac
fi

project_name="$(get_env COMPOSE_PROJECT_NAME)"
project_name="${project_name:-geodock}"
set_env COMPOSE_PROJECT_NAME "$project_name"
set_env MODE "$mode"
set_env SERVER_NAME "$server_name"
set_env LOCAL_SOURCE "$local_source"
set_env LOCAL_SCOPE "${local_scope:-departements}"
set_env LOCAL_DEPARTEMENTS "${local_departements:-}"
set_env LOCAL_AUTO_UPDATE "${local_auto_update:-true}"
set_env LOCAL_BOOTSTRAP_TIMEOUT "${LOCAL_BOOTSTRAP_TIMEOUT:-86400}"

if [ "$mode" = "proxy" ] || [ "$mode" = "remote" ]; then
  docker compose -f docker-compose.yml -f docker-compose.git.yml --profile local stop \
    local-maintainer geocoder-api geocoder-address geocoder-parcel geocoder-poi local-bootstrap \
    >/dev/null 2>&1 || true
fi

if ! grep -q '^LOCAL_UPDATE_SCHEDULE_CRON=' .env; then
  printf '%s=%s\n' "LOCAL_UPDATE_SCHEDULE_CRON" "0 3 * * 1" >> .env
fi

if ! grep -q '^GEODOCK_USE_GHCR=' .env; then
  printf '%s=%s\n' "GEODOCK_USE_GHCR" "true" >> .env
fi
if [ -n "$USE_GHCR_OVERRIDE" ]; then
  set_env GEODOCK_USE_GHCR "$USE_GHCR_OVERRIDE"
fi

departements_json=""
if [ -n "${local_departements:-}" ]; then
  departements_json="$(printf '"%s"' "$local_departements" | sed 's/,/","/g')"
fi

rm -f var/meta/status.json
write_status_file \
  "preflight" \
  "$( [ "$mode" = "proxy" ] || [ "$mode" = "remote" ] || [ "$mode" = "failback" ] && printf remote || printf unknown )" \
  "$( [ "$mode" = "proxy" ] || [ "$mode" = "remote" ] && printf false || printf true )" \
  "Initialisation GeoDock" \
  "null" \
  "${departements_json}"

compose_args=(-f docker-compose.yml -f docker-compose.git.yml)
if [ "$mode" != "proxy" ] && [ "$mode" != "remote" ]; then
  compose_args+=(--profile local)
fi

http_port="$(get_env HOST_PORT_HTTP)"
http_port="${http_port:-80}"

use_ghcr="$(get_env GEODOCK_USE_GHCR)"
build_flag="--build"
if [ "${use_ghcr:-true}" = "true" ]; then
  proxy_image="$(get_env GEODOCK_PROXY_IMAGE)"
  runtime_image="$(get_env GEODOCK_RUNTIME_IMAGE)"
  pulled=1
  if [ -n "$proxy_image" ]; then
    docker pull "$proxy_image" >/dev/null 2>&1 || pulled=0
  fi
  if [ "$mode" != "proxy" ] && [ "$mode" != "remote" ] && [ -n "$runtime_image" ]; then
    docker pull "$runtime_image" >/dev/null 2>&1 || pulled=0
  fi
  if [ "$pulled" -eq 1 ]; then
    build_flag=""
    echo "[geodock_up] Images GHCR utilisees."
  else
    echo "[geodock_up] GHCR indisponible ou incomplet, fallback sur build local."
  fi
fi

echo "[geodock_up] MODE=${mode}"
if [ -n "$build_flag" ]; then
  docker compose "${compose_args[@]}" up -d "$build_flag"
else
  docker compose "${compose_args[@]}" up -d
fi

if [ "$mode" = "proxy" ] || [ "$mode" = "remote" ]; then
  if command -v curl >/dev/null 2>&1 && wait_proxy_health "http://localhost:${http_port}/_health" 120; then
    proxy_ready_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_status_file "ready" "remote" "false" "Proxy pret" "\"${proxy_ready_at}\"" "${departements_json}"
  else
    echo "[geodock_up] WARNING: impossible de confirmer /_health du proxy, statut conserve en preflight." >&2
  fi
fi

echo
echo "GeoDock demarre."
echo "- URL: http://localhost:${http_port}"
echo "- Mode: ${mode}"
echo "- Statut: bash scripts/geodock_status.sh"
echo "- Verification: bash scripts/geodock_verify.sh"
