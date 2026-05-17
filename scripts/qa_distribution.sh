#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT_DIR}/scripts/qa_lib.sh"

QA_SERVER_NAME="${QA_SERVER_NAME:-$(hostname -f 2>/dev/null || hostname)}"
QA_SCOPE_DEPARTEMENTS="${QA_SCOPE_DEPARTEMENTS:-11,75,92}"
DIST_DIR="${QA_OUTPUT_ROOT}/distribution"
mkdir -p "${DIST_DIR}"

log "Validation distribution V2"
backup_env
trap 'restore_env' EXIT

cleanup_stack
bash "${ROOT_DIR}/scripts/release_v2.sh" | tee "${DIST_DIR}/release-v2.log"
TARBALL="$(find "${ROOT_DIR}/dist" -maxdepth 1 -type f -name 'GeoDock-v2-*.tar.gz' | sort | tail -n 1)"
[ -n "${TARBALL}" ] || fail "tar.gz V2 introuvable"

EXTRACT_DIR="${DIST_DIR}/tarball"
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${TARBALL}" -C "${EXTRACT_DIR}"
PKG_DIR="$(find "${EXTRACT_DIR}" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[ -n "${PKG_DIR}" ] || fail "repertoire extrait introuvable"

(
  cd "${PKG_DIR}"
  bash scripts/geodock_up.sh --yes --mode proxy --server-name "${QA_SERVER_NAME}"
  wait_http_ok "http://localhost:80/_health" 600 || fail "Proxy tarball KO"
  qa_python scripts/qa_status_contract.py --file var/meta/status.json --expected-mode proxy --expected-state ready --expected-upstream remote > "${DIST_DIR}/tarball-proxy-status-contract.json"
  EXPECT_MODE=proxy EXPECT_UPSTREAM=remote EXPECT_STATUS_STATE=ready EXPECT_STATUS_MODE=proxy EXPECT_STATUS_UPSTREAM=remote bash scripts/geodock_verify.sh > "${DIST_DIR}/tarball-proxy-verify.txt"
  docker compose -f docker-compose.yml -f docker-compose.git.yml down -v --remove-orphans >/dev/null 2>&1 || true

  bash scripts/geodock_up.sh --yes --mode hybrid --server-name "${QA_SERVER_NAME}" --scope departements --departements "${QA_SCOPE_DEPARTEMENTS}" --auto-update false
  wait_http_ok "http://localhost:80/_health" 600 || fail "Health tarball hybrid KO"
  wait_local_ready "http://localhost:80" 7200 || fail "Hybrid tarball non pret"
  qa_python scripts/qa_status_contract.py --file var/meta/status.json --expected-mode hybrid --require-local-enabled > "${DIST_DIR}/tarball-hybrid-status-contract.json"
) | tee "${DIST_DIR}/tarball-install.log"

cleanup_stack
bash "${ROOT_DIR}/scripts/geodock_up.sh" --yes --mode proxy --server-name "${QA_SERVER_NAME}" --use-ghcr true \
  | tee "${DIST_DIR}/ghcr-proxy-install.log"
wait_http_ok "$(base_http_url)/_health" 600 || fail "Proxy GHCR KO"
qa_python "${ROOT_DIR}/scripts/qa_status_contract.py" --file "${ROOT_DIR}/var/meta/status.json" --expected-mode proxy --expected-state ready --expected-upstream remote > "${DIST_DIR}/ghcr-proxy-status-contract.json"
EXPECT_MODE=proxy EXPECT_UPSTREAM=remote EXPECT_STATUS_STATE=ready EXPECT_STATUS_MODE=proxy EXPECT_STATUS_UPSTREAM=remote bash "${ROOT_DIR}/scripts/geodock_verify.sh" > "${DIST_DIR}/ghcr-proxy-verify.txt"

cleanup_stack
write_env GEODOCK_PROXY_IMAGE ghcr.io/jbjardine/non-existent-geodock-proxy:rc
write_env GEODOCK_RUNTIME_IMAGE ghcr.io/jbjardine/non-existent-geodock-runtime:rc
bash "${ROOT_DIR}/scripts/geodock_up.sh" --yes --mode hybrid --server-name "${QA_SERVER_NAME}" --scope departements --departements "${QA_SCOPE_DEPARTEMENTS}" --auto-update false --use-ghcr true \
  | tee "${DIST_DIR}/fallback-build-install.log"
wait_http_ok "$(base_http_url)/_health" 600 || fail "Health fallback build KO"
wait_local_ready "$(base_http_url)" 7200 || fail "Hybrid fallback build non pret"
qa_python "${ROOT_DIR}/scripts/qa_status_contract.py" --file "${ROOT_DIR}/var/meta/status.json" --expected-mode hybrid --require-local-enabled > "${DIST_DIR}/fallback-status-contract.json"

cleanup_stack
restore_env
log "Validation distribution V2: OK"
