#!/usr/bin/env python3
"""First installation of the reviewed identity PoC only. Default is a read-only dry run.

--install writes the user Applications bundle and LaunchAgent, then bootstraps that
specific user service. It does not launch a probe, grant permissions or reset TCC.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
LABEL = "local.promptbridge.accessibility"
SERVICE = LABEL + ".xpc"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--certificate", required=True)
    parser.add_argument("--install", action="store_true", help="Requires action-specific approval; dry-run is the default")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.certificate):
        parser.error("Exact certificate SHA-1 required")
    fingerprint = args.certificate.upper()
    source = ROOT / ".build/accessibility-poc/packages/PromptBridge Accessibility PoC.app"
    destination = Path.home() / "Applications/PromptBridge Accessibility.app"
    agent = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    requirement = f'identifier "{LABEL}" and certificate leaf = H"{fingerprint}"'
    info = plistlib.loads((source / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != LABEL or info.get("PromptBridgeSignerSHA1") != fingerprint or info.get("CFBundleExecutable") != "AccessibilityBroker":
        raise ValueError("Unexpected source package identity")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R=" + requirement, str(source)], check=True)
    domain = f"gui/{os.getuid()}"
    registered = subprocess.run(["launchctl", "print", domain + "/" + LABEL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    # This first-stage installer never replaces existing user objects or services.
    if destination.exists() or destination.is_symlink() or agent.exists() or agent.is_symlink() or registered:
        raise ValueError("Existing destination/agent/service detected; stop for an identity and lifecycle review")
    configuration = dict(Label=LABEL, ProgramArguments=[str(destination / "Contents/MacOS/AccessibilityBroker")],
                         MachServices={SERVICE: True}, RunAtLoad=False, KeepAlive=False,
                         LimitLoadToSessionType="Aqua", ProcessType="Interactive")
    plan = dict(mode="install" if args.install else "dry-run", source=str(source), destination=str(destination),
                launchAgent=str(agent), domain=domain, configuration=configuration,
                TCCMutation=False, rootService=False, automaticPermissionRequest=False)
    print(json.dumps(plan, ensure_ascii=False, indent=2))
    if not args.install:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    agent.parent.mkdir(parents=True, exist_ok=True)
    stage_dir = Path(tempfile.mkdtemp(prefix=".promptbridge-ax-stage-", dir=destination.parent))
    temporary_agent = agent.with_name(agent.name + ".stage")
    own_temporary_agent = False
    own_destination = False
    own_agent = False
    bootstrap_attempted = False
    try:
        stage = stage_dir / destination.name
        shutil.copytree(source, stage)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", "-R=" + requirement, str(stage)], check=True)
        # Exclusive creation avoids overwriting a user file that appeared after validation.
        with temporary_agent.open("xb") as stream:
            own_temporary_agent = True
            stream.write(plistlib.dumps(configuration))
        temporary_agent.chmod(0o600)
        if destination.exists() or agent.exists():
            raise ValueError("Destination changed during staging")
        stage.rename(destination)
        own_destination = True
        # Exclusive publication must not overwrite a plist created concurrently.
        os.link(temporary_agent, agent)
        own_agent = True
        temporary_agent.unlink()
        own_temporary_agent = False
        bootstrap_attempted = True
        subprocess.run(["launchctl", "bootstrap", domain, str(agent)], check=True)
    except BaseException:
        # Published paths are user-visible: never recursively delete them after
        # failure, as user files may have appeared since publication. Keep them
        # for an exact, separately authorized cleanup and stop the owned service
        # only when this invocation actually attempted its registration.
        service_stopped = not bootstrap_attempted
        bootout_code = None
        if own_agent and bootstrap_attempted:
            bootout_code = subprocess.run(["launchctl", "bootout", domain, str(agent)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
            absent = subprocess.run(["launchctl", "print", domain + "/" + LABEL], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0
            service_stopped = bootout_code == 0 and absent
        print(json.dumps(dict(installationFailed=True, serviceStopConfirmed=service_stopped,
                              bootoutExitCode=bootout_code, cleanupConfirmed=False,
                              retainedObjects=([str(destination)] if own_destination else []) + ([str(agent)] if own_agent else []),
                              TCCMutation=False), ensure_ascii=False, indent=2))
        raise
    finally:
        shutil.rmtree(stage_dir)
        if own_temporary_agent and temporary_agent.exists():
            temporary_agent.unlink()


if __name__ == "__main__":
    main()
