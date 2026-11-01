#!/usr/bin/env python3
"""Use one build backend and a working SwiftUI SDK for every local entry point."""
import os
import platform
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def option(arguments, name):
    for index, argument in enumerate(arguments):
        if argument == name:
            if index + 1 == len(arguments):
                raise ValueError(f"{name} requires a value")
            return arguments[index + 1]
        if argument.startswith(name + "="):
            return argument.split("=", 1)[1]
    return None


def sdk_version(path):
    try:
        with (path / "SDKSettings.plist").open("rb") as file:
            return tuple(int(part) for part in plistlib.load(file)["Version"].split("."))
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException):
        return ()


def select_sdk(default, explicit, probe):
    """Only fall back when the selected SDK cannot compile the SwiftUI API we use."""
    selected = Path(explicit or default).resolve()
    if not selected.is_dir():
        raise ValueError(f"macOS SDK does not exist: {selected}")
    if probe(selected):
        return selected
    if not explicit:
        candidates = {path.resolve() for path in selected.parent.glob("MacOSX*.sdk")}
        candidates = sorted((path for path in candidates if sdk_version(path) < sdk_version(selected)),
                            key=sdk_version, reverse=True)
        for candidate in candidates:
            if probe(candidate):
                print(f"SwiftUI SDK compatibility: using {candidate.name}; {selected.name} failed its compile check.",
                      file=sys.stderr)
                return candidate
    raise ValueError("The selected SDK cannot compile SwiftUI @State. Install matching Xcode/Command Line Tools "
                     "or set BATTERYFLOW_SWIFT_SDK to a compatible macOS SDK (macOS 26.5 is verified).")


def main(arguments):
    if not arguments or arguments[0] not in ("build", "test", "package"):
        raise ValueError("Usage: swift-tool.py {build|test|package} [SwiftPM arguments]")
    # Keep SwiftPM's output layout stable across Swift 6.0–6.4. Swift Build has a
    # different layout and currently fails to initialize in some CLT installations.
    backend = option(arguments, "--build-system") or os.environ.get("BATTERYFLOW_BUILD_SYSTEM", "native")
    if backend not in ("native", "swiftbuild", "xcode"):
        raise ValueError("BATTERYFLOW_BUILD_SYSTEM must be native, swiftbuild, or xcode")
    command = ["xcrun", "swift", arguments[0]]
    if option(arguments, "--build-system") is None:
        command += ["--build-system", backend]
    if arguments[0] != "package":
        default = os.environ.get("SDKROOT") or subprocess.check_output(
            ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        explicit = option(arguments, "--sdk") or os.environ.get("BATTERYFLOW_SWIFT_SDK")
        with tempfile.TemporaryDirectory(prefix="battery-flow-sdk-") as directory:
            source = Path(directory) / "Probe.swift"
            source.write_text("import SwiftUI\nstruct BatteryFlowSDKProbe { @State var expanded = false }\n")

            def probe(sdk):
                result = subprocess.run(["xcrun", "swiftc", "-typecheck", "-target",
                                         f"{platform.machine()}-apple-macosx13.0", "-sdk", str(sdk), str(source)],
                                        capture_output=True, text=True)
                return result.returncode == 0

            sdk = select_sdk(default, explicit, probe)
        if option(arguments, "--sdk") is None:
            command += ["--sdk", str(sdk)]
    return subprocess.call(command + arguments[1:])


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Build setup error: {error}")
