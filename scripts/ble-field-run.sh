#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_config
need_cmd btmon
need_cmd timeout
need_cmd awk
need_cmd sort
need_cmd head
need_cmd tee
need_cmd wc
need_root

IFACE="${1:-}"
DURATION="${2:-300}"
ALERT_THRESHOLD="${3:-${ALERT_ADS_PER_ADDR}}"

if [[ -z "${IFACE}" ]]; then
  IFACE="$(default_capture_iface)"
else
  ensure_hci "${IFACE}"
fi
mkdir -p "${ROOT_DIR}/logs"

STAMP="$(now_stamp)"
CAPTURE_LOG="${ROOT_DIR}/logs/btmon-${IFACE}-${STAMP}.log"
CAPTURE_TRACE="${ROOT_DIR}/logs/btmon-${IFACE}-${STAMP}.btsnoop"
OBS_FILE="${ROOT_DIR}/logs/obs-${IFACE}-${STAMP}.jsonl"
SUMMARY_FILE="${ROOT_DIR}/logs/summary-${IFACE}-${STAMP}.txt"

echo "Starting BLE field run on ${IFACE} for ${DURATION}s"
echo "Capture log: ${CAPTURE_LOG}"
echo "Capture trace: ${CAPTURE_TRACE}"
echo "Observations: ${OBS_FILE}"
echo "Summary file: ${SUMMARY_FILE}"

trap 'stop_capture_progress; stop_le_scan "${IFACE}"' EXIT

start_le_scan "${IFACE}"
# btmon's timestamps are offsets from its first packet, so wall-clock time
# taken here is the base that turns them into absolute time, give or take the
# moment the first advert lands.
CAPTURE_EPOCH="$(date +%s)"
start_capture_progress "${CAPTURE_LOG}" "${DURATION}" 10
run_btmon_capture "${IFACE}" "${DURATION}" "${CAPTURE_LOG}" quiet "${CAPTURE_TRACE}"
stop_capture_progress
stop_le_scan "${IFACE}"

warn_if_capture_empty "${CAPTURE_LOG}"

echo
echo "Capture finished. Analysing..."
echo

# Normalized observations: one ble-obs/1 record per advert, stamped with this
# sensor's identity from config/interfaces.conf. This is the artifact a
# collector or SIEM ingests; the text log and summary are for people.
if ! python3 "${SCRIPT_DIR}/ble-observe.py" --input "${CAPTURE_LOG}"      --out "${OBS_FILE}" --epoch-base "${CAPTURE_EPOCH}"; then
  echo "warn: could not write normalized observations to ${OBS_FILE}." >&2
fi

{
  echo "# BLE Field Summary"
  echo "generated_at=$(date -Is)"
  echo "interface=${IFACE}"
  echo "duration_seconds=${DURATION}"
  echo "alert_threshold=${ALERT_THRESHOLD}"
  echo "capture_log=${CAPTURE_LOG}"
  echo "capture_trace=${CAPTURE_TRACE}"
  echo "observations=${OBS_FILE}"
  echo

  total_lines=$(wc -l < "${CAPTURE_LOG}" | tr -d ' ')
  echo "capture_lines=${total_lines}"
  echo

  echo "## Top advertisers by count"
  awk '
    /Address:/ {
      addr=$2
      gsub(",", "", addr)
      if (addr ~ /([0-9A-F]{2}:){5}[0-9A-F]{2}/) {
        count[addr]++
      }
    }
    END {
      for (a in count) {
        printf "%s %d\n", a, count[a]
      }
    }
  ' "${CAPTURE_LOG}" | sort -k2,2nr | head -n 25

  echo
  echo "## Potential spam senders"
  awk -v t="${ALERT_THRESHOLD}" '
    /Address:/ {
      addr=$2
      gsub(",", "", addr)
      if (addr ~ /([0-9A-F]{2}:){5}[0-9A-F]{2}/) {
        count[addr]++
      }
    }
    END {
      for (a in count) {
        if (count[a] >= t) {
          printf "ALERT %s %d\n", a, count[a]
        }
      }
    }
  ' "${CAPTURE_LOG}" | sort -k3,3nr

  echo
  echo "## Top average RSSI by sender (min 5 RSSI samples)"
  awk '
    /Address:/ {
      addr=$2
      gsub(",", "", addr)
      valid=(addr ~ /([0-9A-F]{2}:){5}[0-9A-F]{2}/)
    }
    /RSSI:/ {
      if (valid) {
        rssi=$2
        gsub("dBm", "", rssi)
        if (rssi ~ /^-?[0-9]+$/) {
          sum[addr]+=rssi
          n[addr]++
        }
      }
    }
    END {
      for (a in n) {
        if (n[a] >= 5) {
          avg=sum[a]/n[a]
          printf "%s %.2f %d\n", a, avg, n[a]
        }
      }
    }
  ' "${CAPTURE_LOG}" | sort -k2,2nr | head -n 20

  echo
  echo "## Signature scan (defensive heuristics)"
  if command -v python3 >/dev/null 2>&1; then
    python3 "${SCRIPT_DIR}/ble-signature-scan.py" --input "${CAPTURE_LOG}" || true
  else
    echo "python3 not available; signature scan skipped"
  fi
# Shown as well as saved. Writing the whole summary to a file left the operator
# with a blank screen and a path to go and read, which is the wrong result for
# something used while standing up at a conference.
} | tee "${SUMMARY_FILE}"

echo
echo "Field run complete."
echo "Open summary: ${SUMMARY_FILE}"
