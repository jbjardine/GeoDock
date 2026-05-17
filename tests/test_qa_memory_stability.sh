#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

QA_OUTPUT_ROOT="${TMP_DIR}/out" QA_MARKER_DIR="${TMP_DIR}/markers" . "${ROOT_DIR}/scripts/qa_lib.sh"

assert_ok(){
  local message="$1"
  shift
  if ! "$@"; then
    printf 'not ok - %s\n' "${message}" >&2
    exit 1
  fi
}

assert_not_ok(){
  local message="$1"
  shift
  if "$@"; then
    printf 'not ok - %s\n' "${message}" >&2
    exit 1
  fi
}

memory_free_percent(){ printf '2\n'; }
# shellcheck disable=SC2317,SC2329
swap_free_mib(){ printf '40960\n'; }

QA_RAM_STABLE_MODE=percent QA_MIN_RAM_FREE_PERCENT=8
assert_not_ok "percent mode rejects low available RAM" memory_stability_ok

QA_RAM_STABLE_MODE=swap QA_MIN_SWAP_FREE_MIB=8192
assert_ok "swap mode accepts low RAM when swap headroom remains" memory_stability_ok

swap_free_mib(){ printf '1024\n'; }
assert_not_ok "swap mode rejects low swap headroom" memory_stability_ok

QA_RAM_STABLE_MODE=bogus
assert_not_ok "unknown mode is rejected" memory_stability_ok

printf 'ok - qa memory stability contract\n'
