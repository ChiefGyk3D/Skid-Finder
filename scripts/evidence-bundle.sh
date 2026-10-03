#!/usr/bin/env bash
set -euo pipefail

# Evidence bundle: everything a venue's security team or law enforcement
# needs about one incident, and nothing about the rest of the day.
#
# Given a time window (or an incident record, whose first_seen/last_seen
# become the window), the bundle collects from logs/:
#
#   - observation files (obs-*.jsonl, wifi-obs-*.jsonl) trimmed to the
#     window, so other people's devices outside it stay out
#   - alert and incident records within the window (ble-alert, wifi-alert,
#     fleet-alert, fleet-incident), which carry no addresses anyway
#   - capture traces whose run overlapped the window (btsnoop, pcapng),
#     whole, because a trace cannot be trimmed without tshark and a copy is
#     the evidence a third party can verify with their own tools
#   - a summary the handler can read, and a sha256 manifest of every file
#
# Output is one tar.gz under logs/evidence/. Records contain personal data:
# hand the bundle over, keep the local copy only as long as the incident
# needs it (docs/data-handling.md).
#
# Usage:
#   scripts/evidence-bundle.sh --incident logs/fleet-incidents.jsonl [--id inc-...]
#   scripts/evidence-bundle.sh --from "2026-09-19 14:00" --to "2026-09-19 14:20"
#   scripts/evidence-bundle.sh --from-epoch 1758300000 --to-epoch 1758301200
# Options: --logs DIR (default logs/), --out FILE, --margin SECONDS (default 60)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGS="${ROOT_DIR}/logs"
OUT=""
MARGIN=60
FROM=""
TO=""
INCIDENT_FILE=""
INCIDENT_ID=""

while (( $# )); do
  case "$1" in
    --logs) LOGS="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --margin) MARGIN="${2:-}"; shift 2 ;;
    --from) FROM="$(date -d "${2:-}" +%s)"; shift 2 ;;
    --to) TO="$(date -d "${2:-}" +%s)"; shift 2 ;;
    --from-epoch) FROM="${2:-}"; shift 2 ;;
    --to-epoch) TO="${2:-}"; shift 2 ;;
    --incident) INCIDENT_FILE="${2:-}"; shift 2 ;;
    --id) INCIDENT_ID="${2:-}"; shift 2 ;;
    -h|--help) sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[[ -d "${LOGS}" ]] || { echo "no such logs directory: ${LOGS}" >&2; exit 1; }
[[ "${MARGIN}" =~ ^[0-9]+$ ]] || { echo "--margin must be a whole number of seconds" >&2; exit 1; }

if [[ -n "${INCIDENT_FILE}" ]]; then
  [[ -r "${INCIDENT_FILE}" ]] || { echo "cannot read ${INCIDENT_FILE}" >&2; exit 1; }
  # The incident's closing record carries the whole span; fall back to the
  # last record for it if it never closed.
  read -r FROM TO INCIDENT_ID < <(python3 - "${INCIDENT_FILE}" "${INCIDENT_ID}" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
best = None
for line in open(path):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    if not str(r.get("schema", "")).startswith("fleet-incident/"):
        continue
    if want and r.get("id") != want:
        continue
    if best is None or r.get("status") == "closed" or r["ts"] >= best["ts"]:
        best = r
if best is None:
    sys.exit("no incident record found" + (f" for id {want}" if want else ""))
print(int(best["first_seen"]), int(best["last_seen"]) + 1, best["id"])
PY
)
fi

[[ -n "${FROM}" && -n "${TO}" ]] || { echo "give --from/--to (or --from-epoch/--to-epoch), or --incident FILE" >&2; exit 1; }
[[ "${FROM}" =~ ^[0-9]+$ && "${TO}" =~ ^[0-9]+$ ]] || { echo "window bounds must be epoch seconds" >&2; exit 1; }
(( TO > FROM )) || { echo "--to must be after --from" >&2; exit 1; }

WFROM=$(( FROM - MARGIN ))
WTO=$(( TO + MARGIN ))
STAMP="$(date -u -d "@${FROM}" +%Y%m%dT%H%M%SZ)"
LABEL="${INCIDENT_ID:-window-${STAMP}}"
mkdir -p "${LOGS}/evidence"
OUT="${OUT:-${LOGS}/evidence/skid-finder-${LABEL}.tar.gz}"

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BUNDLE="${WORK}/skid-finder-${LABEL}"
mkdir -p "${BUNDLE}/records" "${BUNDLE}/traces"

