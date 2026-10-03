#!/usr/bin/env python3
"""Alert on Wi-Fi attacks live, from a wifi-obs/1 stream.

The Wi-Fi adapter for the shared live window (live_window.py): a sliding
window over each observation's own timestamp, the shared wifi_signatures
detector run over it on a fixed cadence, text for the operator and one
wifi-alert/1 JSON record per evaluation for a SIEM or the collector.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import live_window  # noqa: E402
import wifi_parse  # noqa: E402
import wifi_signatures  # noqa: E402


def frame_from_event(event):
    return wifi_parse.WifiFrame(
        timestamp=event.get("ts"),
        subtype=int(event.get("subtype", -1) or -1),
        sa=str(event.get("address", "") or ""),
        da=str(event.get("da", "") or ""),
        bssid=str(event.get("bssid", "") or ""),
        ssid=str(event.get("name", "") or ""),
        rssi=event.get("rssi"),
        channel=event.get("channel"),
        reason=event.get("reason"),
    )


MODALITY = live_window.Modality(
    schema_prefix="wifi-obs/",
    alert_schema="wifi-alert/1",
    name="wifi",
    from_event=frame_from_event,
    build_stats=wifi_signatures.build_stats,
    evaluate=wifi_signatures.evaluate,
    status_line=lambda s: (f"frames={s.total_frames} deauth={s.deauth_rate:.1f}/s "
                           f"bssids={len(s.beacon_bssid_counts)} singleton={s.beacon_singleton_ratio:.2f}"),
    alert_fields=lambda s: {
        "frames": s.total_frames,
        "deauth_rate": round(s.deauth_rate, 3),
        "unique_bssids": len(s.beacon_bssid_counts),
        "beacon_singleton_ratio": round(s.beacon_singleton_ratio, 3),
    },
)


def main() -> int:
    return live_window.main_for(MODALITY, wifi_signatures.load_config,
                                wifi_signatures.config_path_default,
                                "Alert on Wi-Fi attacks from a live observation stream")


if __name__ == "__main__":
    sys.exit(main())
