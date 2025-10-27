#!/bin/sh
set -e

case "${MODE:-remote}" in
  remote|proxy)
    export FALLBACK_LOCATION='@remote_fallback' ;;
  local|hybrid)
    export FALLBACK_LOCATION='@remote_fallback' ;;
  failback)
    export FALLBACK_LOCATION='@local_fallback' ;;
  *)
    export FALLBACK_LOCATION='@remote_fallback' ;;
esac

if [ -z "${SSL_PROTOCOLS:-}" ]; then
  export SSL_PROTOCOLS='TLSv1.2 TLSv1.3'
fi

# Defaults for optional toggles
if [ -z "${EXPOSE_HEALTH_ON_HTTP:-}" ]; then
  export EXPOSE_HEALTH_ON_HTTP='true'
fi

# Normalize CRLFs that may come from a Windows-edited .env
# This avoids issues like REDIRECT_HTTP_TO_HTTPS='true\r'
strip_cr() { printf '%s' "$1" | tr -d '\r'; }
export MODE="$(strip_cr "${MODE:-remote}")"
export SERVER_NAME="$(strip_cr "${SERVER_NAME:-geodock.intra}")"
export UPSTREAM_BAN="$(strip_cr "${UPSTREAM_BAN:-https://api-adresse.data.gouv.fr}")"
export UPSTREAM_HOST="$(strip_cr "${UPSTREAM_HOST:-api-adresse.data.gouv.fr}")"
export SSL_PROTOCOLS="$(strip_cr "${SSL_PROTOCOLS}")"
export UPSTREAM_SSL_PROTOCOLS="$(strip_cr "${UPSTREAM_SSL_PROTOCOLS:-TLSv1.3}")"
export REDIRECT_HTTP_TO_HTTPS="$(strip_cr "${REDIRECT_HTTP_TO_HTTPS:-false}")"
export EXPOSE_HEALTH_ON_HTTP="$(strip_cr "${EXPOSE_HEALTH_ON_HTTP:-true}")"

# Limit envsubst to only our placeholders to keep nginx $vars intact
# Use ${VAR} list as expected by the official envsubst wrapper
export NGINX_ENVSUBST_FILTER='${MODE} ${SERVER_NAME} ${UPSTREAM_BAN} ${SSL_PROTOCOLS} ${UPSTREAM_SSL_PROTOCOLS} ${UPSTREAM_HOST} ${REDIRECT_HTTP_TO_HTTPS} ${EXPOSE_HEALTH_ON_HTTP}'
