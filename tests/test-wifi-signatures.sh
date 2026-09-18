#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi detector regression test: the parser reads tshark's field format, each
# family fires on its own fixture, ambient traffic fires nothing on any
# profile, a beacon flood is not also reported as a hundred evil twins, and a
# short capture is refused. The precision/recall gate runs separately through
# tests/test-detector-metrics.py --modality wifi.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FIX="${ROOT_DIR}/tests/make-wifi-fixture.py"
SCAN="${ROOT_DIR}/scripts/wifi-signature-scan.py"
fail() { echo "FAIL: $*" >&2; exit 1; }

for m in ambient deauth beacon evil_twin karma; do
  python3 "${FIX}" --mode "${m}" --duration 30 --output "${TMP}/${m}.tsv"
done

# --- Parser sanity --------------------------------------------------------------
python3 - "${ROOT_DIR}" "${TMP}/deauth.tsv" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import wifi_parse
frames = wifi_parse.parse_frames(sys.argv[2])
assert frames, "no frames parsed"
kinds = {f.kind for f in frames}
assert {"beacon", "deauth", "probe_req"} <= kinds, kinds
assert any(f.rssi is not None for f in frames) and any(f.channel for f in frames)
assert any(f.reason == 7 for f in frames if f.kind == "deauth"), "reason code not parsed"
assert wifi_parse.capture_duration(frames) > 20
assert any(f.sa_random for f in frames if f.kind == "probe_req"), "locally administered bit not detected"
# Both spellings of the subtype field, and hex-encoded SSIDs, must parse.
assert wifi_parse.parse_line("1.0\t8\tAA:BB:CC:DD:EE:01\tFF:FF:FF:FF:FF:FF\tAA:BB:CC:DD:EE:01\t56656e7565\t-50\t6\t").ssid == "Venue"
assert wifi_parse.parse_line("1.0\t0x000c\tAA:BB:CC:DD:EE:01\tFF:FF:FF:FF:FF:FF\tAA:BB:CC:DD:EE:01\t\t-50\t6\t7").kind == "deauth"
print("wifi parser sanity ok: %d frames" % len(frames))
PY

# --- Each family on its own fixture --------------------------------------------
check() {
  local mode="$1" expect="$2"
  python3 "${SCAN}" --input "${TMP}/${mode}.tsv" --profile balanced --config /dev/null > "${TMP}/${mode}.out" 2>/dev/null
  grep -q "MATCH ${expect}" "${TMP}/${mode}.out" || { cat "${TMP}/${mode}.out" >&2; fail "${mode} fixture did not match '${expect}'"; }
}
check deauth "Deauthentication/disassociation flood"
check beacon "Beacon flood (fake access points)"
check evil_twin "Evil twin (one SSID from unrelated hardware)"
check karma "KARMA-style responder"

# A beacon flood invents SSIDs by the hundred; that is one finding, not an
# evil twin per invented name.
if grep -q "MATCH Evil twin" "${TMP}/beacon.out"; then
  fail "beacon flood was also reported as evil twins"
fi

# --- Ambient must be silent on every profile ------------------------------------
for profile in conservative balanced aggressive; do
  python3 "${SCAN}" --input "${TMP}/ambient.tsv" --profile "${profile}" --config /dev/null > "${TMP}/amb-${profile}.out" 2>/dev/null
  if grep -q '^MATCH ' "${TMP}/amb-${profile}.out"; then
    cat "${TMP}/amb-${profile}.out" >&2
    fail "ambient Wi-Fi matched under '${profile}'"
  fi
done

# --- Short-capture guard -----------------------------------------------------------
python3 "${FIX}" --mode deauth --duration 2 --output "${TMP}/short.tsv"
python3 "${SCAN}" --input "${TMP}/short.tsv" --profile conservative --config /dev/null > "${TMP}/short.out" 2>/dev/null
grep -q '^MATCH ' "${TMP}/short.out" && fail "conservative profile judged a 2 s capture"

# --- Config file: unknown keys are reported, known keys take effect ----------------
printf '[balanced]\ndeauth_min_rate = 1000\nbogus_key = 1\n' > "${TMP}/tuned.conf"
python3 "${SCAN}" --input "${TMP}/deauth.tsv" --profile balanced --config "${TMP}/tuned.conf" > "${TMP}/tuned.out" 2> "${TMP}/tuned.err"
grep -q "unrecognised key" "${TMP}/tuned.err" || fail "unknown config key was not reported"
grep -q "MATCH Deauthentication" "${TMP}/tuned.out" && fail "raised deauth threshold did not take effect"

echo "Wi-Fi signature detection test passed."
