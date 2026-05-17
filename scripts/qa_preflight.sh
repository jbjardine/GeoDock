#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT_DIR}/scripts/qa_lib.sh"

QA_MIN_VCPU="${QA_MIN_VCPU:-8}"
QA_MIN_RAM_GIB="${QA_MIN_RAM_GIB:-32}"
QA_MIN_DISK_GIB="${QA_MIN_DISK_GIB:-400}"
QA_PREFLIGHT_DIR="${QA_OUTPUT_ROOT}/preflight"
mkdir -p "${QA_PREFLIGHT_DIR}"

log "Preflight V2: capture de l'environnement"
date -Is > "${QA_PREFLIGHT_DIR}/timestamp.txt"
uname -a > "${QA_PREFLIGHT_DIR}/uname.txt"
docker version > "${QA_PREFLIGHT_DIR}/docker-version.txt"
docker info > "${QA_PREFLIGHT_DIR}/docker-info.txt"
docker compose version > "${QA_PREFLIGHT_DIR}/docker-compose-version.txt"
df -h > "${QA_PREFLIGHT_DIR}/df-h.txt"
free -h > "${QA_PREFLIGHT_DIR}/free-h.txt"
nproc > "${QA_PREFLIGHT_DIR}/nproc.txt"

VCPU="$(nproc)"
RAM_GIB="$(free -g | awk '/Mem:/ {print $2}')"
DISK_GIB="$(df -BG / | awk 'NR==2 { gsub("G","",$2); print $2 }')"

[ "${VCPU}" -ge "${QA_MIN_VCPU}" ] || fail "vCPU insuffisant: ${VCPU} < ${QA_MIN_VCPU}"
[ "${RAM_GIB}" -ge "${QA_MIN_RAM_GIB}" ] || fail "RAM insuffisante: ${RAM_GIB} GiB < ${QA_MIN_RAM_GIB} GiB"
[ "${DISK_GIB}" -ge "${QA_MIN_DISK_GIB}" ] || fail "Disque insuffisant: ${DISK_GIB} GiB < ${QA_MIN_DISK_GIB} GiB"

curl -fsS "https://api-adresse.data.gouv.fr/search/?q=paris&limit=1" > "${QA_PREFLIGHT_DIR}/api-adresse-search.json"
curl -fsSI https://data.geopf.fr/telechargement/capabilities > "${QA_PREFLIGHT_DIR}/geopf.head.txt"

if [ -f "${ROOT_DIR}/.env" ]; then
  compose config > "${QA_PREFLIGHT_DIR}/compose-config.yml"
fi

log "Preflight V2: OK"
