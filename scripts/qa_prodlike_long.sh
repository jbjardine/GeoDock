#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT_DIR}/scripts/qa_lib.sh"

QA_SERVER_NAME="${QA_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}"
QA_SOAK_HOURS="${QA_SOAK_HOURS:-24}"
QA_SOAK_INTERVAL_SEC="${QA_SOAK_INTERVAL_SEC:-300}"
QA_REMOTE_READY_SEC="${QA_REMOTE_READY_SEC:-300}"
QA_LOCAL_READY_SEC="${QA_LOCAL_READY_SEC:-86400}"
QA_BOOTSTRAP_STATUS_INTERVAL_SEC="${QA_BOOTSTRAP_STATUS_INTERVAL_SEC:-60}"
QA_BOOTSTRAP_RUNTIME_SNAPSHOT_SEC="${QA_BOOTSTRAP_RUNTIME_SNAPSHOT_SEC:-300}"
QA_BOOTSTRAP_FREEZE_SEC="${QA_BOOTSTRAP_FREEZE_SEC:-900}"
QA_BOOTSTRAP_MISSING_LOCAL_SEC="${QA_BOOTSTRAP_MISSING_LOCAL_SEC:-900}"
QA_RAM_STABLE_MODE="${QA_RAM_STABLE_MODE:-percent}"
QA_MIN_RAM_FREE_PERCENT="${QA_MIN_RAM_FREE_PERCENT:-20}"
QA_MIN_SWAP_FREE_MIB="${QA_MIN_SWAP_FREE_MIB:-4096}"
PRODLIKE_DIR="${QA_OUTPUT_ROOT}/prodlike"
mkdir -p "${PRODLIKE_DIR}"
BASE="$(base_http_url)"

log "Qualification longue prod-like"
backup_env
trap 'restore_env' EXIT

GEODOCK_UP_PID=""

prodlike_fail(){
  local message="$*"
  if [ -n "${GEODOCK_UP_PID:-}" ] && kill -0 "${GEODOCK_UP_PID}" 2>/dev/null; then
    kill "${GEODOCK_UP_PID}" 2>/dev/null || true
  fi
  capture_prodlike_failure
  write_marker "FAILED" "prodlike: ${message}"
  fail "${message}"
}

capture_prodlike_failure(){
  snapshot_runtime "prodlike-failure"
  compose_service_logs "${PRODLIKE_DIR}/failure-logs" \
    local-bootstrap \
    local-maintainer \
    geocoder-api \
    geocoder-address \
    geocoder-parcel \
    geocoder-poi \
    proxy
  curl -fsS "${BASE}/_status" > "${PRODLIKE_DIR}/failure-status.json" 2>&1 || true
}

local_runtime_present(){
  local service
  for service in local-bootstrap local-maintainer geocoder-api geocoder-address geocoder-parcel geocoder-poi; do
    if [ -n "$(container_id "$service")" ]; then
      return 0
    fi
  done
  return 1
}

check_memory_stability(){
  local label="$1"
  local summary
  summary="$(memory_stability_summary)"
  printf '%s\n' "${summary}" > "${PRODLIKE_DIR}/memory-${label}.txt"
  memory_stability_ok || prodlike_fail "Memoire stable insuffisante ${label}: ${summary}"
}

