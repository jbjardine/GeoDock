#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT_DIR}/scripts/qa_lib.sh"

QA_SERVER_NAME="${QA_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}"
QA_SCOPE_DEPARTEMENTS="${QA_SCOPE_DEPARTEMENTS:-11,75,92}"
UPGRADE_DIR="${QA_OUTPUT_ROOT}/upgrade"
mkdir -p "${UPGRADE_DIR}"

log "Validation upgrade V1 proxy -> V2"
backup_env
trap 'restore_env' EXIT
cleanup_stack

cp "${ROOT_DIR}/.env.proxy.example" "${ROOT_DIR}/.env"
write_env MODE remote
write_env SERVER_NAME "${QA_SERVER_NAME}"
compose_proxy_only up -d --build proxy | tee "${UPGRADE_DIR}/v1-proxy-up.log"
wait_http_ok "$(base_http_url)/_health" 600 || fail "V1 proxy-only non joignable"
bash "${ROOT_DIR}/scripts/proxy_verify.sh" > "${UPGRADE_DIR}/v1-proxy-verify.txt"
compose_proxy_only down --remove-orphans >/dev/null 2>&1 || true

bash "${ROOT_DIR}/scripts/geodock_up.sh" --yes --mode proxy --server-name "${QA_SERVER_NAME}" | tee "${UPGRADE_DIR}/upgrade-v2-proxy.log"
wait_http_ok "$(base_http_url)/_health" 600 || fail "V2 proxy non joignable apres upgrade"
qa_python "${ROOT_DIR}/scripts/qa_status_contract.py" --file "${ROOT_DIR}/var/meta/status.json" --expected-mode proxy --expected-state ready --expected-upstream remote > "${UPGRADE_DIR}/v2-proxy-status-contract.json"
EXPECT_MODE=proxy EXPECT_UPSTREAM=remote EXPECT_STATUS_STATE=ready EXPECT_STATUS_MODE=proxy EXPECT_STATUS_UPSTREAM=remote bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${UPGRADE_DIR}/v2-proxy-verify.txt"

bash "${ROOT_DIR}/scripts/geodock_reconfigure.sh" --yes --mode hybrid --server-name "${QA_SERVER_NAME}" --scope departements --departements "${QA_SCOPE_DEPARTEMENTS}" --auto-update false \
  | tee "${UPGRADE_DIR}/reconfigure-hybrid.log"
wait_local_ready "$(base_http_url)" 7200 || fail "Hybrid non pret apres upgrade"
EXPECT_MODE=hybrid EXPECT_UPSTREAM=local VERIFY_PARCEL=1 VERIFY_POI=1 bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${UPGRADE_DIR}/hybrid-verify.txt"

bash "${ROOT_DIR}/scripts/geodock_reconfigure.sh" --yes --mode local --server-name "${QA_SERVER_NAME}" --scope departements --departements "${QA_SCOPE_DEPARTEMENTS}" --auto-update false \
  | tee "${UPGRADE_DIR}/reconfigure-local.log"
wait_local_ready "$(base_http_url)" 7200 || fail "Local non pret apres upgrade"
EXPECT_MODE=local EXPECT_UPSTREAM=local VERIFY_PARCEL=1 VERIFY_POI=1 bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${UPGRADE_DIR}/local-verify.txt"

bash "${ROOT_DIR}/scripts/geodock_reconfigure.sh" --yes --mode proxy --server-name "${QA_SERVER_NAME}" | tee "${UPGRADE_DIR}/reconfigure-proxy.log"
wait_http_ok "$(base_http_url)/_health" 600 || fail "Proxy non joignable apres retour proxy"
qa_python "${ROOT_DIR}/scripts/qa_status_contract.py" --file "${ROOT_DIR}/var/meta/status.json" --expected-mode proxy --expected-state ready --expected-upstream remote > "${UPGRADE_DIR}/proxy-return-status-contract.json"
EXPECT_MODE=proxy EXPECT_UPSTREAM=remote EXPECT_STATUS_STATE=ready EXPECT_STATUS_MODE=proxy EXPECT_STATUS_UPSTREAM=remote bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${UPGRADE_DIR}/proxy-return-verify.txt"

cleanup_stack
log "Validation upgrade V2: OK"
