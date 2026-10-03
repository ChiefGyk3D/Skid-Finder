#!/usr/bin/env bash
set -euo pipefail

# Sensor-net regression test: the collector merges records from several
# sensors, estimates location honestly, judges each sensor with the shared
# detector, and moves records over MQTT through the publisher.
#
# No broker is needed. A stand-in 'paho' package on PYTHONPATH records what
# the publisher sends and replays an inbox to the collector, so the topic
# scheme, the retained heartbeat and the subscribe pattern are all checked
# without network access.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 "${ROOT_DIR}/tests/make-fleet-fixture.py" --outdir "${TMP}/fx" > /dev/null

# --- Offline merge ------------------------------------------------------------
python3 "${ROOT_DIR}/scripts/ble-collector.py" \
  --input "${TMP}"/fx/obs-*.jsonl "${TMP}/fx/alerts-A.jsonl" \
  --window 30 --interval 5 --profile balanced --config /dev/null \
  --state "${TMP}/state.json" --alerts-out "${TMP}/fleet-alerts.jsonl" \
  --incidents-out "${TMP}/incidents.jsonl" --incident-quiet 10 \
  > "${TMP}/collector.out" 2> "${TMP}/collector.err"

python3 - "${TMP}" "${ROOT_DIR}" <<'PY'
import json, math, os, sys
tmp, root = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "scripts"))
from importlib import import_module
collector = import_module("ble-collector") if False else None  # scripts are hyphenated; use haversine inline

def hav(lat1, lon1, lat2, lon2):
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2-p1)/2)**2 + math.cos(p1)*math.cos(p2)*math.sin(math.radians(lon2-lon1)/2)**2
    return 2*6371000*math.asin(math.sqrt(a))

state = json.load(open(os.path.join(tmp, "state.json")))
assert state["schema"] == "fleet-state/1"
S = state["sensors"]
assert set(S) == {"A", "B", "C"}, set(S)
for sid in S:
    assert S[sid]["lat"] is not None and S[sid]["lon"] is not None, f"sensor {sid} has no position"
    assert S[sid]["status"] and S[sid]["status"]["schema"] == "sensor-status/1", f"{sid} heartbeat not recorded"
assert S["A"]["alerts_total"] == 1 and S["A"]["node_alert"]["matches"], "node-reported alert not kept"

pos = {"A": (36.1000, -115.2000), "B": (36.1003, -115.2000), "C": (36.1000, -115.1996)}
I = state["identities"]
key = "addr:40:ed:98:18:de:ab"
assert key in I, "public device was not merged under its address key: %r" % sorted(I)[:5]
dev = I[key]
assert dev["tier"] == "strong" and dev["name"] == "FIIO BTR11"
assert set(dev["sensors"]) == {"A", "B", "C"}, "device seen by three sensors is not one identity with three series"
loc = dev["location"]
assert loc is not None, "strong-tier device heard by three positioned sensors has no location estimate"
d = {sid: hav(loc["lat"], loc["lon"], *pos[sid]) for sid in pos}
assert d["B"] < d["A"] and d["B"] < d["C"], f"estimate should be nearest B (loudest): {d}"
assert 30 <= loc["spread_m"] <= 60, f"spread should be the sensor spacing, got {loc['spread_m']}"
assert loc["sensors"] == 3

# model-tier identities are never placed on a map
for k, ident in I.items():
    if ident["tier"] == "model":
        assert ident["location"] is None, f"model-tier identity {k} was given a location"

alerts = [json.loads(l) for l in open(os.path.join(tmp, "fleet-alerts.jsonl")) if l.strip()]
assert alerts, "the flood never produced a fleet alert"
BASE = 1758200000.0
first = min(a["ts"] for a in alerts)
assert first >= BASE + 15, f"alert before the flood started: {first - BASE:.1f}s"
assert first <= BASE + 35, f"alert too late after the flood started: {first - BASE:.1f}s"
hit = [a for a in alerts if "A" in a["sensors"]]
assert hit, "sensor A, the loudest, never matched"
fl = hit[0]["flood"]
assert fl["loudest"] == "A", fl
assert fl["location"], "flood seen by positioned sensors has no location"
d = {sid: hav(fl["location"]["lat"], fl["location"]["lon"], *pos[sid]) for sid in pos}
assert d["A"] < d["B"] and d["A"] < d["C"], f"flood estimate should be nearest A: {d}"
names = {m["name"] for a in alerts for ms in a["sensors"].values() for m in ms}
assert "Flipper-like Apple popup spam pattern" in names, names
print("offline merge ok: %d identities, %d fleet alerts, device placed %.0f m from B, flood %.0f m from A"
      % (len(I), len(alerts), hav(loc["lat"], loc["lon"], *pos["B"]), d["A"]))
