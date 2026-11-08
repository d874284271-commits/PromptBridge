#!/bin/zsh
# Fixed-identity desktop candidates only. Never replaces frozen dist/PromptBridge.app.
set -euo pipefail
cd "${0:A:h:h}"
exec python3 scripts/build-desktop.py "$@"
