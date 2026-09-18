#!/usr/bin/env bash
set -euo pipefail

# Regression test for the live alerting entry point.
#
# The documented live command used to be a raw 'sudo btmon | ble-observe |
# ble-live-alert' pipeline. That has two field failures: btmon records nothing
# unless something holds an LE scan open (the batch scripts do this; the
# one-liner did not), and btmon block-buffers stdout into a pipe, so in a
# quiet room an alert could sit in a buffer for minutes. Separately, the README
# said to set SENSOR_ID in config/interfaces.conf, but the observer only read
# the environment, so every observation was stamped "unknown".
#
# This test stubs btmon and the scan tools, runs the pipeline helper, and
# asserts: the scan is requested around it, btmon is line-buffered and given
# the trace path, observations land in the JSONL side file with absolute
# timestamps and the requested sensor id, the alerter fires on spam, and the
# observer honours the config file with the environment taking precedence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

workdir="$(mktemp -d)"
trap 'stop_le_scan; rm -rf "${workdir}"' EXIT

python3 "${ROOT_DIR}/tests/make-fixture.py" --mode spam --duration 30 \
  --output "${workdir}/spam.log"

mkdir -p "${workdir}/bin"

# btmon stand-in: records its arguments, touches the -w trace path, and streams
# the spam fixture forever so 'timeout' has to stop it, as with the real tool.
cat > "${workdir}/bin/btmon" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/btmon.args"
while (( \$# )); do
  if [[ "\$1" == "-w" ]]; then : > "\$2"; shift; fi
  shift
done
while :; do
  cat "${workdir}/spam.log"
  sleep 0.5
done
STUB
chmod +x "${workdir}/bin/btmon"

# stdbuf stand-in: real stdbuf is not available inside every CI sandbox and it
# is not what is under test; record that it was asked for line buffering.
cat > "${workdir}/bin/stdbuf" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/stdbuf.args"
[[ "\$1" == "-oL" ]] && shift
exec "\$@"
STUB
chmod +x "${workdir}/bin/stdbuf"

cat > "${workdir}/bin/bluetoothctl" <<STUB
#!/usr/bin/env bash
while IFS= read -r line; do
  printf '%s\n' "\${line}" >> "${workdir}/bluetoothctl.in"
  [[ "\${line}" == "quit" ]] && break
done
STUB
chmod +x "${workdir}/bin/bluetoothctl"

cat > "${workdir}/bin/btmgmt" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *info* ]]; then
  echo "        addr AA:BB:CC:00:11:22 version 11 manufacturer 2 class 0x000000"
fi
STUB
chmod +x "${workdir}/bin/btmgmt"

PATH="${workdir}/bin:${PATH}"
export PATH

# --- The pipeline helper --------------------------------------------------------
start_le_scan "hci0"
run_live_pipeline "hci0" 4 "${workdir}/trace.btsnoop" "${workdir}/obs.jsonl" \
  --sensor-id sensor-T --epoch-base now \
  -- --profile balanced --config /dev/null --window 30 --interval 1 \
  > "${workdir}/alerts.txt" 2> "${workdir}/alerts.err"
stop_le_scan "hci0"

if ! grep -qx 'scan on' "${workdir}/bluetoothctl.in"; then
  echo "FAIL: the live run never enabled an LE scan; btmon would record nothing." >&2
  exit 1
fi

if ! grep -q -- '-oL' "${workdir}/stdbuf.args" 2>/dev/null; then
  echo "FAIL: btmon was not line-buffered; alerts would lag behind a full pipe buffer." >&2
  exit 1
fi

if ! grep -q -- "-w ${workdir}/trace.btsnoop" "${workdir}/btmon.args"; then
  echo "FAIL: btmon was not asked to write the btsnoop trace." >&2
  cat "${workdir}/btmon.args" >&2
  exit 1
fi

if [[ ! -s "${workdir}/obs.jsonl" ]]; then
  echo "FAIL: no observations were written to the JSONL side file." >&2
  cat "${workdir}/alerts.err" >&2
  exit 1
fi

python3 - "${workdir}/obs.jsonl" <<'PY'
import json, sys, time
n = 0
now = time.time()
for line in open(sys.argv[1]):
    e = json.loads(line)
    assert e["schema"] == "ble-obs/1", "wrong schema"
    assert e["sensor_id"] == "sensor-T", "sensor id from the command line was not applied"
    assert e["ts_absolute"] is True, "live observations must carry absolute time"
    # Pinned to the first advert's arrival, so every stamp is within the last
    # minute rather than a 0..30 offset from nowhere.
    assert now - 120 < e["ts"] < now + 120, "timestamp is not wall-clock: %r" % e["ts"]
    n += 1
assert n > 0
print("live observations ok: %d records, absolute time, sensor stamped" % n)
PY

if ! grep -q '  ALERT ' "${workdir}/alerts.txt"; then
  echo "FAIL: the live alerter did not fire on a spam stream." >&2
  cat "${workdir}/alerts.txt" "${workdir}/alerts.err" >&2
  exit 1
fi

# --- Sensor identity from config/interfaces.conf ----------------------------------
# Copy the Python into a throwaway root so the test never reads or touches the
# operator's real config file.
mkdir -p "${workdir}/root/scripts" "${workdir}/root/config"
cp "${ROOT_DIR}"/scripts/*.py "${workdir}/root/scripts/"
cat > "${workdir}/root/config/interfaces.conf" <<'CONF'
# operator config
ADAPTER_MODE="dual"
SENSOR_ID="node-from-conf"   # trailing comment must not leak into the id
SENSOR_LAT=36.1
SENSOR_LON="-115.2"
CONF

env -u SENSOR_ID -u SENSOR_LAT -u SENSOR_LON \
  python3 "${workdir}/root/scripts/ble-observe.py" --input "${workdir}/spam.log" \
  | head -n 1 > "${workdir}/conf.json"
python3 - "${workdir}/conf.json" <<'PY'
import json, sys
e = json.loads(open(sys.argv[1]).read())
assert e["sensor_id"] == "node-from-conf", "SENSOR_ID in config/interfaces.conf was ignored: %r" % e["sensor_id"]
assert e["lat"] == 36.1 and e["lon"] == -115.2, "SENSOR_LAT/LON in config were ignored: %r %r" % (e["lat"], e["lon"])
print("config fallback ok")
PY

SENSOR_ID=env-wins python3 "${workdir}/root/scripts/ble-observe.py" \
  --input "${workdir}/spam.log" | head -n 1 > "${workdir}/env.json"
if ! grep -q '"sensor_id": "env-wins"' "${workdir}/env.json"; then
  echo "FAIL: the environment did not take precedence over the config file." >&2
  cat "${workdir}/env.json" >&2
  exit 1
fi

# --- The wrapper must use the helper, not a bare pipeline --------------------------
for needle in start_le_scan run_live_pipeline; do
  if ! grep -q "${needle}" "${ROOT_DIR}/scripts/ble-live-watch.sh"; then
    echo "FAIL: ble-live-watch.sh does not call ${needle}." >&2
    exit 1
  fi
done

echo "BLE live watch test passed."
