#!/bin/zsh
# Self-owned native AX target plus synthetic host/text access. No real host reads,
# environment loading, API calls, global hotkeys, general clipboard or app packaging.
set -euo pipefail
cd "${0:A:h:h}"
swift build --target DraftCore
build_path="$(swift build --show-bin-path)"
output="${1:-$PWD/.build/ax-value-changed-local}"
mkdir -p "$output"
swiftc -swift-version 6 -parse-as-library -I "$build_path/Modules" \
  Sources/PromptBridge/ExternalInput.swift \
  Sources/PromptBridge/ExternalInputAccess.swift \
  Sources/PromptBridge/ExternalInputFixture.swift \
  Sources/PromptBridge/ExternalReplacementCapabilities.swift \
  Sources/PromptBridge/ExternalTextContent.swift \
  Sources/PromptBridge/CodexCapabilityProbe.swift \
  Tests/AXValueChangedChecks/main.swift \
  "$build_path"/DraftCore.build/*.swift.o \
  -o "$output/check"
"$output/check" "$output"
