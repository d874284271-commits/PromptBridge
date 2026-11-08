#!/usr/bin/env python3
"""Export the reviewed source tree without local history or private state."""
import argparse
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parent.parent
FILES = ["Package.swift", "README.md", "LICENSE", "NOTICE", "CONTRIBUTING.md", "SECURITY.md",
         "CHANGELOG.md", "AGENTS.md", ".gitignore", ".env.example", "config/providers.example.json",
         "docs/installation.md", "docs/development.md", "docs/privacy.md", "docs/architecture.md",
         "docs/adr/0007-runtime-integration-capabilities.md", "docs/adr/0008-one-click-auto.md",
         "docs/plans/2026-11-08-public-release.md", "docs/releases/0.9.0.md"]
DIRECTORIES = ["Sources", "Tools", "Tests", "scripts", ".github", "docs/images"]
SECRET = re.compile(rb"(?:gh[pousr]_[A-Za-z0-9]{30,}|sk-(?:ant-)?[A-Za-z0-9_-]{30,}|-----BEGIN (?:RSA |EC )?PRIVATE KEY-----)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        parser.error("Output must not already exist")
    selected = {ROOT / name for name in FILES}
    for directory in DIRECTORIES:
        selected.update(p for p in (ROOT / directory).rglob("*") if p.is_file()
                        and "__pycache__" not in p.parts and p.name != ".DS_Store")
    for source in sorted(selected):
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Missing file or unsupported link: {source.relative_to(ROOT)}")
        if source.suffix in {".p12", ".pfx", ".pem", ".key", ".pyc"}:
            raise ValueError(f"Private or generated material: {source.relative_to(ROOT)}")
        data = source.read_bytes()
        if SECRET.search(data) or (str(Path.home()) + "/").encode() in data:
            raise ValueError(f"Review possible private material: {source.relative_to(ROOT)}")
    output.mkdir(parents=True)
    for source in sorted(selected):
        target = output / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
    print(f"Exported {len(selected)} files to {output}")


if __name__ == "__main__":
    main()
