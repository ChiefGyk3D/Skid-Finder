#!/usr/bin/env python3
"""Fingerprint Wi-Fi senders and track them across captures.

The Wi-Fi counterpart of ble-fingerprint.py. Clients randomise their MAC,
often per probe burst, so "track the MAC" fails within minutes; what
persists is what the frame says about the sender's hardware and driver
(wifi_identity). Each identity gets a tier, and the tier is the part worth
reading:

  strong    a globally administered MAC: an access point, an older client.
            Identifies a unit.
  session   a randomised MAC that holds for one session with one network.
  model     a probe request or a beacon from a randomised MAC, keyed by its
            content fingerprint. Identifies a product, or a tool: every
            beacon a spammer invents shares one fingerprint, and so do all
            the phones of one model in the room.

A beacon flood collapsing to one fingerprint is the useful finding: the
collector and the incident record can say "the same tool, again" without
ever pretending to know whose hand it is in.

Examples:
  ./scripts/wifi-fingerprint.py --input logs/wifi-wlan1-<stamp>.tsv
  ./scripts/wifi-fingerprint.py --input logs/wifi-wlan1-<stamp>.tsv --watchlist config/watchlist.conf
  ./scripts/wifi-fingerprint.py --input logs/wifi-wlan1-<stamp>.tsv --hunt "Venue-Guest"
"""

import argparse
import json
import os
import sys
import time
from typing import Dict, List

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wifi_parse  # noqa: E402
from wifi_identity import fingerprint, has_content, identity_key  # noqa: E402

TIER_NOTE = {
    "strong": "a globally administered address: one unit",
    "session": "a randomised address that holds for one session",
    "model": "a content fingerprint: a product or a tool, possibly several units",
}
ORDER = {"model": 0, "session": 1, "strong": 2}


class Sender:
    def __init__(self, key: str, tier: str) -> None:
        self.key = key
        self.tier = tier
        self.count = 0
        self.addresses: set = set()
        self.ssids: set = set()
        self.kinds: Dict[str, int] = {}
        self.rssi: List[int] = []
        self.fingerprints: set = set()
        self.vendor_ouis: set = set()
        self.first = None
        self.last = None
        self.flood = False

    def add(self, frame) -> None:
        self.count += 1
        if frame.sa:
            self.addresses.add(frame.sa)
        elif frame.bssid:
            self.addresses.add(frame.bssid)
        if frame.ssid:
            self.ssids.add(frame.ssid)
        self.kinds[frame.kind] = self.kinds.get(frame.kind, 0) + 1
        if frame.rssi is not None:
            self.rssi.append(frame.rssi)
        if has_content(frame):
            self.fingerprints.add(fingerprint(frame))
        self.vendor_ouis.update(frame.vendor_ouis)
        if frame.timestamp is not None:
            self.first = frame.timestamp if self.first is None else min(self.first, frame.timestamp)
            self.last = frame.timestamp if self.last is None else max(self.last, frame.timestamp)

    def label(self) -> str:
        if self.flood:
            return f"beacon flood: {len(self.addresses)} invented BSSIDs, {len(self.ssids)} names"
        if self.ssids:
            shown = sorted(self.ssids)[:3]
            extra = f" +{len(self.ssids) - 3}" if len(self.ssids) > 3 else ""
            return "ssids: " + ", ".join(shown) + extra
        top = max(self.kinds.items(), key=lambda kv: kv[1])[0] if self.kinds else ""
        return top

    def median_rssi(self):
        if not self.rssi:
            return None
        vals = sorted(self.rssi)
        return vals[len(vals) // 2]


FLOOD_MIN_BSSIDS = 10


def collapse_beacon_floods(senders: Dict[str, Sender]) -> Dict[str, Sender]:
    """Fold a beacon flood's invented BSSIDs into one model-tier identity.

    A spammer's BSSIDs need not carry the locally-administered bit, so per
    frame they look like globally administered addresses and each becomes
    its own strong identity, seen once. Hundreds of "access points" that
    share one content fingerprint, each beaconing once or twice, are one
    tool. Collapsing them is what lets the report say so, and the tier
    says honestly that it is a tool, not a unit.
    """
    groups: Dict[str, List[Sender]] = {}
    for sender in senders.values():
        if sender.tier != "strong" or sender.count > 2 or len(sender.fingerprints) != 1:
            continue
        if set(sender.kinds) != {"beacon"}:
            continue
        groups.setdefault(next(iter(sender.fingerprints)), []).append(sender)
    out = dict(senders)
    for fp, members in groups.items():
        if len(members) < FLOOD_MIN_BSSIDS:
            continue
        key = "fp:wifi:" + fp
        merged = out.get(key) or Sender(key, "model")
        merged.tier = "model"
        for m in members:
            merged.count += m.count
            merged.addresses |= m.addresses
            merged.ssids |= m.ssids
            for k, n in m.kinds.items():
                merged.kinds[k] = merged.kinds.get(k, 0) + n
            merged.rssi += m.rssi
            merged.fingerprints |= m.fingerprints
            merged.vendor_ouis |= m.vendor_ouis
            out.pop(m.key, None)
        merged.flood = True
        out[key] = merged
    return out


def build(frames) -> Dict[str, Sender]:
    senders: Dict[str, Sender] = {}
    for frame in frames:
        key, tier = identity_key(frame)
        senders.setdefault(key, Sender(key, tier)).add(frame)
    return collapse_beacon_floods(senders)


# --- sighting store ----------------------------------------------------------------
def load_store(path: str) -> dict:
    if not os.path.exists(path):
        return {"version": 1, "senders": {}}
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError):
        return {"version": 1, "senders": {}}
    data.setdefault("senders", {})
    return data


