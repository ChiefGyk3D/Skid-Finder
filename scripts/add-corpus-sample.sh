#!/usr/bin/env bash
set -euo pipefail

# Record a real capture into the detector corpus.
#
# This is the supported way to add either a quiet-ambient baseline or a
# confirmed-spam sample to tests/corpus/real/ and register it in the manifest,
# so tests/test-detector-metrics.py measures the detector against real traffic.
# It needs no root: capture with sudo first, then run this as yourself.
#
# The capture must be the btmon TEXT log (the .log file), not the .btsnoop
# binary trace, because the detector parses text.
#
# Usage:
#   scripts/add-corpus-sample.sh --label ambient --capture logs/btmon-hci0-*.log
#   scripts/add-corpus-sample.sh --label spam --capture logs/flipper.log \
#       --families flipper,fastpair,name_rotation \
#       --note "Flipper Zero BLE Spam app, Apple+Fast Pair, contained room" --run

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REAL_DIR="${ROOT_DIR}/tests/corpus/real"
MANIFEST="${ROOT_DIR}/tests/corpus/manifest.jsonl"

usage() {
  sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

LABEL=""
CAPTURE=""
FAMILIES=""
NOTE=""
NAME=""
RUN=0

while (( $# )); do
  case "$1" in
    --label)    LABEL="${2:-}"; shift 2 ;;
    --capture)  CAPTURE="${2:-}"; shift 2 ;;
    --families) FAMILIES="${2:-}"; shift 2 ;;
    --note)     NOTE="${2:-}"; shift 2 ;;
    --name)     NAME="${2:-}"; shift 2 ;;
    --run)      RUN=1; shift ;;
    -h|--help)  usage ;;
    *)          echo "unknown argument: $1" >&2; usage ;;
  esac
done

[[ "${LABEL}" == "ambient" || "${LABEL}" == "spam" ]] \
  || { echo "--label must be 'ambient' or 'spam'" >&2; usage; }
[[ -n "${CAPTURE}" ]] || { echo "--capture is required" >&2; usage; }
[[ -r "${CAPTURE}" ]] || { echo "cannot read capture: ${CAPTURE}" >&2; exit 1; }

# A .btsnoop is binary and will not parse as text; catch the easy mistake.
if [[ "${CAPTURE}" == *.btsnoop ]] || ! grep -qI . "${CAPTURE}"; then
  echo "error: ${CAPTURE} looks binary. Use the btmon TEXT .log, not .btsnoop." >&2
  exit 1
fi

if ! grep -q "Address:" "${CAPTURE}" 2>/dev/null; then
  echo "warn: ${CAPTURE} contains no advertising reports." >&2
  echo "warn: for a spam sample this means recall cannot be measured from it." >&2
fi

# Default the corpus name from the capture's basename; sanitise to a safe set.
if [[ -z "${NAME}" ]]; then
  NAME="$(basename "${CAPTURE}")"
  NAME="${NAME%.log}"
fi
NAME="$(printf '%s' "${NAME}" | tr -c 'A-Za-z0-9._-' '-')"
DEST="${REAL_DIR}/${NAME}.log"

mkdir -p "${REAL_DIR}"
cp "${CAPTURE}" "${DEST}"
echo "copied capture -> ${DEST#"${ROOT_DIR}/"}"

# Build the manifest line with python so notes and family lists are always
# valid JSON, whatever characters they contain.
python3 - "${MANIFEST}" "${LABEL}" "${NAME}.log" "${FAMILIES}" "${NOTE}" <<'PY'
import json, sys
manifest, label, path, families, note = sys.argv[1:6]
entry = {"kind": "real", "label": label, "path": "real/" + path}
fams = [f.strip() for f in families.split(",") if f.strip()]
if label == "spam" and fams:
    entry["families"] = fams
if note:
    entry["note"] = note
with open(manifest, "a", encoding="utf-8") as handle:
    handle.write(json.dumps(entry, sort_keys=True) + "\n")
print("appended manifest entry:", json.dumps(entry, sort_keys=True))
PY

echo
echo "Recorded. The capture file is git-ignored; the manifest line is tracked."
if (( RUN )); then
  echo "Running detector metrics..."
  python3 "${ROOT_DIR}/tests/test-detector-metrics.py"
else
  echo "Next: python3 tests/test-detector-metrics.py"
fi
