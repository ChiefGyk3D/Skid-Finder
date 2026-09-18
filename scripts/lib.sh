#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONF_FILE="${ROOT_DIR}/config/interfaces.conf"

# Settings accepted from config/interfaces.conf. Anything else is ignored.
INTERFACES_CONF_KEYS=(
  ADAPTER_MODE
  PRIMARY_HCI
  SECONDARY_HCI
  CAPTURE_HCI
  HUNT_HCI
  SCAN_SECONDS
  ALERT_ADS_PER_ADDR
  SENSOR_ID
  SENSOR_LAT
  SENSOR_LON
)

_assign_conf_value() {
  local key="$1"
  local value="$2"

  # Take the contents of a quoted value and discard any trailing comment.
  # Unquoted values are truncated at the first '#'.
  if [[ "${value}" =~ ^\"([^\"]*)\" ]]; then
    value="${BASH_REMATCH[1]}"
  elif [[ "${value}" =~ ^\'([^\']*)\' ]]; then
    value="${BASH_REMATCH[1]}"
  else
    value="${value%%#*}"
    value="${value%"${value##*[![:space:]]}"}"
  fi

  printf -v "${key}" '%s' "${value}"
}

# Read a KEY=value config file without evaluating it.
#
# Using 'source' here would let anything in a config file run as root, since
# most of these scripts require sudo. This parser only assigns values for
# keys that are explicitly allowed, so config contents are treated as data.
#
# Usage: load_conf_file <file> <allowed_key>...
load_conf_file() {
  local file="$1"
  shift
  local allowed_keys=("$@")

  local lineno=0
  local line key value candidate matched

  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))

    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"

    [[ -z "${line}" || "${line}" == \#* ]] && continue

    if [[ ! "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
      echo "warn: ${file}:${lineno}: ignoring unparsable line." >&2
      continue
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"

    matched=0
    for candidate in "${allowed_keys[@]}"; do
      if [[ "${key}" == "${candidate}" ]]; then
        matched=1
        break
      fi
    done

    if (( matched == 0 )); then
      echo "warn: ${file}:${lineno}: ignoring unrecognized setting '${key}'." >&2
      continue
    fi

    _assign_conf_value "${key}" "${value}"
  done < "${file}"
}

# Fall back to a default when a setting that feeds timeout/awk is not numeric.
_require_positive_int() {
  local key="$1"
  local fallback="$2"
  local current="${!key:-}"

  if [[ ! "${current}" =~ ^[0-9]+$ ]] || (( current == 0 )); then
    echo "warn: ${key}='${current}' is not a positive integer; using ${fallback}." >&2
    printf -v "${key}" '%s' "${fallback}"
  fi
}

load_config() {
  if [[ ! -f "${CONF_FILE}" ]]; then
    echo "Missing ${CONF_FILE}. Copy interfaces.conf.example first." >&2
    exit 1
  fi

  load_conf_file "${CONF_FILE}" "${INTERFACES_CONF_KEYS[@]}"

  SCAN_SECONDS="${SCAN_SECONDS:-30}"
  ALERT_ADS_PER_ADDR="${ALERT_ADS_PER_ADDR:-40}"

  _require_positive_int SCAN_SECONDS 30
  _require_positive_int ALERT_ADS_PER_ADDR 40
}

need_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root (sudo)." >&2
    exit 1
  fi
}

hci_exists() {
  local iface="$1"
  hciconfig "${iface}" >/dev/null 2>&1
}

adapter_mode() {
  local mode="${ADAPTER_MODE:-dual}"
  case "${mode}" in
    dual|single|auto)
      printf "%s\n" "${mode}"
      ;;
    *)
      echo "Unknown ADAPTER_MODE='${mode}'. Supported: dual, single, auto. Falling back to dual." >&2
      printf "%s\n" "dual"
      ;;
  esac
}

ensure_hci() {
  local iface="$1"
  if ! hci_exists "${iface}"; then
    echo "Bluetooth interface ${iface} not found." >&2
    echo "Run scripts/detect-hci.sh to discover adapter names." >&2
    exit 1
  fi
}

pick_runtime_iface() {
  local preferred="$1"
  local fallback="$2"
  local context="$3"

  if [[ -n "${preferred}" ]] && hci_exists "${preferred}"; then
    printf "%s\n" "${preferred}"
    return 0
  fi

  if [[ -n "${fallback}" ]] && hci_exists "${fallback}"; then
    echo "${context}: preferred interface ${preferred} not available; falling back to ${fallback}." >&2
    printf "%s\n" "${fallback}"
    return 0
  fi

  echo "${context}: no usable Bluetooth interface found (preferred=${preferred}, fallback=${fallback})." >&2
  echo "Run scripts/detect-hci.sh and update config/interfaces.conf." >&2
  exit 1
}

default_capture_iface() {
  local preferred="${CAPTURE_HCI:-hci0}"
  local fallback="${PRIMARY_HCI:-hci0}"
  pick_runtime_iface "${preferred}" "${fallback}" "capture"
}

default_hunt_iface() {
  local mode
  mode="$(adapter_mode)"

  local preferred
  local fallback

  case "${mode}" in
    single)
      preferred="${HUNT_HCI:-${CAPTURE_HCI:-${PRIMARY_HCI:-hci0}}}"
      fallback="${CAPTURE_HCI:-${PRIMARY_HCI:-hci0}}"
      ;;
    auto)
      if hci_exists "${SECONDARY_HCI:-hci1}"; then
        preferred="${HUNT_HCI:-${SECONDARY_HCI:-hci1}}"
      else
        preferred="${HUNT_HCI:-${CAPTURE_HCI:-${PRIMARY_HCI:-hci0}}}"
      fi
      fallback="${CAPTURE_HCI:-${PRIMARY_HCI:-hci0}}"
      ;;
    dual|*)
      preferred="${HUNT_HCI:-${SECONDARY_HCI:-hci1}}"
      fallback="${CAPTURE_HCI:-${PRIMARY_HCI:-hci0}}"
      ;;
  esac

  pick_runtime_iface "${preferred}" "${fallback}" "hunt"
}

now_stamp() {
  date +"%Y%m%d-%H%M%S"
}

# btmon is a passive observer of the HCI channel. The controller only emits
# LE Advertising Report events while an LE scan is active, so captures taken
# on an idle adapter are almost empty. These helpers turn scanning on for the
# duration of a capture and reliably tear it down afterwards.
#
# Scanning is driven by bluetoothctl rather than 'btmgmt find'. btmgmt is a
# bt_shell program: backgrounded and detached from a terminal it blocks in its
# event loop and never issues the Start Discovery command, so the capture comes
# back empty. bluetoothctl is fed commands over a FIFO whose write end we hold
# open, which keeps its session alive for the whole capture and lets us pick a
# specific controller on dual-radio rigs.
LE_SCAN_PID=""
LE_SCAN_FIFO=""
LE_SCAN_FD=""

# Resolve the Bluetooth address of an hciN interface so bluetoothctl can
# 'select' it. Without this bluetoothctl uses whichever controller is default,
# which is wrong when capture and hunt radios are separate.
hci_address() {
  local iface="$1" addr=""

  if command -v btmgmt >/dev/null 2>&1; then
    addr="$(btmgmt -i "${iface}" info 2>/dev/null \
      | grep -oE 'addr ([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
      | head -n1 | awk '{print $2}')"
  fi

  if [[ -z "${addr}" ]] && command -v hciconfig >/dev/null 2>&1; then
    addr="$(hciconfig "${iface}" 2>/dev/null \
      | grep -oE 'BD Address: ([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' \
      | head -n1 | awk '{print $3}')"
  fi

  printf '%s' "${addr}"
}

