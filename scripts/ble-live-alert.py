#!/usr/bin/env python3
"""Alert on BLE spam live, from a normalized observation stream.

The batch scanner judges a capture only after it finishes. In the field you
want to know a flood is happening while it is happening, which is what this
does: it reads the JSONL stream from ble-observe.py, keeps a sliding window of
the most recent observations, and runs the exact same signature detector
(ble_signatures) over that window on a fixed cadence.

Two deliberate choices:

* The window slides over each observation's own timestamp when the stream
  carries one, falling back to wall-clock arrival time only when it does not.
  btmon timestamps advance in real time, so this is correct for a live feed and
  also correct when a recorded capture is replayed through the pipe faster than
  real time (where wall-clock arrival would collapse the whole capture into one
  instant and the detector would never see a judgeable window).

* Detection reuses ble_signatures.evaluate unchanged. The whole reason the
  detector was split into a module is so the live path and the batch path can
  never disagree about what counts as spam. A threshold tuned in
  config/signatures.conf takes effect in both.

Because the window is short, prefer the 'balanced' or 'aggressive' profile
here; 'conservative' may never accumulate enough in a 30s window to fire.

Example:

  sudo btmon -i hci0 \
    | ./scripts/ble-observe.py --stream --sensor-id uconsole-01 \
    | ./scripts/ble-live-alert.py --window 30 --interval 5 --profile balanced
"""

import argparse
import collections
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ble_parse  # noqa: E402
import ble_signatures  # noqa: E402


def record_from_event(event):
    """Rebuild the minimal AdRecord the detector's statistics need.

    Only the fields Stats.add() reads are required; data the signature detector
    does not use (data length, PDU type) is left at its default.
    """
    return ble_parse.AdRecord(
        address=event.get("address", ""),
        addr_type=event.get("addr_type", ""),
        addr_class=event.get("addr_class", "unknown"),
        timestamp=event.get("ts"),
        rssi=event.get("rssi"),
        tx_power=event.get("tx_power"),
        name=event.get("name", "") or "",
        flags=event.get("flags", "") or "",
        companies=list(event.get("companies", []) or []),
        service_uuids=list(event.get("service_uuids", []) or []),
    )


def event_clock(event, arrival):
    """Pick the timeline this observation sits on.

    A stream is consistent within itself: either every event carries a
    timestamp or none do. Using the event's own timestamp keeps windowing
    correct under fast replay; wall-clock arrival is the fallback for a stream
    without timestamps.
    """
    ts = event.get("ts")
    if isinstance(ts, (int, float)):
        return float(ts)
    return arrival


ALERT_SCHEMA = "ble-alert/1"


def report(window, cfg, window_seconds, out, jsonl=None, sensor_id=""):
    """Evaluate the current window and print status plus any matches.

    When a JSONL handle is given, every evaluation is also written there as
    one 'ble-alert/1' object: the window statistics and the list of matches.
    The text on stdout is for the operator; the JSONL is the record a SIEM or
    collector ingests, so it is written whether or not anything matched. A
    quiet window is evidence too, and a stream of them is what shows a sensor
    is alive.
    """
    records = [rec for _, rec in window]
    stats = ble_signatures.build_stats(records, duration=window_seconds)
    matches = ble_signatures.evaluate(stats, cfg)

    stamp = time.strftime("%H:%M:%S")
    out.write(
        f"[{stamp}] window={window_seconds:.0f}s events={stats.total_events} "
        f"rate={stats.event_rate:.1f}/s uniq_ratio={stats.unique_ratio:.2f} "
        f"singleton={stats.singleton_ratio:.2f} matches={len(matches)}\n"
    )
    for match in matches:
        out.write(f"  ALERT {match.name} confidence={match.confidence}% :: {match.evidence}\n")
    out.flush()

    if jsonl is not None:
        event = {
            "schema": ALERT_SCHEMA,
            "ts": time.time(),
            "sensor_id": sensor_id,
            "modality": "ble",
            "profile": cfg.profile,
            "window_sec": round(window_seconds, 3),
            "events": stats.total_events,
            "unique_addrs": len(stats.unique_addrs),
            "event_rate": round(stats.event_rate, 3),
            "unique_ratio": round(stats.unique_ratio, 3),
            "singleton_ratio": round(stats.singleton_ratio, 3),
            "matches": [
                {"name": m.name, "confidence": m.confidence, "evidence": m.evidence}
                for m in matches
            ],
        }
        jsonl.write(json.dumps(event, sort_keys=True) + "\n")
        jsonl.flush()
    return matches


