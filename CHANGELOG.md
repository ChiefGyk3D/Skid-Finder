# Changelog

All notable changes to Skid Finder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions
follow [SemVer](https://semver.org/) with pre-release stages as defined in
[docs/ROADMAP.md](docs/ROADMAP.md). Record schemas (`ble-obs/1`,
`ble-alert/1`) are versioned separately and only change when a consumer
would break.

## [Unreleased]

## [0.3.0-alpha.1] — 2026-09-18

Closes milestone [v0.3.0 alpha](https://github.com/ChiefGyk3D/Skid-Finder/milestone/3).
**Alpha:** the Wi-Fi detector is measured against synthetic traffic only;
the capture path has not been run on the AC1200 from this project.

### Added
- Passive Wi-Fi detection: `scripts/wifi-capture.sh` (monitor mode,
  channel hopping, pcapng + field extract, interface restored on exit),
  `scripts/wifi-live-watch.sh`, `scripts/wifi-observe.py` (`wifi-obs/1`),
  `scripts/wifi-signature-scan.py`, `scripts/wifi-live-alert.py`
  (`wifi-alert/1`), and the detector core `scripts/wifi_signatures.py`
  with four families: deauthentication/disassociation flood, beacon flood,
  evil twin, KARMA-style responder. Three profiles, tunable through
  `config/wifi-signatures.conf`.
- `scripts/wifi_parse.py` for tshark's field output, tolerant of both
  subtype spellings and hex-encoded SSIDs.
- `scripts/sig_config.py`: one rule loader for both detectors.
- The collector keeps a Wi-Fi window per sensor and judges it with the
  Wi-Fi detector; the publisher routes `wifi-obs`/`wifi-alert` records.
- Wi-Fi corpus (`tests/corpus/wifi-manifest.jsonl`) under the same
  precision/recall gate (`tests/test-detector-metrics.py --modality wifi`),
  plus `tests/test-wifi-signatures.sh` and `tests/test-wifi-live-watch.sh`.
- Field menu entries `wifi-capture`, `wifi-live`, `wifi-scan`;
  `WIFI_IFACE`, `WIFI_CHANNELS`, `WIFI_DWELL_MS` config keys.
- `docs/wifi-notes.md`: families, records, what to verify on hardware,
  legal framing. Wi-Fi monitor-mode section in TROUBLESHOOTING.md.

## [0.2.0-alpha.1] — 2026-09-18

Closes milestone [v0.2.0 alpha](https://github.com/ChiefGyk3D/Skid-Finder/milestone/2).
**Alpha:** the publisher and collector are exercised against a stand-in
broker in CI; no real broker, second physical node, or ESP32 build has been
run from this project yet.

### Added
- `scripts/ble-collector.py`: merges `ble-obs/1`, `ble-alert/1` and
  `sensor-status/1` records from several sensors (MQTT, a watched
  directory, or files), keys devices by `identity_key` across sensors, runs
  the shared detector over each sensor's window, estimates location for
  `strong`/`session` identities and for floods as an RSSI-weighted centroid
  with `spread_m` as the error bar, and writes `fleet-state/1` snapshots
  and `fleet-alert/1` records.
- `scripts/ble-publish.py`: tails a node's JSONL files onto MQTT
  (`<prefix>/<sensor_id>/{obs,alerts,status}`, QoS 1, retained heartbeat,
  last will), or ships a finished file after the fact.
- `MQTT_HOST`, `MQTT_PORT`, `MQTT_TLS`, `MQTT_TOPIC_PREFIX` config keys;
  `ble-live-watch.sh` starts the publisher when a broker is configured.
  Credentials are environment-only.
- `docs/sensor-nodes.md`: the node contract (records, topics, time,
  placement, security) and `nodes/esp32/` reference sketch (alpha, not
  compiled here).
- `scripts/skid_conf.py`: one config reader for the Python tools, with the
  same quoting rules as `lib.sh`.
- `tests/test-sensor-net.sh` and `tests/make-fleet-fixture.py`: three
  positioned sensors, a public device near one and a flood loudest at
  another; asserts merge, tier handling, location ordering, alert timing,
  topics, QoS, retained heartbeat and last will.

## [0.1.0-alpha.1] — 2026-09-18

Closes milestone [v0.1.0 alpha](https://github.com/ChiefGyk3D/Skid-Finder/milestone/1).
**Alpha:** green in CI against synthetic captures and stubbed radios; not
yet validated on the uConsole + AIO v2. The hardware checklist that turns
this into a beta is in `docs/ROADMAP.md`.

### Added
- Defensive BLE signature detector with three sensitivity profiles and a
  tunable `config/signatures.conf`; thresholds measured on the BSidesLV 2026
  floor.
- Labeled corpus and a precision/recall harness
  (`tests/test-detector-metrics.py`) that fails the build on any ambient
  false positive or spam-recall regression; a git-ignored slot for real
  captures and `scripts/add-corpus-sample.sh` to record them.
- Device fingerprinting with identity tiers (`strong`, `session`, `model`,
  `ambiguous`), a sighting history and a watchlist; foxhunting by MAC or by
  resolving a name/vendor/serial to its current address set.
- Normalized `ble-obs/1` observation records from every capture
  (`scripts/ble-observe.py`, batch and streaming), stamped with the sensor
  identity from `config/interfaces.conf` and absolute timestamps.
- Live alerting: `scripts/ble-live-watch.sh` runs the same detector over a
  sliding window and writes `ble-alert/1` JSON records beside the
  observations and the btsnoop trace.
- A field menu, `scripts/skid-finder.sh`, that only builds command lines,
  with `--list`, `--print` and `--run` for use without a terminal.
- Capture progress reporting, LE scan enablement driven by `bluetoothctl`
  over a FIFO, btsnoop traces, reversible AIO feature profiles, adapter
  mode switching, health and recovery scripts for the AC1200.
- `docs/sensor-net-notes.md` (the record schema and the triangulation
  plan), `docs/siem-ingestion.md` (record shapes and the intended shipper
  path, untested end to end), `docs/flipper-spam-capture.md` (the controlled
  recall-measurement procedure).
- CI: shellcheck for the shell, ruff for the Python, the full suite on
  every push and pull request.
- Apache-2.0 licence.

### Changed
- Renamed from the uConsole BLE toolkit to Skid Finder and reframed as
  uConsole-optimized rather than uConsole-only.
- Config files are parsed as data, never sourced, so a config file cannot
  run commands as root.

### Fixed
- LE scanning: `btmgmt find` silently does nothing when backgrounded, so
  every capture used to come back empty.
- The documented live pipeline never enabled a scan and let btmon
  block-buffer into the pipe; the wrapper replaces it.
- The observer ignored `SENSOR_ID` in the config file and stamped every
  record `unknown`.
- Detector false positives on ordinary crowds: rules now key on address
  reuse shape, not on volume or on the random-address ratio.

[Unreleased]: https://github.com/ChiefGyk3D/Skid-Finder/compare/v0.3.0-alpha.1...HEAD
[0.3.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.3.0-alpha.1
[0.2.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.2.0-alpha.1
[0.1.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.1.0-alpha.1
