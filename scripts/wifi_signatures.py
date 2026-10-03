"""Defensive Wi-Fi signature detection core.

Mirrors ble_signatures: thresholds per profile, statistics over a window of
frames, evaluation into matches. The batch scanner, the live alerter and the
collector all import this one module.

What the families key on, and why:

  deauth_flood   deauthentication/disassociation frames per second and the
                 number of distinct targets. A legitimate AP deauths one
                 client occasionally; a flood is tens per second, often to
                 the broadcast address or to many clients, usually with the
                 same reason code every time.
  beacon_flood   distinct BSSIDs per second and the share seen only once.
                 Real APs beacon ten times a second from one BSSID for
                 hours; a beacon spammer invents a new BSSID and SSID for
                 every frame, so the singleton ratio goes to 1.0.
  evil_twin      one SSID advertised by several BSSIDs whose vendor prefixes
                 differ. Enterprise Wi-Fi does advertise one SSID from many
                 APs, but those share a vendor OUI and a channel plan; a
                 rogue copies the name from different hardware.
  karma          one BSSID answering probe requests for many different
                 SSIDs. An honest AP responds only for the networks it
                 serves; a KARMA/MANA-style rogue answers everything.

None of these thresholds have been measured on a real venue yet. They were
set from the shape of the attacks and from what ordinary infrastructure is
known to do; the corpus harness keeps them honest against synthetic traffic,
and a real baseline is the first thing to record on hardware.
"""

import os
import sys
from dataclasses import dataclass
from typing import Dict, List, Set

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wifi_parse  # noqa: E402
from sig_config import (  # noqa: E402
    SignatureConfig,
    clamp_confidence,
    get_bool,
    get_float,
    get_int,
    load_rules,
)

ASSUMED_DURATION_SEC = 30.0
BROADCAST = "FF:FF:FF:FF:FF:FF"

DEFAULT_RULES = {
    "conservative": {
        "min_duration_sec": 10,
        "deauth_min_rate": 8.0,
        "deauth_min_frames": 60,
        "deauth_min_targets": 1,
        "beacon_min_bssid_rate": 4.0,
        "beacon_min_unique_bssids": 60,
        "beacon_min_singleton_ratio": 0.8,
        "evil_twin_min_bssids": 4,
        "evil_twin_min_ouis": 3,
        "karma_min_ssids": 12,
        "karma_min_responses": 30,
        "enable_deauth": True,
        "enable_beacon": True,
        "enable_evil_twin": True,
        "enable_karma": True,
    },
    "balanced": {
        "min_duration_sec": 5,
        "deauth_min_rate": 4.0,
        "deauth_min_frames": 30,
        "deauth_min_targets": 1,
        "beacon_min_bssid_rate": 2.0,
        "beacon_min_unique_bssids": 30,
        "beacon_min_singleton_ratio": 0.7,
        "evil_twin_min_bssids": 3,
        "evil_twin_min_ouis": 2,
        "karma_min_ssids": 8,
        "karma_min_responses": 20,
        "enable_deauth": True,
        "enable_beacon": True,
        "enable_evil_twin": True,
        "enable_karma": True,
    },
    "aggressive": {
        "min_duration_sec": 3,
        "deauth_min_rate": 1.5,
        "deauth_min_frames": 10,
        "deauth_min_targets": 1,
        "beacon_min_bssid_rate": 1.0,
        "beacon_min_unique_bssids": 15,
        "beacon_min_singleton_ratio": 0.5,
        # Two BSSIDs from two vendors is what a venue with mixed hardware
        # looks like; the corpus gate caught exactly that as a false
        # positive. Three is the floor on every profile.
        "evil_twin_min_bssids": 3,
        "evil_twin_min_ouis": 2,
        "karma_min_ssids": 5,
        "karma_min_responses": 10,
        "enable_deauth": True,
        "enable_beacon": True,
        "enable_evil_twin": True,
        "enable_karma": True,
    },
}


