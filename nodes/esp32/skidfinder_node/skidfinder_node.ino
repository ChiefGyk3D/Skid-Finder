// Skid Finder ESP32 sensor node — reference implementation.
//
// STATUS: alpha, written against the public NimBLE-Arduino and PubSubClient
// APIs and NOT yet compiled or run on hardware by this project. It exists so
// the node contract (docs/sensor-nodes.md) has a concrete starting point.
// Treat the first flash as a test of this file, not of your board.
//
// What it does: passive BLE scan (no transmit, no connect), one ble-obs/1
// JSON record per advertisement published to <prefix>/<sensor_id>/obs, a
// retained sensor-status/1 heartbeat on <prefix>/<sensor_id>/status, and a
// last-will that clears the heartbeat if the node drops off.
//
// What it does not do: run the detector. The collector judges a node from
// its raw observations, which is the whole point of emitting them.
//
// Libraries (Arduino Library Manager): NimBLE-Arduino (h2zero),
// PubSubClient (Nick O'Leary). Board: any ESP32 with Wi-Fi; an Ethernet
// board (Olimex ESP32-POE) swaps WiFi.h for ETH.h and is otherwise the same.
//
// Identity tiers: the node marks public and random-static addresses the
// same way the Python side does (strong / session by address), and falls
// back to a content fingerprint the collector recomputes. It does not try
// to reproduce ble_identity.py's fingerprint hash; a rotating-address
// device from a node is tier "model" with identity_key "fp:node:<hash>",
// which the collector treats as model-tier and never places on a map.

#include <WiFi.h>
#include <PubSubClient.h>
#include <NimBLEDevice.h>
#include <time.h>

// ---- configure these -------------------------------------------------------
static const char* WIFI_SSID   = "your-management-ssid";
static const char* WIFI_PASS   = "your-wifi-password";
static const char* MQTT_HOST   = "192.0.2.10";     // the collector's broker
static const uint16_t MQTT_PORT = 1883;
static const char* MQTT_USER   = "";               // "" for none
static const char* MQTT_PASSWD = "";
static const char* PREFIX      = "skidfinder";
static const char* SENSOR_ID   = "esp32-01";
static const char* SENSOR_LAT  = "";               // decimal degrees, or "" when unknown
static const char* SENSOR_LON  = "";
static const uint32_t HEARTBEAT_MS = 30000;
// -----------------------------------------------------------------------------

WiFiClient net;
PubSubClient mqtt(net);
char topicObs[96];
char topicStatus[96];
uint32_t published = 0;
uint32_t lastBeat = 0;
uint32_t bootMs = 0;

