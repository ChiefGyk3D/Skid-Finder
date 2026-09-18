#!/usr/bin/env bash
set -euo pipefail

# Skid Finder field menu.
#
# Everything in this toolkit is a script with positional arguments, which is a
# poor fit for a uConsole used one-handed, standing up, on a small screen.
# This menu covers the common paths so nothing has to be typed from memory.
#
# It only ever builds a command line and runs it. Every action is shown as the
# exact command before it runs, and every action is reachable without the
# menu, so nothing becomes menu-only. whiptail is used because Raspberry Pi
# OS already ships it; nothing else is required.
#
# Non-interactive use (also what the tests exercise):
#   scripts/skid-finder.sh --version                 the toolkit version
#   scripts/skid-finder.sh --list                    actions and their arguments
#   scripts/skid-finder.sh --print <action> [args]   print the command, run nothing
#   scripts/skid-finder.sh --run   <action> [args]   run one action and exit
#
# Radio actions need root. Run the menu with sudo, or run it as yourself and it
# prefixes only those commands with sudo, which keeps logs/sightings.json and
# the other analysis artifacts owned by you.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUDO=""
if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

# Config values with the same defaults the scripts use, read without
# executing the file. load_config from lib.sh exits when the file is missing;
# the menu wants to offer to create it instead.
CAPTURE_HCI="hci0"
HUNT_HCI="hci1"
SCAN_SECONDS="30"
if [[ -f "${ROOT_DIR}/config/interfaces.conf" ]]; then
  # shellcheck source=lib.sh
  source "${SCRIPT_DIR}/lib.sh"
  load_conf_file "${ROOT_DIR}/config/interfaces.conf" CAPTURE_HCI HUNT_HCI SCAN_SECONDS 2>/dev/null || true
fi

latest_capture() {
  ls -1t "${ROOT_DIR}"/logs/btmon-*.log 2>/dev/null | head -n 1 || true
}

has_script() {
  [[ -x "${ROOT_DIR}/scripts/$1" ]]
}

# Every action: tag, one-line description, and the arguments it takes.
# Order here is the order on screen: the field sequence from the README's
# checklist, then analysis, then setup.
ACTIONS=(
  "status|Show adapters and the current mode|"
  "health|Bluetooth health check report|"
  "recover|Reset a flaky adapter (before/after report)|[iface]"
  "watch|Spam sweep: capture, count, signature scan|[iface] [seconds]"
  "field|Field run: capture + full summary to logs/|[iface] [seconds]"
  "live|Live spam alerts until Ctrl+C|[iface] [seconds] [profile]"
  "capture|Raw btmon capture to logs/|[iface] [seconds]"
  "hunt|Foxhunt a target by MAC, or by name from the latest capture|<mac-or-name> [iface]"
  "fingerprint|Identify and track devices in the latest capture|[capture]"
  "scan|Signature scan of the latest capture|[capture] [profile]"
  "mode|Set adapter mode|<dual|single|auto>"
  "aio|uConsole AIO feature profile|<ble-only|ble-gps|ble-gps-lora|restore>"
  "validate|Run the validation suite|"
  "setup|Create config files from the examples|"
)

