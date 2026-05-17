#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA_RUN_ID="${QA_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
QA_OUTPUT_ROOT="${QA_OUTPUT_ROOT:-${ROOT_DIR}/qa-artifacts/${QA_RUN_ID}}"
QA_MARKER_DIR="${QA_MARKER_DIR:-${QA_OUTPUT_ROOT}}"
mkdir -p "${QA_OUTPUT_ROOT}"
mkdir -p "${QA_MARKER_DIR}"

log(){ printf '[qa] %s %s\n' "$(date -Is)" "$*"; }
fail(){ printf '[qa][ERR] %s\n' "$*" >&2; exit 1; }

qa_python(){
  if command -v python3 >/dev/null 2>&1; then
    python3 "$@"
  elif command -v python >/dev/null 2>&1; then
    python "$@"
  else
    fail "python3/python introuvable sur l'hote"
  fi
}

marker_path(){
  local name="$1"
  printf '%s/%s' "${QA_MARKER_DIR}" "$name"
}

write_marker(){
  local name="$1"
  shift || true
  printf '%s\n' "${*:-OK}" > "$(marker_path "$name")"
}

clear_marker(){
  rm -f "$(marker_path "$1")"
}

read_env(){
  local key="$1"
  awk -F= -v key="$key" '$1==key{print substr($0, index($0,"=")+1)}' "${ROOT_DIR}/.env" 2>/dev/null | tr -d '\r' | tail -n 1
}

write_env(){
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "${ROOT_DIR}/.env" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ROOT_DIR}/.env"
  else
    printf '%s=%s\n' "$key" "$value" >> "${ROOT_DIR}/.env"
  fi
}

backup_env(){
  if [ -f "${ROOT_DIR}/.env" ]; then
    cp "${ROOT_DIR}/.env" "${QA_OUTPUT_ROOT}/.env.backup"
  fi
}

restore_env(){
  if [ -f "${QA_OUTPUT_ROOT}/.env.backup" ]; then
    cp "${QA_OUTPUT_ROOT}/.env.backup" "${ROOT_DIR}/.env"
  fi
}

compose(){
  (cd "${ROOT_DIR}" && docker compose -f docker-compose.yml -f docker-compose.git.yml "$@")
}

compose_proxy_only(){
  (cd "${ROOT_DIR}" && docker compose -f docker-compose.proxy.yml "$@")
}

compose_project_name(){
  local value
  value="$(read_env COMPOSE_PROJECT_NAME)"
  printf '%s' "${value:-$(basename "${ROOT_DIR}")}"
}

snapshot_runtime(){
  local label="$1"
  local dir="${QA_OUTPUT_ROOT}/${label}"
  mkdir -p "$dir"
  (cd "${ROOT_DIR}" && docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}') > "${dir}/docker-ps.txt" 2>&1 || true
  compose ps -a > "${dir}/compose-ps.txt" 2>&1 || true
  if [ -f "${ROOT_DIR}/.env" ]; then
    cp "${ROOT_DIR}/.env" "${dir}/.env"
    compose config > "${dir}/compose-config.yml" 2>&1 || true
  fi
  if [ -f "${ROOT_DIR}/var/meta/status.json" ]; then
    cp "${ROOT_DIR}/var/meta/status.json" "${dir}/status.json"
  fi
}

http_port(){
  local value
  value="$(read_env HOST_PORT_HTTP)"
  printf '%s' "${value:-80}"
}

https_port(){
  local value
  value="$(read_env HOST_PORT_HTTPS)"
  printf '%s' "${value:-443}"
}

base_http_url(){
  printf 'http://localhost:%s' "$(http_port)"
}

base_https_url(){
  printf 'https://localhost:%s' "$(https_port)"
}

