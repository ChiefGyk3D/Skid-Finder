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
  MQTT_HOST
  MQTT_PORT
  MQTT_TLS
  MQTT_TOPIC_PREFIX
  WIFI_IFACE
  WIFI_CHANNELS
  WIFI_DWELL_MS
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

# --- Capturing without root ------------------------------------------------------
#
# btmon needs CAP_NET_RAW to open the HCI monitor channel, so the capture
# scripts historically required sudo. A laptop or desktop has another way:
# Wireshark's dumpcap carries that capability for members of the 'wireshark'
# group and exposes the same channel as the 'bluetooth-monitor' interface.
# tshark can record it to pcapng, editcap can rewrite that as btsnoop, and
# btmon can render btsnoop as the text every analysis tool here reads. None
# of that needs root. The trade-offs: the text log only exists once the
# capture ends (so progress counts cannot be shown live), and the monitor
# channel carries every adapter rather than one, which on a single-adapter
# machine changes nothing.
#
# The live path (ble-live-watch.sh) still needs root: it streams btmon text
# as it happens, which the pcapng round trip cannot do.
CAPTURE_MODE="root"

unprivileged_capture_available() {
  command -v tshark >/dev/null 2>&1 || return 1
  command -v editcap >/dev/null 2>&1 || return 1
  command -v btmon >/dev/null 2>&1 || return 1
  tshark -D 2>/dev/null | grep -q 'bluetooth-monitor'
}

# Root, or the unprivileged path above. Exits with the fix otherwise.
need_capture_privileges() {
  if [[ "${EUID}" -eq 0 ]]; then
    CAPTURE_MODE="root"
    return 0
  fi
  if unprivileged_capture_available; then
    CAPTURE_MODE="unprivileged"
    echo "note: not root; capturing through tshark's bluetooth-monitor interface (wireshark group)." >&2
    return 0
  fi
  echo "Run as root (sudo)." >&2
  echo "Or, on a laptop, capture without root: install tshark, add yourself to the" >&2
  echo "'wireshark' group (sudo usermod -aG wireshark \$USER, then log in again) and" >&2
  echo "confirm 'tshark -D' lists bluetooth-monitor. See TROUBLESHOOTING.md." >&2
  exit 1
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

  if [[ "${CAPTURE_MODE}" == "unprivileged" ]]; then
    run_unprivileged_capture "${duration}" "${outfile}" "${mode}" "${btsnoop}"
    return 0
  fi

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

# The unprivileged capture: tshark records the monitor channel to pcapng,
# editcap rewrites it as btsnoop, btmon renders the text. The btsnoop is kept
# when a path is given (it is the same artifact the root path writes), else
# it lives only long enough to be rendered.
run_unprivileged_capture() {
  local duration="$1"
  local outfile="$2"
  local mode="${3:-quiet}"
  local btsnoop="${4:-}"
  local rc=0

  echo "note: the text log is rendered when the capture ends, so running counts are not shown." >&2
  local pcap
  pcap="$(mktemp "${TMPDIR:-/tmp}/ble-capture-XXXXXX.pcapng")"
  local keep_snoop="${btsnoop}"
  if [[ -z "${keep_snoop}" ]]; then
    keep_snoop="$(mktemp "${TMPDIR:-/tmp}/ble-capture-XXXXXX.btsnoop")"
  fi

  tshark -i bluetooth-monitor -a "duration:${duration}" -q -w "${pcap}" 2>/dev/null || rc=$?
  case "${rc}" in
    0|124|130|143) ;;
    *)
      echo "warn: tshark capture exited with status ${rc}; results may be incomplete." >&2
      ;;
  esac

  if [[ -s "${pcap}" ]] && editcap -F btsnoop "${pcap}" "${keep_snoop}" 2>/dev/null; then
    if [[ "${mode}" == "tee" ]]; then
      btmon -r "${keep_snoop}" 2>/dev/null | tee "${outfile}"
    else
      btmon -r "${keep_snoop}" >"${outfile}" 2>/dev/null
    fi
  else
    : >"${outfile}"
    echo "warn: the unprivileged capture produced nothing to render." >&2
  fi

  rm -f "${pcap}"
  if [[ -z "${btsnoop}" ]]; then
    rm -f "${keep_snoop}"
  fi
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

      # Without root the text log is rendered after the capture, so there is
      # nothing to count yet and silence is not a fault.
      if [[ "${CAPTURE_MODE}" == "unprivileged" ]]; then
        printf 'capturing %ss/%ss  (unprivileged: counts appear when the capture ends)\n' \
          "${elapsed}" "${duration}"
        continue
      fi

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
# tshark field list for the unprivileged live path. Keep in step with
# scripts/ble_parse.py TSHARK_FIELDS and TSHARK_FILTER.
BLE_TSHARK_FIELDS=(
  -e frame.time_epoch
  -e bthci_evt.le_meta_subevent
  -e bthci_evt.bd_addr
  -e bthci_evt.le_peer_address_type
  -e bthci_evt.rssi
  -e btcommon.eir_ad.entry.device_name
  -e btcommon.eir_ad.entry.company_id
  -e btcommon.eir_ad.entry.uuid_16
  -e btcommon.eir_ad.entry.type
  -e bthci_evt.le_ext_advts_event_type
  -e bthci_evt.le_advts_event_type
  -e bthci_evt.data_length
)
BLE_TSHARK_FILTER="bthci_evt.le_meta_subevent == 0x02 || bthci_evt.le_meta_subevent == 0x0d"