PY

grep -q "ALERT A:" "${TMP}/collector.out" || fail "collector summary never printed an ALERT line for A"

# --- Incidents: one flood, one ticket ------------------------------------------
python3 - "${TMP}/incidents.jsonl" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assert rows, "no incident records were written"
assert all(r["schema"] == "fleet-incident/1" for r in rows)
opened = [r for r in rows if r["status"] == "open"]
closed = [r for r in rows if r["status"] == "closed"]
assert len(opened) == 1, f"one flood must open exactly one incident, got {len(opened)}"
assert len(closed) == 1, f"the incident must close exactly once, got {len(closed)}"
assert opened[0]["id"] == closed[0]["id"]
BASE = 1758200000.0
assert opened[0]["first_seen"] >= BASE + 15, "incident opened before the flood started"
inc = closed[0]
assert "A" in inc["sensors"] and inc["loudest"] == "A", inc["sensors"]
assert inc["duration_sec"] >= 25, f"a 30 s flood produced a {inc['duration_sec']} s incident"
assert inc["location"] and inc["location"]["track_points"] >= 3, "no location track"
assert inc["identities"] and all(i["tier"] in ("strong", "session", "model", "ambiguous") for i in inc["identities"])
assert "not attribution" in inc["note"]
t = inc["targets"]
assert t and all({"address", "identity_key", "tier"} <= set(x) for x in t), "incident carries no target set"
assert t[0]["tier"] == "strong" and t[0]["address"] == "40:ED:98:18:DE:AB", "reliable targets must lead the handoff: %r" % t[0]
assert len(t) <= 40
print("incidents ok: one open, one close, %d s, %d track points, %d targets" % (inc["duration_sec"], inc["location"]["track_points"], len(t)))
PY
grep -q "INCIDENT inc-" "${TMP}/collector.out" || fail "collector summary never printed the incident"

# --- Foxhunt handoff: the tracker loads the incident's target set ----------------
"${ROOT_DIR}/scripts/foxhunt-rssi.sh" --from-incident "${TMP}/incidents.jsonl" --list-targets \
  > "${TMP}/targets.txt" 2> "${TMP}/targets.err" || { cat "${TMP}/targets.err" >&2; fail "foxhunt could not load targets from the incident"; }
[[ "$(head -n 1 "${TMP}/targets.txt")" == "40:ED:98:18:DE:AB" ]] || fail "handoff did not lead with the strong-tier address: $(head -n1 "${TMP}/targets.txt")"
grep -q "tier=model" "${TMP}/targets.err" && grep -q "rotating" "${TMP}/targets.err" || fail "handoff did not warn about rotating addresses"
"${ROOT_DIR}/scripts/foxhunt-rssi.sh" --from-incident "${TMP}/incidents.jsonl" --id inc-nope --list-targets > /dev/null 2>&1 && fail "unknown incident id accepted"
echo "foxhunt handoff ok: $(wc -l < "${TMP}/targets.txt" | tr -d ' ') targets, strong first"

# --- Directory watch --------------------------------------------------------------
python3 "${ROOT_DIR}/scripts/ble-collector.py" --watch "${TMP}/fx" --interval 1 --max-evals 2 \
  --config /dev/null --state "${TMP}/watch-state.json" --quiet 2> /dev/null
python3 - "${TMP}/watch-state.json" "${TMP}/fx/obs-A.jsonl" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert set(s["sensors"]) == {"A", "B", "C"}, "watch mode did not pick up every sensor's file"
n_obs = sum(1 for l in open(sys.argv[2]) if '"ble-obs/1"' in l)
got = s["sensors"]["A"]["obs_total"]
assert got == n_obs, f"watch mode re-read the file: {got} observations counted, {n_obs} in the file"
print("directory watch ok: offsets advance between polls")
PY

