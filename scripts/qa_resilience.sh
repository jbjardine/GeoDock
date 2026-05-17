#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT_DIR}/scripts/qa_lib.sh"

QA_SERVER_NAME="${QA_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}"
QA_SCOPE_DEPARTEMENTS="${QA_SCOPE_DEPARTEMENTS:-11,75,92}"
QA_PHASE="${QA_PHASE:-all}"
QA_STRICT_ROOT="${QA_STRICT_ROOT:-0}"
QA_POST_REBOOT_SERVICE_NAME="${QA_POST_REBOOT_SERVICE_NAME:-geodock-postreboot.service}"
QA_POST_REBOOT_SERVICE_FILE="${QA_POST_REBOOT_SERVICE_FILE:-}"
QA_UNINSTALL_POST_REBOOT_SERVICE="${QA_UNINSTALL_POST_REBOOT_SERVICE:-0}"
case "${QA_PHASE}" in
  pre-reboot) RESILIENCE_DIR="${QA_OUTPUT_ROOT}/resilience-pre-reboot" ;;
  post-reboot) RESILIENCE_DIR="${QA_OUTPUT_ROOT}/resilience-post-reboot" ;;
  *) RESILIENCE_DIR="${QA_OUTPUT_ROOT}/resilience" ;;
esac
mkdir -p "${RESILIENCE_DIR}"
BASE="$(base_http_url)"

resilience_fail(){
  local message="$*"
  write_marker "FAILED" "resilience(${QA_PHASE}): ${message}"
  fail "${message}"
}

wait_address_upstream(){
  local expected="$1"
  local timeout="$2"
  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if assert_header "${BASE}/search/?q=paris&limit=1" "X-Geodock-Upstream" "$expected"; then
      return 0
    fi
    sleep 3
  done
  return 1
}

ensure_hybrid_ready(){
  bash "${ROOT_DIR}/scripts/geodock_up.sh" --yes --mode hybrid --server-name "${QA_SERVER_NAME}" --scope departements --departements "${QA_SCOPE_DEPARTEMENTS}" --auto-update false \
    > "${RESILIENCE_DIR}/hybrid-up.log"
  wait_local_ready "${BASE}" 7200 || resilience_fail "Hybrid non pret pour la campagne resilience"
}

test_local_service_restart(){
  compose stop geocoder-api > "${RESILIENCE_DIR}/stop-geocoder-api.txt"
  wait_http_ok "${BASE}/_health" 180 || resilience_fail "Health KO apres stop geocoder-api"
  assert_header "${BASE}/search/?q=paris&limit=1" "X-Geodock-Upstream" "remote" || resilience_fail "Pas de fallback remote apres stop geocoder-api"
  compose up -d --no-deps geocoder-api > "${RESILIENCE_DIR}/start-geocoder-api.txt"
  wait_local_ready "${BASE}" 1800 || resilience_fail "Hybrid n'a pas recupere apres restart geocoder-api"
}

test_docker_restart(){
  local restart_status=0
  snapshot_runtime "rootdocker-before"
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && command -v systemctl >/dev/null 2>&1; then
    set +e
    { sudo systemctl restart docker; } > "${RESILIENCE_DIR}/docker-restart.txt"
    restart_status=$?
    set -e
  elif root_host_available; then
    set +e
    root_host 'systemctl restart docker' > "${RESILIENCE_DIR}/docker-restart.txt"
    restart_status=$?
    set -e
  else
    if [ "${QA_STRICT_ROOT}" = "1" ]; then
      resilience_fail "restart daemon Docker non verifiable sans sudo ni root_host"
    fi
    printf 'SKIP: restart daemon Docker non verifiable sans sudo/systemctl\n' > "${RESILIENCE_DIR}/docker-restart-skip.txt"
    log "SKIP restart daemon Docker: sudo/systemctl indisponible"
    return 0
  fi
  {
    printf 'restart_command_exit=%s\n' "${restart_status}"
    printf 'note=non-zero can be expected because restarting Docker may disconnect the Docker client\n'
  } >> "${RESILIENCE_DIR}/docker-restart.txt"
  wait_docker_daemon 600 || resilience_fail "Daemon Docker non revenu apres restart docker"
  wait_http_ok "${BASE}/_health" 600 || resilience_fail "Stack non revenue apres restart docker"
  wait_local_ready "${BASE}" 1800 || resilience_fail "Local non revenu apres restart docker"
  snapshot_runtime "rootdocker-after"
}

install_post_reboot_service(){
  [ -n "${QA_POST_REBOOT_SERVICE_FILE}" ] || resilience_fail "QA_POST_REBOOT_SERVICE_FILE requis en pre-reboot strict"
  root_host "cp '${QA_POST_REBOOT_SERVICE_FILE}' '/etc/systemd/system/${QA_POST_REBOOT_SERVICE_NAME}' && systemctl daemon-reload && systemctl enable '${QA_POST_REBOOT_SERVICE_NAME}'"
  root_host "test -f '/etc/systemd/system/${QA_POST_REBOOT_SERVICE_NAME}'"
  root_host "systemctl is-enabled '${QA_POST_REBOOT_SERVICE_NAME}'" > "${RESILIENCE_DIR}/post-reboot-service-enabled.txt"
  root_host "systemctl cat '${QA_POST_REBOOT_SERVICE_NAME}'" > "${RESILIENCE_DIR}/post-reboot-service-cat.txt"
}

uninstall_post_reboot_service(){
  root_host "systemctl disable '${QA_POST_REBOOT_SERVICE_NAME}' || true; rm -f '/etc/systemd/system/${QA_POST_REBOOT_SERVICE_NAME}'; systemctl daemon-reload || true"
}

