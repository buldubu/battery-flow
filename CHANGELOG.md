# Changelog

Versions 0.3.0 and 0.3.1 were initially distributed as local builds.

## Unreleased

- Add the MIT license, contributor documentation, and build and test CI.
- Check version consistency, documentation links, and repository file hygiene.
- Include the license and platform notices in packaged applications.

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
