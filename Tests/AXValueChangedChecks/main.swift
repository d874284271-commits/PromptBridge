import AppKit
import ApplicationServices
import DraftCore

/// Narrow local check: real AXObserver registration/delivery on our own NSTextView,
/// synthetic host identity/text reads, and the unchanged production capture/workflow.
/// No supported desktop application is activated or queried.
@MainActor private final class LocalObserverAccess: ExternalInputAccess {
    let fixture = ExternalInputFixture()
    let system = SystemExternalInputAccess()
    let nativeApplication: AXUIElement
    let nativeWindow: AXUIElement
    let nativeInput: AXUIElement
    var events: [String] = []
    var requiresSelectionEvents = false

    init(application: AXUIElement, window: AXUIElement, input: AXUIElement) {
        nativeApplication = application; nativeWindow = window; nativeInput = input
    }
    var hasPermission: Bool { fixture.hasPermission }
    var ownApplication: ExternalApplication { fixture.ownApplication }
    func frontmost() -> ExternalApplication? { fixture.frontmost() }
    func isRunning(_ application: ExternalApplication) -> Bool { fixture.isRunning(application) }
    func applicationElement(_ application: ExternalApplication) -> AXUIElement { fixture.applicationElement(application) }
    func owner(_ element: AXUIElement) -> pid_t? { fixture.owner(element) }
    func read(_ element: AXUIElement, _ attribute: ExternalAttribute, optional: Bool) throws -> CFTypeRef? {
        try fixture.read(element, attribute, optional: optional)
    }
    func isEditable(_ element: AXUIElement) -> Bool { fixture.isEditable(element) }
    func string(_ element: AXUIElement, for range: CFRange) throws -> String { try fixture.string(element, for: range) }
    func contextID(window: AXUIElement, input: AXUIElement) throws -> String? { try fixture.contextID(window: window, input: input) }
    func replacementCapabilities(application: ExternalApplication, window: AXUIElement,
                                 input: AXUIElement, host: ExternalInput.Host) -> ExternalReplacementCapabilities {
        fixture.replacementCapabilities(application: application, window: window, input: input, host: host)
    }
    func focus(window: AXUIElement, input: AXUIElement) async throws { try await fixture.focus(window: window, input: input) }
    func setSelectedRange(_ range: CFRange, in input: AXUIElement) throws { try fixture.setSelectedRange(range, in: input) }
    func writeFullText(_ text: String, to input: AXUIElement, validate: () throws -> Void) throws { try fixture.writeFullText(text, to: input, validate: validate) }
    func activate(_ application: ExternalApplication) -> Bool { fixture.activate(application) }
    func observe(application: AXUIElement, window: AXUIElement, input: AXUIElement,
                 pid: pid_t, requireSelectionEvents: Bool,
                 receive: @escaping @MainActor (String) -> Void) throws -> any ExternalObservation {
        requiresSelectionEvents = requireSelectionEvents
        // Register the actual production observer only against this check's own PID/control.
        return try system.observe(application: nativeApplication, window: nativeWindow,
            input: nativeInput, pid: getpid(), requireSelectionEvents: requireSelectionEvents,
            receive: { [weak self] name in
                self?.events.append(name)
                receive(name)
            })
    }
}

@MainActor private struct LocalTranslator: DraftTranslator {
    func generate(_ request: GenerationRequest) async throws -> String { "LOCAL SYNTHETIC RESULT" }
}

@main @MainActor private enum AXValueChangedChecks {
    private struct Check: Codable { let assertion: String; let passed: Bool }
    private struct Report: Codable {
        var checks: [Check] = []
        var events: [String: [String]] = [:]
        var failures: [String] = []
    }
    private enum Failure: Error { case assertion(String) }
    private static var report = Report()
    private static let sample = "LOCAL SYNTHETIC VALUE A"

