# Sensor nodes: the contract

A sensor net is several nodes emitting the same records to one collector.
This page is what a node has to do to take part. Anything that meets it is
a node: a uConsole running this toolkit, a Raspberry Pi, a laptop, an ESP32,
or something not written yet.

## Records

A node emits JSON Lines. Every record carries `schema`, `ts` and
`sensor_id`. Three schemas exist today:

| Schema | One per | Required fields | Written by |
|---|---|---|---|
| `ble-obs/1` | advertisement seen | `ts` (epoch seconds, `ts_absolute: true`), `sensor_id`, `lat`/`lon` or null, `modality: "ble"`, `address`, `addr_type`, `addr_class`, `tier`, `identity_key`, `rssi` | `scripts/ble-observe.py`, the ESP32 sketch |
| `ble-alert/1` | detector evaluation | `ts`, `sensor_id`, `profile`, `window_sec`, `events`, `matches[]` | `scripts/ble-live-alert.py`; optional for a node |
| `sensor-status/1` | heartbeat | `ts`, `sensor_id`, `version`, `uptime_sec`, `published` | `scripts/ble-publish.py`, the ESP32 sketch |

The full `ble-obs/1` field list is in [sensor-net-notes.md](sensor-net-notes.md).
A node that cannot compute the content fingerprint the Python side uses may
emit its own `identity_key` for rotating addresses (`fp:node:<hash>`); the
collector treats any `model`-tier key as a product, never a unit, so a
node-local fingerprint costs nothing in honesty. Public and random-static
addresses must be keyed `addr:<lowercase mac>` so the same unit merges
across nodes.

**Absolute time is not optional.** A node without a synchronised clock
(NTP, GPS, or the collector's time at connect) cannot be lined up with the
others and its observations cannot contribute to a location. The Linux node
uses `--epoch-base now`; the ESP32 sketch waits for NTP before scanning.

## Transport

MQTT, one message per record, payload verbatim, QoS 1:

```
<prefix>/<sensor_id>/obs       ble-obs/*
<prefix>/<sensor_id>/alerts    ble-alert/*
<prefix>/<sensor_id>/status    sensor-status/1, retained
```

`<prefix>` defaults to `skidfinder`. The heartbeat is retained and the
node's last will clears it (empty retained payload on the status topic), so
a collector that starts late still sees which nodes are up, and a node that
drops off stops looking alive.

A file drop works too: a node that cannot reach a broker writes JSONL and
syncs it (rsync, Syncthing, a mounted share) into a directory the collector
watches with `--watch`. The local files are always the record of truth; the
transport only moves copies.

## Placement and position

- Give every fixed node `SENSOR_LAT`/`SENSOR_LON`. Without positions the
  collector still merges identities and judges each node, but nothing gets
  a location.
- Spacing sets the error. The estimate is a weighted centroid and its
  `spread_m` is the widest distance between the nodes that heard the device;
  nodes 30 m apart give an answer no better than "within about 30 m".
  Three or more nodes around a space beat two along a line.
- A moving node (hand-carried) leaves its position blank and is merged for
  identity only; its GPS track is a later addition.

## Security

The broker sits on a management network, not the venue Wi-Fi. Use TLS
(`MQTT_TLS=yes`, port 8883) and per-node credentials; the Linux node reads
`MQTT_USERNAME`/`MQTT_PASSWORD` from the environment and never from a file
in this repository. Records contain other people's device addresses and
names: treat the broker and the collector's files as you would any log
holding personal data, and keep retention short.

## Reference nodes

| Node | Status |
|---|---|
| Linux / SBC: this toolkit with `MQTT_HOST` set; `ble-live-watch.sh` starts the publisher | publisher and collector tested against a stand-in broker in CI; a real broker has not yet been exercised from this project |
| ESP32: [`nodes/esp32/skidfinder_node`](../nodes/esp32/skidfinder_node/skidfinder_node.ino) | **alpha: written to the NimBLE-Arduino and PubSubClient APIs, not compiled or run on hardware here** |

Both are deliberately thin. A node scans and emits; it does not decide.
The collector runs the shared detector over each node's recent window, so
a node with no CPU to spare still gets judged by the same rules as the
uConsole.
