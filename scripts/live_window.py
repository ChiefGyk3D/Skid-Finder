"""The sliding-window loop every live alerter shares.

ble-live-alert.py and wifi-live-alert.py read a JSONL observation stream,
keep a window of recent records on the observations' own timeline, run a
detector over it on a fixed cadence, print a status line and any matches,
and write one alert record per evaluation. Only the record type, the
detector and the wording differ, so the loop lives here once and a third
modality (LoRa, 802.15.4) adds a small adapter rather than a fourth copy.

Two choices the loop makes, unchanged from the originals:

* The window slides over each observation's own timestamp when the stream
  carries one, falling back to wall-clock arrival only when it does not.
  That keeps a fast replay of a recorded capture judgeable (arrival time
  would collapse it into one instant) and is right for a live feed too.
* Evaluation cadence is wall-clock: every `interval` seconds while lines
  arrive, plus a final pass over whatever remains so a short piped capture
  still produces a verdict.
"""

import collections
import json
import sys
import time


class Modality:
    """What a live alerter needs to know about its modality.

    schema_prefix   observation schema prefix to accept ("ble-obs/")
    alert_schema    schema written on alert records ("ble-alert/1")
    name            "ble" / "wifi", stamped on alert records
    from_event      JSON observation -> the record the detector consumes
    build_stats     records, duration -> stats (the detector's own)
    evaluate        stats, cfg -> [matches with .name .confidence .evidence]
    status_line     stats -> the per-evaluation text before "matches=N"
    alert_fields    stats -> extra fields for the alert record
    """

    def __init__(self, schema_prefix, alert_schema, name, from_event, build_stats,
                 evaluate, status_line, alert_fields):
        self.schema_prefix = schema_prefix
        self.alert_schema = alert_schema
        self.name = name
        self.from_event = from_event
        self.build_stats = build_stats
        self.evaluate = evaluate
        self.status_line = status_line
        self.alert_fields = alert_fields


def event_clock(event, arrival):
    ts = event.get("ts")
    if isinstance(ts, (int, float)):
        return float(ts)
    return arrival


def report(modality, window, cfg, window_seconds, out, jsonl=None, sensor_id=""):
    """Evaluate the current window; print status and matches; write the alert record."""
    records = [rec for _, rec in window]
    stats = modality.build_stats(records, duration=window_seconds)
    matches = modality.evaluate(stats, cfg)

    stamp = time.strftime("%H:%M:%S")
    out.write(f"[{stamp}] window={window_seconds:.0f}s {modality.status_line(stats)} "
              f"matches={len(matches)}\n")
    for match in matches:
        out.write(f"  ALERT {match.name} confidence={match.confidence}% :: {match.evidence}\n")
    out.flush()

    if jsonl is not None:
        record = {
            "schema": modality.alert_schema,
            "ts": time.time(),
            "sensor_id": sensor_id,
            "modality": modality.name,
            "profile": cfg.profile,
            "window_sec": round(window_seconds, 3),
            "matches": [{"name": m.name, "confidence": m.confidence, "evidence": m.evidence}
                        for m in matches],
        }
        record.update(modality.alert_fields(stats))
        jsonl.write(json.dumps(record, sort_keys=True) + "\n")
        jsonl.flush()
    return matches


def run(modality, cfg, source, out, window_seconds, interval, jsonl=None, sensor_id=""):
    """Drive the loop over `source` (an iterable of JSONL lines). Returns skipped-line count."""
    window = collections.deque()
    latest = None
    last_eval = time.monotonic()
    skipped = 0

    def span():
        return 0.0 if len(window) < 2 else window[-1][0] - window[0][0]

    try:
        for line in source:
            line = line.strip()
            if line:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    skipped += 1
                    continue
                if str(event.get("schema", "")).startswith(modality.schema_prefix) and event.get("address"):
                    if not sensor_id and event.get("sensor_id"):
                        sensor_id = str(event["sensor_id"])
                    clock = event_clock(event, time.monotonic())
                    latest = clock if latest is None else max(latest, clock)
                    window.append((clock, modality.from_event(event)))
                    cutoff = latest - window_seconds
                    while window and window[0][0] < cutoff:
                        window.popleft()
            now = time.monotonic()
            if now - last_eval >= interval:
                report(modality, window, cfg, span(), out, jsonl, sensor_id)
                last_eval = now
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        return skipped

    if window:
        report(modality, window, cfg, span(), out, jsonl, sensor_id)
    return skipped


def main_for(modality, load_config, config_default, description):
    """A complete main() for a live alerter: the shared argument set and loop."""
    import argparse
    import os

    parser = argparse.ArgumentParser(description=description)
    parser.add_argument("--window", type=float, default=30.0,
                        help="sliding window length in seconds (default: 30)")
    parser.add_argument("--interval", type=float, default=5.0,
                        help="seconds between evaluations (default: 5)")
    parser.add_argument("--profile", default="balanced",
                        choices=["conservative", "balanced", "aggressive"])
    parser.add_argument("--config", default=config_default(),
                        help="optional signatures config file path")
    parser.add_argument("--input", default="-",
                        help="JSONL observation stream to read, or '-' for stdin")
    parser.add_argument("--jsonl-out", default=None,
                        help="append one alert record per evaluation to this file "
                             "(the machine-readable record for a SIEM or collector)")
    parser.add_argument("--sensor-id", default=os.environ.get("SENSOR_ID", ""),
                        help="sensor id to stamp on alert records; defaults to the one "
                             "carried by the observation stream")
    args = parser.parse_args()

    cfg = load_config(args.profile, args.config)
    source = sys.stdin if args.input == "-" else open(args.input, encoding="utf-8")
    jsonl = None
    if args.jsonl_out:
        directory = os.path.dirname(os.path.abspath(args.jsonl_out))
        if directory:
            os.makedirs(directory, exist_ok=True)
        jsonl = open(args.jsonl_out, "a", encoding="utf-8")

    sys.stderr.write(f"{modality.name} live alerting: profile={cfg.profile} window={args.window:.0f}s "
                     f"interval={args.interval:.0f}s (config_source={cfg.source})\n")
    sys.stderr.flush()
    try:
        skipped = run(modality, cfg, source, sys.stdout, args.window, args.interval, jsonl, args.sensor_id)
    finally:
        if source is not sys.stdin:
            source.close()
        if jsonl is not None:
            jsonl.close()
    if skipped:
        sys.stderr.write(f"note: skipped {skipped} unparseable line(s)\n")
    return 0
