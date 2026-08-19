# Capturing a Flipper Zero spam sample (controlled)

The detector's recall — does it catch real spam — cannot be measured from a
quiet baseline. It needs a capture of genuine hostile traffic. The safe way to
produce one is to run your own Flipper Zero's BLE spam against your own capture
device in a contained environment, and record it as a labeled `spam` sample in
the corpus.

## Read this first: where this is allowed

Running BLE spam is harmful and often illegal in public. It disrupts hearing
aids, cochlear implants, and medical alert devices, and can interfere with
emergency connectivity. This procedure is for a **controlled, isolated
environment only** — a room with no bystanders and no one relying on Bluetooth
nearby, ideally with nearby phones in airplane mode, or a shielded enclosure.
Keep the transmit window short. The Flipper is the only transmitter; the
toolkit side stays passive. This mirrors the boundary the README draws:
intentional spam belongs in a lab or an isolated location, never at a venue.

## What the Flipper transmits, and which signature it should trip

The common Flipper BLE spam app (e.g. "BLE Spam" on Momentum/Xtreme firmware)
rotates the advertising address on nearly every packet and cycles lure names,
which is exactly the shape the detector keys on. Its modes map to families:

| Flipper mode | Lure content | Expected detector family |
|---|---|---|
| Apple / iOS | AirPods, AirTag, etc. under Apple's company ID | `flipper`, `name_rotation`, `random_churn`, `generic` |
| Fast Pair / Android | Fast Pair service data (`0xfe2c`) | `fastpair`, `random_churn`, `generic` |
| SwiftPair / Windows | Microsoft pairing beacons, no Apple/lure names | `random_churn`, `generic` |
| Samsung / Android | Samsung buds lures | `name_rotation`, `random_churn`, `generic` |

Capturing each mode **separately** is worth the extra minutes: it lets you tag
each sample with the family it should exercise and measure per-family recall,
instead of one blended "did anything match" result.

## Procedure

1. Set up the contained environment. Put bystander phones in airplane mode.

2. Start a capture on the listening device (30s is plenty; lengthen if you
   want a bigger sample):

   ```bash
   sudo ./scripts/capture-btmon.sh hci0 30
   ```

3. While it runs, start the Flipper spamming in one mode. Stop the Flipper when
   the capture finishes.

4. Record the capture as a labeled spam sample, tagging the family that mode
   should trip:

   ```bash
   latest=$(ls -1t logs/btmon-hci0-*.log | head -1)
   ./scripts/add-corpus-sample.sh --label spam --capture "$latest" \
     --families flipper,name_rotation \
     --note "Flipper Zero, Apple mode, contained room" --run
   ```

   `--run` re-runs the metrics harness immediately.

5. Read the result. Under the `balanced` and `aggressive` profiles, recall must
   be `1.00` — every spam sample, including this real one, must match. Two
   informative outcomes:

   - **A family you tagged did not fire.** The harness prints which sample
     expected which family and what it actually matched. That is a real
     coverage finding: either the sample was weak/short, or a threshold for
     that family is too high for real Flipper output and should be lowered in
     `config/signatures.conf`.
   - **`conservative` misses it.** Allowed by design; that profile trades
     sensitivity for certainty and is not required to catch every sample.

6. Repeat per mode (Fast Pair, SwiftPair, Samsung) with the matching
   `--families` tag.

## Also worth capturing live

Once you have the Flipper spamming, watch the live alerter fire in real time —
this is the field workflow, not just a corpus builder:

```bash
sudo btmon -i hci0 \
  | ./scripts/ble-observe.py --stream --sensor-id "$SENSOR_ID" \
  | ./scripts/ble-live-alert.py --window 30 --interval 5 --profile balanced
```

You should see `ALERT` lines appear within a window or two of starting the
Flipper, and stop once it stops.

## What stays out of git

The capture files under `tests/corpus/real/` are git-ignored (they contain real
addresses and can be large). The manifest line is tracked, so the branch
records that the sample was taken and how it is labeled, without publishing the
raw capture. See `tests/corpus/real/README.md`.
