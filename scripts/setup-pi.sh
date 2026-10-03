#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

# Packages the toolkit cannot run without.
#   bluez        btmon, bluetoothctl, btmgmt, hciconfig
#   python3      signature scanner, fingerprinting, capture parsing
#   rfkill       unblocking adapters before a capture
#   tmux         dual-pane capture + hunt session
REQUIRED=(bluez python3 rfkill tmux)

# Useful alongside the toolkit but not called by any script. These are
# installed one at a time and skipped if unavailable, because `apt install`
# fails as a batch: a single missing package aborts the run and installs
# nothing, which would otherwise leave the toolkit with no dependencies at all.
# iw and tshark are what the Wi-Fi capture needs; they stay optional so a
# BLE-only host installs without them, and the Wi-Fi scripts say what is
# missing when run.
OPTIONAL=(bluez-tools wireless-tools iw tshark whiptail)

apt update

echo "Installing required packages: ${REQUIRED[*]}"
apt install -y "${REQUIRED[@]}"

for pkg in "${OPTIONAL[@]}"; do
  if apt install -y "${pkg}"; then
    continue
  fi
  echo "WARNING: optional package '${pkg}' unavailable; continuing." >&2
done

# Confirm the binaries actually landed. Package names and binary names differ,
# and btmon in particular ships inside bluez rather than a package of its own.
missing=()
for bin in btmon bluetoothctl btmgmt hciconfig rfkill python3 tmux awk; do
  command -v "${bin}" >/dev/null 2>&1 || missing+=("${bin}")
done

if (( ${#missing[@]} > 0 )); then
  echo >&2
  echo "ERROR: required commands still missing: ${missing[*]}" >&2
  echo "Install them before running the toolkit." >&2
  exit 1
fi

# Warn, do not fail. The packages are installed correctly at this point, and an
# adapter can legitimately be absent right now: the AIO v2 support may not have
# been installed or rebooted into yet, or the external adapter may be unplugged.
# Detecting it here is what stops config/interfaces.conf being written for a
# single-adapter machine that is actually dual.
adapters="$(hciconfig 2>/dev/null | grep -cE '^hci[0-9]+:' || true)"
if [[ "${adapters}" -eq 0 ]]; then
  echo >&2
  echo "WARNING: no Bluetooth adapters are visible (hciconfig lists none)." >&2
  echo "On a uConsole this usually means the ClockworkPi AIO v2 support is not" >&2
  echo "installed yet, or the device has not been rebooted since installing it." >&2
  echo "That support is a prerequisite: it owns the boot configuration and" >&2
  echo "kernel modules that bring the radios up, which this toolkit does not." >&2
  echo "Install it, reboot, confirm 'hciconfig -a' lists hci0, then continue." >&2
else
  echo
  echo "Bluetooth adapters visible: ${adapters}"
fi

echo
echo "Dependencies installed and verified."
echo "Next:"
echo "1) cp config/interfaces.conf.example config/interfaces.conf"
echo "2) cp config/signatures.conf.example config/signatures.conf"
echo "3) Edit interface names and optional signature profile"
echo "4) Run scripts/detect-hci.sh"
echo "5) Run ./tests/test-toolkit.sh to confirm the install"