# Print the command for an action. Prints nothing and returns non-zero when
# the action cannot be built, with the reason on stderr.
build_command() {
  local action="$1"
  shift
  local cmd=()

  case "${action}" in
    status)
      cmd=("${SCRIPT_DIR}/detect-hci.sh" "&&" "${SCRIPT_DIR}/set-adapter-mode.sh" status)
      ;;
    health)
      cmd=("${SCRIPT_DIR}/troubleshoot-bluetooth.sh")
      ;;
    recover)
      cmd=("${SUDO}" "${SCRIPT_DIR}/recover-hci.sh" "${1:-${HUNT_HCI}}")
      ;;
    watch)
      cmd=("${SUDO}" "${SCRIPT_DIR}/ble-spam-watch.sh" "${1:-${CAPTURE_HCI}}" "${2:-${SCAN_SECONDS}}")
      ;;
    field)
      cmd=("${SUDO}" "${SCRIPT_DIR}/ble-field-run.sh" "${1:-${CAPTURE_HCI}}" "${2:-300}")
      ;;
    live)
      if ! has_script ble-live-watch.sh; then
        echo "live alerting is not in this checkout (scripts/ble-live-watch.sh missing)." >&2
        return 2
      fi
      cmd=("${SUDO}" "${SCRIPT_DIR}/ble-live-watch.sh" "${1:-${CAPTURE_HCI}}" "${2:-0}" "${3:-balanced}")
      ;;
    capture)
      cmd=("${SUDO}" "${SCRIPT_DIR}/capture-btmon.sh" "${1:-${CAPTURE_HCI}}" "${2:-${SCAN_SECONDS}}")
      ;;
    hunt)
      local target="${1:-}"
      local iface="${2:-${HUNT_HCI}}"
      if [[ -z "${target}" ]]; then
        echo "hunt needs a target: a MAC address, or a name to resolve from the latest capture." >&2
        return 2
      fi
      if [[ "${target}" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
        cmd=("${SUDO}" "${SCRIPT_DIR}/foxhunt-rssi.sh" "${target}" "${iface}")
      else
        local capture
        capture="$(latest_capture)"
        if [[ -z "${capture}" ]]; then
          echo "no capture in logs/ to resolve '${target}' from; run a field run or capture first." >&2
          return 2
        fi
        cmd=("${SUDO}" "${SCRIPT_DIR}/foxhunt-rssi.sh" --hunt "${target}" --from-capture "${capture}" --iface "${iface}")
      fi
      ;;
    fingerprint)
      local capture="${1:-$(latest_capture)}"
      if [[ -z "${capture}" ]]; then
        echo "no capture in logs/ to fingerprint; run a field run or capture first." >&2
        return 2
      fi
      cmd=("${SCRIPT_DIR}/ble-fingerprint.py" --input "${capture}")
      ;;
    scan)
      local capture="${1:-$(latest_capture)}"
      if [[ -z "${capture}" ]]; then
        echo "no capture in logs/ to scan; run a field run or capture first." >&2
        return 2
      fi
      cmd=(python3 "${SCRIPT_DIR}/ble-signature-scan.py" --input "${capture}")
      if [[ -n "${2:-}" ]]; then
        cmd+=(--profile "$2")
      fi
      ;;
    mode)
      case "${1:-}" in
        dual|single|auto) ;;
        *) echo "mode needs one of: dual, single, auto." >&2; return 2 ;;
      esac
      cmd=("${SCRIPT_DIR}/set-adapter-mode.sh" "$1")
      ;;
    aio)
      case "${1:-}" in
        ble-only|ble-gps|ble-gps-lora|restore) ;;
        *) echo "aio needs one of: ble-only, ble-gps, ble-gps-lora, restore." >&2; return 2 ;;
      esac
      cmd=("${SUDO}" "${SCRIPT_DIR}/aio-feature-profile.sh" "$1")
      ;;
    validate)
      cmd=("${ROOT_DIR}/tests/test-toolkit.sh")
      ;;
    setup)
      cmd=(cp -n "${ROOT_DIR}/config/interfaces.conf.example" "${ROOT_DIR}/config/interfaces.conf"
           "&&" cp -n "${ROOT_DIR}/config/signatures.conf.example" "${ROOT_DIR}/config/signatures.conf")
      ;;
    *)
      echo "unknown action: ${action}" >&2
      return 1
      ;;
  esac

  # Drop the empty sudo slot when already root, then print one shell-quoted
  # line so what is shown is exactly what runs.
  local out=()
  local word
  for word in "${cmd[@]}"; do
    [[ -z "${word}" ]] && continue
    if [[ "${word}" == "&&" ]]; then
      out+=("&&")
    else
      out+=("$(printf '%q' "${word}")")
    fi
  done
  printf '%s\n' "${out[*]}"
}

run_action() {
  local line rc=0
  line="$(build_command "$@")" || rc=$?
  if (( rc != 0 )); then
    return "${rc}"
  fi
  echo "+ ${line}"
  echo
  # The line is built from %q-quoted words and literal '&&' only, so eval here
  # runs exactly the command that was printed.
  eval "${line}"
}

list_actions() {
  local entry tag desc args
  for entry in "${ACTIONS[@]}"; do
    IFS='|' read -r tag desc args <<<"${entry}"
    printf '  %-44s %s\n' "${tag} ${args}" "${desc}"
  done
}

ask() {
  # ask <title> <prompt> <default> -> prints the answer, empty on cancel
  whiptail --title "$1" --inputbox "$2" 10 60 "$3" 3>&1 1>&2 2>&3 || true
}

choose() {
  # choose <title> <prompt> tag desc tag desc ... -> prints the tag
  local title="$1" prompt="$2"
  shift 2
  whiptail --title "${title}" --menu "${prompt}" 20 72 12 "$@" 3>&1 1>&2 2>&3 || true
}

