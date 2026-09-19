# Skid Finder

Defensive BLE monitoring toolkit for conference environments (DEF CON, BSides). Skid Finder detects scripted BLE spam and flood tooling — the kind run by "skids" — and lets you foxhunt the source. It is optimized for the ClockworkPi uConsole but runs on other Linux devices too.

Skid Finder started out focused on a single rig — the ClockworkPi uConsole paired with the HackerGadgets AIO v2 — and has since expanded to run on more hardware. The longer-term goal is to grow it into a distributed sensor net, with multiple cooperating nodes monitoring an environment together rather than a single hand-carried device.

Hardware support:
- **Optimized for** the ClockworkPi uConsole with AIO v2 — the defaults, docs, and field workflow are all tuned for this rig.
- **Runs on** any Linux device with a compatible Bluetooth adapter (laptops, mini PCs, SBCs). The same scripts work here; you just supply your own adapter and interface config.

uConsole-specific behavior (AIO feature profiles, dual-adapter assumptions) is layered on top and stays out of the way on other hardware, so nothing here is uConsole-only.

This toolkit is designed for a dual-adapter setup:
- CM4 built-in Bluetooth (usually `hci0`) for broad monitoring
- External adapter (usually `hci1`) for focused foxhunt tracking

Out-of-box defaults are single-adapter safe:
- default mode is `dual` for stock uConsole + AIO v2 assumptions
- scripts auto-fallback to `hci0` if `hci1` is missing or unstable
- one-command mode switch is available for `dual`, `single`, and `auto`

## Legal and Safety

**Operator Qualifications & Compliance:**
- This toolkit is operated under a **General Class Amateur Radio license** in compliance with US FCC regulations and all applicable US federal, state, and local laws.
- Amateur Radio licensing demonstrates intentional training in RF safety, interference prevention, and responsible spectrum use.
- This toolkit is **passive monitoring only**. Do not transmit, jam, deauth, or interfere.

**Critical Warning: BLE Spamming is Harmful and Often Illegal**

This toolkit is designed to **detect and analyze** BLE spam—**not to generate it**. Running BLE spam attacks in uncontrolled, public environments is:

- **Illegal** in most jurisdictions under FCC regulations and computer fraud/interference statutes
- **Dangerous**: BLE spam floods can interfere with emergency services (e.g., disrupting 911 call connectivity or emergency alert systems)
- **Deeply harmful to accessibility**: Hearing-impaired and disabled individuals rely on Bluetooth audio devices for communication, safety, and independence. BLE spam disrupts cochlear implants, hearing aids, and medical alert devices.
- **Unethical**: Subjecting non-consenting users to interference violates their autonomy and safety.

**There is a time and place.** Research involving intentional BLE spam belongs in controlled laboratory environments or isolated locations without public presence or cell coverage—never in public venues where people depend on reliable connectivity.

**Venue Authorization:**
- Use this toolkit only where passive RF monitoring is allowed and authorized by venue/event policy.
- This work has been reviewed and approved by BSidesLV 2026 SOC/NOC staff.
- Initial concerns about extensive antenna equipment were addressed through transparent explanation of the research goals and methodology.
- Multiple BSidesLV staff members have expressed full support and have offered to vouch for this work if needed.

**Community Context:**
- Cybersecurity conferences have historically faced scrutiny and displacement due to security concerns and regulatory paranoia. DEFCON 32 was nearly cancelled when Caesar's Palace withdrew venue support mid-event, leading to the last-minute relocation to Las Vegas Convention Center and the iconic "DEFCON Un-Cancelled" t-shirt.
- This toolkit is built with deep care for the infosec community and its future. Ethical, legal, responsible research strengthens trust in our field and helps venues welcome and protect the conferences we love.
- Responsible boundaries are essential: more aggressive or invasive experiments are conducted in controlled home environments or isolated locations without cell coverage, never at public venues.

**Thank You:**
- Deep gratitude to BSidesLV 2026 SOC/NOC staff for engaging openly, understanding the research mission, and championing ethical experimental work that improves conference security posture and protects community trust.

