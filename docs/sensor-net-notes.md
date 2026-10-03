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
| `tier` | identity confidence: `strong` / `session` / `model` per advert; `ambiguous` appears only after the fingerprint tool aggregates sightings and finds too little content to attribute |
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
sudo ./scripts/ble-live-watch.sh            # until Ctrl+C
sudo ./scripts/ble-live-watch.sh hci0 300   # bounded run
```

The wrapper holds an LE scan open around btmon (nothing is reported on an
idle adapter), line-buffers btmon so alerts are not held back by a full pipe
buffer, and tees the observations to `logs/obs-<iface>-<stamp>.jsonl` with
absolute timestamps (`--epoch-base now` pins the base to the first advert's
arrival). The underlying pipeline is:

```bash
sudo stdbuf -oL btmon -i hci0 \
  | ./scripts/ble-observe.py --stream --epoch-base now \
  | ./scripts/ble-live-alert.py --window 30 --interval 5 --profile balanced
```

It reaches the same verdict as the batch scanner by construction — both import
one detector — so a threshold tuned in `config/signatures.conf` changes both.
The observer takes `SENSOR_ID`, `SENSOR_LAT` and `SENSOR_LON` from
`config/interfaces.conf` unless the environment or the command line overrides
them.

## Sensor net and triangulation (collector exists; alpha)

The normalized stream is the seam the sensor net plugs into, and the first
collector now sits on it:

1. Several sensors each emit records stamped with their own `sensor_id` and
   position. The Linux node is `ble-live-watch.sh` with `MQTT_HOST` set,
   which starts `scripts/ble-publish.py` to tail its files onto the broker;
   other nodes follow the contract in [sensor-nodes.md](sensor-nodes.md).
2. `scripts/ble-collector.py` reads them (`--mqtt`, `--watch DIR`, or
   `--input` files), groups observations by `identity_key`, keeps a median
   RSSI per sensor over a sliding window, runs the shared detector over
   each sensor's window, and writes a `fleet-state/1` snapshot plus
   `fleet-alert/1` records.
3. For `strong`/`session` identities heard by two or more positioned
   sensors it estimates a location as an RSSI-weighted centroid, and for a
   flood it places the source by the event rate each sensor sees. Every
   estimate carries `spread_m`, the widest distance between the sensors
   that produced it, as the error bar.

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

The build order, weakest assumptions last, and where it stands:

1. **RSSI heatmap over position** — plot observations at their sensor's
   location (or a moving sensor's GPS track via `scripts/ble-gps-merge.py`).
   No location math. The `fleet-state/1` snapshot carries per-sensor median
   RSSI per identity, which is the input; no plotter ships yet.
2. **Weighted centroid** — *implemented in the collector.* A device sits at
   the RSSI-weighted average of the sensors that hear it (weight
   10^((rssi+100)/20), roughly inverse free-space distance). Crude, robust,
   no calibration, error bar stated as `spread_m`.
3. **Log-distance multilateration** — not implemented. Needs per-environment
   calibration and is the first step whose output can mislead if the caveats
   above are ignored. It stays behind hardware validation.

## Incidents

An evaluation fires every few seconds while a flood runs; paging on each
one is noise. The collector groups them: an incident opens on the first
evaluation with a match, absorbs every later match (sensors and the
families each reported, peak rate, the loudest sensor, the location
estimate at every step, the identities the matching sensors heard with
their tiers), and closes once the fleet has been quiet for
`--incident-quiet` seconds (default 60; note the detector's window keeps a
flood "visible" for a window length after it stops). `--incidents-out`
appends one `fleet-incident/1` record on open and one on close; the open
incident also rides in `fleet-state/1` under `incident`. Its identities are
what the matching sensors heard, not attribution, and the record says so.
The record's `targets` list is the foxhunt handoff: the addresses those
identities used while the incident ran, reliable tiers first and capped,
which `foxhunt-rssi.sh --from-incident` loads on the handheld. Rotating
(model-tier) addresses in it go stale within minutes; the tracker prints
each address with its tier so the hunter knows which to trust.

## Wi-Fi (exists; alpha)

The `modality` field and the module split are what let the Wi-Fi frontend
reuse everything here. `wifi-observe.py` emits `wifi-obs/1` records with the
same envelope, the collector keeps a Wi-Fi window per sensor and judges it
with the Wi-Fi detector (deauth and disassoc floods, beacon floods, evil
twins, KARMA responders), and `wifi_identity.py` fingerprints randomised
clients by tag order, rates, capabilities and vendor OUIs rather than the
MAC. All of it is measured on synthetic traffic only so far; see
[wifi-notes.md](wifi-notes.md). As with BLE, everything stays passive:
detection only, never transmit.
