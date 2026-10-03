"""Parse 802.11 management frames from tshark's field output.

The capture side runs tshark with a fixed field list (FIELDS below, in this
order, tab separated, first occurrence only). Both the live wrapper and the
batch converter use the same list, so one parser serves both, exactly as
ble_parse does for btmon.

Everything here is passive. A monitor-mode interface only listens; nothing
is injected, associated or transmitted.

Two details worth knowing before trusting a field:

* wlan.fc.type_subtype prints as hex ('0x0008') in some tshark versions and
  as decimal in others; both are accepted. The management subtypes this
  toolkit cares about are beacon (8), probe request (4), probe response (5),
  deauthentication (12) and disassociation (10).
* wlan.ssid has changed representation across Wireshark releases. A value
  that is entirely hex digits of even length and decodes to printable text
  is treated as hex-encoded; otherwise it is taken literally. An SSID that is
  genuinely a hex-looking string is the ambiguity that leaves; it is rare and
  it is noted in docs/wifi-notes.md as something to verify on hardware.
"""

import re
from dataclasses import dataclass, field
from typing import Iterable, Iterator, List, Optional

# tshark -T fields -e ... in exactly this order, every occurrence joined by
# commas (-E occurrence=a -E aggregator=,). Keep in step with scripts/lib.sh
# WIFI_TSHARK_FIELDS. The last four are what a client or an access point
# reveals about itself regardless of its MAC: the order of its tagged
# parameters, its supported rates, its HT capability word and the vendor
# OUIs in its vendor-specific tags. Those are the fingerprint inputs.
FIELDS = [
    "frame.time_epoch",
    "wlan.fc.type_subtype",
    "wlan.sa",
    "wlan.da",
    "wlan.bssid",
    "wlan.ssid",
    "wlan_radio.signal_dbm",
    "wlan_radio.channel",
    "wlan.fixed.reason_code",
    "wlan.tag.number",
    "wlan.supported_rates",
    "wlan.ht.capabilities",
    "wlan.tag.oui",
]

SUBTYPE_NAMES = {
    0: "assoc_req", 1: "assoc_resp", 2: "reassoc_req", 3: "reassoc_resp",
    4: "probe_req", 5: "probe_resp", 8: "beacon", 10: "disassoc",
    11: "auth", 12: "deauth", 13: "action",
}

MAC_RE = re.compile(r"^(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$")
HEX_RE = re.compile(r"^(?:[0-9A-Fa-f]{2})+$")


@dataclass
class WifiFrame:
    timestamp: Optional[float] = None
    subtype: int = -1
    sa: str = ""
    da: str = ""
    bssid: str = ""
    ssid: str = ""
    rssi: Optional[int] = None
    channel: Optional[int] = None
    reason: Optional[int] = None
    tags: List[int] = field(default_factory=list)
    rates: List[str] = field(default_factory=list)
    ht_caps: str = ""
    vendor_ouis: List[str] = field(default_factory=list)

    @property
    def kind(self) -> str:
        return SUBTYPE_NAMES.get(self.subtype, f"subtype_{self.subtype}")

    @property
    def is_management(self) -> bool:
        return 0 <= self.subtype <= 15

    @property
    def sa_random(self) -> bool:
        """Locally administered bit set: a randomised (privacy) MAC."""
        try:
            return bool(int(self.sa[0:2], 16) & 0x02)
        except (ValueError, IndexError):
            return False


def parse_subtype(text: str) -> int:
    text = text.strip()
    if not text:
        return -1
    try:
        return int(text, 0)
    except ValueError:
        return -1


def parse_ssid(text: str) -> str:
    text = text.strip()
    if not text:
        return ""
    if len(text) >= 4 and HEX_RE.match(text):
        try:
            decoded = bytes.fromhex(text).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            return text
        if decoded.isprintable():
            return decoded
    return text


def first(text: str) -> str:
    """The first of a comma-joined list of occurrences (scalar fields)."""
    return text.split(",", 1)[0].strip() if text else ""


def parse_int(text: str) -> Optional[int]:
    text = first(text)
    if not text:
        return None
    try:
        return int(text, 0) if text.lower().startswith("0x") else int(float(text))
    except ValueError:
        return None


def parse_int_list(text: str) -> List[int]:
    out = []
    for part in text.split(","):
        part = part.strip()
        if not part:
            continue
        try:
            out.append(int(part, 0))
        except ValueError:
            continue
    return out


def parse_oui_list(text: str) -> List[str]:
    """Vendor OUIs as six lowercase hex digits, whatever spelling tshark used."""
    out = []
    for part in text.split(","):
        part = part.strip().lower().replace(":", "").replace("-", "")
        if not part:
            continue
        try:
            out.append(f"{int(part, 16 if not part.startswith('0x') else 0):06x}")
        except ValueError:
            continue
    return out


def parse_line(line: str) -> Optional[WifiFrame]:
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        return None
    parts = line.split("\t")
    if len(parts) < 5:
        return None
    parts += [""] * (len(FIELDS) - len(parts))
    frame = WifiFrame()
    try:
        frame.timestamp = float(first(parts[0])) if parts[0].strip() else None
    except ValueError:
        frame.timestamp = None
    frame.subtype = parse_subtype(first(parts[1]))
    sa, da, bssid = first(parts[2]), first(parts[3]), first(parts[4])
    frame.sa = sa.upper() if MAC_RE.match(sa) else ""
    frame.da = da.upper() if MAC_RE.match(da) else ""
    frame.bssid = bssid.upper() if MAC_RE.match(bssid) else ""
    frame.ssid = parse_ssid(first(parts[5]))
    frame.rssi = parse_int(parts[6])
    frame.channel = parse_int(parts[7])
    frame.reason = parse_int(parts[8])
    frame.tags = parse_int_list(parts[9])
    frame.rates = [r.strip().lower() for r in parts[10].split(",") if r.strip()]
    frame.ht_caps = first(parts[11]).lower()
    frame.vendor_ouis = parse_oui_list(parts[12])
    if not frame.sa and not frame.bssid:
        return None
    return frame


def iter_frames(lines: Iterable[str]) -> Iterator[WifiFrame]:
    for line in lines:
        frame = parse_line(line)
        if frame is not None:
            yield frame


def parse_frames(path: str) -> List[WifiFrame]:
    with open(path, "r", encoding="utf-8", errors="ignore") as handle:
        return list(iter_frames(handle))


def capture_duration(frames: List[WifiFrame]) -> float:
    stamps = [f.timestamp for f in frames if f.timestamp is not None]
    if len(stamps) < 2:
        return 0.0
    span = max(stamps) - min(stamps)
    return span if span > 0 else 0.0
