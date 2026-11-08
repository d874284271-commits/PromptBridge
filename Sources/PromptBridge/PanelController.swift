import AppKit
import Combine
import DraftCore
import SwiftUI

private final class InputPanel: NSPanel {
    var generate: (() -> Void)?
    var userInteraction: (() -> Void)?
    var collapse: (() -> Void)?
    var isComposing: (() -> Bool)?
    var acceptsKeyboardFocus = false
    var beginContextMenu: (() -> (() -> Void)?)?
    var acquireContextMenu: (() async throws -> UUID?)?
    var releaseContextMenu: ((UUID) async -> Void)?
    var contextMenuDidEnd: (() -> Void)?
    private struct MenuScope { let endTarget: (() -> Void)? }
    private var menuScopes: [UUID: MenuScope] = [:]
    private var launcherMouseDown = false
    private var launcherDragged = false
    private var launcherMouseDownPoint: NSPoint?
    private var asyncMenuRequestID = UUID()
    var allowsLauncherClick: Bool { !launcherDragged }
    var contextMenuDepth: Int { menuScopes.count }
    override var canBecomeKey: Bool { acceptsKeyboardFocus }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .keyDown { userInteraction?() }
        let rightClick = event.type == .rightMouseDown || event.type == .rightMouseUp
        let controlClick = (event.type == .leftMouseDown || event.type == .leftMouseUp)
            && event.modifierFlags.contains(.control)
        if !acceptsKeyboardFocus && event.type == .leftMouseDown && !controlClick {
            launcherMouseDown = true
            launcherDragged = false
            launcherMouseDownPoint = convertPoint(toScreen: event.locationInWindow)
        } else if launcherMouseDown, event.type == .leftMouseDragged || event.type == .leftMouseUp,
                  let start = launcherMouseDownPoint {
            let point = convertPoint(toScreen: event.locationInWindow)
            let dx = point.x - start.x, dy = point.y - start.y
            if dx * dx + dy * dy >= 16 { launcherDragged = true }
        }
        defer {
            if event.type == .leftMouseUp || rightClick || controlClick {
                launcherMouseDown = false
                launcherMouseDownPoint = nil
            }
        }
        if (rightClick || controlClick) && !acceptsKeyboardFocus {
            trackContextMenuAsync(event)
        } else { super.sendEvent(event) }
    }

    func launcherWindowDidMove() {
        // Native window dragging and SwiftUI button tracking can share the same
        // mouse gesture. Keep the cancellation until the next mouse-down: the
        // button action may arrive after AppKit has dispatched mouse-up.
        if launcherMouseDown { launcherDragged = true }
    }

    func trackContextMenu(_ dispatch: () -> Void) {
        // Keep the launcher visible for the complete native popup dispatch,
        // including menus opened before any external draft has been captured.
        let scope = beginMenuTracking()
        defer { endMenuTracking(scope) }
        dispatch()
    }

    private func trackContextMenuAsync(_ event: NSEvent) {
        let requestID = UUID()
        asyncMenuRequestID = requestID
        Task { @MainActor [weak self] in
            guard let self else { return }
            let localScope = beginLocalMenuTracking()
            defer { endLocalMenuTracking(localScope) }
            do {
                let brokerScope = try await acquireContextMenu?()
                guard self.asyncMenuRequestID == requestID else {
                    if let brokerScope { await releaseContextMenu?(brokerScope) }
                    return
                }
                self.dispatchNativeEvent(event)
                if let brokerScope { await releaseContextMenu?(brokerScope) }
            } catch {
                // A late or rejected scope must not redispatch the native event.
            }
        }
    }

    private func dispatchNativeEvent(_ event: NSEvent) {
        super.sendEvent(event)
    }

    func beginLocalMenuTracking() -> UUID {
        let scope = UUID()
        menuScopes[scope] = MenuScope(endTarget: nil)
        return scope
    }

    func endLocalMenuTracking(_ scope: UUID) {
        guard menuScopes.removeValue(forKey: scope) != nil else { return }
        if menuScopes.isEmpty { contextMenuDidEnd?() }
    }

    func beginMenuTracking() -> UUID {
        let scope = UUID()
        menuScopes[scope] = MenuScope(endTarget: beginContextMenu?())
        return scope
    }

    func endMenuTracking(_ scope: UUID) {
        guard let retained = menuScopes.removeValue(forKey: scope) else { return }
        retained.endTarget?()
        if menuScopes.isEmpty { contextMenuDidEnd?() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 36 && modifiers == .command {
            if isComposing?() != true && (firstResponder as? NSTextView)?.hasMarkedText() != true { generate?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if isComposing?() != true && (firstResponder as? NSTextView)?.hasMarkedText() != true { collapse?() }
    }
}

private final class LauncherHostingView: NSHostingView<CollapsedView> {
    override var needsPanelToBecomeKey: Bool { false }
}

@MainActor final class PanelPresentation: ObservableObject {
    @Published var capturing = false
    @Published var automaticRunning = false
    @Published var automaticMessage = ""
    @Published var cliReadStatus = false
    @Published var cliChecking = false
    @Published var captureFailure: String?
    @Published var failureKind: PanelFailureKind = .capture(nil)
    var failureDocumentID: UUID?
    @Published var copiedDocumentID: UUID?
    @Published var copyError: String?
    @Published var successMessage: String?
    @Published var returning = false
    @Published var availableHeight: CGFloat = 680
    @Published var restoreMessage: String?
    @Published var languagePending = false
    @Published var languageInput = ""
    @Published var languageError: String?
    @Published var languageIsComposing = false
}

@MainActor final class PanelController: NSObject, NSWindowDelegate {
    private let panel: InputPanel
    private let workflow: DraftWorkflow
    let cliEditor: CLIEditorSession
    let cliConnection = CLIConnectionController.shared
    private let host: HostRouter
    private let settings: TranslationSettings
    private let openSettings: () -> Void
    private let openCLISettings: () -> Void
    private let openManual: () -> Void
    private let continueManual: () -> Void
    private let openSavedEntry: (DraftEntry) -> Void
    private let openExternalHelp: () -> Void
    private let pasteboard: NSPasteboard
    private let captureFullInput: @MainActor () async throws -> Void
    private let terminalIsFrontmost: @MainActor () -> Bool
    private let readCLI: @MainActor (CLIEditorSession) async -> Void
    private var captureTask: Task<Void, Never>?
    private var cliReadTask: Task<Void, Never>?
    private enum AutomaticRun {
        case waitingCLI
        case generating(documentID: UUID, sourceRevision: UInt64, requestID: UUID?)
        case committing(requestID: UUID?)
    }
    private var automaticRun: AutomaticRun?
    private var observations: Set<AnyCancellable> = []
    private var captureRequestID = UUID()
    private var restoreRequestID = UUID()
    private var statusMenuScope: UUID?
    private var statusMenuLocalScope: UUID?
    private struct StatusMenuNestedScope { let broker: UUID?; let local: UUID }
    private var statusMenuNestedScopes: [StatusMenuNestedScope] = []
    private var openRequestID = UUID()
    private var launcherHidden = false
    private var launcherMode: LauncherMode = .persistent
    private var focusState: FocusLauncherState = .unavailable
    private var focusedAnchor: NSRect?
    private let presentation = PanelPresentation()
    private var expanded = false
    private var expandedContent: NSView?
    private var settingsVisible = false
    private var desiredHeight: CGFloat = 350
    private var positioning = false
    private var userTopLeft: NSPoint?
    private weak var previousResponder: NSResponder?
    private weak var lastEditor: NSTextView?
    private struct RegisteredEditor { weak var view: NSTextView?; let documentID: UUID }
    private struct FocusMemory { let role: EditorRole; let documentID: UUID; let selection: NSRange }
    private var editors: [EditorRole: RegisteredEditor] = [:]
    private var focusMemory: [UUID: FocusMemory] = [:]
    private var interactionRevision: UInt64 = 0
    private var outputFocusRequest: (document: UUID, revision: UInt64, interaction: UInt64, responder: NSResponder?)?
    private var copyFeedbackTask: Task<Void, Never>?
    private var successFeedbackTask: Task<Void, Never>?
    private var previousSourceDocumentID: UUID?
    private(set) var hasBeenPresented = false
    var onCopyReturn: ((Bool) -> Void)?
    var onHostRestore: ((Bool) -> Void)?
    var externalCapturing = false
    private var localCompositionActive: Bool {
        presentation.languageIsComposing || workflow.sourceIsComposing || workflow.outputIsComposing
            || (panel.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
    private var operationInProgress: Bool { presentation.automaticRunning || externalCapturing || presentation.capturing || presentation.cliChecking || presentation.returning || workflow.phase == .filling || localCompositionActive || cliEditor.finishing || cliEditor.awaitingDraft || cliEditor.readIntent != nil }
    var canChangeInstallation: Bool { !operationInProgress && !cliEditor.active && workflow.phase != .translating }
    var isBusy: Bool { operationInProgress || DesktopInstallation.shared.busy }
    var cliReceptionBusy: Bool { DesktopInstallation.shared.busy || externalCapturing || presentation.capturing || presentation.returning || workflow.phase == .filling || localCompositionActive || cliEditor.finishing }
    var blocksEntrySwitch: Bool { isBusy || cliEditor.active }
    #if PROMPTBRIDGE_TESTING
    // Only the explicitly launched UI acceptance runner sets this fixture.
    var uiTestScreenFrame: NSRect?
    var uiTestWindow: NSPanel { panel }
    var uiTestContextMenuTracking: Bool { panel.contextMenuDepth > 0 }
    func uiTestDuringContextMenu(_ action: () -> Void) { panel.trackContextMenu(action) }
    func uiTestDuringAsyncContextMenu(_ action: @escaping () async -> Void) async {
        let scope = panel.beginLocalMenuTracking()
        await action()
        panel.endLocalMenuTracking(scope)
    }
    var uiTestFocusState: String {
        switch focusState { case .target: "target"; case .ownApplication: "self"; case .unavailable: "unavailable" }
    }
    var uiTestClipboardString: String? { pasteboard.string(forType: .string) }
    func uiTestSetClipboard(_ text: String) { pasteboard.clearContents(); pasteboard.setString(text, forType: .string) }
    func uiTestSetLargeEditor(_ value: Bool) {}
    func uiTestEditor(_ role: EditorRole) -> NSTextView? { editors[role]?.view }
    var uiTestDisplayState: PanelDisplayState {
        PanelDisplayState(workflow: workflow, settings: settings, presentation: presentation,
                          cliEditor: cliEditor, canReturn: host.external.canReturnFocus)
    }
    func uiTestGenerate() { generateCurrentDraft() }

    #else
    private let uiTestScreenFrame: NSRect? = nil
    #endif

    init(workflow: DraftWorkflow, host: HostRouter, settings: TranslationSettings,
         openSettings: @escaping () -> Void, openManual: @escaping () -> Void,
         continueManual: @escaping () -> Void = {}, openSavedEntry: @escaping (DraftEntry) -> Void = { _ in },
         openExternalHelp: @escaping () -> Void, pasteboard: NSPasteboard = .general,
         captureFullInput: (@MainActor () async throws -> Void)? = nil,
         openCLISettings: (() -> Void)? = nil,
         terminalIsFrontmost: @escaping @MainActor () -> Bool = {
             NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal"
         },
         readCLI: (@MainActor (CLIEditorSession) async -> Void)? = nil,
         cliIdentityVerifier: @escaping (CLIEditorPreflight) -> Bool = CLIEditorSession.validateIdentity) {
        self.workflow = workflow
        self.cliEditor = CLIEditorSession(workflow: workflow, host: host, verifyIdentity: cliIdentityVerifier)
        self.host = host
        self.settings = settings
        self.openSettings = openSettings
        self.openCLISettings = openCLISettings ?? openSettings
        self.openManual = openManual
        self.continueManual = continueManual
        self.openSavedEntry = openSavedEntry
        self.openExternalHelp = openExternalHelp
        self.pasteboard = pasteboard
        self.captureFullInput = captureFullInput ?? { try await host.captureExternalFullInput() }
        self.terminalIsFrontmost = terminalIsFrontmost
        self.readCLI = readCLI ?? { await CLIConnectionController.shared.read(using: $0) }
        panel = InputPanel(contentRect: .zero, styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        panel.title = "PromptBridge · 翻译浮窗"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications]
        panel.delegate = self
        panel.isComposing = { [weak workflow, weak presentation = self.presentation] in
            workflow?.canSwitchDraft == false || presentation?.returning == true || presentation?.capturing == true || presentation?.languageIsComposing == true
        }
        panel.userInteraction = { [weak self] in self?.interactionRevision &+= 1 }
        panel.generate = { [weak self] in self?.generateCurrentDraft() }
        panel.collapse = { [weak self] in self?.collapse() }
        panel.beginContextMenu = { [weak self] in
            guard let self, !self.localCompositionActive else { return nil }
            // Synchronous menu tracking is retained for local UI fixtures only.
            // Production external menus use acquireContextMenu below.
            return nil
        }
        panel.acquireContextMenu = { [weak self] in
            guard let self else { return nil }
            guard !self.localCompositionActive else { return nil }
            guard self.host.isExternal else { return nil }
            let hadTarget = self.host.external.hasTarget
            let hadRestoration = self.host.external.canRestoreOriginal
            let expectedCaptureID = self.host.external.captureID
            if !self.host.external.isBrokerConnected && !hadTarget && !hadRestoration { return nil }
            do {
                let receipt = try await self.host.external.beginPanelContextMenu()
                guard !hadTarget || self.host.external.captureID == expectedCaptureID else {
                    await self.host.external.endPanelContextMenu(receipt.scopeID)
                    return nil
                }
                return receipt.scopeID
            } catch {
                // An external draft with no live target or restoration receipt
                // can use the local native menu after broker disconnect.
                guard !self.host.external.isBrokerConnected
                    && !self.host.external.hasTarget && !self.host.external.canRestoreOriginal else {
                    throw error
                }
                return nil
            }
        }
        panel.releaseContextMenu = { [weak self] scopeID in
            guard let self else { return }
            await self.host.external.endPanelContextMenu(scopeID)
        }
        panel.contextMenuDidEnd = { [weak self] in self?.refreshLauncherVisibility() }
        cliEditor.onDraftReady = { [weak self] in self?.cliDraftReady() }
        workflow.$phase.sink { [weak self] phase in
            // Published emits before assignment; evaluate the completed state on the next turn.
            Task { @MainActor [weak self] in
                guard let self, self.workflow.phase == phase else { return }
                self.advanceAutomaticRun()
                if phase == .ready { self.focusGeneratedOutputIfUninterrupted() }
                if phase == .filled && self.workflow.isExternalSelection {
                    self.showSuccess("已替换 · 未发送")
                    self.showCollapsed(explicit: false)
                }
            }
        }.store(in: &observations)
        workflow.$sourceDocumentID.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.presentation.failureDocumentID != self.workflow.sourceDocumentID {
                    self.presentation.captureFailure = nil
                    self.presentation.restoreMessage = nil
                }
                self.presentation.copiedDocumentID = nil
                self.presentation.copyError = nil
                self.presentation.successMessage = nil
            }
        }.store(in: &observations)
        settings.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.settings.canGenerate,
                      case .configuration = self.presentation.failureKind else { return }
                self.presentation.captureFailure = nil
            }
        }.store(in: &observations)
        cliEditor.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.refreshAutomaticCLI() }
        }.store(in: &observations)
    }

    private func setAutomaticRun(_ run: AutomaticRun?, message: String = "") {
        automaticRun = run
        presentation.automaticRunning = run != nil
        presentation.automaticMessage = message
    }

    private func cliDraftReady() {
        if case .waitingCLI = automaticRun {
            startAutomaticGeneration(requestID: cliEditor.requestID)
        } else {
            Task { await open() }
        }
    }

    private func startAutomaticGeneration(requestID: UUID?) {
        guard settings.preferences.automaticTranslationAndReplacement, settings.canGenerate, workflow.canGenerate else {
            failAutomatic("无法开始自动翻译；请检查模型配置和当前文字。")
            return
        }
        setAutomaticRun(.generating(documentID: workflow.sourceDocumentID,
            sourceRevision: workflow.sourceRevision, requestID: requestID), message: "正在翻译…")
        presentation.cliReadStatus = false
        showCollapsed(explicit: false)
        workflow.generate()
    }

    private func advanceAutomaticRun() {
        switch automaticRun {
        case .generating(let documentID, let revision, let requestID):
            guard workflow.sourceDocumentID == documentID, workflow.sourceRevision == revision,
                  settings.preferences.automaticTranslationAndReplacement,
                  requestID == nil ? !host.isCLI : (host.isCLI && cliEditor.requestID == requestID && cliEditor.active) else {
                failAutomatic("本次稿件或 Auto 设置已变化，自动替换已停止。")
                return
            }
            switch workflow.phase {
            case .ready:
                if let requestID {
                    guard cliEditor.canSave else { failAutomatic("当前 CLI 结果无法写回，请查看交接状态或复制结果。"); return }
                    setAutomaticRun(.committing(requestID: requestID), message: "正在保存并返回 CLI…")
                    cliEditor.save()
                } else {
                    guard workflow.isFullInputCapture, workflow.canFill else {
                        failAutomatic("当前输入框无法自动替换，结果已保留，可复制或重新读取。")
                        return
                    }
                    setAutomaticRun(.committing(requestID: nil), message: "正在替换原文…")
                    workflow.fill()
                }
            case .idle, .blocked, .failed: failAutomatic(workflow.message)
            default: break
            }
        case .committing(let requestID) where requestID == nil:
            if workflow.phase == .filled {
                setAutomaticRun(nil)
                showCollapsed(explicit: false)
            } else if workflow.phase != .filling { failAutomatic(workflow.message) }
        default: break
        }
    }

    private func refreshAutomaticCLI() {
        if case .waitingCLI = automaticRun, cliEditor.needsConsent {
            // A request arriving after the read deadline requires a new click.
            setAutomaticRun(nil)
            showCollapsed(explicit: false)
        } else if case .waitingCLI = automaticRun,
           !presentation.cliChecking, !cliEditor.active, cliEditor.readIntent == nil {
            setAutomaticRun(nil)
            showCLIReadStatus()
        } else if case .committing(let requestID) = automaticRun, requestID != nil, !cliEditor.active {
            setAutomaticRun(nil)
            if cliEditor.outcome?.status == .saved {
                showSuccess("已替换 · 未发送")
                showCollapsed(explicit: false)
            } else { showCaptureFailure(cliEditor.message ?? "CLI 交接失败；结果已保留。") }
        } else if case .generating(_, _, let requestID) = automaticRun, requestID != nil,
                  !cliEditor.active || cliEditor.finishing {
            workflow.cancel()
            failAutomatic(cliEditor.message ?? "CLI 编辑已结束，自动替换已停止。")
        }
    }

    private func failAutomatic(_ message: String) {
        setAutomaticRun(nil)
        showCaptureFailure(message)
    }

    private func cancelAutomaticRun() {
        guard automaticRun != nil else { return }
        if case .committing = automaticRun { return }
        setAutomaticRun(nil)
        cliReadTask?.cancel()
        cliReadTask = nil
        cliEditor.cancel()
        workflow.cancel()
    }

    func beginStatusMenuTracking() async throws -> UUID? {
        if statusMenuScope != nil, statusMenuLocalScope != nil {
            let local = panel.beginLocalMenuTracking()
            do {
                let broker: UUID?
                if host.isExternal {
                    let hadTarget = host.external.hasTarget
                    let hadRestoration = host.external.canRestoreOriginal
                    let expectedCaptureID = host.external.captureID
                    if !host.external.isBrokerConnected && !hadTarget && !hadRestoration {
                        broker = nil
                    } else { do {
                        let receipt = try await host.external.beginPanelContextMenu()
                        guard !hadTarget || host.external.captureID == expectedCaptureID else {
                            await host.external.endPanelContextMenu(receipt.scopeID)
                            panel.endLocalMenuTracking(local)
                            return nil
                        }
                        broker = receipt.scopeID
                    } catch {
                        guard !host.external.isBrokerConnected
                            && !host.external.hasTarget && !host.external.canRestoreOriginal else {
                            panel.endLocalMenuTracking(local)
                            throw error
                        }
                        broker = nil
                    } }
                } else { broker = nil }
                statusMenuNestedScopes.append(StatusMenuNestedScope(broker: broker, local: local))
                return broker ?? local
            } catch {
                panel.endLocalMenuTracking(local)
                throw error
            }
        }
        guard statusMenuScope == nil, statusMenuLocalScope == nil else { return nil }
        let local = panel.beginLocalMenuTracking()
        statusMenuLocalScope = local
        let hadTarget = host.isExternal && host.external.hasTarget
        let hadRestoration = host.isExternal && host.external.canRestoreOriginal
        let expectedCaptureID = host.external.captureID
        do {
            if host.isExternal {
                if !host.external.isBrokerConnected && !hadTarget && !hadRestoration {
                    statusMenuScope = local
                    return local
                }
                do {
                    let receipt = try await host.external.beginPanelContextMenu()
                    guard !hadTarget || host.external.captureID == expectedCaptureID else {
                        await host.external.endPanelContextMenu(receipt.scopeID)
                        panel.endLocalMenuTracking(local)
                        statusMenuLocalScope = nil
                        return nil
                    }
                    statusMenuScope = receipt.scopeID
                    return receipt.scopeID
                } catch {
                    guard !host.external.isBrokerConnected
                        && !host.external.hasTarget && !host.external.canRestoreOriginal else {
                        panel.endLocalMenuTracking(local)
                        statusMenuLocalScope = nil
                        throw error
                    }
                    statusMenuScope = local
                    return local
                }
            }
            statusMenuScope = local
            return local
        } catch {
            panel.endLocalMenuTracking(local)
            statusMenuLocalScope = nil
            throw error
        }
    }

    /// Synchronous fixture compatibility path. Production status-menu actions
    /// use the async overload above so a broker scope is acquired first.
    func beginStatusMenuTracking() {
        if statusMenuScope != nil, statusMenuLocalScope != nil {
            let local = panel.beginMenuTracking()
            statusMenuNestedScopes.append(StatusMenuNestedScope(broker: nil, local: local))
            return
        }
        guard statusMenuScope == nil, statusMenuLocalScope == nil else { return }
        let local = panel.beginMenuTracking()
        statusMenuLocalScope = local
        statusMenuScope = local
    }

    func endStatusMenuTracking() async {
        if let nested = statusMenuNestedScopes.popLast() {
            if let broker = nested.broker, host.isExternal { await host.external.endPanelContextMenu(broker) }
            panel.endLocalMenuTracking(nested.local)
            return
        }
        guard let scope = statusMenuScope else { return }
        statusMenuScope = nil
        if host.isExternal { await host.external.endPanelContextMenu(scope) }
        if let local = statusMenuLocalScope {
            statusMenuLocalScope = nil
            panel.endLocalMenuTracking(local)
        }
    }

    func endStatusMenuTracking() {
        if let nested = statusMenuNestedScopes.popLast() {
            panel.endMenuTracking(nested.local)
            return
        }
        guard let scope = statusMenuScope else { return }
        statusMenuScope = nil
        if let local = statusMenuLocalScope {
            statusMenuLocalScope = nil
            panel.endMenuTracking(local)
        } else {
            panel.endMenuTracking(scope)
        }
    }

    func open() async {
        let requestID = UUID()
        openRequestID = requestID
        await open(requestID: requestID)
    }

    private func open(requestID: UUID) async {
        guard automaticRun == nil, !presentation.returning, !presentation.capturing, !localCompositionActive else { return }
        host.hideInactiveDemo()
        var panelScope: UUID?
        let hadTarget = host.isExternal && host.external.hasTarget
        let hadRestoration = host.isExternal && host.external.canRestoreOriginal
        let expectedCaptureID = host.external.captureID
        if host.isExternal && (hadTarget || hadRestoration) {
            do {
                panelScope = try await host.external.prepareForPanelActivation().scopeID
            } catch {
                return
            }
            guard self.openRequestID == requestID, host.isExternal,
                  host.external.captureID == expectedCaptureID else {
                if let panelScope { await host.external.endPanelContextMenu(panelScope) }
                return
            }
        }
        launcherHidden = false
        hasBeenPresented = true
        await workflow.prepareForOpening()
        guard self.openRequestID == requestID,
              !host.isExternal || (!hadTarget && !hadRestoration)
                  || host.external.captureID == expectedCaptureID else {
            if let panelScope { await host.external.endPanelContextMenu(panelScope) }
            return
        }
        presentation.cliReadStatus = false
        expandContent()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        restoreEditorFocus()
        if let panelScope { await host.external.endPanelContextMenu(panelScope) }
    }

    private func registerEditor(_ role: EditorRole, documentID: UUID, editor: NSTextView?) {
        if let editor { editors[role] = RegisteredEditor(view: editor, documentID: documentID) }
        else if editors[role]?.documentID == documentID { editors.removeValue(forKey: role) }
    }

    private func rememberEditorFocus(_ editor: NSTextView) {
        guard panel.firstResponder === editor,
              let match = editors.first(where: { $0.value.view === editor }) else { return }
        lastEditor = editor
        focusMemory[workflow.sourceDocumentID] = FocusMemory(role: match.key,
            documentID: match.value.documentID, selection: editor.selectedRange())
    }

    private func restoreEditorFocus() {
        let memory = focusMemory[workflow.sourceDocumentID]
        let role = memory?.role ?? (workflow.hasOutputEditor && workflow.resultValidity == .current ? .output : .source)
        guard let registered = editors[role], let editor = registered.view,
              registered.documentID == (role == .source ? workflow.sourceDocumentID : workflow.outputDocumentID),
              !localCompositionActive else { return }
        panel.makeFirstResponder(editor)
        if let memory, memory.documentID == registered.documentID,
           NSMaxRange(memory.selection) <= (editor.string as NSString).length {
            editor.setSelectedRange(memory.selection)
        }
    }

    private func focusGeneratedOutputIfUninterrupted() {
        guard let request = outputFocusRequest else { return }
        outputFocusRequest = nil
        guard automaticRun == nil, expanded, panel.isKeyWindow, !settingsVisible,
              request.document == workflow.sourceDocumentID, request.revision == workflow.sourceRevision,
              request.interaction == interactionRevision, panel.firstResponder === request.responder, !localCompositionActive else { return }
        // SwiftUI installs the new result editor after the workflow notification.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.panel.isKeyWindow, self.expanded, !self.settingsVisible,
                  request.document == self.workflow.sourceDocumentID,
                  request.revision == self.workflow.sourceRevision,
                  request.interaction == self.interactionRevision, self.panel.firstResponder === request.responder,
                  self.workflow.phase == .ready, !self.localCompositionActive,
                  let result = self.editors[.output], result.documentID == self.workflow.outputDocumentID,
                  let editor = result.view else { return }
            self.panel.makeFirstResponder(editor)
        }
    }

    private func showSuccess(_ message: String) {
        successFeedbackTask?.cancel()
        presentation.successMessage = message
        let document = workflow.sourceDocumentID
        successFeedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.workflow.sourceDocumentID == document else { return }
            self.presentation.successMessage = nil
        }
    }

    private func expandContent() {
        expanded = true
        panel.acceptsKeyboardFocus = true
        if expandedContent == nil {
            let content = NSHostingView(rootView: PanelView(workflow: workflow, settings: settings,
                presentation: presentation, cliEditor: cliEditor,
                acceptPendingCLI: { [weak self] in self?.acceptPendingCLIDraft() },
                importCLI: { [weak self] in Task { await self?.importCLIDraft() } },
                openSettings: openSettings, openCLISettings: openCLISettings, openManual: openManual,
                continueManual: continueManual, openSavedEntry: openSavedEntry,
                openExternalHelp: openExternalHelp,
                reread: { [weak self] in self?.returnToInput() },
                collapse: { [weak self] in self?.collapse() },
                copy: { [weak self] in self?.copyOutputOnly() },
                copyAndReturn: { [weak self] in self?.copyOutputAndReturn() },
                fill: { [weak self] in self?.fillCurrentDraft() },
                canRestoreHost: { [weak host] in host?.external.canRestoreOriginal == true },
                restoreHost: { [weak self] in self?.restoreHostOriginal() },
                copyRecord: { [weak self] text in self?.copyRecoveryText(text) },
                applyLanguage: { [weak self] in self?.applyLanguage() },
                generate: { [weak self] in self?.generateCurrentDraft() },
                recordEditorFocus: { [weak self] editor in self?.rememberEditorFocus(editor) },
                registerEditor: { [weak self] role, document, editor in self?.registerEditor(role, documentID: document, editor: editor) },
                canReturnToHost: { [weak self] in self?.host.external.canReturnFocus == true },
                resetPosition: { [weak self] in self?.resetPosition() },
                resize: { [weak self] height in
                    guard let self else { return }
                    self.desiredHeight = height
                    if self.expanded { self.position() }
                }))
            content.sizingOptions = []
            expandedContent = content
        }
        panel.contentView = expandedContent
        position()
    }

    func showCaptureFailure(_ message: String, kind: PanelFailureKind = .capture(nil)) {
        hasBeenPresented = true
        presentation.cliReadStatus = false
        presentation.captureFailure = message
        presentation.failureKind = kind
        presentation.failureDocumentID = workflow.sourceDocumentID
        guard !launcherHidden, !settingsVisible else { return }
        expandContent()
        // Display recovery without activating the app or taking the host's keyboard focus.
        panel.orderFrontRegardless()
    }

    func showCollapsed(explicit: Bool = true) {
        if cliEditor.active && !cliEditor.needsConsent && automaticRun == nil { return }
        guard !localCompositionActive else { return }
        if explicit { launcherHidden = false }
        hasBeenPresented = true
        expanded = false
        panel.acceptsKeyboardFocus = false
        let content = LauncherHostingView(rootView: CollapsedView(workflow: workflow, settings: settings, presentation: presentation, cliEditor: cliEditor, cliConnection: cliConnection,
            readAndTranslate: { [weak self] in self?.readFromLauncher() },
            allowsClick: { [weak panel] in panel?.allowsLauncherClick == true },
            open: { [weak self] in Task { await self?.open() } }, openManual: openManual,
            hide: { [weak self] in self?.hideLauncher() }))
        content.sizingOptions = []
        panel.contentView = content
        position()
        if !launcherHidden && !settingsVisible { panel.orderFrontRegardless() }
        refreshLauncherVisibility()
    }

    func readFromLauncher() {
        guard !DesktopInstallation.shared.busy else { return }
        if cliEditor.needsConsent {
            acceptPendingCLIDraft()
            return
        }
        if terminalIsFrontmost() {
            guard !blocksEntrySwitch, workflow.allowDraftSwitch() else { return }
            if settings.preferences.automaticTranslationAndReplacement {
                guard settings.canGenerate else { showCaptureFailure("模型配置尚未就绪，请先打开设置。", kind: .configuration); return }
                setAutomaticRun(.waitingCLI, message: "正在读取 CLI 草稿…")
            }
            presentation.cliChecking = true
            // Locate the Terminal target from nonactivating feedback before triggering once.
            if automaticRun != nil { showCollapsed() } else { showCLIReadStatus() }
            cliReadTask = Task {
                await readCLI(cliEditor)
                presentation.cliChecking = false
                cliReadTask = nil
                refreshAutomaticCLI()
            }
        } else { readAndTranslate() }
    }

    func acceptPendingCLIDraft() {
        guard cliEditor.needsConsent, !cliEditor.finishing,
              automaticRun == nil, !localCompositionActive else { return }
        if settings.preferences.automaticTranslationAndReplacement {
            guard settings.canGenerate else { showCaptureFailure("模型配置尚未就绪，请先打开设置。", kind: .configuration); return }
            setAutomaticRun(.waitingCLI, message: "正在读取 CLI 草稿…")
            showCollapsed()
        } else { showCLIReadStatus() }
        cliEditor.acceptPending()
    }

    private func showCLIReadStatus() {
        launcherHidden = false
        hasBeenPresented = true
        presentation.captureFailure = nil
        presentation.cliReadStatus = true
        expandContent()
        // The Terminal target must retain keyboard focus through the editor trigger.
        // This page also works independently of a previous desktop capture/broker.
        panel.orderFrontRegardless()
    }

    func readAndTranslate() {
        guard !DesktopInstallation.shared.busy else { return }
        guard !blocksEntrySwitch, workflow.allowDraftSwitch() else { return }
        launcherHidden = false
        guard settings.canGenerate else { showCaptureFailure("模型配置尚未就绪，请先打开设置。", kind: .configuration); return }
        presentation.captureFailure = nil
        presentation.restoreMessage = nil
        presentation.successMessage = nil
        let request = UUID()
        captureRequestID = request
        presentation.capturing = true
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard await self.workflow.prepareForEntrySwitch() else {
                    if self.captureRequestID == request {
                        self.captureTask = nil
                        self.presentation.capturing = false
                    }
                    return
                }
                try await self.captureFullInput()
                try Task.checkCancellation()
                guard self.captureRequestID == request else { return }
                await self.workflow.captureSelection()
                try Task.checkCancellation()
                guard self.captureRequestID == request else { return }
                self.captureTask = nil
                self.presentation.capturing = false
                guard self.workflow.canGenerate else {
                    self.showCaptureFailure("输入框为空或已变化，请确认文字后重新读取。"); return
                }
                if self.settings.preferences.automaticTranslationAndReplacement {
                    self.startAutomaticGeneration(requestID: nil)
                } else {
                    await self.open()
                    if self.settings.canGenerate { self.generateCurrentDraft() }
                }
            } catch {
                guard self.captureRequestID == request else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? "读取输入框失败，请重新聚焦目标输入框。"
                self.workflow.captureDidFail(message)
                if self.host.isManual { await self.workflow.useManualInput() }
                guard self.captureRequestID == request else { return }
                self.captureTask = nil
                self.presentation.capturing = false
                self.showCaptureFailure(message, kind: .capture(error as? ExternalInputError))
            }
        }
    }

    func hideLauncher() {
        cancelAutomaticRun()
        if cliEditor.active { cliEditor.cancel(); return }
        guard !localCompositionActive else { return }
        openRequestID = UUID()
        restoreRequestID = UUID()
        if presentation.capturing { host.external.clear() }
        captureRequestID = UUID()
        captureTask?.cancel()
        captureTask = nil
        presentation.capturing = false
        launcherHidden = true
        panel.orderOut(nil)
    }

    func applicationLostFocus() {
        guard hasBeenPresented, !settingsVisible, !launcherHidden, !localCompositionActive else { return }
        if presentation.cliReadStatus { return }
        if expanded && workflow.canSwitchDraft { showCollapsed(explicit: false) }
        else if !expanded { refreshLauncherVisibility() }
    }

    func collapse() {
        if automaticRun != nil { cancelAutomaticRun(); return }
        if presentation.cliReadStatus {
            guard !presentation.cliChecking else { return }
            if cliEditor.active || cliEditor.readIntent != nil { cliEditor.cancel(); return }
            presentation.cliReadStatus = false
            showCollapsed(explicit: false)
            return
        }
        if cliEditor.active { if !localCompositionActive { cliEditor.cancel() }; return }
        guard workflow.canSwitchDraft, !isBusy else { return }
        showCollapsed(explicit: false)
        Task { await host.returnFocus() }
    }

    func restoreHostOriginal() {
        guard !DesktopInstallation.shared.busy else { return }
        guard !isBusy, workflow.canSwitchDraft, host.isExternal else { return }
        let requestID = UUID()
        restoreRequestID = requestID
        presentation.returning = true
        presentation.captureFailure = nil
        presentation.restoreMessage = "正在返回并恢复原文…"
        Task { [weak self] in
            guard let self else { return }
            guard self.restoreRequestID == requestID, self.host.isExternal,
                  self.workflow.canSwitchDraft,
                  await self.host.external.liveRestorationIsValid(),
                  self.restoreRequestID == requestID, self.host.external.canRestoreOriginal else {
                self.presentation.returning = false
                return
            }
            do {
                _ = try await self.host.external.restoreOriginalInput()
                guard self.restoreRequestID == requestID else { return }
                self.presentation.returning = false
                self.presentation.captureFailure = nil
                self.presentation.restoreMessage = "输入框原文已恢复，尚未发送。"
                self.showSuccess("原文已恢复 · 未发送")
                self.onHostRestore?(true)
                self.workflow.captureDidFail("输入框原文已恢复，请重新读取后再生成。")
                self.showCollapsed(explicit: false)
            } catch {
                guard self.restoreRequestID == requestID else { return }
                self.onHostRestore?(false)
                self.presentation.returning = false
                if let failure = error as? FillError, case .outcomeUnknown = failure {
                    self.presentation.restoreMessage = "恢复结果尚未确认，请到原应用检查；不会自动重试。"
                } else { self.presentation.restoreMessage = "原输入框已变化，未恢复原文。" }
                self.showCaptureFailure(self.presentation.restoreMessage ?? "未能恢复原文。", kind: .restore(error as? FillError))
            }
        }
    }

    @discardableResult func copyOutputOnly() -> Bool {
        guard !isBusy, workflow.canCopy else { return false }
        pasteboard.clearContents()
        let succeeded = pasteboard.setString(workflow.output, forType: .string)
        copyFeedbackTask?.cancel()
        if succeeded {
            presentation.copyError = nil
            presentation.copiedDocumentID = workflow.outputDocumentID
            let document = workflow.outputDocumentID
            copyFeedbackTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.workflow.outputDocumentID == document else { return }
                self.presentation.copiedDocumentID = nil
            }
        } else {
            presentation.copiedDocumentID = nil
            presentation.copyError = "复制失败，请重试。"
        }
        return succeeded
    }

    func copyOutputAndReturn() {
        guard !DesktopInstallation.shared.busy else { return }
        let succeeded = copyOutputOnly()
        guard succeeded && workflow.canReturnWithCopy,
              !presentation.returning else { return }
        presentation.returning = true
        let output = workflow.output
        let source = workflow.source
        let external = host.external
        let captureID = external.captureID
        Task { [weak self] in
            guard let self else { return }
            defer { self.presentation.returning = false }
            let scope: UUID
            do { scope = try await external.prepareForPanelActivation().scopeID }
            catch {
                self.reportCopyReturnFailure("已复制，但无法确认原输入框。请手动切回原应用粘贴。")
                return
            }
            guard await external.liveSnapshot()?.captureID == captureID,
                  external.captureID == captureID, self.host.isExternal,
                  self.workflow.output == output, self.workflow.source == source,
                  self.workflow.canReturnWithCopy else {
                await external.endPanelContextMenu(scope)
                self.reportCopyReturnFailure("已复制，但原输入框已变化或无法确认。请手动切回原应用粘贴。")
                return
            }
            // Hold the existing broker UI scope across both responder changes
            // and the verified focus return. Otherwise our own workspace event
            // can invalidate the target between collapsing and validation.
            self.showCollapsed(explicit: false)
            let returned = await external.returnFocus()
            let matches = self.host.isExternal && external.captureID == captureID
                && self.workflow.output == output && self.workflow.source == source
                && self.workflow.canReturnWithCopy
            await external.endPanelContextMenu(scope)
            if returned && matches { self.onCopyReturn?(true) }
            else { self.reportCopyReturnFailure("已复制，但未能返回原输入框。请手动切回原应用粘贴。") }
        }
    }

    private func reportCopyReturnFailure(_ message: String) {
        onCopyReturn?(false)
        workflow.externalReturnDidFail()
        showCaptureFailure(message, kind: .returnFailure)
    }

    private func copyRecoveryText(_ text: String) {
        guard !isBusy, workflow.canSwitchDraft else { return }
        pasteboard.clearContents()
        presentation.restoreMessage = pasteboard.setString(text, forType: .string)
            ? "已复制记录中的文字。" : "复制失败，请重试。"
    }

    private func applyLanguage() {
        guard !isBusy, workflow.canSwitchDraft else { return }
        do {
            try settings.setDefaultLanguage(presentation.languageInput)
            workflow.setTargetLanguage(settings.preferences.targetLanguage)
            presentation.languageInput = workflow.targetLanguage
            presentation.languagePending = false
            presentation.languageError = nil
        } catch { presentation.languageError = error.localizedDescription }
    }

    private func fillCurrentDraft() {
        guard !DesktopInstallation.shared.busy else { return }
        guard !isBusy, workflow.canFill else { return }
        workflow.fill()
    }

    private func generateCurrentDraft() {
        guard !DesktopInstallation.shared.busy else { return }
        guard !presentation.cliReadStatus else { return }
        guard settings.canGenerate, !isBusy, workflow.canSwitchDraft,
              (panel.firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        if presentation.languageInput.trimmingCharacters(in: .whitespacesAndNewlines) != workflow.targetLanguage { applyLanguage() }
        guard presentation.languageInput.trimmingCharacters(in: .whitespacesAndNewlines) == workflow.targetLanguage else { return }
        if case .configuration = presentation.failureKind { presentation.captureFailure = nil }
        presentation.copiedDocumentID = nil
        outputFocusRequest = (workflow.sourceDocumentID, workflow.sourceRevision, interactionRevision, panel.firstResponder)
        workflow.generate()
    }

    func returnToInput() {
        guard !DesktopInstallation.shared.busy else { return }
        guard !cliEditor.active, !host.isCLI else { return }
        guard !workflow.sourceIsComposing && !workflow.outputIsComposing else { return }
        if host.isExternal {
            guard !isBusy else { return }
            let document = workflow.sourceDocumentID
            presentation.returning = true
            Task { [weak self] in
                guard let self else { return }
                await self.workflow.prepareExternalRecapture()
                let returned = await self.host.external.returnFocus(allowInvalidTarget: true)
                self.presentation.returning = false
                guard self.workflow.sourceDocumentID == document else { return }
                if returned { self.showCollapsed(explicit: false) }
                else { self.showCaptureFailure("未能返回原输入框。请手动切回原应用，按 ⌥T 或点击浮窗重新读取。", kind: .returnFailure) }
            }
        } else if !host.isManual {
            Task { await workflow.captureSelection() }
        }
    }

    func importCLIDraft() async {
        guard !blocksEntrySwitch, workflow.allowDraftSwitch() else { return }
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentation.restoreMessage = "剪贴板为空，当前草稿未改变。"
            await open()
            return
        }
        guard await workflow.prepareForEntrySwitch() else { return }
        cliEditor.clearMessage()
        host.useCLI(text)
        await workflow.captureSelection()
        presentation.restoreMessage = "已导入 CLI 草稿。翻译后可复制译文，粘贴回原会话。"
        await open()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if cliEditor.active { collapse(); return false }
        return !localCompositionActive
    }

    func setVisible(_ visible: Bool) {
        if visible { if expanded { activate() } else { showCollapsed(explicit: false) } }
        else {
            workflow.hostDidChange()
            if !launcherHidden && !settingsVisible { showCollapsed(explicit: false) }
        }
    }

    func deactivate() {
        openRequestID = UUID()
        panel.orderOut(nil)
    }

    func activate() {
        if hasBeenPresented && !launcherHidden && !settingsVisible && (!expanded || host.canShowPanel) {
            position()
            if !expanded { refreshLauncherVisibility() }
            else if NSApp.isActive { panel.orderFront(nil) }
        }
    }

    func suspendForSettings() {
        openRequestID = UUID()
        if let editor = panel.firstResponder as? NSTextView { rememberEditorFocus(editor) }
        previousResponder = panel.firstResponder
        previousSourceDocumentID = workflow.sourceDocumentID
        settingsVisible = true
        panel.orderOut(nil)
    }

    func resumeAfterSettings() {
        settingsVisible = false
        guard !launcherHidden, NSApp.isActive && hasBeenPresented && host.canShowPanel else { return }
        activate()
        if expanded {
            panel.makeKeyAndOrderFront(nil)
            if previousSourceDocumentID == workflow.sourceDocumentID,
               let previousResponder, (previousResponder as? NSView)?.window === panel {
                panel.makeFirstResponder(previousResponder)
            } else { restoreEditorFocus() }
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !positioning else { return }
        if !expanded { panel.launcherWindowDidMove() }
        userTopLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if !positioning { position() }
    }

    func resetPosition() {
        userTopLeft = nil
        position()
    }

    func setLauncherMode(_ mode: LauncherMode) {
        launcherMode = mode
        if mode == .persistent { focusedAnchor = nil }
        if hasBeenPresented { refreshLauncherVisibility() }
    }

    func receiveFocusState(_ state: FocusLauncherState) {
        focusState = state
        if case .target(let target) = state { focusedAnchor = target.anchor }
        else if case .unavailable = state { focusedAnchor = nil }
        guard launcherMode == .focusedInput else { return }
        if !hasBeenPresented, case .target = state, !launcherHidden { showCollapsed(explicit: false) }
        refreshLauncherVisibility()
    }

    private func refreshLauncherVisibility() {
        guard hasBeenPresented, !launcherHidden, !settingsVisible, !expanded, !isBusy,
              panel.contextMenuDepth == 0 else { return }
        if launcherMode == .persistent {
            position()
            panel.orderFrontRegardless()
        } else {
            switch focusState {
            case .target:
                position()
                panel.orderFrontRegardless()
            case .ownApplication: break
            case .unavailable: panel.orderOut(nil)
            }
        }
    }

    func position() {
        let anchor = launcherMode == .focusedInput && !expanded ? (focusedAnchor ?? host.frameOnScreen) : host.frameOnScreen
        let screen = uiTestScreenFrame ?? userTopLeft.flatMap { point in
            NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
        } ?? (launcherMode == .focusedInput ? NSScreen.screens.first { $0.frame.intersects(anchor) }?.visibleFrame : nil) ?? host.screenFrame
        let available = min(680, max(1, screen.height - 24))
        if abs(presentation.availableHeight - available) > 0.5 {
            DispatchQueue.main.async { [weak self] in self?.presentation.availableHeight = available }
        }
        let size = NSSize(width: min(expanded ? 390 : 186, max(1, screen.width - 24)),
                          height: min(expanded ? min(desiredHeight, 680) : 52, max(1, screen.height - 24)))
        var x = userTopLeft?.x ?? (anchor.maxX + 12)
        if userTopLeft == nil && x + size.width > screen.maxX { x = anchor.minX - size.width - 12 }
        x = min(max(x, screen.minX + 12), screen.maxX - size.width - 12)
        let top = userTopLeft?.y ?? anchor.maxY
        let y = min(max(top - size.height, screen.minY + 12), screen.maxY - size.height - 12)
        positioning = true
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        positioning = false
    }
}

