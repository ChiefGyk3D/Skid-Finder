#!/usr/bin/env bash
set -euo pipefail

# Live Wi-Fi attack alerting from a monitor-mode interface.
#
# The Wi-Fi counterpart of ble-live-watch.sh: monitor mode on, channels
# hopped, tshark streamed line by line through the normalized observer into
# the windowed alerter, everything kept:
#
#   logs/wifi-obs-<iface>-<stamp>.jsonl      one wifi-obs/1 record per frame
#   logs/wifi-alerts-<iface>-<stamp>.jsonl   one wifi-alert/1 record per evaluation
#
# Records are stamped with SENSOR_ID / SENSOR_LAT / SENSOR_LON and, when
# MQTT_HOST is configured, shipped to the broker as they are written.
#
# Usage:
#   sudo ./scripts/wifi-live-watch.sh [iface] [duration] [profile]
#
#   duration  seconds; 0 runs until Ctrl+C (default: 0)
#   profile   conservative | balanced | aggressive (default: balanced)
#
# Environment overrides: WINDOW (seconds, default 30), INTERVAL (default 5).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_config
need_cmd tshark
need_cmd iw
need_cmd ip
need_cmd python3
need_cmd tee
need_root

IFACE="${1:-${WIFI_IFACE:-}}"
DURATION="${2:-0}"
PROFILE="${3:-balanced}"
WINDOW="${WINDOW:-30}"
INTERVAL="${INTERVAL:-5}"

if [[ -z "${IFACE}" ]]; then
  echo "No Wi-Fi interface given. Set WIFI_IFACE in config/interfaces.conf or pass one." >&2
  exit 1
fi
case "${PROFILE}" in
  conservative|balanced|aggressive) ;;
  *) echo "Unknown profile '${PROFILE}'." >&2; exit 1 ;;
esac
if [[ ! "${DURATION}" =~ ^[0-9]+$ ]]; then
  echo "Duration must be a whole number of seconds (0 = until Ctrl+C)." >&2
  exit 1
fi

mkdir -p "${ROOT_DIR}/logs"
STAMP="$(now_stamp)"
OBS="${ROOT_DIR}/logs/wifi-obs-${IFACE}-${STAMP}.jsonl"
ALERTS="${ROOT_DIR}/logs/wifi-alerts-${IFACE}-${STAMP}.jsonl"

if (( DURATION > 0 )); then
  echo "Wi-Fi live watch on ${IFACE} for ${DURATION}s (profile=${PROFILE}, window=${WINDOW}s)"
else
  echo "Wi-Fi live watch on ${IFACE} until Ctrl+C (profile=${PROFILE}, window=${WINDOW}s)"
fi
echo "Observations: ${OBS}"
echo "Alerts: ${ALERTS}"
echo

PUBLISH_PID=""
stop_publisher() {
  [[ -n "${PUBLISH_PID}" ]] || return 0
  kill "${PUBLISH_PID}" 2>/dev/null || true
  wait "${PUBLISH_PID}" 2>/dev/null || true
  PUBLISH_PID=""
}
trap 'stop_publisher; stop_channel_hop; wifi_monitor_off "${IFACE}"' EXIT

if [[ -n "${MQTT_HOST:-}" ]]; then
  : > "${OBS}"
  : > "${ALERTS}"
  python3 "${SCRIPT_DIR}/ble-publish.py" --follow "${OBS}" "${ALERTS}" --heartbeat 30 &
  PUBLISH_PID=$!
  echo "Publishing to ${MQTT_HOST}:${MQTT_PORT:-1883} as ${SENSOR_ID:-unknown}"
fi

wifi_monitor_on "${IFACE}"
start_channel_hop "${IFACE}" "${WIFI_CHANNELS:-1 6 11}" "${WIFI_DWELL_MS:-250}"

run_wifi_live_pipeline "${IFACE}" "${DURATION}" "${OBS}" \
  --sensor-id "${SENSOR_ID:-unknown}" \
  --sensor-lat "${SENSOR_LAT:-}" \
  --sensor-lon "${SENSOR_LON:-}" \
  -- \
  --profile "${PROFILE}" --window "${WINDOW}" --interval "${INTERVAL}" \
  --jsonl-out "${ALERTS}"

stop_channel_hop
wifi_monitor_off "${IFACE}"
if [[ -n "${PUBLISH_PID}" ]]; then
  sleep 1
  stop_publisher
fi

echo
if [[ ! -s "${OBS}" ]]; then
  echo "warn: no frames were observed. Is the adapter in monitor mode? See TROUBLESHOOTING.md." >&2
else
  echo "Wi-Fi live watch finished. $(wc -l < "${OBS}" | tr -d ' ') observations in ${OBS}"
fi
