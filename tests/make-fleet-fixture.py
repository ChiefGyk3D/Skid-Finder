#!/usr/bin/env python3
"""Generate ble-obs/1 streams from three fixed sensors, for collector testing.

Layout (metres are approximate; the positions are real coordinates so the
haversine maths is exercised):

    B (33 m north of A)
    |
    A ---- C (36 m east of A)

Traffic, on an absolute epoch timeline:

  * ambient devices, each "at home" near one sensor: loud there, faint at the
    others, addresses held for the whole run. Must not trip the detector.
  * one public-address device (tier strong) at home near B, so its location
    estimate must land nearer B than A or C.
  * a MAC-rotating Apple-lure flood from t=15 to t=45, loudest at A, so the
    fleet must place the flood nearest A, and must not alert before t=15.
  * one node-reported ble-alert/1 from A during the flood, and a
    sensor-status/1 heartbeat from every sensor.

Writes obs-<sensor>.jsonl and alerts-A.jsonl into --outdir.
"""

import argparse
import json
import os
import random
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import ble_parse  # noqa: E402
from ble_identity import identity_key  # noqa: E402

SENSORS = {
    "A": (36.1000, -115.2000),
    "B": (36.1003, -115.2000),
    "C": (36.1000, -115.1996),
}
BASE = 1758200000.0  # default; --base overrides (a live collector prunes old records)
LURES = ["AirPods Pro", "Beats Studio", "AirPods Max", "AirTag", "Bose QC", "JBL Flip", "Galaxy Buds"]


def rand_mac(rng):
    return ":".join(f"{rng.randint(0, 255):02X}" for _ in range(6))


def obs(sensor, ts, addr, addr_type, addr_class, rssi, name="", companies=None, uuids=None):
    rec = ble_parse.AdRecord(address=addr, addr_type=addr_type, addr_class=addr_class,
                             timestamp=ts, rssi=rssi, name=name,
                             companies=list(companies or []), service_uuids=list(uuids or []))
    key, tier = identity_key(rec)
    lat, lon = SENSORS[sensor]
    return {
        "schema": "ble-obs/1", "ts": ts, "ts_absolute": True, "sensor_id": sensor,
        "lat": lat, "lon": lon, "modality": "ble", "address": addr, "addr_type": addr_type,
        "addr_class": addr_class, "tier": tier, "identity_key": key, "rssi": rssi,
        "tx_power": None, "name": name, "companies": sorted(set(companies or [])),
        "service_uuids": sorted(set(uuids or [])), "pdu": "", "flags": "",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--outdir", required=True)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--duration", type=float, default=60.0)
    parser.add_argument("--base", type=float, default=None,
                        help="epoch seconds of t=0 (default: a fixed value for reproducibility)")
    args = parser.parse_args()
    global BASE
    if args.base is not None:
        BASE = args.base
    rng = random.Random(args.seed)
    os.makedirs(args.outdir, exist_ok=True)

    streams = {s: [] for s in SENSORS}

    # Ambient: 30 devices, each at home near one sensor, holding an address.
    devices = []
    for i in range(30):
        devices.append({
            "addr": rand_mac(rng), "home": rng.choice(list(SENSORS)),
            "type": "random", "class": "resolvable" if i % 3 else "static",
            "name": f"Device-{i}" if i % 10 == 0 else "",
            "company": rng.choice(["samsung electronics co. ltd.", "microsoft", "lg electronics"]),
        })
    t = 0.0
    while t < args.duration:
        for sensor in SENSORS:
            dev = devices[rng.randrange(len(devices))]
            rssi = rng.randint(-60, -45) if dev["home"] == sensor else rng.randint(-92, -75)
            streams[sensor].append(obs(sensor, BASE + t + rng.random() * 0.4, dev["addr"], dev["type"],
                                       dev["class"], rssi, dev["name"], [dev["company"]]))
        t += 0.5

    # One public device near B, heard once a second by every sensor.
    for n in range(int(args.duration)):
        ts = BASE + n + 0.2
        streams["B"].append(obs("B", ts, "40:ED:98:18:DE:AB", "public", "public", rng.randint(-52, -48),
                                "FIIO BTR11", ["guangzhou fiio"]))
        streams["A"].append(obs("A", ts, "40:ED:98:18:DE:AB", "public", "public", rng.randint(-78, -72),
                                "FIIO BTR11", ["guangzhou fiio"]))
        streams["C"].append(obs("C", ts, "40:ED:98:18:DE:AB", "public", "public", rng.randint(-82, -76),
                                "FIIO BTR11", ["guangzhou fiio"]))

    # The flood: 15 s to 45 s, new address per advert, loudest at A.
    rates = {"A": 40.0, "B": 10.0, "C": 5.0}
    for sensor, rate in rates.items():
        n = int(30 * rate)
        for i in range(n):
            ts = BASE + 15.0 + i * (30.0 / n)
            rssi = {"A": rng.randint(-50, -40), "B": rng.randint(-72, -62), "C": rng.randint(-80, -70)}[sensor]
            streams[sensor].append(obs(sensor, ts, rand_mac(rng), "random", "resolvable", rssi,
                                       rng.choice(LURES), ["apple, inc."],
                                       ["google (0xfe2c)"] if i % 4 == 0 else []))

    for sensor, records in streams.items():
        records.sort(key=lambda r: r["ts"])
        with open(os.path.join(args.outdir, f"obs-{sensor}.jsonl"), "w", encoding="utf-8") as handle:
            for rec in records:
                handle.write(json.dumps(rec, sort_keys=True) + "\n")
            handle.write(json.dumps({"schema": "sensor-status/1", "ts": BASE + args.duration,
                                     "sensor_id": sensor, "version": "test", "uptime_sec": args.duration,
                                     "published": len(records)}, sort_keys=True) + "\n")

    with open(os.path.join(args.outdir, "alerts-A.jsonl"), "w", encoding="utf-8") as handle:
        handle.write(json.dumps({
            "schema": "ble-alert/1", "ts": BASE + 30.0, "sensor_id": "A", "modality": "ble",
            "profile": "balanced", "window_sec": 30.0, "events": 1200, "unique_addrs": 1150,
            "event_rate": 40.0, "unique_ratio": 0.96, "singleton_ratio": 0.97,
            "matches": [{"name": "Flipper-like Apple popup spam pattern", "confidence": 80,
                         "evidence": "node-reported"}],
        }, sort_keys=True) + "\n")
    print(f"wrote fleet fixture to {args.outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