def main() -> int:
    parser = argparse.ArgumentParser(description="Alert on BLE spam from a live observation stream")
    parser.add_argument("--window", type=float, default=30.0,
                        help="sliding window length in seconds (default: 30)")
    parser.add_argument("--interval", type=float, default=5.0,
                        help="seconds between evaluations (default: 5)")
    parser.add_argument("--profile", default="balanced",
                        choices=["conservative", "balanced", "aggressive"])
    parser.add_argument("--config", default=ble_signatures.config_path_default(),
                        help="optional signatures config file path")
    parser.add_argument("--input", default="-",
                        help="JSONL observation stream to read, or '-' for stdin")
    parser.add_argument("--jsonl-out", default=None,
                        help="append one ble-alert/1 JSON object per evaluation to this "
                             "file (the machine-readable record for a SIEM or collector)")
    parser.add_argument("--sensor-id", default=os.environ.get("SENSOR_ID", ""),
                        help="sensor id to stamp on alert records; defaults to the one "
                             "carried by the observation stream")
    args = parser.parse_args()

    cfg = ble_signatures.load_config(args.profile, args.config)

    source = sys.stdin if args.input == "-" else open(args.input, encoding="utf-8")
    jsonl = None
    if args.jsonl_out:
        directory = os.path.dirname(os.path.abspath(args.jsonl_out))
        if directory:
            os.makedirs(directory, exist_ok=True)
        jsonl = open(args.jsonl_out, "a", encoding="utf-8")
    sensor_id = args.sensor_id
    window = collections.deque()
    latest_clock = None
    last_eval = time.monotonic()
    skipped = 0

    sys.stderr.write(
        f"live alerting: profile={cfg.profile} window={args.window:.0f}s "
        f"interval={args.interval:.0f}s (config_source={cfg.source})\n"
    )
    sys.stderr.flush()

    def window_span():
        if len(window) < 2:
            return 0.0
        return window[-1][0] - window[0][0]

    try:
        for line in source:
            line = line.strip()
            if line:
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    skipped += 1
                    continue
                if event.get("schema", "").startswith("ble-obs/") and event.get("address"):
                    if not sensor_id and event.get("sensor_id"):
                        sensor_id = str(event["sensor_id"])
                    clock = event_clock(event, time.monotonic())
                    latest_clock = clock if latest_clock is None else max(latest_clock, clock)
                    window.append((clock, record_from_event(event)))
                    # Drop observations that have aged out of the window, judged
                    # on the observation timeline rather than wall time.
                    cutoff = latest_clock - args.window
                    while window and window[0][0] < cutoff:
                        window.popleft()

            now = time.monotonic()
            if now - last_eval >= args.interval:
                report(window, cfg, window_span(), sys.stdout, jsonl, sensor_id)
                last_eval = now
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        return 0
    finally:
        if source is not sys.stdin:
            source.close()

    # Final evaluation on whatever remains, so a short piped capture still
    # produces a verdict.
    if window:
        report(window, cfg, window_span(), sys.stdout, jsonl, sensor_id)
    if jsonl is not None:
        jsonl.close()
    if skipped:
        sys.stderr.write(f"note: skipped {skipped} unparseable line(s)\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