start_le_scan() {
  local iface="$1"

  # Powering the radio and enabling LE are one-shot btmgmt commands; those work
  # fine non-interactively because they exit immediately.
  if command -v btmgmt >/dev/null 2>&1; then
    btmgmt -i "${iface}" power on >/dev/null 2>&1 || true
    btmgmt -i "${iface}" le on >/dev/null 2>&1 || true
  fi

  if ! command -v bluetoothctl >/dev/null 2>&1; then
    echo "warn: bluetoothctl not found; cannot enable LE scan automatically." >&2
    echo "warn: install bluez, or run 'bluetoothctl scan on' in another shell." >&2
    return 0
  fi

  LE_SCAN_FIFO="$(mktemp -u "${TMPDIR:-/tmp}/ble-scan-XXXXXX.fifo")"
  if ! mkfifo -m 600 "${LE_SCAN_FIFO}" 2>/dev/null; then
    echo "warn: could not create scan control FIFO; LE scan not started." >&2
    LE_SCAN_FIFO=""
    return 0
  fi

  bluetoothctl <"${LE_SCAN_FIFO}" >/dev/null 2>&1 &
  LE_SCAN_PID=$!

  # Hold the write end open for the lifetime of the scan. If we let it close,
  # bluetoothctl sees EOF, quits, and discovery stops with it.
  exec {LE_SCAN_FD}>"${LE_SCAN_FIFO}"

  local addr
  addr="$(hci_address "${iface}")"
  if [[ -n "${addr}" ]]; then
    printf 'select %s\n' "${addr}" >&"${LE_SCAN_FD}"
    sleep 1
  else
    echo "warn: could not resolve address for ${iface}; using default controller." >&2
  fi

  printf 'scan on\n' >&"${LE_SCAN_FD}"

  # Give the controller a moment to actually start scanning before capturing.
  sleep 2
}

