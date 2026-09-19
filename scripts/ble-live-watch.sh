#!/usr/bin/env bash
set -euo pipefail

# Live spam alerting from a running adapter.
#
# This is the supported way to run the live detector. It enables an LE scan
# on the chosen radio (btmon alone records nothing on an idle adapter), holds
# it open for the run, and feeds btmon line-by-line through the normalized
# observer into the windowed alerter, which runs the same detector as the
# batch scanner. Everything the run sees is also kept:
#
#   logs/btmon-<iface>-<stamp>.btsnoop   replayable binary trace
#   logs/obs-<iface>-<stamp>.jsonl       one ble-obs/1 record per advert
#   logs/alerts-<iface>-<stamp>.jsonl    one ble-alert/1 record per evaluation
#
# Observations are stamped with SENSOR_ID / SENSOR_LAT / SENSOR_LON from
# config/interfaces.conf and carry absolute timestamps, so the same file can be
# handed to a collector or a SIEM as-is.
#
# Usage:
#   sudo ./scripts/ble-live-watch.sh [iface] [duration] [profile]
#
#   iface     adapter to listen on (default: capture interface from config)
#   duration  seconds to run; 0 runs until Ctrl+C (default: 0)
#   profile   conservative | balanced | aggressive (default: balanced)
#
# Environment overrides: WINDOW (seconds, default 30), INTERVAL (default 5).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_config
need_cmd btmon
need_cmd python3
need_cmd stdbuf
need_cmd tee
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo). Live alerting streams btmon as it happens, which the" >&2
  echo "unprivileged pcapng path cannot do; capture-btmon.sh and ble-field-run.sh" >&2
  echo "work without root on a laptop in the wireshark group." >&2
  exit 1
fi

IFACE="${1:-}"
DURATION="${2:-0}"
PROFILE="${3:-balanced}"
WINDOW="${WINDOW:-30}"
INTERVAL="${INTERVAL:-5}"

case "${PROFILE}" in
  conservative|balanced|aggressive) ;;
  *)
    echo "Unknown profile '${PROFILE}'. Use conservative, balanced or aggressive." >&2
    exit 1
    ;;
esac

if [[ ! "${DURATION}" =~ ^[0-9]+$ ]]; then
  echo "Duration must be a whole number of seconds (0 = until Ctrl+C)." >&2
  exit 1
fi

if [[ -z "${IFACE}" ]]; then
  IFACE="$(default_capture_iface)"
else
  ensure_hci "${IFACE}"
fi
mkdir -p "${ROOT_DIR}/logs"

STAMP="$(now_stamp)"
TRACE="${ROOT_DIR}/logs/btmon-${IFACE}-${STAMP}.btsnoop"
OBS="${ROOT_DIR}/logs/obs-${IFACE}-${STAMP}.jsonl"
ALERTS="${ROOT_DIR}/logs/alerts-${IFACE}-${STAMP}.jsonl"

if (( DURATION > 0 )); then
  echo "Live watch on ${IFACE} for ${DURATION}s (profile=${PROFILE}, window=${WINDOW}s)"
else
  echo "Live watch on ${IFACE} until Ctrl+C (profile=${PROFILE}, window=${WINDOW}s)"
fi
echo "Trace: ${TRACE}"
echo "Observations: ${OBS}"
echo "Alerts: ${ALERTS}"
if [[ "${PROFILE}" == "conservative" && "${WINDOW}" -lt 60 ]]; then
  echo "note: the conservative profile needs a long window to reach a verdict;" >&2
  echo "note: with WINDOW=${WINDOW} it may never fire. Consider WINDOW=60 or more." >&2
fi
echo

PUBLISH_PID=""
stop_publisher() {
  [[ -n "${PUBLISH_PID}" ]] || return 0
  kill "${PUBLISH_PID}" 2>/dev/null || true
  wait "${PUBLISH_PID}" 2>/dev/null || true
  PUBLISH_PID=""
}
trap 'stop_publisher; stop_le_scan "${IFACE}"' EXIT

# Sensor-net transport: when a broker is configured, ship the records as
# they are written. The publisher tails the files, so a broker outage never
# touches the capture; the files remain the record and can be shipped later.
if [[ -n "${MQTT_HOST:-}" ]]; then
  : > "${OBS}"
  : > "${ALERTS}"
  python3 "${SCRIPT_DIR}/ble-publish.py" --follow "${OBS}" "${ALERTS}" --heartbeat 30 &
  PUBLISH_PID=$!
  echo "Publishing to ${MQTT_HOST}:${MQTT_PORT:-1883} as ${SENSOR_ID:-unknown}"
fi

start_le_scan "${IFACE}"

run_live_pipeline "${IFACE}" "${DURATION}" "${TRACE}" "${OBS}" \
  --sensor-id "${SENSOR_ID:-unknown}" \
  --sensor-lat "${SENSOR_LAT:-}" \
  --sensor-lon "${SENSOR_LON:-}" \
  --epoch-base now \
  -- \
  --profile "${PROFILE}" --window "${WINDOW}" --interval "${INTERVAL}" \
  --jsonl-out "${ALERTS}"

stop_le_scan "${IFACE}"
# Give the publisher one more pass over the files before it goes.
if [[ -n "${PUBLISH_PID}" ]]; then
  sleep 1
  stop_publisher
fi

echo
if [[ ! -s "${OBS}" ]]; then
  echo "warn: no observations were recorded. The adapter may not have been scanning." >&2
  echo "warn: see TROUBLESHOOTING.md." >&2
else
  echo "Live watch finished. $(wc -l < "${OBS}" | tr -d ' ') observations in ${OBS}"
fi
