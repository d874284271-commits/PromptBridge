#!/bin/zsh
# Synthetic fixtures only; runtime policies execute in the component target.
set -euo pipefail
cd "${0:A:h:h}"
exec python3 scripts/run-ui-checks.py "$@"
