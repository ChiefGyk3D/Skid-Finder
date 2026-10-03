#!/usr/bin/env bash
set -euo pipefail

# Retention sweep: delete the files that hold other people's addresses once
# they are older than useful, keep the ones that do not.
#
# Deleted after KEEP_DAYS (default 3): observation files, btmon text logs
# and btsnoop traces, Wi-Fi pcapng and field extracts. Kept: alert,
# incident and fleet-state files (no addresses; the record that something
# happened), summaries, sightings and the watchlist (operator decisions).
# See docs/data-handling.md for why these numbers and not others.
#
# Usage: retention-sweep.sh [logs-dir] [keep-days]
#   SKID_FINDER_KEEP_DAYS in the environment also sets the days.
#   --dry-run prints what would go and deletes nothing.

DRY=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY=1
  shift
fi
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="${1:-${ROOT_DIR}/logs}"
KEEP="${2:-${SKID_FINDER_KEEP_DAYS:-3}}"

if [[ ! "${KEEP}" =~ ^[0-9]+$ ]]; then
  echo "keep-days must be a whole number, got '${KEEP}'" >&2
  exit 1
fi
if [[ ! -d "${LOGS}" ]]; then
  echo "no such logs directory: ${LOGS}" >&2
  exit 1
fi

action=(-print -delete)
if (( DRY )); then
  action=(-print)
fi

# -mtime +N means strictly more than N whole days old.
find "${LOGS}" -maxdepth 1 -type f \( \
    -name 'obs-*.jsonl' -o -name 'wifi-obs-*.jsonl' \
    -o -name 'btmon-*.log' -o -name 'btmon-*.btsnoop' -o -name 'btmon-*.pcapng' \
    -o -name 'wifi-*.pcapng' -o -name 'wifi-*.tsv' \
  \) -mtime +"${KEEP}" "${action[@]}"
