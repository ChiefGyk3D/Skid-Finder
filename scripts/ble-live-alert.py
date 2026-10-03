#!/usr/bin/env python3
"""Alert on BLE spam live, from a normalized observation stream.

The batch scanner judges a capture only after it finishes. In the field you
want to know a flood is happening while it is happening: this reads the
JSONL stream from ble-observe.py, keeps a sliding window of recent
observations, and runs the exact same signature detector (ble_signatures)
over that window on a fixed cadence. The window loop itself is shared with
the Wi-Fi alerter (live_window.py); this file is the BLE adapter.

Detection reuses ble_signatures.evaluate unchanged, so the live path and
the batch path cannot disagree about what counts as spam; a threshold tuned
in config/signatures.conf takes effect in both. Because the window is
short, prefer 'balanced' or 'aggressive' here; 'conservative' may never
accumulate enough in a 30 s window to fire.

Example:

  sudo ./scripts/ble-live-watch.sh            # the supported way
  sudo btmon -i hci0 | ./scripts/ble-observe.py --stream \\
    | ./scripts/ble-live-alert.py --window 30 --interval 5 --profile balanced
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ble_parse  # noqa: E402
import ble_signatures  # noqa: E402
import live_window  # noqa: E402


def record_from_event(event):
    """Rebuild the minimal AdRecord the detector's statistics need."""
    return ble_parse.AdRecord(
        address=event.get("address", ""),
        addr_type=event.get("addr_type", ""),
        addr_class=event.get("addr_class", "unknown"),
        timestamp=event.get("ts"),
        rssi=event.get("rssi"),
        tx_power=event.get("tx_power"),
        name=event.get("name", "") or "",
        flags=event.get("flags", "") or "",
        companies=list(event.get("companies", []) or []),
        company_ids=list(event.get("company_ids", []) or []),
        service_uuids=list(event.get("service_uuids", []) or []),
    )


MODALITY = live_window.Modality(
    schema_prefix="ble-obs/",
    alert_schema="ble-alert/1",
    name="ble",
    from_event=record_from_event,
    build_stats=ble_signatures.build_stats,
    evaluate=ble_signatures.evaluate,
    status_line=lambda s: (f"events={s.total_events} rate={s.event_rate:.1f}/s "
                           f"uniq_ratio={s.unique_ratio:.2f} singleton={s.singleton_ratio:.2f}"),
    alert_fields=lambda s: {
        "events": s.total_events,
        "unique_addrs": len(s.unique_addrs),
        "event_rate": round(s.event_rate, 3),
        "unique_ratio": round(s.unique_ratio, 3),
        "singleton_ratio": round(s.singleton_ratio, 3),
    },
)


def main() -> int:
    return live_window.main_for(MODALITY, ble_signatures.load_config,
                                ble_signatures.config_path_default,
                                "Alert on BLE spam from a live observation stream")


if __name__ == "__main__":
    sys.exit(main())
