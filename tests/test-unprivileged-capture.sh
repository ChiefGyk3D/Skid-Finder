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

# --- Without the route, the gate refuses with the fix ---------------------------------
mkdir -p "${workdir}/nobin"
for tool in grep mktemp dirname; do ln -sf "$(command -v "${tool}")" "${workdir}/nobin/${tool}"; done
if PATH="${workdir}/nobin" "${BASH}" -c "source '${ROOT_DIR}/scripts/lib.sh'; need_capture_privileges" > /dev/null 2> "${workdir}/refuse.err"; then
  fail "the gate passed without root and without tshark"
fi
grep -q "wireshark" "${workdir}/refuse.err" || fail "the refusal did not name the wireshark group fix"

echo "Unprivileged capture test passed."
