"""Installer non-overwrite/rollback contracts; all filesystem effects are isolated in .build.

codesign and launchctl are simulated here. These checks do not prove signatures,
launchd registration or Accessibility authorization.
"""
import contextlib
import importlib.util
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("poc_installer", ROOT / "scripts/install-accessibility-poc.py")
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
CERTIFICATE = "A1" * 20


class InstallerChecks(unittest.TestCase):
    def setUp(self):
        (ROOT / ".build").mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(prefix="poc-install-check-", dir=ROOT / ".build")
        self.root = Path(self.temporary.name)
        self.home = self.root / "user"
        self.destination = self.home / "Applications/PromptBridge Accessibility.app"
        self.agent = self.home / "Library/LaunchAgents/local.promptbridge.accessibility.plist"
        self.source = self.root / ".build/accessibility-poc/packages/PromptBridge Accessibility PoC.app"
        (self.source / "Contents/MacOS").mkdir(parents=True)
        (self.source / "Contents/MacOS/AccessibilityBroker").write_text("fixture executable")
        (self.source / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
            CFBundleIdentifier="local.promptbridge.accessibility", CFBundleExecutable="AccessibilityBroker",
            PromptBridgeSignerSHA1=CERTIFICATE)))
        self.calls = []
        self.registered = False
        self.fail_bootstrap = False
        self.fail_bootout = False

    def tearDown(self):
        self.temporary.cleanup()

    def run_installer(self, install=False):
        def process(args, **kwargs):
            self.calls.append(args)
            if args[:2] == ["launchctl", "print"]:
                return SimpleNamespace(returncode=0 if self.registered else 1)
            if args[:2] == ["launchctl", "bootstrap"] and self.fail_bootstrap:
                raise subprocess.CalledProcessError(1, args)
            if args[:2] == ["launchctl", "bootout"] and self.fail_bootout:
                return SimpleNamespace(returncode=1)
            return SimpleNamespace(returncode=0)
        args = ["installer", "--certificate", CERTIFICATE] + (["--install"] if install else [])
        with patch.object(installer, "ROOT", self.root), patch.object(installer.Path, "home", return_value=self.home), \
             patch.object(installer.subprocess, "run", side_effect=process), patch.object(sys, "argv", args), \
             contextlib.redirect_stdout(io.StringIO()):
            installer.main()

    def test_dry_run_has_no_user_writes_or_bootstrap(self):
        self.run_installer()
        self.assertFalse(self.home.exists())
        self.assertFalse(any(call[:2] == ["launchctl", "bootstrap"] for call in self.calls))

    def test_existing_app_is_preserved(self):
        self.destination.mkdir(parents=True)
        marker = self.destination / "user.txt"
        marker.write_text("user data")
        with self.assertRaises(ValueError): self.run_installer(True)
        self.assertEqual(marker.read_text(), "user data")

    def test_existing_plist_is_preserved(self):
        self.agent.parent.mkdir(parents=True)
        self.agent.write_text("user configuration")
        with self.assertRaises(ValueError): self.run_installer(True)
        self.assertEqual(self.agent.read_text(), "user configuration")

    def test_existing_stage_file_is_preserved(self):
        stage = self.agent.with_name(self.agent.name + ".stage")
        stage.parent.mkdir(parents=True)
        stage.write_text("unrelated stage")
        with self.assertRaises(FileExistsError): self.run_installer(True)
        self.assertEqual(stage.read_text(), "unrelated stage")
        self.assertFalse(self.destination.exists())

    def test_existing_service_is_not_changed(self):
        self.registered = True
        with self.assertRaises(ValueError): self.run_installer(True)
        self.assertFalse(any(call[:2] == ["launchctl", "bootout"] for call in self.calls))

    def test_bad_source_identity_stops_before_system_calls(self):
        info = self.source / "Contents/Info.plist"
        info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier="com.other.app")))
        with self.assertRaises(ValueError): self.run_installer(True)
        self.assertEqual(self.calls, [])

    def test_first_install_publishes_exact_on_demand_service(self):
        self.run_installer(True)
        self.assertTrue((self.destination / "Contents/MacOS/AccessibilityBroker").exists())
        config = plistlib.loads(self.agent.read_bytes())
        self.assertEqual(config["MachServices"], {"local.promptbridge.accessibility.xpc": True})
        self.assertFalse(config["RunAtLoad"])
        self.assertFalse(config["KeepAlive"])
        self.assertEqual(self.agent.stat().st_mode & 0o777, 0o600)

    def test_failed_bootstrap_keeps_published_files_and_stops_owned_service(self):
        self.fail_bootstrap = True
        with self.assertRaises(subprocess.CalledProcessError): self.run_installer(True)
        self.assertTrue(self.agent.exists())
        self.assertTrue(self.destination.exists())
        self.assertTrue(self.source.exists())
        self.assertTrue(any(call[:2] == ["launchctl", "bootout"] for call in self.calls))
        self.assertFalse(any("tccutil" in call for call in self.calls))

    def test_concurrent_agent_and_new_user_file_are_not_removed(self):
        def concurrent_link(*args):
            self.agent.write_text("concurrent user agent")
            (self.destination / "user-note.txt").write_text("new user data")
            raise FileExistsError("concurrent publication")
        with patch.object(installer.os, "link", side_effect=concurrent_link):
            with self.assertRaises(FileExistsError): self.run_installer(True)
        self.assertEqual(self.agent.read_text(), "concurrent user agent")
        self.assertEqual((self.destination / "user-note.txt").read_text(), "new user data")
        self.assertFalse(any(call[:2] == ["launchctl", "bootout"] for call in self.calls))

    def test_failed_bootout_preserves_plist_and_application(self):
        self.fail_bootstrap = True
        self.fail_bootout = True
        with self.assertRaises(subprocess.CalledProcessError): self.run_installer(True)
        self.assertTrue(self.agent.exists())
        self.assertTrue(self.destination.exists())


if __name__ == "__main__": unittest.main()
