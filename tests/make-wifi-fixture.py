#!/usr/bin/env python3
"""Generate synthetic tshark field output for Wi-Fi detector testing.

Lines are in the exact shape scripts/wifi-capture.sh produces: the fields in
wifi_parse.FIELDS, tab separated. Timestamps are absolute epoch seconds
because tshark's frame.time_epoch is.

Modes:
  ambient     a handful of real access points beaconing steadily, clients
              probing, an occasional legitimate deauth. Must not match.
  deauth      an ambient floor plus a deauth flood to broadcast and to
              clients from one source.
  beacon      an ambient floor plus a beacon spammer inventing a BSSID and
              SSID per frame.
  evil_twin   an ambient floor plus one venue SSID copied by several BSSIDs
              from unrelated vendor prefixes.
  karma       an ambient floor plus one BSSID answering probe requests for
              every SSID any client asks for.
"""

import argparse
import random
import sys

BASE = 1758300000.0
OUIS = ["F0:9F:C2", "B8:27:EB", "3C:37:86", "00:1A:1E", "F4:F2:6D", "24:A4:3C", "8C:85:90"]
SSIDS_VENUE = ["Venue-Guest", "Venue-Staff", "xfinitywifi", "Tuscany_Free", "attwifi"]
SSIDS_PROBED = ["HomeNet", "CoffeeShop", "Starbucks", "MyPhone", "linksys", "NETGEAR42",
                "xfinitywifi", "Hilton Honors", "Airport_Free", "office-wlan", "ISP-Guest", "TP-LINK_1F"]


def mac(rng, oui=None):
    prefix = oui or rng.choice(OUIS)
    return prefix + ":" + ":".join(f"{rng.randint(0, 255):02X}" for _ in range(3))


def rand_mac(rng, local=True):
    first = rng.randint(0, 255)
    first = (first | 0x02) & ~0x01 if local else (first & ~0x03)
    return f"{first:02X}:" + ":".join(f"{rng.randint(0, 255):02X}" for _ in range(5))


# What a sender reveals about its hardware regardless of its MAC. Each
# "model" has a fixed tag order, rate set, HT word and vendor OUIs; a real
# capture shows the same. Clients rotate their MAC per probe burst, so only
# these columns tie a burst to a product.
MODELS = {
    "phone-a": ("0,1,3,50,45,127,221,221", "0x82,0x84,0x8b,0x96,0x0c,0x12,0x18,0x24", "0x19ef", "0050f2,001018"),
    "phone-b": ("0,1,45,50,127,221", "0x02,0x04,0x0b,0x16,0x0c,0x12,0x18,0x24", "0x01ef", "0050f2"),
    "laptop":  ("0,1,3,45,127,191,221", "0x82,0x84,0x8b,0x96,0x24,0x30,0x48,0x6c", "0x1ffe", "0050f2,506f9a"),
    "ap":      ("0,1,3,5,42,48,45,61,127,221", "0x82,0x84,0x8b,0x96,0x0c,0x12,0x18,0x24", "0x0dbf", "0050f2"),
    "spammer": ("0,1,3,221", "0x82,0x84,0x8b,0x96", "", "00037f"),
}


def line(ts, subtype, sa, da, bssid, ssid, rssi, channel, reason="", model=""):
    tags, rates, ht, ouis = MODELS.get(model, ("", "", "", ""))
    return "\t".join([f"{ts:.6f}", f"0x{subtype:04x}", sa, da, bssid, ssid, str(rssi), str(channel), str(reason),
                       tags, rates, ht, ouis])


