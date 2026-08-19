#!/usr/bin/env bash
set -euo pipefail

# Exercises the normalized observation pipeline: ble-observe.py (batch and
# stream) and ble-live-alert.py. The contract under test is that the live path
# reaches the same verdict as the batch scanner, because both run the shared
# ble_signatures core.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FIXTURE="${ROOT_DIR}/tests/make-fixture.py"
OBSERVE="${ROOT_DIR}/scripts/ble-observe.py"
ALERT="${ROOT_DIR}/scripts/ble-live-alert.py"

python3 "${FIXTURE}" --mode spam    --duration 30 --output "${TMP_DIR}/spam.log"
python3 "${FIXTURE}" --mode ambient --duration 30 --output "${TMP_DIR}/ambient.log"

# --- Batch emit: every line must be a well-formed, stamped observation -------
python3 "${OBSERVE}" --input "${TMP_DIR}/spam.log" --sensor-id sensor-A \
  --sensor-lat 36.1 --sensor-lon -115.2 --out "${TMP_DIR}/spam.jsonl" 2>/dev/null

python3 - "${TMP_DIR}/spam.jsonl" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1]):
    e = json.loads(line)
    assert e["schema"] == "ble-obs/1", "wrong schema"
    assert e["sensor_id"] == "sensor-A", "sensor id not stamped"
    assert e["lat"] == 36.1 and e["lon"] == -115.2, "sensor position not stamped"
    assert e["modality"] == "ble"
    assert e["address"], "observation without address"
    assert e["identity_key"] and e["tier"] in ("strong", "session", "model", "ambiguous")
    n += 1
assert n > 0, "no observations emitted"
print("batch observe ok: %d stamped observations" % n)
PY

# Batch emit count must equal the parser's record count: the emitter must not
# invent or drop observations.
records=$(python3 - "${ROOT_DIR}" "${TMP_DIR}/spam.log" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import ble_parse
print(len(ble_parse.parse_records(sys.argv[2])))
PY
)
emitted=$(wc -l < "${TMP_DIR}/spam.jsonl" | tr -d ' ')
if [[ "${records}" != "${emitted}" ]]; then
  echo "FAIL: emitted ${emitted} observations but parser found ${records}" >&2
  exit 1
fi

# --- Stream -> live alert: spam must raise an alert --------------------------
python3 "${OBSERVE}" --stream --sensor-id sensor-A < "${TMP_DIR}/spam.log" \
  | python3 "${ALERT}" --profile balanced --config /dev/null > "${TMP_DIR}/spam-alert.txt" 2>/dev/null
if ! grep -q '  ALERT ' "${TMP_DIR}/spam-alert.txt"; then
  echo "FAIL: live alerter did not flag the spam stream" >&2
  cat "${TMP_DIR}/spam-alert.txt" >&2
  exit 1
fi

# --- Stream -> live alert: ambient must NOT raise an alert -------------------
python3 "${OBSERVE}" --stream --sensor-id sensor-A < "${TMP_DIR}/ambient.log" \
  | python3 "${ALERT}" --profile balanced --config /dev/null > "${TMP_DIR}/ambient-alert.txt" 2>/dev/null
if grep -q '  ALERT ' "${TMP_DIR}/ambient-alert.txt"; then
  echo "FAIL: live alerter flagged ordinary ambient traffic" >&2
  cat "${TMP_DIR}/ambient-alert.txt" >&2
  exit 1
fi

echo "BLE observe/live-alert test passed."
