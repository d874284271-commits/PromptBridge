#!/bin/zsh
# Main and helper are independent immutable candidates; no installation or TCC effects.
set -euo pipefail
cd "${0:A:h:h}"
exec python3 scripts/build-desktop.py "$@"