wait_http_ok(){
  local url="$1"
  local timeout="$2"
  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if curl -fsS -o /dev/null "$url" 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

status_json(){
  local base="${1:-$(base_http_url)}"
  curl -fsS "${base}/_status"
}

status_expr(){
  local base="$1"
  local expr="$2"
  status_json "$base" | qa_python -c "import json,sys; data=json.load(sys.stdin); print(${expr})"
}

wait_status_ready(){
  local base="$1"
  local timeout="$2"
  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if [ "$(status_expr "$base" '"1" if data.get("state") == "ready" else "0"' 2>/dev/null || printf '0')" = "1" ]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_local_ready(){
  local base="$1"
  local timeout="$2"
  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if [ "$(status_expr "$base" '"1" if data.get("state") == "ready" and all(bool(data.get("local_ready", {}).get(k)) for k in ("address","parcel","poi","api")) else "0"' 2>/dev/null || printf '0')" = "1" ]; then
      return 0
    fi
    sleep 10
  done
  return 1
}

query_headers(){
  local url="$1"
  curl -sS -D - -o /dev/null "$url"
}

assert_header(){
  local url="$1"
  local header_name="$2"
  local expected="$3"
  local headers
  headers="$(query_headers "$url")" || return 1
  printf '%s' "$headers" | grep -qi "^${header_name}: ${expected}\b"
}

assert_status_contract(){
  local base="$1"
  shift
  qa_python "${ROOT_DIR}/scripts/qa_status_contract.py" --url "${base}/_status" "$@"
}

cleanup_stack(){
  (cd "${ROOT_DIR}" && docker compose -f docker-compose.yml -f docker-compose.git.yml --profile local --profile ops down -v --remove-orphans) >/dev/null 2>&1 || true
  (cd "${ROOT_DIR}" && docker compose -f docker-compose.proxy.yml down -v --remove-orphans) >/dev/null 2>&1 || true
}

container_id(){
  local service="$1"
  docker ps -q --filter "label=com.docker.compose.service=${service}" --filter "label=com.docker.compose.project=$(compose_project_name)"
}

container_id_any(){
  local service="$1"
  docker ps -aq --filter "label=com.docker.compose.service=${service}" --filter "label=com.docker.compose.project=$(compose_project_name)" | head -n 1
}

compose_network_name(){
  docker network ls --filter "label=com.docker.compose.project=$(compose_project_name)" --format '{{.Name}}' | head -n 1
}

compose_service_logs(){
  local dir="$1"
  shift
  mkdir -p "$dir"
  local service
  for service in "$@"; do
    compose logs --no-color "$service" > "${dir}/${service}.log" 2>&1 || true
  done
}

root_host(){
  docker run --rm --privileged --pid=host -v /:/host alpine:3.20 chroot /host /bin/sh -lc "$1"
}

root_host_available(){
  docker info >/dev/null 2>&1 || return 1
  root_host 'command -v systemctl >/dev/null 2>&1' >/dev/null 2>&1
}

wait_docker_daemon(){
  local timeout="$1"
  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

memory_free_percent(){
  free -b | awk '/Mem:/ { if ($2 == 0) { print 0 } else { printf "%.0f", ($7/$2)*100 } }'
}

swap_free_mib(){
  free -m | awk '/Swap:/ { print $4 }'
}

memory_stability_summary(){
  printf 'mode=%s ram_free_percent=%s min_ram_free_percent=%s swap_free_mib=%s min_swap_free_mib=%s' \
    "${QA_RAM_STABLE_MODE:-percent}" \
    "$(memory_free_percent)" \
    "${QA_MIN_RAM_FREE_PERCENT:-20}" \
    "$(swap_free_mib)" \
    "${QA_MIN_SWAP_FREE_MIB:-4096}"
}

memory_stability_ok(){
  case "${QA_RAM_STABLE_MODE:-percent}" in
    percent)
      [ "$(memory_free_percent)" -ge "${QA_MIN_RAM_FREE_PERCENT:-20}" ]
      ;;
    swap)
      [ "$(swap_free_mib)" -ge "${QA_MIN_SWAP_FREE_MIB:-4096}" ]
      ;;
    *)
      return 2
      ;;
  esac
}

disk_free_gib(){
  df -BG / | awk 'NR==2 { gsub("G","",$4); print $4 }'
}
