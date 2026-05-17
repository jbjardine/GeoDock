#!/usr/bin/env bash
set -eEuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PHASE="${1:-all}"
MASTER_ID="${MASTER_ID:-}"
[ -n "${MASTER_ID}" ] || { printf '[qa][ERR] MASTER_ID requis\n' >&2; exit 1; }

export QA_OUTPUT_ROOT="${QA_OUTPUT_ROOT:-${ROOT_DIR}/qa-artifacts/${MASTER_ID}}"
export QA_MARKER_DIR="${QA_MARKER_DIR:-${QA_OUTPUT_ROOT}}"
. "${ROOT_DIR}/scripts/qa_lib.sh"

QA_MIN_DISK_GIB="${QA_MIN_DISK_GIB:-390}"
QA_MIN_RAM_GIB="${QA_MIN_RAM_GIB:-30}"
QA_RAM_STABLE_MODE="${QA_RAM_STABLE_MODE:-percent}"
QA_MIN_RAM_FREE_PERCENT="${QA_MIN_RAM_FREE_PERCENT:-20}"
QA_MIN_SWAP_FREE_MIB="${QA_MIN_SWAP_FREE_MIB:-4096}"
QA_SCOPE_DEPARTEMENTS="${QA_SCOPE_DEPARTEMENTS:-11,75,92}"
QA_SOAK_HOURS="${QA_SOAK_HOURS:-24}"
QA_SOAK_INTERVAL_SEC="${QA_SOAK_INTERVAL_SEC:-300}"
QA_FORENSICS_ID="${QA_FORENSICS_ID:-forensics-finalgate-$(date -u +%Y%m%d)}"
QA_FORENSIC_SOURCE_MASTER="${QA_FORENSIC_SOURCE_MASTER:-}"
SERVICE_SLUG="$(printf '%s' "${MASTER_ID}" | tr -c '[:alnum:]' '-')"
QA_POST_REBOOT_SERVICE_NAME="${QA_POST_REBOOT_SERVICE_NAME:-geodock-postreboot-${SERVICE_SLUG}.service}"
TERMINAL_DIR="${QA_OUTPUT_ROOT}/terminal-gate"
FORENSICS_DIR="${ROOT_DIR}/qa-artifacts/${QA_FORENSICS_ID}"
POST_REBOOT_SCRIPT="${ROOT_DIR}/.qa_postreboot_${MASTER_ID}.sh"
POST_REBOOT_SERVICE_FILE="${ROOT_DIR}/.qa_postreboot_${MASTER_ID}.service"
mkdir -p "${TERMINAL_DIR}"
exec > >(tee -a "${TERMINAL_DIR}/${PHASE}.log") 2>&1

terminal_log(){ printf '[qa-terminal] %s %s\n' "$(date -Is)" "$*"; }

terminal_fail(){
  local message="$*"
  trap - ERR
  write_marker "FAILED" "${message}"
  printf '[qa-terminal][ERR] %s\n' "${message}" >&2
  exit 1
}

trap 'terminal_fail "qa_terminal_gate ${PHASE} failed"' ERR

