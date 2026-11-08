#!/usr/bin/env python3
"""Build/sign separate immutable desktop candidates; never install or modify TCC."""
import argparse
import datetime
import json
from pathlib import Path
import plistlib
import re
import shutil
import tempfile

from desktop_artifacts import ROOT, MAIN, COMPONENT, IPC_PROTOCOL, CLI_EDITOR_PROTOCOL, OPERATIONS, command, digest, signing_identity, requirement, publish_exclusive, verify_app, publish_current, pair_protocol, validate_cli_test_hosts
from desktop_artifacts import copy_app_resources


def package(binary, output, bundle, version, build, fingerprint, editor=None, cli_test_hosts=(), component=None):
    test_hosts = sorted(validate_cli_test_hosts(list(cli_test_hosts)))
    if output.exists() or output.is_symlink():
        raise ValueError(f"Frozen output already exists; use a new candidate version: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)
    stage_root = Path(tempfile.mkdtemp(prefix=".desktop-package-", dir=output.parent))
    stage = stage_root / output.name
    try:
        (stage / "Contents/MacOS").mkdir(parents=True)
        (stage / "Contents/Resources").mkdir()
        shutil.copy2(binary, stage / "Contents/MacOS" / binary.name)
        command("strip", "-S", str(stage / "Contents/MacOS" / binary.name))
        if editor is not None:
            if bundle != MAIN:
                raise ValueError("CLI editor belongs to the main application")
            destination = stage / "Contents/MacOS/promptbridge-editor"
            shutil.copy2(editor, destination)
            command("strip", "-S", str(destination))
            command("codesign", "--force", "--sign", fingerprint, str(destination))
            command("codesign", "--verify", "--strict", str(destination))
        if component is not None:
            verify_app(component, COMPONENT, fingerprint)
            embedded = stage / "Contents/Helpers/PromptBridge Accessibility.app"
            embedded.parent.mkdir(parents=True)
            shutil.copytree(component, embedded)
        name = "PromptBridge" if bundle == MAIN else "PromptBridge Accessibility"
        info = dict(CFBundleIdentifier=bundle, CFBundleName=name, CFBundleDisplayName=name,
                    CFBundleExecutable=binary.name, CFBundlePackageType="APPL",
                    CFBundleShortVersionString=version, CFBundleVersion=build,
                    LSMinimumSystemVersion="14.0", NSHighResolutionCapable=True,
                    PromptBridgeSignerSHA1=fingerprint, PromptBridgeIPCProtocol=IPC_PROTOCOL,
                    PromptBridgeCLIValidatedHosts=[], PromptBridgeCLITestHosts=test_hosts)
        if bundle == COMPONENT:
            info["LSUIElement"] = True
            info["NSAppleEventsUsageDescription"] = "定位当前 CLI 会话所在的 Terminal 标签页，并在你确认后返回该标签页。"
        else:
            copy_app_resources(binary.parent, stage / "Contents/Resources")
            info["CFBundleIconFile"] = "AppIcon.icns"
            info["PromptBridgePortableStorage"] = True
            if editor is not None:
                info["PromptBridgeCLIEditorProtocol"] = CLI_EDITOR_PROTOCOL
                info["CFBundleDocumentTypes"] = [dict(CFBundleTypeName="PromptBridge CLI Edit Request",
                    CFBundleTypeRole="Editor", LSHandlerRank="Owner",
                    LSItemContentTypes=["local.promptbridge.cli-edit-request"])]
                info["UTExportedTypeDeclarations"] = [dict(UTTypeIdentifier="local.promptbridge.cli-edit-request",
                    UTTypeConformsTo=["public.data"],
                    UTTypeTagSpecification={"public.filename-extension": ["promptbridge-edit"]})]
        (stage / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        metadata = dict(version=version, build=build, bundle=bundle, certificateSHA1=fingerprint,
                        codeRequirement=requirement(bundle, fingerprint), sourceBinarySHA256=digest(binary),
                        protocolVersion=IPC_PROTOCOL, supportedOperations=OPERATIONS, cliTestHosts=test_hosts,
                        builtAtUTC=datetime.datetime.now(datetime.timezone.utc).isoformat())
        if editor is not None:
            metadata["cliEditorProtocol"] = CLI_EDITOR_PROTOCOL
            metadata["cliEditorSourceSHA256"] = digest(editor)
        (stage / "Contents/Resources/build-info.json").write_text(json.dumps(metadata, indent=2) + "\n")
        command("codesign", "--force", "--sign", fingerprint, "--requirements",
                "=designated => " + requirement(bundle, fingerprint), str(stage))
        verify_app(stage, bundle, fingerprint)
        publish_exclusive(stage, output)
        return verify_app(output, bundle, fingerprint)
    finally:
        shutil.rmtree(stage_root)


def build(product, scratch):
    command("swift", "build", "-c", "release", "--scratch-path", str(scratch), "-Xswiftc", "-file-prefix-map", "-Xswiftc", str(ROOT) + "=.",
            "-Xswiftc", "-debug-prefix-map", "-Xswiftc", str(ROOT) + "=.", "--product", product)
    binary_directory = Path(command("swift", "build", "-c", "release", "--scratch-path", str(scratch), "--show-bin-path").stdout.strip())
    return binary_directory / product


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--certificate", required=True, help="Exact SHA-1 of your code-signing certificate; no ad-hoc fallback")
    parser.add_argument("--app-version", default="0.9.0")
    parser.add_argument("--app-build", default="47")
    parser.add_argument("--component-version", default="3.1.0")
    parser.add_argument("--component-build", default="19")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--main-only", action="store_true", help="Reuse --component without rebuilding/resigning it")
    mode.add_argument("--component-only", action="store_true")
    parser.add_argument("--component", type=Path, help="Reviewed protocol-compatible component to reuse with --main-only")
    parser.add_argument("--main", type=Path, help="Reviewed main artifact to pair with --component-only; never rebuild or resign it")
    parser.add_argument("--no-publish-current", action="store_true", help="Keep dist/current unchanged; required for candidates awaiting live acceptance")
    args = parser.parse_args()
    fingerprint = signing_identity(args.certificate)
    for version, build_number in ((args.app_version, args.app_build), (args.component_version, args.component_build)):
        if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build_number):
            parser.error("Use a numeric three-part version and positive build")
    if args.main_only != (args.component is not None):
        parser.error("--main-only requires --component; component reuse is not valid in other modes")
    if args.main is not None and not args.component_only:
        parser.error("--main is only valid with --component-only")
    output = ROOT / "dist/candidates"
    app = output / f"PromptBridge-{args.app_version}-build{args.app_build}.app"
    helper = args.component or output / f"PromptBridge Accessibility-{args.component_version}-build{args.component_build}.app"
    manifest = output / (f"component-{args.component_version}-build{args.component_build}.json" if args.component_only else f"desktop-{args.app_version}-build{args.app_build}.json")
    if manifest.exists() or manifest.is_symlink() or (not args.component_only and (app.exists() or app.is_symlink())) or (not args.main_only and (helper.exists() or helper.is_symlink())):
        raise ValueError("Candidate already exists; frozen outputs cannot be overwritten")
    scratch = ROOT / ".build/desktop-production" / (f"component-{args.component_version}-{args.component_build}" if args.component_only else f"main-{args.app_version}-{args.app_build}")
    component = verify_app(helper, COMPONENT, fingerprint) if args.main_only else None
    main_app = verify_app(args.main, MAIN, fingerprint) if args.main else None
    for reused in (component, main_app):
        if reused is not None and reused["protocolVersion"] != IPC_PROTOCOL:
            raise ValueError("Reused artifact has a different IPC protocol; build a matching pair")
    if not args.main_only:
        component = package(build("AccessibilityBroker", scratch), helper, COMPONENT, args.component_version, args.component_build, fingerprint)
    if not args.component_only:
        main_app = package(build("PromptBridge", scratch), app, MAIN, args.app_version, args.app_build, fingerprint, editor=build("promptbridge-editor", scratch), component=helper)
    if main_app is not None:
        pair_protocol(main_app, component)
    release = dict(main=main_app, component=component, protocolVersion=IPC_PROTOCOL, certificateSHA1=fingerprint,
                   componentRebuilt=not args.main_only, installed=False, acceptance="candidate_not_accepted")
    with manifest.open("x") as stream:
        json.dump(release, stream, indent=2, ensure_ascii=False)
        stream.write("\n")
    if main_app is not None and not args.no_publish_current:
        current = publish_current(manifest, fingerprint)
        print(f"Current output: {current}")
    print(json.dumps(release, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
