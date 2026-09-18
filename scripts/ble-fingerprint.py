#!/usr/bin/env python3
"""Fingerprint BLE advertisers and track them across captures.

Why this is not simply "track the MAC"
--------------------------------------
Most modern devices advertise with resolvable private addresses that rotate
every ~15 minutes. In a 20 second sample taken on a conference floor, 63% of
observed addresses were resolvable, 33% were random static, and only 4% were
public. Keying a watchlist on the address alone therefore loses most targets
within a quarter of an hour.

So each advertiser gets two keys:

  fingerprint  a hash of the advertisement's *structure*: which company IDs,
               service UUIDs, TX power, data length, flags and PDU type it
               uses, plus a model-normalised name. This survives address
               rotation.

  address      the observed MAC, which is a true identity only when it is
               public or random static.

The important limitation, stated plainly: a fingerprint identifies a device
*model and configuration*, not an individual unit. In the same capture three
different addresses all advertised the name 'AC695X_1', a Bluetrum earbud
chipset used by many vendors. Those are almost certainly three separate people
wearing similar earbuds, and any tool claiming otherwise is lying to you.

Each sighting is therefore given an identity tier:

  strong   the address is public, or the name embeds a serial number. This is
           an individual device.
  session  the address is random static. Stable until the device reboots, so
           it is reliable within an evening but not across days.
  model    resolvable private address. The fingerprint tells you what kind of
           device it is and nothing more. Multiple units collapse together.

Treat 'model' hits as leads to confirm by other means, not as identifications.
"""

import argparse
import json
import os
import sys
import time
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ble_parse  # noqa: E402
from ble_identity import (  # noqa: E402
    fingerprint,
    identity_key,
    identity_tier,  # noqa: F401  (re-exported for tests and callers)
    split_name,
)


class Device:
    def __init__(self, key: str):
        self.key = key
        self.fp = ""
        self.tier = "model"
        self.name = ""
        self.model = ""
        self.serials = set()
        self.addresses = set()
        self.companies = set()
        self.service_uuids = set()
        self.count = 0
        self.rssi_min: Optional[int] = None
        self.rssi_max: Optional[int] = None
        self.rssi_best: Optional[int] = None

    def add(self, record, tier: str) -> None:
        model, serial = split_name(record.name)
        order = {"ambiguous": -1, "model": 0, "session": 1, "strong": 2}
        if order[tier] > order[self.tier]:
            self.tier = tier
        self.fp = fingerprint(record)
        if record.name and not self.name:
            self.name = record.name
        if model:
            self.model = model
        if serial:
            self.serials.add(serial)
        self.addresses.add(record.address)
        self.companies.update(record.companies)
        self.service_uuids.update(record.service_uuids)
        self.count += 1
        if record.rssi is not None:
            self.rssi_min = record.rssi if self.rssi_min is None else min(self.rssi_min, record.rssi)
            self.rssi_max = record.rssi if self.rssi_max is None else max(self.rssi_max, record.rssi)
            self.rssi_best = self.rssi_max

    def finalise(self) -> None:
        """Downgrade entries that cannot honestly claim their tier.

        An advertisement with no name, no company ID and no service UUID has
        almost no distinguishing content, so every such device in range hashes
        to the same fingerprint. Reporting that as an identification would be
        wrong, and it is common: bare advertisements are the single largest
        group in a typical capture.
        """
        if self.key.startswith("fp:"):
            contentless = not (self.name or self.companies or self.service_uuids)
            if contentless or len(self.addresses) > 3:
                self.tier = "ambiguous"

    def absorb(self, other: "Device") -> None:
        order = {"ambiguous": -1, "model": 0, "session": 1, "strong": 2}
        if order[other.tier] > order[self.tier]:
            self.tier = other.tier
        if other.name and not self.name:
            self.name = other.name
        if other.model and not self.model:
            self.model = other.model
        self.serials |= other.serials
        self.addresses |= other.addresses
        self.companies |= other.companies
        self.service_uuids |= other.service_uuids
        self.count += other.count
        for attr in ("rssi_min",):
            mine, theirs = getattr(self, attr), getattr(other, attr)
            if theirs is not None:
                setattr(self, attr, theirs if mine is None else min(mine, theirs))
        for attr in ("rssi_max", "rssi_best"):
            mine, theirs = getattr(self, attr), getattr(other, attr)
            if theirs is not None:
                setattr(self, attr, theirs if mine is None else max(mine, theirs))

    def label(self) -> str:
        if self.name:
            return self.name
        if self.companies:
            return "(" + ", ".join(sorted(self.companies)) + ")"
        return "(unnamed)"


