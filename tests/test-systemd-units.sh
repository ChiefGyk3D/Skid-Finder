#!/usr/bin/env bash
set -euo pipefail

# The fixed-sensor units must parse cleanly, name the scripts that exist,
# and the retention sweep must delete exactly the personal-data files that
# are old enough and nothing else.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Units --------------------------------------------------------------------------
for unit in skid-finder-sensor@.service skid-finder-collector.service \
            skid-finder-retention.service skid-finder-retention.timer; do
  [[ -f "${ROOT_DIR}/systemd/${unit}" ]] || fail "missing systemd/${unit}"
done
for script in ble-live-watch.sh ble-collector.py retention-sweep.sh; do
  grep -q "${script}" "${ROOT_DIR}"/systemd/*.service || fail "no unit references scripts/${script}"
  [[ -x "${ROOT_DIR}/scripts/${script}" ]] || fail "scripts/${script} referenced by a unit is missing or not executable"
done
grep -q 'incidents-out' "${ROOT_DIR}/systemd/skid-finder-collector.service" || fail "collector unit does not write incidents"
if grep -qE 'MQTT_PASSWORD=' "${ROOT_DIR}"/systemd/*; then fail "a unit carries a password"; fi

if command -v systemd-analyze >/dev/null 2>&1; then
  for unit in "${ROOT_DIR}"/systemd/*.service "${ROOT_DIR}"/systemd/*.timer; do
    # verify complains about units it cannot load for dependencies on this
    # host; only syntax and escape warnings about our own file count.
    if systemd-analyze verify "${unit}" 2>&1 | grep -E "$(basename "${unit}"):[0-9]+:" ; then
      fail "systemd-analyze reports a problem in $(basename "${unit}")"
    fi
  done
  echo "systemd-analyze verify: clean"
else
  echo "systemd-analyze not available; unit syntax not verified here"
fi

# --- Retention sweep ------------------------------------------------------------------
logs="${TMP}/logs"; mkdir -p "${logs}"
old="$(date -d '10 days ago' +%Y%m%d%H%M)"
for f in obs-hci0-old.jsonl wifi-obs-wlan1-old.jsonl btmon-hci0-old.log btmon-hci0-old.btsnoop wifi-wlan1-old.pcapng wifi-wlan1-old.tsv \
         alerts-hci0-old.jsonl wifi-alerts-wlan1-old.jsonl summary-hci0-old.txt fleet-state.json fleet-incidents.jsonl sightings.json; do
  : > "${logs}/${f}"; touch -t "${old}" "${logs}/${f}"
done
: > "${logs}/obs-hci0-new.jsonl"   # today: must survive

"${ROOT_DIR}/scripts/retention-sweep.sh" --dry-run "${logs}" 3 > "${TMP}/dry.txt"
[[ -f "${logs}/obs-hci0-old.jsonl" ]] || fail "--dry-run deleted a file"
grep -q 'obs-hci0-old.jsonl' "${TMP}/dry.txt" || fail "--dry-run did not list the old observation file"

"${ROOT_DIR}/scripts/retention-sweep.sh" "${logs}" 3 > /dev/null
for gone in obs-hci0-old.jsonl wifi-obs-wlan1-old.jsonl btmon-hci0-old.log btmon-hci0-old.btsnoop wifi-wlan1-old.pcapng wifi-wlan1-old.tsv; do
  [[ ! -e "${logs}/${gone}" ]] || fail "${gone} should have been deleted"
done
for kept in alerts-hci0-old.jsonl wifi-alerts-wlan1-old.jsonl summary-hci0-old.txt fleet-state.json fleet-incidents.jsonl sightings.json obs-hci0-new.jsonl; do
  [[ -e "${logs}/${kept}" ]] || fail "${kept} must be kept"
done
"${ROOT_DIR}/scripts/retention-sweep.sh" "${logs}" abc > /dev/null 2>&1 && fail "non-numeric keep-days accepted"
"${ROOT_DIR}/scripts/retention-sweep.sh" "${TMP}/nope" 3 > /dev/null 2>&1 && fail "missing logs dir accepted"

echo "systemd units test passed."