capture_forensics(){
  local source_dir=""
  if [ -n "${QA_FORENSIC_SOURCE_MASTER}" ] && [ -d "${ROOT_DIR}/qa-artifacts/${QA_FORENSIC_SOURCE_MASTER}" ]; then
    source_dir="${ROOT_DIR}/qa-artifacts/${QA_FORENSIC_SOURCE_MASTER}"
  else
    source_dir="$(find "${ROOT_DIR}/qa-artifacts" -maxdepth 1 -type d -name 'finalgate-orchestrator-*' 2>/dev/null | sort | tail -n 1)"
  fi

  mkdir -p "${FORENSICS_DIR}"
  [ -f "${FORENSICS_DIR}/forensics.done" ] && return 0

  terminal_log "capture forensic dans ${FORENSICS_DIR}"
  if [ -n "${source_dir}" ] && [ -f "${source_dir}/runner.log" ]; then
    cp "${source_dir}/runner.log" "${FORENSICS_DIR}/runner.log" || true
  fi
  (cd "${ROOT_DIR}" && docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}') > "${FORENSICS_DIR}/docker-ps.txt" 2>&1 || true
  compose ps -a > "${FORENSICS_DIR}/compose-ps.txt" 2>&1 || true
  if [ -f "${ROOT_DIR}/.env" ]; then
    cp "${ROOT_DIR}/.env" "${FORENSICS_DIR}/.env" || true
    compose config > "${FORENSICS_DIR}/compose-config.yml" 2>&1 || true
  fi
  curl -fsS "$(base_http_url)/_status" > "${FORENSICS_DIR}/status.json" 2>&1 || true
  proxy_cid="$(container_id_any proxy)"
  if [ -n "${proxy_cid:-}" ]; then
    docker inspect "${proxy_cid}" > "${FORENSICS_DIR}/proxy-inspect.json" 2>&1 || true
  fi
  compose_service_logs "${FORENSICS_DIR}/logs" \
    proxy \
    local-bootstrap \
    local-maintainer \
    geocoder-api \
    geocoder-address \
    geocoder-parcel \
    geocoder-poi
  write_marker "forensics.done" "OK"
  printf 'OK\n' > "${FORENSICS_DIR}/forensics.done"
}