# --- MQTT through a stand-in paho -----------------------------------------------------
mkdir -p "${TMP}/fake/paho/mqtt"
: > "${TMP}/fake/paho/__init__.py"
: > "${TMP}/fake/paho/mqtt/__init__.py"
cat > "${TMP}/fake/paho/mqtt/client.py" <<'PY'
"""Stand-in for paho.mqtt.client: records publishes, replays an inbox."""
import json, os, enum

class CallbackAPIVersion(enum.Enum):
    VERSION1 = 1
    VERSION2 = 2

class _Info:
    def wait_for_publish(self, timeout=None):
        return True

class _Msg:
    def __init__(self, topic, payload):
        self.topic = topic
        self.payload = payload.encode("utf-8")

class Client:
    def __init__(self, api=None, client_id="", **kw):
        self.api = api
        self.client_id = client_id
        self.on_message = None
        self.on_connect = None
        self.subscriptions = []
        self.will = None
        self.tls = False
        self.auth = None

    def username_pw_set(self, u, p=None): self.auth = (u, p)
    def tls_set(self, *a, **k): self.tls = True
    def will_set(self, topic, payload=None, qos=0, retain=False): self.will = (topic, payload, retain)
    def connect(self, host, port=1883, keepalive=60):
        with open(os.environ["FAKE_MQTT_LOG"], "a") as h:
            h.write(json.dumps({"connect": [host, port], "tls": self.tls, "auth": self.auth,
                                "will": self.will, "client_id": self.client_id}) + "\n")
    def loop_start(self):
        if self.on_connect:
            self.on_connect(self, None, None, 0, None)
        inbox = os.environ.get("FAKE_MQTT_INBOX")
        if inbox and self.on_message and os.path.exists(inbox):
            for line in open(inbox):
                if line.strip():
                    m = json.loads(line)
                    self.on_message(self, None, _Msg(m["topic"], m["payload"]))
    def loop_stop(self): pass
    def disconnect(self): pass
    def subscribe(self, topic, qos=0):
        self.subscriptions.append(topic)
        with open(os.environ["FAKE_MQTT_LOG"], "a") as h:
            h.write(json.dumps({"subscribe": topic, "qos": qos}) + "\n")
    def publish(self, topic, payload=None, qos=0, retain=False):
        with open(os.environ["FAKE_MQTT_LOG"], "a") as h:
            h.write(json.dumps({"topic": topic, "payload": payload, "qos": qos, "retain": retain}) + "\n")
        return _Info()
PY

export FAKE_MQTT_LOG="${TMP}/mqtt.log"
: > "${FAKE_MQTT_LOG}"

# Publisher: one-shot file, then a follow pass with a heartbeat.
PYTHONPATH="${TMP}/fake" MQTT_USERNAME=node MQTT_PASSWORD=secret \
  python3 "${ROOT_DIR}/scripts/ble-publish.py" --input "${TMP}/fx/obs-A.jsonl" "${TMP}/fx/alerts-A.jsonl" \
  --host broker.test --port 8883 --tls --prefix sf --sensor-id A 2> /dev/null
PYTHONPATH="${TMP}/fake" \
  python3 "${ROOT_DIR}/scripts/ble-publish.py" --follow "${TMP}/fx/obs-B.jsonl" --once --heartbeat 1 \
  --host broker.test --prefix sf --sensor-id B 2> /dev/null

