# Architecture

Battery Flow is a SwiftPM executable with SwiftUI views and AppKit window integration. It has no external package dependencies.

## Telemetry

`BatteryTelemetryReader` reads AppleSmartBattery properties through IOKit and power-source state through the macOS power-source API. `PowerMath` validates individual values and power balance, retaining legitimate zeros and rejecting invalid ranges and sentinels.

Each power reading has reported, calculated, or unavailable provenance. Adapter rating is separate from actual input. Direct telemetry takes priority; voltage/current calculations and balanced-power derivations require sufficient valid measurements. A disagreement greater than 1 W suppresses misleading power values while retaining valid charge, temperature, and health information.

`PowerMonitor` coordinates one cancellable polling schedule, coalesces source notifications, and prevents overlapping reads. Intervals are 1 second visible and 30 seconds hidden, or 2/60 seconds in Low Power Mode. Opening the panel, waking, and changing power source trigger a refresh.

Live presentation uses a three-second time-based smoothing constant. Source, state, direction, and sleep/wake changes reset smoothing. History receives validated unsmoothed observations. Failures preserve the last successful timestamp and mark readings stale.

Some IORegistry telemetry keys and `system_profiler` output are hardware- and OS-dependent. Missing values remain unavailable; compatibility with every future schema is not assumed.

## Health

Health is independent of live power. The fast power-source API supplies condition; a bounded background `system_profiler SPPowerDataType -json` read supplies detailed OS health and maximum capacity. It runs at startup, at most hourly, or on manual refresh, with a ten-second timeout.

Successful values are cached with their dates. An OS service warning is retained if the fast API temporarily reports Good. The app does not derive a service diagnosis from capacity or cycle thresholds.

## Persistence

`HistoryPersistence` is a serial actor. Load, append, prune, retry, and clear transactions contain no suspension points. `HistoryStore` publishes UI state on the main actor.

History records one observation per minute while awake and recording. JSONL schema 2 adds quality and provenance. Legacy records, including the old sailing state, retain timestamps and measurements. Invalid legacy power is excluded from power graphs and counted.

Recovery backs up partially damaged files before rewriting valid records. Wholly unreadable or future-format files remain untouched. Pending writes stay in memory within retention; retries reconcile IDs to avoid duplicate records after partial writes. Quitting before a failed save is recovered can lose pending observations.

Aggregation is cached by data revision, range, and current minute. Stable time buckets and separate recording segments preserve graph identity and visible gaps. Charts use linear interpolation.

## UI and preferences

`AppPreferences` stores typed preferences in UserDefaults. `SettingsWindowController` reuses one NSWindowController hosting SwiftUI content. `LaunchAtLoginController` treats macOS registration status as authoritative and only changes registration in response to user action.

`AppTypography` defines shared text roles. `PowerFlowLines` uses Core Animation for moving dashes; SwiftUI updates the layout and values with readings. Hidden views, disabled animation, Reduce Motion, Low Power Mode, and stale readings pause motion.

The reader, clock, preferences, health service, and history file access can be injected. Tests and the UI review tool use isolated stores rather than changing an installed application's data.
