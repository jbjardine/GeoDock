#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT_DIR}/scripts/qa_lib.sh"

QA_SCENARIOS="${QA_SCENARIOS:-proxy,local,hybrid,failback}"
QA_SCOPE_DEPARTEMENTS="${QA_SCOPE_DEPARTEMENTS:-11,75,92}"
QA_SERVER_NAME="${QA_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}"
QA_WAIT_REMOTE_SEC="${QA_WAIT_REMOTE_SEC:-300}"
QA_WAIT_LOCAL_SEC="${QA_WAIT_LOCAL_SEC:-7200}"
BASE="$(base_http_url)"
ADDRESS_QUERY="/search/?q=paris&limit=1"

wait_address_upstream(){
  local expected="$1"
  local timeout="$2"
  local end=$((SECONDS + timeout))
  while [ "$SECONDS" -lt "$end" ]; do
    if assert_header "${BASE}${ADDRESS_QUERY}" "X-Geodock-Upstream" "$expected"; then
      return 0
    fi
    sleep 3
  done
  return 1
}

install_mode(){
  local mode="$1"
  bash "${ROOT_DIR}/scripts/geodock_up.sh" \
    --yes \
    --mode "$mode" \
    --server-name "${QA_SERVER_NAME}" \
    --scope departements \
    --departements "${QA_SCOPE_DEPARTEMENTS}" \
    --auto-update false \
    --local-source build
}

log "Smoke matrix V2 sur ${QA_SCENARIOS}"
backup_env
trap 'restore_env' EXIT

IFS=',' read -r -a scenarios <<< "${QA_SCENARIOS}"
for raw_mode in "${scenarios[@]}"; do
  mode="$(printf '%s' "$raw_mode" | xargs)"
  [ -n "$mode" ] || continue
  scenario_dir="${QA_OUTPUT_ROOT}/smoke-${mode}"
  mkdir -p "${scenario_dir}"
  log "Scenario smoke: ${mode}"

  cleanup_stack
  snapshot_runtime "smoke-${mode}-before"
  install_mode "${mode}" | tee "${scenario_dir}/geodock-up.log"

  wait_http_ok "${BASE}/_health" 600 || fail "Health KO pour ${mode}"
  snapshot_runtime "smoke-${mode}-started"

  case "${mode}" in
    proxy|remote)
      assert_status_contract "${BASE}" --expected-mode "proxy" --expected-state "ready" --expected-upstream "remote" >/dev/null 2>&1 || \
        assert_status_contract "${BASE}" --expected-mode "remote" --expected-state "ready" --expected-upstream "remote"
      EXPECT_MODE="proxy" EXPECT_UPSTREAM="remote" EXPECT_STATUS_STATE="ready" EXPECT_STATUS_MODE="proxy" EXPECT_STATUS_UPSTREAM="remote" bash "${ROOT_DIR}/scripts/geodock_verify.sh" \
        > "${scenario_dir}/verify.txt" 2>&1 || EXPECT_MODE="remote" EXPECT_UPSTREAM="remote" EXPECT_STATUS_STATE="ready" EXPECT_STATUS_MODE="remote" EXPECT_STATUS_UPSTREAM="remote" bash "${ROOT_DIR}/scripts/geodock_verify.sh" \
        > "${scenario_dir}/verify.txt" 2>&1
      ;;
    local)
      assert_status_contract "${BASE}" --expected-mode "local" --require-local-enabled > "${scenario_dir}/status-contract.json"
      wait_local_ready "${BASE}" "${QA_WAIT_LOCAL_SEC}" || fail "Local not ready pour ${mode}"
      EXPECT_MODE="local" EXPECT_UPSTREAM="local" VERIFY_PARCEL=1 VERIFY_POI=1 bash "${ROOT_DIR}/scripts/geodock_verify.sh" \
        > "${scenario_dir}/verify.txt" 2>&1
      ;;
    hybrid)
      assert_status_contract "${BASE}" --expected-mode "hybrid" --require-local-enabled > "${scenario_dir}/status-contract.json"
      wait_address_upstream remote "${QA_WAIT_REMOTE_SEC}" || fail "Hybrid n'a pas servi le distant pendant le bootstrap"
      wait_local_ready "${BASE}" "${QA_WAIT_LOCAL_SEC}" || fail "Hybrid local not ready"
      EXPECT_MODE="hybrid" EXPECT_UPSTREAM="local" VERIFY_PARCEL=1 VERIFY_POI=1 bash "${ROOT_DIR}/scripts/geodock_verify.sh" \
        > "${scenario_dir}/verify-local.txt" 2>&1
      compose stop geocoder-api > "${scenario_dir}/inject-stop-geocoder-api.txt" 2>&1
      wait_address_upstream remote 180 || fail "Hybrid n'a pas bascule sur remote apres stop geocoder-api"
      compose start geocoder-api > "${scenario_dir}/restore-geocoder-api.txt" 2>&1
      wait_local_ready "${BASE}" 1800 || fail "Hybrid n'a pas recupere apres restart geocoder-api"
      ;;
    failback)
      assert_status_contract "${BASE}" --expected-mode "failback" --require-local-enabled > "${scenario_dir}/status-contract.json"
      wait_address_upstream remote "${QA_WAIT_REMOTE_SEC}" || fail "Failback n'a pas servi le distant pendant le bootstrap"
      wait_local_ready "${BASE}" "${QA_WAIT_LOCAL_SEC}" || fail "Failback local not ready"
      EXPECT_MODE="failback" EXPECT_UPSTREAM="remote" bash "${ROOT_DIR}/scripts/geodock_verify.sh" \
        > "${scenario_dir}/verify-remote.txt" 2>&1
      original_upstream_ban="$(read_env UPSTREAM_BAN)"
      write_env UPSTREAM_BAN http://127.0.0.1:9
      compose up -d --force-recreate --no-deps proxy > "${scenario_dir}/inject-upstream-failure.txt" 2>&1
      wait_address_upstream local 180 || fail "Failback n'a pas bascule sur local quand l'upstream est casse"
      EXPECT_MODE="failback" EXPECT_UPSTREAM="local" VERIFY_PARCEL=1 VERIFY_POI=1 bash "${ROOT_DIR}/scripts/geodock_verify.sh" \
        > "${scenario_dir}/verify-local-fallback.txt" 2>&1
      write_env UPSTREAM_BAN "${original_upstream_ban:-https://api-adresse.data.gouv.fr}"
      compose up -d --force-recreate --no-deps proxy > "${scenario_dir}/restore-upstream.txt" 2>&1
      wait_address_upstream remote 180 || fail "Failback n'a pas restaure le distant"
      ;;
    *)
      fail "Mode inconnu dans smoke matrix: ${mode}"
      ;;
  esac

  snapshot_runtime "smoke-${mode}-after"
done

cleanup_stack
log "Smoke matrix V2: OK"