stop_le_scan() {
  local iface="${1:-}"

  if [[ -n "${LE_SCAN_FD}" ]]; then
    printf 'scan off\n' >&"${LE_SCAN_FD}" || true
    printf 'quit\n' >&"${LE_SCAN_FD}" || true
    # No '2>/dev/null' here. 'exec' with only redirections and no command
    # applies them to the current shell permanently, so that would silence the
    # caller's stderr for the rest of the run.
    exec {LE_SCAN_FD}>&- || true
    LE_SCAN_FD=""
  fi

  if [[ -n "${LE_SCAN_PID}" ]]; then
    # bluetoothctl exits on 'quit'; kill only if it lingers.
    local waited=0
    while kill -0 "${LE_SCAN_PID}" 2>/dev/null && (( waited < 3 )); do
      sleep 1
      waited=$((waited + 1))
    done
    kill "${LE_SCAN_PID}" 2>/dev/null || true
    wait "${LE_SCAN_PID}" 2>/dev/null || true
    LE_SCAN_PID=""
  fi

  if [[ -n "${LE_SCAN_FIFO}" ]]; then
    rm -f "${LE_SCAN_FIFO}" 2>/dev/null || true
    LE_SCAN_FIFO=""
  fi

  if [[ -n "${iface}" ]] && command -v btmgmt >/dev/null 2>&1; then
    btmgmt -i "${iface}" stop-find >/dev/null 2>&1 || true
  fi
}

# Capture btmon output for a bounded duration.
#
# 'timeout' exits 124 when it stops the command, and under 'set -o pipefail'
# plus 'set -e' that status would abort the calling script before any analysis
# stage could run. Absorb the expected statuses here so callers keep going.
#
# When a btsnoop path is given, btmon also writes a compact binary trace that
# can be replayed with 'btmon -r <file>' or summarized with 'btmon -a <file>'.
# That format is much smaller than the text log and is the better artifact to
# hand to venue SOC/NOC staff.
#
# Usage: run_btmon_capture <iface> <duration> <outfile> [quiet|tee] [btsnoop]
run_btmon_capture() {
  local iface="$1"
  local duration="$2"
  local outfile="$3"
  local mode="${4:-quiet}"
  local btsnoop="${5:-}"
  local rc=0

  local btmon_args=(-i "${iface}")
  if [[ -n "${btsnoop}" ]]; then
    btmon_args+=(-w "${btsnoop}")
  fi

  if [[ "${mode}" == "tee" ]]; then
    timeout "${duration}" stdbuf -oL btmon "${btmon_args[@]}" 2>/dev/null | tee "${outfile}" || rc=$?
  else
    timeout "${duration}" stdbuf -oL btmon "${btmon_args[@]}" >"${outfile}" 2>/dev/null || rc=$?
  fi

  case "${rc}" in
    0|124|143)
      # 0 = clean exit, 124 = timeout reached (expected), 143 = SIGTERM.
      :
      ;;
    *)
      echo "warn: btmon capture on ${iface} exited with status ${rc}." >&2
      echo "warn: results may be incomplete. See TROUBLESHOOTING.md." >&2
      ;;
  esac

  return 0
}

# Warn when a capture produced no usable advertising data, so an empty result
# is reported as a problem instead of looking like a quiet RF environment.
warn_if_capture_empty() {
  local logfile="$1"

  if [[ ! -s "${logfile}" ]]; then
    echo "warn: capture file is empty. The adapter may not be scanning." >&2
    return 0
  fi

  if ! grep -q "Address:" "${logfile}" 2>/dev/null; then
    echo "warn: capture contains no advertising reports." >&2
    echo "warn: check that LE scan is enabled and the adapter is up (see TROUBLESHOOTING.md)." >&2
  fi
}

CAPTURE_PROGRESS_PID=""

