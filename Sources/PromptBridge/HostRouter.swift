import AppKit
import DraftCore

@MainActor final class HostRouter: HostInput {
    #if PROMPTBRIDGE_TESTING
    let demo: DemoHost
    #endif
    let external: ExternalInput
    private(set) var isExternal = false
    private(set) var isManual = false
    private(set) var isCLI = false
    private var cliSource = ""
    private var cliIdentity = UUID()
    private var cliRevision: UInt64 = 0
    private var manualRevision: UInt64 = 0
    private var manualReturnTarget: NSRunningApplication?
    private var lastExternalFrame: NSRect?
    var onChange: (() -> Void)?
    var onGeometryChange: (() -> Void)?

    #if PROMPTBRIDGE_TESTING
    init(demo: DemoHost, external: ExternalInput = ExternalInput(client: .shared)) {
        self.external = external
        self.demo = demo
        observeExternal()
    }
    #else
    init(external: ExternalInput = ExternalInput(client: .shared)) {
        self.external = external
        isManual = true
        observeExternal()
    }
    #endif

    private func observeExternal() {
        external.onChange = { [weak self] in
            guard let self, self.isExternal else { return }
            self.onChange?()
        }
        external.onGeometryChange = { [weak self] in
            guard let self else { return }
            if let frame = self.external.frameOnScreen { self.lastExternalFrame = frame }
            if self.isExternal { self.onGeometryChange?() }
        }
    }

    var frameOnScreen: NSRect {
        if isManual || isCLI, let screen = NSScreen.main?.visibleFrame {
            return NSRect(x: screen.maxX - 16, y: screen.maxY - 24, width: 1, height: 1)
        }
        #if PROMPTBRIDGE_TESTING
        let fallback = demo.inputFrameOnScreen
        #else
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let fallback = NSRect(x: screen.maxX - 16, y: screen.maxY - 24, width: 1, height: 1)
        #endif
        return isExternal ? (external.frameOnScreen ?? lastExternalFrame ?? fallback) : fallback
    }

    var screenFrame: NSRect {
        let anchor = frameOnScreen
        return NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? .zero
    }

    var canShowPanel: Bool {
        #if PROMPTBRIDGE_TESTING
        isCLI || isManual || isExternal || (demo.window.isVisible && !demo.window.isMiniaturized)
        #else
        isCLI || isManual || isExternal
        #endif
    }

    func hideInactiveDemo() {
        #if PROMPTBRIDGE_TESTING
        if isCLI || isManual || isExternal { demo.window.orderOut(nil) }
        #endif
    }

    func captureExternal() async throws {
        // Invalidate the previous remote token before a new capture starts so a
        // late response cannot repopulate the old route.
        external.clear()
        isCLI = false
        try await external.captureFrontmost()
        isManual = false
        isExternal = true
        hideInactiveDemo()
        lastExternalFrame = external.frameOnScreen
        onChange?()
    }

    func captureExternalFullInput() async throws {
        isCLI = false
        external.clear()
        try await external.captureFullInput()
        try Task.checkCancellation()
        guard let snapshot = await external.liveSnapshot(), snapshot.captureScope == .entireInput else {
            throw ExternalInputError.invalidSelection
        }
        isManual = false
        isExternal = true
        hideInactiveDemo()
        lastExternalFrame = external.frameOnScreen
        onChange?()
    }

    #if PROMPTBRIDGE_TESTING
    @discardableResult func useDemo() -> Bool {
        guard isExternal || isManual || isCLI else { return false }
        isCLI = false
        isExternal = false
        isManual = false
        external.clear()
        onChange?()
        return true
    }

    #endif
    func useExternalDraft() {
        isCLI = false
        isExternal = false
        external.clear()
        isManual = false
        isExternal = true
        hideInactiveDemo()
        onChange?()
    }

    func returnFocus() async {
        if isCLI { return }
        if isManual { manualReturnTarget?.activate(options: []) }
        else if isExternal { _ = await external.returnFocus(allowInvalidTarget: true) }
        else {
            #if PROMPTBRIDGE_TESTING
            demo.window.makeKeyAndOrderFront(nil)
            demo.window.makeFirstResponder(demo.editor)
            #endif
        }
    }

    @discardableResult func useManual() -> Bool {
        isCLI = false
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != NSRunningApplication.current.processIdentifier {
            manualReturnTarget = app
        }
        guard !isManual else { return false }
        isExternal = false
        isManual = true
        hideInactiveDemo()
        manualRevision += 1
        external.clear()
        onChange?()
        return true
    }

    func snapshot() -> InputSnapshot? {
        if isCLI {
            return InputSnapshot(identity: InputIdentity(host: "CLI", window: "cli", input: "cli", session: cliIdentity.uuidString),
                revision: cliRevision, selection: NSRange(location: 0, length: cliSource.utf16.count),
                selectedText: cliSource, supportsDirectFill: false)
        }
        if isManual {
            return InputSnapshot(identity: InputIdentity(host: "手动输入", window: "manual", input: "manual", session: "manual"),
                revision: manualRevision, selection: NSRange(location: 0, length: 0), selectedText: "", supportsDirectFill: false)
        }
        #if PROMPTBRIDGE_TESTING
        return isExternal ? external.snapshot() : demo.snapshot()
        #else
        return isExternal ? external.snapshot() : nil
        #endif
    }

    func liveSnapshot() async -> InputSnapshot? {
        if isManual || isCLI { return snapshot() }
        #if PROMPTBRIDGE_TESTING
        return isExternal ? await external.liveSnapshot() : await demo.liveSnapshot()
        #else
        return isExternal ? await external.liveSnapshot() : nil
        #endif
    }

    func replaceSelection(with text: String, expected: InputSnapshot) async throws -> ReplacementReceipt {
        if isManual || isCLI { throw FillError.notEditable }
        if isExternal { return try await external.replaceSelection(with: text, expected: expected) }
        #if PROMPTBRIDGE_TESTING
        return try await demo.replaceSelection(with: text, expected: expected)
        #else
        throw FillError.notEditable
        #endif
    }

    func useCLI(_ source: String, id: UUID = UUID()) {
        isExternal = false
        isManual = false
        isCLI = true
        hideInactiveDemo()
        cliSource = source
        cliIdentity = id
        cliRevision &+= 1
        external.clear()
        onChange?()
    }
}
