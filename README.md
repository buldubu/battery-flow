# Battery Flow

A macOS menu-bar app for seeing how power moves between your adapter, battery, and Mac.

Battery Flow displays live power, charge, temperature, battery health, and local history. It reads battery information; charging limits and energy settings remain under macOS control.

## Features

- Live power flow with charging, fully charged, paused, battery-only, and adapter-plus-battery states.
- Battery condition, maximum capacity, cycles, and the dates of health readings reported by macOS.
- Interactive power, charge, and temperature history with 1-, 7-, or 30-day retention, recorded averages/peaks, and CSV export.
- Native Settings for appearance, menu-bar percentage, temperature units, animation, history, and launch at login.
- Validated readings, visible stale-data warnings, and recovery for partially damaged history files.
- Local operation without accounts, analytics, or network telemetry.

A neutral plug appears for up to three seconds after connecting power while charging status settles. It switches immediately when macOS reports charging or a full battery.

During a telemetry transition, last-known wattages remain visible for at most 45 seconds after their last coherent reading. A waiting label distinguishes cached values from live readings. After expiry, wattages are hidden until consistent telemetry returns; charge and charging status continue updating independently.

The lightning bolt inside the battery icon means **Charging**. During **Sailing**, only the sailboat is shown (plus the percentage when enabled): an adapter is connected and charging is paused. The battery icon reflects the current charge level, including a proportional fill behind the lightning bolt while charging.

## Requirements

- Apple silicon MacBook running macOS 13 or later.
- Swift 6 or later, supplied by Xcode or Apple's Command Line Tools, to build.
- macOS 14 or later to run the Swift Testing suite with the current toolchain.

There are no external Swift package dependencies. Telemetry availability varies by Mac and macOS version; Intel Macs are not currently supported.

The standard commands use `Scripts/swift-tool.py` and Python 3. They explicitly select SwiftPM's native build backend and compile a small SwiftUI probe against the selected SDK. If the default SDK fails the probe, the newest working older installed macOS SDK is selected with a diagnostic. This handles Command Line Tools installations whose macOS 27 SDK lacks the required SwiftUI macro implementation; macOS 26.5 is verified locally. Explicit SDK selections are never silently replaced. If no SDK passes, install matching Xcode/Command Line Tools.

To select an SDK or try another backend, set `BATTERYFLOW_SWIFT_SDK` to its SDK directory and/or `BATTERYFLOW_BUILD_SYSTEM` to `swiftbuild`. `DEVELOPER_DIR` selects the toolchain; an explicit `--sdk` argument also pins the SDK. `SDKROOT` supplies the initial automatic SDK candidate and may fall back if its probe fails. Build, test, package, and UI-review commands use the same selection process.

## Build and install

From the project directory:

```sh
make build
make test
make app
```

The packaged application is created at `build/BatteryFlow.app`. To install and launch it:

```sh
make install
```

Installation replaces `/Applications/BatteryFlow.app` after preserving the previous application, history, and preferences in a local rollback directory. It does not register or re-enable launch at login. Local builds use ad-hoc signing; Developer ID signing and notarization are a separate distribution step.

## Settings

Open the menu-bar panel and choose **Settings…**, or press **Command-comma** while Battery Flow has focus. Reopening the app also opens its reusable Settings window.

| Tab | Available settings |
|---|---|
| General | Launch at login, System/Light/Dark appearance, menu-bar percentage, Celsius/Fahrenheit, flow animation, version/build |
| History | Recording, retention, sample counts, retrying failed saves, clearing history |
| Battery | Health and freshness, Refresh Health, Open Battery Settings |

Defaults are System appearance, icon only, Celsius, animation enabled, recording enabled, 30-day retention, and Power/24H history. Existing macOS login registration is preserved; new installations do not enable it automatically.

Pausing history recording keeps existing data within the retention period. Clearing history and shortening retention enough to delete records require confirmation. Charge limits, Optimized Battery Charging, and Low Power Mode are managed in **macOS Battery Settings**, where available.

## Data and privacy

Expand **History** to inspect readings by hovering or dragging across the chart. Focus the chart and use Left/Right, or choose the previous/next buttons. Averaged chart points show their observation count and time span. Average and peak statistics use valid original observations, rather than averaged chart buckets; they describe recorded samples, not time-weighted energy use. Gaps remain visible.

The power chart uses positive values for power being supplied and negative values for consumption. Adapter input is above zero; Mac consumption is below zero. Battery charging appears below zero and discharge above zero, with explicit Charging, Discharging, or Idle inspection labels. This separates adapter input from Mac consumption when their wattages match.

**Export CSV…** saves all original observations in the selected time range, across all metrics, including pending unsaved observations. It captures a snapshot when clicked, and the save dialog remains available if the menu-bar popover closes. CSV timestamps use ISO 8601 UTC, temperatures use Celsius, and numeric fields use decimal points. Missing or rejected measurements are blank; quality and provenance columns remain available. Exported files may reveal usage patterns.

CSV retains the recorded measurement convention: adapter input and Mac consumption are positive magnitudes; battery power is positive while charging and negative while discharging. The chart's sign conversion does not change stored or exported readings.

History is stored at `~/Library/Application Support/BatteryFlow/power-history.jsonl`. Preferences and dated health values use the app's local defaults domain. The app does not persist battery serial numbers or change charging hardware settings.

Corrupt-file recovery creates a separate backup before rewriting valid records. Failed saves remain in memory for retry; quitting before they are saved can lose those pending observations. Local diagnostic logs and rollback copies may contain paths and usage history, so review and redact them before sharing an issue report.

## Development

- [Contributing](CONTRIBUTING.md): development workflow, tests, and useful bug reports.
- [Architecture](docs/ARCHITECTURE.md): telemetry, health, scheduling, persistence, and rendering.
- [Changelog](CHANGELOG.md): version history.
- [Platform dependencies and notices](THIRD_PARTY_NOTICES.md).

## Compatibility

Local testing has covered an Apple silicon MacBook Air on macOS 26.6.2. macOS 13 is the minimum deployment target; physical testing on older supported versions and additional hardware remains incomplete. A full VoiceOver and keyboard-only review, native popover lifecycle checks, and real Low Power Mode, Reduce Motion, and login-approval transitions remain unverified.

## License

[MIT](LICENSE). Copyright (c) 2026 Kadir Burak Buldu.
