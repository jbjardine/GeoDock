#!/usr/bin/env bash
set -euo pipefail

SERVICE_KIND="${1:-}"
STATUSCTL="/opt/geodock-runtime/scripts/statusctl.py"
LOCAL_SOURCE="${LOCAL_SOURCE:-build}"
BOOTSTRAP_TIMEOUT="${LOCAL_BOOTSTRAP_TIMEOUT:-86400}"
DATA_PATH="${DATA_PATH:-/data}"

log(){ printf '[start_service] %s %s\n' "$(date -Is)" "$*"; }

wait_for_file(){
  local path="$1"
  local waited=0
  while [ ! -f "$path" ]; do
    if [ "$waited" -ge "$BOOTSTRAP_TIMEOUT" ]; then
      python "$STATUSCTL" update --state error --current-step "Timeout en attente de $path" --last-error "Timeout bootstrap local"
      log "timeout waiting for $path"
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

flatten_if_needed(){
  local root="$1"
  if [ -d "$root/index" ]; then
    cp -a "$root/index/." "$root/"
    rm -rf "$root/index"
  fi
}

case "$SERVICE_KIND" in
  address)
    python "$STATUSCTL" update --state "bootstrapping" --current-step "Preparation du service address"
    if [ "$LOCAL_SOURCE" = "archive" ]; then
      python "$STATUSCTL" update --state downloading --current-step "Telechargement de l'index address"
      test -f "$DATA_PATH/address/index/address.mdb" || yarn address:download-index
    else
      wait_for_file "$DATA_PATH/address/index/address.mdb"
    fi
    flatten_if_needed "$DATA_PATH/address/index"
    python "$STATUSCTL" watch-port --component address --host 127.0.0.1 --port "${ADDRESS_SERVICE_PORT:-3001}" --timeout 1800 &
    exec yarn address:start
    ;;
  parcel)
    python "$STATUSCTL" update --state "bootstrapping" --current-step "Preparation du service parcel"
    if [ "$LOCAL_SOURCE" = "archive" ]; then
      python "$STATUSCTL" update --state downloading --current-step "Telechargement de l'index parcel"
      test -f "$DATA_PATH/parcel/index/parcel.mdb" || yarn parcel:download-index
    else
      wait_for_file "$DATA_PATH/parcel/index/parcel.mdb"
    fi
    flatten_if_needed "$DATA_PATH/parcel/index"
    python "$STATUSCTL" watch-port --component parcel --host 127.0.0.1 --port "${PARCEL_SERVICE_PORT:-3002}" --timeout 1800 &
    exec yarn parcel:start
    ;;
  poi)
    python "$STATUSCTL" update --state "bootstrapping" --current-step "Preparation du service poi"
    if [ "$LOCAL_SOURCE" = "archive" ]; then
      python "$STATUSCTL" update --state downloading --current-step "Telechargement de l'index poi"
      test -f "$DATA_PATH/poi/index/poi.mdb" || yarn poi:download-index
    else
      wait_for_file "$DATA_PATH/poi/index/poi.mdb"
    fi
    flatten_if_needed "$DATA_PATH/poi/index"
    python "$STATUSCTL" watch-port --component poi --host 127.0.0.1 --port "${POI_SERVICE_PORT:-3003}" --timeout 1800 &
    exec yarn poi:start
    ;;
  api)
    python "$STATUSCTL" update --state starting --current-step "Activation du backend local"
    wait_for_file "$DATA_PATH/address/index/address.mdb"
    wait_for_file "$DATA_PATH/parcel/index/parcel.mdb"
    wait_for_file "$DATA_PATH/poi/index/poi.mdb"
    python "$STATUSCTL" watch-port --component api --host 127.0.0.1 --port "${API_PORT:-3000}" --timeout 1800 &
    exec yarn api:start
    ;;
  *)
    log "unknown service kind: $SERVICE_KIND"
    exit 1
    ;;
esac
