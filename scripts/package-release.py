#!/usr/bin/env python3
"""Verify a complete signed candidate and create the public download ZIP."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from desktop_artifacts import ROOT, MAIN, COMPONENT, verify_app, pair_protocol


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    args = parser.parse_args()
    release = json.loads(args.manifest.read_text())
    certificate = release["certificateSHA1"]
    source = Path(release["main"]["path"])
    main = verify_app(source, MAIN, certificate)
    embedded = source / "Contents/Helpers/PromptBridge Accessibility.app"
    component = verify_app(embedded, COMPONENT, certificate)
    pair_protocol(main, component)
    expected_component = release["component"]
    if {k: v for k, v in component.items() if k != "path"} != {k: v for k, v in expected_component.items() if k != "path"}:
        raise ValueError("Embedded component differs from the candidate manifest; rebuild the main application with this component")
    if main != release["main"]:
        raise ValueError("The candidate has changed since it was built")
    for app in (source, embedded):
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        if any(key in info for key in ("PromptBridgeConfigFile", "PromptBridgeEnvironmentFile")):
            raise ValueError("A public bundle must not contain developer configuration paths")
        for file in app.rglob("*"):
            if not file.is_file():
                continue
            data = file.read_bytes()
            if (str(Path.home()) + "/").encode() in data or b"--ui-test-script" in data or b"--preferences-ui-test" in data:
                raise ValueError("Developer path or test entry found in " + str(file.relative_to(source)))
    executable = source / "Contents/MacOS/PromptBridge"
    architecture = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).strip()
    if architecture != "arm64":
        raise ValueError("This release targets Apple Silicon (arm64)")
    version = main["version"]
    output = ROOT / "dist" / f"PromptBridge-{version}-arm64.zip"
    if output.exists():
        raise ValueError("Release ZIP already exists; preserve it and use a new release destination")
    with tempfile.TemporaryDirectory(prefix="public-package-", dir=ROOT / ".build") as temporary:
        folder = Path(temporary) / f"PromptBridge-{version}"
        folder.mkdir()
        shutil.copytree(source, folder / "PromptBridge.app")
        shutil.copy2(ROOT / "LICENSE", folder / "LICENSE.txt")
        (folder / "开始使用.txt").write_text(
            "打开 PromptBridge，在设置中配置模型。\n"
            "输入框接入：设置 → 翻译与浮窗 → 安装并启用。\n"
            "本版为自签名、未公证应用。首次打开说明：\n"
            "https://github.com/d874284271-commits/PromptBridge/blob/main/docs/installation.md\n",
            encoding="utf-8")
        subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(folder), str(output)], check=True)
    checksum = hashlib.sha256(output.read_bytes()).hexdigest()
    output.with_suffix(".zip.sha256").write_text(f"{checksum}  {output.name}\n")
    metadata = dict(version=version, build=main["build"], architecture=architecture,
                    componentVersion=component["version"], componentBuild=component["build"],
                    protocolVersion=3, cliEditorProtocol=2, notarized=False, sha256=checksum)
    output.with_suffix(".json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()
