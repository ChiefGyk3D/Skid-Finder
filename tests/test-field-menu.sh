#!/usr/bin/env bash
set -euo pipefail

# Regression test for the field menu.
#
# The menu exists so the common paths do not have to be typed from memory on
# a small screen, and its one rule is that it only builds command lines: what
# it shows is exactly what runs, and nothing is menu-only. This test drives it
# through --print, which needs no terminal, and checks that every action maps
# to a script that exists, that defaults come from config/interfaces.conf, that
# arguments land where the underlying script expects them, and that the
# failure cases say why instead of building a broken command.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MENU="${ROOT_DIR}/scripts/skid-finder.sh"

# Work in a copy so the operator's real config and logs are never touched, and
# so the "no capture yet" and "config missing" cases are reproducible.
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
mkdir -p "${workdir}/root/config" "${workdir}/root/logs" "${workdir}/root/tests"
cp -r "${ROOT_DIR}/scripts" "${workdir}/root/scripts"
cp "${ROOT_DIR}"/config/*.example "${workdir}/root/config/"
cp "${ROOT_DIR}/tests/test-toolkit.sh" "${workdir}/root/tests/"
MENU="${workdir}/root/scripts/skid-finder.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# --- Every listed action must build, or refuse with a reason -------------------
"${MENU}" --list > "${workdir}/list.txt"
for action in status health recover watch field capture mode aio validate setup; do
  grep -q "^  ${action}" "${workdir}/list.txt" || fail "--list does not show '${action}'"
done

# --- Every script the menu names must exist ------------------------------------
# A rename in scripts/ must break this test, not the operator in the field.
for script in detect-hci.sh set-adapter-mode.sh troubleshoot-bluetooth.sh recover-hci.sh \
              ble-spam-watch.sh ble-field-run.sh capture-btmon.sh foxhunt-rssi.sh \
              ble-fingerprint.py ble-signature-scan.py aio-feature-profile.sh; do
  grep -q "${script}" "${MENU}" || fail "menu no longer references ${script}"
  [[ -e "${ROOT_DIR}/scripts/${script}" ]] || fail "menu references scripts/${script}, which does not exist"
done

# --- Defaults come from config, not from the script ----------------------------
cat > "${workdir}/root/config/interfaces.conf" <<'CONF'
ADAPTER_MODE="dual"
CAPTURE_HCI="hci7"
HUNT_HCI="hci8"
SCAN_SECONDS="45"
CONF

out="$("${MENU}" --print watch)"
[[ "${out}" == *"ble-spam-watch.sh hci7 45" ]] || fail "watch did not take iface/seconds from config: ${out}"

out="$("${MENU}" --print field)"
[[ "${out}" == *"ble-field-run.sh hci7 300" ]] || fail "field run default is not 300s on the capture adapter: ${out}"

out="$("${MENU}" --print recover)"
[[ "${out}" == *"recover-hci.sh hci8" ]] || fail "recover should default to the hunt adapter: ${out}"

# Explicit arguments override the defaults, in the order the scripts expect.
out="$("${MENU}" --print watch hci0 12)"
[[ "${out}" == *"ble-spam-watch.sh hci0 12" ]] || fail "watch arguments not passed through: ${out}"

# --- Root handling --------------------------------------------------------------
# As a normal user the radio commands get sudo and the analysis commands do not,
# so logs/sightings.json stays owned by the operator.
if [[ "${EUID}" -ne 0 ]]; then
  [[ "$("${MENU}" --print watch)" == sudo\ * ]] || fail "radio action not prefixed with sudo for a normal user"
  [[ "$("${MENU}" --print health)" != sudo\ * ]] || fail "health check should not need sudo"
fi

# --- Foxhunt: a MAC goes straight through; a name resolves from the latest capture
out="$("${MENU}" --print hunt AA:BB:CC:DD:EE:FF)"
[[ "${out}" == *"foxhunt-rssi.sh AA:BB:CC:DD:EE:FF hci8" ]] || fail "MAC hunt malformed: ${out}"

if "${MENU}" --print hunt flipper > /dev/null 2> "${workdir}/err.txt"; then
  fail "name hunt with no capture should refuse, not build a command"
fi
grep -q "no capture" "${workdir}/err.txt" || fail "name hunt refusal does not say why"

# Same for the two analysis actions that need a capture.
for action in fingerprint scan; do
  if "${MENU}" --print "${action}" > /dev/null 2>&1; then
    fail "${action} with no capture should refuse"
  fi
done

: > "${workdir}/root/logs/btmon-hci7-20260918-120000.log"
sleep 1
: > "${workdir}/root/logs/btmon-hci7-20260918-120100.log"
out="$("${MENU}" --print hunt flipper)"
[[ "${out}" == *"--hunt flipper --from-capture "*"btmon-hci7-20260918-120100.log --iface hci8" ]] \
  || fail "name hunt did not resolve from the newest capture: ${out}"

out="$("${MENU}" --print scan "" aggressive)"
[[ "${out}" == *"ble-signature-scan.py --input "*"120100.log --profile aggressive" ]] || fail "scan malformed: ${out}"

out="$("${MENU}" --print fingerprint)"
[[ "${out}" == *"ble-fingerprint.py --input "*"120100.log" ]] || fail "fingerprint malformed: ${out}"

# --- Constrained arguments are validated before anything runs ------------------
"${MENU}" --print mode sideways > /dev/null 2>&1 && fail "mode accepted an invalid value"
"${MENU}" --print aio everything > /dev/null 2>&1 && fail "aio accepted an invalid value"
"${MENU}" --print nonsense > /dev/null 2>&1 && fail "unknown action did not fail"
out="$("${MENU}" --print aio restore)"
[[ "${out}" == *"aio-feature-profile.sh restore" ]] || fail "aio malformed: ${out}"

# --- The live action appears only when the script exists ----------------------
if [[ -x "${ROOT_DIR}/scripts/ble-live-watch.sh" ]]; then
  out="$("${MENU}" --print live)"
  [[ "${out}" == *"ble-live-watch.sh hci7 0 balanced" ]] || fail "live malformed: ${out}"
else
  if "${MENU}" --print live > /dev/null 2>&1; then
    fail "live should refuse when scripts/ble-live-watch.sh is absent"
  fi
fi

# --- --run executes exactly what --print shows ---------------------------------
rm -f "${workdir}/root/config/interfaces.conf" "${workdir}/root/config/signatures.conf"
"${MENU}" --run setup > "${workdir}/run.txt"
grep -q '^+ cp -n' "${workdir}/run.txt" || fail "--run did not echo the command before running it"
[[ -f "${workdir}/root/config/interfaces.conf" ]] || fail "--run setup did not create interfaces.conf"
[[ -f "${workdir}/root/config/signatures.conf" ]] || fail "--run setup did not create signatures.conf"

# --- shell quoting: what is shown is what runs ---------------------------------
# A capture path with a space must survive %q quoting on the way to eval.
mkdir -p "${workdir}/root/logs/with space"
: > "${workdir}/root/logs/with space/x.log"
out="$("${MENU}" --print fingerprint "${workdir}/root/logs/with space/x.log")"
[[ "${out}" == *'with\ space/x.log' ]] || fail "path with a space was not quoted: ${out}"

echo "Field menu test passed."
