#!/usr/bin/env bash
set -euo pipefail

log(){ printf '[updater] %s %s\n' "$(date -Is)" "$*"; }

flatten_index_dir(){
  local root="$1"
  if [ -d "$root/index" ]; then
    cp -a "$root/index/." "$root/"
    rm -rf "$root/index"
  fi
}

STATE_DIR="/data/.meta"
mkdir -p "$STATE_DIR"

compose(){ docker compose "$@"; }

get_env(){
  local svc="$1" var="$2"
  compose exec -T "$svc" /bin/sh -lc "printenv $var" 2>/dev/null || true
}

etag_of(){
  local url="$1"
  [ -z "$url" ] && return 1
  local headers
  headers=$(curl -sI -L "$url" || true)
  local etag lm
  etag=$(printf '%s' "$headers" | awk -F': ' 'tolower($1)=="etag"{print $2}' | tr -d '\r"')
  lm=$(printf '%s' "$headers" | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tr -d '\r')
  if [ -n "$etag" ]; then
    printf '%s' "$etag"
  else
    printf '%s' "$lm"
  fi
}

needs_update(){
  local key="$1" sig="$2" file="$STATE_DIR/$1.sig"
  [ ! -f "$file" ] && return 0
  local old
  old=$(cat "$file" || true)
  [ "$sig" != "$old" ]
}

store_sig(){ echo -n "$2" > "$STATE_DIR/$1.sig"; }

resolve_source_url(){
  local svc="$1" archive_var="$2" resolver_var="$3"
  local archive_url resolver_url
  archive_url=$(get_env "$svc" "$archive_var")
  if [ -n "$archive_url" ]; then
    printf '%s' "$archive_url"
    return 0
  fi

  resolver_url=$(get_env "$svc" "$resolver_var")
  if [ -n "$resolver_url" ]; then
    printf '%s' "$resolver_url"
    return 0
  fi

  return 1
}

update_component(){
  local name="$1" svc="$2" archive_var="$3" resolver_var="$4" download_cmd="$5" restart_svcs="$6"
  local url sig
  url=$(resolve_source_url "$svc" "$archive_var" "$resolver_var") || {
    log "skip $name: neither $archive_var nor $resolver_var set on $svc"
    return 0
  }

  sig=$(etag_of "$url") || true
  if [ -z "$sig" ]; then
    log "warn $name: no ETag/Last-Modified from $url"
  fi

  if [ -z "$sig" ] || needs_update "$name" "$sig"; then
    log "$name: change detected -> downloading new index"
    compose exec -T "$svc" /bin/sh -lc "$download_cmd" || {
      log "$name: download failed"
      return 1
    }
    case "$name" in
      address) compose exec -T "$svc" /bin/sh -lc 'cp -a /data/address/index/index/. /data/address/index/ 2>/dev/null || true; rm -rf /data/address/index/index 2>/dev/null || true' ;;
      parcel) compose exec -T "$svc" /bin/sh -lc 'cp -a /data/parcel/index/index/. /data/parcel/index/ 2>/dev/null || true; rm -rf /data/parcel/index/index 2>/dev/null || true' ;;
      poi) compose exec -T "$svc" /bin/sh -lc 'cp -a /data/poi/index/index/. /data/poi/index/ 2>/dev/null || true; rm -rf /data/poi/index/index 2>/dev/null || true' ;;
    esac
    for r in $restart_svcs; do
      log "$name: restarting $r"
      compose restart "$r" || true
    done
    store_sig "$name" "$sig"
    log "$name: updated"
  else
    log "$name: up-to-date"
  fi
}

log "start"

update_component address geocoder-address ADDRESS_ARCHIVE_URL ADDRESS_ARCHIVE_URL_RESOLVER "yarn address:download-index" "geocoder-address geocoder-api"
update_component parcel  geocoder-parcel  PARCEL_ARCHIVE_URL  PARCEL_ARCHIVE_URL_RESOLVER  "yarn parcel:download-index"  "geocoder-parcel geocoder-api"
update_component poi     geocoder-poi     POI_ARCHIVE_URL     POI_ARCHIVE_URL_RESOLVER     "yarn poi:download-index"     "geocoder-poi geocoder-api"

log "done"
