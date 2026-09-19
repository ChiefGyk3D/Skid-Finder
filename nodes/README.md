# Sensor nodes

A node is anything that emits Skid Finder records to the collector. The
contract is in [docs/sensor-nodes.md](../docs/sensor-nodes.md). Reference
implementations:

| Node | Where | Status |
|---|---|---|
| Linux / SBC (uConsole, Pi, laptop) | this toolkit: `scripts/ble-live-watch.sh` with `MQTT_HOST` set | tested with a stand-in broker in CI; not yet against a real broker from this project |
| ESP32 | [esp32/skidfinder_node](esp32/skidfinder_node/skidfinder_node.ino) | **compiles** (measured 2026-09-18, below); **not yet run on hardware** |

The ESP32 sketch is deliberately small: passive scan, one record per
advertisement, a retained heartbeat. It does not run the detector; the
collector judges it from the raw observations.

## Building the ESP32 sketch

Measured on 2026-09-18 with arduino-cli, ESP32 core 3.3.12, NimBLE-Arduino
2.5.1 and PubSubClient 2.8: the sketch compiles for `esp32:esp32:esp32`
using 1,161,510 bytes, **88% of the default 1.3 MB app partition**, with
57 KB of static RAM. Pick a larger app partition scheme when flashing
(`huge_app` or `min_spiffs` in the board options) so an OTA slot or a
library update does not push it over.

```bash
arduino-cli config set board_manager.additional_urls \
  https://espressif.github.io/arduino-esp32/package_esp32_index.json
arduino-cli core update-index && arduino-cli core install esp32:esp32
arduino-cli lib install NimBLE-Arduino PubSubClient
arduino-cli compile --fqbn esp32:esp32:esp32 nodes/esp32/skidfinder_node
arduino-cli upload  --fqbn esp32:esp32:esp32 -p /dev/ttyUSB0 nodes/esp32/skidfinder_node
```

Edit the `configure these` block at the top of the sketch first (Wi-Fi,
broker, sensor id, position). What remains unverified is everything after
the compile: that it scans, that the JSON it builds parses, that the
collector accepts it. That is the first thing to do with a board in hand.
