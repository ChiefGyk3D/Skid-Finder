#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_config
need_cmd rfkill
need_cmd hciconfig
need_cmd bluetoothctl
need_cmd dmesg
need_cmd awk
need_cmd sed
need_cmd grep

IFACE="${1:-}"

if [[ -z "${IFACE}" ]]; then
  IFACE="$(pick_runtime_iface "${SECONDARY_HCI:-hci1}" "${CAPTURE_HCI:-${PRIMARY_HCI:-hci0}}" "recover")"
fi

if [[ ! -x "${SCRIPT_DIR}/troubleshoot-bluetooth.sh" ]]; then
  echo "Missing executable script: scripts/troubleshoot-bluetooth.sh" >&2
  echo "Run: chmod +x scripts/troubleshoot-bluetooth.sh" >&2
  exit 1
fi

need_root
mkdir -p "${ROOT_DIR}/logs"
SUMMARY="${ROOT_DIR}/logs/recover-${IFACE}-$(now_stamp).txt"

run_diag() {
  local stage="$1"
  local out

  out="$(${SCRIPT_DIR}/troubleshoot-bluetooth.sh 2>&1 || true)"
  printf "%s\n" "${out}" >&2

  local report_path
  report_path="$(printf "%s\n" "${out}" | sed -n 's/^Wrote report: //p' | tail -n 1)"
  if [[ -z "${report_path}" ]]; then
    echo ""
    return
  fi

  echo "${stage}|${report_path}"
}

run_btmgmt_cmd() {
  local iface="$1"
  local mode="$2"
  local value="$3"
  local output

  output="$(btmgmt -i "${iface}" "${mode}" "${value}" 2>&1)" || {
    # status 0x0b on BR/EDR is commonly returned by LE-only or restricted adapters.
    if printf "%s\n" "${output}" | grep -qi 'status 0x0b'; then
      echo "btmgmt -i ${iface} ${mode} ${value}: rejected (0x0b); continuing (usually safe on LE-only adapters)"
      return 0
    fi

    echo "btmgmt -i ${iface} ${mode} ${value}: failed"
    printf "%s\n" "${output}"
    return 1
  }

  echo "${output}"
}

echo "Running pre-recovery diagnostics..."
pre_info="$(run_diag "before")"

echo "Applying safe recovery sequence for ${IFACE}..."
{
  echo "== commands =="
  echo "rfkill unblock all"
  rfkill unblock all || true

  echo "hciconfig ${IFACE} down"
  hciconfig "${IFACE}" down || true

  echo "hciconfig ${IFACE} reset"
  hciconfig "${IFACE}" reset || true

  echo "hciconfig ${IFACE} up"
  hciconfig "${IFACE}" up || true

  if command -v btmgmt >/dev/null 2>&1; then
    echo "btmgmt -i ${IFACE} power off"
    run_btmgmt_cmd "${IFACE}" power off || true

    echo "btmgmt -i ${IFACE} power on"
    run_btmgmt_cmd "${IFACE}" power on || true

    echo "btmgmt -i ${IFACE} le on"
    run_btmgmt_cmd "${IFACE}" le on || true

    echo "btmgmt -i ${IFACE} bredr off"
    run_btmgmt_cmd "${IFACE}" bredr off || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    echo "systemctl restart bluetooth"
    systemctl restart bluetooth || true
  fi
}

echo "Running post-recovery diagnostics..."
post_info="$(run_diag "after")"

{
  echo "# Skid Finder BLE Recovery Summary"
  echo "generated_at=$(date -Is)"
  echo "interface=${IFACE}"
  echo

  if [[ -n "${pre_info}" ]]; then
    pre_report="${pre_info#*|}"
    echo "before_report=${pre_report}"
  else
    pre_report=""
    echo "before_report=unavailable"
  fi

  if [[ -n "${post_info}" ]]; then
    post_report="${post_info#*|}"
    echo "after_report=${post_report}"
  else
    post_report=""
    echo "after_report=unavailable"
  fi

  echo
  echo "## Quick status checks"
  echo "bluetoothctl_controllers=$(bluetoothctl list 2>/dev/null | grep -c '^Controller ' || true)"
  echo
  echo "hciconfig_${IFACE}:"
  hciconfig "${IFACE}" || true
  echo

  if [[ -n "${post_report}" && -f "${post_report}" ]]; then
    echo "## Post-recovery recommendations"
    awk '/^## Quick recommendations/{flag=1; next} /^$/{if (flag) print; next} {if (flag) print}' "${post_report}" | sed -n '1,20p'
  fi

  echo
  echo "## Last bluetooth kernel messages"
  dmesg | grep -Ei 'bluetooth|hci[0-9]|btusb|btmtk|btbcm|firmware|timeout' | tail -n 40 || true
} > "${SUMMARY}"

echo "Recovery summary: ${SUMMARY}"
echo "If ${IFACE} still fails, switch toolkit to single-adapter mode and use a known-good BLE USB dongle for hci1."