def ambient(rng, duration, out):
    aps = []
    for i in range(6):
        oui = OUIS[i % 3]  # the venue runs one vendor
        aps.append({"bssid": mac(rng, oui), "ssid": SSIDS_VENUE[i % len(SSIDS_VENUE)],
                    "ch": rng.choice([1, 6, 11, 36, 44]), "rssi": rng.randint(-75, -40)})
    # Twenty clients of three models; each rotates its probe MAC every burst.
    clients = [{"model": ["phone-a", "phone-b", "laptop"][i % 3], "mac": rand_mac(rng), "left": 0}
               for i in range(20)]
    t = 0.0
    while t < duration:
        for ap in aps:
            out.append(line(BASE + t + rng.random() * 0.05, 8, ap["bssid"], "FF:FF:FF:FF:FF:FF",
                            ap["bssid"], ap["ssid"], ap["rssi"] + rng.randint(-4, 4), ap["ch"], model="ap"))
        if rng.random() < 0.6:
            c = rng.choice(clients)
            if c["left"] <= 0:
                c["mac"] = rand_mac(rng)
                c["left"] = rng.randint(2, 6)
            c["left"] -= 1
            ssid = rng.choice(SSIDS_PROBED)
            out.append(line(BASE + t + 0.02, 4, c["mac"], "FF:FF:FF:FF:FF:FF", "FF:FF:FF:FF:FF:FF", ssid,
                            rng.randint(-80, -50), 6, model=c["model"]))
            if ssid in SSIDS_VENUE:
                ap = next(a for a in aps if a["ssid"] == ssid)
                out.append(line(BASE + t + 0.03, 5, ap["bssid"], c["mac"], ap["bssid"], ssid, ap["rssi"], ap["ch"],
                                model="ap"))
        if rng.random() < 0.01:
            ap = rng.choice(aps)
            out.append(line(BASE + t + 0.04, 12, ap["bssid"], rng.choice(clients)["mac"], ap["bssid"], "",
                            ap["rssi"], ap["ch"], 4))
        t += 0.1
    return aps, [c["mac"] for c in clients]


def deauth(rng, duration, out, aps, clients, rate=25.0):
    attacker = rand_mac(rng)
    ap = rng.choice(aps)
    n = int(duration * rate)
    for i in range(n):
        target = "FF:FF:FF:FF:FF:FF" if i % 3 else rng.choice(clients)
        sub = 12 if i % 5 else 10
        out.append(line(BASE + 5 + i * ((duration - 10) / n), sub, ap["bssid"], target, ap["bssid"], "",
                        rng.randint(-60, -45), ap["ch"], 7))
    return attacker


def beacon(rng, duration, out, rate=30.0):
    n = int(duration * rate)
    for i in range(n):
        b = rand_mac(rng, local=False)
        out.append(line(BASE + 5 + i * ((duration - 10) / n), 8, b, "FF:FF:FF:FF:FF:FF", b,
                        f"FreeWiFi-{rng.randint(1000, 9999)}", rng.randint(-70, -40), rng.choice([1, 6, 11]),
                        model="spammer"))


def evil_twin(rng, duration, out, aps):
    victim = aps[0]["ssid"]
    twins = [mac(rng, o) for o in OUIS[3:7]]
    t = 0.0
    while t < duration:
        for i, b in enumerate(twins):
            out.append(line(BASE + t + 0.01 * i, 8, b, "FF:FF:FF:FF:FF:FF", b, victim,
                            rng.randint(-55, -35), rng.choice([1, 6, 11])))
        t += 0.1


def karma(rng, duration, out, clients):
    rogue = mac(rng, OUIS[6])
    t = 0.0
    while t < duration:
        c = rng.choice(clients)
        ssid = rng.choice(SSIDS_PROBED)
        out.append(line(BASE + t, 4, c, "FF:FF:FF:FF:FF:FF", "FF:FF:FF:FF:FF:FF", ssid, rng.randint(-80, -50), 6))
        out.append(line(BASE + t + 0.005, 5, rogue, c, rogue, ssid, rng.randint(-50, -35), 6))
        t += 0.25


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", required=True, choices=["ambient", "deauth", "beacon", "evil_twin", "karma"])
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--rate", type=float, default=None)
    parser.add_argument("--seed", type=int, default=4242)
    parser.add_argument("--output", default="-")
    args = parser.parse_args()
    rng = random.Random(args.seed)
    out = []
    aps, clients = ambient(rng, args.duration, out)
    if args.mode == "deauth":
        deauth(rng, args.duration, out, aps, clients, **({} if args.rate is None else {"rate": args.rate}))
    elif args.mode == "beacon":
        beacon(rng, args.duration, out, **({} if args.rate is None else {"rate": args.rate}))
    elif args.mode == "evil_twin":
        evil_twin(rng, args.duration, out, aps)
    elif args.mode == "karma":
        karma(rng, args.duration, out, clients)
    out.sort(key=lambda row: float(row.split("\t", 1)[0]))
    text = "\n".join(out) + "\n"
    if args.output == "-":
        sys.stdout.write(text)
    else:
        with open(args.output, "w", encoding="utf-8") as handle:
            handle.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
