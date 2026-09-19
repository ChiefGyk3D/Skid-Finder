# Changelog

All notable changes to Skid Finder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions
follow [SemVer](https://semver.org/) with pre-release stages as defined in
[docs/ROADMAP.md](docs/ROADMAP.md). Record schemas (`ble-obs/1`,
`ble-alert/1`) are versioned separately and only change when a consumer
would break.

## [Unreleased]

### Added
- `scripts/evidence-bundle.sh`: the handoff for venue security or law
  enforcement. Given an incident record or a time window, it collects the
  observation, alert and incident lines inside the window (plus a margin),
  the traces whose run overlapped it, a plain-language summary and a
  sha256 manifest into one archive under `logs/evidence/`.
  `tests/test-evidence-bundle.sh` verifies the scoping and that the
  manifest checks out after extraction.
### Changed
- Fingerprints (identity keys `fp:…`) are version 2: built from Bluetooth
  SIG company ids and a normalised PDU class instead of vendor strings and
  the flags byte, so the btmon and tshark capture paths file the same
  device under the same key (asserted for identity, spam and ambient
  traffic in the fingerprint test). Records gain `company_ids`; the tshark
  path labels the common vendors by name. Keys from an older
  `logs/sightings.json` no longer match; the history rebuilds itself.

## [0.5.0-alpha.1] — 2026-09-19

**Alpha.** Everything below was exercised on a laptop's real adapter
without root or with stubbed tools in CI; the uConsole checklist is
unchanged. This is the version where the whole BLE workflow (capture,
field run, live alerting, foxhunt) runs on any laptop in the `wireshark`
group with no `sudo`, and where a SOC gets one incident per flood.

### Added
- `SECURITY.md` (what counts as a security report for a receive-only tool,
  where to send it), `CONTRIBUTING.md` (the rules that shape a change and
  what to include), and `docs/data-handling.md` (what is collected, what it
  is for and not for, retention, access, what to tell a venue or employer,
  evidence handoff).
- CI runs the suite on Python 3.11 (Raspberry Pi OS bookworm) and 3.13
  (Debian 13, Parrot, Ubuntu 26.04).
- `fleet-incident/1`: the collector groups a run of related fleet alerts
  into one incident (open on the first match, closed after
  `--incident-quiet` seconds without one), carrying sensors and families,
  the loudest sensor, peak rate, the location track, and the identities
  the matching sensors heard with their tiers. `--incidents-out` writes
  the open and close records; the open incident rides in `fleet-state/1`.
- `systemd/`: `skid-finder-sensor@.service` (live BLE alerting per adapter,
  root or a wireshark-group account), `skid-finder-collector.service`, and
  `skid-finder-retention.timer` running `scripts/retention-sweep.sh`
  (observations, captures and traces older than N days go; alerts,
  incidents, state, summaries, sightings and the watchlist stay;
  `--dry-run`). `docs/fixed-sensor.md` has the install and drop-ins.
  `tests/test-systemd-units.sh` verifies the units with systemd-analyze
  where available and the sweep's keep/delete sets.
- Foxhunting without root: `foxhunt-rssi.sh` takes its address/RSSI pairs
  from tshark's `bluetooth-monitor` stream when not root, so the whole
  BLE workflow (capture, field run, live alerting, foxhunt) runs on a
  laptop in the `wireshark` group without `sudo`.
- `./scripts/skid-finder.sh --doctor` (and the `doctor` menu entry): tools,
  privileges (including whether the unprivileged BLE route works here),
  adapters, Wi-Fi interface and monitor-mode capability, default-route
  warning, config files, root-owned logs. Every miss carries its fix.

### Changed
- The BLE and Wi-Fi live alerters share one windowing loop
  (`scripts/live_window.py`); each is now a small adapter naming its
  record type, detector and wording. No change in behaviour or output; a
  third modality adds an adapter rather than a copy of the loop.
- The menu prefixes `sudo` on BLE actions only when the unprivileged
  capture route is unavailable; Wi-Fi and AIO actions always get it.

## [0.4.0-alpha.1] — 2026-09-18

**Alpha.** The laptop paths below were exercised on real hardware (a
Parrot 7.3 laptop's internal adapter); the uConsole checklist is
unchanged.

### Added
- Live alerting without root: `ble-live-watch.sh` streams LE advertising
  reports from tshark's `bluetooth-monitor` interface as fields
  (`ble_parse.TSHARK_FIELDS`, a second parser feeding the same detector),
  with a separate tshark keeping the btsnoop trace. `ble-observe.py` and
  `ble-signature-scan.py` take `--format tshark`; `make-fixture.py` emits
  that spelling, and the corpus gate now holds the same verdict on the
  same traffic through both parsers.
- The ESP32 reference node compiles (ESP32 core 3.3.12, NimBLE-Arduino
  2.5.1, PubSubClient 2.8; 88% of the default app partition), with build
  instructions in `nodes/README.md`. Still not run on a board.
- Capture without root on laptops: members of the `wireshark` group record
  the HCI monitor channel through tshark's `bluetooth-monitor` interface;
  the toolkit rewrites it as btsnoop and renders it with `btmon -r`.
  `capture-btmon.sh`, `ble-spam-watch.sh` and `ble-field-run.sh` take that
  route automatically when not root (`need_capture_privileges`), keep the
  btsnoop artifact, and report progress honestly. Wi-Fi monitor mode stays
  root-only. `tests/test-unprivileged-capture.sh`.
- A second real ambient baseline in the corpus manifest: a Parrot 7.3
  laptop's internal adapter, captured unprivileged (the file itself stays
  git-ignored). Six ambient samples now; the gate holds at zero false
  positives.
- `docs/post-1.0-direction.md`: the post-1.0 tracks (Wi-Fi parity with
  BLE, LoRa/Meshtastic, other radios, enterprise defence and foxhunting),
  each with what is passively detectable, its honest limit, and what it
  needs; linked from the roadmap and README, tracked as milestones 6–9.

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

[Unreleased]: https://github.com/ChiefGyk3D/Skid-Finder/compare/v0.5.0-alpha.1...HEAD
[0.5.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.5.0-alpha.1
[0.4.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.4.0-alpha.1
[0.3.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.3.0-alpha.1
[0.2.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.2.0-alpha.1
[0.1.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.1.0-alpha.1
