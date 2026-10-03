#!/usr/bin/env python3
"""Publish Skid Finder records to an MQTT broker.

A sensor writes JSON Lines locally (logs/obs-*.jsonl, logs/alerts-*.jsonl)
and this tool ships them: one MQTT message per record, payload verbatim, on a
topic derived from the record's schema and sensor id:

  <prefix>/<sensor_id>/obs      ble-obs/*    one per advertisement
  <prefix>/<sensor_id>/alerts   ble-alert/*  one per detector evaluation
  <prefix>/<sensor_id>/status   sensor-status/1, retained, the heartbeat

The local file stays the record of truth; MQTT is the transport. If the
broker is unreachable the sensor keeps capturing, and the file can be
published later with --input. That is why publishing is a separate process
that tails files rather than a step inside the capture pipeline.

Settings come from config/interfaces.conf (MQTT_HOST, MQTT_PORT, MQTT_TLS,
MQTT_TOPIC_PREFIX) or the environment, which overrides the file. Credentials
are environment-only: MQTT_USERNAME and MQTT_PASSWORD. Nothing here ever
writes a secret to disk.

Examples:

  # Follow a live run's files and heartbeat every 30 s.
  ./scripts/ble-publish.py --follow logs/obs-hci0-*.jsonl logs/alerts-hci0-*.jsonl

  # Ship a finished capture after the fact.
  ./scripts/ble-publish.py --input logs/obs-hci0-20260918-120000.jsonl

Requires python3-paho-mqtt (apt) or 'pip install paho-mqtt'.
"""

import argparse
import json
import os
import socket
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from skid_conf import read_conf, setting, version  # noqa: E402

CONF_KEYS = ("SENSOR_ID", "MQTT_HOST", "MQTT_PORT", "MQTT_TLS", "MQTT_TOPIC_PREFIX")
STATUS_SCHEMA = "sensor-status/1"


def load_paho():
    try:
        import paho.mqtt.client as mqtt
    except ImportError:
        sys.exit("ERROR: the paho MQTT client is not installed. "
                 "Install python3-paho-mqtt (apt) or 'pip install paho-mqtt'.")
    return mqtt


def make_client(mqtt, client_id):
    """Construct a client on whichever callback API this paho supports."""
    api = getattr(mqtt, "CallbackAPIVersion", None)
    if api is not None:
        return mqtt.Client(api.VERSION2, client_id=client_id)
    return mqtt.Client(client_id=client_id)


def topic_for(prefix, record, default_sensor):
    schema = str(record.get("schema", ""))
    sensor = str(record.get("sensor_id") or default_sensor or "unknown")
    if schema.startswith("ble-obs/") or schema.startswith("wifi-obs/"):
        kind = "obs"
    elif schema.startswith("ble-alert/") or schema.startswith("wifi-alert/"):
        kind = "alerts"
    elif schema.startswith("sensor-status/"):
        kind = "status"
    else:
        return None, sensor
    return f"{prefix}/{sensor}/{kind}", sensor


def truthy(value):
    return str(value).strip().lower() in ("1", "true", "yes", "on")


class Publisher:
    def __init__(self, mqtt, host, port, tls, username, password, prefix, sensor_id):
        self.mqtt = mqtt
        self.prefix = prefix
        self.sensor_id = sensor_id
        self.published = 0
        self.skipped = 0
        self.started = time.time()
        client_id = f"skidfinder-{sensor_id}-{socket.gethostname()}-{os.getpid()}"
        self.client = make_client(mqtt, client_id)
        if username:
            self.client.username_pw_set(username, password or None)
        if tls:
            self.client.tls_set()
        # Last will: the broker clears the retained heartbeat if we vanish, so a
        # collector sees a dead sensor as dead rather than as its last status.
        self.client.will_set(f"{prefix}/{sensor_id}/status", payload="", retain=True)
        self.client.connect(host, port, keepalive=60)
        self.client.loop_start()

    def publish_record(self, record):
        topic, _ = topic_for(self.prefix, record, self.sensor_id)
        if topic is None:
            self.skipped += 1
            return
        retain = topic.endswith("/status")
        info = self.client.publish(topic, json.dumps(record, sort_keys=True), qos=1, retain=retain)
        self.published += 1
        return info

    def heartbeat(self, extra=None):
        record = {
            "schema": STATUS_SCHEMA,
            "ts": time.time(),
            "sensor_id": self.sensor_id,
            "version": version(),
            "uptime_sec": round(time.time() - self.started, 1),
            "published": self.published,
        }
        if extra:
            record.update(extra)
        return self.publish_record(record)

    def close(self):
        try:
            self.client.loop_stop()
            self.client.disconnect()
        except Exception:  # noqa: BLE001 - shutting down; nothing to do about it
            pass


