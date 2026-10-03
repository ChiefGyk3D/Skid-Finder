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

2. Record it with the helper, which copies the log here and adds the manifest
   line for you (no root needed):

   ```bash
   latest=$(ls -1t logs/btmon-hci0-*.log | head -1)
   ./scripts/add-corpus-sample.sh --label ambient --capture "$latest" \
     --note "home baseline" --run
   ```

   `--run` re-runs the harness immediately. If a real ambient capture *does*
   match, that is the signal to raise the threshold it tripped in
   `config/signatures.conf` — the baselining step the README's roadmap calls
   for.

For a **spam** sample — a capture where you *know* spam was present, to measure
recall on real traffic instead of only synthetic floods — use `--label spam`
and tag the family it should trip:

```bash
./scripts/add-corpus-sample.sh --label spam --capture "$latest" \
  --families flipper,fastpair --note "Flipper Zero, contained room" --run
```

See [../../../docs/flipper-spam-capture.md](../../../docs/flipper-spam-capture.md)
for the controlled Flipper Zero capture procedure.

The old manual path (copy the log, hand-edit `tests/corpus/manifest.jsonl`)
still works; the helper just makes the labels and JSON hard to get wrong.
