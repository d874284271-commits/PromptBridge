"""Desktop artifact/lifecycle contracts. Isolated files and mocked system calls only.

These checks do not prove actual signatures, launchd behavior, AX permissions,
or real update continuity. Those are separate live gates.
"""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import desktop_artifacts as artifacts
LEGACY_CLI_TEST_HOSTS = ["claude:2.1.283", "codex:0.157.1"]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


builder = load("desktop_builder", ROOT / "scripts/build-desktop.py")
installer = load("desktop_installer", ROOT / "scripts/install-desktop.py")
selector = load("desktop_selector", ROOT / "scripts/select-current.py")
CERT = "4B2FF1BE2CA31CA190658D87E3A858CA02C58419"


class DesktopChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="desktop-check-", dir=ROOT / ".build")
        self.root = Path(self.temporary.name)
        self.home = self.root / "user"
        self.calls = []
        self.registered = False
        self.fail_bootstrap = False
        self.fail_signing = False
        self.sources = self.root / "candidates"
        self.sources.mkdir()
        self.main = self.make_app(self.sources / "main.app", artifacts.MAIN)
        self.helper = self.make_app(self.sources / "helper.app", artifacts.COMPONENT)
        self.agent = self.home / "Library/LaunchAgents/local.promptbridge.accessibility.plist"
        self.destination = self.home / "Applications/PromptBridge Accessibility.app"
        self.manifest = self.root / "release.json"
        self.manifest.write_text(json.dumps(dict(main=self.metadata(self.main, artifacts.MAIN),
            component=self.metadata(self.helper, artifacts.COMPONENT), protocolVersion=1, certificateSHA1=CERT)))

    def tearDown(self):
        self.temporary.cleanup()

    def make_app(self, path, bundle, executable_text="fixture", protocol=1, cli_test_hosts=None):
        executable = "PromptBridge" if bundle == artifacts.MAIN else "AccessibilityBroker"
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Resources").mkdir()
        (path / "Contents/MacOS" / executable).write_text(executable_text)
        if bundle == artifacts.MAIN:
            resource_bundle = path / "Contents/MacOS/PromptBridge_PromptBridge.bundle"
            resource_bundle.mkdir()
            for name in artifacts.APP_RESOURCE_FILES:
                (resource_bundle / name).write_bytes(b"fixture " + name.encode())
        info = dict(CFBundleIdentifier=bundle, CFBundleExecutable=executable, CFBundleShortVersionString="1.0.0",
                    CFBundleVersion="1", PromptBridgeSignerSHA1=CERT, PromptBridgeIPCProtocol=protocol)
        metadata = dict(version="1.0.0", build="1", certificateSHA1=CERT, protocolVersion=protocol,
                        supportedOperations=artifacts.OPERATIONS_BY_PROTOCOL[protocol],
                        sourceBinarySHA256=artifacts.digest(path / "Contents/MacOS" / executable))
        if protocol >= 2:
            info["PromptBridgeCLIValidatedHosts"] = []
            if bundle == artifacts.MAIN:
                editor = path / "Contents/MacOS/promptbridge-editor"
                editor.write_text("fixture editor")
                info["PromptBridgeCLIEditorProtocol"] = 2
                metadata["cliEditorProtocol"] = 2
                metadata["cliEditorSourceSHA256"] = artifacts.digest(editor)
            else:
                info["NSAppleEventsUsageDescription"] = "Return to the selected Terminal tab."
        if cli_test_hosts is not None:
            info["PromptBridgeCLITestHosts"] = cli_test_hosts
            metadata["cliTestHosts"] = cli_test_hosts
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (path / "Contents/Resources/build-info.json").write_text(json.dumps(metadata))
        return path

    def signature_command(self, *args):
        self.calls.append(list(args))
        if args[0] == "strip":
            return SimpleNamespace(stdout="", stderr="")
        if self.fail_signing:
            raise subprocess.CalledProcessError(1, args)
        path = Path(args[-1])
        info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
        metadata = json.loads((path / "Contents/Resources/build-info.json").read_text())
        cdhash = artifacts.digest(path / "Contents/MacOS" / info["CFBundleExecutable"])[:40]
        return SimpleNamespace(stdout='', stderr=f'designated => {artifacts.requirement(info["CFBundleIdentifier"], CERT)}\nCDHash={cdhash}\n')

    def metadata(self, path, bundle):
        with patch.object(artifacts, "command", side_effect=self.signature_command):
            return artifacts.verify_app(path, bundle, CERT)

    @staticmethod
    def tree_contents(path):
        return {str(item.relative_to(path)): ("dir", None) if item.is_dir() else ("file", item.read_bytes())
                for item in path.rglob("*")}

    def system_call(self, args, **kwargs):
        self.calls.append(list(args))
        if args[:2] == ["launchctl", "print"]:
            if not self.registered:
                return SimpleNamespace(returncode=113, stdout="", stderr="Could not find service")
            return SimpleNamespace(returncode=0, stderr="", stdout=f'path = {self.agent}\nprogram = {self.destination}/Contents/MacOS/AccessibilityBroker\nstate = not running\n')
        if args[:2] == ["launchctl", "bootout"]:
            self.registered = False
        if args[:2] == ["launchctl", "bootstrap"]:
            if self.fail_bootstrap:
                raise subprocess.CalledProcessError(1, args)
            self.registered = True
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    def install(self, apply=False):
        argv = ["install-desktop", "--manifest", str(self.manifest)] + (["--apply"] if apply else [])
        with patch.object(installer, "ROOT", self.root), patch.object(installer, "signing_identity", return_value=CERT), \
             patch.object(installer.Path, "home", return_value=self.home), patch.object(installer, "own_main_running", return_value=False), \
             patch.object(installer, "command", side_effect=lambda *args: self.system_call(list(args))), \
             patch.object(installer.subprocess, "run", side_effect=self.system_call), \
             patch.object(artifacts, "command", side_effect=self.signature_command), patch.object(sys, "argv", argv), \
             contextlib.redirect_stdout(io.StringIO()):
            installer.main()

    def uninstall(self, apply=False):
        argv = ["install-desktop", "--uninstall"] + (["--apply"] if apply else [])
        with patch.object(installer, "ROOT", self.root), patch.object(installer, "signing_identity", return_value=CERT), \
             patch.object(installer.Path, "home", return_value=self.home), patch.object(installer, "own_main_running", return_value=False), \
             patch.object(installer, "command", side_effect=lambda *args: self.system_call(list(args))), \
             patch.object(installer.subprocess, "run", side_effect=self.system_call), \
             patch.object(artifacts, "command", side_effect=self.signature_command), patch.object(sys, "argv", argv), \
             contextlib.redirect_stdout(io.StringIO()):
            installer.main()

    def test_dry_run_no_configuration_write(self):
        self.install()
        self.assertFalse(self.home.exists())
        self.assertFalse(any(c[:2] == ["launchctl", "bootstrap"] for c in self.calls))

    def test_first_install_exact_on_demand_configuration(self):
        self.install(True)
        self.assertEqual(plistlib.loads(self.agent.read_bytes()), artifacts.launch_configuration(self.destination))
        self.assertTrue(self.registered)
        self.assertFalse(any(c and c[0] == "tccutil" for c in self.calls))

    def test_component_unchanged_on_main_update(self):
        self.install(True)
        original = artifacts.digest(self.destination / "Contents/MacOS/AccessibilityBroker")
        plist = self.agent.read_bytes()
        main = self.make_app(self.sources / "main2.app", artifacts.MAIN, "different-client")
        manifest = json.loads(self.manifest.read_text())
        manifest["main"] = self.metadata(main, artifacts.MAIN)
        self.manifest.write_text(json.dumps(manifest))
        self.calls = []
        self.install(True)
        self.assertEqual(original, artifacts.digest(self.destination / "Contents/MacOS/AccessibilityBroker"))
        self.assertEqual(plist, self.agent.read_bytes())
        self.assertFalse(any(c[:2] in (["launchctl", "bootout"], ["launchctl", "bootstrap"]) for c in self.calls))
        self.assertTrue(list((self.root / ".build/desktop-installations").glob("*/rollback-manifest.json")))

    def test_component_update_preserves_old_pair_and_plist(self):
        self.install(True)
        old_binary = (self.destination / "Contents/MacOS/AccessibilityBroker").read_bytes()
        plist = self.agent.read_bytes()
        helper = self.make_app(self.sources / "helper2.app", artifacts.COMPONENT, "new-component")
        manifest = json.loads(self.manifest.read_text())
        manifest["component"] = self.metadata(helper, artifacts.COMPONENT)
        self.manifest.write_text(json.dumps(manifest))
        self.install(True)
        self.assertEqual(self.agent.read_bytes(), plist)
        self.assertTrue(any(p.read_bytes() == old_binary for p in (self.root / ".build/desktop-installations").glob("*/PromptBridge Accessibility.app/Contents/MacOS/AccessibilityBroker")))

    def test_uninstall_preserves_exact_pair_and_plist_without_tcc_reset(self):
        self.install(True)
        installed_main = self.home / "Applications/PromptBridge.app"
        original_main = self.tree_contents(installed_main)
        original_helper = self.tree_contents(self.destination)
        original_agent = self.agent.read_bytes()
        self.calls = []
        self.uninstall(True)
        self.assertFalse(installed_main.exists())
        self.assertFalse(self.destination.exists())
        self.assertFalse(self.agent.exists())
        self.assertFalse(self.registered)
        backups = [p.parent for p in (self.root / ".build/desktop-installations").glob("*/result.json")
                   if json.loads(p.read_text())["mode"] == "uninstall"]
        self.assertEqual(len(backups), 1)
        backup = backups[0]
        self.assertEqual(self.tree_contents(backup / "original-PromptBridge.app"), original_main)
        self.assertEqual(self.tree_contents(backup / "original-PromptBridge Accessibility.app"), original_helper)
        self.assertEqual((backup / "removed-launchagent.plist").read_bytes(), original_agent)
        self.assertEqual(self.calls.count(["launchctl", "bootout", f"gui/{self.home.stat().st_uid}", str(self.agent)]), 1)
        self.assertEqual(sum(c[:2] == ["launchctl", "bootout"] for c in self.calls), 1)
        self.assertFalse(any(c and c[0] == "tccutil" for c in self.calls))

        self.manifest = backup / "rollback-manifest.json"
        self.install(True)
        self.assertEqual(self.tree_contents(installed_main), original_main)
        self.assertEqual(self.tree_contents(self.destination), original_helper)
        self.assertEqual(self.agent.read_bytes(), original_agent)
        self.assertTrue(self.registered)

    def test_uninstall_failure_stays_closed_and_compatible_pair_can_recover(self):
        self.install(True)
        installed_main = self.home / "Applications/PromptBridge.app"
        original_main = self.tree_contents(installed_main)
        original_helper = self.tree_contents(self.destination)
        original_agent = self.agent.read_bytes()
        original_copy = installer.shutil.copy2

        def fail_removed_agent_copy(source, destination, *args, **kwargs):
            if ".removed-" in str(source):
                raise OSError("injected backup copy failure")
            return original_copy(source, destination, *args, **kwargs)

        with patch.object(installer.shutil, "copy2", side_effect=fail_removed_agent_copy):
            with self.assertRaises(OSError):
                self.uninstall(True)
        self.assertFalse(self.registered)
        self.assertFalse(self.agent.exists())
        self.assertEqual(self.tree_contents(installed_main), original_main)
        self.assertEqual(self.tree_contents(self.destination), original_helper)
        failures = list((self.root / ".build/desktop-installations").glob("*/failure.json"))
        self.assertEqual(len(failures), 1)
        failure = json.loads(failures[0].read_text())
        self.assertTrue(failure["serviceUnloaded"])
        self.assertEqual(failure["published"], [])
        self.assertTrue(Path(failure["removedAgent"]).exists())
        self.assertEqual(failure["compatibleRollbackManifest"],
                         str(failures[0].parent / "rollback-manifest.json"))
        self.manifest = failures[0].parent / "rollback-manifest.json"
        self.install(True)
        self.assertTrue(self.registered)
        self.assertEqual(self.tree_contents(installed_main), original_main)
        self.assertEqual(self.tree_contents(self.destination), original_helper)
        self.assertEqual(self.agent.read_bytes(), original_agent)

    def test_incompatible_pair_refused(self):
        metadata = self.helper / "Contents/Resources/build-info.json"
        content = json.loads(metadata.read_text()); content["supportedOperations"] = []
        metadata.write_text(json.dumps(content))
        with self.assertRaises(ValueError): self.install(True)
        self.assertFalse(self.home.exists())

    def test_wrong_existing_identity_preserved(self):
        wrong = self.make_app(self.destination, artifacts.COMPONENT)
        info = wrong / "Contents/Info.plist"
        value = plistlib.loads(info.read_bytes()); value["PromptBridgeSignerSHA1"] = "A1" * 20
        info.write_bytes(plistlib.dumps(value))
        before = info.read_bytes()
        with self.assertRaises(ValueError): self.install(True)
        self.assertEqual(before, info.read_bytes())

    def test_symlink_source_refused(self):
        alias = self.sources / "alias.app"; alias.symlink_to(self.helper, target_is_directory=True)
        manifest = json.loads(self.manifest.read_text()); manifest["component"]["path"] = str(alias)
        self.manifest.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError): self.install(True)

    def test_failed_registration_preserves_published_packages(self):
        self.fail_bootstrap = True
        with self.assertRaises(subprocess.CalledProcessError): self.install(True)
        self.assertTrue(self.destination.exists())
        self.assertTrue(self.agent.exists())
        self.assertTrue(list((self.root / ".build/desktop-installations").glob("*/failure.json")))

    def test_signature_failure_does_not_publish(self):
        self.fail_signing = True
        with self.assertRaises(subprocess.CalledProcessError): self.install(True)
        self.assertFalse(self.home.exists())

    def test_job_with_other_program_is_refused(self):
        with self.assertRaises(ValueError):
            installer.validate_job(f"path = {self.agent}\nprogram = /other/bin\n", self.agent, self.destination)

    def test_publish_never_overwrites(self):
        a = self.root / "a"; b = self.root / "b"
        a.write_text("new"); b.write_text("old")
        with self.assertRaises(OSError): artifacts.publish_exclusive(a, b)
        self.assertEqual(b.read_text(), "old")
        self.assertEqual(a.read_text(), "new")

    def test_frozen_package_refused_before_signing(self):
        with self.assertRaises(ValueError): builder.package(self.root / "missing", self.helper, artifacts.COMPONENT, "1.0.0", "1", CERT)

    def test_ad_hoc_requirement_refused(self):
        with self.assertRaises(ValueError): artifacts.requirement(artifacts.MAIN, "-")

    def test_arbitrary_bundle_refused(self):
        with self.assertRaises(ValueError): artifacts.requirement("fixture.other", CERT)

    def test_builder_can_use_own_explicit_certificate(self):
        self.assertIn(("A1" * 20).lower(), artifacts.requirement(artifacts.MAIN, "A1" * 20))

    def test_signed_digest_is_separate_from_source_provenance(self):
        binary = self.main / "Contents/MacOS/PromptBridge"
        original = artifacts.digest(binary)
        binary.write_text(binary.read_text() + " simulated Mach-O signature bytes")
        result = self.metadata(self.main, artifacts.MAIN)
        self.assertEqual(result["sourceBinarySHA256"], original)
        self.assertEqual(result["executableSHA256"], artifacts.digest(binary))
        self.assertNotEqual(result["sourceBinarySHA256"], result["executableSHA256"])

    def test_duplicate_operations_refused(self):
        metadata = self.helper / "Contents/Resources/build-info.json"
        content = json.loads(metadata.read_text()); content["supportedOperations"] += ["capture"]
        metadata.write_text(json.dumps(content))
        with self.assertRaises(ValueError): self.install(True)

    def test_boolean_protocol_version_refused(self):
        metadata = self.helper / "Contents/Resources/build-info.json"
        content = json.loads(metadata.read_text()); content["protocolVersion"] = True
        metadata.write_text(json.dumps(content))
        with self.assertRaises(ValueError): self.install(True)

    def test_compatible_rollback_uses_preserved_pair(self):
        self.install(True)
        original = artifacts.digest(self.home / "Applications/PromptBridge.app/Contents/MacOS/PromptBridge")
        main = self.make_app(self.sources / "updated.app", artifacts.MAIN, "updated-client")
        manifest = json.loads(self.manifest.read_text()); manifest["main"] = self.metadata(main, artifacts.MAIN)
        self.manifest.write_text(json.dumps(manifest))
        self.install(True)
        rollbacks = list((self.root / ".build/desktop-installations").glob("*/rollback-manifest.json"))
        self.assertEqual(len(rollbacks), 1)
        self.manifest = rollbacks[0]
        self.install(True)
        self.assertEqual(original, artifacts.digest(self.home / "Applications/PromptBridge.app/Contents/MacOS/PromptBridge"))

    def test_main_only_builder_never_rebuilds_or_signs_component(self):
        main_output = self.root / "dist/candidates/PromptBridge-0.5.5-build14.app"
        component = self.make_app(self.sources / "v2-component.app", artifacts.COMPONENT, protocol=artifacts.IPC_PROTOCOL)
        verified = self.metadata(component, artifacts.COMPONENT)
        packaged_main = dict(path=str(main_output), bundle=artifacts.MAIN, protocolVersion=artifacts.IPC_PROTOCOL)
        argv = ["build-desktop", "--certificate", CERT, "--main-only", "--component", str(component)]
        with patch.object(builder, "ROOT", self.root), patch.object(builder, "signing_identity", return_value=CERT), \
             patch.object(builder, "verify_app", return_value=verified), patch.object(builder, "build", return_value=self.main) as build_call, \
             patch.object(builder, "package", return_value=packaged_main) as package_call, \
             patch.object(builder, "publish_current") as current_call, patch.object(sys, "argv", argv), \
             contextlib.redirect_stdout(io.StringIO()):
            (self.root / "dist/candidates").mkdir(parents=True)
            builder.main()
        self.assertEqual([call.args[0] for call in build_call.call_args_list], ["PromptBridge", "promptbridge-editor"])
        self.assertEqual(package_call.call_count, 1)
        self.assertEqual(package_call.call_args.args[2], artifacts.MAIN)
        self.assertEqual(package_call.call_args.kwargs["editor"], self.main)
        current_call.assert_called_once_with(self.root / "dist/candidates/desktop-0.9.0-build47.json", CERT)

    def select_current(self, installed=False):
        argv = ["select-current", "--manifest", str(self.manifest)] + (["--installed"] if installed else [])
        with patch.object(artifacts, "ROOT", self.root), patch.object(artifacts, "command", side_effect=self.signature_command), \
             patch.object(artifacts.Path, "home", return_value=self.home), \
             patch.object(selector, "signing_identity", return_value=CERT), patch.object(sys, "argv", argv), \
             contextlib.redirect_stdout(io.StringIO()):
            selector.main()
        return self.root / "dist/current"

    def test_installed_current_entry_uses_fixed_applications_pair_and_editor(self):
        main = self.make_app(self.sources / "v2-main.app", artifacts.MAIN,
                             protocol=2, cli_test_hosts=LEGACY_CLI_TEST_HOSTS)
        helper = self.make_app(self.sources / "v2-helper.app", artifacts.COMPONENT,
                               protocol=2, cli_test_hosts=LEGACY_CLI_TEST_HOSTS)
        self.manifest.write_text(json.dumps(dict(main=self.metadata(main, artifacts.MAIN),
            component=self.metadata(helper, artifacts.COMPONENT), protocolVersion=2,
            certificateSHA1=CERT, acceptance="candidate_not_accepted")))
        frozen_manifest = self.manifest.read_bytes()
        installed_main = self.home / "Applications/PromptBridge.app"
        shutil.copytree(main, installed_main)
        shutil.copytree(helper, self.destination)
        current = self.select_current(installed=True)
        self.assertEqual((current / "PromptBridge.app").resolve(), installed_main)
        self.assertEqual((current / "PromptBridge Accessibility.app").resolve(), self.destination)
        self.assertEqual((current / "promptbridge-editor").resolve(), installed_main / "Contents/MacOS/promptbridge-editor")
        self.assertEqual((current / "release.json").resolve(), self.manifest)
        self.assertEqual(self.manifest.read_bytes(), frozen_manifest)
        notes = (current / "README.txt").read_text()
        self.assertIn(str(installed_main), notes)
        self.assertIn("候选（尚未全部验收）", notes)
        self.assertIn("CLI 用户测试范围：", notes)
        self.assertIn("历史归档，无需逐个挑选", notes)

    def test_installed_pair_mismatch_keeps_all_existing_current_contents(self):
        current = self.select_current()
        before = {p.name: p.readlink() if p.is_symlink() else p.read_bytes() for p in current.iterdir()}
        installed_main = self.home / "Applications/PromptBridge.app"
        shutil.copytree(self.main, installed_main)
        shutil.copytree(self.helper, self.destination)
        for executable in (installed_main / "Contents/MacOS/PromptBridge",
                           self.destination / "Contents/MacOS/AccessibilityBroker"):
            with self.subTest(executable=executable.name):
                original = executable.read_bytes()
                executable.write_bytes(original + b" mismatch")
                with self.assertRaisesRegex(ValueError, "does not match"):
                    self.select_current(installed=True)
                self.assertEqual(before, {p.name: p.readlink() if p.is_symlink() else p.read_bytes() for p in current.iterdir()})
                self.assertFalse(list((self.root / "dist").glob(".current-*")))
                executable.write_bytes(original)

    def test_current_entry_reuses_signed_artifacts_and_original_manifest(self):
        original = self.tree_contents(self.main)
        editor = self.main / "Contents/MacOS/promptbridge-editor"
        editor.write_text("fixture editor")
        current = self.select_current()
        self.assertEqual((current / "PromptBridge.app").resolve(), self.main)
        self.assertEqual((current / "PromptBridge Accessibility.app").resolve(), self.helper)
        self.assertEqual((current / "release.json").resolve(), self.manifest)
        self.assertEqual((current / "promptbridge-editor").resolve(), editor)
        self.assertEqual(self.tree_contents(self.main), dict(original, **{"Contents/MacOS/promptbridge-editor": ("file", b"fixture editor")}))
        self.assertFalse(any(call[:2] == ["codesign", "--force"] for call in self.calls))

    def test_current_entry_updates_and_old_versions_remain_available(self):
        current = self.select_current()
        updated = self.make_app(self.sources / "new-main.app", artifacts.MAIN, "updated")
        release = json.loads(self.manifest.read_text())
        release["main"] = self.metadata(updated, artifacts.MAIN)
        next_manifest = self.root / "next.json"
        next_manifest.write_text(json.dumps(release))
        self.manifest = next_manifest
        self.select_current()
        self.assertEqual((current / "PromptBridge.app").resolve(), updated)
        self.assertEqual((current / "release.json").resolve(), next_manifest)
        self.assertTrue(self.main.exists())
        self.assertFalse(list((self.root / "dist").glob(".current-*")))

    def test_bad_manifest_keeps_existing_current_entry(self):
        current = self.select_current()
        before = (current / "PromptBridge.app").readlink()
        release = json.loads(self.manifest.read_text())
        release["main"]["CDHash"] = "0" * 40
        self.manifest.write_text(json.dumps(release))
        with self.assertRaises(ValueError):
            self.select_current()
        self.assertEqual((current / "PromptBridge.app").readlink(), before)

    def test_current_entry_preserves_unmanaged_files(self):
        current = self.root / "dist/current"
        current.mkdir(parents=True)
        existing = current / "PromptBridge.app"
        existing.mkdir()
        marker = existing / "user.txt"
        marker.write_text("keep")
        with self.assertRaises(ValueError):
            self.select_current()
        self.assertEqual(marker.read_text(), "keep")

    def test_current_entry_removes_editor_link_when_selected_main_has_no_editor(self):
        editor = self.main / "Contents/MacOS/promptbridge-editor"
        editor.write_text("fixture editor")
        current = self.select_current()
        editor.unlink()
        self.select_current()
        self.assertFalse((current / "promptbridge-editor").is_symlink())

    def test_cli_editor_is_signed_before_bundle_and_declares_document_protocol(self):
        binary = self.main / "Contents/MacOS/PromptBridge"
        editor = self.root / "promptbridge-editor"
        editor.write_text("fixture editor")
        output = self.sources / "cli.app"

        def command(*args):
            if Path(args[-1]).is_file():
                self.calls.append(list(args))
                return SimpleNamespace(stdout="", stderr="")
            return self.signature_command(*args)

        with patch.object(builder, "command", side_effect=command), \
             patch.object(artifacts, "command", side_effect=self.signature_command):
            builder.package(binary, output, artifacts.MAIN, "0.5.11", "20", CERT, editor=editor)
        info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["PromptBridgeCLIEditorProtocol"], 2)
        self.assertEqual(info["CFBundleIconFile"], "AppIcon.icns")
        for name in artifacts.APP_RESOURCE_FILES:
            self.assertEqual((output / "Contents/Resources" / name).read_bytes(),
                             (binary.parent / "PromptBridge_PromptBridge.bundle" / name).read_bytes())
        self.assertEqual(info["PromptBridgeIPCProtocol"], artifacts.IPC_PROTOCOL)
        self.assertEqual(info["PromptBridgeCLIValidatedHosts"], [])
        self.assertEqual(info["PromptBridgeCLITestHosts"], [])
        self.assertNotIn("cliTestHosts", self.metadata(output, artifacts.MAIN))
        self.assertEqual(info["UTExportedTypeDeclarations"][0]["UTTypeTagSpecification"]["public.filename-extension"], ["promptbridge-edit"])
        self.assertEqual((output / "Contents/MacOS/promptbridge-editor").read_bytes(), editor.read_bytes())
        signing = [call for call in self.calls if call[:2] == ["codesign", "--force"]]
        self.assertEqual(len(signing), 2)
        self.assertEqual(Path(signing[0][-1]).name, "promptbridge-editor")
        self.assertEqual(Path(signing[1][-1]).name, "cli.app")

    def test_v2_component_declares_terminal_automation_without_live_acceptance(self):
        binary = self.helper / "Contents/MacOS/AccessibilityBroker"
        output = self.sources / "v2-component.app"
        with patch.object(builder, "command", side_effect=self.signature_command), \
             patch.object(artifacts, "command", side_effect=self.signature_command):
            result = builder.package(binary, output, artifacts.COMPONENT, "2.0.0", "2", CERT)
        info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["PromptBridgeIPCProtocol"], artifacts.IPC_PROTOCOL)
        self.assertEqual(info["PromptBridgeCLIValidatedHosts"], [])
        self.assertEqual(info["PromptBridgeCLITestHosts"], [])
        self.assertNotIn("cliTestHosts", result)
        self.assertTrue(info["NSAppleEventsUsageDescription"])
        self.assertEqual(result["supportedOperations"], artifacts.OPERATIONS)
        self.assertTrue({"cliQueryTarget", "cliTriggerEditor", "cliReturnTarget"}.issubset(result["supportedOperations"]))

    def test_no_publish_current_keeps_existing_entry(self):
        current = self.select_current()
        before = {path.name: path.readlink() if path.is_symlink() else path.read_bytes() for path in current.iterdir()}
        component = self.make_app(self.sources / "v2-component.app", artifacts.COMPONENT, protocol=artifacts.IPC_PROTOCOL)
        verified = self.metadata(component, artifacts.COMPONENT)
        packaged = dict(path=str(self.sources / "new-main.app"), bundle=artifacts.MAIN, protocolVersion=artifacts.IPC_PROTOCOL)
        argv = ["build-desktop", "--certificate", CERT, "--main-only", "--component", str(component), "--no-publish-current"]
        with patch.object(builder, "ROOT", self.root), patch.object(builder, "signing_identity", return_value=CERT), \
             patch.object(builder, "verify_app", return_value=verified), patch.object(builder, "build", return_value=self.main), \
             patch.object(builder, "package", return_value=packaged), patch.object(builder, "publish_current") as publish, \
             patch.object(sys, "argv", argv), contextlib.redirect_stdout(io.StringIO()):
            (self.root / "dist/candidates").mkdir(parents=True)
            builder.main()
        publish.assert_not_called()
        self.assertEqual(before, {path.name: path.readlink() if path.is_symlink() else path.read_bytes() for path in current.iterdir()})
        release = json.loads((self.root / "dist/candidates/desktop-0.9.0-build47.json").read_text())
        self.assertEqual(release["protocolVersion"], artifacts.IPC_PROTOCOL)
        self.assertEqual(release["acceptance"], "candidate_not_accepted")

    def test_builder_refuses_v1_component_before_build_or_sign(self):
        verified = self.metadata(self.helper, artifacts.COMPONENT)
        argv = ["build-desktop", "--certificate", CERT, "--main-only", "--component", str(self.helper), "--no-publish-current"]
        with patch.object(builder, "ROOT", self.root), patch.object(builder, "signing_identity", return_value=CERT), \
             patch.object(builder, "verify_app", return_value=verified), patch.object(builder, "build") as build, \
             patch.object(builder, "package") as package, patch.object(sys, "argv", argv):
            with self.assertRaises(ValueError):
                builder.main()
        build.assert_not_called()
        package.assert_not_called()

    def test_mixed_pair_refused_by_install_and_current(self):
        current = self.select_current()
        prior = (current / "PromptBridge.app").readlink()
        v2 = self.make_app(self.sources / "v2-main.app", artifacts.MAIN, "v2 client", protocol=2)
        release = json.loads(self.manifest.read_text())
        release.update(main=self.metadata(v2, artifacts.MAIN), protocolVersion=2)
        self.manifest.write_text(json.dumps(release))
        with self.assertRaises(ValueError): self.install(True)
        self.assertFalse(self.home.exists())
        with self.assertRaises(ValueError): self.select_current()
        self.assertEqual((current / "PromptBridge.app").readlink(), prior)

    def test_v2_upgrade_retains_complete_v1_rollback(self):
        self.install(True)
        installed_main = self.home / "Applications/PromptBridge.app"
        old_main = self.tree_contents(installed_main)
        old_helper = self.tree_contents(self.destination)
        main = self.make_app(self.sources / "v2-main.app", artifacts.MAIN, "v2 client", protocol=2)
        helper = self.make_app(self.sources / "v2-component.app", artifacts.COMPONENT, "v2 component", protocol=2)
        self.manifest.write_text(json.dumps(dict(main=self.metadata(main, artifacts.MAIN),
            component=self.metadata(helper, artifacts.COMPONENT), protocolVersion=2, certificateSHA1=CERT)))
        self.install(True)
        self.assertEqual(self.metadata(installed_main, artifacts.MAIN)["protocolVersion"], 2)
        rollbacks = list((self.root / ".build/desktop-installations").glob("*/rollback-manifest.json"))
        self.assertEqual(len(rollbacks), 1)
        rollback = json.loads(rollbacks[0].read_text())
        self.assertEqual(rollback["protocolVersion"], 1)
        self.assertEqual(rollback["main"]["protocolVersion"], 1)
        self.assertEqual(rollback["component"]["protocolVersion"], 1)
        self.manifest = rollbacks[0]
        self.install(True)
        self.assertEqual(self.tree_contents(installed_main), old_main)
        self.assertEqual(self.tree_contents(self.destination), old_helper)

    def test_v2_info_and_editor_protocol_must_match_metadata(self):
        main = self.make_app(self.sources / "v2-main.app", artifacts.MAIN, protocol=2)
        info_path = main / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["PromptBridgeIPCProtocol"] = 1
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError): self.metadata(main, artifacts.MAIN)
        info["PromptBridgeIPCProtocol"] = 2
        info["PromptBridgeCLIEditorProtocol"] = 1
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError): self.metadata(main, artifacts.MAIN)

    def test_v2_missing_automation_declaration_is_refused(self):
        component = self.make_app(self.sources / "v2-component.app", artifacts.COMPONENT, protocol=2)
        info_path = component / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        del info["NSAppleEventsUsageDescription"]
        info_path.write_bytes(plistlib.dumps(info))
        with self.assertRaises(ValueError): self.metadata(component, artifacts.COMPONENT)

    def test_cli_testing_packages_declare_pinned_hosts_without_acceptance(self):
        editor = self.root / "promptbridge-editor"
        editor.write_text("fixture editor")

        def command(*args):
            if Path(args[-1]).is_file():
                return SimpleNamespace(stdout="", stderr="")
            return self.signature_command(*args)

        pair = []
        for bundle, source in ((artifacts.MAIN, self.main), (artifacts.COMPONENT, self.helper)):
            with self.subTest(bundle=bundle):
                executable = "PromptBridge" if bundle == artifacts.MAIN else "AccessibilityBroker"
                output = self.sources / f"{executable}-testing.app"
                with patch.object(builder, "command", side_effect=command), \
                     patch.object(artifacts, "command", side_effect=self.signature_command):
                    result = builder.package(source / "Contents/MacOS" / executable, output, bundle,
                        "2.0.0", "2", CERT, editor=editor if bundle == artifacts.MAIN else None,
                        cli_test_hosts=LEGACY_CLI_TEST_HOSTS)
                info = plistlib.loads((output / "Contents/Info.plist").read_bytes())
                metadata = json.loads((output / "Contents/Resources/build-info.json").read_text())
                self.assertEqual(info["PromptBridgeCLITestHosts"], ["claude:2.1.283", "codex:0.157.1"])
                self.assertEqual(info["PromptBridgeCLIValidatedHosts"], [])
                self.assertEqual(metadata["cliTestHosts"], info["PromptBridgeCLITestHosts"])
                self.assertEqual(result["cliTestHosts"], info["PromptBridgeCLITestHosts"])
                pair.append(result)
        self.assertEqual(artifacts.pair_protocol(*pair), artifacts.IPC_PROTOCOL)
        self.assertEqual(artifacts.pair_protocol(pair[0], dict(pair[1], cliTestHosts=list(reversed(LEGACY_CLI_TEST_HOSTS)))), artifacts.IPC_PROTOCOL)

    def test_cli_test_host_declarations_are_strict_and_match_signed_metadata(self):
        component = self.make_app(self.sources / "testing-component.app", artifacts.COMPONENT,
                                  protocol=2, cli_test_hosts=LEGACY_CLI_TEST_HOSTS)
        info_path = component / "Contents/Info.plist"
        metadata_path = component / "Contents/Resources/build-info.json"
        original_info = plistlib.loads(info_path.read_bytes())
        original_metadata = json.loads(metadata_path.read_text())
        for location, key in (("info", "PromptBridgeCLITestHosts"), ("metadata", "cliTestHosts")):
            for value in ("codex:0.157.1", {}, [True], [1], ["codex:0.157.1", "codex:0.157.1"], []):
                with self.subTest(location=location, value=value):
                    info, metadata = dict(original_info), dict(original_metadata)
                    (info if location == "info" else metadata)[key] = value
                    info_path.write_bytes(plistlib.dumps(info))
                    metadata_path.write_text(json.dumps(metadata))
                    with self.assertRaises(ValueError): self.metadata(component, artifacts.COMPONENT)
        info_path.write_bytes(plistlib.dumps(original_info))
        metadata = dict(original_metadata, cliTestHosts=None)
        metadata_path.write_text(json.dumps(metadata))
        with self.assertRaises(ValueError): self.metadata(component, artifacts.COMPONENT)

    def test_cli_testing_flag_requires_no_publish_before_any_build(self):
        argv = ["build-desktop", "--certificate", CERT, "--cli-user-testing"]
        with patch.object(builder, "signing_identity") as identity, patch.object(builder, "build") as build, \
             patch.object(builder, "publish_current") as publish, patch.object(sys, "argv", argv), \
             contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit): builder.main()
        identity.assert_not_called()
        build.assert_not_called()
        publish.assert_not_called()

    def test_ordinary_builder_has_no_runtime_host_declarations(self):
        argv = ["build-desktop", "--certificate", CERT, "--no-publish-current"]
        def package(binary, output, bundle, *args, **kwargs):
            self.assertNotIn("cli_test_hosts", kwargs)
            return dict(path=str(output), bundle=bundle, protocolVersion=artifacts.IPC_PROTOCOL)
        with patch.object(builder, "ROOT", self.root), patch.object(builder, "signing_identity", return_value=CERT), \
             patch.object(builder, "build", return_value=self.main), patch.object(builder, "package", side_effect=package) as packaged, \
             patch.object(builder, "publish_current") as publish, patch.object(sys, "argv", argv), \
             contextlib.redirect_stdout(io.StringIO()):
            (self.root / "dist/candidates").mkdir(parents=True)
            builder.main()
        self.assertEqual(packaged.call_count, 2)
        publish.assert_not_called()
        release = json.loads((self.root / "dist/candidates/desktop-0.9.0-build47.json").read_text())
        self.assertEqual(release["acceptance"], "candidate_not_accepted")

    def test_builder_reuse_ignores_legacy_host_metadata(self):
        for mode, source_argument in (("--main-only", "--component"), ("--component-only", "--main")):
            with self.subTest(mode=mode):
                root = self.root / mode
                (root / "dist/candidates").mkdir(parents=True)
                reused = dict(protocolVersion=artifacts.IPC_PROTOCOL, cliTestHosts=LEGACY_CLI_TEST_HOSTS)
                packaged = dict(protocolVersion=artifacts.IPC_PROTOCOL)
                argv = ["build-desktop", "--certificate", CERT, mode, source_argument, str(self.helper), "--no-publish-current"]
                with patch.object(builder, "ROOT", root), patch.object(builder, "signing_identity", return_value=CERT), \
                     patch.object(builder, "verify_app", return_value=reused), patch.object(builder, "build", return_value=self.main), \
                     patch.object(builder, "package", return_value=packaged) as package, patch.object(sys, "argv", argv), \
                     contextlib.redirect_stdout(io.StringIO()):
                    builder.main()
                self.assertEqual(package.call_count, 1)
                self.assertNotIn("cli_test_hosts", package.call_args.kwargs)

    def test_legacy_host_metadata_does_not_block_install_or_current(self):
        main = self.make_app(self.sources / "testing-main.app", artifacts.MAIN,
                             protocol=2, cli_test_hosts=LEGACY_CLI_TEST_HOSTS)
        helper = self.make_app(self.sources / "old-v2-helper.app", artifacts.COMPONENT, protocol=2)
        self.manifest.write_text(json.dumps(dict(main=self.metadata(main, artifacts.MAIN),
            component=self.metadata(helper, artifacts.COMPONENT), protocolVersion=2, certificateSHA1=CERT)))
        self.install(True)
        self.select_current()
        self.assertTrue(self.home.exists())
        self.assertTrue((self.root / "dist/current/PromptBridge.app").is_symlink())

    def test_cli_testing_upgrade_retains_complete_old_v2_rollback(self):
        main = self.make_app(self.sources / "old-v2-main.app", artifacts.MAIN, protocol=2)
        helper = self.make_app(self.sources / "old-v2-helper.app", artifacts.COMPONENT, protocol=2)
        self.manifest.write_text(json.dumps(dict(main=self.metadata(main, artifacts.MAIN),
            component=self.metadata(helper, artifacts.COMPONENT), protocolVersion=2, certificateSHA1=CERT)))
        self.install(True)
        old_main, old_helper = self.tree_contents(main), self.tree_contents(helper)
        main = self.make_app(self.sources / "testing-main.app", artifacts.MAIN,
                             protocol=2, cli_test_hosts=LEGACY_CLI_TEST_HOSTS)
        helper = self.make_app(self.sources / "testing-helper.app", artifacts.COMPONENT,
                               protocol=2, cli_test_hosts=LEGACY_CLI_TEST_HOSTS)
        self.manifest.write_text(json.dumps(dict(main=self.metadata(main, artifacts.MAIN),
            component=self.metadata(helper, artifacts.COMPONENT), protocolVersion=2, certificateSHA1=CERT)))
        self.install(True)
        rollbacks = list((self.root / ".build/desktop-installations").glob("*/rollback-manifest.json"))
        self.assertEqual(len(rollbacks), 1)
        rollback = json.loads(rollbacks[0].read_text())
        self.assertNotIn("cliTestHosts", rollback["main"])
        self.assertNotIn("cliTestHosts", rollback["component"])
        self.manifest = rollbacks[0]
        self.install(True)
        self.assertEqual(self.tree_contents(self.home / "Applications/PromptBridge.app"), old_main)
        self.assertEqual(self.tree_contents(self.destination), old_helper)


if __name__ == "__main__":
    unittest.main()
