#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATE_SCRIPT="${ROOT_DIR}/scripts/validate-toolkit.sh"

if [[ ! -x "${VALIDATE_SCRIPT}" ]]; then
  echo "Missing validation entrypoint: ${VALIDATE_SCRIPT}" >&2
  exit 1
fi

"${VALIDATE_SCRIPT}"

REPORT=$(ls -1t "${ROOT_DIR}/logs"/toolkit-validation-*.txt 2>/dev/null | head -n 1)
if [[ -z "${REPORT}" || ! -f "${REPORT}" ]]; then
  echo "Validation report was not created." >&2
  exit 1
fi

grep -q "Validation complete" "${REPORT}"

"${ROOT_DIR}/tests/test-ble-gps-merge-optional.sh"
"${ROOT_DIR}/tests/test-ble-signatures.sh"
"${ROOT_DIR}/tests/test-ble-signature-tuning.sh"
python3 "${ROOT_DIR}/tests/test-detector-metrics.py"
python3 "${ROOT_DIR}/tests/test-detector-metrics.py" --modality wifi
"${ROOT_DIR}/tests/test-ble-fingerprint.sh"
"${ROOT_DIR}/tests/test-ble-observe.sh"
"${ROOT_DIR}/tests/test-ble-live-watch.sh"
"${ROOT_DIR}/tests/test-capture-resilience.sh"
"${ROOT_DIR}/tests/test-capture-progress.sh"
"${ROOT_DIR}/tests/test-le-scan-enable.sh"
"${ROOT_DIR}/tests/test-config-parsing.sh"
"${ROOT_DIR}/tests/test-field-menu.sh"
"${ROOT_DIR}/tests/test-versioning.sh"
"${ROOT_DIR}/tests/test-sensor-net.sh"
"${ROOT_DIR}/tests/test-wifi-signatures.sh"
"${ROOT_DIR}/tests/test-wifi-live-watch.sh"

echo "Toolkit validation smoke test passed."
