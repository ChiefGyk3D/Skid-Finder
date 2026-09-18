# Sensor nodes

A node is anything that emits Skid Finder records to the collector. The
contract is in [docs/sensor-nodes.md](../docs/sensor-nodes.md). Reference
implementations:

| Node | Where | Status |
|---|---|---|
| Linux / SBC (uConsole, Pi, laptop) | this toolkit: `scripts/ble-live-watch.sh` with `MQTT_HOST` set | tested with a stand-in broker in CI; not yet against a real broker from this project |
| ESP32 | [esp32/skidfinder_node](esp32/skidfinder_node/skidfinder_node.ino) | **alpha, not compiled or run on hardware by this project** |

The ESP32 sketch is deliberately small: passive scan, one record per
advertisement, a retained heartbeat. It does not run the detector; the
collector judges it from the raw observations.