write_post_reboot_launcher(){
  cat > "${POST_REBOOT_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "${ROOT_DIR}"
export MASTER_ID="${MASTER_ID}"
export QA_OUTPUT_ROOT="${QA_OUTPUT_ROOT}"
export QA_MARKER_DIR="${QA_MARKER_DIR}"
export QA_MIN_DISK_GIB="${QA_MIN_DISK_GIB}"
export QA_MIN_RAM_GIB="${QA_MIN_RAM_GIB}"
export QA_RAM_STABLE_MODE="${QA_RAM_STABLE_MODE}"
export QA_MIN_RAM_FREE_PERCENT="${QA_MIN_RAM_FREE_PERCENT}"
export QA_MIN_SWAP_FREE_MIB="${QA_MIN_SWAP_FREE_MIB}"
export QA_SCOPE_DEPARTEMENTS="${QA_SCOPE_DEPARTEMENTS}"
export QA_POST_REBOOT_SERVICE_NAME="${QA_POST_REBOOT_SERVICE_NAME}"
bash "${ROOT_DIR}/scripts/qa_terminal_gate.sh" post-reboot >> "${TERMINAL_DIR}/post-reboot-launch.log" 2>&1
EOF
  chmod +x "${POST_REBOOT_SCRIPT}"

  cat > "${POST_REBOOT_SERVICE_FILE}" <<EOF
[Unit]
Description=GeoDock terminal gate post reboot validation (${MASTER_ID})
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=/bin/bash ${POST_REBOOT_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
}

run_prodlike(){
  capture_forensics
  terminal_log "phase prodlike"
  QA_RUN_ID="${QA_RUN_ID:-finalgate-prodlike-${MASTER_ID}}" \
  QA_MIN_DISK_GIB="${QA_MIN_DISK_GIB}" \
  QA_MIN_RAM_GIB="${QA_MIN_RAM_GIB}" \
  QA_RAM_STABLE_MODE="${QA_RAM_STABLE_MODE}" \
  QA_MIN_RAM_FREE_PERCENT="${QA_MIN_RAM_FREE_PERCENT}" \
  QA_MIN_SWAP_FREE_MIB="${QA_MIN_SWAP_FREE_MIB}" \
  QA_SOAK_HOURS="${QA_SOAK_HOURS}" \
  QA_SOAK_INTERVAL_SEC="${QA_SOAK_INTERVAL_SEC}" \
  bash "${ROOT_DIR}/scripts/qa_prodlike_long.sh"
  [ -f "$(marker_path "prodlike.ok")" ] || terminal_fail "prodlike termine sans prodlike.ok"
}

run_rootdocker(){
  terminal_log "phase rootdocker"
  QA_RUN_ID="${QA_RUN_ID:-finalgate-rootdocker-${MASTER_ID}}" \
  QA_MIN_DISK_GIB="${QA_MIN_DISK_GIB}" \
  QA_MIN_RAM_GIB="${QA_MIN_RAM_GIB}" \
  QA_RAM_STABLE_MODE="${QA_RAM_STABLE_MODE}" \
  QA_MIN_RAM_FREE_PERCENT="${QA_MIN_RAM_FREE_PERCENT}" \
  QA_MIN_SWAP_FREE_MIB="${QA_MIN_SWAP_FREE_MIB}" \
  QA_SCOPE_DEPARTEMENTS="${QA_SCOPE_DEPARTEMENTS}" \
  QA_STRICT_ROOT=1 \
  QA_PHASE=all \
  bash "${ROOT_DIR}/scripts/qa_resilience.sh"
  [ ! -f "${QA_OUTPUT_ROOT}/resilience/docker-restart-skip.txt" ] || terminal_fail "rootdocker a encore produit docker-restart-skip.txt"
  [ -f "${QA_OUTPUT_ROOT}/resilience/docker-restart.txt" ] || terminal_fail "rootdocker n'a pas trace de restart Docker"
  write_marker "rootdocker.ok" "OK"
}

run_pre_reboot(){
  terminal_log "phase pre-reboot"
  write_post_reboot_launcher
  QA_RUN_ID="${QA_RUN_ID:-finalgate-reboot-pre-${MASTER_ID}}" \
  QA_STRICT_ROOT=1 \
  QA_POST_REBOOT_SERVICE_NAME="${QA_POST_REBOOT_SERVICE_NAME}" \
  QA_POST_REBOOT_SERVICE_FILE="${POST_REBOOT_SERVICE_FILE}" \
  QA_PHASE=pre-reboot \
  bash "${ROOT_DIR}/scripts/qa_resilience.sh"
  write_marker "reboot.pending" "PENDING"
  terminal_log "reboot hote declenche"
  root_host 'systemctl reboot' >/dev/null 2>&1 || true
}

run_post_reboot(){
  terminal_log "phase post-reboot"
  QA_RUN_ID="${QA_RUN_ID:-finalgate-reboot-post-${MASTER_ID}}" \
  QA_STRICT_ROOT=1 \
  QA_POST_REBOOT_SERVICE_NAME="${QA_POST_REBOOT_SERVICE_NAME}" \
  QA_UNINSTALL_POST_REBOOT_SERVICE=1 \
  QA_PHASE=post-reboot \
  bash "${ROOT_DIR}/scripts/qa_resilience.sh"
  [ -f "$(marker_path "prodlike.ok")" ] || terminal_fail "post-reboot sans prodlike.ok"
  [ -f "$(marker_path "rootdocker.ok")" ] || terminal_fail "post-reboot sans rootdocker.ok"
  write_marker "reboot.ok" "OK"
  write_marker "PUBLIC_GO" "GO"
  rm -f "${POST_REBOOT_SCRIPT}" "${POST_REBOOT_SERVICE_FILE}" || true
}

case "${PHASE}" in
  forensics)
    capture_forensics
    ;;
  prodlike)
    run_prodlike
    ;;
  rootdocker)
    run_rootdocker
    ;;
  pre-reboot)
    run_pre_reboot
    ;;
  post-reboot)
    run_post_reboot
    ;;
  all)
    run_prodlike
    run_rootdocker
    run_pre_reboot
    ;;
  *)
    terminal_fail "phase inconnue: ${PHASE}"
    ;;
esac

terminal_log "phase ${PHASE}: OK"
