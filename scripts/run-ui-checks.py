#!/usr/bin/env python3
"""Route fixture-only UI and component checks to their respective owners.

Does not connect to an installed helper, read model settings, or access real hosts.
"""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
from desktop_artifacts import copy_app_resources

ROOT = Path(__file__).resolve().parent.parent
MOVED = {"codex-probe-policy", "external-selection-policy", "full-input-policy", "focus-launcher-policy"}


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)


def main():
    input_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "Tests/PromptBridgeUITests/stability.json"
    output = (Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / ".build/ui-acceptance").resolve()
    if not output.is_relative_to(ROOT / ".build") or output.exists():
        raise ValueError("Use a new workspace .build output directory; previous evidence is never overwritten")
    script = json.loads(input_path.read_text())
    scenes = script.get("scenarios")
    if set(script) != {"scenarios"} or not isinstance(scenes, list) or not scenes or not all(isinstance(x, str) for x in scenes):
        raise ValueError("Expected a nonempty scenarios array")
    runtime_scenes = [x for x in scenes if x in MOVED]
    ui_scenes = [x for x in scenes if x not in MOVED]
    output.mkdir(parents=True)
    report = dict(checks=[], snapshots=[], failures=[], migratedScenarioNames=runtime_scenes)
    scratch = ROOT / ".build/ui-component-fixtures"
    try:
        if runtime_scenes:
            run("swift", "build", "--scratch-path", str(scratch), "--product", "AccessibilityRuntimeChecks")
            directory = Path(subprocess.check_output(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"], cwd=ROOT, text=True).strip())
            destination = output / "runtime-report.json"
            result = subprocess.run([str(directory / "AccessibilityRuntimeChecks"), "--output", str(destination)], cwd=ROOT)
            runtime = json.loads(destination.read_text())
            report["checks"] += [dict(item, scenario="accessibility-runtime") for item in runtime["checks"]]
            report["failures"] += runtime["failures"]
            if result.returncode:
                raise RuntimeError("Component fixture checks failed")
        if ui_scenes:
            run("swift", "build", "--scratch-path", str(scratch), "-Xswiftc", "-DPROMPTBRIDGE_TESTING", "--product", "PromptBridge")
            directory = Path(subprocess.check_output(["swift", "build", "--scratch-path", str(scratch), "--show-bin-path"], cwd=ROOT, text=True).strip())
            # A separate ephemeral bundle, never a production signature/permission identity.
            with tempfile.TemporaryDirectory(prefix="ui-app-", dir=ROOT / ".build") as temporary:
                app = Path(temporary) / "PromptBridgeUITests.app"
                (app / "Contents/MacOS").mkdir(parents=True)
                shutil.copy2(directory / "PromptBridge", app / "Contents/MacOS/PromptBridge")
                copy_app_resources(directory, app / "Contents/Resources")
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps(dict(
                    CFBundleIdentifier="local.promptbridge.uitests", CFBundleName="PromptBridgeUITests",
                    CFBundleExecutable="PromptBridge", CFBundlePackageType="APPL", CFBundleIconFile="AppIcon.icns",
                    LSMinimumSystemVersion="14.0", NSHighResolutionCapable=True)))
                run("codesign", "--force", "--sign", "-", str(app))
                routed = Path(temporary) / "scenarios.json"
                routed.write_text(json.dumps(dict(scenarios=ui_scenes)))
                result = subprocess.run([str(app / "Contents/MacOS/PromptBridge"), "--ui-test-script", str(routed),
                    "--ui-test-output", str(output / "ui")], cwd=ROOT)
                ui_report = json.loads((output / "ui/report.json").read_text())
                report["checks"] += ui_report["checks"]
                report["snapshots"] += [dict(item, image="ui/" + item["image"]) for item in ui_report["snapshots"]]
                report["failures"] += ui_report["failures"]
                if result.returncode:
                    raise RuntimeError("UI fixture checks failed")
    except BaseException as error:
        report["failures"].append(str(error))
        raise
    finally:
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f'{sum(x["passed"] for x in report["checks"])}/{len(report["checks"])} fixture checks; {len(report["failures"])} failures; {output}')


if __name__ == "__main__":
    main()
