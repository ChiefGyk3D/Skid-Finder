#!/usr/bin/env python3
"""Defensive Wi-Fi signature scanner (command-line front end).

The detector lives in wifi_signatures.py so this batch scanner, the live
alerter and the collector share one implementation. Input is the tshark
field extract that scripts/wifi-capture.sh writes (.tsv).
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wifi_signatures import (  # noqa: E402
    config_path_default,
    evaluate,
    load_config,
    parse_log,
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Defensive Wi-Fi signature scanner")
    parser.add_argument("--input", required=True, help="tshark field extract (.tsv)")
    parser.add_argument("--profile", default=None, choices=["conservative", "balanced", "aggressive"])
    parser.add_argument("--config", default=config_path_default())
    parser.add_argument("--quiet", action="store_true", help="Only print match lines")
    args = parser.parse_args()

    cfg = load_config(args.profile, args.config)
    stats = parse_log(args.input)
    matches = evaluate(stats, cfg)

    if not args.quiet:
        print("# Wi-Fi Signature Scan Summary")
        print(f"profile={cfg.profile}")
        print(f"config_source={cfg.source}")
        print(f"frames={stats.total_frames}")
        note = " (estimated: capture had no timestamps)" if stats.duration_estimated else ""
        print(f"duration_sec={stats.duration:.1f}{note}")
        print(f"deauth_frames={stats.deauth_frames}")
        print(f"deauth_rate_per_sec={stats.deauth_rate:.2f}")
        print(f"beacon_frames={stats.beacon_frames}")
        print(f"unique_bssids={len(stats.beacon_bssid_counts)}")
        print(f"beacon_singleton_ratio={stats.beacon_singleton_ratio:.3f}")
        print(f"unique_ssids={len(stats.beacon_ssids)}")
        print(f"probe_requests={stats.probe_req_frames}")
        print("")

    if not matches:
        print("No high-confidence signatures matched.")
        return 0

    print("# Matched Signatures")
    for match in matches:
        print(f"MATCH {match.name} confidence={match.confidence}%")
        print(f"  evidence: {match.evidence}")
    if cfg.source.startswith("defaults:"):
        print("NOTE: using built-in Wi-Fi thresholds, which have not been baselined on any real "
              "venue yet. Capture known-quiet traffic and confirm it produces no match before "
              "treating a match as conclusive.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