def parse_line(line):
    line = line.strip()
    if not line:
        return None
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        return None
    return record if isinstance(record, dict) else None


def follow(paths, publisher, heartbeat_every, poll, once=False):
    """Tail the given files, publishing new lines as they appear.

    Files that do not exist yet are retried each poll, so the publisher can be
    started before the capture that creates them.
    """
    offsets = {}
    last_beat = 0.0
    while True:
        for path in paths:
            try:
                with open(path, encoding="utf-8") as handle:
                    handle.seek(offsets.get(path, 0))
                    # readline, not 'for line in handle': iterating a text
                    # file disables tell(), and the offset is the whole point.
                    while True:
                        line = handle.readline()
                        if not line:
                            break
                        if not line.endswith("\n"):
                            # A partial line is still being written; re-read it next time.
                            break
                        record = parse_line(line)
                        if record is not None:
                            publisher.publish_record(record)
                        offsets[path] = handle.tell()
            except FileNotFoundError:
                continue
        now = time.time()
        if heartbeat_every and now - last_beat >= heartbeat_every:
            publisher.heartbeat({"following": [os.path.basename(p) for p in paths]})
            last_beat = now
        if once:
            return
        time.sleep(poll)


def main() -> int:
    conf = read_conf(CONF_KEYS)
    parser = argparse.ArgumentParser(description="Publish Skid Finder JSONL records to MQTT")
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--follow", nargs="+", metavar="FILE",
                     help="tail these JSONL files and publish new records until interrupted")
    src.add_argument("--input", nargs="+", metavar="FILE",
                     help="publish every record in these files, then exit")
    parser.add_argument("--host", default=setting("MQTT_HOST", conf))
    parser.add_argument("--port", type=int, default=int(setting("MQTT_PORT", conf, "1883")))
    parser.add_argument("--tls", action="store_true", default=truthy(setting("MQTT_TLS", conf, "no")))
    parser.add_argument("--prefix", default=setting("MQTT_TOPIC_PREFIX", conf, "skidfinder"))
    parser.add_argument("--sensor-id", default=setting("SENSOR_ID", conf, "unknown"))
    parser.add_argument("--heartbeat", type=float, default=30.0,
                        help="seconds between retained status messages when following (0 = none)")
    parser.add_argument("--poll", type=float, default=0.5, help="seconds between file polls")
    parser.add_argument("--once", action="store_true",
                        help="with --follow: one pass over the files, then exit (for tests)")
    args = parser.parse_args()

    if not args.host:
        sys.exit("ERROR: no broker. Set MQTT_HOST in config/interfaces.conf or pass --host.")

    mqtt = load_paho()
    publisher = Publisher(mqtt, args.host, args.port, args.tls,
                          os.environ.get("MQTT_USERNAME", ""), os.environ.get("MQTT_PASSWORD", ""),
                          args.prefix, args.sensor_id)
    sys.stderr.write(f"publishing to {args.host}:{args.port} prefix={args.prefix} "
                     f"sensor={args.sensor_id} tls={'yes' if args.tls else 'no'}\n")
    try:
        if args.input:
            last = None
            for path in args.input:
                with open(path, encoding="utf-8") as handle:
                    for line in handle:
                        record = parse_line(line)
                        if record is not None:
                            last = publisher.publish_record(record)
            if last is not None and hasattr(last, "wait_for_publish"):
                last.wait_for_publish(timeout=10)
        else:
            follow(args.follow, publisher, args.heartbeat, args.poll, once=args.once)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stderr.write(f"published {publisher.published} record(s), skipped {publisher.skipped}\n")
        publisher.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
