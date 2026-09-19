#!/usr/bin/env bash
set -euo pipefail

# The evidence bundle must contain the incident's window and nothing else:
# records inside the window (with the margin) kept, records outside dropped,
# traces whose run overlapped the window copied whole, a summary, and a
# manifest that sha256sum can verify after extraction.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

logs="${TMP}/logs"; mkdir -p "${logs}"

# A real incident from the fleet fixture through the collector.
python3 "${ROOT_DIR}/tests/make-fleet-fixture.py" --outdir "${TMP}/fx" > /dev/null
python3 "${ROOT_DIR}/scripts/ble-collector.py" --input "${TMP}"/fx/obs-*.jsonl \
  --window 30 --interval 5 --config /dev/null --incident-quiet 10 --quiet \
  --alerts-out "${logs}/fleet-alerts.jsonl" --incidents-out "${logs}/fleet-incidents.jsonl" 2>/dev/null
cp "${TMP}/fx/obs-A.jsonl" "${logs}/obs-hci0-20250918-120000.jsonl"
cp "${TMP}/fx/alerts-A.jsonl" "${logs}/alerts-hci0-20250918-120000.jsonl"

BASE=1758200000
inc_from="$(python3 -c "import json; r=[json.loads(l) for l in open('${logs}/fleet-incidents.jsonl') if l.strip()][-1]; print(int(r['first_seen']))")"
inc_to="$(python3 -c "import json; r=[json.loads(l) for l in open('${logs}/fleet-incidents.jsonl') if l.strip()][-1]; print(int(r['last_seen']))")"
(( inc_from > BASE && inc_to > inc_from )) || fail "fixture incident has no usable window"

# Traces: one whose run overlaps the window, one from a different day.
in_trace="${logs}/btmon-hci0-$(date -d "@${inc_from}" +%Y%m%d-%H%M%S).btsnoop"
echo "in-window-trace" > "${in_trace}"; touch -d "@$(( inc_to + 5 ))" "${in_trace}"
out_trace="${logs}/btmon-hci0-20240101-000000.btsnoop"
echo "old-trace" > "${out_trace}"; touch -d "2024-01-01 00:05" "${out_trace}"

"${ROOT_DIR}/scripts/evidence-bundle.sh" --logs "${logs}" --incident "${logs}/fleet-incidents.jsonl" \
  --margin 5 --out "${TMP}/bundle.tar.gz" > "${TMP}/bundle.out"
[[ -s "${TMP}/bundle.tar.gz" ]] || fail "no bundle written"

mkdir -p "${TMP}/x" && tar -C "${TMP}/x" -xzf "${TMP}/bundle.tar.gz"
b="$(find "${TMP}/x" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -f "${b}/SUMMARY.txt" && -f "${b}/MANIFEST.sha256" ]] || fail "summary or manifest missing"
( cd "${b}" && sha256sum -c --quiet MANIFEST.sha256 ) || fail "manifest does not verify after extraction"
grep -q "incident=inc-" "${b}/SUMMARY.txt" || fail "summary does not name the incident"

# Records: only lines inside the window (plus margin) survive.
python3 - "${b}/records" "${inc_from}" "${inc_to}" <<'PY'
import glob, json, os, sys
d, lo, hi = sys.argv[1], float(sys.argv[2]) - 5, float(sys.argv[3]) + 5
files = glob.glob(os.path.join(d, "*.jsonl"))
assert files, "no record files in the bundle"
obs = [f for f in files if os.path.basename(f).startswith("obs-")]
assert obs, "observation file missing from the bundle"
n = 0
for f in files:
    for line in open(f):
        r = json.loads(line)
        if str(r.get("schema", "")).startswith("fleet-incident/"):
            continue
        assert lo <= r["ts"] <= hi, f"{os.path.basename(f)} carries a record outside the window: {r['ts']}"
        n += 1
assert n > 0
inc = [f for f in files if "incident" in os.path.basename(f)]
assert inc, "incident record missing from the bundle"
print("records scoped ok: %d lines" % n)
PY
# The source file had records before the window; the bundle must have fewer.
src_lines="$(wc -l < "${logs}/obs-hci0-20250918-120000.jsonl")"
bundle_lines="$(wc -l < "${b}/records/obs-hci0-20250918-120000.jsonl")"
(( bundle_lines < src_lines )) || fail "observation file was copied whole (${bundle_lines} of ${src_lines})"

# Traces: the overlapping one is present, the old one is not.
[[ -f "${b}/traces/$(basename "${in_trace}")" ]] || fail "overlapping trace not bundled"
[[ ! -e "${b}/traces/$(basename "${out_trace}")" ]] || fail "a trace from another day was bundled"

# Explicit window form, and refusal without one.
"${ROOT_DIR}/scripts/evidence-bundle.sh" --logs "${logs}" --from-epoch "${inc_from}" --to-epoch "${inc_to}" \
  --out "${TMP}/b2.tar.gz" > /dev/null || fail "--from-epoch/--to-epoch form failed"
[[ -s "${TMP}/b2.tar.gz" ]] || fail "window bundle not written"
"${ROOT_DIR}/scripts/evidence-bundle.sh" --logs "${logs}" > /dev/null 2>&1 && fail "bundle without a window was accepted"
"${ROOT_DIR}/scripts/evidence-bundle.sh" --logs "${logs}" --incident "${logs}/fleet-incidents.jsonl" --id inc-nope > /dev/null 2>&1 && fail "unknown incident id was accepted"

echo "Evidence bundle test passed."
