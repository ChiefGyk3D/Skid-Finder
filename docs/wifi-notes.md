# Wi-Fi detection

The Wi-Fi frontend mirrors the BLE one: a passive capture emits one
normalized record per management frame (`wifi-obs/1`), a detector judges a
window of them, and the same collector, publisher and SIEM path carry the
result. Everything is receive-only. A monitor-mode interface listens; this
toolkit never injects, associates, deauthenticates or transmits.

**Stage: alpha.** The detector is measured against synthetic traffic only.
No threshold has been baselined on a real venue and the capture path has not
been run on the AC1200 from this project. Treat every match as a lead.

## What it detects

| Family | Keys on | What ordinary infrastructure does instead |
|---|---|---|
| Deauthentication/disassociation flood | deauth + disassoc frames per second, distinct targets, broadcast target, repeated reason code | a real AP deauths one client now and then; tens per second is a tool |
| Beacon flood (fake access points) | distinct BSSIDs per second and the share seen once | real APs beacon ten times a second from one BSSID for hours |
| Evil twin | one SSID from several BSSIDs whose vendor prefixes differ | enterprise Wi-Fi advertises one SSID from many APs that share a vendor OUI |
| KARMA-style responder | one BSSID answering probe requests for many different SSIDs | an honest AP answers only for the networks it serves |

Coverage is deliberately the common scripted attacks. Not covered yet: WPA
handshake capture attempts (passive and indistinguishable from a client
joining), PMKID probing, rogue DHCP/DNS on the wire, and probe-request
fingerprinting of randomised clients.

## Capture

```bash
sudo ./scripts/wifi-capture.sh wlan1 60          # 60 s to logs/wifi-<iface>-<stamp>.{pcapng,tsv}
python3 scripts/wifi-signature-scan.py --input logs/wifi-wlan1-<stamp>.tsv
sudo ./scripts/wifi-live-watch.sh wlan1          # live alerts until Ctrl+C
```

The wrappers put the interface into monitor mode, take it away from
NetworkManager for the run, hop across `WIFI_CHANNELS` dwelling
`WIFI_DWELL_MS` on each, and on exit return it to managed mode and hand it
back. Channel hopping trades per-channel completeness for coverage, which is
the right trade for detection; a deauth flood on channel 6 is still tens of
frames in a 250 ms dwell.

tshark is asked for management frames only (`wlan.fc.type == 0`). Data
frames carry other people's traffic and the detector does not need them; the
`.pcapng` therefore holds nothing anyone typed.

On the uConsole + AC1200 the MT7921 is the monitor-capable radio and usually
enumerates as `wlan1`, with the CM4's own radio on `wlan0`. Set `WIFI_IFACE`
in `config/interfaces.conf`.

## Records

`wifi-obs/1` shares the envelope of `ble-obs/1` (`schema`, `ts`,
`ts_absolute`, `sensor_id`, `lat`, `lon`, `modality`, `address`, `tier`,
`identity_key`, `rssi`, `name`) and adds `frame` (beacon, probe_req,
probe_resp, deauth, disassoc, ...), `subtype`, `bssid`, `da`, `channel` and
`reason`. `name` carries the SSID. `ts` is absolute because tshark's
`frame.time_epoch` is.

Identity is stated plainly: a globally administered MAC is tier `strong`
and keyed `addr:<mac>`; a locally administered one is a randomised client
address, tier `session`, stable for one session with one network and
rotated afterwards. Nothing links a randomised address across rotations.

`wifi-alert/1` mirrors `ble-alert/1`. The collector keeps a separate Wi-Fi
window per sensor and judges it with the Wi-Fi detector; a flood seen by
several positioned sensors is placed the same way a BLE flood is.

## Things to verify on hardware

- `wlan.ssid` has changed representation across Wireshark releases. The
  parser accepts both text and hex-encoded values; an SSID that is itself a
  hex-looking string is the ambiguity that leaves. Confirm on the tshark
  version the uConsole ships.
- `wlan.fc.type_subtype` prints as hex in some versions and decimal in
  others; both are handled.
- Monitor mode on the MT7921 under the AIO v2 kernel, and whether
  NetworkManager or `wpa_supplicant` fights the interface. The wrapper
  handles NetworkManager; anything else is a troubleshooting entry to write.
- The first real ambient capture goes into `tests/corpus/real/` via the
  Wi-Fi manifest and is the baseline every threshold is waiting for.

## Legal

Listening to 802.11 management frames is the same act every Wi-Fi client
performs to find a network. Nothing here decrypts, joins or interferes. The
venue-authorisation and passive-only rules in the README apply unchanged,
and the `.pcapng` files contain other people's MAC addresses and the SSIDs
their devices ask for: keep them as you would any log with personal data.