private struct CollapsedView: View {
    @ObservedObject var workflow: DraftWorkflow
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var presentation: PanelPresentation
    @ObservedObject var cliEditor: CLIEditorSession
    @ObservedObject var cliConnection: CLIConnectionController
    let readAndTranslate: () -> Void
    let allowsClick: () -> Bool
    let open: () -> Void
    let openManual: () -> Void
    let hide: () -> Void
    private var interactionBlocked: Bool {
        presentation.automaticRunning || presentation.cliChecking || presentation.capturing
            || presentation.returning || cliEditor.readIntent != nil || !workflow.canSwitchDraft
    }
    private var actionDescription: String {
        let automatic = settings.preferences.automaticTranslationAndReplacement
        if cliEditor.needsConsent || cliConnection.terminalFrontmost {
            return automatic ? "读取 CLI 草稿、翻译并替换" : "读取 CLI 草稿"
        }
        return automatic ? "读取输入框全文、翻译并替换" : "读取输入框全文并翻译"
    }
    private var idleTitle: String {
        if settings.preferences.automaticTranslationAndReplacement { return "翻译并替换" }
        return cliEditor.needsConsent || cliConnection.terminalFrontmost ? "读取草稿" : "读取并翻译"
    }
    private var accessibilityStatus: String {
        let mode = settings.preferences.automaticTranslationAndReplacement ? "Auto 已开启" : "Auto 已关闭"
        let stage = presentation.automaticRunning ? presentation.automaticMessage
            : (presentation.cliChecking ? "正在检查 CLI 连接"
               : (presentation.capturing ? "正在读取输入框全文" : (cliEditor.message ?? "等待点击")))
        return "目标语言：\(settings.preferences.targetLanguage)；\(mode)；\(stage)"
    }
    var body: some View {
        Button {
            if !interactionBlocked && allowsClick() { readAndTranslate() }
        } label: {
            HStack(spacing: 10) {
                BrandMark().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.automaticRunning ? presentation.automaticMessage : (cliEditor.readIntent != nil || presentation.capturing ? "正在读取…" : idleTitle)).font(.system(size: 13, weight: .medium))
                    Text(presentation.automaticRunning ? "Auto · 译为 \(settings.preferences.targetLanguage)" : (presentation.successMessage ?? cliEditor.message ?? "\(settings.preferences.automaticTranslationAndReplacement ? "Auto · " : "")译为 \(settings.preferences.targetLanguage)")).font(.system(size: 11))
                        .foregroundStyle(.secondary).lineLimit(1).help(cliEditor.message ?? settings.preferences.targetLanguage)
                }
                Spacer(minLength: 0)
                if presentation.capturing || presentation.automaticRunning { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(interactionBlocked)
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(actionDescription)
        .accessibilityValue(accessibilityStatus)
        .accessibilityAction {
            guard !interactionBlocked else { return }
            readAndTranslate()
        }
        .help("\(actionDescription)。先点击原应用或已连接的 Terminal CLI 输入框，再点击浮窗。右键可打开已有草稿。")
        .contextMenu {
            Button("打开已有草稿", action: open)
            Button("直接输入", action: openManual)
            Divider()
            Button("隐藏浮窗", action: hide)
        }
    }
}

private struct PanelContentHeight: PreferenceKey {
    static var defaultValue: CGFloat { 0 }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

private struct PanelView: View {
    @ObservedObject var workflow: DraftWorkflow
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var presentation: PanelPresentation
    @ObservedObject var cliEditor: CLIEditorSession
    let acceptPendingCLI: () -> Void
    @State private var sourceHeight: CGFloat = 72
    @State private var outputHeight: CGFloat = 72
    @State private var chromeHeight: CGFloat = 330
    @State private var showingRecord = false
    @State private var showingStatus = false
    let importCLI: () -> Void
    let openSettings: () -> Void
    let openCLISettings: () -> Void
    let openManual: () -> Void
    let continueManual: () -> Void
    let openSavedEntry: (DraftEntry) -> Void
    let openExternalHelp: () -> Void
    let reread: () -> Void
    let collapse: () -> Void
    let copy: () -> Void
    let copyAndReturn: () -> Void
    let fill: () -> Void
    let canRestoreHost: () -> Bool
    let restoreHost: () -> Void
    let copyRecord: (String) -> Void
    let applyLanguage: () -> Void
    let generate: () -> Void
    let recordEditorFocus: (NSTextView) -> Void
    let registerEditor: (EditorRole, UUID, NSTextView?) -> Void
    let canReturnToHost: () -> Bool
    let resetPosition: () -> Void
    let resize: (CGFloat) -> Void

