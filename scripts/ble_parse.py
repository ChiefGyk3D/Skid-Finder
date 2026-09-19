#!/usr/bin/env python3
"""Shared parser for btmon text captures.

Both the signature scanner and the fingerprint tool need the same view of a
capture, so the parsing lives here rather than being reimplemented per script.

Two details of real btmon output drive the design:

1. Every advertisement can appear twice. Once as an HCI event
   ('> HCI Event: LE Meta Event') and again as a management event
   ('@ MGMT Event: Device Found') when something like bluetoothd or
   bluetoothctl holds an mgmt socket open. The HCI event is the ground truth,
   so MGMT echoes are skipped; counting both roughly doubles every statistic.

2. Field names are not what they are often assumed to be. btmon writes
   'Name (complete):', not 'Complete local name:', and addresses appear as
   'Address:', 'LE Address:', 'BR/EDR Address:' and 'Direct address:' in
   different event types. Matching loosely on 'Address:' pulls in unrelated
   events.
"""

import re
from dataclasses import dataclass, field
from typing import Dict, Iterable, Iterator, List, Optional


MAC_RE = re.compile(r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}")
TIME_RE = re.compile(r"(\d+\.\d+)\s*$")
INT_RE = re.compile(r"-?\d+")

# btmon block markers. '>' host<-controller, '<' host->controller,
# '@' management channel, '=' monitor note.
BLOCK_RE = re.compile(r"^[><@=]\s")

ADV_REPORT_RE = re.compile(
    r"LE (?:Extended )?Advertising Report|LE Direct Advertising Report"
)

# Real btmon spelling first, then tolerant fallbacks so hand-written or
# older-format fixtures still parse.
NAME_RE = re.compile(
    r"^\s*(?:Name \((?:complete|short)\)|(?:Complete |Shortened )?[Ll]ocal [Nn]ame)\s*:\s*(.+)$"
)
ADDRESS_RE = re.compile(r"^\s*(?:LE |BR/EDR )?Address\s*:\s*(" + MAC_RE.pattern + r")(.*)$")
ADDR_TYPE_RE = re.compile(r"^\s*Address type\s*:\s*(\w+)")
RSSI_RE = re.compile(r"^\s*RSSI\s*:\s*(-?\d+)")
TXPOWER_RE = re.compile(r"^\s*TX power\s*:\s*(-?\d+)")
COMPANY_RE = re.compile(r"^\s*Company\s*:\s*(.+?)\s*\((\d+)\)\s*$")
MANUF_RE = re.compile(r"^\s*Manufacturer data\s*\(([^)]*)\)", re.IGNORECASE)
SERVICE_DATA_RE = re.compile(r"^\s*Service Data\b.*?(0x[0-9A-Fa-f]{4})")
UUID_RE = re.compile(r"^\s*(?:16-bit|32-bit|128-bit) Service UUIDs.*")
UUID_VALUE_RE = re.compile(r"(0x[0-9A-Fa-f]{4})")
FLAGS_RE = re.compile(r"^\s*Flags\s*:\s*(0x[0-9A-Fa-f]+)")
PDU_RE = re.compile(r"^\s*(?:Legacy PDU Type|Event type)\s*:\s*(.+?)\s*$")
DATA_LEN_RE = re.compile(r"^\s*Data length\s*:\s*(\d+)")

FAST_PAIR_UUID = "0xfe2c"


def classify_address(suffix: str) -> str:
    """Classify an advertiser address from btmon's parenthesised suffix.

    btmon annotates addresses with one of:

      (Resolvable)      private, rotates roughly every 15 minutes
      (Non-Resolvable)  private, also rotates
      (Static)          random static, stable until the device reboots
      (Intel Corporate) / (OUI 40-ED-98) / vendor name
                        a public address, resolved against the OUI registry

    Note that 'Non-Resolvable' contains 'Resolvable' as a substring, so a naive
    containment test silently mislabels it. Both rotate, but they are different
    address types and the distinction matters when reasoning about tracking.
    """
    text = suffix.strip().strip("()").strip()
    lowered = text.lower()
    if lowered == "non-resolvable":
        return "non-resolvable"
    if lowered == "resolvable":
        return "resolvable"
    if lowered == "static":
        return "static"
    if text:
        # Anything else is an OUI or vendor name, which only public addresses get.
        return "public"
    return "unknown"


