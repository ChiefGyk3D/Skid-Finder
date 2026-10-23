# Bench runbook: the beta hardware checklist in one or two sittings

This orders the ten items of the [hardware checklist](ROADMAP.md#the-hardware-checklist-alpha--beta)
(issues #58 to #67) by shared setup, so each power-up, each radio mode and
each Flipper session is used once. Tick the boxes in `ROADMAP.md` and close
the issues only with the capture or the log that proves them.

Everything here is receive-only. The Flipper Zero is the only transmitter,
it is the test source, and it runs only in Part 3, in a contained room.

## What you need

- The uConsole with the AIO v2 and the AC1200 (MT7921) installed, charged.
- A Flipper Zero with a BLE spam app, charged. Read
  [flipper-spam-capture.md](flipper-spam-capture.md) first: contained room,
  no bystanders, nearby phones in airplane mode, short transmit windows.
- A second node for Part 2: a laptop on the same network, or an ESP32 board
  with a USB cable.
- A host for the MQTT broker (the laptop is fine) on a network both nodes
  reach. Not the venue Wi-Fi; see [sensor-nodes.md](sensor-nodes.md#security).
- The tree on the uConsole, either from a clone or from
  `hammunition install skid-finder` (issue #69). Installed under
  `/usr/local/share/hammunition/skid-finder` it is run in place.

Keep a notes file open for the whole session and paste each command's
output into it. The closing step needs the evidence.

## Part 0: at the desk, no radio traffic (about 30 minutes)

### 0.1 Configure (once)

```bash
cd /path/to/Skid-Finder
cp config/interfaces.conf.example config/interfaces.conf
hciconfig -a | grep -E '^hci|BD Address'
iw dev | awk '/Interface/{print $2}'
```

Set in `config/interfaces.conf`: `PRIMARY_HCI`/`CAPTURE_HCI` (CM4 radio,
normally `hci0`), `SECONDARY_HCI`/`HUNT_HCI` (AC1200, normally `hci1`),
`WIFI_IFACE` (normally `wlan1`; `wlan0` is the CM4), and a unique
`SENSOR_ID`. Leave `MQTT_HOST` empty until Part 2.

### 0.2 Doctor (#64)

```bash
./scripts/skid-finder.sh --doctor
```

Pass when it names the AC1200, both Bluetooth adapters and the Wi-Fi
interface correctly, and every "fix" line it prints is either empty or
something you can act on. Record the whole output. A wrong or missing name is
the finding; file it as a bug against `--doctor` and carry on.

### 0.3 Menu on the 1280x480 display (#63)

```bash
./scripts/skid-finder.sh
```

On the uConsole screen, walk every menu entry down to its first prompt and
back, with the console font you actually use. Record: any screen that
overflows or wraps unreadably (note the entry and the row count), and whether
every action is reachable one-handed. `./scripts/skid-finder.sh --list`
prints the entries so none are missed. Cancel out of each action; nothing
needs to run here.

### 0.4 Compile and flash the ESP32 (#67, first half)

Skip if the second node in Part 2 is a laptop, and run this part later.

```bash
arduino-cli compile --fqbn esp32:esp32:esp32 nodes/esp32/skidfinder_node
arduino-cli upload  --fqbn esp32:esp32:esp32 -p /dev/ttyUSB0 nodes/esp32/skidfinder_node
```

First edit the `configure these` block at the top of the sketch: Wi-Fi
credentials, the broker address from Part 2, a unique sensor id. Use the
`huge_app` partition scheme (the sketch is 88% of the default). Open the
serial monitor and record whether it connects to Wi-Fi and the broker and
prints scan activity. Do not commit the edited sketch.

## Part 1: quiet radio (about 45 minutes)

Do this before the Flipper is powered on, in the quietest place you can get.
Phones and watches in the room are normal ambient traffic; the point is a
baseline with no spam in it.

### 1.1 Adapter stability starts now (#62)

Note the time. For the rest of the session, whenever `hci1` drops or stops
scanning, run:

```bash
sudo ./scripts/recover-hci.sh hci1
```

Record each drop: what you were doing, what `recover-hci.sh` reported, and
whether it fixed it. The pass condition is either no drop for the session, or
every drop recovered by `recover-hci.sh`, in which case that script is the
documented fix and the issue closes by naming it in `TROUBLESHOOTING.md`.

### 1.2 BLE ambient baseline on the AC1200 (#58)

```bash
sudo ./scripts/capture-btmon.sh hci1 300
latest=$(ls -1t logs/btmon-hci1-*.log | head -1)
./scripts/add-corpus-sample.sh --label ambient --capture "$latest" \
  --note "uConsole AC1200, quiet room, no spam present" --run
```

Pass when the harness run that `--run` triggers reports zero matches on
`strict`, `balanced` and `aggressive`. If anything matches, that is a
finding: save the offending window, do not tune thresholds in the field.

If you also want the CM4 radio's baseline, repeat with `hci0` and a different
`--note`.

### 1.3 End-to-end field run (#61)

```bash
sudo ./scripts/ble-field-run.sh hci1 300
```

Pass when it finishes without intervention and leaves a summary, an
observation file and a trace in `logs/`. Then open the produced
`logs/obs-hci1-*.jsonl` and confirm the records carry your `SENSOR_ID`.
Run the same thing once from the menu so the menu path is exercised too.
Record the summary text.

### 1.4 Wi-Fi monitor mode and a real ambient capture (#65)

```bash
tshark --version | head -1
sudo ./scripts/wifi-capture.sh wlan1 120
```

Record, in order:

1. Whether monitor mode came up on the MT7921 without NetworkManager or
   `wpa_supplicant` taking the interface back. If it fights, capture
   `journalctl -u NetworkManager -n 50` and the exact symptom; that is the
   troubleshooting entry to write.
2. That the interface returned to managed mode afterwards (`iw dev`).
3. The tshark version, and how `wlan.ssid` and `wlan.fc.type_subtype` print
   in the produced `logs/wifi-wlan1-*.tsv` (hex or text, hex or decimal).
   The parser accepts both; the check is that the real output parses.
4. The fingerprint fields (`wlan.tag.number`, `wlan.supported_rates`,
   `wlan.ht.capabilities`, `wlan.tag.oui`) are present and non-empty on probe
   requests.

Then run the live path for a few minutes and confirm it stays silent:

```bash
sudo ./scripts/wifi-live-watch.sh wlan1 180 balanced
```

Add the `.tsv` as the first real Wi-Fi ambient sample: copy it into
`tests/corpus/real/` and add one `{"kind":"real","label":"ambient",...}`
line to `tests/corpus/wifi-manifest.jsonl`, shaped like the real entries in
`tests/corpus/manifest.jsonl`, then run
`python3 tests/test-detector-metrics.py --modality wifi`. The `real/`
directory is git-ignored on purpose: raw captures hold real device
addresses and never get committed.

## Part 2: two nodes, one collector (about 30 minutes)

### 2.1 Broker and collector on the laptop (#66)

On the laptop, run any MQTT broker on the management network (for example
`mosquitto`). Then start the collector:

```bash
./scripts/ble-collector.py --mqtt --state logs/fleet-state.json
```

### 2.2 The uConsole publishes

In the uConsole's `config/interfaces.conf` set `MQTT_HOST` to the laptop and
leave `MQTT_TLS="no"` for this lab test only. Credentials, if the broker
wants them, go in the environment, never the file:

```bash
export MQTT_USERNAME=...   # your broker user
export MQTT_PASSWORD=...
sudo -E ./scripts/ble-live-watch.sh hci1 120 balanced
```

### 2.3 The second node publishes

Either the ESP32 from 0.4 (powered, near the broker's network) or the laptop
itself with a different `SENSOR_ID` running `ble-live-watch.sh`. Pass when
the collector's `logs/fleet-state.json` shows both `SENSOR_ID`s, and an
identity heard by both is merged into one entry rather than duplicated.
Record `jq` of the state file, and the `sensor-status/1` heartbeat from each
node.

If the second node is the ESP32, this also closes #67: it scans, the JSON it
builds parses, and the collector accepts its records. If the collector
rejects any, copy the rejected line verbatim into the issue.

## Part 3: the Flipper (about 40 minutes; contained room only)

Move to the contained room. Phones in airplane mode. Re-read
[flipper-spam-capture.md](flipper-spam-capture.md) once more.

### 3.1 One capture per mode (#59)

For each mode in this order: Apple, Fast Pair, SwiftPair, Samsung. Start the
capture, start the Flipper for the 30 second window, stop it when the capture
ends.

```bash
sudo ./scripts/capture-btmon.sh hci1 30
latest=$(ls -1t logs/btmon-hci1-*.log | head -1)
./scripts/add-corpus-sample.sh --label spam --capture "$latest" \
  --families flipper,name_rotation \
  --note "Flipper Zero, Apple mode, contained room, AC1200" --run
```

Change `--families` and `--note` per mode using the table in
[flipper-spam-capture.md](flipper-spam-capture.md). Pass when `balanced` and
`aggressive` report recall 1.00 across all four. A family that did not fire is
a coverage finding, not a failure: keep the sample, record which family
missed, and tune later from the data.

### 3.2 Live alerting fires and goes quiet (#60)

```bash
sudo ./scripts/ble-live-watch.sh hci1 180 balanced
```

Start the Flipper about 30 seconds in, run it for 60 seconds, stop it, and
let the watch run to the end. Pass when an alert record appears within one or
two windows (`WINDOW` is 30 seconds by default) of the Flipper starting and
the alerts stop within a window or two of it stopping. Record the first alert
timestamp, the Flipper start and stop times from your own clock, and
`logs/alerts-hci1-*.jsonl`.

## Part 4: close out

1. Put the session's evidence somewhere durable. Raw captures stay out of
   git; the notes file, the doctor output, the harness results and the
   alert timestamps go into the issues.
2. For each issue, comment with the command, the output that shows the pass
   condition, and the date. Close only the ones that passed.
3. In one commit, tick the matching boxes in `docs/ROADMAP.md` and update
   the README caveats those boxes refer to. If anything failed, leave the box
   open and file the defect first.
4. When all ten pass, cut `v0.9.0-beta.1` by the procedure in
   [ROADMAP.md](ROADMAP.md#cutting-a-release) (#68), then re-pin Hammunition
   to it (#69).

## If you only get one sitting

Do Part 0.2 and 0.3 (they need no quiet), then Part 1.2 and 1.4 (the two
baselines the thresholds are waiting for), then Part 3. Those are the
captures that cannot be reconstructed afterwards. Parts 0.4 and 2 can follow
on the desk with no radio conditions to control.

## Order and why

| Part | Items | Shares |
|---|---|---|
| 0 | #64, #63, #67 flash | no radio traffic, desk |
| 1 | #62 (runs all session), #58, #61, #65 | quiet room, before the Flipper powers on |
| 2 | #66, #67 | the broker, once |
| 3 | #59, #60 | the Flipper and the contained room, once |
| 4 | #68 | after all of the above |
