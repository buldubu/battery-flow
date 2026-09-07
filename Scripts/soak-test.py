#!/usr/bin/env python3
"""Read-only runtime and history validation for Battery Flow."""
import argparse
import json
import math
import datetime
import platform
import plistlib
import re
from pathlib import Path
import statistics
import subprocess
import sys
import time


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def power_consistent(point):
    a, b, s = (point.get(k) for k in ("adapterPowerWatts", "batteryPowerWatts", "systemPowerWatts"))
    for value, low in ((a, 0), (b, -250), (s, 0)):
        if value is not None and (not number(value) or not low <= value <= 250):
            return False
    if point.get("externalConnected") is False:
        if a is not None and a > 0.05 or b is not None and b > 0.2:
            return False
    if a is not None and b is not None and s is None and a - b < -1.0:
        return False
    if s is not None and b is not None and a is None and s + b < -1.0:
        return False
    return not all(value is not None for value in (a, b, s)) or abs(a - s - b) <= 1.0


def validate(rows):
    errors, legacy_anomalies, flagged = [], 0, 0
    for index, point in enumerate(rows, 1):
        if point.get("schemaVersion", 1) < 2:
            legacy_anomalies += not power_consistent(point)
            continue
        reason = []
        if point.get("schemaVersion") != 2:
            reason.append("unsupported schema")
        if not number(point.get("timestamp")):
            reason.append("invalid timestamp")
        for key, bounds in (("chargePercent", (0, 100)), ("temperatureCelsius", (-20, 100))):
            value = point.get(key)
            if value is not None and (not number(value) or not bounds[0] <= value <= bounds[1]):
                reason.append("invalid " + key)
        quality = point.get("quality")
        values = [point.get(k) for k in ("adapterPowerWatts", "batteryPowerWatts", "systemPowerWatts")]
        if quality == "valid" and (any(v is None for v in values) or not power_consistent(point)):
            reason.append("inconsistent or missing power marked valid")
        elif quality == "partial" and not power_consistent(point):
            reason.append("invalid partial power")
        elif quality == "inconsistent":
            flagged += 1
            if any(v is not None for v in values):
                reason.append("inconsistent power was not suppressed")
        elif quality not in ("valid", "partial", "legacy"):
            reason.append("unknown quality")
        for field, value in zip(("adapterSource", "batterySource", "systemSource"), values):
            source = point.get(field)
            if value is None and source != "unavailable":
                reason.append("missing value has incorrect provenance")
            if value is not None and source not in ("reported", "calculated", "legacy"):
                reason.append("power value has incorrect provenance")
        battery = point.get("batteryPowerWatts")
        if number(battery):
            state = point.get("state")
            if state == "charging" and battery < -0.2 or state == "supplementing" and battery > 0.2:
                reason.append("state contradicts battery direction")
            if state in ("charged", "paused") and abs(battery) > 0.2:
                reason.append("idle state contradicts battery flow")
        if reason:
            errors.append({"line": index, "reasons": reason})
    return {"legacy_power_anomalies": legacy_anomalies, "flagged_new_samples": flagged, "validation_errors": errors}


def history_rows(path):
    rows, malformed = [], 0
    if not path.exists():
        return rows, malformed
    for line in path.read_text().splitlines():
        try:
            rows.append(json.loads(line))
        except (ValueError, TypeError):
            malformed += 1
    return rows, malformed


def process_sample(pid):
    text = subprocess.check_output(["ps", "-p", str(pid), "-o", "time=,%cpu=,rss="], text=True).strip()
    if not text:
        raise RuntimeError("Battery Flow exited during the run")
    cpu_time, percent, rss = text.split()
    seconds = 0.0
    for part in cpu_time.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds, float(percent), int(rss) / 1024


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("duration", nargs="?", type=int, default=300)
    parser.add_argument("interval", nargs="?", type=int, default=5)
    parser.add_argument("--label", default="unspecified")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--app-bundle", type=Path, default=Path("/Applications/BatteryFlow.app"))
    parser.add_argument("--history", type=Path,
                        default=Path.home() / "Library/Application Support/BatteryFlow/power-history.jsonl")
    args = parser.parse_args()
    if args.duration < 1 or args.interval < 1:
        parser.error("duration and interval must be positive")
    app_bundle = args.app_bundle.resolve()
    with (app_bundle / "Contents/Info.plist").open("rb") as info_file:
        bundle = plistlib.load(info_file)
    executable = app_bundle / "Contents/MacOS" / bundle["CFBundleExecutable"]
    result = subprocess.run(["pgrep", "-f", "^" + re.escape(str(executable)) + "$"],
                            text=True, capture_output=True)
    if result.returncode:
        sys.exit(f"App is not running from {app_bundle}")
    pid = int(result.stdout.splitlines()[0])
    path = args.history.resolve()
    before, _ = history_rows(path)
    old_ids = {p.get("id") for p in before}
    started = time.monotonic()
    first = process_sample(pid)
    samples = [first]
    last_progress = 0
    print(f"Soak: {args.label}, {args.duration}s, PID {pid}, {len(before)} history samples", flush=True)
    while time.monotonic() - started < args.duration:
        time.sleep(min(args.interval, max(0, args.duration - (time.monotonic() - started))))
        samples.append(process_sample(pid))
        elapsed = time.monotonic() - started
        if elapsed - last_progress >= 60:
            print(f"Progress: {elapsed:.0f}s", flush=True)
            last_progress = elapsed
    elapsed = time.monotonic() - started
    rows, malformed = history_rows(path)
    tail = samples[len(samples) // 2:]
    report = {
        "label": args.label, "pid": pid, "elapsed_seconds": elapsed,
        "app_bundle": str(app_bundle), "history_path": str(path),
        "completed_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "app_version": bundle.get("CFBundleShortVersionString"), "app_build": bundle.get("CFBundleVersion"),
        "macos": platform.mac_ver()[0], "architecture": platform.machine(),
        "cumulative_cpu_percent": (samples[-1][0] - first[0]) / elapsed * 100,
        "sampled_cpu_percent": statistics.mean(s[1] for s in samples),
        "rss_average_mib": statistics.mean(s[2] for s in samples),
        "rss_max_mib": max(s[2] for s in samples),
        "rss_first_mib": first[2], "rss_last_mib": samples[-1][2],
        "rss_second_half_min_mib": min(s[2] for s in tail),
        "rss_second_half_max_mib": max(s[2] for s in tail),
        "rss_second_half_change_mib": tail[-1][2] - tail[0][2],
        "new_history_records": sum(p.get("id") not in old_ids for p in rows),
        "total_history_records": len(rows), "malformed_lines": malformed,
        **validate(rows)
    }
    print(json.dumps(report, indent=2), flush=True)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n")
    if malformed or report["validation_errors"]:
        sys.exit(1)


if __name__ == "__main__":
    main()
