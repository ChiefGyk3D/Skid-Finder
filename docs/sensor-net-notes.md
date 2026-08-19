# Normalized observations and the sensor net

This note records the data model the toolkit is growing toward, so the design
intent travels with the code. It covers what exists now (single-sensor
normalized output and live alerting) and what it is the foundation for
(multi-sensor collection and triangulation).

## Why a normalized observation exists

Every analysis tool used to re-parse a btmon text log at the end of a run.
That is fine for one device judging its own capture, but it is a dead end for
three things on the roadmap:

- **live alerting**, which needs observations as they arrive, not after the
  capture finishes;
- **a sensor net**, where several devices must emit observations in one shared
  machine-readable shape a collector can merge;
- **a second radio modality (Wi-Fi)**, which can reuse everything downstream if
  it emits the same record shape.

So `scripts/ble-observe.py` turns a capture — from a file or a live `btmon`
pipe — into one JSON object per advertising report, stamped with which sensor
saw it and where. The schema is versioned so a collector can reject or adapt to
records it does not understand.

## Schema: `ble-obs/1`

One JSON object per line (JSON Lines). Fields:

| Field | Meaning |
|---|---|
| `schema` | `"ble-obs/1"` — version tag |
| `ts` | observation time; capture-relative seconds unless `ts_absolute` is true |
| `ts_absolute` | true when `ts` is absolute epoch (an `--epoch-base` was supplied) |
| `sensor_id` | which sensor observed this (from `SENSOR_ID`) |
| `lat`, `lon` | sensor position in decimal degrees, or null when moving/unknown |
| `modality` | `"ble"` today; the field exists so `"wifi"` can join later |
| `address` | observed device address |
| `addr_type` | `public` / `random` |
| `addr_class` | `public` / `static` / `resolvable` / `non-resolvable` / `unknown` |
| `tier` | identity confidence: `strong` / `session` / `model` / `ambiguous` |
| `identity_key` | the key that decides what is "the same device" across time |
| `rssi`, `tx_power` | signal fields, or null when absent |
| `name` | advertised name, if any |
| `companies`, `service_uuids` | advertised vendor IDs and service UUIDs |
| `pdu`, `flags` | advertising PDU type and flags |

The `tier` and `identity_key` come from `scripts/ble_identity.py`, the same
logic the fingerprint tool uses, so a stream and a batch fingerprint agree on
what counts as one device.

## Live alerting (exists now)

`scripts/ble-live-alert.py` consumes the stream, keeps a sliding window over
each observation's own timestamp, and runs the shared `ble_signatures`
detector over that window on a fixed cadence:

```bash
sudo btmon -i hci0 \
  | ./scripts/ble-observe.py --stream --sensor-id "$SENSOR_ID" \
  | ./scripts/ble-live-alert.py --window 30 --interval 5 --profile balanced
```

It reaches the same verdict as the batch scanner by construction — both import
one detector — so a threshold tuned in `config/signatures.conf` changes both.

## Sensor net and triangulation (planned)

The normalized stream is the seam a sensor net plugs into. The intended shape:

1. Several sensors each run `ble-observe.py`, stamping their own `sensor_id`
   and position, and ship JSONL to a collector (start with append-to-shared-
   file or MQTT; the transport is not the hard part).
2. The collector groups observations by `identity_key` and, for a given
   device, has RSSI from several known positions at overlapping times.
3. From that it can estimate a location.

**Read this part honestly before trusting a dot on a map.** RSSI-based
location indoors is bad. Multipath swings a single reading by 20 dB — the
foxhunt tool already steers on a median for exactly this reason — so expect
metres-to-tens-of-metres error, not a pin. Two constraints matter more than the
math:

- **You can only triangulate an identity that persists across sensors.** A
  `strong` or `session` tier device holds still enough in identity to be
  located. A `model`/`ambiguous` tier "device" is a product seen on several
  sensors that may be several different people; triangulating it triangulates a
  crowd, not a person. The tier field is what tells the collector which targets
  are tractable.
- **Spam sources are often the tractable case.** Many spam tools transmit
  continuously from one radio and do not rotate identity cleanly, which is
  exactly the persistent, high-rate signal multilateration handles best.

A sensible build order, weakest assumptions last:

1. **RSSI heatmap over position** — plot observations at their sensor's
   location (or a moving sensor's GPS track via `scripts/ble-gps-merge.py`).
   No location math, immediately useful.
2. **Weighted centroid** — place a device at the RSSI-weighted average of the
   sensors that hear it. Crude, robust, no calibration.
3. **Log-distance multilateration** — fit a path-loss model and solve. Needs
   per-environment calibration and time-synchronised sensors (chrony/NTP), and
   is the first step whose output can mislead if the caveats above are ignored.

## Wi-Fi (later)

The `modality` field and the module split exist so a Wi-Fi capture frontend can
emit `ble-obs`-shaped records (`modality:"wifi"`) and reuse the collector,
identity tiers, and alerting. Detection would mirror the BLE families — deauth
and disassoc floods, beacon floods, evil-twin/karma/known-beacon patterns — and
fingerprinting would key on probe-request SSID lists and tagged-parameter order
rather than the MAC, since modern clients randomise probe MACs. As with BLE,
everything stays passive: detection only, never transmit.