pause() {
  echo
  read -r -p "Press Enter to return to the menu." _ || true
}

interactive() {
  if ! command -v whiptail >/dev/null 2>&1; then
    echo "whiptail is not installed. Use --list, --print or --run, or install 'whiptail'." >&2
    exit 1
  fi

  if [[ ! -f "${ROOT_DIR}/config/interfaces.conf" ]]; then
    if whiptail --title "Skid Finder" --yesno \
        "config/interfaces.conf is missing.\n\nCreate it and config/signatures.conf from the examples now?" 12 60; then
      run_action setup || true
    fi
  fi

  while :; do
    local items=() entry tag desc args
    for entry in "${ACTIONS[@]}"; do
      IFS='|' read -r tag desc args <<<"${entry}"
      if [[ "${tag}" == "live" ]] && ! has_script ble-live-watch.sh; then
        continue
      fi
      items+=("${tag}" "${desc}")
    done
    items+=("quit" "Leave the menu")

    local choice
    choice="$(choose "Skid Finder" "capture=${CAPTURE_HCI}  hunt=${HUNT_HCI}  window=${SCAN_SECONDS}s" "${items[@]}")"
    [[ -z "${choice}" || "${choice}" == "quit" ]] && break

    local a1="" a2="" a3=""
    case "${choice}" in
      recover)
        a1="$(ask "Recover" "Adapter to reset" "${HUNT_HCI}")" ;;
      watch|capture)
        a1="$(ask "${choice}" "Adapter" "${CAPTURE_HCI}")"
        a2="$(ask "${choice}" "Seconds" "${SCAN_SECONDS}")" ;;
      field)
        a1="$(ask "Field run" "Adapter" "${CAPTURE_HCI}")"
        a2="$(ask "Field run" "Seconds" "300")" ;;
      live)
        a1="$(ask "Live" "Adapter" "${CAPTURE_HCI}")"
        a2="$(ask "Live" "Seconds (0 = until Ctrl+C)" "0")"
        a3="$(choose "Live" "Sensitivity profile" balanced "default" aggressive "short windows, more alerts" conservative "needs a long window")" ;;
      hunt)
        a1="$(ask "Foxhunt" "Target MAC, or a name/vendor/serial to resolve from the latest capture" "")"
        a2="$(ask "Foxhunt" "Adapter" "${HUNT_HCI}")" ;;
      scan)
        a1="$(ask "Scan" "Capture file (blank = latest)" "")"
        a2="$(choose "Scan" "Profile" balanced "default" conservative "fewer alerts" aggressive "more alerts")" ;;
      fingerprint)
        a1="$(ask "Fingerprint" "Capture file (blank = latest)" "")" ;;
      mode)
        a1="$(choose "Adapter mode" "Pick a mode" dual "capture hci0, hunt hci1" single "one adapter for both" auto "dual when hci1 exists")" ;;
      aio)
        a1="$(choose "AIO profile" "Pick a profile" ble-only "BLE only" ble-gps "BLE + GPS" ble-gps-lora "BLE + GPS + LoRa" restore "restore previous state")" ;;
    esac

    clear
    local argv=()
    [[ -n "${a1}" ]] && argv+=("${a1}")
    [[ -n "${a2}" ]] && argv+=("${a2}")
    [[ -n "${a3}" ]] && argv+=("${a3}")
    run_action "${choice}" "${argv[@]}" || true
    pause
  done
}

case "${1:-}" in
  --version)
    if [[ -r "${ROOT_DIR}/VERSION" ]]; then
      printf 'skid-finder %s\n' "$(tr -d '[:space:]' < "${ROOT_DIR}/VERSION")"
    else
      echo "skid-finder (unversioned checkout: VERSION file missing)" >&2
      exit 1
    fi
    ;;
  --list)
    list_actions
    ;;
  --print)
    shift
    [[ -n "${1:-}" ]] || { echo "usage: $0 --print <action> [args]" >&2; exit 1; }
    build_command "$@"
    ;;
  --run)
    shift
    [[ -n "${1:-}" ]] || { echo "usage: $0 --run <action> [args]" >&2; exit 1; }
    run_action "$@"
    ;;
  -h|--help)
    sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'
    echo
    list_actions
    ;;
  "")
    interactive
    ;;
  *)
    echo "unknown option: $1 (try --help)" >&2
    exit 1
    ;;
esac
