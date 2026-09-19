# Data handling

Skid Finder records other people's radio metadata. This page says what is
kept, for how long it should be kept, who should see it, and what a venue
or an employer can be told before a sensor is switched on. It is written
so a venue can sign off on it; if your venue needs something it does not
say, that is a gap to report.

## What is collected

Everything is passive. Nothing is transmitted, joined, decrypted or
replayed. What a sensor hears is what any phone in the room hears when it
looks for a headset or a network.

| Record | Contains | Personal? |
|---|---|---|
| Capture (`.btsnoop`, `.pcapng`) | every advertisement or management frame heard, raw | yes: device addresses, advertised names, SSIDs devices probe for |
| `ble-obs/1`, `wifi-obs/1` | one line per advertisement/frame: address, class, name, vendor, signal, sensor, time | yes, the same fields, structured |
| `ble-alert/1`, `wifi-alert/1`, `fleet-alert/1` | window statistics and which signature families matched; no addresses | no |
| `fleet-state/1` | per identity: tier, addresses seen (capped), per-sensor signal, an estimated location for `strong`/`session` identities | yes |
| `logs/sightings.json` | fingerprints and addresses seen across captures, for the watchlist | yes |
| `config/watchlist.conf` | addresses and names you chose to watch | yes, by definition |

Names are what a device advertises about itself (`Galaxy Buds`,
`WHOOP 5AM…`, a laptop's hostname). Some people name devices after
themselves. A serial number in a name is what promotes an identity to tier
`strong`. None of this is content: no message bodies, no data frames, no
Wi-Fi payloads.

## What it is for, and not for

For: telling a venue that a spam tool is running and roughly where, giving
a security team a timeline, and handing evidence to whoever is responsible
for the space. The tool ends at "this device, this confidence, here, then".

Not for: tracking a named person, building attendance lists, or watching a
device that is not attacking anything. The watchlist exists to re-find a
known attacker's hardware; putting a colleague's earbuds on it is misuse
the tool cannot prevent and the policy must.

## Retention

Keep the minimum that answers the question.

| Data | Suggested retention | Why |
|---|---|---|
| Observations and captures | hours to days; the event, plus enough to write up an incident | the bulk of the personal data, and only useful near the time |
| Alerts | months | no addresses; this is the record that something happened |
| Sightings and watchlist | the engagement | the watchlist is a decision, review it at the end |
| Corpus samples (`tests/corpus/real/`) | as long as they measure the detector; git-ignored, never published | a baseline is a measurement, not a log |

`logs/` is a flat directory; a nightly `find logs -name 'obs-*' -mtime +3
-delete` on a fixed sensor is the whole retention mechanism today. The
collector package planned after 1.0 carries retention by record type.

## Access

- A sensor's `logs/` is readable by whoever runs it. Root runs leave
  root-owned files; the doctor check flags them.
- The broker is on a management network, with TLS and per-sensor
  credentials from the environment, never from a file in this repository.
- The collector's `fleet-state.json` is the most personal artifact: it
  joins identities across sensors and places some of them. Treat it like a
  badge log. A read-only role for dashboards is planned; until then, the
  file's permissions are the control.

## Telling people

Before a sensor runs at a venue: who is running it, what it listens to
(Bluetooth advertisements and Wi-Fi management frames), that nothing is
transmitted or decrypted, what is kept and for how long, and who to ask.
The README's legal section is the template; a one-paragraph notice at the
registration desk is enough for most events, and some venues will want it
in the attendee terms.

Before a sensor runs in an enterprise: the same, in writing, with the
retention numbers filled in and a named owner. Works councils and privacy
officers will ask for the record table above; give them this page.

## Evidence handoff

When something is handed to venue security or law enforcement, hand over
the incident window and the involved identities, not the day. The
evidence-bundle command planned after 1.0 scopes that automatically; today
it is a manual copy of the capture and the observation file for the
window, with a note of what was seen and when.
