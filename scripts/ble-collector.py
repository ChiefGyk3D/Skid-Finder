#!/usr/bin/env python3
"""Merge records from several sensors into one fleet view.

Each sensor emits the same records (ble-obs/1 per advertisement, ble-alert/1
per detector evaluation, sensor-status/1 heartbeats). This collector takes
them from an MQTT broker, from a directory nodes drop files into, or from
files after the fact, and keeps three things current:

  sensors     which nodes are alive, where they are, what they have seen
  identities  every device seen fleet-wide, keyed by identity_key so a unit
              observed by three sensors is one entry with three RSSI series,
              and a location estimate when at least two of those sensors
              have a fixed position
  alerts      the shared detector run over each sensor's recent window (so a
              node with no detector of its own, such as an ESP32, still gets
              judged), plus alerts the nodes report themselves, plus a fleet
              estimate of where a flood is coming from

Read this before trusting a location. The estimate is an RSSI-weighted
centroid of the sensors that hear the device: crude, robust, no calibration,
and no better than the sensor spacing. Indoors, multipath swings a single
reading by 20 dB, so the median over the window is used and the answer still
lies somewhere inside the polygon of contributing sensors. Every estimate
carries `spread_m`, the widest distance between the sensors that produced
it; treat that as the error bar. Only identities that persist across sensors
(tier strong or session) and continuous floods are estimated at all. A
model-tier identity seen by three sensors may be three people with the same
earbuds, and its "location" would be the middle of a crowd.

Examples:

  # Live, from a broker.
  ./scripts/ble-collector.py --mqtt --state logs/fleet-state.json \
      --alerts-out logs/fleet-alerts.jsonl

  # Live, from a directory the nodes rsync/syncthing their JSONL into.
  ./scripts/ble-collector.py --watch /srv/skidfinder/incoming --state logs/fleet-state.json

  # After the fact, from files.
  ./scripts/ble-collector.py --input logs/obs-*.jsonl --state logs/fleet-state.json
"""

import argparse
import collections
import glob
import json
import math
import os
import queue
import statistics
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ble_parse  # noqa: E402
import ble_signatures  # noqa: E402
from skid_conf import read_conf, setting, version  # noqa: E402

STATE_SCHEMA = "fleet-state/1"
FLEET_ALERT_SCHEMA = "fleet-alert/1"
CONF_KEYS = ("MQTT_HOST", "MQTT_PORT", "MQTT_TLS", "MQTT_TOPIC_PREFIX")
EARTH_RADIUS_M = 6371000.0
MAX_ADDRESSES = 50


