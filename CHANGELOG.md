# Changelog

All notable changes to Skid Finder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions
follow [SemVer](https://semver.org/) with pre-release stages as defined in
[docs/ROADMAP.md](docs/ROADMAP.md). Record schemas (`ble-obs/1`,
`ble-alert/1`) are versioned separately and only change when a consumer
would break.

## [Unreleased]

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

[Unreleased]: https://github.com/ChiefGyk3D/Skid-Finder/compare/v0.1.0-alpha.1...HEAD
[0.1.0-alpha.1]: https://github.com/ChiefGyk3D/Skid-Finder/releases/tag/v0.1.0-alpha.1
