#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
script="${ROOT_DIR}/scripts/qa_resilience.sh"

pre_reboot_block="$(
  awk '
    /^case "\$\{QA_PHASE\}" in/ { case_count += 1 }
    case_count >= 2 && /^[[:space:]]*pre-reboot\)/ { in_block=1 }
    in_block { print }
    in_block && /;;/ { exit }
  ' "${script}"
)"

printf '%s\n' "${pre_reboot_block}" | grep -q 'ensure_hybrid_ready' \
  || { echo "pre-reboot must start a ready hybrid stack before reboot" >&2; exit 1; }

ensure_line="$(printf '%s\n' "${pre_reboot_block}" | awk '/ensure_hybrid_ready/ { print NR; exit }')"
snapshot_line="$(printf '%s\n' "${pre_reboot_block}" | awk '/snapshot_runtime "resilience-pre-reboot"/ { print NR; exit }')"

if [ -z "${ensure_line}" ] || [ -z "${snapshot_line}" ] || [ "${ensure_line}" -ge "${snapshot_line}" ]; then
  echo "pre-reboot must snapshot only after hybrid readiness" >&2
  exit 1
fi

echo "ok - qa pre-reboot prepares a restartable stack"