wait_local_ready_with_heartbeat(){
  local base="$1"
  local timeout="$2"
  local end=$((SECONDS + timeout))
  local status_idx=0
  local runtime_idx=0
  local next_runtime_snapshot=$SECONDS
  local last_updated=""
  local last_updated_change=$SECONDS
  local last_signature=""
  local last_signature_change=$SECONDS
  local last_local_runtime_seen=$SECONDS

  while [ "$SECONDS" -lt "$end" ]; do
    local status_file="${PRODLIKE_DIR}/bootstrap-status-${status_idx}.json"
    status_idx=$((status_idx + 1))
    if ! curl -fsS "${base}/_status" > "${status_file}"; then
      sleep "${QA_BOOTSTRAP_STATUS_INTERVAL_SEC}"
      continue
    fi

    local parsed
    parsed="$(
      qa_python -c 'import json,sys
path=sys.argv[1]
with open(path, encoding="utf-8") as fh:
    data=json.load(fh)
local_ready=data.get("local_ready", {})
fields=[
    data.get("state",""),
    data.get("updated_at",""),
    data.get("current_step",""),
    "1" if local_ready.get("address") else "0",
    "1" if local_ready.get("parcel") else "0",
    "1" if local_ready.get("poi") else "0",
    "1" if local_ready.get("api") else "0",
]
print("\t".join(fields))' "${status_file}"
    )"

    local state updated_at current_step address_ready parcel_ready poi_ready api_ready
    IFS=$'\t' read -r state updated_at current_step address_ready parcel_ready poi_ready api_ready <<< "${parsed}"

    if [ -n "${updated_at}" ] && [ "${updated_at}" != "${last_updated}" ]; then
      last_updated="${updated_at}"
      last_updated_change=$SECONDS
    fi

    local signature="${current_step}|${address_ready}${parcel_ready}${poi_ready}${api_ready}"
    if [ "${signature}" != "${last_signature}" ]; then
      last_signature="${signature}"
      last_signature_change=$SECONDS
    fi

    if [ "${state}" = "ready" ] && [ "${address_ready}" = "1" ] && [ "${parcel_ready}" = "1" ] && [ "${poi_ready}" = "1" ] && [ "${api_ready}" = "1" ]; then
      return 0
    fi

    [ "${state}" != "error" ] || prodlike_fail "Etat error detecte pendant le bootstrap France"
    [ "${state}" != "degraded" ] || prodlike_fail "Etat degraded detecte pendant le bootstrap France"

    if local_runtime_present; then
      last_local_runtime_seen=$SECONDS
    fi

    if [ $((SECONDS - last_updated_change)) -ge "${QA_BOOTSTRAP_FREEZE_SEC}" ]; then
      prodlike_fail "Freeze bootstrap detecte: updated_at ne bouge plus depuis ${QA_BOOTSTRAP_FREEZE_SEC}s"
    fi

    if [ $((SECONDS - last_signature_change)) -ge "${QA_BOOTSTRAP_FREEZE_SEC}" ]; then
      prodlike_fail "Freeze bootstrap detecte: current_step/local_ready n'evoluent plus depuis ${QA_BOOTSTRAP_FREEZE_SEC}s"
    fi

    if [ $((SECONDS - last_local_runtime_seen)) -ge "${QA_BOOTSTRAP_MISSING_LOCAL_SEC}" ]; then
      prodlike_fail "Les conteneurs locaux ont disparu trop longtemps pendant le bootstrap"
    fi

    if [ "$SECONDS" -ge "${next_runtime_snapshot}" ]; then
      snapshot_runtime "bootstrap-runtime-${runtime_idx}"
      runtime_idx=$((runtime_idx + 1))
      next_runtime_snapshot=$((SECONDS + QA_BOOTSTRAP_RUNTIME_SNAPSHOT_SEC))
    fi

    sleep "${QA_BOOTSTRAP_STATUS_INTERVAL_SEC}"
  done

  prodlike_fail "France entiere non prete dans le delai"
}

bash "${ROOT_DIR}/scripts/qa_preflight.sh" | tee "${PRODLIKE_DIR}/preflight.log"
cleanup_stack

start_epoch="$(date +%s)"
bash "${ROOT_DIR}/scripts/geodock_up.sh" --yes --mode hybrid --server-name "${QA_SERVER_NAME}" --scope france --auto-update false \
  > "${PRODLIKE_DIR}/hybrid-france-up.log" 2>&1 &
GEODOCK_UP_PID=$!
wait_address_upstream_remote(){
  local end=$((SECONDS + QA_REMOTE_READY_SEC))
  while [ "$SECONDS" -lt "$end" ]; do
    if assert_header "${BASE}/search/?q=paris&limit=1" "X-Geodock-Upstream" "remote"; then
      return 0
    fi
    sleep 3
  done
  return 1
}
wait_address_upstream_remote || prodlike_fail "Aucune premiere reponse utile distante dans le delai"
first_useful_epoch="$(date +%s)"

