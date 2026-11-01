import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("swift_tool", SOURCE / "Scripts/swift-tool.py")
swift_tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(swift_tool)


class BuildCompatibility(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="battery-flow-sdks-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.current = self.sdk("27.2")
        self.compatible = self.sdk("26.5")
        self.old = self.sdk("26.0")

    def sdk(self, version):
        path = self.root / f"MacOSX{version}.sdk"
        path.mkdir()
        (path / "SDKSettings.plist").write_bytes(plistlib.dumps({"Version": version}))
        return path.resolve()

    def test_working_default_is_preserved(self):
        tried = []

        def probe(sdk):
            tried.append(sdk)
            return True

        self.assertEqual(swift_tool.select_sdk(self.current, None, probe), self.current)
        self.assertEqual(tried, [self.current])

    def test_newest_working_older_sdk_is_selected(self):
        alias = self.root / "MacOSX.sdk"
        alias.symlink_to(self.current, target_is_directory=True)
        tried = []

        def probe(sdk):
            tried.append(sdk)
            return sdk == self.compatible

        self.assertEqual(swift_tool.select_sdk(alias, None, probe), self.compatible)
        self.assertEqual(tried, [self.current, self.compatible])

    def test_explicit_sdk_failure_is_not_silently_overridden(self):
        tried = []

        def probe(sdk):
            tried.append(sdk)
            return False

        with self.assertRaisesRegex(ValueError, "matching Xcode"):
            swift_tool.select_sdk(self.current, str(self.current), probe)
        self.assertEqual(tried, [self.current])

    def test_missing_sdk_and_no_compatible_sdk_have_actionable_errors(self):
        with self.assertRaisesRegex(ValueError, "does not exist"):
            swift_tool.select_sdk(self.root / "missing", None, lambda sdk: True)
        with self.assertRaisesRegex(ValueError, "BATTERYFLOW_SWIFT_SDK"):
            swift_tool.select_sdk(self.current, None, lambda sdk: False)

    def test_overrides_and_paths_with_spaces_are_forwarded_as_arguments(self):
        with patch.dict(os.environ, {"BATTERYFLOW_SWIFT_SDK": str(self.compatible)}, clear=True), \
                patch.object(subprocess, "check_output", return_value=str(self.current)), \
                patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(subprocess, "call", return_value=0) as call:
            result = swift_tool.main(["build", "--package-path", "/fixture/project with spaces", "-c", "release"])
            self.assertEqual(result, 0)
            self.assertEqual(call.call_args.args[0], ["xcrun", "swift", "build", "--build-system", "native", "--sdk",
                                                    str(self.compatible), "--package-path",
                                                    "/fixture/project with spaces", "-c", "release"])

    def test_command_line_overrides_are_not_duplicated(self):
        arguments = ["test", "--sdk", str(self.compatible), "--build-system=swiftbuild", "--filter", "History"]
        with patch.dict(os.environ, {}, clear=True), \
                patch.object(subprocess, "check_output", return_value=str(self.current)), \
                patch.object(subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(subprocess, "call", return_value=7) as call:
            self.assertEqual(swift_tool.main(arguments), 7)
            self.assertEqual(call.call_args.args[0], ["xcrun", "swift"] + arguments)

    def test_inherited_sdkroot_can_fall_back(self):
        def compile_probe(arguments, **kwargs):
            sdk = Path(arguments[arguments.index("-sdk") + 1])
            return subprocess.CompletedProcess(arguments, 0 if sdk == self.compatible else 1)

        with patch.dict(os.environ, {"SDKROOT": str(self.current)}, clear=True), \
                patch.object(subprocess, "run", side_effect=compile_probe), \
                patch.object(subprocess, "call", return_value=0) as call:
            self.assertEqual(swift_tool.main(["build"]), 0)
            self.assertIn(str(self.compatible), call.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
