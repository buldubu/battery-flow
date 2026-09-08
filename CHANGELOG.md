# Changelog

Versions 0.3.0–0.3.3 were distributed as local builds.

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