# Trace writer for the unprivileged live path: a second tshark on the same
# monitor channel writing pcapng, converted to btsnoop when stopped.
UNPRIV_TRACE_PID=""
UNPRIV_TRACE_PCAP=""

start_unprivileged_trace() {
  local btsnoop="$1"
  UNPRIV_TRACE_PCAP="${btsnoop%.btsnoop}.pcapng"
  tshark -i bluetooth-monitor -q -w "${UNPRIV_TRACE_PCAP}" >/dev/null 2>&1 &
  UNPRIV_TRACE_PID=$!
}

stop_unprivileged_trace() {
  local btsnoop="$1"
  if [[ -n "${UNPRIV_TRACE_PID}" ]]; then
    # TERM, not INT: a job started in the background from a non-interactive
    # shell has INT ignored, and tshark finalises the file on TERM as well.
    kill "${UNPRIV_TRACE_PID}" 2>/dev/null || true
    wait "${UNPRIV_TRACE_PID}" 2>/dev/null || true
    UNPRIV_TRACE_PID=""
  fi
  if [[ -n "${UNPRIV_TRACE_PCAP}" && -s "${UNPRIV_TRACE_PCAP}" ]]; then
    if editcap -F btsnoop "${UNPRIV_TRACE_PCAP}" "${btsnoop}" 2>/dev/null; then
      rm -f "${UNPRIV_TRACE_PCAP}"
    else
      echo "note: trace kept as pcapng at ${UNPRIV_TRACE_PCAP} (editcap could not convert it)." >&2
    fi
  fi
  UNPRIV_TRACE_PCAP=""
}

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
  local format="btmon"
  if [[ "${CAPTURE_MODE}" == "unprivileged" ]]; then
    # Without root, tshark streams the same advertising reports as fields,
    # one line per report (-l flushes per packet). A live tshark refuses a
    # display filter together with -w, so the trace is not written here;
    # the caller runs a second tshark for it (start_unprivileged_trace).
    format="tshark"
    cmd+=(tshark -i bluetooth-monitor -l -Y "${BLE_TSHARK_FILTER}" -T fields "${BLE_TSHARK_FIELDS[@]}"
          -E separator=/t -E occurrence=a -E 'aggregator=,')
  else
    cmd+=(stdbuf -oL btmon -i "${iface}")
    if [[ -n "${trace}" ]]; then
      cmd+=(-w "${trace}")
    fi
  fi

  local rc=0
  "${cmd[@]}" 2>/dev/null \
    | python3 "${ROOT_DIR}/scripts/ble-observe.py" --stream --format "${format}" "${observe_args[@]}" \
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

# --- Wi-Fi monitor mode -----------------------------------------------------------
#
# Passive only. Monitor mode listens; nothing below transmits. The interface
# state is recorded so it can be put back the way it was found: managed
# mode, and returned to NetworkManager if NetworkManager had it.
#
# tshark field list. Keep in step with scripts/wifi_parse.py FIELDS.
WIFI_TSHARK_FIELDS=(
  -e frame.time_epoch
  -e wlan.fc.type_subtype
  -e wlan.sa
  -e wlan.da
  -e wlan.bssid
  -e wlan.ssid
  -e wlan_radio.signal_dbm
  -e wlan_radio.channel
  -e wlan.fixed.reason_code
)
# Management frames only (type 0); data frames carry people's traffic and the
# detector does not need them.
WIFI_TSHARK_FILTER="wlan.fc.type == 0"