def coalesce(devices: Dict[str, Device]) -> Dict[str, Device]:
    """Merge address groups into serial groups that share an address.

    A device does not put its name in every advertisement. The named ones key
    on the serial while the unnamed ones key on the address, which splits one
    physical device across two entries and makes a watchlist report it twice.
    A stable address belongs to exactly one device, so sharing one is proof the
    two groups are the same device.
    """
    serial_keys = [k for k in devices if k.startswith("serial:")]
    if not serial_keys:
        return devices

    owner: Dict[str, str] = {}
    for key in serial_keys:
        for addr in devices[key].addresses:
            owner[addr] = key

    for key in [k for k in devices if k.startswith("addr:")]:
        dev = devices[key]
        target = next((owner[a] for a in dev.addresses if a in owner), None)
        if target and target != key:
            devices[target].absorb(dev)
            del devices[key]
    return devices


def build(records) -> Dict[str, Device]:
    devices: Dict[str, Device] = {}
    for record in records:
        if not record.address:
            continue
        key, tier = identity_key(record)
        devices.setdefault(key, Device(key)).add(record, tier)
    devices = coalesce(devices)
    for dev in devices.values():
        dev.finalise()
    return devices


# --- persistent sighting store ------------------------------------------------

def load_store(path: str) -> dict:
    if not path or not os.path.exists(path):
        return {"devices": {}}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"warn: could not read store {path}: {exc}", file=sys.stderr)
        return {"devices": {}}
    if not isinstance(data, dict) or "devices" not in data:
        print(f"warn: store {path} is not in the expected format; ignoring.",
              file=sys.stderr)
        return {"devices": {}}
    return data


def save_store(path: str, store: dict) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(store, handle, indent=2, sort_keys=True)
    os.replace(tmp, path)


def merge(store: dict, devices: Dict[str, Device], source: str) -> List[str]:
    """Fold this capture into the store. Returns keys seen in an earlier run."""
    now = time.time()
    known = []
    for key, dev in devices.items():
        entry = store["devices"].get(key)
        if entry is None:
            entry = {
                "first_seen": now,
                "sightings": 0,
                "captures": [],
                "addresses": [],
                "serials": [],
                "note": "",
            }
            store["devices"][key] = entry
        else:
            known.append(key)
        entry["last_seen"] = now
        entry["tier"] = dev.tier
        entry["fingerprint"] = dev.fp
        entry["label"] = dev.label()
        entry["model"] = dev.model
        entry["sightings"] = entry.get("sightings", 0) + dev.count
        entry["addresses"] = sorted(set(entry.get("addresses", [])) | dev.addresses)
        entry["serials"] = sorted(set(entry.get("serials", [])) | dev.serials)
        entry["companies"] = sorted(dev.companies)
        if source and source not in entry["captures"]:
            entry["captures"].append(source)
        if dev.rssi_best is not None:
            prev = entry.get("rssi_best")
            entry["rssi_best"] = dev.rssi_best if prev is None else max(prev, dev.rssi_best)
    return known


# --- watchlist ---------------------------------------------------------------

def load_watchlist(path: str) -> List[dict]:
    """Watchlist lines: '<match> [# comment]'.

    A match is a fingerprint, a MAC address, or 'name:<substring>'.
    """
    entries = []
    if not path:
        return entries
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            note = raw.split("#", 1)[1].strip() if "#" in raw else ""
            entries.append({"match": line, "note": note})
    return entries


def watch_hits(devices: Dict[str, Device], watchlist: List[dict]) -> List[tuple]:
    hits = []
    for entry in watchlist:
        needle = entry["match"].lower()
        for key, dev in devices.items():
            matched = False
            if needle.startswith("name:"):
                target = needle[5:]
                if target and target in dev.label().lower():
                    matched = True
            elif needle in (key.lower(), dev.fp.lower()):
                matched = True
            elif any(needle == a.lower() for a in dev.addresses):
                matched = True
            elif any(needle == s.lower() for s in dev.serials):
                matched = True
            if matched:
                hits.append((entry, dev))
    return hits


def matches_query(dev: Device, query: str) -> bool:
    q = query.lower()
    if q in (dev.key.lower(), dev.fp.lower()):
        return True
    if any(q == a.lower() for a in dev.addresses):
        return True
    if any(q == s.lower() for s in dev.serials):
        return True
    if q in dev.label().lower():
        return True
    if any(q in c.lower() for c in dev.companies):
        return True
    if any(q == u.lower() for u in dev.service_uuids):
        return True
    return False


