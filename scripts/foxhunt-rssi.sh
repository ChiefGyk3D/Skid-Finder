#!/usr/bin/env bash
set -euo pipefail

# Walk-in RSSI tracker.
#
# Tracks one or more target addresses and reports a rolling median RSSI, which
# is what you actually walk in on. Instantaneous RSSI is far too noisy to
# navigate by, especially indoors where multipath swings readings by 20 dB.
#
# Multiple targets matter because most devices rotate their address. Resolve a
# target to its current address set with ble-fingerprint.py, then track them
# all at once:
#
#   sudo ./scripts/foxhunt-rssi.sh --hunt "WHOOP" --from-capture logs/cap.log
#
# Read the tier warning that ble-fingerprint.py prints. If the target resolved
# at 'model' or 'ambiguous' tier, the address set may span several different
# devices and the RSSI trend will jump between them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  cat >&2 <<'EOF'
Usage:
  sudo foxhunt-rssi.sh <TARGET_MAC> [HCI_IFACE]
  sudo foxhunt-rssi.sh --targets <FILE> [--iface hciN]
  sudo foxhunt-rssi.sh --hunt <QUERY> --from-capture <LOG> [--iface hciN]

Options:
  --targets FILE       file of target MAC addresses, one per line
  --hunt QUERY         resolve targets from a capture by name, vendor,
                       fingerprint, serial or address
  --from-capture LOG   btmon capture used to resolve --hunt
  --iface hciN         adapter to hunt with
EOF
  exit 1
}

TARGET_MAC=""
TARGETS_FILE=""
HUNT_QUERY=""
FROM_CAPTURE=""
IFACE=""

while (( $# )); do
  case "$1" in
    --targets)      TARGETS_FILE="${2:-}"; shift 2 ;;
    --hunt)         HUNT_QUERY="${2:-}"; shift 2 ;;
    --from-capture) FROM_CAPTURE="${2:-}"; shift 2 ;;
    --iface)        IFACE="${2:-}"; shift 2 ;;
    -h|--help)      usage ;;
    -*)             echo "unknown option: $1" >&2; usage ;;
    *)
      if [[ -z "${TARGET_MAC}" ]]; then
        TARGET_MAC="$1"
      elif [[ -z "${IFACE}" ]]; then
        IFACE="$1"
      else
        echo "unexpected argument: $1" >&2; usage
      fi
      shift ;;
  esac
done

load_config
need_cmd btmon
need_cmd hciconfig
need_capture_privileges

resolved="$(mktemp)"
tmpfile="$(mktemp)"
fifo="$(mktemp -u "${TMPDIR:-/tmp}/foxhunt-XXXXXX.fifo")"
PRODUCER_PID=""
cleanup() {
  # The radio producer (btmon or tshark) runs in the background feeding a
  # FIFO, so it is ours to stop; a pipeline member would outlive a script
  # killed by a signal and keep the radio busy.
  if [[ -n "${PRODUCER_PID}" ]]; then
    kill "${PRODUCER_PID}" 2>/dev/null || true
    wait "${PRODUCER_PID}" 2>/dev/null || true
    PRODUCER_PID=""
  fi
  stop_le_scan "${IFACE}"
  rm -f "${resolved}" "${tmpfile}" "${tmpfile}.new" "${fifo}"
}

if [[ -n "${HUNT_QUERY}" ]]; then
  if [[ -z "${FROM_CAPTURE}" ]]; then
    echo "--hunt requires --from-capture <LOG>" >&2
    rm -f "${resolved}" "${tmpfile}"
    exit 1
  fi
  # Let the resolver's tier warnings reach the operator; they say whether the
  # address set is one device or several.
  if ! python3 "${SCRIPT_DIR}/ble-fingerprint.py" --input "${FROM_CAPTURE}" \
       --no-store --hunt "${HUNT_QUERY}" > "${resolved}"; then
    echo "no targets resolved for '${HUNT_QUERY}' in ${FROM_CAPTURE}" >&2
    rm -f "${resolved}" "${tmpfile}"
    exit 1
  fi
elif [[ -n "${TARGETS_FILE}" ]]; then
  if [[ ! -r "${TARGETS_FILE}" ]]; then
    echo "cannot read targets file: ${TARGETS_FILE}" >&2
    rm -f "${resolved}" "${tmpfile}"
    exit 1
  fi
  grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' "${TARGETS_FILE}" > "${resolved}" || true
elif [[ -n "${TARGET_MAC}" ]]; then
  printf '%s\n' "${TARGET_MAC}" > "${resolved}"
else
  rm -f "${resolved}" "${tmpfile}"
  usage
fi

# Normalise so the comparison in awk is a plain string match.
tr 'a-z' 'A-Z' < "${resolved}" | sort -u > "${resolved}.norm"
mv "${resolved}.norm" "${resolved}"

target_count="$(wc -l < "${resolved}" | tr -d ' ')"
if (( target_count == 0 )); then
  echo "no valid target addresses" >&2
  rm -f "${resolved}" "${tmpfile}"
  exit 1
