"""Load a detector's rule thresholds from a profile plus an optional INI file.

Both the BLE and the Wi-Fi detectors ship three profiles of built-in
thresholds and let the operator override them per profile in a config file.
The loading rules are the same for both and live here once:

  * the profile on the command line wins; otherwise [general] profile in the
    file; otherwise 'balanced'
  * only keys the detector knows are applied; unknown keys are reported on
    stderr, because a misspelled threshold that silently stays at its default
    is the failure this exists to prevent
  * values are coerced to the type of the built-in default
"""

import configparser
import os
import sys
from typing import Dict, List


class SignatureConfig:
    def __init__(self, profile: str, rules: Dict[str, object], source: str) -> None:
        self.profile = profile
        self.rules = rules
        self.source = source


def load_rules(profile: str, config_path: str, defaults: Dict[str, Dict[str, object]],
               example_name: str) -> SignatureConfig:
    selected = profile.lower() if profile else ""
    if not selected or selected not in defaults:
        selected = "balanced"

    rules = dict(defaults[selected])
    source = f"defaults:{selected}"

    if not config_path or not os.path.exists(config_path):
        return SignatureConfig(selected, rules, source)

    parser = configparser.ConfigParser()
    parser.read(config_path)

    if not profile and parser.has_option("general", "profile"):
        requested = parser.get("general", "profile").strip().lower()
        if requested in defaults:
            selected = requested
            rules = dict(defaults[selected])

    if parser.has_section(selected):
        unknown: List[str] = []
        for key, value in parser.items(selected):
            base = rules.get(key)
            if base is None:
                unknown.append(key)
                continue
            if isinstance(base, bool):
                rules[key] = value.strip().lower() in ("1", "true", "yes", "on")
            elif isinstance(base, float):
                try:
                    rules[key] = float(value)
                except ValueError:
                    print(f"WARNING: {config_path}: {key} is not a number: {value!r} (keeping default)",
                          file=sys.stderr)
            elif isinstance(base, int):
                try:
                    rules[key] = int(value)
                except ValueError:
                    print(f"WARNING: {config_path}: {key} is not an integer: {value!r} (keeping default)",
                          file=sys.stderr)
        if unknown:
            print(f"WARNING: {config_path} [{selected}]: {len(unknown)} unrecognised key(s) ignored: "
                  f"{', '.join(sorted(unknown))}", file=sys.stderr)
            print(f"WARNING: these thresholds are NOT in effect. Compare against {example_name}.",
                  file=sys.stderr)

    return SignatureConfig(selected, rules, f"{config_path}:{selected}")


def get_int(rules: Dict[str, object], key: str) -> int:
    return int(rules[key])


def get_float(rules: Dict[str, object], key: str) -> float:
    return float(rules[key])


def get_bool(rules: Dict[str, object], key: str) -> bool:
    value = rules[key]
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def clamp_confidence(value: int) -> int:
    return max(1, min(99, value))
