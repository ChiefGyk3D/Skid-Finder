#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

SCAN="${ROOT_DIR}/scripts/ble-signature-scan.py"
FIXTURE="${ROOT_DIR}/tests/make-fixture.py"

# A low-volume Apple lure burst. The rate is deliberately placed between the
# shipped conservative threshold (3.0/s) and the tuned one below (2.0/s), so
# this test measures the config override and nothing else.
python3 "${FIXTURE}" --mode spam --duration 20 --rate 2.5 --output "${TMP_DIR}/weak.log"

# Explicit empty config: without it the scanner would fall back to the
# operator's untracked config/signatures.conf and the result would vary by
# machine.
NO_CONF="${TMP_DIR}/empty.conf"
: > "${NO_CONF}"

python3 "${SCAN}" --input "${TMP_DIR}/weak.log" --profile conservative --config "${NO_CONF}" > "${TMP_DIR}/default.txt"
if grep -q 'MATCH Flipper-like Apple popup spam pattern' "${TMP_DIR}/default.txt"; then
  echo "FAIL: conservative profile matched a low-volume burst; thresholds too loose." >&2
  cat "${TMP_DIR}/default.txt" >&2
  exit 1
fi

# Same capture, operator-lowered thresholds, should now match.
cat > "${TMP_DIR}/signatures.conf" <<'EOF'
[general]
profile = aggressive

[aggressive]
min_duration_sec = 5
flipper_min_apple_rate = 2.0
flipper_min_unique_addrs = 8
flipper_min_unique_ratio = 0.60
flipper_min_lure_hits = 4
enable_flipper = true
EOF

python3 "${SCAN}" --input "${TMP_DIR}/weak.log" --config "${TMP_DIR}/signatures.conf" \
  > "${TMP_DIR}/tuned.txt"

if ! grep -q 'MATCH Flipper-like Apple popup spam pattern' "${TMP_DIR}/tuned.txt"; then
  echo "FAIL: tuned config did not lower thresholds as expected." >&2
  cat "${TMP_DIR}/tuned.txt" >&2
  exit 1
fi

# The summary must report where its thresholds came from, otherwise a silently
# ignored config file looks identical to a working one.
grep -q "config_source=${TMP_DIR}/signatures.conf" "${TMP_DIR}/tuned.txt"

# Disabling a rule must actually disable it.
cat > "${TMP_DIR}/disabled.conf" <<'EOF'
[general]
profile = aggressive

[aggressive]
min_duration_sec = 5
flipper_min_apple_rate = 2.0
flipper_min_unique_addrs = 8
flipper_min_unique_ratio = 0.60
flipper_min_lure_hits = 4
enable_flipper = false
EOF

python3 "${SCAN}" --input "${TMP_DIR}/weak.log" --config "${TMP_DIR}/disabled.conf" \
  > "${TMP_DIR}/disabled.txt"
if grep -q 'MATCH Flipper-like Apple popup spam pattern' "${TMP_DIR}/disabled.txt"; then
  echo "FAIL: enable_flipper=false did not disable the rule." >&2
  exit 1
fi

# A key the scanner does not recognise must be reported. The shipped example
# config once drifted out of sync with the scanner's keys: 73 keys were
# defined, 2 applied, and config_source still named the file, so a config that
# did nothing looked exactly like one that worked.
cat > "${TMP_DIR}/stale.conf" <<'EOF'
[general]
profile = balanced

[balanced]
flipper_min_apple_mfg_events = 20
marauder_min_events = 80
flipper_min_unique_addrs = 9
EOF

python3 "${SCAN}" --input "${TMP_DIR}/weak.log" --config "${TMP_DIR}/stale.conf" \
  > "${TMP_DIR}/stale.txt" 2> "${TMP_DIR}/stale.err"

for key in flipper_min_apple_mfg_events marauder_min_events; do
  if ! grep -q "${key}" "${TMP_DIR}/stale.err"; then
    echo "FAIL: unrecognised key ${key} was silently ignored." >&2
    cat "${TMP_DIR}/stale.err" >&2
    exit 1
  fi
done

# The valid key in that same file must still be applied, and the warning must
# not leak into stdout where it would corrupt the parsed summary.
if grep -qi 'warning' "${TMP_DIR}/stale.txt"; then
  echo "FAIL: config warning leaked into stdout." >&2
  exit 1
fi

# Every key in the shipped example must be one the scanner actually honours,
# for all three profiles. This is what drifted before.
python3 - "${ROOT_DIR}" <<'EOF'
import configparser, importlib.util, sys, os

root = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "sig", os.path.join(root, "scripts", "ble_signatures.py")
)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

parser = configparser.ConfigParser()
parser.read(os.path.join(root, "config", "signatures.conf.example"))

failed = False
for profile, defaults in mod.DEFAULT_RULES.items():
    if not parser.has_section(profile):
        print(f"FAIL: example config missing [{profile}] section", file=sys.stderr)
        failed = True
        continue
    keys = {k for k, _ in parser.items(profile)}
    unknown = keys - set(defaults)
    missing = set(defaults) - keys
    if unknown:
        print(f"FAIL: [{profile}] documents keys the scanner ignores: "
              f"{sorted(unknown)}", file=sys.stderr)
        failed = True
    if missing:
        print(f"FAIL: [{profile}] omits tunable keys: {sorted(missing)}",
              file=sys.stderr)
        failed = True

sys.exit(1 if failed else 0)
EOF

echo "BLE signature tuning test passed."
