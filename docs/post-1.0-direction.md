# After 1.0: where detection goes next

1.0 is one thing done properly: BLE spam and the common Wi-Fi floods,
detected passively, measured against real baselines, foxhuntable, logged in
a shape a SIEM ingests, with several sensors feeding one collector. This
page records what comes after, so the direction is written down before the
work starts and each track can be argued with. Nothing here is promised for
a date; each track lands when it is measured.

Two rules carry over unchanged from everything before 1.0:

- **Receive-only.** Every track below detects. Nothing transmits, jams,
  deauthenticates, replays or associates. Where a technology can only be
  probed actively (RFID, most of NFC), the track says so and stops there.
- **Say what the data supports.** An identity tier travels with every
  record. A rotating address is a product, not a unit; a location is a
  centroid with an error bar; a signature names a pattern family, not a
  person. "Who is doing it" means "which device, how confident, seen where
  and when", never a name.

The tracks, in the order they are worth doing:

| Track | Milestone | Why this order |
|---|---|---|
| Wi-Fi parity with BLE | [#6](https://github.com/ChiefGyk3D/Skid-Finder/milestone/6) | The radio is already fitted and the detector exists; what is missing is the tracking half |
| LoRa and Meshtastic | [#7](https://github.com/ChiefGyk3D/Skid-Finder/milestone/7) | The AIO v2 carries a LoRa radio, the mesh is where skids go next, and the nodes are on hand |
| Other radios: 802.15.4, sub-GHz ISM, cellular, GNSS, spectrum | [#8](https://github.com/ChiefGyk3D/Skid-Finder/milestone/8) | Each needs a radio the rig has or a sibling project already covers |
| Enterprise defence and foxhunting | [#9](https://github.com/ChiefGyk3D/Skid-Finder/milestone/9) | Turns a detector into something a security team runs for a week |

## Track 1: Wi-Fi at parity with BLE

The Wi-Fi side detects four attack families. The BLE side also
fingerprints, keeps a sighting history, watches a list, and foxhunts by
name. Bring Wi-Fi to the same place.

**Fingerprinting randomised clients.** Modern clients randomise the MAC
per network and often per probe burst, so an address is a `session`
identity at best. What persists is the probe request's content: the
ordered list of SSIDs a device asks for, the order and values of its
tagged parameters (supported rates, HT/VHT/HE capabilities, vendor
specific elements), and its timing. A `wifi_identity.py` mirrors
`ble_identity.py`: a content fingerprint over those fields, tier `model`
by default, promoted to `session` when the same fingerprint holds one
address for the run. The honesty note is the same as BLE's: a fingerprint
identifies a product and a configuration, and two people with the same
phone and the same saved networks collapse together.

**Attack-source fingerprinting.** A deauth flood, a beacon spammer or a
KARMA responder has a signature of its own: sequence-number stride, the
exact reason code, the beacon interval, the capability bits it claims,
whether its BSSIDs share a prefix. Recording those per alert lets the
collector say "the same tool, again" across an event, which is the
"who is doing it" a venue actually needs.

**Sighting history and watchlist.** `wifi-fingerprint.py` with the same
`logs/sightings.json` store and `config/watchlist.conf` matchers as BLE,
so a device flagged on Friday is marked `*` when it reappears on Saturday.

**Foxhunt.** `foxhunt-rssi.sh` gains a Wi-Fi mode: track one or more MACs
(resolved from a fingerprint the same way BLE does it) by median RSSI from
the monitor-mode interface, channel pinned rather than hopped once the
target's channel is known. A deauth attacker transmits continuously, which
is the easy foxhunt; a probe-only client is intermittent and the tool says
so.

**Logging parity.** `wifi-obs/1` already carries the envelope. Add the
fingerprint fields, and let the collector's identity store merge a BLE
identity and a Wi-Fi identity when a name or a serial ties them, keyed
explicitly and never guessed.

Needs: the hardware checklist done first (monitor mode on the MT7921, the
tshark field representations confirmed), then a real ambient baseline for
the new fingerprint fields.

## Track 2: LoRa and Meshtastic

The AIO v2 carries a LoRa radio, and Meshtastic is both the mesh people
bring to conferences and the next place spam goes. Owned nodes (T-Deck,
T-Echo, SenseCAP, RAK tags) are the reference senders and the candidate
sensor nodes.

What is detectable passively from a LoRa receiver on the mesh's channel:

| Pattern | Keys on | Honest limit |
|---|---|---|
| Channel flood / text spam | packets per second per node id and per channel, message repetition, hop-limit abuse | a busy legitimate mesh at an event is dense; baseline first, exactly as for BLE |
| Node-id spoofing and impersonation | one node id from two RSSI/SNR/frequency-error signatures at once, or a known node's id with a different hardware model or public key | key-based identity is strong only where the mesh uses it; otherwise tier `session` |
| Position spoofing | a node's reported position moving faster than possible, or disagreeing with the RSSI seen at fixed sensors | RSSI-to-distance on LoRa is as coarse as on BLE |
| Telemetry and admin abuse | admin messages, remote-config attempts, channel-key probing from unknown nodes | payloads are encrypted on private channels; only the public/default channel is readable, and that is stated in every record |
| LoRaWAN join floods | join-request rate per DevEUI/AppEUI on the gateway's channels | needs the gateway's channel plan; a track for sites that run one |
| Jamming | noise-floor rise and packet-error rate across the band, from the SDR rather than the LoRa modem | energy detection says "something", not "who" |

Records: `lora-obs/1` with the shared envelope plus node id, hardware
model, channel, spreading factor, SNR, frequency error and hop count. The
identity key is the node's public key when present, else its id at tier
`session`. Foxhunting a LoRa transmitter works the way it does for BLE and
better: LoRa carries SNR and frequency error, which separate two senders
sharing an id.

Sensor nodes: a Meshtastic device in a listen-only role is already a LoRa
sensor; the node contract gains a LoRa modality and the collector merges
it. Meshtastic's own MQTT uplink is the obvious transport to reuse, with
its packets translated into records rather than a new firmware.

Needs: the AIO's LoRa radio driven from Linux (the Hammunition `lora`
inventory records the boards and identifiers), an owned node as the known
sender, and a quiet baseline.

## Track 3: other radios

Each of these has a radio on the rig or on the bench, or a sibling
project that already does the work. The rule is to integrate, not
reimplement, wherever a maintained tool exists.

**802.15.4: Zigbee and Thread.** The nRF52840 and the CatSniffer V3 sniff
802.15.4 passively. Attacks worth detecting: beacon-request storms and
association floods (the Zigbee equivalent of a BLE lure flood), PAN-ID
conflicts injected to force network moves, and touchlink scans. Records
`zigbee-obs/1`; identity is the 64-bit extended address (`strong`) or the
short address (`session`).

**Sub-GHz ISM (315/433/868/915 MHz).** The AIO's SDR and `rtl_433` give a
passive view of key fobs, sensors and remotes. Detectable: replay and
rolling-code attacks show as identical or out-of-sequence codes from a
device that is not there; jammers show as a raised noise floor on a band
where devices stop decoding. Both keyed on `rtl_433`'s decoded records
plus an SDR noise-floor sample, integrated rather than reimplemented.

**Cellular.** IMSI-catcher detection is Rayhunter's job and Hammunition
already carries it. This project ingests Rayhunter's alerts as
`cell-alert/1` records so a cell-site simulator at an event lands in the
same timeline as the BLE and Wi-Fi floods, and nothing more.

**GNSS spoofing and jamming.** The AIO's GPS reports fix quality, satellite
count and carrier-to-noise per satellite. A sudden position jump with a
clean fix, every satellite at the same signal level, or a fix that
disagrees with the sensor's known fixed position, are spoofing signatures;
a lost fix with a raised L1 noise floor on the SDR is jamming. Records
`gnss-obs/1` from the sensor's own receiver. Passive by definition.

**RFID and NFC.** Proxmark3 territory, and mostly active: reading a tag
means transmitting a field. What is passive is sniffing a reader-to-tag
exchange in progress, which detects downgrade and relay attempts at a badge
reader. Narrow, and stated as such; it lands only if a venue asks.

**Spectrum watch.** The HackRF or the AIO's SDR as a wideband energy
monitor over 2.4 GHz and the ISM bands: a channel that goes to full
occupancy with no decodable frames is a jammer, and the only way to see
one. Records `spectrum-obs/1` (band, occupancy, noise floor per slice).
This is the sensor that catches the attack every protocol-level detector
above is blind to.

Each of these is a separate `*-obs/1` schema on the shared envelope, a
separate detector module, and a separate corpus under the same
precision/recall gate. None ships without a baseline.

## Track 4: enterprise defence and foxhunting

A conference runs the tool for a weekend; a security team runs it for
years. The difference is operations, not detection.

- **Fixed sensor fleet.** Sensors as a service: install on a Pi or an
  ESP32, register with the collector, heartbeat, position from config,
  over-the-air config for channels and profiles. Sensor health is an alert
  class of its own (a dead sensor is a finding).
- **Incident records.** The collector groups a run of related alerts
  (same family, overlapping sensors, continuous in time) into one
  `fleet-incident/1` with first seen, last seen, sensors, location track,
  the identities involved, and the evidence files. That is the unit a SOC
  ticket wraps, and the thing an analyst is paged for once, not every five
  seconds.
- **Evidence bundle.** One command produces the handoff for venue security
  or law enforcement: the btsnoop and pcapng, the observation and alert
  records for the window, the incident summary, and a hash manifest. What
  it contains is other people's device addresses, so the bundle is
  scoped to the incident window and the involved identities, not the day.
- **Foxhunt handoff.** The collector's estimate is the starting point; a
  handheld (the uConsole) takes over from there. The handoff is a target
  set (identity key, current addresses, last centroid, last seen) the
  foxhunt tool loads with one flag, and the handheld's own sightings feed
  back into the incident.
- **SIEM, dashboards, playbooks.** Wazuh decoders and rules and an
  OpenSearch/Grafana dashboard over `*-alert/1` and `fleet-incident/1`,
  exercised end to end and kept in the repository as tested examples.
  Playbooks written for the three things a team actually does: confirm
  it is real, find it, document it.
- **Access, retention, privacy.** Records contain personal data. The
  collector gets TLS, per-sensor credentials, a read-only role for
  dashboards, retention limits by record type (observations short, alerts
  and incidents long). The written data-handling note a venue can sign off
  on exists now: `docs/data-handling.md`. An enterprise offering that
  cannot answer "who can see this and for how long" is not one.
- **Packaging.** A `skid-finder-collector` unit (systemd service, config
  under `/etc`) beside the field tool, both carried by Hammunition, and
  an image for the ESP32 sensor.

## What is not on this list

- Any transmit, jam or deauth capability, for testing or otherwise. Test
  senders are your own devices in a contained space, as
  `docs/flipper-spam-capture.md` describes.
- Decrypting anyone's traffic. Private Meshtastic channels, WPA data
  frames and LoRaWAN payloads stay opaque; the metadata is the signal.
- Attribution to a person. The tool ends at "this device, this confidence,
  here, then". The rest is the venue's job, with the evidence bundle.
