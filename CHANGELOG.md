# Changelog

Versions 0.3.0–0.3.3 were distributed as local builds.

## Unreleased

## 0.3.7 — 2026-09-11

### Changed

- Slim the charging battery outline and bolt, and reduce the plug artwork to better match macOS menu-bar icons.

## 0.3.6 — 2026-09-11

### Fixed

- Keep cached wattages pending when sample counters are unchanged; ignore changes to unused voltage/current inputs.
- Respect macOS reporting that charging stopped, excluding conflicting positive battery power from live animation and history.
- Show a neutral plug for up to three seconds on a new power connection, ending immediately when charging or a full battery is reported.

## 0.3.5 — 2026-09-09

### Fixed

- Refresh promptly after adapter and charging-status changes, including charge-limit changes that do not disconnect the cable.
- Keep retrying while macOS power telemetry settles so hidden status no longer waits for the normal 30-second polling interval.
- Treat macOS charging status as authoritative when older wattage samples disagree, and exclude those samples from animation and history.
- Accept fresh battery and system-load samples while adapter input remains idle, preventing connected non-charging telemetry from remaining blank.
- Keep the last coherent same-source wattages visible during a transition without presenting them as current measurements.
- Distinguish connected battery discharge from a disconnected Mac while retaining Adapter + Battery when the adapter also supplies power.

### Changed

- Update the soak validator for legitimate battery discharge during a connected, non-charging state.

## 0.3.4 — 2026-09-08

### Fixed

- Show only the sailboat during Sailing, with the optional percentage when enabled.
- Draw the actual charge level behind a centered lightning bolt while charging, without extra menu-bar width.
- Render each menu-bar state as a single native image so its symbols and optional percentage remain visible.
- Prevent delayed battery-only power readings from overriding macOS's charging status; suppress conflicting wattages and animation until readings agree.
- Reset the menu-bar indicator when telemetry becomes stale.

### Added

- Regression tests for charging transitions, proportional battery fill, and Sailing rendering.
- A native menu-bar item in the isolated UI review app.
- MIT licensing, contributor documentation, repository hygiene checks, and staged pre-commit checks.
- Build and test CI plus tag-triggered releases with version, ancestry, signing, and package validation.
- License and platform notices in packaged applications.

## 0.3.1 — 2026-09-07

### Changed

- Use consistent interface labels, supporting text, and live-reading typography across the panel, charts, and Settings.
- Improve wrapping and spacing for long messages and health conditions.
- Animate power-flow strokes with Core Animation to reduce application CPU use.

### Fixed

- Replace a health-warning symbol that did not render.
- Restore the sailboat beside the charge-level menu-bar battery for Not Charging.

## 0.3.0 — 2026-09-06

### Added

- Native General, History, and Battery Settings with persisted preferences.
- OS-reported battery health, dated cached values, and manual health refresh.
- Optional telemetry with provenance, power-balance validation, and explicit power states.
- Serialized JSONL persistence, versioned records, recovery backups, save retries, and retention controls.
- Adaptive polling, presentation-only smoothing, and a SwiftPM test target.

### Changed

- Rename Native Sailing to Not Charging and distinguish Fully Charged.
- Keep adapter rating separate from actual input power.
- Preserve legacy measurements and exclude inconsistent legacy power from graphs.
- Use stable aggregation, linear chart interpolation, and visible recording gaps.