python3 - "${FAKE_MQTT_LOG}" "${TMP}/fx" <<'PY'
import json, sys, os
log = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
conn = [e for e in log if "connect" in e]
assert conn and conn[0]["connect"] == ["broker.test", 8883] and conn[0]["tls"] is True, conn[:1]
assert conn[0]["auth"] == ["node", "secret"], "credentials from the environment were not applied"
assert conn[0]["will"][0] == "sf/A/status" and conn[0]["will"][2] is True, "no retained last-will on the status topic"
pubs = [e for e in log if "topic" in e]
topics = {e["topic"] for e in pubs}
assert "sf/A/obs" in topics and "sf/A/alerts" in topics, topics
n_obs = sum(1 for l in open(os.path.join(sys.argv[2], "obs-A.jsonl")) if '"ble-obs/1"' in l)
assert sum(1 for e in pubs if e["topic"] == "sf/A/obs") == n_obs, "not every observation was published"
assert all(e["qos"] == 1 for e in pubs), "records must be published at QoS 1"
status = [e for e in pubs if e["topic"] == "sf/B/status"]
assert status and status[-1]["retain"] is True, "heartbeat was not published retained"
hb = json.loads(status[-1]["payload"])
assert hb["schema"] == "sensor-status/1" and hb["sensor_id"] == "B" and "version" in hb, hb
assert not any(e["retain"] for e in pubs if e["topic"].endswith("/obs")), "observations must not be retained"
print("publisher ok: %d publishes, heartbeat retained, will set" % len(pubs))
PY

# Collector over MQTT: replay every sensor's records as messages. A live
# collector prunes to its window against wall-clock time, so this fixture is
# generated on a timeline that ends about now.
python3 "${ROOT_DIR}/tests/make-fleet-fixture.py" --outdir "${TMP}/live" \
  --base "$(python3 -c 'import time; print(time.time() - 70)')" > /dev/null
python3 - "${TMP}/live" "${TMP}/inbox.jsonl" <<'PY'
import json, sys, glob, os
out = open(sys.argv[2], "w")
for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.jsonl"))):
    for line in open(path):
        if not line.strip():
            continue
        rec = json.loads(line)
        kind = {"ble-obs/1": "obs", "ble-alert/1": "alerts", "sensor-status/1": "status"}[rec["schema"]]
        out.write(json.dumps({"topic": f"sf/{rec['sensor_id']}/{kind}", "payload": line.strip()}) + "\n")
out.close()
PY
: > "${FAKE_MQTT_LOG}"
PYTHONPATH="${TMP}/fake" FAKE_MQTT_INBOX="${TMP}/inbox.jsonl" \
  python3 "${ROOT_DIR}/scripts/ble-collector.py" --mqtt --host broker.test --prefix sf \
  --interval 1 --max-evals 1 --window 120 --config /dev/null --state "${TMP}/mqtt-state.json" --quiet 2> /dev/null
python3 - "${TMP}/mqtt-state.json" "${FAKE_MQTT_LOG}" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
assert set(s["sensors"]) == {"A", "B", "C"}, "collector did not receive every sensor over MQTT"
assert s["sensors"]["A"]["alerts_total"] == 1
assert len(s["identities"]) > 0, "records arrived over MQTT but no identity survived the window"
assert "addr:40:ed:98:18:de:ab" in s["identities"], "the public device did not merge over MQTT"
assert s["identities"]["addr:40:ed:98:18:de:ab"]["location"], "no location from MQTT-delivered records"
log = [json.loads(l) for l in open(sys.argv[2]) if l.strip()]
subs = {e["subscribe"] for e in log if "subscribe" in e}
assert subs == {"sf/+/obs", "sf/+/alerts", "sf/+/status"}, subs
print("collector over mqtt ok: %d identities" % len(s["identities"]))
PY

# --- Missing client library must say what to install -----------------------------
# A 'paho' package that refuses to import stands in for an absent one.
mkdir -p "${TMP}/nopaho/paho"
echo 'raise ImportError("paho is not installed (test stand-in)")' > "${TMP}/nopaho/paho/__init__.py"
for tool in ble-publish.py ble-collector.py; do
  args=(--input /dev/null --host h)
  [[ "${tool}" == ble-collector.py ]] && args=(--mqtt --host h --max-evals 1)
  if PYTHONPATH="${TMP}/nopaho" python3 "${ROOT_DIR}/scripts/${tool}" "${args[@]}" > /dev/null 2> "${TMP}/nopaho.err"; then
    fail "${tool} ran without the MQTT client library instead of refusing"
  fi
  grep -q "python3-paho-mqtt" "${TMP}/nopaho.err" || fail "${tool} without paho did not name the package to install"
done

echo "Sensor net test passed."