test_failback_upstream_outage(){
  bash "${ROOT_DIR}/scripts/geodock_reconfigure.sh" --yes --mode failback --server-name "${QA_SERVER_NAME}" --scope departements --departements "${QA_SCOPE_DEPARTEMENTS}" --auto-update false \
    > "${RESILIENCE_DIR}/switch-failback.log"
  wait_local_ready "${BASE}" 1800 || resilience_fail "Failback non pret pour le test d'upstream"
  original_upstream_ban="$(read_env UPSTREAM_BAN)"
  write_env UPSTREAM_BAN http://127.0.0.1:9
  compose up -d --force-recreate --no-deps proxy > "${RESILIENCE_DIR}/break-upstream.txt"
  wait_address_upstream local 180 || resilience_fail "Failback n'a pas bascule local quand upstream casse"
  write_env UPSTREAM_BAN "${original_upstream_ban:-https://api-adresse.data.gouv.fr}"
  compose up -d --force-recreate --no-deps proxy > "${RESILIENCE_DIR}/restore-upstream.txt"
  wait_address_upstream remote 180 || resilience_fail "Failback n'a pas restaure le distant"
}

test_geopf_outage_update(){
  local network
  local cid
  network="$(compose_network_name)"
  cid="$(container_id local-maintainer)"
  [ -n "$cid" ] || resilience_fail "local-maintainer introuvable"
  docker network disconnect "$network" "$cid" > "${RESILIENCE_DIR}/disconnect-local-maintainer.txt"
  if bash "${ROOT_DIR}/scripts/geodock_update_now.sh" > "${RESILIENCE_DIR}/update-while-disconnected.txt" 2>&1; then
    resilience_fail "Le refresh aurait du echouer sans reseau GeoPF"
  fi
  state="$(status_expr "${BASE}" 'repr(data.get("state"))' 2>/dev/null | tr -d "'")"
  [ "$state" = "error" ] || resilience_fail "Le statut n'est pas passe a error pendant l'indisponibilite GeoPF"
  docker network connect "$network" "$cid" > "${RESILIENCE_DIR}/reconnect-local-maintainer.txt"
  bash "${ROOT_DIR}/scripts/geodock_update_now.sh" > "${RESILIENCE_DIR}/update-after-reconnect.txt"
  wait_local_ready "${BASE}" 1800 || resilience_fail "Le runtime n'a pas recupere apres retour du reseau GeoPF"
}

test_bootstrap_interruption(){
  cleanup_stack
  bash "${ROOT_DIR}/scripts/geodock_up.sh" --yes --mode hybrid --server-name "${QA_SERVER_NAME}" --scope departements --departements "${QA_SCOPE_DEPARTEMENTS}" --auto-update false \
    > "${RESILIENCE_DIR}/bootstrap-interruption-up.log" 2>&1 &
  local up_pid=$!
  local network
  local cid
  local end=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$end" ]; do
    cid="$(container_id local-bootstrap)"
    [ -n "${cid:-}" ] && break
    sleep 2
  done
  [ -n "${cid:-}" ] || resilience_fail "local-bootstrap introuvable"
  network="$(compose_network_name)"
  docker network disconnect "$network" "$cid" > "${RESILIENCE_DIR}/disconnect-local-bootstrap.txt"
  local error_end=$((SECONDS + 180))
  local state=""
  while [ "$SECONDS" -lt "$error_end" ]; do
    state="$(status_expr "${BASE}" 'repr(data.get("state"))' 2>/dev/null | tr -d "'" || true)"
    [ "$state" = "error" ] && break
    sleep 5
  done
  [ "$state" = "error" ] || resilience_fail "Le statut n'est pas passe a error apres interruption bootstrap"
  wait "$up_pid" || true
  cleanup_stack
  ensure_hybrid_ready
}

case "${QA_PHASE}" in
  pre-reboot)
    mkdir -p "${ROOT_DIR}/var/qa"
    ensure_hybrid_ready
    snapshot_runtime "resilience-pre-reboot"
    printf 'post-reboot\n' > "${ROOT_DIR}/var/qa/reboot-phase.txt"
    if [ "${QA_STRICT_ROOT}" = "1" ]; then
      root_host_available || resilience_fail "root_host indisponible pour installer le post-reboot"
      install_post_reboot_service
    fi
    log "Etat capture. Reboote l'hote puis relance QA_PHASE=post-reboot bash scripts/qa_resilience.sh"
    ;;
  post-reboot)
    wait_http_ok "${BASE}/_health" 600 || resilience_fail "Health KO apres reboot hote"
    wait_local_ready "${BASE}" 1800 || resilience_fail "Local non pret apres reboot hote"
    snapshot_runtime "resilience-post-reboot"
    if [ "${QA_UNINSTALL_POST_REBOOT_SERVICE}" = "1" ]; then
      root_host_available || resilience_fail "root_host indisponible pour desinstaller le service post-reboot"
      uninstall_post_reboot_service
    fi
    ;;
  all)
    backup_env
    trap 'restore_env' EXIT
    cleanup_stack
    ensure_hybrid_ready
    test_local_service_restart
    test_docker_restart
    test_failback_upstream_outage
    test_geopf_outage_update
    test_bootstrap_interruption
    snapshot_runtime "resilience-final"
    cleanup_stack
    ;;
  *)
    resilience_fail "QA_PHASE inconnu: ${QA_PHASE}"
    ;;
esac

log "Campagne resilience: OK (${QA_PHASE})"
