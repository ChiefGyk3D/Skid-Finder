#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/logs"
mkdir -p "${LOG_DIR}"

REPORT="${LOG_DIR}/toolkit-validation-$(date +%Y%m%d-%H%M%S).txt"

pass_count=0
warn_count=0
fail_count=0

log() {
  printf '%s\n' "$1" | tee -a "${REPORT}"
}

record_pass() {
  pass_count=$((pass_count + 1))
  log "PASS: $1"
}

record_warn() {
  warn_count=$((warn_count + 1))
  log "WARN: $1"
}

record_fail() {
  fail_count=$((fail_count + 1))
  log "FAIL: $1"
}

check_file() {
  local path="$1"
  if [[ -f "${ROOT_DIR}/${path}" ]]; then
    record_pass "Found ${path}"
  else
    record_fail "Missing ${path}"
  fi
}

check_optional_file() {
  local path="$1"
  local hint="$2"
  if [[ -f "${ROOT_DIR}/${path}" ]]; then
    record_pass "Found ${path}"
  else
    record_warn "Missing ${path} (${hint})"
  fi
}

check_shell_syntax() {
  local script="$1"
  local target="${ROOT_DIR}/${script}"
  local output=""

  # Report these separately. Previously every one of them surfaced as
  # "Syntax error", with the real message discarded, so a stale checkout, a
  # permissions problem and genuinely broken code were indistinguishable.
  if [[ ! -e "${target}" ]]; then
    record_fail "Missing file: ${script} (checkout may be incomplete or stale)"
    return
  fi
  if [[ ! -r "${target}" ]]; then
    record_fail "Not readable: ${script} ($(ls -ld "${target}" | awk '{print $1, $3, $4}'))"
    return
  fi

  if [[ "${script}" == *.py ]]; then
    # Compile in memory rather than with py_compile, which writes __pycache__.
    # Much of this toolkit must run under sudo, and one sudo run leaves
    # __pycache__ owned by root; every later check as a normal user then fails
    # with EACCES on a perfectly valid file.
    if output="$(python3 -c 'import sys
path = sys.argv[1]
try:
    with open(path, "rb") as handle:
        compile(handle.read(), path, "exec")
except SyntaxError as exc:
    sys.exit("line %s: %s" % (exc.lineno, exc.msg))
except OSError as exc:
    sys.exit("cannot read: %s" % exc)' "${target}" 2>&1)"; then
      record_pass "Syntax OK: ${script}"
    else
      record_fail "Syntax error: ${script}"
      log "       ${output}"
    fi
  elif output="$(bash -n "${target}" 2>&1)"; then
    record_pass "Syntax OK: ${script}"
  else
    record_fail "Syntax error: ${script}"
    log "       ${output}"
  fi
}

{
  echo "Skid Finder Toolkit Validation"
  echo "generated_at=$(date -Is)"
  echo

  check_file "README.md"
  check_file "TROUBLESHOOTING.md"
  check_file "LICENSE"
  check_file "config/interfaces.conf.example"
  check_file "config/aio-features.conf.example"
  check_file "config/signatures.conf.example"
  check_optional_file "config/interfaces.conf" "copy from config/interfaces.conf.example"
  check_optional_file "config/signatures.conf" "copy from config/signatures.conf.example"
  check_file "tests/test-ble-signature-tuning.sh"
  check_file "tests/test-ble-signatures.sh"
  check_file "tests/test-ble-fingerprint.sh"
  check_file "tests/test-capture-resilience.sh"
  check_file "tests/test-le-scan-enable.sh"
  check_file "tests/test-config-parsing.sh"
  check_file "tests/make-fixture.py"
  check_file "tests/test-detector-metrics.py"
  check_file "tests/test-ble-observe.sh"
  check_file "tests/corpus/manifest.jsonl"
  check_file "tests/test-toolkit.sh"

  for script in \
    scripts/lib.sh \
    scripts/detect-hci.sh \
    scripts/setup-linux.sh \
    scripts/ble_parse.py \
    scripts/ble_identity.py \
    scripts/ble_signatures.py \
    scripts/ble-fingerprint.py \
    scripts/ble-signature-scan.py \
    scripts/ble-observe.py \
    scripts/ble-live-alert.py \
    scripts/ble-spam-watch.sh \
    scripts/capture-btmon.sh \
    scripts/foxhunt-rssi.sh \
    scripts/recover-hci.sh \
    scripts/ble-field-run.sh \
    scripts/aio-feature-profile.sh \
    scripts/set-adapter-mode.sh \
    scripts/add-corpus-sample.sh \
    scripts/troubleshoot-bluetooth.sh \
    scripts/diagnose-mediatek-ac1200.sh \
    scripts/validate-toolkit.sh; do
    check_shell_syntax "${script}"
  done

  check_shell_syntax "tests/test-detector-metrics.py"

  if command -v python3 >/dev/null 2>&1; then
    record_pass "python3 available"
  else
    record_warn "python3 not available; GPS merge helper may be unavailable"
  fi

  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck_failed=0
    for script in "${ROOT_DIR}"/scripts/*.sh "${ROOT_DIR}"/tests/*.sh; do
      [[ -f "${script}" ]] || continue
      if ! shellcheck -S warning -x "${script}" >/dev/null 2>&1; then
        record_warn "shellcheck findings in ${script#"${ROOT_DIR}"/}"
        shellcheck_failed=1
      fi
    done
    if (( shellcheck_failed == 0 )); then
      record_pass "shellcheck clean at warning severity"
    fi
  else
    record_warn "shellcheck not installed; static analysis skipped"
  fi

  if command -v ruff >/dev/null 2>&1; then
    if ruff check "${ROOT_DIR}"/scripts/*.py "${ROOT_DIR}"/tests/*.py >/dev/null 2>&1; then
      record_pass "ruff clean (ruff.toml ruleset)"
    else
      record_warn "ruff findings in Python (run: ruff check scripts/*.py tests/*.py)"
    fi
  else
    record_warn "ruff not installed; Python static analysis skipped"
  fi

  echo
  echo "Summary: ${pass_count} passed, ${warn_count} warnings, ${fail_count} failed"
  echo "Validation complete"
} > "${REPORT}"

cat "${REPORT}"

if (( fail_count > 0 )); then
  exit 1
fi
