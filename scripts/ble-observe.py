#!/usr/bin/env python3
"""Emit normalized BLE observations as JSON Lines.

This is the seam the rest of the roadmap hangs off. Today every tool re-parses
a btmon text log at the end of a run, which is fine for one device analysing
its own capture but is a dead end for three things you want next:

  * live spam alerting, which needs observations as they arrive rather than
    after the capture finishes (see ble-live-alert.py);
  * a sensor net, where several devices must emit observations in one shared,
    machine-readable shape that a collector can merge and triangulate;
  * a second radio modality (Wi-Fi) later, which can reuse everything
    downstream if it emits the same record shape.

So this tool turns a capture — from a file or a live 'btmon' pipe — into one
flat JSON object per advertising report, stamped with which sensor saw it and
where that sensor is. The schema is versioned ("ble-obs/1") so a collector can
reject or adapt to records it does not understand.

Each observation carries the per-advertisement identity key and tier from
ble_identity, with the same honesty the fingerprint tool prints: a 'model' or
'ambiguous' tier identifies a product, not a person's specific unit, and no
amount of merging across sensors changes that.

Examples:

  # Batch: a finished capture to a JSONL file.
  ./scripts/ble-observe.py --input logs/capture.log --sensor-id uconsole-01 \
      --out logs/obs.jsonl

  # Live: tee btmon into a normalized stream while also capturing.
  sudo btmon -i hci0 | ./scripts/ble-observe.py --stream --sensor-id uconsole-01
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ble_parse  # noqa: E402
from ble_identity import identity_key  # noqa: E402

SCHEMA = "ble-obs/1"


def to_event(record, sensor_id, lat, lon, epoch_base):
    key, tier = identity_key(record)

    ts = record.timestamp
    ts_absolute = False
    if ts is not None and epoch_base is not None:
        # btmon timestamps are capture-relative seconds. Adding a known base
        # (the capture's wall-clock start) turns them into absolute epoch time,
        # which is what a multi-sensor collector needs to line events up.
        ts = ts + epoch_base
        ts_absolute = True

    return {
        "schema": SCHEMA,
        "ts": ts,
        "ts_absolute": ts_absolute,
        "sensor_id": sensor_id,
        "lat": lat,
        "lon": lon,
        "modality": "ble",
        "address": record.address,
        "addr_type": record.addr_type,
        "addr_class": record.addr_class,
        "tier": tier,
        "identity_key": key,
        "rssi": record.rssi,
        "tx_power": record.tx_power,
        "name": record.name,
        "companies": sorted(set(record.companies)),
        "service_uuids": sorted(set(record.service_uuids)),
        "pdu": record.pdu_type,
        "flags": record.flags,
    }


def emit(records, handle, args):
    count = 0
    for record in records:
        event = to_event(record, args.sensor_id, args.lat, args.lon, args.epoch_base)
        handle.write(json.dumps(event, sort_keys=True) + "\n")
        # Flush per line in stream mode so a downstream consumer (or a person
        # watching) sees observations as they happen, not in block-buffered
        # bursts.
        if args.stream:
            handle.flush()
        count += 1
    return count


def coerce_float(value, name):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        sys.exit(f"ERROR: {name} must be a number, got {value!r}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Emit normalized BLE observations as JSON Lines")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--input", help="btmon text capture to convert")
    src.add_argument("--stream", action="store_true",
                     help="read btmon text from stdin and emit live")
    parser.add_argument("--out", default="-",
                        help="output JSONL path, or '-' for stdout (default)")
    parser.add_argument("--sensor-id", default=os.environ.get("SENSOR_ID", "unknown"),
                        help="identifier for this sensor (default: $SENSOR_ID or 'unknown')")
    parser.add_argument("--sensor-lat", default=os.environ.get("SENSOR_LAT", ""),
                        help="sensor latitude in decimal degrees (stationary sensors)")
    parser.add_argument("--sensor-lon", default=os.environ.get("SENSOR_LON", ""),
                        help="sensor longitude in decimal degrees (stationary sensors)")
    parser.add_argument("--epoch-base", type=float, default=None,
                        help="wall-clock epoch seconds of the capture start; when "
                             "given, per-record timestamps become absolute")
    args = parser.parse_args()

    args.lat = coerce_float(args.sensor_lat, "--sensor-lat")
    args.lon = coerce_float(args.sensor_lon, "--sensor-lon")

    if args.stream:
        records = ble_parse.iter_records(sys.stdin)
    else:
        if not os.path.exists(args.input):
            sys.exit(f"ERROR: input file not found: {args.input}")
        records = ble_parse.parse_records(args.input)

    if args.out == "-":
        count = emit(records, sys.stdout, args)
    else:
        directory = os.path.dirname(os.path.abspath(args.out))
        if directory:
            os.makedirs(directory, exist_ok=True)
        with open(args.out, "w", encoding="utf-8") as handle:
            count = emit(records, handle, args)
        print(f"wrote {count} observations to {args.out}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