    private var otherInteractionBlocked: Bool { !workflow.canSwitchDraft || presentation.returning || presentation.capturing || cliEditor.finishing || cliEditor.awaitingDraft }
    private var composing: Bool { otherInteractionBlocked || presentation.languageIsComposing }
    private var hasOutput: Bool { workflow.hasOutputEditor }
    private var display: PanelDisplayState {
        PanelDisplayState(workflow: workflow, settings: settings, presentation: presentation,
                          cliEditor: cliEditor, canReturn: canReturnToHost())
    }
    private var editorSizes: (source: CGFloat, output: CGFloat) {
        EditorLayout.heights(source: sourceHeight, output: hasOutput ? outputHeight : nil,
            available: presentation.availableHeight - chromeHeight)
    }
    private func editorHeight(_ measured: CGFloat, output: Bool = false) -> CGFloat {
        output ? editorSizes.output : editorSizes.source
    }
    private var heightMeasurement: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: PanelContentHeight.self, value: geometry.size.height)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if presentation.cliReadStatus {
                cliReadStatus.background(heightMeasurement)
            } else {
                header.background(heightMeasurement)
                ScrollView {
                    form.padding(.trailing, 2).fixedSize(horizontal: false, vertical: true).background(heightMeasurement)
                }
                footer.fixedSize(horizontal: false, vertical: true).background(heightMeasurement)
            }
        }
        .padding(InterfaceTheme.panelPadding).tint(InterfaceTheme.accent).ignoresSafeArea()
        .onAppear { presentation.languageInput = workflow.targetLanguage; presentation.languagePending = false }
        .onChange(of: workflow.output) { _, _ in presentation.copiedDocumentID = nil; presentation.copyError = nil }
        .onChange(of: workflow.targetLanguage) { _, value in presentation.languageInput = value; presentation.languagePending = false }
        .onChange(of: workflow.sourceDocumentID) { _, _ in presentation.languageInput = workflow.targetLanguage; presentation.languagePending = false }
        .onChange(of: presentation.languageInput) { _, value in
            presentation.languagePending = value.trimmingCharacters(in: .whitespacesAndNewlines) != workflow.targetLanguage
            if !presentation.languagePending { presentation.languageError = nil }
        }
        .sheet(isPresented: $showingRecord) {
            if let record = workflow.replacementRecord {
                ReplacementRecordView(record: record, copy: copyRecord, close: { showingRecord = false })
            }
        }
        .onPreferenceChange(PanelContentHeight.self) { height in
            if height.isFinite && height > 0 {
                let overhead = max(0, ceil(height + 56 - editorSizes.source - editorSizes.output))
                if abs(overhead - chromeHeight) > 1 { chromeHeight = overhead }
                let desired = EditorLayout.heights(source: sourceHeight, output: hasOutput ? outputHeight : nil,
                    available: .greatestFiniteMagnitude)
                resize(ceil(overhead + desired.source + desired.output))
            }
        }
    }

    private var cliReadStatus: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("CLI 草稿", systemImage: "terminal").font(.headline)
                Spacer()
                Button(cliEditor.active || cliEditor.readIntent != nil ? "取消读取" : "收起", action: collapse)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .disabled(presentation.cliChecking || cliEditor.finishing)
            }
            if presentation.cliChecking || cliEditor.readIntent != nil || (cliEditor.awaitingDraft && !cliEditor.needsConsent) {
                ProgressView().controlSize(.small)
            }
            Text(presentation.cliChecking ? "正在检查 CLI 连接…" : (cliEditor.message ?? "尚未读取到 CLI 草稿。"))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("CLI 读取状态")
            if cliEditor.needsConsent {
                Button("读取草稿", action: acceptPendingCLI).buttonStyle(.borderedProminent)
            } else if !presentation.cliChecking && !cliEditor.active && cliEditor.readIntent == nil {
                Text("如果会话已连接，请回到 CLI 输入框，按 Ctrl+G 打开外部编辑器，再点击“读取草稿”。如果修改过快捷键，请使用自定义快捷键。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("CLI 接入设置", action: openCLISettings)
            }
            Text(settings.preferences.automaticTranslationAndReplacement ? "Auto 已开启：读取并翻译草稿，然后替换原文。" : "读取后生成译文，由你确认后替换原文。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                BrandMark().frame(width: 24, height: 24)
                Text("翻译草稿").font(.system(size: 16, weight: .semibold))
            }
            Spacer()
            Menu {
                Button("直接输入", action: openManual)
                Menu("已有草稿") {
                    if workflow.hasSavedDraft(.cli) { Button("CLI") { openSavedEntry(.cli) } }
                    if workflow.hasSavedDraft(.claude) { Button("Claude") { openSavedEntry(.claude) } }
                    if workflow.hasSavedDraft(.codex) { Button("ChatGPT / Codex") { openSavedEntry(.codex) } }
                    ForEach(workflow.externalDraftEntries.filter { workflow.hasSavedDraft($0.entry) }, id: \.entry) { saved in
                        Button(saved.name) { openSavedEntry(saved.entry) }
                    }
                    #if PROMPTBRIDGE_TESTING
                    if workflow.hasSavedDraft(.demo) { Button("测试宿主草稿") { openSavedEntry(.demo) } }
                    #endif
                }.disabled(!workflow.hasSavedDraft(.cli) && !workflow.hasSavedDraft(.claude)
                    && !workflow.hasSavedDraft(.codex) && !workflow.externalDraftEntries.contains { workflow.hasSavedDraft($0.entry) })
                Menu("CLI") {
                    Button("接入设置", action: openCLISettings)
                    Button("从剪贴板导入", action: importCLI).disabled(cliEditor.active)
                }
                if !workflow.isManualInput { Button("将当前草稿转为直接输入", action: continueManual) }
                Divider()
                Button("恢复上一稿") { Task { await workflow.restorePreviousDraft() } }.disabled(!workflow.canRestore || cliEditor.active)
                if workflow.replacementRecord != nil { Button("查看替换记录") { showingRecord = true } }
                Button("重置浮窗位置", action: resetPosition)
                Divider()
                Button("输入框翻译说明…", action: openExternalHelp)
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize().disabled(composing).accessibilityLabel("更多操作")
            Button(cliEditor.active ? "取消 CLI 编辑" : "收起", action: collapse).buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(composing).help("按 Esc 收起浮窗；正在选字时，先取消输入法候选。")
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: InterfaceTheme.sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(workflow.targetLabel).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(settings.preferences.automaticTranslationAndReplacement ? "Auto 开启" : "Auto 关闭")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .help("Auto 开启时，点击浮窗会读取全文、翻译并替换；关闭后预览并确认。")
            }
            if presentation.availableHeight < 500 {
                DisclosureGroup("翻译选项") { translationOptions }
            } else { translationOptions }
            if let notice = settings.preferencesNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("原文").font(.system(size: 12, weight: .medium))
                    Spacer()
                    if !workflow.isManualInput && workflow.entry != .cli {
                        Button(workflow.isExternalSelection ? "返回输入框" : "重新读取选区", action: reread)
                            .font(.caption).buttonStyle(.borderless).disabled(composing)
                            .help(workflow.isFullInputCapture ? "返回后，按 ⌥T 或点击浮窗重新读取全文。"
                                  : "返回原应用选择文字，再从菜单读取选中文字。")
                    }
                }
                NativeEditor(value: workflow.source, documentID: workflow.sourceDocumentID,
                    isEditable: display.sourceEditable,
                    onFocus: recordEditorFocus, onHeightChange: { sourceHeight = $0 },
                    role: .source, onRegister: registerEditor, onSelectionChange: recordEditorFocus) {
                    text, composing in workflow.editSource(text, isComposing: composing)
                }
                .frame(height: editorHeight(sourceHeight)).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)).accessibilityLabel("原文")
            }
            if hasOutput {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("译文").font(.system(size: 12, weight: .medium))
                        if workflow.staleReason != nil { Text("旧译文").font(.caption).foregroundStyle(.orange) }
                        Spacer(minLength: 4)
                        if display.action != .generate {
                            Button("重新生成", action: generate).font(.caption).buttonStyle(.borderless)
                                .disabled(!workflow.canGenerate || composing)
                                .help("⌘Return 重新生成；Return 换行。")
                        }
                        if display.action != .copy {
                            Button(presentation.copiedDocumentID == workflow.outputDocumentID ? "已复制" : "复制", action: copy)
                                .font(.caption).buttonStyle(.borderless).disabled(!workflow.canCopy || composing)
                                .accessibilityLabel("仅复制译文")
                        }
                    }
                    if display.action != .copy, let error = presentation.copyError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                    NativeEditor(value: workflow.output, documentID: workflow.outputDocumentID,
                        isEditable: display.outputEditable, onFocus: recordEditorFocus,
                        onHeightChange: { outputHeight = $0 }, role: .output,
                        onRegister: registerEditor, onSelectionChange: recordEditorFocus) {
                        text, composing in workflow.editOutput(text, isComposing: composing)
                    }
                    .frame(height: editorHeight(outputHeight, output: true)).clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary)).accessibilityLabel("译文")
                }
            }
        }
    }

    private var translationOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("处理方式").font(.system(size: 12, weight: .medium))
                    Picker("处理方式", selection: Binding(get: { workflow.intent }, set: { workflow.setIntent($0) })) {
                        Text("翻译").tag(DraftIntent.translate)
                        Text("翻译并优化表达").tag(DraftIntent.optimize)
                    }.labelsHidden().pickerStyle(.menu).frame(height: 26).disabled(composing)
                }.frame(width: 140)
                VStack(alignment: .leading, spacing: 6) {
                    Text("目标语言").font(.system(size: 12, weight: .medium))
                    LanguageComboBox(text: $presentation.languageInput,
                        onCompositionChange: { presentation.languageIsComposing = $0 }) { value in
                        presentation.languageInput = value; applyLanguage()
                    }.frame(height: 26).disabled(otherInteractionBlocked)
                        .help("可输入任意语言；提交后同时用于当前稿和新草稿的默认语言。")
                }
            }
            if let error = presentation.languageError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack(spacing: 6) {
                Text(settings.description).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).help(settings.description)
                Spacer(minLength: 4)
                Button("设置", action: openSettings).font(.caption).buttonStyle(.borderless).disabled(composing)
            }
        }
    }

    private func performPrimary() {
        switch display.action {
        case .generate: generate()
        case .fill: fill()
        case .copy: copy()
        case .copyAndReturn: copyAndReturn()
        case .cliRead: acceptPendingCLI()
        case .cliSave: cliEditor.save()
        case .settings: openSettings()
        case .none: break
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                if display.busy { ProgressView().controlSize(.small) }
                else if display.warning { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                Text(display.message).font(.system(size: 12))
                    .foregroundStyle(display.warning ? Color.primary : Color.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .help(display.message).accessibilityLabel("操作状态：\(display.message)")
                if display.message.count > 40 {
                    Button("详情") { showingStatus = true }.font(.caption).buttonStyle(.borderless)
                        .popover(isPresented: $showingStatus) {
                            Text(display.message).font(.callout).textSelection(.enabled)
                                .frame(width: 310, alignment: .leading).fixedSize(horizontal: false, vertical: true).padding(16)
                        }
                }
            }
            if cliEditor.active && !cliEditor.outputIsNormalized && !cliEditor.awaitingDraft {
                DisclosureGroup("CLI 将按规则调整末尾空白") {
                    Text(cliEditor.deliveryText).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).lineLimit(5)
                }.font(.caption)
            }
            HStack {
                if display.canCancelGeneration {
                    Button("取消生成") { workflow.cancel() }.font(.caption)
                } else if cliEditor.active && !cliEditor.finishing {
                    Button("取消 CLI 编辑", action: cliEditor.cancel).font(.caption).disabled(composing)
                } else if canRestoreHost() && workflow.replacementRecord?.status == .confirmed {
                    Button("恢复原文", action: restoreHost).font(.caption).disabled(composing)
                }
                if presentation.captureFailure != nil && !hasOutput {
                    Button("直接输入", action: openManual).font(.caption).disabled(composing)
                    Button("读取说明", action: openExternalHelp).font(.caption)
                }
                Spacer(minLength: 0)
            }
            if display.action == .copy, let error = presentation.copyError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Button(action: performPrimary) {
                Text(display.action == .copy && presentation.copiedDocumentID == workflow.outputDocumentID
                     ? "已复制" : display.title).frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(!display.enabled || (display.action == .cliRead ? presentation.languageIsComposing : composing) || presentation.languagePending)
            .help(display.action == .generate ? "⌘Return 生成译文；Return 换行。" : "")
        }
    }
}