fi

if [[ -z "${IFACE}" ]]; then
  IFACE="$(default_hunt_iface)"
else
  ensure_hci "${IFACE}"
fi

trap cleanup EXIT
# A signal must still run the EXIT trap, so the producer and the scan stop.
trap 'exit 130' INT TERM

echo "Tracking ${target_count} address(es) on ${IFACE}. Ctrl+C to stop."
sed 's/^/  target: /' "${resolved}"
if (( target_count > 1 )); then
  echo "Note: several addresses are being followed at once. If they belong to"
  echo "      different devices the median will jump between them."
fi
echo "Walk slowly; watch the median rise as you close on the source."

start_le_scan "${IFACE}"

total=0
last_report=-1
last_seen="?"
idle=5

# btmon prints each advertisement twice when something holds an mgmt socket:
# once as an HCI event ('>') and again as a management event ('@'). Counting
# both doubles the sample rate for no extra information, so only '>' blocks
# are read. IGNORECASE is deliberately not used; it is a gawk extension and
# these scripts also run under mawk on the uConsole image.
# Producer: one "ADDRESS RSSI" line per advertisement from a target. With
# root that is btmon's text; without it, tshark's field output from the
# monitor channel (the unprivileged route lib.sh sets up), which carries
# the same two values and needs no block parsing. The radio process runs
# in the background into a FIFO so cleanup can stop it by pid.
mkfifo -m 600 "${fifo}"
if [[ "${CAPTURE_MODE}" == "unprivileged" ]]; then
  tshark -i bluetooth-monitor -l -Y "${BLE_TSHARK_FILTER}" -T fields \
    -e bthci_evt.bd_addr -e bthci_evt.rssi -E separator=/t -E occurrence=f \
    > "${fifo}" 2>/dev/null &
else
  stdbuf -oL btmon -i "${IFACE}" > "${fifo}" 2>/dev/null &
fi
PRODUCER_PID=$!

rssi_pairs() {
  if [[ "${CAPTURE_MODE}" == "unprivileged" ]]; then
    awk -F'\t' -v targets="${resolved}" '
        BEGIN {
          while ((getline line < targets) > 0) {
            if (line != "") {
              want[line] = 1
            }
          }
          close(targets)
        }
        {
          addr = toupper($1)
          if ((addr in want) && ($2 ~ /^-?[0-9]+$/)) {
            print addr, $2
            fflush()
          }
        }' < "${fifo}"
    return
  fi
  awk -v targets="${resolved}" '
  BEGIN {
    while ((getline line < targets) > 0) {
      if (line != "") {
        want[line] = 1
      }
    }
    close(targets)
    inhci = 0
  }
  /^[<>@=] / {
    inhci = ($1 == ">")
    next
  }
  inhci && /^[[:space:]]*(LE |BR\/EDR )?Address:/ {
    addr = ""
    for (i = 1; i <= NF; i++) {
      if ($i ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
        addr = toupper($i)
        break
      }
    }
    next
  }
  inhci && /^[[:space:]]*RSSI:/ {
    if (addr != "" && (addr in want)) {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^-?[0-9]+$/) {
          print addr, $i
          fflush()
          break
        }
      }
    }
    addr = ""
  }
' < "${fifo}"
}

rssi_pairs | while :; do
  rc=0
  read -r -t "${idle}" addr rssi || rc=$?

  # read -t returns >128 on timeout, 1 on end of input. A quiet target is
  # normal: some devices advertise only every few seconds, so say so rather
  # than looking hung.
  if (( rc > 128 )); then
    if (( total == 0 )); then
      echo "waiting: target not heard yet (${idle}s). Check it is powered and in range."
    else
      echo "waiting: no report in ${idle}s (samples=${total}, last=${last_seen}dBm)"
    fi
    continue
  fi
  (( rc != 0 )) && break

  echo "${rssi}" >> "${tmpfile}"
  total=$((total + 1))
  last_seen="${rssi}"

  # Report the first sample immediately, then at most once a second. A fox
  # hunt needs continuous feedback, and a sparse target would otherwise print
  # nothing for minutes.
  if (( total == 1 || SECONDS != last_report )); then
    last_report=${SECONDS}
    med=$(sort -n "${tmpfile}" | awk '
    {
      a[NR] = $1
    }
    END {
      if (NR == 0) {
        exit
      }
      if (NR % 2 == 1) {
        print a[(NR + 1) / 2]
      } else {
        print int((a[NR / 2] + a[NR / 2 + 1]) / 2)
      }
    }')
    window=$(wc -l < "${tmpfile}" | tr -d ' ')
    echo "samples=${total} from=${addr} latest=${rssi}dBm median${window}=${med}dBm"

    # Keep a sliding window of recent points for responsiveness.
    tail -n 40 "${tmpfile}" > "${tmpfile}.new"
    mv "${tmpfile}.new" "${tmpfile}"
  fi
done
