#!/usr/bin/env python3
"""Emit normalized Wi-Fi observations as JSON Lines (schema wifi-obs/1).

The Wi-Fi counterpart of ble-observe.py. Each management frame becomes one
flat record with the same envelope as ble-obs/1 (schema, ts, sensor_id,
lat/lon, modality, address, tier, identity_key, rssi, name), so the
collector, the publisher and a SIEM handle both modalities with one set of
fields, plus the Wi-Fi specifics: frame kind, bssid, da, ssid, channel and
reason code.

Identity comes from wifi_identity: a globally administered MAC is tier
strong; a randomised MAC on a probe request or a beacon is keyed by its
content fingerprint (tag order, rates, HT capabilities, vendor OUIs) at
tier model, which identifies a product or a tool rather than a unit; a
randomised MAC on any other frame is tier session.

Timestamps are absolute: tshark's frame.time_epoch already is, so there is
no --epoch-base here.
"""

import argparse
import os
import sys
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wifi_parse  # noqa: E402
from skid_conf import read_conf, setting  # noqa: E402
from wifi_identity import fingerprint, has_content, identity_key  # noqa: E402

SCHEMA = "wifi-obs/1"
CONF_KEYS = ("SENSOR_ID", "SENSOR_LAT", "SENSOR_LON")


def to_event(frame, sensor_id, lat, lon):
    key, tier = identity_key(frame)
    return {
        "schema": SCHEMA,
        "ts": frame.timestamp,
        "ts_absolute": frame.timestamp is not None,
        "sensor_id": sensor_id,
        "lat": lat,
        "lon": lon,
        "modality": "wifi",
        "address": frame.sa or frame.bssid,
        "addr_class": "random" if frame.sa_random else "public",
        "tier": tier,
        "identity_key": key,
        "rssi": frame.rssi,
        "name": frame.ssid,
        "frame": frame.kind,
        "subtype": frame.subtype,
        "bssid": frame.bssid,
        "da": frame.da,
        "channel": frame.channel,
        "reason": frame.reason,
        "fingerprint": fingerprint(frame) if has_content(frame) else "",
        "tags": ",".join(str(t) for t in frame.tags),
        "vendor_ouis": sorted(set(frame.vendor_ouis)),
    }


def coerce_float(value, name):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except ValueError:
        sys.exit(f"ERROR: {name} must be a number, got {value!r}")


def emit(frames, handle, args):
    count = 0
    for frame in frames:
        handle.write(json.dumps(to_event(frame, args.sensor_id, args.lat, args.lon), sort_keys=True) + "\n")
        if args.stream:
            handle.flush()
        count += 1
    return count


def main() -> int:
    conf = read_conf(CONF_KEYS)
    parser = argparse.ArgumentParser(description="Emit normalized Wi-Fi observations as JSON Lines")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--input", help="tshark field extract (.tsv) to convert")
    src.add_argument("--stream", action="store_true", help="read tshark field lines from stdin, emit live")
    parser.add_argument("--out", default="-")
    parser.add_argument("--sensor-id", default=setting("SENSOR_ID", conf, "unknown"))
    parser.add_argument("--sensor-lat", default=setting("SENSOR_LAT", conf))
    parser.add_argument("--sensor-lon", default=setting("SENSOR_LON", conf))
    args = parser.parse_args()
    args.lat = coerce_float(args.sensor_lat, "--sensor-lat")
    args.lon = coerce_float(args.sensor_lon, "--sensor-lon")

    if args.stream:
        frames = wifi_parse.iter_frames(sys.stdin)
    else:
        if not os.path.exists(args.input):
            sys.exit(f"ERROR: input file not found: {args.input}")
        frames = wifi_parse.parse_frames(args.input)

    try:
        if args.out == "-":
            count = emit(frames, sys.stdout, args)
        else:
            directory = os.path.dirname(os.path.abspath(args.out))
            if directory:
                os.makedirs(directory, exist_ok=True)
            with open(args.out, "w", encoding="utf-8") as handle:
                count = emit(frames, handle, args)
            print(f"wrote {count} observations to {args.out}", file=sys.stderr)
    except KeyboardInterrupt:
        return 0
    except BrokenPipeError:
        try:
            sys.stdout.close()
        except OSError:
            pass
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
