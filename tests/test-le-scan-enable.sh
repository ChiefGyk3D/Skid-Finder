#!/usr/bin/env bash
set -euo pipefail

# Regression test for LE scan enablement.
#
# The original scanner shelled out to a backgrounded 'btmgmt find'. btmgmt is a
# bt_shell program: detached from a controlling terminal it blocks in epoll and
# never issues Start Discovery, while still reporting success. Every capture
# therefore recorded nothing, and no test noticed because the capture tests stub
# btmon and never invoke the scanner at all.
#
# This test stubs bluetoothctl and btmgmt and asserts the scan control commands
# are actually delivered, and that teardown leaves nothing behind.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

mkdir -p "${workdir}/bin"

# Stand-in for bluetoothctl: records everything it is fed, and stays alive until
# it reads 'quit' or its input closes. This mirrors the real program closely
# enough to catch a caller that never sends anything.
cat > "${workdir}/bin/bluetoothctl" <<STUB
#!/usr/bin/env bash
while IFS= read -r line; do
  printf '%s\n' "\${line}" >> "${workdir}/bluetoothctl.in"
  [[ "\${line}" == "quit" ]] && break
done
printf 'exited\n' >> "${workdir}/bluetoothctl.state"
STUB
chmod +x "${workdir}/bin/bluetoothctl"

cat > "${workdir}/bin/btmgmt" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/btmgmt.args"
if [[ "\$*" == *info* ]]; then
  echo "hci0:  Primary controller"
  echo "        addr AA:BB:CC:00:11:22 version 11 manufacturer 2 class 0x000000"
fi
STUB
chmod +x "${workdir}/bin/btmgmt"

PATH="${workdir}/bin:${PATH}"
export PATH

: > "${workdir}/bluetoothctl.in"
: > "${workdir}/btmgmt.args"

start_le_scan "hci0"

# --- The scan must actually have been requested -------------------------------
if [[ ! -s "${workdir}/bluetoothctl.in" ]]; then
  echo "FAIL: no commands were delivered to bluetoothctl; scan never started." >&2
  exit 1
fi

if ! grep -qx 'scan on' "${workdir}/bluetoothctl.in"; then
  echo "FAIL: 'scan on' was never sent." >&2
  echo "--- bluetoothctl received ---" >&2
  cat "${workdir}/bluetoothctl.in" >&2
  exit 1
fi

# On dual-adapter rigs the scan must be pinned to the requested radio, or the
# hunt adapter ends up scanning while the capture adapter sits idle.
if ! grep -qx 'select AA:BB:CC:00:11:22' "${workdir}/bluetoothctl.in"; then
  echo "FAIL: controller was not selected by address." >&2
  cat "${workdir}/bluetoothctl.in" >&2
  exit 1
fi

# Powering the radio and enabling LE are privileged; as root they must be
# issued, and as an ordinary user they must not be attempted at all (btmgmt
# cannot do them and has been seen to block instead of failing).
if [[ "${EUID}" -eq 0 ]]; then
  if ! grep -q 'le on' "${workdir}/btmgmt.args"; then
    echo "FAIL: LE was never enabled on the controller." >&2
    cat "${workdir}/btmgmt.args" >&2
    exit 1
  fi
else
  if grep -qE 'power on|le on' "${workdir}/btmgmt.args"; then
    echo "FAIL: privileged btmgmt commands were attempted without root." >&2
    cat "${workdir}/btmgmt.args" >&2
    exit 1
  fi
fi

# --- The helper must remain running while the scan is up ----------------------
if [[ -z "${LE_SCAN_PID}" ]] || ! kill -0 "${LE_SCAN_PID}" 2>/dev/null; then
  echo "FAIL: scan helper is not running; it exited early." >&2
  exit 1
fi

if [[ ! -p "${LE_SCAN_FIFO}" ]]; then
  echo "FAIL: scan control FIFO was not created." >&2
  exit 1
fi

saved_pid="${LE_SCAN_PID}"
saved_fifo="${LE_SCAN_FIFO}"

# --- Teardown -----------------------------------------------------------------
stop_le_scan "hci0"

if ! grep -qx 'scan off' "${workdir}/bluetoothctl.in"; then
  echo "FAIL: 'scan off' was never sent; the radio would keep scanning." >&2
  exit 1
fi

if kill -0 "${saved_pid}" 2>/dev/null; then
  echo "FAIL: scan helper (pid ${saved_pid}) survived teardown." >&2
  exit 1
fi

if [[ -e "${saved_fifo}" ]]; then
  echo "FAIL: control FIFO was left behind at ${saved_fifo}." >&2
  exit 1
fi

if [[ "${EUID}" -eq 0 ]] && ! grep -q 'stop-find' "${workdir}/btmgmt.args"; then
  echo "FAIL: discovery was not stopped on the controller." >&2
  exit 1
fi

for var in LE_SCAN_PID LE_SCAN_FIFO LE_SCAN_FD; do
  if [[ -n "${!var}" ]]; then
    echo "FAIL: ${var} was not cleared after teardown (=${!var})." >&2
    exit 1
  fi
done

# --- Missing bluetoothctl must warn, not crash --------------------------------
# Deleting the stub is not enough; the real bluetoothctl is still on PATH. Build
# a minimal PATH that deliberately lacks it. start_le_scan returns at the
# 'command -v bluetoothctl' check, so only btmgmt and grep are needed here.
mkdir -p "${workdir}/nobt"
cp "${workdir}/bin/btmgmt" "${workdir}/nobt/btmgmt"
ln -sf "$(command -v grep)" "${workdir}/nobt/grep"

if ! PATH="${workdir}/nobt" start_le_scan "hci0" 2>&1 | grep -q 'warn:'; then
  echo "FAIL: missing bluetoothctl did not produce a warning." >&2
  exit 1
fi
stop_le_scan "hci0"

echo "LE scan enablement test passed."