static double nowEpoch() {
  struct timeval tv;
  gettimeofday(&tv, nullptr);
  return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static void jsonEscape(const std::string& in, char* out, size_t cap) {
  size_t o = 0;
  for (char c : in) {
    if (o + 6 >= cap) break;
    if (c == '"' || c == '\\') { out[o++] = '\\'; out[o++] = c; }
    else if ((unsigned char)c < 0x20) { o += snprintf(out + o, cap - o, "\\u%04x", c); }
    else out[o++] = c;
  }
  out[o] = 0;
}

static uint32_t fnv1a(const std::string& s) {
  uint32_t h = 2166136261u;
  for (unsigned char c : s) { h ^= c; h *= 16777619u; }
  return h;
}

class ScanCallbacks : public NimBLEScanCallbacks {
  void onResult(const NimBLEAdvertisedDevice* dev) override {
    if (!mqtt.connected()) return;

    // Address type. NimBLE reports the raw type: 0 public, 1 random. For
    // random, the top two bits of the first byte say static (11) vs
    // resolvable (01) vs non-resolvable (00).
    const NimBLEAddress addr = dev->getAddress();
    const uint8_t type = addr.getType();
    const uint8_t* raw = addr.getBase()->val;  // little-endian; val[5] is the MSB
    const char* addrType = (type == BLE_ADDR_PUBLIC) ? "public" : "random";
    const char* addrClass = "public";
    if (type != BLE_ADDR_PUBLIC) {
      const uint8_t top = raw[5] >> 6;
      addrClass = (top == 0x3) ? "static" : (top == 0x1) ? "resolvable" : "non-resolvable";
    }

    char name[64]; jsonEscape(dev->getName(), name, sizeof name);
    char addrStr[24]; snprintf(addrStr, sizeof addrStr, "%s", addr.toString().c_str());
    for (char* p = addrStr; *p; ++p) *p = toupper(*p);

    // Tier and identity key, matching ble_identity.py where the address
    // alone decides; content fingerprints are marked as node-computed.
    const char* tier;
    char key[80];
    if (type == BLE_ADDR_PUBLIC) { tier = "strong"; snprintf(key, sizeof key, "addr:%s", addrStr); }
    else if (raw[5] >> 6 == 0x3) { tier = "session"; snprintf(key, sizeof key, "addr:%s", addrStr); }
    else {
      tier = "model";
      std::string blob = dev->getName();
      if (dev->haveManufacturerData()) blob += "|m:" + dev->getManufacturerData().substr(0, 2);
      if (dev->haveServiceUUID()) blob += "|u:" + dev->getServiceUUID().toString();
      snprintf(key, sizeof key, "fp:node:%08x", fnv1a(blob));
    }
    for (char* p = key; *p; ++p) if (*p >= 'A' && *p <= 'Z') *p = *p - 'A' + 'a';

    // Company id from manufacturer data (little-endian first two bytes),
    // rendered as the hex the Python detector already matches on (0x004c
    // is Apple).
    char companies[32] = "";
    if (dev->haveManufacturerData() && dev->getManufacturerData().size() >= 2) {
      const std::string m = dev->getManufacturerData();
      snprintf(companies, sizeof companies, "\"0x%02x%02x\"", (uint8_t)m[1], (uint8_t)m[0]);
    }
    char uuids[48] = "";
    if (dev->haveServiceUUID()) {
      char u[40]; jsonEscape(dev->getServiceUUID().toString(), u, sizeof u);
      snprintf(uuids, sizeof uuids, "\"%s\"", u);
    }

    char payload[512];
    snprintf(payload, sizeof payload,
      "{\"schema\":\"ble-obs/1\",\"ts\":%.3f,\"ts_absolute\":true,\"sensor_id\":\"%s\","
      "\"lat\":%s,\"lon\":%s,\"modality\":\"ble\",\"address\":\"%s\",\"addr_type\":\"%s\","
      "\"addr_class\":\"%s\",\"tier\":\"%s\",\"identity_key\":\"%s\",\"rssi\":%d,"
      "\"tx_power\":%s,\"name\":\"%s\",\"companies\":[%s],\"service_uuids\":[%s],"
      "\"pdu\":\"\",\"flags\":\"\"}",
      nowEpoch(), SENSOR_ID,
      SENSOR_LAT[0] ? SENSOR_LAT : "null", SENSOR_LON[0] ? SENSOR_LON : "null",
      addrStr, addrType, addrClass, tier, key, dev->getRSSI(),
      "null", name, companies, uuids);
    if (mqtt.publish(topicObs, payload, false)) published++;
  }
};

static void heartbeat() {
  char payload[256];
  snprintf(payload, sizeof payload,
    "{\"schema\":\"sensor-status/1\",\"ts\":%.3f,\"sensor_id\":\"%s\",\"version\":\"esp32-node-alpha\","
    "\"uptime_sec\":%.1f,\"published\":%lu,\"rssi_wifi\":%d}",
    nowEpoch(), SENSOR_ID, (millis() - bootMs) / 1000.0, (unsigned long)published, WiFi.RSSI());
  mqtt.publish(topicStatus, payload, true);
}

static void connectMqtt() {
  while (!mqtt.connected()) {
    char clientId[64]; snprintf(clientId, sizeof clientId, "skidfinder-%s", SENSOR_ID);
    // Last will clears the retained heartbeat so the collector sees a dead node as dead.
    if (mqtt.connect(clientId, MQTT_USER[0] ? MQTT_USER : nullptr, MQTT_PASSWD[0] ? MQTT_PASSWD : nullptr,
                     topicStatus, 1, true, "")) {
      heartbeat();
    } else {
      delay(2000);
    }
  }
}

void setup() {
  Serial.begin(115200);
  bootMs = millis();
  snprintf(topicObs, sizeof topicObs, "%s/%s/obs", PREFIX, SENSOR_ID);
  snprintf(topicStatus, sizeof topicStatus, "%s/%s/status", PREFIX, SENSOR_ID);

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  while (WiFi.status() != WL_CONNECTED) delay(250);

  // Absolute time is what lets the collector line this node up with others.
  configTime(0, 0, "pool.ntp.org", "time.nist.gov");
  time_t t = 0;
  while (t < 1700000000) { delay(250); time(&t); }

  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setBufferSize(1024);
  connectMqtt();

  NimBLEDevice::init("");
  NimBLEScan* scan = NimBLEDevice::getScan();
  scan->setScanCallbacks(new ScanCallbacks(), false);
  scan->setActiveScan(false);       // passive: never send scan requests
  scan->setDuplicateFilter(false);  // every advert is an observation
  scan->setInterval(100);
  scan->setWindow(99);
  scan->start(0, false, true);      // forever, no duplicate filtering, restart on stop
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) { WiFi.reconnect(); delay(1000); return; }
  if (!mqtt.connected()) connectMqtt();
  mqtt.loop();
  if (millis() - lastBeat >= HEARTBEAT_MS) { heartbeat(); lastBeat = millis(); }
  delay(10);
}
