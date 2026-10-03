#!/usr/bin/env bash
set -euo pipefail

# Tests for device fingerprinting and identity tiering.
#
# The claim this tool makes is that it can track a device across captures. That
# claim is only true for some address classes, so these tests pin down which,
# and assert the tool does not overstate what it knows.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

FP="${ROOT_DIR}/scripts/ble-fingerprint.py"
FIXTURE="${ROOT_DIR}/tests/make-fixture.py"

python3 "${FIXTURE}" --mode identity --output "${TMP_DIR}/id.log"

# --- Address classification ---------------------------------------------------
# 'Non-Resolvable' contains 'Resolvable' as a substring, so a containment test
# silently misclassifies it as a rotating-but-resolvable address.
python3 - "${ROOT_DIR}" "${TMP_DIR}/id.log" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import ble_parse

records = ble_parse.parse_records(sys.argv[2])
classes = {r.addr_class for r in records}
for expected in ("public", "static", "resolvable", "non-resolvable"):
    assert expected in classes, f"address class {expected!r} not parsed: {classes}"

for record in records:
    if record.addr_class == "non-resolvable":
        assert not record.resolvable, "non-resolvable address reported as resolvable"
        assert record.rotates, "non-resolvable address reported as stable"
    if record.addr_class == "static":
        assert not record.rotates, "static address reported as rotating"
    if record.addr_class == "public":
        assert record.is_public, "OUI-annotated address not treated as public"
print("address classification ok")
PY

# --- Identity tiers -----------------------------------------------------------
python3 "${FP}" --input "${TMP_DIR}/id.log" --no-store --limit 50 > "${TMP_DIR}/report.txt"

# A public address is an individual device.
grep -q 'addr:40:ed:98:18:de:ab .*strong' "${TMP_DIR}/report.txt" \
  || { echo "FAIL: public address not tiered 'strong'" >&2; cat "${TMP_DIR}/report.txt" >&2; exit 1; }

# A random static address is stable only until reboot.
grep -q 'addr:e7:d3:b0:3f:95:e5 .*session' "${TMP_DIR}/report.txt" \
  || { echo "FAIL: static address not tiered 'session'" >&2; cat "${TMP_DIR}/report.txt" >&2; exit 1; }

# Rotating addresses must never be presented as an individual device.
if grep -E '^fp:[0-9a-f]+ +strong' "${TMP_DIR}/report.txt"; then
  echo "FAIL: a rotating-address group claimed 'strong' identity." >&2
  exit 1
fi
if grep -E '^fp:[0-9a-f]+ +session' "${TMP_DIR}/report.txt"; then
  echo "FAIL: a rotating-address group claimed 'session' identity." >&2
  exit 1
fi

# --- Coalescing ---------------------------------------------------------------
# The serial-bearing device omits its name on half its adverts. Those unnamed
# adverts key on the address while the named ones key on the serial, so without
# coalescing one physical device appears twice.
if [[ "$(grep -c 'DA:AB:97:C5:53:68\|5am0191117' "${TMP_DIR}/report.txt")" -gt 1 ]]; then
  echo "FAIL: one device was reported under more than one identity key." >&2
  grep -n 'DA:AB:97:C5:53:68\|5am0191117' "${TMP_DIR}/report.txt" >&2
  exit 1
fi
grep -q 'serial:5am0191117 .*strong' "${TMP_DIR}/report.txt" \
  || { echo "FAIL: serial-bearing device not tiered 'strong'" >&2; exit 1; }

# All 8 adverts must be attributed to it, not just the 4 that carried a name.
if ! awk '/^serial:5am0191117/ { if ($3 != 8) exit 1 }' "${TMP_DIR}/report.txt"; then
  echo "FAIL: coalesced device lost sightings." >&2
  grep '^serial:' "${TMP_DIR}/report.txt" >&2
  exit 1
fi

# --- Cross-capture tracking ---------------------------------------------------
store="${TMP_DIR}/sightings.json"
python3 "${FP}" --input "${TMP_DIR}/id.log" --store "${store}" > "${TMP_DIR}/pass1.txt"
grep -q '^previously_seen=0$' "${TMP_DIR}/pass1.txt" \
  || { echo "FAIL: first pass should not recognise anything." >&2; exit 1; }

python3 "${FP}" --input "${TMP_DIR}/id.log" --store "${store}" > "${TMP_DIR}/pass2.txt"
if grep -q '^previously_seen=0$' "${TMP_DIR}/pass2.txt"; then
  echo "FAIL: second pass did not recognise devices from the store." >&2
  exit 1
fi

