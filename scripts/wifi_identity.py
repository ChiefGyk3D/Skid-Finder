"""Per-frame identity for Wi-Fi, shared by the observer, the fingerprint tool
and the collector.

Modern clients randomise their MAC, often per probe burst, so for a probe
request the address is worth nothing as an identity. What persists is the
frame's content: the order of its tagged parameters, its supported rates,
its HT capability word and the vendor OUIs it names. Those come from the
driver and firmware, not from the user, so they identify a product and a
configuration: the same honesty as the BLE fingerprint. Two people with the
same phone model collapse together, and the tier says so.

An access point's BSSID is a real, stable identity (tier strong). A beacon
from a random BSSID is a beacon spammer inventing addresses; its content
fingerprint is what says "the same tool, again" across an event.

Tiers:
  strong    globally administered MAC: an access point, an older client
  session   locally administered MAC on a frame that is not a probe or a
            beacon: a randomised client address that holds for one session
  model     probe request or beacon from a randomised address: the content
            fingerprint identifies a product or a tool, not a unit
"""

import hashlib

FINGERPRINT_VERSION = 1

# Frames whose sender content is the identity when the address is random.
CONTENT_SUBTYPES = {4, 8, 5}   # probe request, beacon, probe response


def fingerprint(frame) -> str:
    parts = [
        "t=" + ",".join(str(t) for t in frame.tags),
        "r=" + ",".join(frame.rates),
        "h=" + (frame.ht_caps or ""),
        "o=" + ",".join(sorted(set(frame.vendor_ouis))),
        "k=" + str(frame.subtype),
    ]
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()[:12]


def has_content(frame) -> bool:
    return bool(frame.tags or frame.rates or frame.ht_caps or frame.vendor_ouis)


def identity_tier(frame) -> str:
    if not frame.sa:
        return "strong"          # a frame keyed by its BSSID alone
    if not frame.sa_random:
        return "strong"
    if frame.subtype in CONTENT_SUBTYPES and has_content(frame):
        return "model"
    return "session"


def identity_key(frame):
    """Return (key, tier) for one frame."""
    tier = identity_tier(frame)
    if tier == "model":
        return "fp:wifi:" + fingerprint(frame), tier
    addr = frame.sa or frame.bssid
    return "addr:" + addr.lower(), tier
