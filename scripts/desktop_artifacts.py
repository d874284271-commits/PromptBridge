"""Explicit certificate signing and immutable desktop artifacts. No model access."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MAIN = "local.promptbridge.prototype"
COMPONENT = "local.promptbridge.accessibility"
LABEL = COMPONENT
IPC_PROTOCOL = 3
CLI_EDITOR_PROTOCOL = 2
APP_RESOURCE_FILES = ("AppIcon.png", "MenuBarTemplate.png", "AppIcon.icns")
OPERATIONS_V1 = ["capture", "validate", "replace", "restore", "returnFocus", "acquireScope",
                 "releaseScope", "subscribe", "cancel", "invalidate", "probeCodex", "probeInputSupport"]
OPERATIONS = OPERATIONS_V1 + ["cliQueryTarget", "cliTriggerEditor", "cliReturnTarget"]
OPERATIONS_BY_PROTOCOL = {1: OPERATIONS_V1, 2: OPERATIONS, 3: OPERATIONS}


def signing_identity(fingerprint=None):
    if fingerprint is None:
        identity = json.loads((ROOT / "config/accessibility-signing.json").read_text())
        if identity.get("mainBundle") != MAIN or identity.get("componentBundle") != COMPONENT:
            raise ValueError("Unexpected application bundle identity")
        fingerprint = identity.get("certificateSHA1", "")
    if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-fA-F]{40}", fingerprint):
        raise ValueError("Supply the exact SHA-1 of your code-signing certificate; ad-hoc signing is not supported")
    return fingerprint.upper()


def requirement(bundle, fingerprint):
    if bundle not in (MAIN, COMPONENT):
        raise ValueError("Invalid signing requirement")
    fingerprint = signing_identity(fingerprint)
    return f'identifier "{bundle}" and certificate leaf = H"{fingerprint.lower()}"'


def command(*args):
    result = subprocess.run(args, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed ({result.returncode}):\n{result.stdout}\n{result.stderr}")
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def copy_app_resources(binary_directory, destination):
    """Include SwiftPM artwork in the app so it runs without its build directory."""
    source = Path(binary_directory) / "PromptBridge_PromptBridge.bundle"
    destination.mkdir(parents=True, exist_ok=True)
    for name in APP_RESOURCE_FILES:
        shutil.copy2(source / name, destination / name)


def publish_exclusive(source, destination):
    """Atomic same-filesystem publication. Never replaces a user-owned path."""
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 4) != 0:  # RENAME_EXCL
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), str(destination))


def validate_cli_test_hosts(hosts):
    # Legacy signed metadata remains readable; it no longer defines runtime admission.
    if type(hosts) is not list or not all(type(host) is str and bool(host) for host in hosts) or len(set(hosts)) != len(hosts):
        raise ValueError("Invalid CLI user-testing host declaration")
    return hosts


def verify_app(path, bundle, fingerprint, production=True):
    path = Path(path)
    if path.is_symlink() or not path.is_dir() or any(p.is_symlink() for p in path.rglob("*")):
        raise ValueError("Application must be an intact bundle without symlinks")
    info = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    executable = "PromptBridge" if bundle == MAIN else "AccessibilityBroker"
    if info.get("CFBundleIdentifier") != bundle or info.get("CFBundleExecutable") != executable or info.get("PromptBridgeSignerSHA1") != fingerprint:
        raise ValueError("Unexpected application identity")
    expected = requirement(bundle, fingerprint)
    command("codesign", "--verify", "--deep", "--strict", "-R=" + expected, str(path))
    details = command("codesign", "-d", "-r-", "--verbose=4", str(path))
    output = details.stdout + details.stderr
    match = re.search(r"^designated => (.+)$", output, re.MULTILINE)
    cdhash = re.search(r"^CDHash=([a-fA-F0-9]{40})$", output, re.MULTILINE)
    if not match or match.group(1).strip().lower() != expected.lower() or not cdhash:
        raise ValueError("Designated requirement or CDHash does not match fixed identity")
    metadata = json.loads((path / "Contents/Resources/build-info.json").read_text())
    test_hosts = validate_cli_test_hosts(info.get("PromptBridgeCLITestHosts", []))
    metadata_test_hosts = validate_cli_test_hosts(metadata.get("cliTestHosts", []))
    if set(test_hosts) != set(metadata_test_hosts):
        raise ValueError("CLI user-testing hosts differ between Info.plist and signed metadata")
    protocol = metadata.get("protocolVersion")
    if production:
        operations = metadata.get("supportedOperations")
        expected_operations = OPERATIONS_BY_PROTOCOL.get(protocol) if type(protocol) is int else None
        if expected_operations is None or type(info.get("PromptBridgeIPCProtocol")) is not int or info["PromptBridgeIPCProtocol"] != protocol or not isinstance(operations, list) or not all(isinstance(value, str) for value in operations) or len(operations) != len(expected_operations) or set(operations) != set(expected_operations):
            raise ValueError("Incompatible production IPC contract")
        if protocol >= 2:
            validated_hosts = info.get("PromptBridgeCLIValidatedHosts")
            if not isinstance(validated_hosts, list) or not all(isinstance(host, str) for host in validated_hosts):
                raise ValueError("Missing CLI validation declaration")
            if bundle == COMPONENT and (not isinstance(info.get("NSAppleEventsUsageDescription"), str) or not info["NSAppleEventsUsageDescription"].strip()):
                raise ValueError("Terminal Automation purpose must belong to the component")
            if bundle == MAIN:
                if type(info.get("PromptBridgeCLIEditorProtocol")) is not int or info["PromptBridgeCLIEditorProtocol"] != CLI_EDITOR_PROTOCOL or type(metadata.get("cliEditorProtocol")) is not int or metadata["cliEditorProtocol"] != CLI_EDITOR_PROTOCOL:
                    raise ValueError("Incompatible CLI editor protocol")
                editor_digest = metadata.get("cliEditorSourceSHA256")
                if not (path / "Contents/MacOS/promptbridge-editor").is_file() or not isinstance(editor_digest, str) or not re.fullmatch(r"[a-f0-9]{64}", editor_digest):
                    raise ValueError("Missing CLI editor or its source provenance")
    # codesign changes the Mach-O signature. The sealed source digest describes
    # the pre-signing build input, not the signed executable. Strict code-signing
    # verification above establishes bundle integrity; release manifests record
    # the actual signed executable digest separately, without editing the seal.
    source_digest = metadata.get("sourceBinarySHA256")
    if not isinstance(source_digest, str) or not re.fullmatch(r"[a-f0-9]{64}", source_digest):
        raise ValueError("Invalid source binary provenance digest")
    for key, value in (("version", info.get("CFBundleShortVersionString")), ("build", info.get("CFBundleVersion")), ("certificateSHA1", fingerprint)):
        if metadata.get(key) != value:
            raise ValueError("Signed package metadata differs from Info.plist")
    result = dict(path=str(path.resolve()), bundle=bundle, version=info["CFBundleShortVersionString"],
                build=info["CFBundleVersion"], protocolVersion=protocol,
                certificateSHA1=fingerprint, codeRequirement=expected, CDHash=cdhash.group(1).lower(),
                executableSHA256=digest(path / "Contents/MacOS" / executable),
                sourceBinarySHA256=source_digest, supportedOperations=metadata.get("supportedOperations", []))
    if test_hosts:
        result["cliTestHosts"] = sorted(test_hosts)
    return result


def pair_protocol(main, component):
    """Frozen pairs remain valid rollback targets; match the actual IPC protocol."""
    protocol = main.get("protocolVersion")
    if type(protocol) is not int or protocol not in OPERATIONS_BY_PROTOCOL or type(component.get("protocolVersion")) is not int or component["protocolVersion"] != protocol:
        raise ValueError("Main and component must use the same supported IPC protocol")
    return protocol


def launch_configuration(destination):
    return dict(Label=LABEL, ProgramArguments=[str(destination / "Contents/MacOS/AccessibilityBroker")],
                MachServices={LABEL + ".xpc": True}, RunAtLoad=False, KeepAlive=False,
                LimitLoadToSessionType="Aqua", ProcessType="Interactive")


def publish_current(manifest, fingerprint, installed=False):
    manifest = Path(manifest).resolve(strict=True)
    if not manifest.is_relative_to(ROOT.resolve()):
        raise ValueError("Current release manifest must be inside the workspace")
    release = json.loads(manifest.read_text())
    if release.get("certificateSHA1") != fingerprint or type(release.get("protocolVersion")) is not int or release["protocolVersion"] not in OPERATIONS_BY_PROTOCOL:
        raise ValueError("Incompatible current release manifest")
    sources = {}
    for key, bundle in (("main", MAIN), ("component", COMPONENT)):
        item = release.get(key)
        if not isinstance(item, dict):
            raise ValueError("Current output requires a complete main/component pair")
        if installed:
            name = "PromptBridge.app" if key == "main" else "PromptBridge Accessibility.app"
            source = Path.home() / "Applications" / name
            verified = verify_app(source, bundle, fingerprint)
            matches = {k: v for k, v in verified.items() if k != "path"} == {k: v for k, v in item.items() if k != "path"}
        else:
            source = Path(item["path"])
            if not source.resolve(strict=True).is_relative_to(ROOT.resolve()):
                raise ValueError("Current artifact must be inside the workspace")
            matches = verify_app(source, bundle, fingerprint) == item
        if not matches:
            raise ValueError("Current release manifest does not match its artifact")
        sources[key] = source
    if pair_protocol(release["main"], release["component"]) != release["protocolVersion"]:
        raise ValueError("Current release protocol differs from its pair")
    current = ROOT / "dist/current"
    if current.is_symlink():
        raise ValueError("Current output directory must not be a symlink")
    names = ["PromptBridge.app", "PromptBridge Accessibility.app", "promptbridge-editor", "release.json"]
    for name in names:
        destination = current / name
        if destination.exists() and not destination.is_symlink():
            raise ValueError(f"Refusing to replace an unmanaged current output: {destination}")
    notes = current / "README.txt"
    if notes.is_symlink() or (notes.exists() and not notes.is_file()):
        raise ValueError("Current output notes must be a regular file")
    current.mkdir(parents=True, exist_ok=True)
    targets = {"PromptBridge.app": sources["main"], "PromptBridge Accessibility.app": sources["component"],
               "release.json": manifest}
    editor = sources["main"] / "Contents/MacOS/promptbridge-editor"
    if editor.is_file():
        targets["promptbridge-editor"] = editor
    stage = Path(tempfile.mkdtemp(prefix=".current-", dir=current.parent))
    try:
        for name, target in targets.items():
            (stage / name).symlink_to(os.path.relpath(target, current))
        main = release["main"]
        component = release["component"]
        acceptance = release.get("acceptance")
        status = "候选（尚未全部验收）" if acceptance == "candidate_not_accepted" else str(acceptance or "未记录")
        cli_note = ("CLI 接入请使用已安装应用的设置，稳定助手路径由应用管理。\n" if release["protocolVersion"] >= 2
                    else "CLI 配置指向本目录的 promptbridge-editor。\n")
        entry_note = (f"日常使用固定已安装入口：{sources['main']}\n"
                      "本目录的应用和 CLI 助手均指向 ~/Applications 中的已安装版本。\n" if installed
                      else "打开 PromptBridge.app 使用。\n")
        test_hosts = release["main"].get("cliTestHosts", [])
        testing_note = f"CLI 用户测试范围：{', '.join(test_hosts)}（不代表已通过验收）。\n" if test_hosts else ""
        (stage / "README.txt").write_text(
            f"PromptBridge 当前统一入口\n\n主应用：{main['version']} / build {main['build']}\n"
            f"辅助功能组件：{component['version']} / build {component['build']}\n"
            f"验收状态：{status}\n\n" +
            entry_note + testing_note + cli_note +
            "旧版本保留在 dist/candidates 作为历史归档，无需逐个挑选。\n"
            "本目录更新入口，不修改已签名应用、不执行安装。\n", encoding="utf-8")
        for name in targets:
            os.replace(stage / name, current / name)
        if "promptbridge-editor" not in targets and (current / "promptbridge-editor").is_symlink():
            (current / "promptbridge-editor").unlink()
        os.replace(stage / "README.txt", notes)
    finally:
        shutil.rmtree(stage)
    return current