wait_local_ready_with_heartbeat "${BASE}" "${QA_LOCAL_READY_SEC}"
if ! wait "${GEODOCK_UP_PID}"; then
  prodlike_fail "geodock_up.sh a echoue pendant le bootstrap France"
fi
GEODOCK_UP_PID=""
ready_epoch="$(date +%s)"
echo "$((first_useful_epoch - start_epoch))" > "${PRODLIKE_DIR}/time-to-first-useful-sec.txt"
echo "$((ready_epoch - start_epoch))" > "${PRODLIKE_DIR}/time-to-local-ready-sec.txt"
EXPECT_MODE=hybrid EXPECT_UPSTREAM=local VERIFY_PARCEL=1 VERIFY_POI=1 bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${PRODLIKE_DIR}/hybrid-ready-verify.txt"

[ "$(disk_free_gib)" -ge 80 ] || prodlike_fail "Moins de 80 GiB libres apres bootstrap France"
check_memory_stability "after-bootstrap"

soak_end=$((SECONDS + QA_SOAK_HOURS * 3600))
idx=0
while [ "$SECONDS" -lt "$soak_end" ]; do
  idx=$((idx + 1))
  curl -fsS "${BASE}/_health" > "${PRODLIKE_DIR}/soak-health-${idx}.json"
  curl -fsS "${BASE}/_status" > "${PRODLIKE_DIR}/soak-status-${idx}.json"
  curl -fsS "${BASE}/search/?q=paris&limit=1" > "${PRODLIKE_DIR}/soak-address-${idx}.json"
  qa_python "${ROOT_DIR}/scripts/qa_status_contract.py" --file "${PRODLIKE_DIR}/soak-status-${idx}.json" --expected-mode hybrid --require-local-enabled >/dev/null
  state="$(qa_python -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(d["state"])' "${PRODLIKE_DIR}/soak-status-${idx}.json")"
  [ "$state" != "error" ] || prodlike_fail "Etat error detecte pendant le soak"
  [ "$state" != "degraded" ] || prodlike_fail "Etat degraded detecte pendant le soak"
  sleep "${QA_SOAK_INTERVAL_SEC}"
done

bash "${ROOT_DIR}/scripts/geodock_reconfigure.sh" --yes --mode local --server-name "${QA_SERVER_NAME}" --scope france --auto-update false > "${PRODLIKE_DIR}/switch-local.log"
wait_local_ready "${BASE}" 3600 || prodlike_fail "Mode local non pret apres reconfiguration"
EXPECT_MODE=local EXPECT_UPSTREAM=local VERIFY_PARCEL=1 VERIFY_POI=1 bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${PRODLIKE_DIR}/local-verify.txt"

bash "${ROOT_DIR}/scripts/geodock_reconfigure.sh" --yes --mode proxy --server-name "${QA_SERVER_NAME}" > "${PRODLIKE_DIR}/switch-proxy.log"
EXPECT_MODE=proxy EXPECT_UPSTREAM=remote bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${PRODLIKE_DIR}/proxy-verify.txt"

bash "${ROOT_DIR}/scripts/geodock_reconfigure.sh" --yes --mode failback --server-name "${QA_SERVER_NAME}" --scope france --auto-update false > "${PRODLIKE_DIR}/switch-failback.log"
wait_local_ready "${BASE}" 3600 || prodlike_fail "Mode failback non pret apres reconfiguration"
EXPECT_MODE=failback EXPECT_UPSTREAM=remote bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${PRODLIKE_DIR}/failback-verify.txt"

[ "$(disk_free_gib)" -ge 80 ] || prodlike_fail "Moins de 80 GiB libres en fin de qualification"
check_memory_stability "final"

snapshot_runtime "prodlike-final"
write_marker "prodlike.ok" "OK"
cleanup_stack
log "Qualification longue prod-like: OK"
