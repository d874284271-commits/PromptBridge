#!/usr/bin/env python3
"""Install/update/rollback reviewed desktop pairs. Dry-run by default; no TCC mutation.

Requires the main application and the on-demand component to have finished all
operations and exited. Never terminates an active writer or replays a capture.
"""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import uuid

from desktop_artifacts import ROOT, MAIN, COMPONENT, LABEL, OPERATIONS_BY_PROTOCOL, command, signing_identity, publish_exclusive, verify_app, launch_configuration, pair_protocol


def service_state(domain):
    result = subprocess.run(["launchctl", "print", domain + "/" + LABEL], text=True, capture_output=True)
    if result.returncode != 0:
        # A nonzero result is not, by itself, proof of an absent service.
        if "Could not find service" in result.stderr or "Could not find specified service" in result.stderr:
            return None
        raise RuntimeError("Unable to inspect the exact user service: " + result.stderr.strip())
    return result.stdout


def own_main_running():
    # Enumerate only this executable name, then inspect executable paths rather
    # than command-line arguments, which could contain private text.
    result = subprocess.run(["pgrep", "-u", str(os.getuid()), "-x", "PromptBridge"], text=True, capture_output=True)
    if result.returncode == 1:
        return False
    if result.returncode != 0:
        raise RuntimeError("Unable to inspect PromptBridge processes")
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    function = library.proc_pidpath
    function.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    function.restype = ctypes.c_int
    for value in result.stdout.split():
        buffer = ctypes.create_string_buffer(4096)
        if function(int(value), buffer, len(buffer)) <= 0:
            raise RuntimeError("Process identity changed during lifecycle preflight")
        path = Path(os.fsdecode(buffer.value))
        # Fixture apps and all prior product versions must also finish first.
        if path.name == "PromptBridge":
            return True
    return False


def validate_job(state, agent, destination):
    if state is None:
        return
    program = re.search(r"^\s*program = (.+)$", state, re.MULTILINE)
    source = re.search(r"^\s*path = (.+)$", state, re.MULTILINE)
    if not program or program.group(1).strip() != str(destination / "Contents/MacOS/AccessibilityBroker") or not source or source.group(1).strip() != str(agent):
        raise ValueError("Registered service identity does not match the fixed app and plist")


