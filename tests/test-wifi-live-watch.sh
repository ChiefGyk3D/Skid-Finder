#!/usr/bin/env bash
set -euo pipefail

# Wi-Fi live path regression test with stubbed tools: monitor mode is set and
# then restored (and NetworkManager handed the interface back), the channel
# hopper runs and stops, tshark is asked for the field list the parser
# expects with per-packet flushing, observations land with the sensor id,
# and the live alerter fires on a deauth flood and writes JSON alert records.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

workdir="$(mktemp -d)"
trap 'stop_channel_hop; rm -rf "${workdir}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 "${ROOT_DIR}/tests/make-wifi-fixture.py" --mode deauth --duration 30 --output "${workdir}/deauth.tsv"
mkdir -p "${workdir}/bin"

cat > "${workdir}/bin/tshark" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/tshark.args"
if [[ " \$* " == *" -r "* ]]; then cat "${workdir}/deauth.tsv"; exit 0; fi
while :; do cat "${workdir}/deauth.tsv"; sleep 0.5; done
STUB
for tool in iw ip nmcli; do
  cat > "${workdir}/bin/${tool}" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/${tool}.args"
if [[ "${tool}" == nmcli && "\$*" == *"device show"* ]]; then echo "GENERAL.STATE:100 (connected)"; fi
exit 0
STUB
done
chmod +x "${workdir}"/bin/*
PATH="${workdir}/bin:${PATH}"
export PATH

# --- Monitor mode on/off and the hopper -------------------------------------------
wifi_monitor_on wlan9
grep -q "dev wlan9 set type monitor" "${workdir}/iw.args" || fail "monitor mode was never requested"
grep -q "device set wlan9 managed no" "${workdir}/nmcli.args" || fail "NetworkManager was not told to let go of the interface"
start_channel_hop wlan9 "1 6 11" 50
sleep 0.5
stop_channel_hop
grep -q "set channel 6" "${workdir}/iw.args" || fail "channel hopper never changed channel"
[[ -z "${CHANNEL_HOP_PID}" ]] || fail "hopper pid not cleared"
wifi_monitor_off wlan9
grep -q "dev wlan9 set type managed" "${workdir}/iw.args" || fail "interface not returned to managed mode"
grep -q "device set wlan9 managed yes" "${workdir}/nmcli.args" || fail "interface not handed back to NetworkManager"

# --- The live pipeline --------------------------------------------------------------
run_wifi_live_pipeline wlan9 4 "${workdir}/obs.jsonl" --sensor-id sensor-W \
  -- --profile balanced --config /dev/null --window 30 --interval 1 --jsonl-out "${workdir}/alerts.jsonl" \
  > "${workdir}/alerts.txt" 2> "${workdir}/alerts.err"

grep -q -- "-l " "${workdir}/tshark.args" || fail "tshark was not asked to flush per packet (-l)"
grep -q -- "-e frame.time_epoch -e wlan.fc.type_subtype" "${workdir}/tshark.args" || fail "tshark field list does not start as the parser expects"
grep -q -- "wlan.fc.type == 0" "${workdir}/tshark.args" || fail "capture is not filtered to management frames"

[[ -s "${workdir}/obs.jsonl" ]] || { cat "${workdir}/alerts.err" >&2; fail "no Wi-Fi observations written"; }
python3 - "${workdir}/obs.jsonl" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1]):
    e = json.loads(line)
    assert e["schema"] == "wifi-obs/1" and e["modality"] == "wifi"
    assert e["sensor_id"] == "sensor-W"
    assert e["ts_absolute"] is True
    assert e["tier"] in ("strong", "session", "model")
    assert e["identity_key"].startswith(("addr:", "fp:wifi:"))
    n += 1
print("wifi observations ok: %d" % n)
PY
grep -q "  ALERT Deauthentication" "${workdir}/alerts.txt" || { cat "${workdir}/alerts.txt" "${workdir}/alerts.err" >&2; fail "live alerter did not fire on the deauth flood"; }
python3 - "${workdir}/alerts.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert rows and all(r["schema"] == "wifi-alert/1" for r in rows)
assert any(r["matches"] for r in rows) and rows[-1]["sensor_id"] == "sensor-W"
print("wifi alert records ok: %d evaluations" % len(rows))
PY

# --- Field extract from a saved capture ---------------------------------------------
wifi_fields_from_pcap "${workdir}/x.pcapng" > "${workdir}/fields.tsv"
[[ -s "${workdir}/fields.tsv" ]] || fail "field extract from pcap produced nothing"

# --- The wrappers must use the helpers ------------------------------------------------
for script in wifi-capture.sh wifi-live-watch.sh; do
  for needle in wifi_monitor_on wifi_monitor_off start_channel_hop; do
    grep -q "${needle}" "${ROOT_DIR}/scripts/${script}" || fail "${script} does not call ${needle}"
  done
done
grep -q "ble-publish.py" "${ROOT_DIR}/scripts/wifi-live-watch.sh" || fail "wifi-live-watch.sh does not ship records when a broker is configured"

echo "Wi-Fi live watch test passed."