# A corrupt store must not take the tool down mid-hunt.
echo 'not json' > "${TMP_DIR}/bad.json"
python3 "${FP}" --input "${TMP_DIR}/id.log" --store "${TMP_DIR}/bad.json" \
  > "${TMP_DIR}/pass3.txt" 2>"${TMP_DIR}/pass3.err"
grep -q 'warn:' "${TMP_DIR}/pass3.err" \
  || { echo "FAIL: corrupt store did not warn." >&2; exit 1; }

# --- Watchlist ----------------------------------------------------------------
cat > "${TMP_DIR}/watch.txt" <<'EOF'
# comments and blank lines are ignored

name:whoop            # by advertised name
40:ED:98:18:DE:AB     # by address
5AM0191117            # by serial
EOF

python3 "${FP}" --input "${TMP_DIR}/id.log" --no-store \
  --watchlist "${TMP_DIR}/watch.txt" > "${TMP_DIR}/watch-out.txt"
for needle in 'HIT name:whoop' 'HIT 40:ED:98:18:DE:AB' 'HIT 5AM0191117'; do
  grep -q "${needle}" "${TMP_DIR}/watch-out.txt" \
    || { echo "FAIL: watchlist missed ${needle}" >&2; cat "${TMP_DIR}/watch-out.txt" >&2; exit 1; }
done

# --- Hunt mode ----------------------------------------------------------------
# Hunt output feeds foxhunt-rssi.sh, so stdout must be addresses and nothing else.
python3 "${FP}" --input "${TMP_DIR}/id.log" --no-store --hunt whoop \
  > "${TMP_DIR}/hunt.txt" 2>/dev/null
if [[ "$(cat "${TMP_DIR}/hunt.txt")" != "DA:AB:97:C5:53:68" ]]; then
  echo "FAIL: hunt did not resolve to the expected address." >&2
  cat "${TMP_DIR}/hunt.txt" >&2
  exit 1
fi
while read -r line; do
  [[ "${line}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] \
    || { echo "FAIL: hunt stdout contained non-address text: ${line}" >&2; exit 1; }
done < "${TMP_DIR}/hunt.txt"

# A miss must be an error, so a hunt script does not proceed with no targets.
if python3 "${FP}" --input "${TMP_DIR}/id.log" --no-store --hunt nosuchdevice \
     > /dev/null 2>&1; then
  echo "FAIL: hunt for an absent device returned success." >&2
  exit 1
fi

# A model-level hunt must warn that the addresses may be different devices.
python3 "${FP}" --input "${TMP_DIR}/id.log" --no-store --hunt apple \
  > /dev/null 2>"${TMP_DIR}/apple.err" || true
grep -q 'warn:' "${TMP_DIR}/apple.err" \
  || { echo "FAIL: model-level hunt did not warn about ambiguity." >&2; exit 1; }

# --- Both capture paths must file a device under the same identity key -------------
# A sensor net mixes laptops on the tshark route with uConsoles on btmon.
# The same synthetic traffic in both spellings must produce the same set of
# identity keys, or a device would be two devices depending on who heard it.
for mode in identity spam ambient; do
  python3 "${FIXTURE}" --mode "${mode}" --duration 10 --output "${TMP_DIR}/x-${mode}.log"
  python3 "${FIXTURE}" --mode "${mode}" --duration 10 --format tshark --output "${TMP_DIR}/x-${mode}.tsv"
  python3 "${ROOT_DIR}/scripts/ble-observe.py" --input "${TMP_DIR}/x-${mode}.log" 2>/dev/null \
    | python3 -c 'import sys,json; print("\n".join(sorted({json.loads(l)["identity_key"] for l in sys.stdin})))' > "${TMP_DIR}/keys-btmon"
  python3 "${ROOT_DIR}/scripts/ble-observe.py" --input "${TMP_DIR}/x-${mode}.tsv" --format tshark 2>/dev/null \
    | python3 -c 'import sys,json; print("\n".join(sorted({json.loads(l)["identity_key"] for l in sys.stdin})))' > "${TMP_DIR}/keys-tshark"
  if ! diff -q "${TMP_DIR}/keys-btmon" "${TMP_DIR}/keys-tshark" > /dev/null; then
    echo "FAIL: identity keys differ between the btmon and tshark paths for '${mode}' traffic" >&2
    diff "${TMP_DIR}/keys-btmon" "${TMP_DIR}/keys-tshark" | head -10 >&2
    exit 1
  fi
done
echo "cross-path identity ok: identical keys for identity, spam and ambient traffic"

echo "BLE fingerprint test passed."
