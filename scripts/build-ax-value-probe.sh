#!/bin/zsh
# Compile a separate diagnostic; do not launch it or modify a frozen app bundle.
set -euo pipefail
cd "${0:A:h:h}"
swift build --target DraftCore
build_path="$(swift build --show-bin-path)"
output="$PWD/.build/ax-value-probe"
mkdir -p "$output"
swiftc -swift-version 6 -parse-as-library -I "$build_path/Modules" \
  Sources/PromptBridge/ExternalInput.swift \
  Sources/PromptBridge/ExternalInputAccess.swift \
  Sources/PromptBridge/ExternalInputFixture.swift \
  Sources/PromptBridge/ExternalReplacementCapabilities.swift \
  Sources/PromptBridge/ExternalTextContent.swift \
  Sources/PromptBridge/CodexCapabilityProbe.swift \
  Tools/AXValueChangedProbe/main.swift \
  "$build_path"/DraftCore.build/*.swift.o \
  -o "$output/probe"
