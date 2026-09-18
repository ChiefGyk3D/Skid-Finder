#!/usr/bin/env python3
"""Alert on Wi-Fi attacks live, from a wifi-obs/1 stream.

The Wi-Fi counterpart of ble-live-alert.py: a sliding window over each
observation's own timestamp, the shared wifi_signatures detector run over
it on a fixed cadence, text for the operator and one wifi-alert/1 JSON
record per evaluation for a SIEM or the collector.
"""

import argparse
import collections
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wifi_parse  # noqa: E402
import wifi_signatures  # noqa: E402

ALERT_SCHEMA = "wifi-alert/1"


def frame_from_event(event):
    return wifi_parse.WifiFrame(
        timestamp=event.get("ts"),
        subtype=int(event.get("subtype", -1) or -1),
        sa=str(event.get("address", "") or ""),
        da=str(event.get("da", "") or ""),
        bssid=str(event.get("bssid", "") or ""),
        ssid=str(event.get("name", "") or ""),
        rssi=event.get("rssi"),
        channel=event.get("channel"),
        reason=event.get("reason"),
    )


def event_clock(event, arrival):
    ts = event.get("ts")
    if isinstance(ts, (int, float)):
        return float(ts)
    return arrival


def report(window, cfg, window_seconds, out, jsonl=None, sensor_id=""):
    frames = [f for _, f in window]
    stats = wifi_signatures.build_stats(frames, duration=window_seconds)
    matches = wifi_signatures.evaluate(stats, cfg)
    stamp = time.strftime("%H:%M:%S")
    out.write(f"[{stamp}] window={window_seconds:.0f}s frames={stats.total_frames} "
              f"deauth={stats.deauth_rate:.1f}/s bssids={len(stats.beacon_bssid_counts)} "
              f"singleton={stats.beacon_singleton_ratio:.2f} matches={len(matches)}\n")
    for match in matches:
        out.write(f"  ALERT {match.name} confidence={match.confidence}% :: {match.evidence}\n")
    out.flush()
    if jsonl is not None:
        jsonl.write(json.dumps({
            "schema": ALERT_SCHEMA, "ts": time.time(), "sensor_id": sensor_id, "modality": "wifi",
            "profile": cfg.profile, "window_sec": round(window_seconds, 3),
            "frames": stats.total_frames, "deauth_rate": round(stats.deauth_rate, 3),
            "unique_bssids": len(stats.beacon_bssid_counts),
            "beacon_singleton_ratio": round(stats.beacon_singleton_ratio, 3),
            "matches": [{"name": m.name, "confidence": m.confidence, "evidence": m.evidence} for m in matches],
        }, sort_keys=True) + "\n")
        jsonl.flush()
    return matches


def main() -> int:
    parser = argparse.ArgumentParser(description="Alert on Wi-Fi attacks from a live observation stream")
    parser.add_argument("--window", type=float, default=30.0)
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--profile", default="balanced", choices=["conservative", "balanced", "aggressive"])
    parser.add_argument("--config", default=wifi_signatures.config_path_default())
    parser.add_argument("--input", default="-")
    parser.add_argument("--jsonl-out", default=None)
    parser.add_argument("--sensor-id", default=os.environ.get("SENSOR_ID", ""))
    args = parser.parse_args()

    cfg = wifi_signatures.load_config(args.profile, args.config)
    source = sys.stdin if args.input == "-" else open(args.input, encoding="utf-8")
    jsonl = None
    if args.jsonl_out:
        directory = os.path.dirname(os.path.abspath(args.jsonl_out))
        if directory:
            os.makedirs(directory, exist_ok=True)
        jsonl = open(args.jsonl_out, "a", encoding="utf-8")
    sensor_id = args.sensor_id
    window = collections.deque()
    latest = None
    last_eval = time.monotonic()
    skipped = 0

    sys.stderr.write(f"wifi live alerting: profile={cfg.profile} window={args.window:.0f}s "
                     f"interval={args.interval:.0f}s (config_source={cfg.source})\n")

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
                if str(event.get("schema", "")).startswith("wifi-obs/") and event.get("address"):
                    if not sensor_id and event.get("sensor_id"):
                        sensor_id = str(event["sensor_id"])
                    clock = event_clock(event, time.monotonic())
                    latest = clock if latest is None else max(latest, clock)
                    window.append((clock, frame_from_event(event)))
                    cutoff = latest - args.window
                    while window and window[0][0] < cutoff:
                        window.popleft()
            now = time.monotonic()
            if now - last_eval >= args.interval:
                report(window, cfg, span(), sys.stdout, jsonl, sensor_id)
                last_eval = now
    except KeyboardInterrupt:
        pass
    except BrokenPipeError:
        return 0
    finally:
        if source is not sys.stdin:
            source.close()

    if window:
        report(window, cfg, span(), sys.stdout, jsonl, sensor_id)
    if jsonl is not None:
        jsonl.close()
    if skipped:
        sys.stderr.write(f"note: skipped {skipped} unparseable line(s)\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
