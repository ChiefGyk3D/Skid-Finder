#!/usr/bin/env python3
"""Defensive BLE signature scanner (command-line front end).

The detector itself — thresholds, statistics and evaluation — lives in
ble_signatures.py so that this batch scanner, the live windowed alerter and any
future collector share one implementation. This file only parses arguments,
runs a whole capture through that core, and prints the summary.

See ble_signatures.py for the calibration rationale.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ble_signatures import (  # noqa: E402
    Match,
    SignatureConfig,
    Stats,
    config_path_default,
    evaluate,
    load_config,
    parse_log,
)


def print_summary(stats: Stats, matches: "list[Match]", quiet: bool, cfg: SignatureConfig) -> None:
    if not quiet:
        print("# Signature Scan Summary")
        print(f"profile={cfg.profile}")
        print(f"config_source={cfg.source}")
        print(f"events={stats.total_events}")
        duration_note = " (estimated: capture had no timestamps)" if stats.duration_estimated else ""
        print(f"duration_sec={stats.duration:.1f}{duration_note}")
        print(f"event_rate_per_sec={stats.event_rate:.1f}")
        print(f"unique_addresses={len(stats.unique_addrs)}")
        print(f"unique_ratio={stats.unique_ratio:.3f}")
        print(f"singleton_ratio={stats.singleton_ratio:.3f}")
        print(f"random_addresses={len(stats.random_addrs)}")
        print(f"unique_names={len(stats.unique_names)}")
        print(f"apple_mfg_events={stats.apple_mfg_events}")
        print(f"fast_pair_events={stats.fast_pair_events}")
        print("")

    if not matches:
        print("No high-confidence signatures matched.")
        return

    print("# Matched Signatures")
    for match in matches:
        print(f"MATCH {match.name} confidence={match.confidence}%")
        print(f"  evidence: {match.evidence}")

    # The shipped thresholds were measured on a hacker-conference floor, which
    # is denser than normal and already contains real spam, so no clean ambient
    # baseline was available when they were set. Until the operator baselines
    # their own environment a match is a lead worth investigating, not proof.
    # On stderr so it cannot corrupt the summary on stdout.
    if cfg.source.startswith("defaults:"):
        print(
            "NOTE: using built-in thresholds, which were measured in a very "
            "noisy RF environment and are not baselined for yours. Capture "
            "known-quiet ambient traffic and confirm it produces no match "
            "before treating a match as conclusive.",
            file=sys.stderr,
        )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Defensive BLE signature scanner for common scripted spam/flood patterns"
    )
    parser.add_argument("--input", required=True, help="btmon capture log path")
    parser.add_argument(
        "--profile",
        default=None,
        choices=["conservative", "balanced", "aggressive"],
        help="Detection sensitivity profile (overrides config when provided)",
    )
    parser.add_argument(
        "--config",
        default=config_path_default(),
        help="Optional signatures config file path",
    )
    parser.add_argument("--quiet", action="store_true", help="Only print match lines")
    parser.add_argument("--format", default="btmon", choices=["btmon", "tshark"],
                        help="btmon text (default) or tshark field lines")
    args = parser.parse_args()

    cfg = load_config(args.profile, args.config)
    stats = parse_log(args.input, args.format)
    matches = evaluate(stats, cfg)
    print_summary(stats, matches, args.quiet, cfg)
    return 0


if __name__ == "__main__":
    sys.exit(main())
