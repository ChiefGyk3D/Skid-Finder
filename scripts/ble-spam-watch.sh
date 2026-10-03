#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_config
need_cmd btmon
need_cmd hciconfig
need_cmd timeout
need_cmd tee
need_capture_privileges

IFACE="${1:-}"
DURATION="${2:-${SCAN_SECONDS}}"
THRESHOLD="${3:-${ALERT_ADS_PER_ADDR}}"

if [[ -z "${IFACE}" ]]; then
  IFACE="$(default_capture_iface)"
else
  ensure_hci "${IFACE}"
fi

echo "Monitoring ${IFACE} for ${DURATION}s. Alert threshold=${THRESHOLD} ads/address"

tmpfile="$(mktemp)"
tmplog="$(mktemp)"
trap 'stop_capture_progress; stop_le_scan "${IFACE}"; rm -f "${tmpfile}" "${tmplog}"' EXIT

start_le_scan "${IFACE}"
start_capture_progress "${tmplog}" "${DURATION}" 10
run_btmon_capture "${IFACE}" "${DURATION}" "${tmplog}" quiet
stop_capture_progress
stop_le_scan "${IFACE}"

warn_if_capture_empty "${tmplog}"

echo
echo "Sweep finished. Analysing..."
echo

awk '
  /Address:/ {
    addr=$2
    gsub(",", "", addr)
    if (addr ~ /([0-9A-F]{2}:){5}[0-9A-F]{2}/) {
      counts[addr]++
    }
  }
  END {
    for (a in counts) {
      printf "%s %d\n", a, counts[a]
    }
  }
' "${tmplog}" | sort -k2,2nr > "${tmpfile}"

echo
echo "Top advertisers:"
head -n 20 "${tmpfile}" | awk '{printf "%-20s %s\n", $1, $2}'

echo
echo "Potential spam senders (>=${THRESHOLD}):"
awk -v t="${THRESHOLD}" '$2 >= t {printf "ALERT %-20s %s ads\n", $1, $2}' "${tmpfile}" || true

if command -v python3 >/dev/null 2>&1; then
  echo
  echo "Signature scan (defensive heuristics):"
  python3 "${SCRIPT_DIR}/ble-signature-scan.py" --input "${tmplog}" || true
else
  echo
  echo "Signature scan skipped: python3 not available."
fi
