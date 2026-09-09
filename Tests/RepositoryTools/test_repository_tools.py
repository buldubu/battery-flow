import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SOURCE = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("release", SOURCE / "Scripts/release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
soak_spec = importlib.util.spec_from_file_location("soak_test", SOURCE / "Scripts/soak-test.py")
soak_test = importlib.util.module_from_spec(soak_spec)
soak_spec.loader.exec_module(soak_test)


class RepositoryFixture(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="battery-flow-tools-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.environment = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull)
        for variable in ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"):
            self.environment.pop(variable, None)
        for name in ("LICENSE", "Resources/Info.plist", "Scripts/check-repository.py", "Scripts/release.py",
                     "Scripts/install-hooks.sh", ".githooks/pre-commit"):
            destination = self.root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(SOURCE / name, destination)
        info_path = self.root / "Resources/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["CFBundleShortVersionString"] = "0.3.1"
        info_path.write_bytes(plistlib.dumps(info))
        self.write("VERSION", "0.3.1\n")
        self.write("CHANGELOG.md", "# Changelog\n\n## 0.3.1\n\n- Example release.\n")
        self.write("README.md", "# Example\n\n[License](LICENSE)\n")
        self.write(".gitignore", "build/\n__pycache__/\n*.jsonl\n*.pem\n")
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Test Fixture")
        self.git("config", "user.email", "fixture@example.test")
        self.git("add", ".")
        self.git("commit", "-qm", "Initial fixture")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def run_command(self, *command):
        return subprocess.run(command, cwd=self.root, env=self.environment, text=True, capture_output=True)

    def git(self, *arguments):
        result = self.run_command("git", *arguments)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def check(self, success, expected=""):
        result = self.run_command(sys.executable, "Scripts/check-repository.py", "--staged")
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertIn(expected, result.stdout)
        return result

    def validate_release(self, success, tag="v0.3.1", expected=""):
        result = self.run_command(sys.executable, "Scripts/release.py", "validate", tag)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        self.assertIn(expected, result.stdout + result.stderr)


class StagedChecks(RepositoryFixture):
    def test_staged_secret_cannot_be_hidden_by_clean_working_copy(self):
        secret = "ghp_" + "a" * 36
        self.write("README.md", secret + "\n")
        self.git("add", "README.md")
        self.write("README.md", "# Clean working copy\n")
        result = self.check(False, "possible credential")
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_unstaged_files_do_not_change_the_checked_snapshot(self):
        self.write("README.md", "# Staged update\n")
        self.git("add", "README.md")
        self.write("README.md", "ghp_" + "a" * 36 + "\n")
        self.write("VERSION", "9.9.9\n")
        self.check(True)

    def test_staged_license_deletion_fails_even_when_local_file_exists(self):
        self.git("rm", "--cached", "LICENSE")
        self.assertTrue((self.root / "LICENSE").is_file())
        self.check(False, "LICENSE is missing")

    def test_force_added_private_files_are_rejected(self):
        for name in ("build/history.jsonl", "signing.pem"):
            self.write(name, "fixture\n")
            self.git("add", "-f", name)
        self.check(False, "must not be tracked")

    def test_staged_whitespace_is_checked(self):
        self.write("README.md", "# Example \n")
        self.git("add", "README.md")
        self.write("README.md", "# Example\n")
        self.check(False, "trailing whitespace")

    def test_version_consistency_uses_the_index(self):
        self.write("VERSION", "0.3.2\n")
        self.git("add", "VERSION")
        self.write("VERSION", "0.3.1\n")
        self.check(False, "Info.plist and VERSION disagree")

    def test_staged_document_deletion_and_link_update_are_valid(self):
        self.write("GUIDE.md", "# Guide\n")
        self.write("README.md", "[Guide](GUIDE.md)\n")
        self.git("add", ".")
        self.git("commit", "-qm", "Add guide")
        self.git("rm", "GUIDE.md")
        self.write("README.md", "# Example\n")
        self.git("add", "README.md")
        self.check(True)

    def test_symlinks_are_rejected(self):
        (self.root / "LINK.md").symlink_to("LICENSE")
        self.git("add", "LINK.md")
        self.check(False, "symlinks and submodules require review")

    def test_personal_paths_with_spaces_are_detected(self):
        self.write("README.md", "/" + "Users/Example User/private/file\n")
        self.git("add", "README.md")
        self.check(False, "personal absolute path")

    def test_existing_hook_is_preserved(self):
        original = "#!/bin/sh\nexit 0\n"
        self.write(".git/hooks/pre-commit", original)
        result = self.run_command("sh", "Scripts/install-hooks.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.root / ".git/hooks/pre-commit").read_text(), original)
        self.assertEqual(self.run_command("git", "config", "--local", "--get", "core.hooksPath").returncode, 1)

    def test_installed_hook_blocks_a_bad_commit(self):
        result = self.run_command("sh", "Scripts/install-hooks.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.write("README.md", "ghp_" + "a" * 36 + "\n")
        self.git("add", "README.md")
        before = self.git("rev-parse", "HEAD")
        result = self.run_command("git", "commit", "-m", "Invalid fixture")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)


class ReleaseChecks(RepositoryFixture):
    def test_matching_tag_on_main_is_accepted(self):
        self.git("tag", "v0.3.1")
        self.validate_release(True)

    def test_tag_version_must_match_source(self):
        self.validate_release(False, "v0.3.2", "does not match VERSION")

    def test_tag_must_match_checked_out_commit(self):
        self.git("tag", "v0.3.1")
        self.write("README.md", "# Changed\n")
        self.git("commit", "-qam", "Update fixture")
        self.validate_release(False, expected="checked-out commit")

    def test_release_commit_must_be_on_main(self):
        self.git("checkout", "-qb", "feature")
        self.write("README.md", "# Feature\n")
        self.git("commit", "-qam", "Feature fixture")
        self.git("tag", "v0.3.1")
        self.validate_release(False, expected="already be on origin/main")

    def test_dirty_release_checkout_is_rejected(self):
        self.git("tag", "v0.3.1")
        self.write("README.md", "# Uncommitted\n")
        self.validate_release(False, expected="clean checkout")

    def test_package_version_must_match(self):
        path = self.root / "build/BatteryFlow.app/Contents/Info.plist"
        path.parent.mkdir(parents=True)
        path.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.3.0"}))
        result = self.run_command(sys.executable, "Scripts/release.py", "package", "v0.3.1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("built app version", result.stderr)
        self.assertFalse((self.root / "build/releases").exists())


class ReleaseNotes(unittest.TestCase):
    def test_only_the_selected_version_is_included(self):
        changelog = "## Unreleased\n\n- Future.\n\n## 0.3.1 — 2026-09-07\n\n- Current.\n\n## 0.3.0\n\n- Old.\n"
        self.assertEqual(release.notes_for_version(changelog, "0.3.1"), "- Current.\n")

    def test_empty_and_missing_entries_fail(self):
        for text in ("## 0.3.1\n\n## 0.3.0\n\n- Old.\n", "## 0.3.10\n\n- Different.\n"):
            with self.assertRaises(ValueError):
                release.notes_for_version(text, "0.3.1")

    def test_invalid_tags_are_rejected(self):
        for tag in ("main", "0.3.1", "v00.3.1", "v0.3.1-beta", "v0.3.1;exit", "v0.3.1\n"):
            with self.assertRaises(ValueError):
                release.version_for_tag(tag)


class SoakValidation(unittest.TestCase):
    @staticmethod
    def point(state, adapter, battery, system):
        return {
            "schemaVersion": 2,
            "timestamp": 1_788_979_200,
            "quality": "valid",
            "adapterPowerWatts": adapter,
            "batteryPowerWatts": battery,
            "systemPowerWatts": system,
            "adapterSource": "reported",
            "batterySource": "reported",
            "systemSource": "reported",
            "externalConnected": True,
            "state": state,
            "chargePercent": 80,
            "temperatureCelsius": 35,
        }

    def test_sailing_allows_connected_battery_discharge(self):
        report = soak_test.validate([self.point("paused", 0, -6, 6)])
        self.assertEqual(report["validation_errors"], [])

    def test_sailing_rejects_battery_charge(self):
        report = soak_test.validate([self.point("paused", 10, 2, 8)])
        self.assertEqual(
            report["validation_errors"][0]["reasons"],
            ["paused state contradicts battery direction"],
        )

    def test_fully_charged_rejects_active_battery_flow(self):
        report = soak_test.validate([self.point("charged", 10, 2, 8)])
        self.assertEqual(
            report["validation_errors"][0]["reasons"],
            ["charged state contradicts battery flow"],
        )


if __name__ == "__main__":
    unittest.main()
