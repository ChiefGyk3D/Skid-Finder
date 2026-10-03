#!/usr/bin/env bash
set -euo pipefail

# Passive Wi-Fi capture: monitor mode, channel hopping, tshark to disk.
#
# Nothing here transmits. The interface is put into monitor mode (which only
# listens), hopped across the configured channels, and tshark records the
# management frames the detector needs. On exit the interface is returned to
# managed mode and, if NetworkManager was managing it, handed back.
#
# Usage:
#   sudo ./scripts/wifi-capture.sh [iface] [seconds]
#
# Writes:
#   logs/wifi-<iface>-<stamp>.pcapng   the raw capture
#   logs/wifi-<iface>-<stamp>.tsv      the field extract the detector reads
#
# Config (config/interfaces.conf): WIFI_IFACE, WIFI_CHANNELS, WIFI_DWELL_MS.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_config
need_cmd tshark
need_cmd iw
need_cmd ip
need_cmd timeout
need_root

IFACE="${1:-${WIFI_IFACE:-}}"
DURATION="${2:-${SCAN_SECONDS}}"

if [[ -z "${IFACE}" ]]; then
  echo "No Wi-Fi interface given. Set WIFI_IFACE in config/interfaces.conf or pass one." >&2
  echo "Interfaces: $(iw dev 2>/dev/null | awk '/Interface/{print $2}' | tr '\n' ' ')" >&2
  exit 1
fi

mkdir -p "${ROOT_DIR}/logs"
STAMP="$(now_stamp)"
PCAP="${ROOT_DIR}/logs/wifi-${IFACE}-${STAMP}.pcapng"
TSV="${ROOT_DIR}/logs/wifi-${IFACE}-${STAMP}.tsv"

echo "Passive Wi-Fi capture on ${IFACE} for ${DURATION}s"
echo "Capture: ${PCAP}"
echo "Fields:  ${TSV}"

trap 'stop_channel_hop; wifi_monitor_off "${IFACE}"' EXIT

wifi_monitor_on "${IFACE}"
start_channel_hop "${IFACE}" "${WIFI_CHANNELS:-1 6 11}" "${WIFI_DWELL_MS:-250}"

rc=0
timeout "${DURATION}" tshark -i "${IFACE}" -q -w "${PCAP}" 2>/dev/null || rc=$?
case "${rc}" in
  0|124|130|143) ;;
  *) echo "warn: tshark exited with status ${rc}; the capture may be incomplete." >&2 ;;
esac

stop_channel_hop
wifi_monitor_off "${IFACE}"

if [[ -s "${PCAP}" ]]; then
  wifi_fields_from_pcap "${PCAP}" > "${TSV}"
  frames="$(wc -l < "${TSV}" | tr -d ' ')"
  echo "Capture complete: ${frames} management frames in ${TSV}"
  if (( frames == 0 )); then
    echo "warn: no frames captured. Is the adapter capable of monitor mode? See TROUBLESHOOTING.md." >&2
  fi
else
  echo "warn: capture file is empty. See TROUBLESHOOTING.md (Wi-Fi monitor mode)." >&2
fi