@dataclass
class Match:
    name: str
    confidence: int
    evidence: str


def oui(mac: str) -> str:
    return mac[:8].upper()


class Stats:
    def __init__(self) -> None:
        self.total_frames = 0
        self.duration = 0.0
        self.duration_estimated = False
        self.deauth_frames = 0
        self.deauth_targets: Set[str] = set()
        self.deauth_sources: Set[str] = set()
        self.deauth_reasons: Dict[int, int] = {}
        self.beacon_frames = 0
        self.beacon_bssid_counts: Dict[str, int] = {}
        self.beacon_ssids: Set[str] = set()
        self.ssid_bssids: Dict[str, Set[str]] = {}
        self.probe_resp_ssids: Dict[str, Set[str]] = {}
        self.probe_resp_counts: Dict[str, int] = {}
        self.probe_req_frames = 0

    def add(self, frame) -> None:
        self.total_frames += 1
        if frame.subtype in (12, 10):
            self.deauth_frames += 1
            if frame.da:
                self.deauth_targets.add(frame.da)
            if frame.sa:
                self.deauth_sources.add(frame.sa)
            if frame.reason is not None:
                self.deauth_reasons[frame.reason] = self.deauth_reasons.get(frame.reason, 0) + 1
        elif frame.subtype == 8:
            self.beacon_frames += 1
            if frame.bssid:
                self.beacon_bssid_counts[frame.bssid] = self.beacon_bssid_counts.get(frame.bssid, 0) + 1
                if frame.ssid:
                    self.beacon_ssids.add(frame.ssid)
                    self.ssid_bssids.setdefault(frame.ssid, set()).add(frame.bssid)
        elif frame.subtype == 5:
            if frame.bssid:
                self.probe_resp_counts[frame.bssid] = self.probe_resp_counts.get(frame.bssid, 0) + 1
                if frame.ssid:
                    self.probe_resp_ssids.setdefault(frame.bssid, set()).add(frame.ssid)
        elif frame.subtype == 4:
            self.probe_req_frames += 1

    @property
    def deauth_rate(self) -> float:
        return self.deauth_frames / max(self.duration, 0.001)

    @property
    def beacon_bssid_rate(self) -> float:
        return len(self.beacon_bssid_counts) / max(self.duration, 0.001)

    @property
    def beacon_singleton_ratio(self) -> float:
        if not self.beacon_bssid_counts:
            return 0.0
        singles = sum(1 for c in self.beacon_bssid_counts.values() if c == 1)
        return singles / len(self.beacon_bssid_counts)


def build_stats(frames, duration: float = 0.0) -> Stats:
    stats = Stats()
    materialised = list(frames)
    for frame in materialised:
        stats.add(frame)
    if duration and duration > 0:
        stats.duration = duration
    else:
        derived = wifi_parse.capture_duration(materialised)
        if derived <= 0:
            stats.duration = ASSUMED_DURATION_SEC
            stats.duration_estimated = True
        else:
            stats.duration = derived
    return stats


def parse_log(path: str) -> Stats:
    try:
        frames = wifi_parse.parse_frames(path)
    except FileNotFoundError:
        print(f"ERROR: input file not found: {path}", file=sys.stderr)
        sys.exit(2)
    return build_stats(frames)


def config_path_default() -> str:
    root = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    return os.path.join(root, "config", "wifi-signatures.conf")


def load_config(profile: str, config_path: str) -> SignatureConfig:
    return load_rules(profile, config_path, DEFAULT_RULES, "config/wifi-signatures.conf.example")


