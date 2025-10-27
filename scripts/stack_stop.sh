#!/usr/bin/env bash
set -euo pipefail

# Stop or remove the stack
# Usage: stack_stop.sh [--down] [--prune]

DO_DOWN=0
DO_PRUNE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --down) DO_DOWN=1; shift;;
    --prune) DO_PRUNE=1; shift;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

if [ "$DO_DOWN" -eq 1 ]; then
  if [ "$DO_PRUNE" -eq 1 ]; then
    docker compose down -v
  else
    docker compose down
  fi
else
  docker compose stop
fi

echo "[stack_stop] done"

