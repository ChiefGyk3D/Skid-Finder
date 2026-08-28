#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_config
need_cmd date
need_cmd uname
need_cmd hciconfig
need_cmd bluetoothctl
need_cmd rfkill
need_cmd lsusb
need_cmd dmesg
need_cmd lsmod
need_cmd awk

mkdir -p "${ROOT_DIR}/logs"
REPORT="${ROOT_DIR}/logs/troubleshoot-$(now_stamp).txt"

{
  echo "# Skid Finder Toolkit Troubleshooting Report"
  echo "generated_at=$(date -Is)"
  echo "hostname=$(hostname)"
  echo "kernel=$(uname -a)"
  echo

  echo "## Config"
  echo "PRIMARY_HCI=${PRIMARY_HCI:-unset}"
  echo "SECONDARY_HCI=${SECONDARY_HCI:-unset}"
  echo "CAPTURE_HCI=${CAPTURE_HCI:-unset}"
  echo "HUNT_HCI=${HUNT_HCI:-unset}"
  echo

  echo "## bluetoothctl list"
  bluetoothctl list || true
  echo

  echo "## hciconfig -a"
  hciconfig -a || true
  echo

  echo "## rfkill list"
  rfkill list || true
  echo

  echo "## lsusb"
  lsusb || true
  echo

  echo "## lsmod (bluetooth related)"
  lsmod | awk 'NR==1 || /bluetooth|btusb|btintel|btmtk|btbcm/' || true
  echo

  echo "## dmesg (bluetooth related, last 200 matches)"
  dmesg | grep -Ei 'bluetooth|hci[0-9]|btusb|btmtk|btbcm|firmware|timeout' | tail -n 200 || true
  echo

  echo "## Interface sanity checks"
  for iface in "${PRIMARY_HCI:-}" "${SECONDARY_HCI:-}"; do
    if [[ -n "${iface}" ]]; then
      if hciconfig "${iface}" >/dev/null 2>&1; then
        echo "${iface}: present"
      else
        echo "${iface}: missing"
      fi
    fi
  done
  echo

  echo "## Quick recommendations"
  controller_count=$(bluetoothctl list 2>/dev/null | grep -c '^Controller ' || true)
  echo "controllers_detected=${controller_count}"

  if [[ "${controller_count}" -lt 2 ]]; then
    echo "- Only one controller detected. If your external adapter is AC1200 Wi-Fi-only, it will not create hci1."
    echo "- Use single-adapter mode by setting CAPTURE_HCI and HUNT_HCI to the same interface."
  fi

  if rfkill list 2>/dev/null | grep -qi 'Soft blocked: yes\|Hard blocked: yes'; then
    echo "- Bluetooth appears blocked; run: sudo rfkill unblock all"
  fi

  if dmesg 2>/dev/null | grep -Eqi 'btusb|btmtk|btbcm.*(fail|timeout|error|firmware)'; then
    echo "- Driver or firmware errors detected for a Bluetooth adapter; try replugging USB adapter and restarting bluetooth service."
  fi

  echo "- If hciconfig reports local-name read failures on hci1 but scanning works, adapter is partially functional for passive monitoring."
} > "${REPORT}"

echo "Wrote report: ${REPORT}"
echo "Share this report when debugging adapter issues."
