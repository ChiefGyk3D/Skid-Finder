#!/usr/bin/env python3
"""Measure detector precision/recall against a labeled corpus.

The signature scanner's honest weakness, recorded in the README roadmap, is
that its thresholds were only ever set in a hostile, unusually dense
environment. A single true-positive test and a single false-positive test
(which is what tests/test-ble-signatures.sh does) confirm the detector works
on one sample of each; they do not measure how often it is right.

This harness runs the scanner across every sample in
tests/corpus/manifest.jsonl, for every profile, and computes:

  false-positive rate   share of 'ambient' samples that matched anything.
                        This is the number the roadmap cares about. It must be
                        zero: a detector that cries spam at ordinary traffic is
                        useless at a venue.

  recall                share of 'spam' samples that matched something. A miss
                        here is a spam flood walking past undetected.

Synthetic samples are generated deterministically by tests/make-fixture.py, so
the metrics are reproducible run to run. Real, operator-provided captures named
in the manifest are folded in when present and skipped (not failed) when
absent, so CI stays green without them while a field baseline strengthens the
measurement the moment it is added. See tests/corpus/real/README.md.

Exit status is non-zero if any gate below is missed, so this is a regression
guard, not just a report.
"""

import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAKE_FIXTURE = os.path.join(ROOT, "tests", "make-fixture.py")
SCANNER = os.path.join(ROOT, "scripts", "ble-signature-scan.py")
MANIFEST = os.path.join(ROOT, "tests", "corpus", "manifest.jsonl")
CORPUS_DIR = os.path.join(ROOT, "tests", "corpus")

PROFILES = ["conservative", "balanced", "aggressive"]

# Map a scanner MATCH line back to the short family label used in the manifest.
FAMILY_BY_MATCH = {
    "Flipper-like Apple popup spam pattern": "flipper",
    "Marauder-like rotating beacon flood": "marauder",
    "Fast Pair lure flood pattern": "fastpair",
    "Generic BLE spam burst": "generic",
    "Random-address churn flood": "random_churn",
    "Lure-name rotation burst": "name_rotation",
}

# Gates per profile. Ambient false positives are never acceptable, so the bar
# is zero for every profile. Recall is allowed to be lower on the conservative
# profile by design: it deliberately trades sensitivity for certainty.
MAX_FP_RATE = {"conservative": 0.0, "balanced": 0.0, "aggressive": 0.0}
MIN_RECALL = {"conservative": 0.5, "balanced": 1.0, "aggressive": 1.0}


def read_manifest(path):
    samples = []
    with open(path, encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            try:
                samples.append(json.loads(line))
            except json.JSONDecodeError as exc:
                sys.exit(f"{path}:{lineno}: invalid JSON: {exc}")
    return samples


def materialise(sample, tmpdir):
    """Return a filesystem path to the capture for a sample, or None to skip."""
    if sample["kind"] == "real":
        path = os.path.join(CORPUS_DIR, sample["path"])
        if not os.path.exists(path):
            return None
        return path

    if sample["kind"] == "synthetic":
        name = f"{sample['mode']}-{sample['rate']}-{sample['duration']}-{sample['seed']}.log"
        out = os.path.join(tmpdir, name)
        cmd = [
            sys.executable, MAKE_FIXTURE,
            "--mode", sample["mode"],
            "--duration", str(sample["duration"]),
            "--rate", str(sample["rate"]),
            "--seed", str(sample["seed"]),
            "--output", out,
        ]
        subprocess.run(cmd, check=True)
        return out

    sys.exit(f"unknown sample kind: {sample['kind']!r}")


def matched_families(capture, profile, empty_conf):
    """Run the scanner and return the set of families it reported."""
    # An explicit empty config keeps the result independent of any operator's
    # local config/signatures.conf, exactly as test-ble-signatures.sh does.
    result = subprocess.run(
        [sys.executable, SCANNER, "--input", capture,
         "--profile", profile, "--config", empty_conf],
        check=True, capture_output=True, text=True,
    )
    families = set()
    for line in result.stdout.splitlines():
        if line.startswith("MATCH "):
            name = line[len("MATCH "):].split(" confidence=")[0].strip()
            families.add(FAMILY_BY_MATCH.get(name, name))
    return families


def describe(sample):
    if sample["kind"] == "real":
        return f"real:{sample['path']}"
    return f"{sample['mode']}@{sample['rate']}/s×{sample['duration']}s#{sample['seed']}"


def main():
    samples = read_manifest(MANIFEST)
    with tempfile.TemporaryDirectory() as tmpdir:
        empty_conf = os.path.join(tmpdir, "empty.conf")
        open(empty_conf, "w").close()

        # Materialise once; reuse across profiles.
        prepared = []
        skipped = 0
        for sample in samples:
            capture = materialise(sample, tmpdir)
            if capture is None:
                skipped += 1
                print(f"skip (absent): {describe(sample)}")
                continue
            prepared.append((sample, capture))

        ambient = [(s, c) for s, c in prepared if s["label"] == "ambient"]
        spam = [(s, c) for s, c in prepared if s["label"] == "spam"]

        print()
        print(f"corpus: {len(ambient)} ambient, {len(spam)} spam"
              f"{f', {skipped} skipped' if skipped else ''}")
        print()

        failures = []
        header = f"{'profile':<14}{'fp_rate':>9}{'recall':>9}  detail"
        print(header)
        print("-" * len(header))

        for profile in PROFILES:
            fp_hits = []
            for sample, capture in ambient:
                fams = matched_families(capture, profile, empty_conf)
                if fams:
                    fp_hits.append((sample, fams))

            recall_hits = 0
            family_misses = []
            for sample, capture in spam:
                fams = matched_families(capture, profile, empty_conf)
                if fams:
                    recall_hits += 1
                expected = set(sample.get("families", []))
                # Only require an expected family on profiles that are meant to
                # catch it; conservative is allowed to be quiet.
                if expected and profile != "conservative" and not (expected & fams):
                    family_misses.append((sample, expected, fams))

            fp_rate = len(fp_hits) / len(ambient) if ambient else 0.0
            recall = recall_hits / len(spam) if spam else 1.0

            detail = "ok"
            if fp_rate > MAX_FP_RATE[profile]:
                detail = "FALSE POSITIVES"
                for sample, fams in fp_hits:
                    failures.append(
                        f"{profile}: ambient sample {describe(sample)} matched "
                        f"{sorted(fams)}")
            if recall < MIN_RECALL[profile]:
                detail = "LOW RECALL" if detail == "ok" else detail + "+LOW RECALL"
                failures.append(
                    f"{profile}: recall {recall:.2f} < required "
                    f"{MIN_RECALL[profile]:.2f}")
            for sample, expected, fams in family_misses:
                failures.append(
                    f"{profile}: spam sample {describe(sample)} expected one of "
                    f"{sorted(expected)} but matched {sorted(fams) or 'nothing'}")

            print(f"{profile:<14}{fp_rate:>9.2f}{recall:>9.2f}  {detail}")

        print()
        if failures:
            print("REGRESSION:")
            for line in failures:
                print(f"  - {line}")
            print()
            print("detector metrics FAILED")
            return 1

        print("detector metrics passed")
        return 0


if __name__ == "__main__":
    sys.exit(main())