@dataclass
class AdRecord:
    """A single advertising report."""

    address: str = ""
    addr_type: str = ""
    addr_class: str = "unknown"
    timestamp: Optional[float] = None
    rssi: Optional[int] = None
    tx_power: Optional[int] = None
    name: str = ""
    pdu_type: str = ""
    flags: str = ""
    data_length: Optional[int] = None
    companies: List[str] = field(default_factory=list)
    service_uuids: List[str] = field(default_factory=list)

    @property
    def is_random(self) -> bool:
        return self.addr_type == "random"

    @property
    def resolvable(self) -> bool:
        return self.addr_class == "resolvable"

    @property
    def rotates(self) -> bool:
        """True when the address cannot be relied on as a stable identity."""
        return self.addr_class in ("resolvable", "non-resolvable", "unknown")

    @property
    def is_public(self) -> bool:
        return self.addr_class == "public" or self.addr_type == "public"


def iter_records(lines: Iterable[str]) -> Iterator[AdRecord]:
    """Yield advertising records from an iterable of btmon text lines.

    This is the streaming heart of the parser. It emits each record the moment
    the block that follows it makes clear the record is complete, so it works
    identically whether the lines come from a file read all at once or from a
    live 'btmon' pipe delivered one line at a time. parse_records() is just this
    generator drained into a list.

    Only HCI advertising reports are yielded. MGMT 'Device Found' echoes of the
    same advertisement are skipped so events are not counted twice.
    """
    current: Optional[AdRecord] = None
    in_adv_block = False
    block_time: Optional[float] = None

    for raw in lines:
        line = raw.rstrip("\n")

        if BLOCK_RE.match(line):
            # A new top-level event ends whatever came before.
            if current is not None and current.address:
                yield current
            current = None

            # Only HCI events carry advertising reports we want to count.
            # '@' is the management channel, which duplicates them.
            in_adv_block = line.startswith(">")
            time_match = TIME_RE.search(line)
            block_time = float(time_match.group(1)) if time_match else None
            continue

        if not in_adv_block:
            continue

        if ADV_REPORT_RE.search(line):
            if current is not None and current.address:
                yield current
            current = None
            continue

        # 'Entry N' starts a new report inside a multi-report event.
        if re.match(r"^\s*Entry \d+\s*$", line):
            if current is not None and current.address:
                yield current
            current = AdRecord(timestamp=block_time)
            continue

        addr_match = ADDRESS_RE.match(line)
        if addr_match:
            # 'Direct address:' is the scan target, not the advertiser, and
            # is excluded by the regex requiring 'Address:' with a capital A.
            if current is None:
                current = AdRecord(timestamp=block_time)
            if not current.address:
                current.address = addr_match.group(1).upper()
                current.addr_class = classify_address(addr_match.group(2))
            continue

        if current is None:
            continue

        type_match = ADDR_TYPE_RE.match(line)
        if type_match:
            current.addr_type = type_match.group(1).strip().lower()
            continue

        rssi_match = RSSI_RE.match(line)
        if rssi_match:
            current.rssi = int(rssi_match.group(1))
            continue

        tx_match = TXPOWER_RE.match(line)
        if tx_match:
            value = int(tx_match.group(1))
            # 127 is the 'not available' sentinel in the LE spec.
            current.tx_power = None if value == 127 else value
            continue

        name_match = NAME_RE.match(line)
        if name_match:
            current.name = name_match.group(1).strip()
            continue

        company_match = COMPANY_RE.match(line)
        if company_match:
            current.companies.append(company_match.group(1).strip().lower())
            continue

        manuf_match = MANUF_RE.match(line)
        if manuf_match:
            vendor = manuf_match.group(1).strip().lower()
            if vendor:
                current.companies.append(vendor)
            continue

        svc_match = SERVICE_DATA_RE.match(line)
        if svc_match:
            current.service_uuids.append(svc_match.group(1).lower())
            continue

        if UUID_RE.match(line):
            for uuid in UUID_VALUE_RE.findall(line):
                current.service_uuids.append(uuid.lower())
            continue

        flags_match = FLAGS_RE.match(line)
        if flags_match:
            current.flags = flags_match.group(1).lower()
            continue

        len_match = DATA_LEN_RE.match(line)
        if len_match:
            current.data_length = int(len_match.group(1))
            continue

        pdu_match = PDU_RE.match(line)
        if pdu_match and not current.pdu_type:
            current.pdu_type = pdu_match.group(1).strip()
            continue

    if current is not None and current.address:
        yield current


