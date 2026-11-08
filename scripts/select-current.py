#!/usr/bin/env python3
"""Select a signed existing desktop pair for dist/current; no build or installation."""
import argparse
from pathlib import Path

from desktop_artifacts import publish_current, signing_identity


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--installed", action="store_true",
                        help="Point to the fixed ~/Applications pair after verifying it matches the manifest")
    args = parser.parse_args()
    current = publish_current(args.manifest, signing_identity(), installed=args.installed)
    print(f"Current output: {current}")


if __name__ == "__main__":
    main()
