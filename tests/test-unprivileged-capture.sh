#!/usr/bin/env bash
set -euo pipefail

# Capturing without root. btmon needs CAP_NET_RAW, but a member of the
# 'wireshark' group can record the same HCI monitor channel through tshark's
# bluetooth-monitor interface, rewrite it as btsnoop with editcap and render
# it with btmon -r. This test stubs those three tools and asserts the batch
# capture path takes that route when not root, keeps the btsnoop artifact,
# produces the text log the analysis tools read, reports progress honestly,
# and refuses with the fix when the route is unavailable.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../scripts/lib.sh
source "${ROOT_DIR}/scripts/lib.sh"

if [[ "${EUID}" -eq 0 ]]; then
  echo "Unprivileged capture test skipped (running as root)."
  exit 0
fi

workdir="$(mktemp -d)"
trap 'stop_capture_progress; rm -rf "${workdir}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 "${ROOT_DIR}/tests/make-fixture.py" --mode ambient --duration 10 --output "${workdir}/render.log"
mkdir -p "${workdir}/bin"

cat > "${workdir}/bin/tshark" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/tshark.args"
if [[ "\$1" == "-D" ]]; then printf '1. wlan0\n5. bluetooth0\n6. bluetooth-monitor\n'; exit 0; fi
while (( \$# )); do [[ "\$1" == "-w" ]] && { echo "pcapng-bytes" > "\$2"; }; shift; done
exit 0
STUB
cat > "${workdir}/bin/editcap" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/editcap.args"
# last two arguments are input and output
in="\${@: -2:1}"; out="\${@: -1}"
[[ -s "\$in" ]] && echo "btsnoop-bytes" > "\$out"
STUB
cat > "${workdir}/bin/btmon" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/btmon.args"
if [[ "\$1" == "-r" ]]; then cat "${workdir}/render.log"; exit 0; fi
echo "Failed to bind channel: Operation not permitted" >&2; exit 1
STUB
chmod +x "${workdir}"/bin/*
PATH="${workdir}/bin:${PATH}"
export PATH

# --- The gate chooses the unprivileged route ----------------------------------------
need_capture_privileges 2> "${workdir}/gate.err"
[[ "${CAPTURE_MODE}" == "unprivileged" ]] || fail "not root with tshark available, but CAPTURE_MODE=${CAPTURE_MODE}"
grep -q "wireshark group" "${workdir}/gate.err" || fail "the gate did not say how it is capturing"

# --- The capture round trip ---------------------------------------------------------
run_btmon_capture hci0 2 "${workdir}/capture.log" quiet "${workdir}/capture.btsnoop"
grep -q -- "-i bluetooth-monitor" "${workdir}/tshark.args" || fail "tshark was not pointed at bluetooth-monitor"
grep -q -- "duration:2" "${workdir}/tshark.args" || fail "capture duration was not passed to tshark"
grep -q -- "-F btsnoop" "${workdir}/editcap.args" || fail "pcapng was not rewritten as btsnoop"
[[ -s "${workdir}/capture.btsnoop" ]] || fail "the btsnoop artifact was not kept"
grep -q -- "-r ${workdir}/capture.btsnoop" "${workdir}/btmon.args" || fail "btmon did not render the kept btsnoop"
grep -q "Address:" "${workdir}/capture.log" || fail "the rendered text log has no advertising reports"
if grep -q "Failed to bind" "${workdir}/capture.log"; then fail "the live btmon path was used without root"; fi

# tee mode must both save and show.
run_btmon_capture hci0 2 "${workdir}/tee.log" tee > "${workdir}/tee.out"
grep -q "Address:" "${workdir}/tee.log" && grep -q "Address:" "${workdir}/tee.out" || fail "tee mode did not both save and print"

# --- Progress is honest about not being able to count yet -----------------------------
: > "${workdir}/empty.log"
start_capture_progress "${workdir}/empty.log" 2 1 > "${workdir}/progress.txt" 2>&1
sleep 3
stop_capture_progress
grep -q "unprivileged" "${workdir}/progress.txt" || fail "progress did not explain why counts are absent"
if grep -q "nothing captured yet" "${workdir}/progress.txt"; then fail "progress raised the no-scan alarm on a capture that cannot be counted yet"; fi

# --- The live path streams tshark fields and keeps a trace ----------------------------
python3 "${ROOT_DIR}/tests/make-fixture.py" --mode spam --format tshark --duration 30 --output "${workdir}/spam.tsv"
cat > "${workdir}/bin/tshark" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/tshark.args"
if [[ "\$1" == "-D" ]]; then printf '6. bluetooth-monitor\n'; exit 0; fi
if [[ " \$* " == *" -T fields "* ]]; then
  while :; do cat "${workdir}/spam.tsv"; sleep 0.5; done
fi
# trace writer: write until interrupted
while (( \$# )); do [[ "\$1" == "-w" ]] && out="\$2"; shift; done
trap 'echo pcapng-bytes > "\$out"; exit 0' INT TERM
while :; do sleep 0.2; done
STUB
chmod +x "${workdir}/bin/tshark"
: > "${workdir}/tshark.args"

start_unprivileged_trace "${workdir}/live.btsnoop"
run_live_pipeline hci0 3 "${workdir}/live.btsnoop" "${workdir}/live-obs.jsonl" \
  --sensor-id sensor-U -- --profile balanced --config /dev/null --window 30 --interval 1 \
  > "${workdir}/live-alerts.txt" 2> "${workdir}/live-alerts.err"
stop_unprivileged_trace "${workdir}/live.btsnoop"

grep -q -- "-i bluetooth-monitor -l -Y" "${workdir}/tshark.args" || fail "live path did not stream tshark fields from bluetooth-monitor"
grep -q -- "-e frame.time_epoch -e bthci_evt.le_meta_subevent" "${workdir}/tshark.args" || fail "live tshark field list does not match the parser"
if grep -q -- "-Y.*-w \|-w.*-Y" "${workdir}/tshark.args"; then fail "a display filter and -w were combined on one live tshark, which tshark refuses"; fi
grep -q -- "-q -w ${workdir}/live.pcapng" "${workdir}/tshark.args" || fail "no separate trace writer was started"
[[ -s "${workdir}/live.btsnoop" ]] || fail "trace was not converted to btsnoop when the run stopped"
[[ -e "${workdir}/live.pcapng" ]] && fail "pcapng was left behind after conversion"
python3 - "${workdir}/live-obs.jsonl" <<'PY'
import json, sys, time
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert rows, "no observations from the live tshark path"
assert all(r["ts_absolute"] is True for r in rows), "tshark timestamps are absolute and must be marked so"
assert all(r["sensor_id"] == "sensor-U" for r in rows)
assert any(r["addr_class"] == "resolvable" for r in rows), "address class was not derived from the address bits"
print("live tshark observations ok: %d" % len(rows))
PY
grep -q "  ALERT " "${workdir}/live-alerts.txt" || { cat "${workdir}/live-alerts.txt" "${workdir}/live-alerts.err" >&2; fail "live alerter did not fire on the tshark-format spam stream"; }

# --- Foxhunt without root: the tracker reads address/RSSI pairs from tshark ----------
cat > "${workdir}/bin/tshark" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${workdir}/tshark.args"
if [[ "\$1" == "-D" ]]; then printf '6. bluetooth-monitor\n'; exit 0; fi
# Two advertisers, one of them the target, RSSI rising as the hunter walks in.
for r in -80 -78 -75 -70 -66 -60; do
  printf 'aa:bb:cc:dd:ee:ff\t%s\n' "\$r"
  printf '11:22:33:44:55:66\t-90\n'
  sleep 0.3
done
# End of input ends the hunt cleanly (the tracker breaks on EOF).
STUB
chmod +x "${workdir}/bin/tshark"
cat > "${workdir}/bin/hciconfig" <<STUB
#!/usr/bin/env bash
echo "hci0:	Type: Primary  Bus: USB"
echo "	UP RUNNING"
STUB
# The scan helpers must not reach the real bluetoothctl/btmgmt from a test.
cat > "${workdir}/bin/bluetoothctl" <<STUB
#!/usr/bin/env bash
while IFS= read -r line; do [[ "\${line}" == "quit" ]] && break; done
STUB
cat > "${workdir}/bin/btmgmt" <<STUB
#!/usr/bin/env bash
[[ "\$*" == *info* ]] && echo "        addr AA:BB:CC:00:11:22 version 11 manufacturer 2 class 0x000000"
exit 0
STUB
chmod +x "${workdir}/bin/hciconfig" "${workdir}/bin/bluetoothctl" "${workdir}/bin/btmgmt"
mkdir -p "${workdir}/froot/scripts" "${workdir}/froot/config"
cp "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/scripts/*.py "${workdir}/froot/scripts/"
cp "${ROOT_DIR}/config/interfaces.conf.example" "${workdir}/froot/config/interfaces.conf"
: > "${workdir}/tshark.args"
timeout -k 2 30 "${workdir}/froot/scripts/foxhunt-rssi.sh" AA:BB:CC:DD:EE:FF hci0 > "${workdir}/fox.txt" 2> "${workdir}/fox.err" || true
grep -q -- "-e bthci_evt.bd_addr -e bthci_evt.rssi" "${workdir}/tshark.args" || { cat "${workdir}/fox.err" >&2; fail "foxhunt did not stream address/RSSI pairs from tshark"; }
grep -q "median" "${workdir}/fox.txt" || { cat "${workdir}/fox.txt" "${workdir}/fox.err" >&2; fail "foxhunt printed no median RSSI"; }
if grep -q -- "-90" "${workdir}/fox.txt"; then fail "foxhunt reported the other device's RSSI"; fi
last="$(grep -oE 'median[0-9]*=-?[0-9]+' "${workdir}/fox.txt" | tail -1 | cut -d= -f2)"
first="$(grep -oE 'median[0-9]*=-?[0-9]+' "${workdir}/fox.txt" | head -1 | cut -d= -f2)"
(( last > first )) || fail "median did not rise while the target got louder (first=${first} last=${last})"
echo "foxhunt without root ok: median ${first} -> ${last} dBm"

# --- Without the route, the gate refuses with the fix ---------------------------------
mkdir -p "${workdir}/nobin"
for tool in grep mktemp dirname; do ln -sf "$(command -v "${tool}")" "${workdir}/nobin/${tool}"; done
if PATH="${workdir}/nobin" "${BASH}" -c "source '${ROOT_DIR}/scripts/lib.sh'; need_capture_privileges" > /dev/null 2> "${workdir}/refuse.err"; then
  fail "the gate passed without root and without tshark"
fi
grep -q "wireshark" "${workdir}/refuse.err" || fail "the refusal did not name the wireshark group fix"

echo "Unprivileged capture test passed."
