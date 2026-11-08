#!/usr/bin/env python3
"""Workspace-only PoC packaging. Never installs, registers, requests TCC or reads model configuration."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".build/accessibility-poc"


def requirement(bundle, fingerprint):
    return f'identifier "{bundle}" and certificate leaf = H"{fingerprint}"'


def run(*args, capture=False):
    return subprocess.run(args, cwd=ROOT, check=True, text=True, capture_output=capture)


def package(binary, output, bundle, name, version, build, fingerprint, marker):
    metadata = dict(sourceBinarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                    certificateSHA1=fingerprint, bundle=bundle, version=version, build=build,
                    protocolVersion=1, marker=marker)
    expected = requirement(bundle, fingerprint)
    if output.exists():
        stored = json.loads((output / "Contents/Resources/build-info.json").read_text())
        if stored != metadata:
            raise ValueError(f"Existing PoC package differs; use a new reviewed package revision: {output}")
        run("codesign", "--verify", "--deep", "--strict", f"-R={expected}", str(output))
        return
    stage = Path(tempfile.mkdtemp(prefix="package-", dir=WORK)) / output.name
    try:
        (stage / "Contents/MacOS").mkdir(parents=True)
        (stage / "Contents/Resources").mkdir()
        shutil.copy2(binary, stage / "Contents/MacOS" / binary.name)
        info = dict(CFBundleIdentifier=bundle, CFBundleName=name, CFBundleDisplayName=name,
                    CFBundleExecutable=binary.name, CFBundlePackageType="APPL",
                    CFBundleShortVersionString=version, CFBundleVersion=build,
                    LSMinimumSystemVersion="14.0", LSUIElement=True,
                    PromptBridgeSignerSHA1=fingerprint, PromptBridgeProbeWorkspace=str(ROOT))
        (stage / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (stage / "Contents/Resources/build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
        # Explicit certificate required. No name ambiguity and no ad-hoc fallback.
        # codesign treats a requirements argument without '=' as a filename.
        run("codesign", "--force", "--sign", fingerprint, "--requirements", "=designated => " + expected, str(stage))
        run("codesign", "--verify", "--deep", "--strict", f"-R={expected}", str(stage))
        output.parent.mkdir(parents=True, exist_ok=True)
        stage.rename(output)
    finally:
        shutil.rmtree(stage.parent)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--certificate", required=True, help="Exact public SHA-1 fingerprint of the dedicated signing certificate")
    updates = parser.add_mutually_exclusive_group()
    updates.add_argument("--client-update", action="store_true", help="Build a different client binary; leave the packaged component unchanged")
    updates.add_argument("--component-update", action="store_true", help="Build reviewed PoC 0.0.2/build2 in a new package; leave baseline component and clients unchanged")
    updates.add_argument("--diagnostic-update", action="store_true", help="Build separate PoC 0.0.3/build3 and diagnostic client; no installation or baseline/client overwrite")
    updates.add_argument("--ax-diagnostic-update", action="store_true", help="Build separate PoC0.0.4/build4 and bounded AX failure client; no installation or overwrite")
    updates.add_argument("--optional-subrole-update", action="store_true", help="Build separate PoC0.0.5/build5 and explicit optional-subrole client; no installation or overwrite")
    updates.add_argument("--compatible-client-update", action="store_true", help="Build only a compatible different client F0.0.6/build6; preserve reviewed PoC0.0.5 and all earlier clients")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-fA-F]{40}", args.certificate):
        parser.error("A 40-digit certificate SHA-1 is required; ad-hoc/name identities are rejected")
    fingerprint = args.certificate.upper()
    WORK.mkdir(parents=True, exist_ok=True)
    packages = WORK / "packages"
    component = packages / "PromptBridge Accessibility PoC.app"
    normal_build = WORK / "build"
    if args.compatible_client_update:
        component = packages / "PromptBridge Accessibility PoC 0.0.5-build5.app"
        info = plistlib.loads((component / "Contents/Info.plist").read_bytes())
        if info.get("CFBundleShortVersionString") != "0.0.5" or info.get("CFBundleVersion") != "5":
            raise ValueError("Review the compatible PoC0.0.5 component first; client update never rebuilds it")
        run("codesign", "--verify", "--deep", "--strict", f"-R={requirement('local.promptbridge.accessibility', fingerprint)}", str(component))
        scratch = WORK / "build-client-F"
        flags = ("-Xswiftc", "-DACCESSIBILITY_PROBE_COMPATIBLE_UPDATE")
        run("swift", "build", "--scratch-path", str(scratch), "--product", "AccessibilityProbe", *flags)
        bin_dir = Path(run("swift", "build", "--scratch-path", str(scratch), "--show-bin-path", capture=True).stdout.strip())
        client = packages / "PromptBridge Authorization Probe Update 0.0.6-build6.app"
        package(bin_dir / "AccessibilityProbe", client, "local.promptbridge.prototype", "PromptBridge Authorization Probe", "0.0.6", "6", fingerprint, "compatible-update-F")
        print(json.dumps(dict(component=str(component), client=str(client), certificateSHA1=fingerprint,
                              componentRebuilt=False, productionMigration=False, systemInstalled=False), indent=2))
        return
    if args.component_update or args.diagnostic_update or args.ax_diagnostic_update or args.optional_subrole_update:
        # Explicit workspace-only revisions; never rebuild/resign baseline A/B.
        if not component.exists():
            raise ValueError("Review baseline component first; update never replaces it")
        run("codesign", "--verify", "--deep", "--strict", f"-R={requirement('local.promptbridge.accessibility', fingerprint)}", str(component))
        revision = "5" if args.optional_subrole_update else ("4" if args.ax_diagnostic_update else ("3" if args.diagnostic_update else "2"))
        version = "0.0." + revision
        scratch = WORK / ("build-component-" + revision)
        flags = ("-Xswiftc", "-DACCESSIBILITY_PROBE_OPTIONAL_SUBROLE") if args.optional_subrole_update else (("-Xswiftc", "-DACCESSIBILITY_PROBE_AX_DIAGNOSTIC") if args.ax_diagnostic_update else (("-Xswiftc", "-DACCESSIBILITY_PROBE_DIAGNOSTIC") if args.diagnostic_update else ()))
        run("swift", "build", "--scratch-path", str(scratch), "--product", "AccessibilityBroker", *flags)
        bin_dir = Path(run("swift", "build", "--scratch-path", str(scratch), "--show-bin-path", capture=True).stdout.strip())
        candidate = packages / f"PromptBridge Accessibility PoC {version}-build{revision}.app"
        marker = "identity-PoC-explicit-optional-subrole" if args.optional_subrole_update else ("identity-PoC-AX-failure-diagnostics" if args.ax_diagnostic_update else ("identity-PoC-host-rejection-diagnostics" if args.diagnostic_update else "identity-PoC-Claude-2.26454.0"))
        package(bin_dir / "AccessibilityBroker", candidate, "local.promptbridge.accessibility", "PromptBridge Accessibility", version, revision, fingerprint, marker)
        diagnostic_client = None
        if args.diagnostic_update or args.ax_diagnostic_update or args.optional_subrole_update:
            run("swift", "build", "--scratch-path", str(scratch), "--product", "AccessibilityProbe", *flags)
            diagnostic_client = packages / (f"PromptBridge Authorization Probe Diagnostic {version}-build{revision}.app" if args.ax_diagnostic_update or args.optional_subrole_update else "PromptBridge Authorization Probe Diagnostic.app")
            package(bin_dir / "AccessibilityProbe", diagnostic_client, "local.promptbridge.prototype", "PromptBridge Authorization Probe", version, revision, fingerprint, "diagnostic-E" if args.optional_subrole_update else ("diagnostic-D" if args.ax_diagnostic_update else "diagnostic-C"))
        print(json.dumps(dict(component=str(candidate), client=str(diagnostic_client) if diagnostic_client else None,
                              certificateSHA1=fingerprint, productionMigration=False, systemInstalled=False), indent=2))
        return
    if args.client_update:
        if not component.exists():
            raise ValueError("Build and review baseline component first; update mode never rebuilds it")
        run("codesign", "--verify", "--deep", "--strict", f"-R={requirement('local.promptbridge.accessibility', fingerprint)}", str(component))
        scratch = WORK / "build-client-B"
        run("swift", "build", "--scratch-path", str(scratch), "--product", "AccessibilityProbe", "-Xswiftc", "-DACCESSIBILITY_PROBE_UPDATE")
    else:
        scratch = normal_build
        run("swift", "build", "--scratch-path", str(scratch), "--product", "AccessibilityBroker")
        bin_dir = Path(run("swift", "build", "--scratch-path", str(scratch), "--show-bin-path", capture=True).stdout.strip())
        package(bin_dir / "AccessibilityBroker", component, "local.promptbridge.accessibility", "PromptBridge Accessibility", "0.0.1", "1", fingerprint, "identity-PoC")
        run("swift", "build", "--scratch-path", str(scratch), "--product", "AccessibilityProbe")
    bin_dir = Path(run("swift", "build", "--scratch-path", str(scratch), "--show-bin-path", capture=True).stdout.strip())
    marker = "B" if args.client_update else "A"
    client = packages / f"PromptBridge Authorization Probe {marker}.app"
    package(bin_dir / "AccessibilityProbe", client, "local.promptbridge.prototype", "PromptBridge Authorization Probe", "0.0.2" if args.client_update else "0.0.1", "2" if args.client_update else "1", fingerprint, marker)
    print(json.dumps(dict(component=str(component), client=str(client), certificateSHA1=fingerprint,
                          productionMigration=False, systemInstalled=False), indent=2))


if __name__ == "__main__":
    main()