WIFI_NM_MANAGED=""
CHANNEL_HOP_PID=""

wifi_monitor_on() {
  local iface="$1"
  WIFI_NM_MANAGED=""
  if command -v nmcli >/dev/null 2>&1; then
    if nmcli -t -f GENERAL.STATE device show "${iface}" >/dev/null 2>&1; then
      WIFI_NM_MANAGED="yes"
      nmcli device set "${iface}" managed no >/dev/null 2>&1 || true
    fi
  fi
  ip link set "${iface}" down 2>/dev/null || true
  if ! iw dev "${iface}" set type monitor 2>/dev/null; then
    echo "warn: could not put ${iface} into monitor mode; the adapter or driver may not support it." >&2
    echo "warn: see TROUBLESHOOTING.md (Wi-Fi monitor mode)." >&2
  fi
  ip link set "${iface}" up 2>/dev/null || true
}

wifi_monitor_off() {
  local iface="$1"
  ip link set "${iface}" down 2>/dev/null || true
  iw dev "${iface}" set type managed 2>/dev/null || true
  ip link set "${iface}" up 2>/dev/null || true
  if [[ "${WIFI_NM_MANAGED}" == "yes" ]] && command -v nmcli >/dev/null 2>&1; then
    nmcli device set "${iface}" managed yes >/dev/null 2>&1 || true
  fi
  WIFI_NM_MANAGED=""
}

# Hop the interface across channels in the background. A single channel sees
# one sixth of the 2.4 GHz floor; hopping trades per-channel completeness for
# coverage, which is the right trade for detection.
start_channel_hop() {
  local iface="$1"
  local channels="${2:-1 6 11}"
  local dwell_ms="${3:-250}"
  local dwell
  dwell="$(awk -v ms="${dwell_ms}" 'BEGIN { printf "%.3f", ms / 1000 }')"
  (
    while :; do
      for ch in ${channels}; do
        iw dev "${iface}" set channel "${ch}" >/dev/null 2>&1 || true
        sleep "${dwell}"
      done
    done
  ) &
  CHANNEL_HOP_PID=$!
}

stop_channel_hop() {
  [[ -n "${CHANNEL_HOP_PID}" ]] || return 0
  kill "${CHANNEL_HOP_PID}" 2>/dev/null || true
  wait "${CHANNEL_HOP_PID}" 2>/dev/null || true
  CHANNEL_HOP_PID=""
}

# Field extract from a saved capture, in the detector's format.
wifi_fields_from_pcap() {
  local pcap="$1"
  tshark -r "${pcap}" -Y "${WIFI_TSHARK_FILTER}" -T fields "${WIFI_TSHARK_FIELDS[@]}" \
    -E separator=/t -E occurrence=f 2>/dev/null
}

# Live pipeline: tshark -> wifi-observe.py --stream -> wifi-live-alert.py.
# Usage: run_wifi_live_pipeline <iface> <duration> <obs_out> [observe args...] -- [alert args...]
run_wifi_live_pipeline() {
  local iface="$1"
  local duration="$2"
  local obs_out="$3"
  shift 3

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
  # -l flushes per packet, the tshark equivalent of stdbuf -oL.
  cmd+=(tshark -i "${iface}" -l -Y "${WIFI_TSHARK_FILTER}" -T fields "${WIFI_TSHARK_FIELDS[@]}"
        -E separator=/t -E occurrence=f)

  local rc=0
  "${cmd[@]}" 2>/dev/null \
    | python3 "${ROOT_DIR}/scripts/wifi-observe.py" --stream "${observe_args[@]}" \
    | tee "${obs_out}" \
    | python3 "${ROOT_DIR}/scripts/wifi-live-alert.py" "${alert_args[@]}" || rc=$?

  case "${rc}" in
    0|124|130|143) ;;
    *)
      echo "warn: Wi-Fi live pipeline on ${iface} exited with status ${rc}." >&2
      ;;
  esac
  return 0
}