# Records: keep lines whose ts falls in the window. Files that are not JSONL
# with a ts (or are entirely outside) contribute nothing and are skipped.
python3 - "${LOGS}" "${BUNDLE}/records" "${WFROM}" "${WTO}" > "${WORK}/records.txt" <<'PY'
import glob, json, os, sys
logs, out, lo, hi = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
kept = {}
for path in sorted(glob.glob(os.path.join(logs, "*.jsonl"))):
    name = os.path.basename(path)
    rows = []
    try:
        with open(path, encoding="utf-8", errors="ignore") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = r.get("ts")
                if not isinstance(ts, (int, float)):
                    continue
                # An incident spans a range; keep it if the range overlaps.
                if str(r.get("schema", "")).startswith("fleet-incident/"):
                    if r.get("last_seen", ts) >= lo and r.get("first_seen", ts) <= hi:
                        rows.append(line)
                elif lo <= ts <= hi:
                    rows.append(line)
    except OSError:
        continue
    if rows:
        with open(os.path.join(out, name), "w", encoding="utf-8") as handle:
            handle.write("\n".join(rows) + "\n")
        kept[name] = len(rows)
for name, n in kept.items():
    print(f"{name}\t{n}")
PY

# Traces: a capture file is whole or nothing. Its run is dated by the stamp
# in its name (btmon-<iface>-YYYYmmdd-HHMMSS) as the start and its mtime as
# the end; keep it if that span overlaps the window.
python3 - "${LOGS}" "${BUNDLE}/traces" "${WFROM}" "${WTO}" > "${WORK}/traces.txt" <<'PY'
import glob, os, re, shutil, sys, time
logs, out, lo, hi = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
stamp = re.compile(r"(\d{8})-(\d{6})")
for path in sorted(glob.glob(os.path.join(logs, "*.btsnoop")) + glob.glob(os.path.join(logs, "*.pcapng"))
                   + glob.glob(os.path.join(logs, "wifi-*.tsv")) + glob.glob(os.path.join(logs, "btmon-*.log"))):
    name = os.path.basename(path)
    m = stamp.search(name)
    end = os.path.getmtime(path)
    if m:
        start = time.mktime(time.strptime(m.group(1) + m.group(2), "%Y%m%d%H%M%S"))
    else:
        start = end
    if end >= lo and start <= hi:
        shutil.copy2(path, os.path.join(out, name))
        print(f"{name}\t{os.path.getsize(path)}")
PY

{
  echo "Skid Finder evidence bundle"
  echo "generated_at=$(date -Is)"
  echo "toolkit_version=$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION" 2>/dev/null || echo unknown)"
  echo "incident=${INCIDENT_ID:-none}"
  echo "window_from=$(date -Is -d "@${FROM}") (${FROM})"
  echo "window_to=$(date -Is -d "@${TO}") (${TO})"
  echo "margin_seconds=${MARGIN}"
  echo "host=$(id -un)"
  echo
  echo "Records (file, lines within the window):"
  if [[ -s "${WORK}/records.txt" ]]; then sed 's/^/  /' "${WORK}/records.txt"; else echo "  none"; fi
  echo
  echo "Traces (file, bytes; whole files whose run overlapped the window):"
  if [[ -s "${WORK}/traces.txt" ]]; then sed 's/^/  /' "${WORK}/traces.txt"; else echo "  none"; fi
  echo
  echo "What this is: passive observations of Bluetooth advertisements and"
  echo "Wi-Fi management frames, and the detector's alerts over them. Nothing"
  echo "was transmitted, joined or decrypted. Addresses and advertised names"
  echo "are other people's device identifiers; identities marked tier 'model'"
  echo "are products, possibly several people, not units. See docs/data-handling.md."
} > "${BUNDLE}/SUMMARY.txt"

( cd "${BUNDLE}" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z | xargs -0 sha256sum > MANIFEST.sha256 )
tar -C "${WORK}" -czf "${OUT}" "$(basename "${BUNDLE}")"

echo "Evidence bundle: ${OUT}"
echo "  records: $(wc -l < "${WORK}/records.txt" | tr -d ' ') file(s), traces: $(wc -l < "${WORK}/traces.txt" | tr -d ' ') file(s)"
echo "  verify with: tar -xzf ${OUT} && cd $(basename "${BUNDLE}") && sha256sum -c MANIFEST.sha256"