# --- reporting ---------------------------------------------------------------

TIER_NOTE = {
    "strong": "individual device",
    "session": "stable until reboot",
    "model": "device model only, not a unique unit",
    "ambiguous": "cannot be attributed to any single device",
}


def print_report(devices: Dict[str, Device], known: List[str], limit: int) -> None:
    ordered = sorted(devices.values(), key=lambda d: (-d.count, d.label()))
    tiers = {"strong": 0, "session": 0, "model": 0, "ambiguous": 0}
    for dev in devices.values():
        tiers[dev.tier] += 1

    print("# Fingerprint Summary")
    print(f"tracked={len(devices)}")
    print(f"strong_identity={tiers['strong']}")
    print(f"session_identity={tiers['session']}")
    print(f"model_only={tiers['model']}")
    print(f"ambiguous={tiers['ambiguous']}")
    print(f"previously_seen={len(known)}")
    print()
    print("# Devices")
    print(f"{'KEY':<26}{'TIER':<11}{'SEEN':>5}{'ADDRS':>7}{'RSSI':>6}  LABEL")
    for dev in ordered[:limit]:
        rssi = "-" if dev.rssi_best is None else str(dev.rssi_best)
        flag = "*" if dev.key in known else " "
        print(f"{dev.key:<26}{dev.tier:<11}{dev.count:>5}{len(dev.addresses):>7}"
              f"{rssi:>6}  {flag}{dev.label()}")
    if len(ordered) > limit:
        print(f"... {len(ordered) - limit} more (use --limit)")
    print()
    print("* = seen in an earlier capture")
    print()
    print("tier meanings:")
    print("  strong     public address or a serial in the name. An individual unit.")
    print("  session    random static address. Stable until the device reboots.")
    print("  model      rotating address; the fingerprint identifies a product,")
    print("             not a unit. Several people with the same product merge here.")
    print("  ambiguous  too little distinguishing content to attribute at all.")
    print("Only 'strong' entries should be treated as identifying a person's device.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, help="btmon text capture")
    parser.add_argument("--store", default="logs/sightings.json",
                        help="persistent sighting database (default: logs/sightings.json)")
    parser.add_argument("--no-store", action="store_true",
                        help="do not read or write the sighting database")
    parser.add_argument("--watchlist", help="file of fingerprints/MACs/name: patterns to flag")
    parser.add_argument("--hunt", help="print addresses matching a fingerprint, MAC, name or vendor")
    parser.add_argument("--min-sightings", type=int, default=1,
                        help="ignore fingerprints seen fewer than N times")
    parser.add_argument("--limit", type=int, default=40, help="rows to print")
    args = parser.parse_args()

    records = ble_parse.parse_records(args.input)
    if not records:
        print(f"warn: no advertising reports parsed from {args.input}", file=sys.stderr)
        return 1

    devices = build(records)
    if args.min_sightings > 1:
        devices = {fp: d for fp, d in devices.items() if d.count >= args.min_sightings}

    # Hunt mode prints addresses only, so it can feed foxhunt-rssi.sh directly.
    if args.hunt:
        found = [d for d in devices.values() if matches_query(d, args.hunt)]
        if not found:
            print(f"no device matched {args.hunt!r}", file=sys.stderr)
            return 1
        for dev in sorted(found, key=lambda d: -d.count):
            for addr in sorted(dev.addresses):
                print(addr)
            if dev.tier in ("model", "ambiguous"):
                print(f"warn: {dev.key} matched at tier '{dev.tier}' ({dev.label()}); "
                      f"these {len(dev.addresses)} addresses may belong to "
                      f"different devices.", file=sys.stderr)
        return 0

    known: List[str] = []
    if not args.no_store:
        store = load_store(args.store)
        known = merge(store, devices, os.path.basename(args.input))
        save_store(args.store, store)

    print_report(devices, known, args.limit)

    if args.watchlist:
        hits = watch_hits(devices, load_watchlist(args.watchlist))
        print()
        if not hits:
            print("# Watchlist: no matches")
        else:
            print("# Watchlist matches")
            for entry, dev in hits:
                note = f"  ({entry['note']})" if entry["note"] else ""
                print(f"HIT {entry['match']} -> {dev.key} {dev.label()} "
                      f"tier={dev.tier} seen={dev.count}{note}")
                if dev.tier in ("model", "ambiguous"):
                    print(f"    caution: {TIER_NOTE[dev.tier]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