# Report capture progress while btmon runs into a file.
#
# A quiet capture is indistinguishable from a hung one: the default field run
# is five minutes, during which the screen would not change at all. Worse, a
# capture that is silently recording nothing, which is the failure this toolkit
# has hit before, looked exactly like one that was working.
#
# Reads the growing capture file rather than tapping the stream, so it costs
# the capture nothing and cannot interfere with it. The trade-off is that btmon
# flushes to that file in blocks, so the running counts lag behind reality and
# jump in steps. They are a liveness indicator, not a measurement; the summary
# at the end is the authoritative count.
#
# Usage: start_capture_progress <logfile> <duration> [interval]
start_capture_progress() {
  local logfile="$1"
  local duration="$2"
  local interval="${3:-10}"

  (
    local elapsed=0
    local events=0
    local addrs=0
    local reported_silence=0

    while (( elapsed < duration )); do
      sleep "${interval}"
      elapsed=$(( elapsed + interval ))
      (( elapsed > duration )) && elapsed="${duration}"

      events=0
      addrs=0
      if [[ -s "${logfile}" ]]; then
        # Only '>' blocks are real HCI events. '@' MGMT lines echo the same
        # advert and would roughly double the count.
        read -r events addrs <<<"$(awk '
          /^> / { ev++ }
          /Address:/ {
            a = $2
            gsub(",", "", a)
            if (a ~ /([0-9A-F]{2}:){5}[0-9A-F]{2}/) { seen[a] = 1 }
          }
          END {
            n = 0
            for (k in seen) { n++ }
            printf "%d %d\n", ev + 0, n
          }
        ' "${logfile}" 2>/dev/null)"
      fi

      printf 'capturing %ss/%ss  events=%s  unique_addrs=%s\n' \
        "${elapsed}" "${duration}" "${events:-0}" "${addrs:-0}"

      # Say so early rather than after a five minute wait.
      if (( events == 0 && reported_silence == 0 && elapsed >= interval * 2 )); then
        reported_silence=1
        echo "  note: nothing captured yet. If this stays at zero the adapter" >&2
        echo "  is probably not scanning; see TROUBLESHOOTING.md." >&2
      fi
    done
  ) &

  CAPTURE_PROGRESS_PID=$!
}

stop_capture_progress() {
  [[ -n "${CAPTURE_PROGRESS_PID}" ]] || return 0
  kill "${CAPTURE_PROGRESS_PID}" 2>/dev/null || true
  wait "${CAPTURE_PROGRESS_PID}" 2>/dev/null || true
  CAPTURE_PROGRESS_PID=""
}

# Live pipeline: btmon -> ble-observe.py --stream -> ble-live-alert.py.
#
# The documented "sudo btmon | ble-observe | ble-live-alert" one-liner has two
# field failures that this helper exists to remove. First, btmon alone records
# nothing on an idle adapter, exactly as for the batch captures, so the caller
# must hold an LE scan open around it. Second, btmon block-buffers its stdout
# when it is a pipe, so in a quiet room an alert could sit in a 4 KB buffer
# for minutes; 'stdbuf -oL' makes every advert reach the detector as it lands.
#
# The normalized stream is tee'd to <obs_out> so the run leaves a machine-
# readable artifact (one JSON object per advert) beside the btsnoop trace.
# Pass /dev/null to discard it. A <duration> of 0 runs until interrupted.
#
# Usage: run_live_pipeline <iface> <duration> <trace|""> <obs_out> \
#            [observe args...] -- [alert args...]
run_live_pipeline() {
  local iface="$1"
  local duration="$2"
  local trace="$3"
  local obs_out="$4"
  shift 4

  local observe_args=()
  local alert_args=()
  local phase=0
  while (( $# )); do
    if [[ "$1" == "--" ]]; then
      phase=1
      shift
      continue
    fi
    if (( phase == 0 )); then
      observe_args+=("$1")
    else
      alert_args+=("$1")
    fi
    shift
  done

  local cmd=()
  if (( duration > 0 )); then
    cmd+=(timeout "${duration}")
  fi
  cmd+=(stdbuf -oL btmon -i "${iface}")
  if [[ -n "${trace}" ]]; then
    cmd+=(-w "${trace}")
  fi

  local rc=0
  "${cmd[@]}" 2>/dev/null \
    | python3 "${ROOT_DIR}/scripts/ble-observe.py" --stream "${observe_args[@]}" \
    | tee "${obs_out}" \
    | python3 "${ROOT_DIR}/scripts/ble-live-alert.py" "${alert_args[@]}" || rc=$?

  case "${rc}" in
    0|124|130|143)
      # 0 = clean exit, 124 = timeout reached, 130 = Ctrl+C, 143 = SIGTERM.
      :
      ;;
    *)
      echo "warn: live pipeline on ${iface} exited with status ${rc}." >&2
      echo "warn: results may be incomplete. See TROUBLESHOOTING.md." >&2
      ;;
  esac

  return 0
}
