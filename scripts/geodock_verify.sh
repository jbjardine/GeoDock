#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT_DIR}"

read_env(){
  awk -F= -v key="$1" '$1==key{print substr($0, index($0,"=")+1)}' .env 2>/dev/null | tr -d '\r' | tail -n 1
}

http_port="$(read_env HOST_PORT_HTTP)"
http_port="${http_port:-80}"
BASE="${BASE:-http://localhost:${http_port}}"
QUERY="${QUERY:-/search/?q=paris&limit=1}"
PARCEL_QUERY="${PARCEL_QUERY:-/reverse/?lat=42.947492&lon=1.958315&index=parcel&limit=1}"
POI_QUERY="${POI_QUERY:-/search/?q=mairie&index=poi&limit=5}"
INSECURE_SSL="${INSECURE_SSL:-0}"
EXPECT_MODE="${EXPECT_MODE:-}"
EXPECT_UPSTREAM="${EXPECT_UPSTREAM:-}"
EXPECT_STATUS_STATE="${EXPECT_STATUS_STATE:-}"
EXPECT_STATUS_MODE="${EXPECT_STATUS_MODE:-}"
EXPECT_STATUS_UPSTREAM="${EXPECT_STATUS_UPSTREAM:-}"
VERIFY_PARCEL="${VERIFY_PARCEL:-0}"
VERIFY_POI="${VERIFY_POI:-0}"

curl_args=(--max-time 15 -sS -L)
if [ "${INSECURE_SSL}" = "1" ]; then
  curl_args=(-k "${curl_args[@]}")
fi

status=0
tmp_headers="$(mktemp)"
tmp_body="$(mktemp)"
tmp_status_body="$(mktemp)"
trap 'rm -f "$tmp_headers" "$tmp_body" "$tmp_status_body"' EXIT

run_check(){
  local label="$1"
  local url="$2"
  local http_code=""
  echo "[geodock_verify] GET ${url} (${label})"
  : > "$tmp_headers"
  : > "$tmp_body"
  if ! http_code="$(curl "${curl_args[@]}" -w '%{http_code}' -D "$tmp_headers" -o "$tmp_body" "$url")"; then
    status=1
    echo "[geodock_verify] ERROR: requete echouee pour ${label}" >&2
  elif [ "${http_code}" -lt 200 ] || [ "${http_code}" -ge 300 ]; then
    status=1
    echo "[geodock_verify] ERROR: HTTP ${http_code} pour ${label}" >&2
  fi
  if [ "$label" = "status" ]; then
    cp "$tmp_body" "$tmp_status_body"
  fi
  cat "$tmp_headers"
  head -n 60 "$tmp_body" || true
  echo
}

run_check "health" "${BASE}/_health"
run_check "status" "${BASE}/_status"
run_check "address" "${BASE}${QUERY}"
if [ "$VERIFY_PARCEL" = "1" ]; then
  run_check "parcel" "${BASE}${PARCEL_QUERY}"
fi
if [ "$VERIFY_POI" = "1" ]; then
  run_check "poi" "${BASE}${POI_QUERY}"
fi

if [ -n "$EXPECT_MODE" ] && ! grep -qi "^X-Geodock-Mode: ${EXPECT_MODE}\b" "$tmp_headers"; then
  echo "[geodock_verify] ERROR: header X-Geodock-Mode attendu=${EXPECT_MODE}" >&2
  status=1
fi
if [ -n "$EXPECT_UPSTREAM" ] && ! grep -qi "^X-Geodock-Upstream: ${EXPECT_UPSTREAM}\b" "$tmp_headers"; then
  echo "[geodock_verify] ERROR: header X-Geodock-Upstream attendu=${EXPECT_UPSTREAM}" >&2
  status=1
fi

check_status_field(){
  local field="$1"
  local expected="$2"
  if command -v python3 >/dev/null 2>&1; then
    if ! python3 - "$tmp_status_body" "$field" "$expected" <<'PY'
import json, sys
path, field, expected = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(field)
if value != expected:
    raise SystemExit(1)
PY
    then
      echo "[geodock_verify] ERROR: _status.${field} attendu=${expected}" >&2
      status=1
    fi
  elif command -v python >/dev/null 2>&1; then
    if ! python - "$tmp_status_body" "$field" "$expected" <<'PY'
import json, sys
path, field, expected = sys.argv[1:]
with open(path, "r", encoding="utf-8") as fh:
    data = json.load(fh)
value = data.get(field)
if value != expected:
    raise SystemExit(1)
PY
    then
      echo "[geodock_verify] ERROR: _status.${field} attendu=${expected}" >&2
      status=1
    fi
  elif ! grep -Eq "\"${field}\"[[:space:]]*:[[:space:]]*\"${expected}\"" "$tmp_status_body"; then
    echo "[geodock_verify] ERROR: _status.${field} attendu=${expected}" >&2
    status=1
  fi
}

if [ -n "$EXPECT_STATUS_STATE" ]; then
  check_status_field state "$EXPECT_STATUS_STATE"
fi
if [ -n "$EXPECT_STATUS_MODE" ]; then
  check_status_field mode "$EXPECT_STATUS_MODE"
fi
if [ -n "$EXPECT_STATUS_UPSTREAM" ]; then
  check_status_field upstream_active "$EXPECT_STATUS_UPSTREAM"
fi

exit "$status"
