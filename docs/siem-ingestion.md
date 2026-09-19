# Feeding Skid Finder into a SIEM

Every capture and every live run now leaves machine-readable records beside
the human-readable log and summary. They are JSON Lines: one JSON object per
line, append-only, with a `schema` field on every record so a pipeline can
reject or adapt to shapes it does not know. Nothing here is tied to one SIEM;
the files are meant to be picked up by whatever log shipper you already run.

This page records the two record shapes and the intended ingestion path. The
shipper configurations are the standard JSON-lines pattern for each product,
written down here so they are not rediscovered, but **they have not been
exercised end to end from this toolkit yet**. Treat them as a starting point
and confirm the fields land as expected before building alerting on them.

## The files

| File | Written by | One record per |
|---|---|---|
| `logs/obs-<iface>-<stamp>.jsonl` | `ble-field-run.sh`, `ble-live-watch.sh`, `ble-observe.py` | advertisement seen |
| `logs/alerts-<iface>-<stamp>.jsonl` | `ble-live-watch.sh`, `ble-live-alert.py --jsonl-out` | detector evaluation (fires or not) |

Both carry the sensor identity from `config/interfaces.conf`
(`SENSOR_ID`, and `SENSOR_LAT`/`SENSOR_LON` for a fixed sensor), so records
from several devices can be told apart once they reach one index.

## `ble-obs/1` — observations

One object per advertising report. The full field list is in
[sensor-net-notes.md](sensor-net-notes.md); the ones a SIEM query usually
wants:

| Field | Meaning |
|---|---|
| `ts` | epoch seconds. `ts_absolute` is true when it is wall-clock time (live runs and field runs); false means capture-relative seconds from a converted log with no base |
| `sensor_id`, `lat`, `lon` | which sensor, and where it is if stationary |
| `address`, `addr_class` | observed address; `public` / `static` / `resolvable` / `non-resolvable` |
| `identity_key`, `tier` | what counts as "the same device" over time, and how far to trust it: `strong`, `session`, or `model` |
| `rssi` | signal strength in dBm |
| `name`, `companies`, `service_uuids` | advertised content, when present |

Volume is the thing to plan for. A conference floor produces tens of adverts
per second per sensor, so an observation stream is a high-rate index; a SIEM
that bills or degrades by event count should ingest **alerts** and keep
observations somewhere cheaper (object storage, a local OpenSearch index with
a short retention) for the cases where you need to go back and look.

## `ble-alert/1` — detector evaluations

One object per evaluation of the sliding window, written whether or not
anything matched. A run of quiet records is how you know a sensor is alive;
a gap is how you know it is not.

```json
{
  "schema": "ble-alert/1",
  "ts": 1758214532.41,
  "sensor_id": "uconsole-01",
  "modality": "ble",
  "profile": "balanced",
  "window_sec": 30.0,
  "events": 812,
  "unique_addrs": 640,
  "event_rate": 27.07,
  "unique_ratio": 0.788,
  "singleton_ratio": 0.81,
  "matches": [
    {
      "name": "Flipper-like Apple popup spam pattern",
      "confidence": 78,
      "evidence": "apple_rate=9.3/s, unique_addrs=640, unique_ratio=0.79, lure_name_hits=214"
    }
  ]
}
```

`matches` is empty on a quiet window. The signature names are the same
strings the batch scanner prints, so a rule keyed on `matches[].name` fires
identically from a live sensor and from a scan of a saved capture.

## `fleet-incident/1` — one ticket per flood

The collector groups related fleet alerts into incidents
(`--incidents-out`): one record when an incident opens and one when it
closes, with `id`, `first_seen`, `last_seen`, `duration_sec`, the sensors
involved and the families each reported, `loudest`, `peak_rate`, the last
location estimate and how many track points it has, and the top
identities the matching sensors heard with their tiers. This is the record
to page on and to wrap in a ticket; alerts are the evidence behind it.

## Shipping the files

The files are plain JSON Lines, so any shipper that reads JSON logs works.
Two common ones:

**Wazuh agent** (`ossec.conf` on the sensor):

```xml
<localfile>
  <log_format>json</log_format>
  <location>/path/to/Skid-Finder/logs/alerts-*.jsonl</location>
</localfile>
```

**Filebeat or Fluent Bit to OpenSearch:** a `filestream`/`tail` input on
`logs/alerts-*.jsonl` with JSON parsing enabled, indexed by `schema` and
`sensor_id`. Observations go the same way into a separate index if you want
them at all.

Two practical notes:

- The wrapper scripts run as root, so the files under `logs/` are root-owned.
  Give the shipper's user read access to `logs/`, or point the scripts at a
  directory the shipper already reads.
- Each run creates a new file with a timestamp in the name; ship by glob, not
  by fixed filename.

## What is not here yet

- No collector: sensors write files, nothing yet merges them. The shipper is
  the collector for now, which is fine for alerting and not for triangulation.
- No dashboard. A Grafana/OpenSearch dashboard over `ble-alert/1` is the
  natural next step once records are landing; the fields above are the ones
  it would plot.
- No Wazuh decoder or rules. The JSON log format needs neither to ingest;
  rules that raise a Wazuh alert on `matches[].name` are a few lines, but
  they should be written against records that have actually arrived.