    private static func check(_ condition: Bool, _ assertion: String) throws {
        report.checks.append(Check(assertion: assertion, passed: condition))
        if !condition { throw Failure.assertion(assertion) }
    }
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 360, height: 140),
            styleMask: [.titled], backing: .buffered, defer: false)
        let editor = NSTextView(frame: window.contentView!.bounds)
        editor.string = sample
        editor.setSelectedRange(NSRange(location: 0, length: (sample as NSString).length))
        window.contentView!.addSubview(editor)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(200))
                let system = SystemExternalInputAccess()
                let application = AXUIElementCreateApplication(getpid())
                let nativeWindow = try system.read(application, .focusedWindow, optional: false) as! AXUIElement
                let nativeInput = try system.read(application, .focusedInput, optional: false) as! AXUIElement
                try check(system.owner(nativeWindow) == getpid() && system.owner(nativeInput) == getpid(),
                          "native observer target belongs only to the local check process")
                try check(try system.read(nativeInput, .role, optional: false) as? String == "AXTextArea",
                          "native observer target is our synthetic NSTextView")
                for host in ["codex", "claude"] {
                    try await run(host: host, application: application, window: nativeWindow,
                                  input: nativeInput, editor: editor)
                }
            } catch { report.failures.append(String(describing: error)) }
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .atomic)
            } catch { report.failures.append(String(describing: error)) }
            print("\(report.checks.filter(\.passed).count)/\(report.checks.count) assertions; \(report.failures.count) failures")
            for failure in report.failures { print(failure) }
            window.orderOut(nil)
            Darwin.exit(report.failures.isEmpty ? 0 : 1)
        }
        app.run()
    }

    private static func run(host: String, application: AXUIElement, window: AXUIElement,
                            input: AXUIElement, editor: NSTextView) async throws {
        let access = LocalObserverAccess(application: application, window: window, input: input)
        if host == "claude" {
            access.fixture.application = ExternalApplication(pid: 7, bundle: "com.anthropic.claudefordesktop",
                version: "2.19675.0", build: "2.19675.0")
            access.fixture.foreground = access.fixture.application
        }
        access.fixture.text = sample
        access.fixture.range = CFRange(location: 0, length: (sample as NSString).length)
        let external = ExternalInput(access: access)
        let workflow = DraftWorkflow(host: external, translator: LocalTranslator())
        external.onChange = { workflow.hostDidChange() }
        defer { report.events[host] = access.events; external.clear() }
        try external.captureFrontmost()
        workflow.captureSelection()
        workflow.generate()
        let readyDeadline = Date().addingTimeInterval(0.3)
        while workflow.phase != .ready, Date() < readyDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try check(workflow.phase == .ready && workflow.canCopy && external.isTargetAvailable,
                  "\(host): capture and synthetic generation ready before value event")
        try check(access.requiresSelectionEvents == (host == "codex"),
                  "\(host): production observer uses existing required-notification policy")
        let range = editor.selectedRange()
        // Restore the synthetic read boundary before posting the native value event.
        // Mutating NSTextStorage itself also posts a selection notification, which
        // would mask the value path. The native control remains untouched here.
        access.fixture.text = "LOCAL SYNTHETIC VALUE B"
        access.fixture.text = sample
        try await Task.sleep(for: .milliseconds(80))
        try check(editor.string == sample && editor.selectedRange() == range && access.events.isEmpty
                  && external.isTargetAvailable,
                  "\(host): ABA preserves text/selection/focus and has no competing notification or poll")
        let reads = access.fixture.reads.count
        let rangeReads = access.fixture.rangeReads
        let output = workflow.output
        let started = Date()
        NSAccessibility.post(element: editor, notification: .valueChanged)
        let deadline = started.addingTimeInterval(0.4)
        while external.isTargetAvailable, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try check(access.events == [kAXValueChangedNotification],
                  "\(host): real AXObserver delivers isolated AXValueChanged as the sole trigger")
        try check(!external.isTargetAvailable && Date().timeIntervalSince(started) < 0.4,
                  "\(host): value callback invalidates before the one-second poll and any snapshot query")
        try check(workflow.phase == .blocked && !workflow.canGenerate && workflow.canCopy && workflow.output == output,
                  "\(host): value event blocks generation and retains the copyable result")
        try check(access.fixture.reads.count == reads && access.fixture.rangeReads == rangeReads,
                  "\(host): invalidation callback performs no AX attribute or range reads")
        try check(external.snapshot() == nil && access.fixture.reads.count == reads
                  && access.fixture.rangeReads == rangeReads && access.fixture.writeCount == 0,
                  "\(host): invalidated capture stays unavailable with zero further reads or host writes")
    }
}
