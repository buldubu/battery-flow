# Contributing

Bug reports, focused fixes, and compatibility testing are welcome. Before a larger feature, open an issue describing the problem and proposed behavior.

## Development setup

Use an Apple silicon Mac with Swift 6 or later. The app targets macOS 13; running the current Swift Testing suite requires macOS 14 or later. Repository and soak checks also use Python 3 without external Python dependencies.

```sh
make build
make test
make check
make app
```

`make app` creates a local bundle without replacing your installed app. `make install` does replace it and preserves rollback data first. `make clean` preserves local rollback and validation directories.

`make check` checks version consistency, local documentation links, license presence, and candidate files selected by Git's ignore rules. It also flags common credentials and personal absolute paths. It is a limited hygiene check; review the staged diff and source provenance before publishing.

## Changes and tests

Keep pull requests focused. Explain the problem, resulting behavior, and relevant validation. Use clear, imperative commit subjects such as `Fix stale power labels after wake`.

Add regression coverage for changes to telemetry, persistence, scheduling, or other behavior. Tests must inject preferences, clocks, readers, and history storage instead of using the user's real data. Do not enable live-hardware tests in CI.

The optional live check runs with `BATTERYFLOW_LIVE_TEST=1 make test` on a supported MacBook. For a local five-minute runtime report, use `./Scripts/soak-test.sh 300 5 --label hidden --output build/validation/hidden.json`. Keep generated reports local and review them before sharing.

For interface work, run `Scripts/ui-review.sh`. It builds a separate application with isolated preferences, simulated login registration, and a temporary copy of history. Use its scenario selector for representative power states and long error labels. Its live mode reads this Mac; it never changes the installed application's settings or active history. Close it when finished.

Also check the actual menu-bar panel, keyboard focus, VoiceOver labels, appearance changes, and constrained screen sizes. The review window does not replace native popover testing.

## Reporting bugs

Include the app version/build, macOS version, Mac model, relevant adapter information, reproduction steps, expected behavior, and actual behavior. A small redacted example is more useful than an entire history file.

Do not post complete `system_profiler` dumps, preferences, private paths, serial numbers, or usage history. Local files under `build/` and `.build/` are excluded from the repository. Use synthetic fixtures for tests.

## Source and assets

Contributions are licensed under [MIT](LICENSE). Only contribute material you have the right to share under those terms. Identify the origin and compatible license of any copied code or added dependency. Apple framework and SF Symbols assets retain their own terms; see [platform notices](THIRD_PARTY_NOTICES.md).

## Versioning

Keep `VERSION` and `CFBundleShortVersionString` in `Resources/Info.plist` synchronized, and document behavior changes in [CHANGELOG.md](CHANGELOG.md). Use `0.MINOR.PATCH` for feature releases and fixes while the app is pre-1.0. Tags use `vMAJOR.MINOR.PATCH`; packaged apps receive a separate UTC timestamp build number. The packager includes the license and platform notices. Distribute bundles as release assets; keep builds and local reports out of source control.

## Forks

The existing bundle identifier is retained for upgrade and login-item continuity. A separately distributed fork should choose its own identifier and application name, and review the installer and UI-review identifiers to avoid colliding with the original app's defaults or registration.
