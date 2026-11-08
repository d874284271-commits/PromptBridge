import AccessibilityContracts
import DraftCore
import Foundation
import Darwin

var failures = 0
var total = 0
@MainActor func check(_ name: String, _ body: () throws -> Bool) {
    total += 1
    do { if try body() { print("PASS \(name)"); return } } catch { print("ERROR \(name): \(error)") }
    failures += 1; print("FAIL \(name)")
}
let fm = FileManager.default
let root = fm.temporaryDirectory.appendingPathComponent("promptbridge-release-" + UUID().uuidString)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let certificate = String(repeating: "A", count: 40)

check("short editors use their own minimum") {
    let size = EditorLayout.heights(source: 20, output: 60, available: 500)
    return size.source == 72 && size.output == 72
}
check("long editors stop at 220 and share a constrained budget") {
    let full = EditorLayout.heights(source: 10_000, output: 4_000, available: 600)
    let small = EditorLayout.heights(source: 10_000, output: 4_000, available: 300)
    return full.source == 220 && full.output == 220 && small.source + small.output == 300
}
check("a short source does not expand to match a long result") {
    let size = EditorLayout.heights(source: 20, output: 10_000, available: 300)
    return size.source == 72 && size.output == 220
}
check("no result reserves no empty editor; deleting content shrinks") {
    let size = EditorLayout.heights(source: 30, output: nil, available: 400)
    return size.source == 72 && size.output == 0
}
check("tiny screen keeps editors usable and permits form scrolling") {
    let size = EditorLayout.heights(source: 500, output: 500, available: 90)
    return size.source == 72 && size.output == 72
}

let old = root.appendingPathComponent("old/providers.json")
let destination = root.appendingPathComponent("data")
let preset = ProviderPreset(name: "Fixture", configuration: ProviderConfiguration(format: .chatCompletions,
    baseURL: "https://example.invalid/v1", model: "fixture", apiKey: "fixture-only"))
let library = ProviderLibrary(presets: [preset], activePresetID: preset.id)
try ProviderLibraryStore(fileURL: old).save(library)
try TranslationPreferencesStore(fileURL: old.deletingLastPathComponent().appendingPathComponent("preferences.json")).save(TranslationPreferences())
check("migration copies validated settings and keeps the originals") {
    try ApplicationStorage.migrate(from: old, to: destination)
    return try ProviderLibraryStore(fileURL: destination.appendingPathComponent("providers.json")).load() == library
        && fm.fileExists(atPath: old.path) && fm.fileExists(atPath: destination.appendingPathComponent("preferences.json").path)
}
check("migration preserves an existing destination including malformed data") {
    let file = destination.appendingPathComponent("providers.json")
    try Data("keep this".utf8).write(to: file)
    try ApplicationStorage.migrate(from: old, to: destination)
    return try String(contentsOf: file, encoding: .utf8) == "keep this"
}
check("migration gives new credentials private permissions") {
    let next = root.appendingPathComponent("private-data")
    try ApplicationStorage.migrate(from: old, to: next)
    let attributes = try fm.attributesOfItem(atPath: next.appendingPathComponent("providers.json").path)
    return (attributes[.posixPermissions] as? Int) == 0o600
}

final class ServiceFixture: @unchecked Sendable {
    var registered = false
    var failNextBootstrap = false
    func run(_ args: [String]) -> Int32 {
        switch args.first {
        case "print": return registered ? 0 : 113
        case "bootout": registered = false; return 0
        case "bootstrap":
            if failNextBootstrap { failNextBootstrap = false; return 5 }
            registered = true; return 0
        default: return 1
        }
    }
}
@MainActor func app(_ location: URL, bundle: String, version: String) throws {
    try fm.createDirectory(at: location.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let info: [String: Any] = ["CFBundleIdentifier": bundle, "CFBundleName": "Fixture", "CFBundlePackageType": "APPL",
        "CFBundleExecutable": "fixture", "CFBundleVersion": version, "PromptBridgeIPCProtocol": 3]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: location.appendingPathComponent("Contents/Info.plist"))
    try Data(version.utf8).write(to: location.appendingPathComponent("Contents/MacOS/fixture"))
}
func verifyFixture(_ location: URL, _ bundle: String, _ certificate: String) throws {
    guard Bundle(url: location)?.bundleIdentifier == bundle, certificate == String(repeating: "A", count: 40),
          FileManager.default.fileExists(atPath: location.appendingPathComponent("Contents/MacOS/fixture").path) else {
        throw BrokerContractError.invalidIdentity
    }
}
let source = root.appendingPathComponent("download/PromptBridge.app")
try app(source, bundle: BrokerIdentity.clientBundle, version: "1")
try app(source.appendingPathComponent("Contents/Helpers/PromptBridge Accessibility.app"), bundle: BrokerIdentity.bundle, version: "1")
let service = ServiceFixture()
let installer = DesktopInstaller(home: root.appendingPathComponent("home"), verify: verifyFixture, service: { service.run($0) }, ensureQuiescent: {})
check("fresh user installation publishes the pair and registers service") {
    try installer.install(from: source, certificate: certificate)
    return service.registered && fm.fileExists(atPath: installer.application.path) && fm.fileExists(atPath: installer.component.path)
}
let next = root.appendingPathComponent("update/PromptBridge.app")
try app(next, bundle: BrokerIdentity.clientBundle, version: "2")
try app(next.appendingPathComponent("Contents/Helpers/PromptBridge Accessibility.app"), bundle: BrokerIdentity.bundle, version: "2")
check("bootstrap failure restores the old app pair and registered service") {
    service.failNextBootstrap = true
    do { try installer.install(from: next, certificate: certificate); return false } catch { }
    return try service.registered && String(contentsOf: installer.application.appendingPathComponent("Contents/MacOS/fixture"), encoding: .utf8) == "1"
        && String(contentsOf: installer.component.appendingPathComponent("Contents/MacOS/fixture"), encoding: .utf8) == "1"
}
check("update publishes the new pair") {
    try installer.install(from: next, certificate: certificate)
    return try service.registered && String(contentsOf: installer.application.appendingPathComponent("Contents/MacOS/fixture"), encoding: .utf8) == "2"
}
check("repair from the installed app preserves its running executable") {
    let before = try fm.attributesOfItem(atPath: installer.application.path)[.systemFileNumber] as? NSNumber
    try installer.install(from: installer.application, certificate: certificate)
    return try before == (fm.attributesOfItem(atPath: installer.application.path)[.systemFileNumber] as? NSNumber)
}
check("uninstall leaves the main app and user configuration") {
    let config = installer.home.appendingPathComponent("Library/Application Support/PromptBridge/providers.json")
    try ProviderLibraryStore(fileURL: config).save(library)
    try installer.uninstall(certificate: certificate)
    return !service.registered && !fm.fileExists(atPath: installer.component.path)
        && fm.fileExists(atPath: installer.application.path) && fm.fileExists(atPath: config.path)
}
check("a helper that becomes active before service changes aborts installation") {
    let guarded = DesktopInstaller(home: installer.home, verify: verifyFixture,
        service: { service.run($0) }, ensureQuiescent: { throw DesktopInstallError.message("fixture active helper") })
    do { try guarded.install(from: next, certificate: certificate); return false } catch { }
    return !service.registered && !fm.fileExists(atPath: installer.component.path)
}
check("an application with another identity cannot be installed") {
    do { try installer.install(from: source, certificate: String(repeating: "B", count: 40)); return false }
    catch { return !service.registered }
}
print("\(total - failures)/\(total) release checks")
exit(failures == 0 ? 0 : 1)
