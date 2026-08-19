"""Per-advertisement identity primitives, shared across the toolkit.

The fingerprint tool, the normalized-event emitter and the live alerter all
need the same answer to one question: given a single advertising record, what
is its identity key and how much can that key be trusted? Keeping that logic
here means the batch fingerprinter and the streaming tools cannot drift into
disagreeing about what counts as the same device.

The reasoning behind the tiers lives in ble-fingerprint.py; in short, most
modern devices rotate their address every few minutes, so the address is a
real identity only when it is public or random static. Everything else falls
back to a content fingerprint that identifies a product, not a unit.
"""

import hashlib
import re

# A token that is long and mixes letters with digits is usually a serial
# number or unit ID rather than a model name. Stripping it yields a key that
# groups units of the same product; keeping it identifies the individual.
SERIAL_TOKEN_RE = re.compile(r"^(?=.*\d)[A-Za-z0-9_-]{6,}$")


def split_name(name: str):
    """Return (model_key, serial) for an advertised name."""
    if not name:
        return "", ""
    tokens = name.split()
    if len(tokens) < 2:
        # A single token cannot be split without guessing which half is which.
        return name.strip().lower(), ""
    model = [t for t in tokens if not SERIAL_TOKEN_RE.match(t)]
    serial = [t for t in tokens if SERIAL_TOKEN_RE.match(t)]
    if not model:
        return name.strip().lower(), ""
    return " ".join(model).strip().lower(), " ".join(serial)


def identity_tier(record, serial: str) -> str:
    # A serial in the advertised name survives address rotation, so it is the
    # strongest signal available and is checked first.
    if serial:
        return "strong"
    if record.is_public:
        return "strong"
    # Only 'Static' random addresses persist. Resolvable and non-resolvable
    # private addresses both rotate, so neither can anchor an identity.
    if record.addr_class == "static":
        return "session"
    return "model"


def fingerprint(record) -> str:
    model, _ = split_name(record.name)
    parts = [
        "c=" + ",".join(sorted(set(record.companies))),
        "u=" + ",".join(sorted(set(record.service_uuids))),
        "n=" + model,
        "t=" + ("" if record.tx_power is None else str(record.tx_power)),
        "l=" + ("" if record.data_length is None else str(record.data_length)),
        "f=" + record.flags,
        "p=" + record.pdu_type,
    ]
    blob = "|".join(parts)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:12]


def identity_key(record) -> tuple:
    """Return (key, tier) for a sighting.

    The key decides what gets merged into one tracked device, so it must not
    merge things that are merely similar. A stable address is its own identity.
    Only rotating addresses fall back to the content fingerprint, and that
    fallback is explicitly model-level.
    """
    _, serial = split_name(record.name)
    tier = identity_tier(record, serial)
    if serial:
        return ("serial:" + serial.lower(), tier)
    if tier in ("strong", "session"):
        return ("addr:" + record.address.lower(), tier)
    return ("fp:" + fingerprint(record), tier)