## Features

- Discover available HCI adapters
- Capture raw BLE monitor output via `btmon`
- Summarize top BLE advertisers and flag high-rate senders
- Match defensive signatures for common scripted BLE spam/flood behaviors
- Live target RSSI tracking for hot/cold foxhunt movement
- Optional dual-pane tmux session for monitor + hunt workflow
- One-command capture plus summary report for field sessions
- Reversible AIO feature profiles to reduce noise and power draw during BLE operations

## Hardware

This toolkit is optimized for uConsole with AIO v2. Optional USB-C expansion adapters sourced from [HackerGadgets.com](https://www.hackergadgets.com/):

- **AC1200 USB-C Wi-Fi Card** (MediaTek MT7921AUN): Dual Bluetooth adapter for parallel capture/hunt workflows; passive BLE 5.2 monitoring + active WiFi 6E connectivity; swappable IPEX antennas.
- **Dual-adapter mode** leverages hci0 (internal) for continuous capture and hci1 (AC1200 external) for live target tracking, or fallback to single-adapter on compatible hardware.

The uConsole rig is what everything is tuned around, but it is not required. Any Linux machine with one or more BlueZ-compatible HCI adapters will run the same capture, signature, and foxhunt workflows — a single built-in adapter is enough to get started, and a second USB adapter unlocks dual-adapter mode on any host.

## Install (Raspberry Pi OS / Debian)

### Prerequisite: install the AIO v2 support first

On a uConsole, install and reboot into the ClockworkPi AIO v2 support before
installing this toolkit. That installer owns the boot configuration and the
kernel modules that bring the radios up; this toolkit deliberately owns none
of it, and only makes runtime-reversible changes such as `rfkill block` and
stopping a service for the duration of a field session. Keeping boot-critical
configuration out of a scanning tool means a bad field profile cannot leave
the device unbootable.

The practical consequence is ordering. If this toolkit is installed and
configured before the adapters enumerate, `detect-hci.sh` reports whatever
exists at that moment, so `hci1` looks absent and `config/interfaces.conf`
gets written for a single-adapter machine that is actually dual.

Confirm the radios are up before continuing:

```bash
hciconfig -a
```

Expect `hci0` for the CM4 internal radio, and `hci1` as well if an external
adapter such as the AC1200 is fitted. If a device is missing here it is a
platform problem, not a toolkit problem: recheck the AIO v2 install and
reboot. Note that some AC1200 variants are Wi-Fi only and expose no Bluetooth
at all, in which case single-adapter mode is correct and expected.

Already running the AIO v2 support? Nothing to redo; carry straight on.

### Install the toolkit

Primary path (uConsole + AIO v2):

```bash
git clone https://github.com/ChiefGyk3D/Skid-Finder.git
cd Skid-Finder
sudo ./scripts/setup-pi.sh
```

Secondary path (other apt-based Linux devices):

```bash
sudo ./scripts/setup-linux.sh
```

Both installers install `bluez`, `python3`, `rfkill` and `tmux` as hard
requirements, then add `bluez-tools`, `wireless-tools`, `iw` and `tshark`
individually, skipping any that the distribution does not carry. They verify
the binaries afterwards and fail loudly if something is still missing, since
package names and binary names do not always match.

None of these packages are provided by the AIO v2 installer, so there is
nothing to conflict with: this step only adds to what is already there.

`btmon` is a binary provided by the `bluez` package, not a standalone package.
If `btmon` is reported missing, install `bluez`.

Confirm the install before relying on it in the field:

```bash
./tests/test-toolkit.sh
```

### First run on any machine: doctor

```bash
./scripts/skid-finder.sh --doctor
```

One screen of measurements, never guesses: which tools are present, whether
BLE capture works without root here, which adapters exist and are up,
whether the configured Wi-Fi interface supports monitor mode and whether it
carries your default route, and which config files are missing. Every miss
is printed with its fix. It is also the first entry in the menu.

### Running on a laptop without root

`btmon` needs a capability only root has, but a laptop has another way in.
Members of the `wireshark` group can record the same HCI monitor channel
through tshark's `bluetooth-monitor` interface; the toolkit rewrites that
as btsnoop and renders it with `btmon -r`, so the capture, field run and
spam sweep work without `sudo`:

```bash
sudo usermod -aG wireshark "$USER"   # once, then log in again
tshark -D | grep bluetooth-monitor   # must be listed
./scripts/capture-btmon.sh hci0 30    # no sudo
./scripts/ble-field-run.sh hci0 60
```

Live alerting works without root too: `ble-live-watch.sh` streams the
same advertising reports from tshark as fields, one line per report, into
the same observer and detector, and a second tshark keeps the btsnoop
trace. When the unprivileged route is available the menu drops `sudo` from the
BLE actions automatically; Wi-Fi and the AIO profiles keep it. Differences
from the root path: the batch captures render their text
log when the capture ends (so running counts are not shown), the monitor
channel carries every adapter rather than one, and the content fingerprint
of a device differs between the two paths because tshark names a vendor by
id (`0x004c`) where btmon names it (`apple, inc.`). Wi-Fi monitor mode
still needs root.

Measured on a Parrot 7.3 laptop on 2026-09-18: a 30 s unprivileged capture
rendered 74 advertising reports and matched no signature on any profile
(recorded as a real ambient baseline in the corpus), and a 25 s
unprivileged live watch produced 67 observations with absolute timestamps,
a converted btsnoop trace and alert records. The corpus gate also holds
the same verdict on the same synthetic traffic in both spellings.

## Configure Interfaces

```bash
cp config/interfaces.conf.example config/interfaces.conf
nano config/interfaces.conf
```

Config files are parsed as plain `KEY=value` data, not executed as shell.
Only recognized settings are applied; anything else is reported and ignored.

Then discover adapter names:

```bash
./scripts/detect-hci.sh
```

Switch adapter mode quickly:

```bash
./scripts/set-adapter-mode.sh status
./scripts/set-adapter-mode.sh dual
./scripts/set-adapter-mode.sh single
./scripts/set-adapter-mode.sh auto
```

## Typical Mapping

- `hci0`: Pi CM4 internal Bluetooth
- `hci1`: external USB Bluetooth (if present)

Note: some AC1200 adapters are Wi-Fi-only and do not expose Bluetooth.

Verify by unplug/replug external adapter and rerun detection.

Mode behavior:
- `dual`: capture prefers `hci0`, hunt prefers `hci1`
- `single`: capture and hunt use one adapter
- `auto`: uses dual when `hci1` exists, otherwise single-like fallback

## Usage

### 0) The field menu

Everything below is a script with positional arguments, which is a poor fit
for a uConsole used one-handed, standing up. The menu covers the common paths
so nothing has to be typed from memory:

```bash
./scripts/skid-finder.sh
```

It only builds command lines. Each action shows the exact command before it
runs, every action is reachable without the menu, and as a normal user only
the radio actions are prefixed with `sudo`, so analysis artifacts such as
`logs/sightings.json` stay owned by you. It uses `whiptail`, which Raspberry
Pi OS already ships. For scripting or when there is no terminal:

```bash
./scripts/skid-finder.sh --list                 # actions and their arguments
./scripts/skid-finder.sh --print field hci0 120 # show the command, run nothing
./scripts/skid-finder.sh --run watch            # run one action and exit
```

### 1) Detection sweep

```bash
sudo ./scripts/ble-spam-watch.sh
```

At the end of each sweep, the script also runs a defensive signature scan and reports likely matches such as:
- Flipper-like Apple popup spam pattern
- Marauder-like rotating beacon flood
- Fast Pair lure flood pattern
- Generic BLE spam burst
- Random-address churn flood
- Lure-name rotation burst

Arguments:
- interface (default from config)
- duration seconds
- alert threshold (ads per address during window)

Signature tuning options:
- sensitivity profile: conservative, balanced, aggressive
- optional local overrides via config/signatures.conf

Example:

```bash
python3 scripts/ble-signature-scan.py --input logs/btmon-hci0-YYYYMMDD-HHMMSS.log --profile conservative
```

#### Baseline before you trust a threshold

The shipped thresholds were measured on a hacker-conference floor, where
ambient traffic is far denser than normal and some of it is genuinely
hostile. That makes them defensible there and unproven anywhere else. Take
your own baseline somewhere quiet before relying on a verdict:

```bash
sudo ./scripts/capture-btmon.sh
python3 scripts/ble-signature-scan.py --input logs/<capture>.log
```

Nothing should match on ordinary ambient traffic. If something does, raise the
thresholds it tripped in `config/signatures.conf`. The scanner prints
`config_source=` so you can confirm which thresholds were actually used, and
warns on stderr about keys it does not recognise — an unrecognised key keeps
its default rather than taking effect.

Two things learned from real captures that are worth knowing before you tune:

- **A high proportion of random addresses is not evidence of spam.** In plain
  ambient traffic 94% of addresses were random, because privacy-preserving
  address rotation is now the norm. Any rule keyed on address randomness fires
  on everybody. `unique_ratio` and `singleton_ratio` are what actually
  separate a flood from a crowd.
- **Short captures cannot be judged.** A two second sample can look like
  anything, so the scanner refuses to reach a verdict below
  `min_duration_sec`. Give it at least 10-20 seconds.

### 2) Raw capture for later analysis

```bash
sudo ./scripts/capture-btmon.sh
```

Creates logs under `logs/`.

### 3) Foxhunt a known sender

```bash
sudo ./scripts/foxhunt-rssi.sh AA:BB:CC:DD:EE:FF
```

Walk slowly and compare median RSSI trend over time.
Rising (less negative) median indicates moving closer.

Instantaneous RSSI is far too noisy to navigate by, so the median over a
sliding window is what you steer on. The tool prints a `waiting:` line when the
target has not been heard for a few seconds; many devices advertise only every
few seconds, so silence usually means "not yet" rather than "broken".

### 3a) Identify and track devices across captures

```bash
./scripts/ble-fingerprint.py --input logs/btmon-hci0-YYYYMMDD-HHMMSS.log
```

This records every advertiser in `logs/sightings.json`, so devices seen in an
earlier capture are flagged with `*` when they turn up again.

Tracking a device is not simply tracking its MAC. Most modern devices advertise
with addresses that rotate every few minutes. In a 25 second sample taken on a
conference floor, 63% of addresses were rotating, 33% were random static, and
only 4% were public. Each device therefore gets an identity tier, and the tier
is the part worth reading:

| Tier | Meaning | Reliable for |
|---|---|---|
| `strong` | public address, or a serial number in the advertised name | identifying an individual unit |
| `session` | random static address | one unit until it reboots |
| `model` | rotating address; only the advertisement's structure persists | identifying a product, not a unit |
| `ambiguous` | too little distinguishing content to attribute at all | nothing |

`model` and `ambiguous` hits are leads, not identifications. Several people
carrying the same earbuds produce one `model` fingerprint. In one real capture
three different devices all advertised the name `AC695X_1`, a chipset used by
many cheap earbud vendors.

Keep a list of devices worth flagging:

```bash
cp config/watchlist.conf.example config/watchlist.conf
./scripts/ble-fingerprint.py --input logs/capture.log --watchlist config/watchlist.conf
```

### 3b) Hunt a device whose address rotates

Resolve a target by name, vendor, serial or fingerprint, then track every
address it is currently using:

```bash
sudo ./scripts/foxhunt-rssi.sh --hunt "flipper" --from-capture logs/capture.log
```

Read the tier warning it prints. If the target resolved at `model` or
`ambiguous` tier the address set may span several different devices, and the
RSSI trend will jump between them as you walk.

To supply targets yourself:

```bash
./scripts/ble-fingerprint.py --input logs/capture.log --hunt "whoop" > targets.txt
sudo ./scripts/foxhunt-rssi.sh --targets targets.txt
```

### 3c) Normalized observations and live alerting

The capture-then-analyze scripts judge a log only after the run finishes. For
live alerting, for combining several sensors, and as the shared shape a future
Wi-Fi frontend will reuse, captures can be emitted as normalized JSON Lines,
one object per advertising report, stamped with which sensor saw it:

```bash
# Alert on spam live. Runs until Ctrl+C; give a duration in seconds to bound it.
sudo ./scripts/ble-live-watch.sh
sudo ./scripts/ble-live-watch.sh hci0 120 aggressive

# Convert a finished capture to a normalized stream.
./scripts/ble-observe.py --input logs/capture.log --out logs/obs.jsonl
```

`ble-live-watch.sh` enables an LE scan on the radio for the run (btmon alone
records nothing on an idle adapter), line-buffers btmon so each advert reaches
the detector as it lands, and leaves two artifacts behind: the `.btsnoop`
trace and `logs/obs-<iface>-<timestamp>.jsonl`, one record per advert with
absolute timestamps. `ble-field-run.sh` writes the same `obs-*.jsonl` beside
its summary, so every capture already produces the file a collector or SIEM
ingests.

The live alerter runs the *same* detector as the batch scanner over a sliding
window, so a threshold tuned in `config/signatures.conf` changes both. Set
`SENSOR_ID`, and optionally `SENSOR_LAT`/`SENSOR_LON`, in
`config/interfaces.conf` so every observation is attributable to a sensor;
the observer reads them from there, and the environment overrides the file.

Under the hood the wrapper runs this pipeline, which you can assemble yourself
if you need to (the LE scan is the part that is easy to forget):

```bash
sudo stdbuf -oL btmon -i hci0 \
  | ./scripts/ble-observe.py --stream --epoch-base now \
  | ./scripts/ble-live-alert.py --window 30 --interval 5 --profile balanced
```

See [docs/sensor-net-notes.md](docs/sensor-net-notes.md) for the `ble-obs/1`
schema and how this becomes the foundation for a triangulating sensor net,
and [docs/siem-ingestion.md](docs/siem-ingestion.md) for the `ble-alert/1`
record the live watcher writes and how to ship both files to a SIEM.

### 3e) Wi-Fi: deauth floods, fake APs, evil twins, KARMA responders

The same shape for 802.11, passive only:

```bash
sudo ./scripts/wifi-capture.sh wlan1 60                   # capture + field extract to logs/
python3 scripts/wifi-signature-scan.py --input logs/wifi-wlan1-<stamp>.tsv
sudo ./scripts/wifi-live-watch.sh wlan1                   # live alerts, wifi-obs/1 + wifi-alert/1 records
```

Set `WIFI_IFACE` (on the uConsole + AC1200 usually `wlan1`) and the hop list
in `config/interfaces.conf`. The wrappers put the adapter in monitor mode,
hop channels, and restore it on exit. Records carry the same envelope as the
BLE ones, so the collector, publisher and SIEM path handle both. Families,
caveats and what must be verified on hardware are in
[docs/wifi-notes.md](docs/wifi-notes.md). None of the Wi-Fi thresholds have
been baselined on a real venue yet.

### 3d) Sensor net: several nodes, one collector

Set `MQTT_HOST` (and the rest of the `MQTT_*` keys) in
`config/interfaces.conf` and `ble-live-watch.sh` ships every observation and
alert record to the broker as it is written, with a retained heartbeat. On
the machine that watches the fleet:

```bash
./scripts/ble-collector.py --mqtt --state logs/fleet-state.json --alerts-out logs/fleet-alerts.jsonl
```

The collector merges devices across sensors by identity, judges every
sensor's recent window with the same detector, estimates where a
`strong`/`session` device or a flood is, with the error bar stated, and
groups a run of alerts into one `fleet-incident/1` record
(`--incidents-out`) so a SOC gets one ticket per flood. Nodes
that cannot reach a broker drop files into a directory it watches instead
(`--watch DIR`), and finished captures can be merged after the fact
(`--input logs/obs-*.jsonl`). The node contract, including an ESP32
reference sketch, is in [docs/sensor-nodes.md](docs/sensor-nodes.md).

### 4) Dual-pane session

```bash
sudo ./scripts/start-dual-session.sh
```

Left pane: spam monitor on capture interface.
Right pane: ready for target RSSI tracking command.

### 5) One-command field run (capture + summary)

```bash
sudo ./scripts/ble-field-run.sh
```

Outputs:
- `logs/btmon-<iface>-<timestamp>.log` and `.btsnoop`
- `logs/obs-<iface>-<timestamp>.jsonl` (normalized observations, see 3c)
- `logs/summary-<iface>-<timestamp>.txt`

The summary now includes a signature scan section based on the captured `btmon` log.

### 6) AIO feature profile modes (disable unused subsystems)

Default profile script behavior is conservative and reversible.

```bash
sudo ./scripts/aio-feature-profile.sh ble-only
sudo ./scripts/aio-feature-profile.sh ble-gps
sudo ./scripts/aio-feature-profile.sh ble-gps-lora
sudo ./scripts/aio-feature-profile.sh restore
```

Customize target interfaces/services:

```bash
cp config/aio-features.conf.example config/aio-features.conf
nano config/aio-features.conf
```

The script writes and uses `logs/aio-state-latest.state` to restore previous interface and service states.

## Validation suite

Run the full local validation suite before a field session:

```bash
./tests/test-toolkit.sh
```

This checks shell syntax for the toolkit scripts, runs `shellcheck` and `ruff` when they are installed, confirms the example config files exist, exercises the signature, fingerprint, GPS-merge, normalized-observation, live-watch and field-menu regression tests, measures detector false-positive rate and recall against the labeled corpus, verifies the capture pipeline survives its own timeout, and writes a timestamped report under `logs/`.

The same suite runs in CI on every push and pull request. To match CI locally, install `shellcheck`:

```bash
sudo apt install -y shellcheck
```

## How scanning works

`btmon` is a passive observer of the local HCI channel. It does not start a scan
itself, and a Bluetooth controller only emits `LE Advertising Report` events
while an LE scan is active. A capture taken on an otherwise idle adapter will
therefore be nearly empty.

The capture scripts handle this for you: they enable LE scanning on the target
interface for the duration of the run and stop it again on exit, including when
you interrupt with Ctrl+C. If `btmgmt` is unavailable the scripts warn and
continue, and you can start a scan yourself in another shell:

```bash
bluetoothctl scan on
```

If a capture completes with no advertising reports, the scripts say so rather
than letting an empty result look like a quiet RF environment.

### Capture artifacts

Captures produce both a human-readable text log and a compact `.btsnoop`
binary trace:

```bash
btmon -r logs/btmon-hci0-<timestamp>.btsnoop   # replay the capture
btmon -a logs/btmon-hci0-<timestamp>.btsnoop   # summarize the capture
```

The `.btsnoop` file is far smaller than the text log and is the better artifact
to share with venue SOC/NOC staff or attach to a bug report.

## Optional GPS-assisted plotting

For future mapping work, you can merge BLE observations with GPS coordinates into a CSV that is easy to plot. GPS is optional, so the workflow still works if the GPS source is unavailable or unreliable:

```bash
python3 scripts/ble-gps-merge.py --gps /path/to/gps.csv --ble /path/to/ble.csv --output logs/ble-gps-plot.csv
```

If you omit `--gps`, the script still writes the BLE rows and leaves the latitude/longitude fields blank.

See `docs/gps-plotting-notes.md` for the intended workflow and output schema.

## Practical Conference Workflow

1. Run spam watch near suspected area.
2. Note high-rate address candidates.
3. Validate with repeat scans from different locations.
4. Pick target and switch to RSSI tracking on second adapter.
5. Move in short steps and follow median RSSI increase.

## Field Operation Checklist

Use this sequence when you are actively operating in the field.

1. Pull latest changes:

```bash
git pull
```

2. Enter BLE-focused mode (pick one):

```bash
sudo ./scripts/aio-feature-profile.sh ble-only
sudo ./scripts/aio-feature-profile.sh ble-gps
sudo ./scripts/aio-feature-profile.sh ble-gps-lora
```

3. Run health check:

```bash
./scripts/troubleshoot-bluetooth.sh
```

4. If second adapter is unstable, run recovery:

```bash
sudo ./scripts/recover-hci.sh hci1
```

5. Capture and summarize in one run:

```bash
sudo ./scripts/ble-field-run.sh
```

6. Read the newest summary and select hunt targets:

```bash
latest=$(ls -1t logs/summary-*.txt | head -n 1)
sed -n '1,220p' "$latest"
```

7. Foxhunt a selected target:

```bash
sudo ./scripts/foxhunt-rssi.sh AA:BB:CC:DD:EE:FF hci0
```

8. Restore normal system profile after operation:

```bash
sudo ./scripts/aio-feature-profile.sh restore
```

9. Archive logs before moving locations:

```bash
mkdir -p ~/field-archives
tar -czf ~/field-archives/ble-$(date +%Y%m%d-%H%M%S).tgz logs/
```

## Git Initialization

```bash
git init
git add .
git commit -m "Initial Skid Finder BLE spam detector and foxhunt toolkit"
```

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for adapter detection, `hci1` local-name errors, package install issues, and single-adapter fallback workflows.

Quick report command:

```bash
./scripts/troubleshoot-bluetooth.sh
```

Auto-recovery command (runs before/after diagnostics):

```bash
sudo ./scripts/recover-hci.sh
```

MediaTek AC1200-specific diagnostic report:

```bash
./scripts/diagnose-mediatek-ac1200.sh
```

## Notes

- BLE spammers may rotate MAC addresses quickly.
- Address-only logic can miss rotating identities.
- Signature matches are heuristic and defensive, not attribution-grade proof of a specific tool.
- Coverage is strong for common scripted BLE spam patterns but not exhaustive for every custom payload seen during Hacker Summer Camp.

## Versions and stages

The current version is in `VERSION` (`./scripts/skid-finder.sh --version`
prints it). Versions, the alpha/beta/rc/stable stages and what has to be
measured before each label is used are defined in
[docs/ROADMAP.md](docs/ROADMAP.md); every release is recorded in
[CHANGELOG.md](CHANGELOG.md) and tagged. Anything at `0.x-alpha` is green in
CI but not yet confirmed on the uConsole hardware.

## Known Limitations and Roadmap

Open work, kept here rather than in a tracker so the caveats travel with the
tool. The milestone view of the same list is [docs/ROADMAP.md](docs/ROADMAP.md),
and what comes after 1.0 (Wi-Fi fingerprinting and foxhunting, LoRa and
Meshtastic, 802.15.4, sub-GHz, cellular, GNSS, spectrum watch, and the
enterprise operations layer) is in
[docs/post-1.0-direction.md](docs/post-1.0-direction.md).

### Detector thresholds are measured, but not yet against real quiet RF

Every threshold in the detector was set during Hacker Summer Camp 2026, on the
BSidesLV floor at the Tuscany. That environment is both far denser than normal
and genuinely full of BLE spam, so a clean ambient sample was never available
while the numbers were being set. The thresholds are workable and they no
longer fire on ordinary conference traffic, but "does not fire in a hostile
environment" is a weaker claim than "fires only on hostile traffic".

What now exists to close this:

- A labeled corpus and a metrics harness, `tests/test-detector-metrics.py`,
  which runs the detector across every sample for every profile and reports
  false-positive rate and recall. It fails the build if ambient traffic
  matches anything or spam recall drops. This is a regression guard, not just a
  report, and it runs in CI.
- A committed slot for **your own real captures** under `tests/corpus/real/`
  (git-ignored for privacy and size). Record one with
  `scripts/add-corpus-sample.sh --label ambient --capture <log> --run` and the
  same harness measures the detector against real quiet RF instead of only
  synthetic traffic. See `tests/corpus/real/README.md`.
- The recall side needs real hostile traffic, which a quiet baseline cannot
  provide. To produce one safely, capture your own Flipper Zero's BLE spam in a
  contained environment and record it with `--label spam`. See
  [docs/flipper-spam-capture.md](docs/flipper-spam-capture.md).

The remaining gap is the one only hardware can close: capturing that real quiet
baseline. Until you have, the scanner still prints a stderr note whenever it
uses built-in thresholds, and a match is a lead worth investigating rather than
a verdict. Prefer your own `config/signatures.conf` over the shipped defaults
once you have measured your environment.

### The field menu has not been used on the uConsole yet

`scripts/skid-finder.sh` covers setup, adapter mode, health and recovery, the
sweep, field run, capture, foxhunt, fingerprinting and signature scans. Its
command building is tested (`tests/test-field-menu.sh`), but the `whiptail`
screens have only been exercised on a laptop. Sizing and flow on the uConsole's
1280x480 display are unverified; if a dialog is cut off or a prompt is in the
wrong order, that is a bug worth reporting with the screen size.

### Other open items

- Rotating addresses limit tracking by design. Roughly two thirds of observed
  addresses rotate, so `model` and `ambiguous` tier hits identify a product
  rather than a unit. Improving this means correlating advertising interval
  and timing, which is not implemented.
- Signature coverage targets common scripted spam. Custom payloads are not
  exhaustively covered.

### Sensor net (alpha: collector and transport exist, unproven on real nodes)

`scripts/ble-collector.py` merges records from several sensors over MQTT or
a watched directory, judges each sensor with the shared detector, and
estimates location as an RSSI-weighted centroid with its error stated. The
publisher and collector are tested against a stand-in broker in CI; neither
has been run against a real broker or a second physical node from this
project yet, and the ESP32 reference sketch has not been compiled here.

The honest caveat, recorded in [docs/sensor-net-notes.md](docs/sensor-net-notes.md):
RSSI-based location indoors is coarse (multipath swings readings by 20 dB), and
you can only locate an identity that persists across sensors — a `strong`
or `session` tier device, or a spam source that transmits continuously. A
`model`/`ambiguous` tier target is a product, possibly several people, and
the collector refuses to place it on a map. Multilateration with a
calibrated path-loss model is not implemented.

### SIEM and dashboards (records exist, pipeline untested)

Live runs write `logs/alerts-<iface>-<stamp>.jsonl`, one `ble-alert/1`
record per detector evaluation, beside the `ble-obs/1` observation file. Both
are JSON Lines a log shipper can pick up as-is. The record shapes and the
intended Wazuh/OpenSearch path are in
[docs/siem-ingestion.md](docs/siem-ingestion.md); no shipper configuration has
been exercised end to end from this toolkit yet, and there is no dashboard.

### Wi-Fi attack detection (alpha: synthetic-only thresholds, unrun on the AC1200)

`scripts/wifi-capture.sh`, `wifi-live-watch.sh`, `wifi-observe.py`,
`wifi-signature-scan.py` and `wifi-live-alert.py` detect deauth/disassoc
floods, beacon floods, evil twins and KARMA-style responders from a
monitor-mode capture and emit `wifi-obs/1` / `wifi-alert/1` records the
collector and publisher already carry. The thresholds are measured against
synthetic traffic only; the capture path has not been run on the MT7921
under the AIO v2 kernel from this project; and two tshark field
representations are handled by heuristic (see docs/wifi-notes.md). Probe-
request fingerprinting of randomised clients is not implemented. Passive
only: detection, never transmit.

### Tooling

Both the shell and the Python are now statically checked in CI: `shellcheck`
for the scripts, `ruff` for the Python (ruleset in `ruff.toml`). The detector's
behaviour is additionally measured, not just exercised, by
`tests/test-detector-metrics.py`.

## Contributing

Testing on additional hardware is especially welcome. When reporting an issue,
include the output of:

```bash
./scripts/troubleshoot-bluetooth.sh
./tests/test-toolkit.sh
```

Please run `shellcheck -S warning -x scripts/*.sh tests/*.sh` and
`ruff check scripts/*.py tests/*.py` before opening a pull request; CI enforces
both.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE).

Apache-2.0 was chosen so the toolkit stays usable in both open source and
corporate environments, and because it includes an explicit patent grant.
