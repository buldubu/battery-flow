# Architecture

Battery Flow is a SwiftPM executable with SwiftUI views and AppKit window integration. It has no external package dependencies.

## Telemetry

`BatteryTelemetryReader` reads AppleSmartBattery properties through IOKit and power-source state through the macOS power-source API. `PowerMath` validates individual values and power balance, retaining legitimate zeros and rejecting invalid ranges and sentinels.

Each power reading has reported, calculated, or unavailable provenance. Adapter rating is separate from actual input. Direct telemetry takes priority; voltage/current calculations and balanced-power derivations require sufficient valid measurements. A disagreement greater than 1 W suppresses misleading power values while retaining valid charge, temperature, and health information.

`PowerMonitor` coordinates one cancellable polling schedule, coalesces source notifications, and prevents overlapping reads. Intervals are 1 second visible and 30 seconds hidden, or 2/60 seconds in Low Power Mode. Opening the panel, waking, and changing power source trigger a refresh.

Live presentation uses a three-second time-based smoothing constant. Source, state, direction, and sleep/wake changes reset smoothing. History receives validated unsmoothed observations. Failures preserve the last successful timestamp and mark readings stale.

Unsettled or inconsistent wattages can reuse a coherent same-connection presentation only while its power timestamp is less than 45 seconds old. At the boundary, cached watts are removed and a waiting message appears, without invalidating independently fresh charge/status readings. An uninterrupted wait longer than 45 seconds returns hidden polling to 30/60 seconds; a new source/status transition or wake starts a fresh retry window.

Some IORegistry telemetry keys and `system_profiler` output are hardware- and OS-dependent. Missing values remain unavailable; compatibility with every future schema is not assumed.

## Health

Health is independent of live power. The fast power-source API supplies condition; a bounded background `system_profiler SPPowerDataType -json` read supplies detailed OS health and maximum capacity. It runs at startup, at most hourly, or on manual refresh, with a ten-second timeout.

Successful values are cached with their dates. An OS service warning is retained if the fast API temporarily reports Good. The app does not derive a service diagnosis from capacity or cycle thresholds.

## Persistence

`HistoryPersistence` is a serial actor. Load, append, prune, retry, and clear transactions contain no suspension points. `HistoryStore` publishes UI state on the main actor.

History records one observation per minute while awake and recording. JSONL schema 2 adds quality and provenance. Legacy records, including the old sailing state, retain timestamps and measurements. Invalid legacy power is excluded from power graphs and counted.

Recovery backs up partially damaged files before rewriting valid records. Wholly unreadable or future-format files remain untouched. Pending writes stay in memory within retention; retries reconcile IDs to avoid duplicate records after partial writes. Quitting before a failed save is recovered can lose pending observations.

Aggregation is cached by data revision, range, and current minute. Stable time buckets and separate recording segments preserve graph identity and visible gaps. Charts use linear interpolation.

Chart inspection snaps to plotted samples and reports the original observation count and time span for each bucket. Summary statistics use unaggregated valid observations. CSV export snapshots the selected range, including pending observations, before opening a standalone save panel. Encoding and atomic disk writes run off the main actor; the export controller remains alive until completion or cancellation even if the popover closes. CSV includes quality/provenance and leaves rejected power values blank.

`HistoryPowerFlow` converts only plotted values to a source/consumer convention: adapter input stays positive, Mac consumption is negated, and battery power is negated so charging is below zero and discharge above zero. Inspection uses directional battery labels. Aggregation, summary statistics, history files, and CSV keep the original measurement convention.

## Build tooling

`Scripts/swift-tool.py` is shared by the Makefile, test runner, packager, and UI-review builder. It uses the native SwiftPM backend by default and probes SwiftUI `@State` at the app's deployment target before selecting an SDK. Only automatic SDK selection may fall back to an older installed SDK. SDK and backend overrides are supported; packagers query SwiftPM for executable locations. The selected toolchain remains controlled by `DEVELOPER_DIR`/`xcode-select`.

## UI and preferences

`AppPreferences` stores typed preferences in UserDefaults. `SettingsWindowController` reuses one NSWindowController hosting SwiftUI content. `LaunchAtLoginController` treats macOS registration status as authoritative and only changes registration in response to user action.

`AppTypography` defines shared text roles. `PowerFlowLines` uses Core Animation for moving dashes; SwiftUI updates the layout and values with readings. Hidden views, disabled animation, Reduce Motion, Low Power Mode, and stale readings pause motion.

The reader, clock, preferences, health service, and history file access can be injected. Tests and the UI review tool use isolated stores rather than changing an installed application's data.