def read_manifest(path, fingerprint):
    path = path.resolve(strict=True)
    if not path.is_relative_to(ROOT) or path.is_symlink():
        raise ValueError("Review manifest must be in the workspace")
    manifest = json.loads(path.read_text())
    if manifest.get("certificateSHA1") != fingerprint or type(manifest.get("protocolVersion")) is not int or manifest["protocolVersion"] not in OPERATIONS_BY_PROTOCOL:
        raise ValueError("Incompatible installation manifest")
    pairs = {}
    for key, bundle in (("main", MAIN), ("component", COMPONENT)):
        item = manifest.get(key)
        if not isinstance(item, dict):
            raise ValueError("A complete protocol-compatible main/component pair is required")
        source = Path(item["path"])
        if source.is_symlink() or not source.resolve(strict=True).is_relative_to(ROOT):
            raise ValueError("Installation source must be a reviewed workspace artifact")
        verified = verify_app(source, bundle, fingerprint)
        if verified != item:
            raise ValueError("Frozen manifest and artifact do not match")
        pairs[key] = (source, verified)
    if pair_protocol(pairs["main"][1], pairs["component"][1]) != manifest["protocolVersion"]:
        raise ValueError("Installation manifest protocol differs from its pair")
    return pairs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, help="Reviewed signed pair; also used for compatible rollback")
    parser.add_argument("--apply", action="store_true", help="Perform the already authorized fixed-directory operation")
    parser.add_argument("--uninstall", action="store_true", help="Unload the user service and preserve apps/plist in a workspace backup")
    args = parser.parse_args()
    if os.getuid() == 0:
        parser.error("Only a user-level installation is supported")
    if bool(args.manifest) == args.uninstall:
        parser.error("Choose --manifest or --uninstall")
    fingerprint = signing_identity()
    destinations = dict(main=Path.home() / "Applications/PromptBridge.app",
                        component=Path.home() / "Applications/PromptBridge Accessibility.app")
    agent = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    expected_agent = launch_configuration(destinations["component"])
    domain = f"gui/{os.getuid()}"
    sources = {} if args.uninstall else read_manifest(args.manifest, fingerprint)
    old = {}
    for key, destination in destinations.items():
        if destination.is_symlink():
            raise ValueError("Refusing an existing symlink installation")
        if destination.exists():
            old[key] = verify_app(destination, MAIN if key == "main" else COMPONENT, fingerprint, production=False)
    if agent.is_symlink() or (agent.exists() and plistlib.loads(agent.read_bytes()) != expected_agent):
        raise ValueError("Existing LaunchAgent configuration does not match this service")
    state = service_state(domain)
    validate_job(state, agent, destinations["component"])
    if state is not None and (not agent.exists() or "pid = " in state or "state = running" in state):
        raise ValueError("Service must be the known idle job; finish operations and let it exit first")
    if own_main_running():
        raise ValueError("Close PromptBridge after clearing external targets before replacing or unloading the component")
    changed = list(old) if args.uninstall else [key for key in sources if old.get(key, {}).get("CDHash") != sources[key][1]["CDHash"]]
    component_change = "component" in changed or args.uninstall
    plan = dict(mode="uninstall" if args.uninstall else "install-or-compatible-rollback", apply=args.apply,
                destinations={key: str(value) for key, value in destinations.items()}, changed=changed,
                userDomain=domain, launchAgent=str(agent), TCCMutation=False,
                automaticPermissionRequest=False, rootService=False, capturesReplayed=False,
                quiescent=True, serviceReloadRequired=component_change or state is None)
    print(json.dumps(plan, ensure_ascii=False, indent=2))
    if not args.apply:
        return
    backup = ROOT / ".build/desktop-installations" / str(uuid.uuid4())
    backup.mkdir(parents=True, exist_ok=False)
    applications = destinations["main"].parent
    applications.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix=".promptbridge-update-", dir=applications))
    published = {}
    moved_old = {}
    service_unloaded = False
    agent_created = False
    removed_agent = None
    success = False
    try:
        # Fully verify every staged artifact before changing any installed file.
        for key in old:
            shutil.copytree(destinations[key], backup / destinations[key].name)
            verify_app(backup / destinations[key].name, MAIN if key == "main" else COMPONENT, fingerprint, production=False)
        for key in changed:
            if not args.uninstall:
                stage = stage_root / (key + ".app")
                shutil.copytree(sources[key][0], stage)
                if verify_app(stage, MAIN if key == "main" else COMPONENT, fingerprint)["CDHash"] != sources[key][1]["CDHash"]:
                    raise ValueError("Staging changed a signed artifact")
        if agent.exists():
            (backup / agent.name).write_bytes(agent.read_bytes())
        (backup / "previous-installation.json").write_text(json.dumps(dict(previous=old, configuration=expected_agent), indent=2) + "\n")
        if set(old) == {"main", "component"}:
            try:
                compatible_previous = {key: verify_app(backup / destinations[key].name,
                    MAIN if key == "main" else COMPONENT, fingerprint) for key in old}
                previous_protocol = pair_protocol(compatible_previous["main"], compatible_previous["component"])
            except ValueError:
                # A legacy PoC is preserved but never offered as a production rollback.
                compatible_previous = None
            if compatible_previous:
                (backup / "rollback-manifest.json").write_text(json.dumps(dict(compatible_previous,
                    protocolVersion=previous_protocol, certificateSHA1=fingerprint, installed=False,
                    acceptance="previous_protocol_compatible_pair"), indent=2) + "\n")
        # Main-only updates leave the exact component and existing service intact.
        if component_change and state is not None:
            current_state = service_state(domain)
            validate_job(current_state, agent, destinations["component"])
            if current_state is None or "pid = " in current_state or "state = running" in current_state or own_main_running():
                raise ValueError("Lifecycle changed during staging; no active service is stopped")
            command("launchctl", "bootout", domain, str(agent))
            if service_state(domain) is not None:
                raise RuntimeError("Exact service remains registered after bootout")
            service_unloaded = True
        for key in changed:
            destination = destinations[key]
            if key in old:
                if verify_app(destination, MAIN if key == "main" else COMPONENT, fingerprint, production=False) != old[key]:
                    raise ValueError("Installed identity changed during staging")
                previous = stage_root / (key + "-previous.app")
                publish_exclusive(destination, previous)
                moved_old[key] = previous
            if not args.uninstall:
                publish_exclusive(stage_root / (key + ".app"), destination)
                published[key] = sources[key][1]
        if args.uninstall:
            if agent.exists():
                # Preserve the plist rather than mutating the TCC database.
                if plistlib.loads(agent.read_bytes()) != expected_agent:
                    raise ValueError("LaunchAgent changed during uninstall")
                removal_path = agent.with_name(agent.name + ".removed-" + backup.name)
                publish_exclusive(agent, removal_path)
                removed_agent = removal_path
                # Move the exact removed plist into the workspace backup.
                shutil.copy2(removed_agent, backup / "removed-launchagent.plist")
                removed_agent.unlink()
        else:
            if not agent.exists():
                agent.parent.mkdir(parents=True, exist_ok=True)
                temporary_agent = stage_root / "launchagent.plist"
                temporary_agent.write_bytes(plistlib.dumps(expected_agent))
                temporary_agent.chmod(0o600)
                # Hard-link publication is exclusive and the user folders share a volume.
                os.link(temporary_agent, agent)
                agent_created = True
            if component_change or state is None:
                command("launchctl", "bootstrap", domain, str(agent))
                registered_state = service_state(domain)
                if registered_state is None:
                    raise RuntimeError("Service registration not verified")
                validate_job(registered_state, agent, destinations["component"])
            for key, (_, item) in sources.items():
                current = verify_app(destinations[key], MAIN if key == "main" else COMPONENT, fingerprint)
                if current["CDHash"] != item["CDHash"]:
                    raise ValueError("Installed artifact does not match reviewed pair")
            (backup / "installed-pair.json").write_text(json.dumps({key: verify_app(destinations[key], MAIN if key == "main" else COMPONENT, fingerprint) for key in sources}, indent=2) + "\n")
        # Preserve the actual old bundles too, including anything that appeared
        # after the preflight copy. Never discard a moved user-visible bundle.
        for key, previous in moved_old.items():
            publish_exclusive(previous, backup / ("original-" + destinations[key].name))
        success = True
        (backup / "result.json").write_text(json.dumps(dict(plan, completed=True, backup=str(backup)), indent=2) + "\n")
        print(json.dumps(dict(completed=True, backup=str(backup), TCCMutation=False), indent=2))
    except BaseException:
        # Leave published user-visible files intact after failure. Restore an old
        # bundle only where no replacement was published; never delete new state.
        for key, previous in moved_old.items():
            if not destinations[key].exists():
                publish_exclusive(previous, destinations[key])
        (backup / "failure.json").write_text(json.dumps(dict(completed=False, published=list(published),
            serviceUnloaded=service_unloaded, agentCreated=agent_created, automaticRollback=False,
            retainedStage=str(stage_root), TCCMutation=False,
            removedAgent=str(removed_agent) if removed_agent is not None and removed_agent.exists() else None,
            compatibleRollbackManifest=str(backup / "rollback-manifest.json")
                if (backup / "rollback-manifest.json").exists() else None), indent=2) + "\n")
        raise
    finally:
        # On failure preserve staged/previous artifacts for exact recovery. No
        # recursive deletion of a newly published user-owned application.
        if success:
            shutil.rmtree(stage_root)


if __name__ == "__main__":
    main()
