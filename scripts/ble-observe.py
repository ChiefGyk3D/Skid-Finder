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
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ble_parse  # noqa: E402
from ble_identity import identity_key  # noqa: E402

SCHEMA = "ble-obs/1"

# Sensor identity settings read from config/interfaces.conf when neither the
# command line nor the environment supplies them. The README tells operators
# to set these in the config file, and every shell script parses that file
# through lib.sh; this tool is Python, so it reads the same three keys itself
# rather than silently defaulting to "unknown".
CONF_KEYS = ("SENSOR_ID", "SENSOR_LAT", "SENSOR_LON")
QUOTED_RE = re.compile(r"""^"([^"]*)"|^'([^']*)'""")


def read_sensor_conf(path):
    """Return {KEY: value} for the sensor keys in a KEY=value config file.

    Mirrors lib.sh: the file is data, never executed; quoted values keep
    their contents, unquoted values lose a trailing '# comment'.
    """
    found = {}
    try:
        with open(path, encoding="utf-8") as handle:
            for raw in handle:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                key, sep, value = line.partition("=")
                key = key.strip()
                if not sep or key not in CONF_KEYS:
                    continue
                value = value.strip()
                # Same rules as lib.sh: a quoted value keeps its contents and
                # drops whatever follows the closing quote; an unquoted value
                # is cut at the first '#'.
                quoted = QUOTED_RE.match(value)
                if quoted:
                    value = quoted.group(1) or quoted.group(2) or ""
                else:
                    value = value.split("#", 1)[0].strip()
                found[key] = value
    except OSError:
        pass
    return found


def sensor_default(name, conf):
    """Precedence: environment, then config/interfaces.conf, then empty."""
    value = os.environ.get(name)
    if value is None or value == "":
        value = conf.get(name, "")
    return value


def to_event(record, sensor_id, lat, lon, epoch_base):
    key, tier = identity_key(record)

    ts = record.timestamp
    ts_absolute = False
    if ts is not None and epoch_base is not None:
        # btmon timestamps are offsets from its first packet. Adding a known
        # base (the capture's wall-clock start) turns them into absolute epoch
        # time, which is what a multi-sensor collector needs to line events up.
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
        if args.epoch_base == "now" and record.timestamp is not None:
            # Live mode: pin the base to the first advert's arrival. btmon's
            # offsets count from its first packet, so wall-clock-now minus that
            # offset is the base, accurate to pipe latency rather than to the
            # seconds it took to bring the scan up.
            args.epoch_base = time.time() - record.timestamp
        base = args.epoch_base if isinstance(args.epoch_base, float) else None
        event = to_event(record, args.sensor_id, args.lat, args.lon, base)
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


def parse_epoch_base(value):
    if value is None:
        return None
    if value == "now":
        return "now"
    try:
        return float(value)
    except ValueError:
        sys.exit(f"ERROR: --epoch-base must be a number or 'now', got {value!r}")


def main() -> int:
    conf_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                             "config", "interfaces.conf")
    conf = read_sensor_conf(conf_path)

    parser = argparse.ArgumentParser(description="Emit normalized BLE observations as JSON Lines")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--input", help="btmon text capture to convert")
    src.add_argument("--stream", action="store_true",
                     help="read btmon text from stdin and emit live")
    parser.add_argument("--out", default="-",
                        help="output JSONL path, or '-' for stdout (default)")
    parser.add_argument("--sensor-id", default=sensor_default("SENSOR_ID", conf) or "unknown",
                        help="identifier for this sensor (default: $SENSOR_ID, then "
                             "SENSOR_ID in config/interfaces.conf, then 'unknown')")
    parser.add_argument("--sensor-lat", default=sensor_default("SENSOR_LAT", conf),
                        help="sensor latitude in decimal degrees (stationary sensors)")
    parser.add_argument("--sensor-lon", default=sensor_default("SENSOR_LON", conf),
                        help="sensor longitude in decimal degrees (stationary sensors)")
    parser.add_argument("--epoch-base", default=None,
                        help="wall-clock epoch seconds of the capture start, or 'now' "
                             "to pin it to the first advert's arrival in --stream mode; "
                             "when given, per-record timestamps become absolute")
    args = parser.parse_args()

    args.lat = coerce_float(args.sensor_lat, "--sensor-lat")
    args.lon = coerce_float(args.sensor_lon, "--sensor-lon")
    args.epoch_base = parse_epoch_base(args.epoch_base)

    if args.stream:
        records = ble_parse.iter_records(sys.stdin)
    else:
        if not os.path.exists(args.input):
            sys.exit(f"ERROR: input file not found: {args.input}")
        records = ble_parse.parse_records(args.input)

    try:
        if args.out == "-":
            count = emit(records, sys.stdout, args)
        else:
            directory = os.path.dirname(os.path.abspath(args.out))
            if directory:
                os.makedirs(directory, exist_ok=True)
            with open(args.out, "w", encoding="utf-8") as handle:
                count = emit(records, handle, args)
            print(f"wrote {count} observations to {args.out}", file=sys.stderr)
    except KeyboardInterrupt:
        # Ctrl+C on a live pipeline is the normal way to stop; not a traceback.
        return 0
    except BrokenPipeError:
        # The consumer went away (alerter stopped, pager closed). Also normal.
        try:
            sys.stdout.close()
        except OSError:
            pass
        return 0

    return 0


if __name__ == "__main__":
    sys.exit(main())
