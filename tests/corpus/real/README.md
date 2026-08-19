# Real capture corpus (operator-provided)

Files in this directory are **not committed**. They come from your own
hardware, they contain real device addresses observed in public, and a raw
`.btsnoop` can be large — none of that belongs in git. `.gitignore` keeps
everything here out of the repo except this README and `.gitkeep`.

## Why this exists

`scripts/ble-signature-scan.py` ships thresholds that were only ever measured
on a hostile, unusually dense conference floor. "Does not fire in a hostile
environment" is a weaker claim than "fires only on hostile traffic", and the
second half can only be confirmed against a **quiet** baseline the shipped
corpus cannot contain. This directory is where your real baselines plug into
the same precision/recall harness the synthetic samples run through.

## How to add a baseline

1. Capture ordinary ambient traffic somewhere quiet:

   ```bash
   sudo ./scripts/capture-btmon.sh
   ```

2. Copy the text log here with a descriptive, dated name:

   ```bash
   cp logs/btmon-hci0-YYYYMMDD-HHMMSS.log \
      tests/corpus/real/quiet-office-YYYYMMDD.log
   ```

3. Add a line to `tests/corpus/manifest.jsonl` labelling it:

   ```json
   {"kind":"real","label":"ambient","path":"real/quiet-office-YYYYMMDD.log"}
   ```

4. Run the harness and confirm the ambient sample produces no match:

   ```bash
   python3 tests/test-detector-metrics.py
   ```

   If a real ambient capture *does* match, that is the signal to raise the
   threshold it tripped in `config/signatures.conf` — this is exactly the
   baselining step the README's roadmap calls for.

Do the same with `"label":"spam"` for a capture where you *know* spam was
present (e.g. a Flipper you were holding), to measure recall on real traffic
rather than only on synthetic floods.
