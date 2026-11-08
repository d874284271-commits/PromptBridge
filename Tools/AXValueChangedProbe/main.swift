import AppKit
import ApplicationServices
import DraftCore

/// Standalone acceptance tool. It never activates a host, writes text, loads
/// model configuration, or publishes state by asking the captured target to read.
@MainActor private final class ReadCountingAccess: ExternalInputAccess {
    let base: any ExternalInputAccess
    private(set) var attributeReads = 0
    private(set) var rangeReads = 0
    private(set) var writeAttempts = 0
    init(_ base: any ExternalInputAccess) { self.base = base }
    var hasPermission: Bool { base.hasPermission }
    var ownApplication: ExternalApplication { base.ownApplication }
    func frontmost() -> ExternalApplication? { base.frontmost() }
    func isRunning(_ application: ExternalApplication) -> Bool { base.isRunning(application) }
    func applicationElement(_ application: ExternalApplication) -> AXUIElement { base.applicationElement(application) }
    func owner(_ element: AXUIElement) -> pid_t? { base.owner(element) }
    func read(_ element: AXUIElement, _ attribute: ExternalAttribute, optional: Bool) throws -> CFTypeRef? {
        attributeReads += 1
        return try base.read(element, attribute, optional: optional)
    }
    func isEditable(_ element: AXUIElement) -> Bool { base.isEditable(element) }
    func string(_ element: AXUIElement, for range: CFRange) throws -> String {
        rangeReads += 1
        return try base.string(element, for: range)
    }
    func contextID(window: AXUIElement, input: AXUIElement) throws -> String? { try base.contextID(window: window, input: input) }
    func replacementCapabilities(application: ExternalApplication, window: AXUIElement,
                                 input: AXUIElement, host: ExternalInput.Host) -> ExternalReplacementCapabilities {
        base.replacementCapabilities(application: application, window: window, input: input, host: host)
    }
    func focus(window: AXUIElement, input: AXUIElement) async throws { throw ExternalInputError.unavailable }
    func setSelectedRange(_ range: CFRange, in input: AXUIElement) throws { throw ExternalInputError.unavailable }
    func writeFullText(_ text: String, to input: AXUIElement) throws {
        writeAttempts += 1
        throw ExternalInputError.unavailable
    }
    func activate(_ application: ExternalApplication) -> Bool { false }
    func observe(application: AXUIElement, window: AXUIElement, input: AXUIElement,
                 pid: pid_t, requireSelectionEvents: Bool,
                 receive: @escaping @MainActor (String) -> Void) throws -> any ExternalObservation {
        try base.observe(application: application, window: window, input: input, pid: pid,
                         requireSelectionEvents: requireSelectionEvents, receive: receive)
    }
}
@MainActor private struct ProbeTranslator: DraftTranslator {
    func generate(_ request: GenerationRequest) async throws -> String { "LOCAL SYNTHETIC RESULT" }
}
@main @MainActor private enum AXValueChangedProbe {
    private static let sample = "请保留按钮文案“确认删除”和路径 ./src/登录.ts。"
    private struct Event: Codable {
        let stream: String
        let name: String
        let milliseconds: Double
        let captureID: UUID?
        let targetAvailable: Bool
        let attributeReads: Int
        let rangeReads: Int
    }
    private struct Report: Codable {
        let mode: String
        var armed = false
        var selectedTextMatchesSyntheticFixture = false
        var verifiedApplication: ApplicationIdentity?
        var firstInvalidationTrigger: String?
        var valueNotificationObserved = false
        var captureValueNotificationObserved = false
        var independentObserverValueNotificationObserved = false
        var independentValueInvalidation = false
        var callbackReadDelta: Int?
        var phase = "notStarted"
        var canCopy = false
        var outputRetained = false
        var writeAttempts = 0
        var error: String?
        var events: [Event] = []
    }
    private struct ApplicationIdentity: Codable {
        let pid: pid_t
        let bundle: String
        let version: String
        let build: String
    }
    private enum Failure: Error { case arguments, existingEvidence, permission, wrongHost, unsupportedBuild, fixtureMismatch, generation }
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--help") {
            print("Build only: zsh scripts/build-ax-value-probe.sh")
            print("Local check: probe --fixture [--idle] --output FRESH_DIRECTORY")
            print("Authorized synthetic host only: probe --observe --pid PID --host BUNDLE --output FRESH_DIRECTORY")
            print("Expected selected fixture: \(sample)")
            return
        }
        func value(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        let fixtureMode = args.contains("--fixture")
        let idle = args.contains("--idle")
        guard fixtureMode != args.contains("--observe"), let path = value("--output"),
              fixtureMode || (value("--pid").flatMap(Int32.init) != nil && value("--host") != nil),
              !idle || fixtureMode, args.count == (fixtureMode ? (idle ? 5 : 4) : 8) else {
            print("FAIL: expected --fixture / --observe with explicit output and host identity; use --help.")
            Darwin.exit(1)
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            var report = Report(mode: fixtureMode ? "localFixture" : "naturalHostObservation")
            var rawObservation: (any ExternalObservation)?
            var external: ExternalInput?
            do {
                guard !FileManager.default.fileExists(atPath: output.appendingPathComponent("report.json").path),
                      !FileManager.default.fileExists(atPath: output.appendingPathComponent("ready.json").path) else {
                    throw Failure.existingEvidence
                }
                let base: any ExternalInputAccess
                let fixture: ExternalInputFixture?
                if fixtureMode {
                    let local = ExternalInputFixture()
                    local.text = sample
                    local.range = CFRange(location: 0, length: (sample as NSString).length)
                    base = local; fixture = local
                } else {
                    let system = SystemExternalInputAccess()
                    guard system.hasPermission else { throw Failure.permission }
                    guard let front = system.frontmost(), front.pid == Int32(value("--pid")!)!,
                          front.bundle == value("--host"), system.isRunning(front) else { throw Failure.wrongHost }
                    _ = try ExternalInput.Host.matching(front)
                    if front.bundle == "com.anthropic.claudefordesktop" {
                        guard ExternalReplacementCapabilities.approves(front) else { throw Failure.unsupportedBuild }
                    }
                    report.verifiedApplication = ApplicationIdentity(pid: front.pid, bundle: front.bundle,
                        version: front.version, build: front.build)
                    base = system; fixture = nil
                }
                let access = ReadCountingAccess(base)
                let capture = ExternalInput(access: access)
                external = capture
                let workflow = DraftWorkflow(host: capture, translator: ProbeTranslator())
                var armedAt: TimeInterval?
                var captureID: UUID?
                var pendingTrigger: String?
                var readsAtTrigger: Int?
                @MainActor func record(_ stream: String, _ name: String) {
                    guard let armedAt, report.events.count < 256 else { return }
                    report.events.append(Event(stream: stream, name: name,
                        milliseconds: (ProcessInfo.processInfo.systemUptime - armedAt) * 1000,
                        captureID: captureID, targetAvailable: capture.isTargetAvailable,
                        attributeReads: access.attributeReads, rangeReads: access.rangeReads))
                }
                capture.onObservedChange = { name in
                    guard report.armed else { return }
                    pendingTrigger = name
                    readsAtTrigger = access.attributeReads + access.rangeReads
                    if name == kAXValueChangedNotification {
                        report.valueNotificationObserved = true
                        report.captureValueNotificationObserved = true
                    }
                    record("capture", name)
                }
                capture.onChange = {
                    workflow.hostDidChange()
                    guard report.armed, !capture.isTargetAvailable, report.firstInvalidationTrigger == nil else { return }
                    report.firstInvalidationTrigger = pendingTrigger ?? "unattributedChange"
                    if let readsAtTrigger { report.callbackReadDelta = access.attributeReads + access.rangeReads - readsAtTrigger }
                    record("invalidation", report.firstInvalidationTrigger!)
                }
                try capture.captureFrontmost()
                guard let snapshot = capture.snapshot(), snapshot.selectedText == sample else { throw Failure.fixtureMismatch }
                captureID = snapshot.captureID
                workflow.captureSelection(); workflow.generate()
                let generatedBy = ProcessInfo.processInfo.systemUptime + 0.3
                while workflow.phase != .ready, ProcessInfo.processInfo.systemUptime < generatedBy {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard workflow.phase == .ready else { throw Failure.generation }
                if !fixtureMode {
                    guard let application = base.frontmost(), application.pid == report.verifiedApplication?.pid,
                          application.bundle == report.verifiedApplication?.bundle,
                          application.version == report.verifiedApplication?.version,
                          application.build == report.verifiedApplication?.build,
                          base.isRunning(application) else { throw Failure.wrongHost }
                    let appElement = base.applicationElement(application)
                    let window = try base.read(appElement, .focusedWindow, optional: false) as! AXUIElement
                    let input = try base.read(appElement, .focusedInput, optional: false) as! AXUIElement
                    guard base.owner(window) == application.pid, base.owner(input) == application.pid,
                          snapshot.identity.window == "\(application.pid):ax:\(CFHash(window))",
                          snapshot.identity.input == "\(application.pid):ax:\(CFHash(input))" else { throw Failure.wrongHost }
                    rawObservation = try base.observe(application: appElement, window: window, input: input,
                        pid: application.pid, requireSelectionEvents: false, receive: { name in
                            if report.armed, name == kAXValueChangedNotification {
                                report.valueNotificationObserved = true
                                report.independentObserverValueNotificationObserved = true
                            }
                            record("independentObserver", name)
                        })
                }
                guard capture.isTargetAvailable, workflow.phase == .ready else { throw Failure.generation }
                let originalOutput = workflow.output
                report.selectedTextMatchesSyntheticFixture = true
                report.armed = true
                armedAt = ProcessInfo.processInfo.systemUptime
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try save(["armed": true, "localTranslator": true, "syntheticAXBackend": fixtureMode,
                    "naturalHostBackend": !fixtureMode], to: output.appendingPathComponent("ready.json"))
                if let fixture, !idle {
                    fixture.emit("poll") // A valid poll must not be mistaken for the invalidation cause.
                    fixture.emit(kAXValueChangedNotification)
                } else if !fixtureMode {
                    // No state/snapshot reads here. Natural observer polling is recorded separately.
                    try await Task.sleep(for: .seconds(10))
                }
                report.phase = String(describing: workflow.phase)
                report.canCopy = workflow.canCopy
                report.outputRetained = workflow.output == originalOutput
                report.writeAttempts = access.writeAttempts
                report.independentValueInvalidation = report.firstInvalidationTrigger == kAXValueChangedNotification
                    && report.captureValueNotificationObserved && (fixtureMode || report.independentObserverValueNotificationObserved)
                    && report.callbackReadDelta == 0 && !capture.isTargetAvailable && workflow.phase == .blocked
                    && !workflow.canGenerate && workflow.canCopy && report.outputRetained && access.writeAttempts == 0
            } catch {
                switch error {
                case Failure.permission: report.error = "accessibilityPermissionRequired"
                case Failure.existingEvidence: report.error = "existingEvidence"
                case Failure.wrongHost: report.error = "wrongHostOrPID"
                case Failure.unsupportedBuild: report.error = "unsupportedHostBuild"
                case Failure.fixtureMismatch: report.error = "selectedFixtureMismatch"
                case Failure.generation: report.error = "localGenerationFailed"
                default: report.error = "captureOrObservationFailed"
                }
            }
            // Cleanup is not a host notification and must not become the recorded cause.
            external?.onObservedChange = nil
            external?.onChange = nil
            rawObservation?.stop(); external?.clear()
            do {
                if report.error != "existingEvidence" {
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try save(report, to: output.appendingPathComponent("report.json"))
                }
            } catch { print("FAIL: could not save probe evidence."); Darwin.exit(1) }
            print("\(report.mode): trigger=\(report.firstInvalidationTrigger ?? "none"), valueObserved=\(report.valueNotificationObserved), independentInvalidation=\(report.independentValueInvalidation)")
            Darwin.exit(report.error == nil && report.independentValueInvalidation ? 0 : 1)
        }
        app.run()
    }
    private static func save<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
    }
}