def evaluate(stats: Stats, cfg: SignatureConfig) -> List[Match]:
    matches: List[Match] = []
    if stats.total_frames == 0:
        return matches
    if stats.duration < get_int(cfg.rules, "min_duration_sec"):
        return matches
    rules = cfg.rules

    if (
        get_bool(rules, "enable_deauth")
        and stats.deauth_rate >= get_float(rules, "deauth_min_rate")
        and stats.deauth_frames >= get_int(rules, "deauth_min_frames")
        and len(stats.deauth_targets) >= get_int(rules, "deauth_min_targets")
    ):
        broadcast = BROADCAST in stats.deauth_targets
        top_reason = max(stats.deauth_reasons.items(), key=lambda kv: kv[1])[0] if stats.deauth_reasons else None
        score = 50 + min(int(stats.deauth_rate), 30) + (10 if broadcast else 0)
        matches.append(Match(
            name="Deauthentication/disassociation flood",
            confidence=clamp_confidence(score),
            evidence=(f"deauth_rate={stats.deauth_rate:.1f}/s, frames={stats.deauth_frames}, "
                      f"targets={len(stats.deauth_targets)}, sources={len(stats.deauth_sources)}, "
                      f"broadcast={'yes' if broadcast else 'no'}, top_reason={top_reason}"),
        ))

    if (
        get_bool(rules, "enable_beacon")
        and stats.beacon_bssid_rate >= get_float(rules, "beacon_min_bssid_rate")
        and len(stats.beacon_bssid_counts) >= get_int(rules, "beacon_min_unique_bssids")
        and stats.beacon_singleton_ratio >= get_float(rules, "beacon_min_singleton_ratio")
    ):
        score = 50 + min(int(stats.beacon_bssid_rate * 4), 25) + int(stats.beacon_singleton_ratio * 20)
        matches.append(Match(
            name="Beacon flood (fake access points)",
            confidence=clamp_confidence(score),
            evidence=(f"bssid_rate={stats.beacon_bssid_rate:.1f}/s, unique_bssids={len(stats.beacon_bssid_counts)}, "
                      f"singleton_ratio={stats.beacon_singleton_ratio:.2f}, unique_ssids={len(stats.beacon_ssids)}"),
        ))

    if get_bool(rules, "enable_evil_twin"):
        twins = []
        for ssid, bssids in stats.ssid_bssids.items():
            if len(bssids) < get_int(rules, "evil_twin_min_bssids"):
                continue
            ouis = {oui(b) for b in bssids}
            if len(ouis) >= get_int(rules, "evil_twin_min_ouis"):
                twins.append((ssid, len(bssids), len(ouis)))
        # A beacon flood invents SSIDs by the hundred and would trip this
        # on every one of them; that is the flood family's finding, not this one.
        if twins and stats.beacon_singleton_ratio < 0.5:
            twins.sort(key=lambda t: -t[1])
            ssid, n_bssids, n_ouis = twins[0]
            score = 45 + min(n_bssids * 5, 25) + min(n_ouis * 5, 20)
            matches.append(Match(
                name="Evil twin (one SSID from unrelated hardware)",
                confidence=clamp_confidence(score),
                evidence=(f"ssid={ssid!r}, bssids={n_bssids}, vendor_ouis={n_ouis}, "
                          f"other_ssids_affected={len(twins) - 1}"),
            ))

    if get_bool(rules, "enable_karma"):
        best = None
        for bssid, ssids in stats.probe_resp_ssids.items():
            if (len(ssids) >= get_int(rules, "karma_min_ssids")
                    and stats.probe_resp_counts.get(bssid, 0) >= get_int(rules, "karma_min_responses")):
                if best is None or len(ssids) > best[1]:
                    best = (bssid, len(ssids), stats.probe_resp_counts[bssid])
        if best is not None:
            bssid, n_ssids, n_resp = best
            score = 55 + min(n_ssids * 2, 30)
            matches.append(Match(
                name="KARMA-style responder (one AP answering for many SSIDs)",
                confidence=clamp_confidence(score),
                evidence=f"bssid={bssid}, distinct_ssids_answered={n_ssids}, probe_responses={n_resp}",
            ))

    return sorted(matches, key=lambda m: m.confidence, reverse=True)