def merge(store: dict, senders: Dict[str, Sender], capture: str) -> List[str]:
    known = []
    now = time.time()
    for key, sender in senders.items():
        entry = store["senders"].get(key)
        if entry is not None:
            known.append(key)
        else:
            entry = store["senders"][key] = {"tier": sender.tier, "first_seen": now, "captures": []}
        entry["last_seen"] = now
        entry["tier"] = sender.tier
        entry["count"] = entry.get("count", 0) + sender.count
        entry["addresses"] = sorted(set(entry.get("addresses", [])) | sender.addresses)[:50]
        entry["ssids"] = sorted(set(entry.get("ssids", [])) | sender.ssids)[:50]
        if capture not in entry["captures"]:
            entry["captures"] = (entry["captures"] + [capture])[-20:]
    return known


def save_store(path: str, store: dict) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(store, handle, indent=1, sort_keys=True)
    os.replace(tmp, path)


# --- watchlist and hunt --------------------------------------------------------------
def load_watchlist(path: str) -> List[dict]:
    entries = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            match, _, note = line.partition("#")
            entries.append({"match": match.strip(), "note": note.strip()})
    return entries


def matches_query(sender: Sender, query: str) -> bool:
    q = query.strip().lower()
    if not q:
        return False
    if q.startswith("name:") or q.startswith("ssid:"):
        needle = q.split(":", 1)[1]
        return any(needle in s.lower() for s in sender.ssids)
    if q == sender.key.lower() or q in {fp.lower() for fp in sender.fingerprints}:
        return True
    if q.upper() in sender.addresses:
        return True
    return any(q in s.lower() for s in sender.ssids)


def watch_hits(senders: Dict[str, Sender], entries: List[dict]):
    hits = []
    for entry in entries:
        for sender in senders.values():
            if matches_query(sender, entry["match"]):
                hits.append((entry, sender))
    return hits


# --- report ---------------------------------------------------------------------------
def print_report(senders: Dict[str, Sender], known: List[str], limit: int) -> None:
    tiers = {"strong": 0, "session": 0, "model": 0}
    for s in senders.values():
        tiers[s.tier] = tiers.get(s.tier, 0) + 1
    print("# Wi-Fi Fingerprint Summary")
    print(f"tracked={len(senders)}")
    print(f"strong_identity={tiers.get('strong', 0)}")
    print(f"session_identity={tiers.get('session', 0)}")
    print(f"model_only={tiers.get('model', 0)}")
    print(f"previously_seen={len(known)}")
    print()
    print("# Senders")
    print(f"{'KEY':<26}{'TIER':<9}{'SEEN':>6}{'ADDRS':>7}{'RSSI':>6}  LABEL")
    rows = sorted(senders.values(), key=lambda s: (-ORDER[s.tier], -s.count))
    for s in rows[:limit]:
        flag = "*" if s.key in known else " "
        med = s.median_rssi()
        print(f"{s.key:<26}{s.tier:<9}{s.count:>6}{len(s.addresses):>7}{'' if med is None else med:>6}  "
              f"{flag}{s.label()}")
    if len(rows) > limit:
        print(f"... {len(rows) - limit} more (use --limit)")
    print()
    print("* = seen in an earlier capture")
    print("tier meanings:")
    for tier in ("strong", "session", "model"):
        print(f"  {tier:<8} {TIER_NOTE[tier]}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--input", required=True, help="tshark field extract (.tsv)")
    parser.add_argument("--store", default="logs/wifi-sightings.json",
                        help="persistent sighting database (default: logs/wifi-sightings.json)")
    parser.add_argument("--no-store", action="store_true", help="do not read or write the store")
    parser.add_argument("--watchlist", help="file of addresses / name:<ssid> / fingerprints to flag")
    parser.add_argument("--hunt", help="print addresses matching an SSID, fingerprint or address")
    parser.add_argument("--min-sightings", type=int, default=1)
    parser.add_argument("--limit", type=int, default=40)
    args = parser.parse_args()

    frames = wifi_parse.parse_frames(args.input)
    if not frames:
        print(f"warn: no frames parsed from {args.input}", file=sys.stderr)
        return 1
    senders = build(frames)
    if args.min_sightings > 1:
        senders = {k: s for k, s in senders.items() if s.count >= args.min_sightings}

    if args.hunt:
        found = [s for s in senders.values() if matches_query(s, args.hunt)]
        if not found:
            print(f"no sender matched {args.hunt!r}", file=sys.stderr)
            return 1
        for s in sorted(found, key=lambda x: -x.count):
            for addr in sorted(s.addresses):
                print(addr)
            if s.tier == "model":
                print(f"warn: {s.key} matched at tier 'model' ({s.label()}); these "
                      f"{len(s.addresses)} addresses may belong to different devices.", file=sys.stderr)
        return 0

    known: List[str] = []
    if not args.no_store:
        store = load_store(args.store)
        known = merge(store, senders, os.path.basename(args.input))
        save_store(args.store, store)

    print_report(senders, known, args.limit)

    if args.watchlist:
        hits = watch_hits(senders, load_watchlist(args.watchlist))
        print()
        if not hits:
            print("# Watchlist: no matches")
        else:
            print("# Watchlist matches")
            for entry, s in hits:
                note = f"  ({entry['note']})" if entry["note"] else ""
                print(f"HIT {entry['match']} -> {s.key} {s.label()} tier={s.tier} seen={s.count}{note}")
                if s.tier == "model":
                    print(f"    caution: {TIER_NOTE['model']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
