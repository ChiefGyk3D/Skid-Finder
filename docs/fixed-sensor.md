# Running as a fixed sensor or a collector

A hand-carried uConsole is one way to run Skid Finder. The other is a box
in a corner for a week: a Pi, a NUC, a laptop on a shelf, listening on its
own and shipping records to a collector. The `systemd/` directory carries
the units for that.

| Unit | Runs | As |
|---|---|---|
| `skid-finder-sensor@hciN.service` | `ble-live-watch.sh hciN 0 balanced`: live BLE alerting until stopped, publishing when `MQTT_HOST` is set | root, or a `wireshark`-group account (see below) |
| `skid-finder-collector.service` | `ble-collector.py --mqtt` with state, alerts and incidents under `logs/` | the account that owns the tree; needs no root |
| `skid-finder-retention.timer` | `retention-sweep.sh` nightly: observations, captures and traces older than 3 days go; alerts, incidents and state stay | the tree's owner |

All three assume the tree at `/usr/local/share/hammunition/skid-finder`,
which is where Hammunition installs it. A git checkout elsewhere works the
same; set `SKID_FINDER_HOME` in a drop-in.

## Install

```bash
sudo cp systemd/skid-finder-sensor@.service systemd/skid-finder-collector.service \
        systemd/skid-finder-retention.service systemd/skid-finder-retention.timer \
        /etc/systemd/system/
sudo systemctl daemon-reload
```

Then, per unit, a drop-in for what differs on this host:

```bash
sudo systemctl edit skid-finder-sensor@hci0
```

```ini
[Service]
Environment=SKID_FINDER_HOME=/home/sensor/Skid-Finder
# Optional: run without root. The account must be in the wireshark group
# and own the tree; the scripts take the unprivileged route on their own.
User=sensor
```

```bash
sudo systemctl enable --now skid-finder-sensor@hci0
sudo systemctl enable --now skid-finder-retention.timer
journalctl -u skid-finder-sensor@hci0 -f
```

The collector needs the broker settings from `config/interfaces.conf` and,
if the broker wants credentials, an environment file the unit reads and
nobody else can:

```bash
sudo install -m 600 /dev/null /etc/skid-finder/collector.env
sudo tee /etc/skid-finder/collector.env >/dev/null <<'ENV'
MQTT_USERNAME=collector
MQTT_PASSWORD=change-me
ENV
sudo systemctl edit skid-finder-collector
```

```ini
[Service]
User=sensor
EnvironmentFile=/etc/skid-finder/collector.env
```

```bash
sudo systemctl enable --now skid-finder-collector
```

Sensors that publish also want credentials; give the sensor unit the same
kind of `EnvironmentFile=` drop-in with that node's own account on the
broker.

## What to check after the first hour

- `journalctl -u skid-finder-sensor@hci0` shows `capturing` lines, no
  `warn: nothing captured`. If it does, the adapter is not scanning; run
  `./scripts/skid-finder.sh --doctor` as the service's user.
- `logs/alerts-hci0-*.jsonl` is growing by one line per evaluation. Quiet
  windows are written too; a file that stops growing is a dead sensor.
- On the collector, `logs/fleet-state.json` lists the sensor with a recent
  `age_sec`, and `logs/fleet-incidents.jsonl` is empty unless something
  happened.
- `sudo systemctl start skid-finder-retention.service` once by hand, with
  `--dry-run` added to the script in a drop-in if you want to see what it
  would remove first.

## What this is not yet

A packaged service with its own config under `/etc`, over-the-air config,
and a read-only role for dashboards are on the post-1.0 list
(`docs/post-1.0-direction.md`, track 4). These units are the minimum that
keeps a sensor running across reboots and keeps its data from
accumulating.