def haversine_m(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dphi = p2 - p1
    dlmb = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dlmb / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def estimate_location(points):
    """RSSI-weighted centroid of (lat, lon, median_rssi) points.

    Weight is 10^((rssi+100)/20): a device at -40 dBm counts a thousand times
    a device at -100 dBm, which is roughly the inverse of free-space distance
    and keeps the estimate near the loudest sensor without any calibration.
    Returns (lat, lon, spread_m, n) or None when fewer than two points.
    """
    pts = [(lat, lon, rssi) for lat, lon, rssi in points
           if lat is not None and lon is not None and rssi is not None]
    if len(pts) < 2:
        return None
    weights = [10 ** ((rssi + 100.0) / 20.0) for _, _, rssi in pts]
    total = sum(weights)
    lat = sum(w * p[0] for w, p in zip(weights, pts)) / total
    lon = sum(w * p[1] for w, p in zip(weights, pts)) / total
    spread = 0.0
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            spread = max(spread, haversine_m(pts[i][0], pts[i][1], pts[j][0], pts[j][1]))
    return (round(lat, 6), round(lon, 6), round(spread, 1), len(pts))


def record_from_obs(event):
    return ble_parse.AdRecord(
        address=event.get("address", ""),
        addr_type=event.get("addr_type", "") or "",
        addr_class=event.get("addr_class", "unknown") or "unknown",
        timestamp=event.get("ts"),
        rssi=event.get("rssi"),
        tx_power=event.get("tx_power"),
        name=event.get("name", "") or "",
        flags=event.get("flags", "") or "",
        companies=list(event.get("companies", []) or []),
        service_uuids=list(event.get("service_uuids", []) or []),
    )


class Sensor:
    def __init__(self, sensor_id):
        self.id = sensor_id
        self.lat = None
        self.lon = None
        self.first_seen = None
        self.last_seen = None
        self.obs_count = 0
        self.alert_count = 0
        self.status = None
        self.last_node_alert = None
        self.window = collections.deque()  # (clock, AdRecord)
        self.last_matches = []
        self.last_stats = None

    def prune(self, cutoff):
        while self.window and self.window[0][0] < cutoff:
            self.window.popleft()

    def span(self):
        if len(self.window) < 2:
            return 0.0
        return self.window[-1][0] - self.window[0][0]


class Identity:
    def __init__(self, key):
        self.key = key
        self.tier = "model"
        self.name = ""
        self.addr_class = "unknown"
        self.first_seen = None
        self.last_seen = None
        self.count = 0
        self.addresses = set()
        self.per_sensor = {}  # sensor_id -> deque[(clock, rssi)]

    def prune(self, cutoff):
        for series in self.per_sensor.values():
            while series and series[0][0] < cutoff:
                series.popleft()


class Fleet:
    def __init__(self, cfg, window, relative_ok=False):
        self.cfg = cfg
        self.window = window
        self.sensors = {}
        self.identities = {}
        self.unknown = 0
        self.relative_warned = False
        self.relative_ok = relative_ok
        self.latest_clock = None
        self.started = time.time()

    # --- ingest ---------------------------------------------------------------
    def sensor(self, sensor_id):
        return self.sensors.setdefault(sensor_id, Sensor(sensor_id))

    def clock_for(self, event, arrival):
        ts = event.get("ts")
        if isinstance(ts, (int, float)) and (event.get("ts_absolute", True) or self.relative_ok):
            clock = float(ts)
        else:
            if isinstance(ts, (int, float)) and not self.relative_warned:
                sys.stderr.write("warn: a sensor sent capture-relative timestamps; using arrival "
                                 "time for it. Convert with --epoch-base so sensors line up.\n")
                self.relative_warned = True
            clock = arrival
        self.latest_clock = clock if self.latest_clock is None else max(self.latest_clock, clock)
        return clock

    def ingest(self, event, arrival=None):
        if not isinstance(event, dict):
            self.unknown += 1
            return
        arrival = time.time() if arrival is None else arrival
        schema = str(event.get("schema", ""))
        sensor_id = str(event.get("sensor_id") or "unknown")
        if schema.startswith("ble-obs/"):
            self.ingest_obs(event, sensor_id, arrival)
        elif schema.startswith("ble-alert/"):
            self.ingest_alert(event, sensor_id, arrival)
        elif schema.startswith("sensor-status/"):
            sensor = self.sensor(sensor_id)
            sensor.status = event
            sensor.last_seen = max(sensor.last_seen or 0, self.clock_for(event, arrival))
        else:
            self.unknown += 1

    def ingest_obs(self, event, sensor_id, arrival):
        if not event.get("address"):
            self.unknown += 1
            return
        clock = self.clock_for(event, arrival)
        sensor = self.sensor(sensor_id)
        if event.get("lat") is not None and event.get("lon") is not None:
            sensor.lat, sensor.lon = float(event["lat"]), float(event["lon"])
        sensor.first_seen = clock if sensor.first_seen is None else min(sensor.first_seen, clock)
        sensor.last_seen = clock if sensor.last_seen is None else max(sensor.last_seen, clock)
        sensor.obs_count += 1
        sensor.window.append((clock, record_from_obs(event)))

        key = str(event.get("identity_key") or ("addr:" + str(event["address"]).lower()))
        ident = self.identities.get(key)
        if ident is None:
            ident = self.identities[key] = Identity(key)
            ident.first_seen = clock
        ident.last_seen = clock if ident.last_seen is None else max(ident.last_seen, clock)
        ident.count += 1
        tier = str(event.get("tier") or "model")
        order = {"ambiguous": -1, "model": 0, "session": 1, "strong": 2}
        if order.get(tier, 0) > order.get(ident.tier, 0):
            ident.tier = tier
        if event.get("name") and not ident.name:
            ident.name = str(event["name"])
        if event.get("addr_class"):
            ident.addr_class = str(event["addr_class"])
        if len(ident.addresses) < MAX_ADDRESSES:
            ident.addresses.add(str(event["address"]).upper())
        rssi = event.get("rssi")
        if isinstance(rssi, (int, float)):
            ident.per_sensor.setdefault(sensor_id, collections.deque()).append((clock, float(rssi)))

    def ingest_alert(self, event, sensor_id, arrival):
        clock = self.clock_for(event, arrival)
        sensor = self.sensor(sensor_id)
        sensor.last_seen = clock if sensor.last_seen is None else max(sensor.last_seen, clock)
        sensor.alert_count += 1
        if event.get("matches"):
            sensor.last_node_alert = event

    # --- evaluate ---------------------------------------------------------------
    def prune(self, now):
        cutoff = now - self.window
        for sensor in self.sensors.values():
            sensor.prune(cutoff)
        for ident in self.identities.values():
            ident.prune(cutoff)

    def evaluate(self, now):
        """Prune to the window, run the detector per sensor, build the state."""
        self.prune(now)
        matching = []
        sensors_out = {}
        for sid, sensor in sorted(self.sensors.items()):
            records = [rec for _, rec in sensor.window]
            stats = ble_signatures.build_stats(records, duration=sensor.span()) if records else None
            matches = ble_signatures.evaluate(stats, self.cfg) if stats else []
            sensor.last_matches = matches
            sensor.last_stats = stats
            if matches:
                matching.append((sensor, stats, matches))
            sensors_out[sid] = {
                "lat": sensor.lat, "lon": sensor.lon,
                "first_seen": sensor.first_seen, "last_seen": sensor.last_seen,
                "age_sec": None if sensor.last_seen is None else round(now - sensor.last_seen, 1),
                "obs_total": sensor.obs_count, "alerts_total": sensor.alert_count,
                "window_events": stats.total_events if stats else 0,
                "window_rate": round(stats.event_rate, 2) if stats else 0.0,
                "window_unique_ratio": round(stats.unique_ratio, 3) if stats else 0.0,
                "matches": [{"name": m.name, "confidence": m.confidence, "evidence": m.evidence}
                            for m in matches],
                "node_alert": sensor.last_node_alert,
                "status": sensor.status,
            }

        identities_out = {}
        for key, ident in self.identities.items():
            series = {sid: [r for _, r in s] for sid, s in ident.per_sensor.items() if s}
            if not series:
                continue
            medians = {sid: statistics.median(vals) for sid, vals in series.items()}
            location = None
            if ident.tier in ("strong", "session"):
                points = []
                for sid, med in medians.items():
                    sensor = self.sensors.get(sid)
                    if sensor is not None:
                        points.append((sensor.lat, sensor.lon, med))
                location = estimate_location(points)
            identities_out[key] = {
                "tier": ident.tier, "name": ident.name, "addr_class": ident.addr_class,
                "first_seen": ident.first_seen, "last_seen": ident.last_seen,
                "count": ident.count, "addresses": sorted(ident.addresses)[:10],
                "sensors": {sid: {"median_rssi": round(m, 1), "samples": len(series[sid])}
                            for sid, m in medians.items()},
                "location": None if location is None else {
                    "lat": location[0], "lon": location[1], "spread_m": location[2],
                    "sensors": location[3],
                    "note": "RSSI-weighted centroid; the device is somewhere within spread_m "
                            "of this point, not at it",
                },
            }

        flood = None
        if matching:
            points = []
            for sensor, stats, _ in matching:
                # A flood's loudness at a sensor is its event rate there; map it
                # onto the RSSI scale the centroid expects (rate 1/s ~ -90, 100/s ~ -50).
                pseudo_rssi = -90.0 + 20.0 * math.log10(max(stats.event_rate, 1.0))
                points.append((sensor.lat, sensor.lon, pseudo_rssi))
            est = estimate_location(points)
            flood = {
                "sensors": [s.id for s, _, _ in matching],
                "loudest": max(matching, key=lambda t: t[1].event_rate)[0].id,
                "location": None if est is None else {
                    "lat": est[0], "lon": est[1], "spread_m": est[2], "sensors": est[3],
                    "note": "event-rate-weighted centroid of the sensors that see the flood",
                },
            }

        state = {
            "schema": STATE_SCHEMA,
            "ts": now,
            "collector_version": version(),
            "window_sec": self.window,
            "profile": self.cfg.profile,
            "sensors": sensors_out,
            "identities": identities_out,
            "flood": flood,
            "unknown_records": self.unknown,
        }
        alerts = []
        if matching:
            alerts.append({
                "schema": FLEET_ALERT_SCHEMA,
                "ts": now,
                "profile": self.cfg.profile,
                "sensors": {s.id: [{"name": m.name, "confidence": m.confidence} for m in ms]
                            for s, _, ms in matching},
                "flood": flood,
            })
        return state, alerts


# --- sources ---------------------------------------------------------------------
def parse_line(line):
    line = line.strip()
    if not line:
        return None
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    return record if isinstance(record, dict) else None


def read_files(paths):
    for path in paths:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                record = parse_line(line)
                if record is not None:
                    yield record


class DirectoryTail:
    """Follow every *.jsonl under a directory, including files that appear later."""

    def __init__(self, directory, from_now=False):
        self.directory = directory
        self.offsets = {}
        self.from_now = from_now
        self.primed = False

    def poll(self):
        paths = sorted(glob.glob(os.path.join(self.directory, "**", "*.jsonl"), recursive=True))
        if self.from_now and not self.primed:
            for path in paths:
                self.offsets[path] = os.path.getsize(path)
            self.primed = True
        for path in paths:
            try:
                with open(path, encoding="utf-8") as handle:
                    handle.seek(self.offsets.get(path, 0))
                    # readline, not 'for line in handle': iterating a text
                    # file disables tell(). A broad 'except OSError' here once
                    # hid exactly that, so every poll re-read every file.
                    while True:
                        line = handle.readline()
                        if not line:
                            break
                        if not line.endswith("\n"):
                            break
                        record = parse_line(line)
                        if record is not None:
                            yield record
                        self.offsets[path] = handle.tell()
            except FileNotFoundError:
                continue


def mqtt_source(host, port, tls, prefix, username, password, inbox):
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        sys.exit("ERROR: the paho MQTT client is not installed. "
                 "Install python3-paho-mqtt (apt) or 'pip install paho-mqtt'.")
    api = getattr(mqtt, "CallbackAPIVersion", None)
    client = mqtt.Client(api.VERSION2, client_id=f"skidfinder-collector-{os.getpid()}") \
        if api is not None else mqtt.Client(client_id=f"skidfinder-collector-{os.getpid()}")
    if username:
        client.username_pw_set(username, password or None)
    if tls:
        client.tls_set()

    def on_message(_client, _userdata, message):
        record = parse_line(message.payload.decode("utf-8", errors="replace")
                            if isinstance(message.payload, bytes) else str(message.payload))
        if record is not None:
            inbox.put((record, time.time()))

    def on_connect(_client, _userdata, *_args):
        for kind in ("obs", "alerts", "status"):
            client.subscribe(f"{prefix}/+/{kind}", qos=1)

    client.on_message = on_message
    client.on_connect = on_connect
    client.connect(host, port, keepalive=60)
    client.loop_start()
    return client


# --- outputs ------------------------------------------------------------------------
def write_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(state, handle, sort_keys=True, indent=1)
    os.replace(tmp, path)


def summarize(state, alerts, out):
    stamp = time.strftime("%H:%M:%S", time.localtime(state["ts"]))
    sensors = state["sensors"]
    alive = sum(1 for s in sensors.values() if s["age_sec"] is not None and s["age_sec"] <= 120)
    located = sum(1 for i in state["identities"].values() if i["location"])
    out.write(f"[{stamp}] sensors={len(sensors)} alive={alive} identities={len(state['identities'])} "
              f"located={located} matching={len(state['flood']['sensors']) if state['flood'] else 0}\n")
    for sid, s in sensors.items():
        for m in s["matches"]:
            out.write(f"  ALERT {sid}: {m['name']} confidence={m['confidence']}%\n")
    if state["flood"] and state["flood"]["location"]:
        loc = state["flood"]["location"]
        out.write(f"  flood near {loc['lat']},{loc['lon']} (spread {loc['spread_m']} m, "
                  f"loudest sensor {state['flood']['loudest']})\n")
    elif state["flood"]:
        out.write(f"  flood seen by {', '.join(state['flood']['sensors'])}; no positions to place it\n")
    out.flush()


def emit(fleet, now, args, alerts_handle):
    state, alerts = fleet.evaluate(now)
    if args.state:
        write_state(args.state, state)
    if alerts_handle is not None:
        for alert in alerts:
            alerts_handle.write(json.dumps(alert, sort_keys=True) + "\n")
        alerts_handle.flush()
    if not args.quiet:
        summarize(state, alerts, sys.stdout)
    return state, alerts


def main() -> int:
    conf = read_conf(CONF_KEYS)
    parser = argparse.ArgumentParser(description="Merge Skid Finder records from several sensors")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--input", nargs="+", metavar="FILE", help="JSONL files; process and exit")
    src.add_argument("--watch", metavar="DIR", help="follow every *.jsonl under DIR")
    src.add_argument("--mqtt", action="store_true", help="subscribe to the broker in config")
    parser.add_argument("--host", default=setting("MQTT_HOST", conf))
    parser.add_argument("--port", type=int, default=int(setting("MQTT_PORT", conf, "1883")))
    parser.add_argument("--tls", action="store_true",
                        default=str(setting("MQTT_TLS", conf, "no")).lower() in ("1", "true", "yes", "on"))
    parser.add_argument("--prefix", default=setting("MQTT_TOPIC_PREFIX", conf, "skidfinder"))
    parser.add_argument("--window", type=float, default=30.0, help="sliding window seconds (default 30)")
    parser.add_argument("--interval", type=float, default=5.0, help="seconds between evaluations")
    parser.add_argument("--profile", default="balanced", choices=["conservative", "balanced", "aggressive"])
    parser.add_argument("--config", default=ble_signatures.config_path_default())
    parser.add_argument("--state", help="write the fleet-state/1 snapshot here after each evaluation")
    parser.add_argument("--alerts-out", help="append fleet-alert/1 records here")
    parser.add_argument("--from-now", action="store_true",
                        help="with --watch: ignore what is already in the files")
    parser.add_argument("--relative-ok", action="store_true",
                        help="treat capture-relative timestamps as a shared timeline (single-capture replay)")
    parser.add_argument("--quiet", action="store_true")
    parser.add_argument("--max-evals", type=int, default=0,
                        help="stop after this many evaluations (0 = run until interrupted; for tests)")
    args = parser.parse_args()

    cfg = ble_signatures.load_config(args.profile, args.config)
    fleet = Fleet(cfg, args.window, relative_ok=args.relative_ok)
    alerts_handle = open(args.alerts_out, "a", encoding="utf-8") if args.alerts_out else None
    if args.state:
        directory = os.path.dirname(os.path.abspath(args.state))
        os.makedirs(directory, exist_ok=True)

    try:
        if args.input:
            # Replay on the records' own timeline, evaluating every --interval of
            # record time, so alerts land when they happened rather than only at
            # the end.
            records = sorted(read_files(args.input),
                             key=lambda r: r.get("ts") if isinstance(r.get("ts"), (int, float)) else 0)
            next_eval = None
            evals = 0
            for record in records:
                fleet.ingest(record, arrival=record.get("ts") if isinstance(record.get("ts"), (int, float)) else 0.0)
                now = fleet.latest_clock or 0.0
                if next_eval is None:
                    next_eval = now + args.interval
                while now >= next_eval:
                    emit(fleet, next_eval, args, alerts_handle)
                    evals += 1
                    next_eval += args.interval
            emit(fleet, fleet.latest_clock or time.time(), args, alerts_handle)
            return 0

        inbox = queue.Queue()
        client = None
        tail = None
        if args.mqtt:
            if not args.host:
                sys.exit("ERROR: no broker. Set MQTT_HOST in config/interfaces.conf or pass --host.")
            client = mqtt_source(args.host, args.port, args.tls, args.prefix,
                                 os.environ.get("MQTT_USERNAME", ""), os.environ.get("MQTT_PASSWORD", ""),
                                 inbox)
            sys.stderr.write(f"collecting from {args.host}:{args.port} prefix={args.prefix}\n")
        else:
            tail = DirectoryTail(args.watch, from_now=args.from_now)
            sys.stderr.write(f"collecting from {args.watch}\n")

        evals = 0
        last_eval = time.monotonic()
        while True:
            if tail is not None:
                for record in tail.poll():
                    fleet.ingest(record)
            while True:
                try:
                    record, arrival = inbox.get_nowait()
                except queue.Empty:
                    break
                fleet.ingest(record, arrival)
            if time.monotonic() - last_eval >= args.interval:
                emit(fleet, time.time(), args, alerts_handle)
                last_eval = time.monotonic()
                evals += 1
                if args.max_evals and evals >= args.max_evals:
                    break
            time.sleep(min(0.5, args.interval))
        if client is not None:
            client.loop_stop()
            client.disconnect()
    except KeyboardInterrupt:
        pass
    finally:
        if alerts_handle is not None:
            alerts_handle.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
