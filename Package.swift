// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PromptBridge",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PromptBridge", targets: ["PromptBridge"]),
               .executable(name: "promptbridge-editor", targets: ["PromptBridgeEditor"])],
    targets: [
        .target(name: "AccessibilityContracts"),
        .target(name: "AccessibilityRuntime", dependencies: ["AccessibilityContracts"]),
        .executableTarget(name: "AccessibilityRuntimeChecks", dependencies: ["AccessibilityRuntime"], path: "Tests/AccessibilityRuntimeTests"),
        .executableTarget(name: "AccessibilityBroker", dependencies: ["AccessibilityContracts", "AccessibilityRuntime"], path: "Tools/AccessibilityBroker"),
        .executableTarget(name: "AccessibilityProbe", dependencies: ["AccessibilityContracts"], path: "Tools/AccessibilityProbe"),
        .executableTarget(name: "AccessibilityContractsChecks", dependencies: ["AccessibilityContracts"], path: "Tests/AccessibilityContractsTests", exclude: ["install_checks.py"]),
        .target(name: "DraftCore", dependencies: ["AccessibilityContracts"]),
        .executableTarget(name: "PromptBridge", dependencies: ["DraftCore", "AccessibilityContracts"],
                          resources: [.process("Resources")]),
        .executableTarget(name: "PromptBridgeEditor", dependencies: ["DraftCore"], path: "Tools/PromptBridgeEditor"),
        .executableTarget(name: "CLIEditorChecks", dependencies: ["DraftCore"], path: "Tests/CLIEditorTests"),
        .executableTarget(name: "CLIIntegrationChecks", dependencies: ["DraftCore", "AccessibilityContracts"], path: "Tests/CLIIntegrationTests"),
        .executableTarget(name: "ProviderCheck", dependencies: ["DraftCore"], path: "Tools/ProviderCheck"),
        .executableTarget(name: "ReleaseChecks", dependencies: ["DraftCore", "AccessibilityContracts"], path: "Tests/ReleaseTests"),
        .executableTarget(name: "DraftCoreChecks", dependencies: ["DraftCore"], path: "Tests/DraftCoreTests"),
    ]
)
