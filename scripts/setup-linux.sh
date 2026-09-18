#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# Keep this list in step with scripts/setup-pi.sh.
REQUIRED=(bluez python3 rfkill tmux)
# iw and tshark are what the Wi-Fi capture needs; they stay optional so a
# BLE-only host installs without them, and the Wi-Fi scripts say what is
# missing when run.
OPTIONAL=(bluez-tools wireless-tools iw tshark whiptail)

if ! command -v apt >/dev/null 2>&1; then
  echo "This installer currently supports apt-based Debian/Ubuntu systems." >&2
  echo "Install equivalents manually: ${REQUIRED[*]} ${OPTIONAL[*]}" >&2
  exit 1
fi

apt update

echo "Installing required packages: ${REQUIRED[*]}"
apt install -y "${REQUIRED[@]}"

# Installed individually: a single unavailable package makes `apt install` fail
# as a batch and install nothing at all.
for pkg in "${OPTIONAL[@]}"; do
  if apt install -y "${pkg}"; then
    continue
  fi
  echo "WARNING: optional package '${pkg}' unavailable; continuing." >&2
done

missing=()
for bin in btmon bluetoothctl btmgmt hciconfig rfkill python3 tmux awk; do
  command -v "${bin}" >/dev/null 2>&1 || missing+=("${bin}")
done

if (( ${#missing[@]} > 0 )); then
  echo >&2
  echo "ERROR: required commands still missing: ${missing[*]}" >&2
  exit 1
fi

echo
echo "Dependencies installed for secondary Linux/laptop use."
echo "Primary support target remains uConsole + AIO v2; non-uConsole usage is best-effort."
echo "Next:"
echo "1) cp config/interfaces.conf.example config/interfaces.conf"
echo "2) cp config/signatures.conf.example config/signatures.conf"
echo "3) Edit interface names and optional signature profile"
echo "4) Run scripts/detect-hci.sh"
echo "5) Run ./tests/test-toolkit.sh to confirm the install"