# --- tshark field format ----------------------------------------------------
#
# A second way to get advertising reports, for hosts where btmon cannot be
# run as root: tshark on the 'bluetooth-monitor' interface (open to members
# of the wireshark group) with exactly these fields, tab separated, all
# occurrences joined by commas. scripts/lib.sh asks for the same list; keep
# the two in step. Measured on Wireshark 4.x, 2026-09-18.
TSHARK_FIELDS = [
    "frame.time_epoch",
    "bthci_evt.le_meta_subevent",
    "bthci_evt.bd_addr",
    "bthci_evt.le_peer_address_type",
    "bthci_evt.rssi",
    "btcommon.eir_ad.entry.device_name",
    "btcommon.eir_ad.entry.company_id",
    "btcommon.eir_ad.entry.uuid_16",
    "btcommon.eir_ad.entry.type",
    "bthci_evt.le_ext_advts_event_type",
    "bthci_evt.le_advts_event_type",
    "bthci_evt.data_length",
]
# Only LE Advertising Report (0x02) and LE Extended Advertising Report (0x0d).
TSHARK_FILTER = "bthci_evt.le_meta_subevent == 0x02 || bthci_evt.le_meta_subevent == 0x0d"


def _split_list(text: str) -> List[str]:
    return [t.strip() for t in text.split(",") if t.strip()]


def classify_random_address(address: str) -> str:
    """Static / resolvable / non-resolvable from the top two bits of a random address.

    btmon labels these for us; tshark reports only public-vs-random, so the
    class comes from the address itself: 11 static, 01 resolvable, 00
    non-resolvable (Core spec vol 6 part B 1.3.2).
    """
    try:
        top = int(address[0:2], 16) >> 6
    except (ValueError, IndexError):
        return "unknown"
    return {3: "static", 1: "resolvable", 0: "non-resolvable"}.get(top, "unknown")


def parse_tshark_line(line: str) -> Optional[AdRecord]:
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        return None
    parts = line.split("\t")
    if len(parts) < 5:
        return None
    parts += [""] * (len(TSHARK_FIELDS) - len(parts))

    addr = parts[2].strip().upper()
    if not MAC_RE.match(addr):
        return None
    record = AdRecord(address=addr)
    try:
        record.timestamp = float(parts[0]) if parts[0].strip() else None
    except ValueError:
        record.timestamp = None

    addr_type = parts[3].strip().lower()
    if addr_type in ("0x00", "0", "0x02", "2"):
        record.addr_type = "public"
        record.addr_class = "public"
    else:
        record.addr_type = "random"
        record.addr_class = classify_random_address(addr)

    rssi = parts[4].strip()
    if INT_RE.fullmatch(rssi or "x"):
        record.rssi = int(rssi)

    names = _split_list(parts[5])
    if names:
        record.name = names[-1]
    # Company ids come out as hex ('0x004c'); the BLE detector's vendor
    # regex already matches that spelling for Apple. Fingerprints computed
    # from this path therefore differ from btmon's ('apple, inc.') for the
    # same device, which docs/README record.
    record.companies = [c.lower() for c in _split_list(parts[6])]
    record.service_uuids = [u.lower().replace("0x", "") for u in _split_list(parts[7])]

    ext = parts[9].strip()
    legacy = parts[10].strip()
    if ext:
        record.pdu_type = "ext:" + ext.lower()
    elif legacy:
        record.pdu_type = "legacy:" + legacy.lower()
    length = parts[11].strip()
    if length.isdigit():
        record.data_length = int(length)
    types = [t.lower() for t in _split_list(parts[8])]
    if "0x01" in types:
        record.flags = "present"
    return record


def iter_tshark_records(lines: Iterable[str]) -> Iterator[AdRecord]:
    """Yield advertising records from tshark field lines (see TSHARK_FIELDS)."""
    for line in lines:
        record = parse_tshark_line(line)
        if record is not None:
            yield record


def parse_tshark_records(path: str) -> List[AdRecord]:
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        return list(iter_tshark_records(handle))


def parse_records(path: str) -> List[AdRecord]:
    """Parse a btmon text log into a list of advertising records.

    Thin wrapper over iter_records() so batch and streaming callers share one
    parser and cannot disagree about what a capture contains.
    """
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        return list(iter_records(handle))


def capture_duration(records: List[AdRecord]) -> float:
    """Wall-clock span of the capture in seconds.

    Returns 0.0 when timestamps are unavailable so callers can fall back to
    absolute counts instead of dividing by a fabricated duration.
    """
    stamps = [r.timestamp for r in records if r.timestamp is not None]
    if len(stamps) < 2:
        return 0.0
    span = max(stamps) - min(stamps)
    return span if span > 0 else 0.0


def address_counts(records: List[AdRecord]) -> Dict[str, int]:
    counts: Dict[str, int] = {}
    for record in records:
        counts[record.address] = counts.get(record.address, 0) + 1
    return counts
