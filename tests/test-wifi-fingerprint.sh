#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi identity: a client that rotates its probe MAC must still be one
# identity (its content fingerprint), a beacon spammer inventing a BSSID
# per frame must collapse to one fingerprint ("the same tool, again"), an
# access point must be a strong identity by its BSSID, the sighting store
# must recognise a return visit, and the watchlist and hunt must resolve.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FIX="${ROOT_DIR}/tests/make-wifi-fixture.py"
FP="${ROOT_DIR}/scripts/wifi-fingerprint.py"
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 "${FIX}" --mode ambient --duration 60 --output "${TMP}/ambient.tsv"
python3 "${FIX}" --mode beacon --duration 30 --output "${TMP}/beacon.tsv"

# --- Parser: the four fingerprint columns and comma-joined scalars -------------------
python3 - "${ROOT_DIR}" "${TMP}/ambient.tsv" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import wifi_parse
frames = wifi_parse.parse_frames(sys.argv[2])
probes = [f for f in frames if f.kind == "probe_req"]
assert probes and all(f.tags and f.rates for f in probes), "probe requests lost their tag order or rates"
assert any(f.ht_caps for f in probes) and any(f.vendor_ouis for f in probes)
# A scalar field printed with two occurrences must still parse (first wins).
f = wifi_parse.parse_line("1.0,1.0\t0x0004,0x0004\taa:bb:cc:dd:ee:01\tff:ff:ff:ff:ff:ff\tff:ff:ff:ff:ff:ff\tX,Y\t-50,-51\t6\t\t0,1\t0x82\t0x19ef\t0050f2")
assert f.kind == "probe_req" and f.ssid == "X" and f.rssi == -50 and f.tags == [0, 1] and f.vendor_ouis == ["0050f2"]
print("wifi parser fingerprint fields ok")
PY

# --- Rotating probe MACs collapse to their model; beacons to one tool -----------------
python3 "${FP}" --input "${TMP}/ambient.tsv" --no-store --limit 100 > "${TMP}/amb.txt"
python3 - "${TMP}/amb.txt" "${TMP}/ambient.tsv" <<'PY'
import sys
report = open(sys.argv[1]).read()
rows = [l.split() for l in report.splitlines() if l.startswith(("fp:", "addr:"))]
model = [r for r in rows if r[1] == "model"]
strong = [r for r in rows if r[1] == "strong"]
assert 2 <= len(model) <= 4, f"20 clients of 3 models should be 3 model-tier identities, got {len(model)}: {[r[0] for r in model]}"
total_addrs = sum(int(r[3]) for r in model)
assert total_addrs > 20, f"model identities should span many rotated addresses, got {total_addrs}"
assert len(strong) >= 6, f"six access points should be strong identities, got {len(strong)}"
print("wifi identity ok: %d model identities over %d rotated addresses, %d strong" % (len(model), total_addrs, len(strong)))
PY

python3 "${FP}" --input "${TMP}/beacon.tsv" --no-store --limit 100 > "${TMP}/beacon.txt"
python3 - "${TMP}/beacon.txt" <<'PY'
import sys
rows = [l.split() for l in open(sys.argv[1]).read().splitlines() if l.startswith(("fp:", "addr:"))]
model = [r for r in rows if r[1] == "model"]
big = [r for r in model if int(r[3]) > 100]
assert len(big) == 1, f"a beacon flood should collapse to one fingerprint with hundreds of BSSIDs, got {[(r[0], r[3]) for r in model]}"
print("beacon flood -> one fingerprint over %s invented BSSIDs" % big[0][3])
PY

# --- Sighting store: a return visit is marked ------------------------------------------
python3 "${FP}" --input "${TMP}/ambient.tsv" --store "${TMP}/store.json" > /dev/null
python3 "${FP}" --input "${TMP}/ambient.tsv" --store "${TMP}/store.json" > "${TMP}/second.txt"
grep -q "previously_seen=[1-9]" "${TMP}/second.txt" || fail "second capture did not recognise earlier senders"
grep -qE "^(fp|addr):[^ ]+ +[a-z]+ +[0-9]+ +[0-9]+ +-?[0-9]* +\*" "${TMP}/second.txt" || fail "no sender was starred as previously seen"

# --- Watchlist and hunt -----------------------------------------------------------------
bssid="$(grep -m1 '^addr:' "${TMP}/amb.txt" | cut -d: -f2- | cut -d' ' -f1)"
fpkey="$(grep -m1 '^fp:wifi:' "${TMP}/amb.txt" | awk '{print $1}')"
printf '%s   # the venue AP\nname:starbucks   # someone probing for it\n%s   # a phone model\n' "${bssid}" "${fpkey}" > "${TMP}/watch.conf"
python3 "${FP}" --input "${TMP}/ambient.tsv" --no-store --watchlist "${TMP}/watch.conf" > "${TMP}/watch.txt"
grep -q "^HIT ${bssid}" "${TMP}/watch.txt" || fail "watchlist did not hit the AP by address"
grep -q "^HIT name:starbucks" "${TMP}/watch.txt" || fail "watchlist did not hit by probed SSID"
grep -q "^HIT ${fpkey}" "${TMP}/watch.txt" && grep -q "caution:" "${TMP}/watch.txt" || fail "watchlist fingerprint hit missing its caution"
n="$(python3 "${FP}" --input "${TMP}/ambient.tsv" --no-store --hunt "${fpkey}" 2>/dev/null | wc -l | tr -d ' ')"
(( n > 1 )) || fail "hunt by fingerprint should list every rotated address, got ${n}"

echo "Wi-Fi fingerprint test passed."
