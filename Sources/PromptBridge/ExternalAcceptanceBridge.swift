#if PROMPTBRIDGE_TESTING
import AppKit
import DraftCore

/// Explicitly launched native acceptance mode. Fixed synthetic text, local translation,
/// and an isolated clipboard; fill/restore use the unchanged production capability gate.
@MainActor final class ExternalAcceptanceBridge {
    private enum Action: String, Codable {
        case capture, captureFull = "capture-full", generate, copy, fill, restore, state, quit
        case showLauncher = "show-launcher", showCurrent = "show-current"
        case focusMode = "focus-mode", persistentMode = "persistent-mode"
        case translate, autoOn = "auto-on", autoOff = "auto-off", editOutput = "edit-output"
    }
    private struct Command: Decodable { let id: UUID; let action: Action }
    private struct ExplicitOptional<Value: Encodable>: Encodable {
        let value: Value?

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value { try container.encode(value) }
            else { try container.encodeNil() }
        }
    }
    private struct Ready: Encodable {
        let ready: Bool
        let localDemo: Bool
        let connected: Bool
        let brokerConnected: Bool
        let permissionKnown: Bool
        let permission: ExplicitOptional<Bool>
        let brokerEpoch: ExplicitOptional<String>
        let brokerStatus: ExplicitOptional<BrokerStatus>
    }
    private struct Result: Encodable {
        let id: UUID
        let succeeded: Bool
        let error: String?
        let failedAttribute: String?
        let captureOutcome: String?
        let captureError: String?
        let captureFailedAttribute: String?
        let connected: Bool
        let brokerConnected: Bool
        let brokerEpoch: ExplicitOptional<String>
        let brokerStatus: ExplicitOptional<BrokerStatus>
        let permissionKnown: Bool
        let host: String
        let phase: String
        let sourceMatchesFixture: Bool
        let outputMatchesFixture: Bool
        let editedOutputMatchesFixture: Bool
        let replacementRecordMatchesFixture: Bool
        let launcherMode: String
        let focusState: String
        let contextMenuTracking: Bool
        let clipboardMatchesFixture: Bool
        let targetAvailable: Bool
        let fullInputCapture: Bool
        let contextCandidatePresent: Bool
        let replacementApproved: Bool
        let canGenerate: Bool
        let canCopy: Bool
        let canFill: Bool
        let replacementReceiptVerified: Bool
        let writeAttempts: Int
        let replacementTrace: [String]
        let canRestoreOriginal: Bool
        let restoreSucceeded: Bool?
        let busy: Bool
        let panelVisible: Bool
        let panelIsKeyWindow: Bool
        let panelWidth: Double
        let frontmost: String
        let ownIdentityMatchesFrontmost: Bool
        let copyReturnSucceeded: Bool?
        let valueEvents: Int
        let selectionEvents: Int
        let lastObservedChange: String?
    }
    static var fixture: String {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--external-test-fixture"), args.indices.contains(i + 1) else { return "short" }
        return args[i + 1]
    }
    static var source: String {
        switch fixture {
        case "multiline": "请保留路径 ./src/登录.ts 和按钮“确认删除”。\n第二行：中文 😀 👨‍👩‍👧‍👦 e\u{301}；不要发送消息。"
        case "long": (1...40).map { "第\($0)行：保留 ./src/登录.ts、中文 😀 e\u{301}；只修改必要内容，不发送。" }.joined(separator: "\n")
        default: "请保留按钮文案“确认删除”和路径 ./src/登录.ts。"
        }
    }
    static var output: String {
        fixture == "short" ? "Keep the button label “确认删除” and the path ./src/登录.ts unchanged."
            : "【本地演示，非实际译文】\n" + source
    }
    static var editedOutput: String { output + "\n[MANUAL EDIT — 合成验收 😀]" }
    private static func matchesOutput(_ value: String) -> Bool { value == output || value == editedOutput }
    static func supports(bundle: String) -> Bool {
        ["com.anthropic.claudefordesktop", "com.openai.codex", "com.tencent.xinWeChat", "com.tencent.qq", "local.promptbridge.input-harness"].contains(bundle)
    }

    // Capture callbacks initiated by a physical click do not return through a
    // command. Retain metadata only so fixture rejection cannot masquerade as
    // a rejection by the real input adapter.
    private static var captureOutcome: String?
    private static var captureError: String?
    private static var captureFailedAttribute: String?

    /// Shared by the command and the actual nonactivating launcher click. This adds
    /// only the fixture boundary; capture and replacement remain product operations.
    static func captureFullInput(router: HostRouter, bundle: String) async throws {
        captureOutcome = "checkingHost"
        captureError = nil
        captureFailedAttribute = nil
        guard supports(bundle: bundle), NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else {
            captureOutcome = "hostRejected"
            throw ExternalInputError.unsupportedApplication
        }
        do { try await router.captureExternalFullInput() }
        catch {
            captureOutcome = "adapterRejected"
            captureError = (error as? ExternalInputError).map { String(describing: $0) } ?? "captureFailed"
            captureFailedAttribute = router.external.lastReadFailure
            throw error
        }
        let snapshot = await router.external.liveSnapshot()
        guard snapshot?.fullText == source else {
            captureOutcome = snapshot == nil ? "snapshotUnavailable" : "fixtureMismatch"
            router.external.clear()
            throw ExternalInputError.invalidSelection
        }
        captureOutcome = "accepted"
    }
    private let directory: URL
    private let bundle: String
    private let router: HostRouter
    private let workflow: DraftWorkflow
    private let panel: PanelController
    private let settings: TranslationSettings
    private var timer: Timer?
    private var lastID: UUID?
    private var processing = false
    private var copiedReturn: Bool?
    private var restored: Bool?
    private var valueEvents = 0
    private var selectionEvents = 0
    private var lastObservedChange: String?
    private var replacementTrace: [String] = []

    private var brokerCache: (connected: Bool, status: BrokerStatus?, epoch: String?, permissionKnown: Bool) {
        let broker = BrokerClient.shared
        let connected = broker.connected
        let status = connected ? broker.cachedStatus : nil
        let epoch = connected ? broker.epoch?.uuidString : nil
        return (connected, status, epoch, connected && status != nil)
    }

    init(directory: URL, bundle: String, router: HostRouter, workflow: DraftWorkflow, panel: PanelController, settings: TranslationSettings) throws {
        guard Self.supports(bundle: bundle), ["short", "multiline", "long"].contains(Self.fixture) else {
            throw ExternalInputError.unsupportedApplication
        }
        self.directory = directory
        self.bundle = bundle
        self.router = router
        self.workflow = workflow
        self.panel = panel
        self.settings = settings
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["command.json", "result.json", "ready.json"] {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
        router.external.onObservedChange = { [weak self] name in
            if name != "poll" { self?.lastObservedChange = name }
            if name == "AXValueChanged" { self?.valueEvents += 1 }
            if name == "AXSelectedTextChanged" { self?.selectionEvents += 1 }
            if name != "poll", self?.replacementTrace.isEmpty == false {
                self?.recordReplacementTrace("event:" + name)
            }
        }
        let previousStageHandler = router.external.onReplacementStage
        router.external.onReplacementStage = { [weak self] stage in
            previousStageHandler?(stage)
            self?.recordReplacementTrace("stage:" + String(describing: stage))
        }
        panel.onCopyReturn = { [weak self] in self?.copiedReturn = $0 }
        panel.onHostRestore = { [weak self] in self?.restored = $0 }
        let broker = brokerCache
        let ready = Ready(ready: true, localDemo: true, connected: broker.connected,
                          brokerConnected: broker.connected, permissionKnown: broker.permissionKnown,
                          permission: ExplicitOptional(value: broker.status?.permission),
                          brokerEpoch: ExplicitOptional(value: broker.epoch),
                          brokerStatus: ExplicitOptional(value: broker.status))
        try JSONEncoder().encode(ready).write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                let _: Task<Void, Never> = Task { @MainActor [weak self] in await self?.process() }
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func process() async {
        guard !processing else { return }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")), data.count <= 4096,
              let command = try? JSONDecoder().decode(Command.self, from: data), command.id != lastID else { return }
        lastID = command.id
        if command.action == .captureFull {
            processing = true
            var errorName: String?
            do {
                guard !panel.isBusy else { throw ExternalInputError.unavailable }
                copiedReturn = nil
                restored = nil
                valueEvents = 0
                selectionEvents = 0
                lastObservedChange = nil
                try await Self.captureFullInput(router: router, bundle: bundle)
                await workflow.captureSelection()
                await panel.open()
            } catch let error as ExternalInputError { errorName = String(describing: error) }
            catch { errorName = "commandFailed" }
            publish(command, errorName: errorName)
            processing = false
            return
        }
        var errorName: String?
        do {
            guard !panel.isBusy || command.action == .state else { throw ExternalInputError.unavailable }
            switch command.action {
            case .capture:
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else {
                    throw ExternalInputError.unsupportedApplication
                }
                copiedReturn = nil
                restored = nil
                valueEvents = 0
                selectionEvents = 0
                lastObservedChange = nil
                try await router.captureExternal()
                guard await router.external.liveSnapshot()?.selectedText == Self.source else {
                    router.external.clear()
                    throw ExternalInputError.invalidSelection
                }
                await workflow.captureSelection()
                await panel.open()
            case .captureFull: break // handled asynchronously before this switch
            case .translate:
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle else {
                    throw ExternalInputError.unsupportedApplication
                }
                replacementTrace = []
                restored = nil
                panel.readFromLauncher()
            case .autoOn, .autoOff:
                var preferences = settings.preferences
                preferences.automaticTranslationAndReplacement = command.action == .autoOn
                try settings.savePreferences(preferences)
            case .editOutput:
                guard workflow.source == Self.source, workflow.output == Self.output, workflow.canEditOutput else {
                    throw ExternalInputError.invalidSelection
                }
                workflow.editOutput(Self.editedOutput)
            case .generate:
                guard workflow.source == Self.source, workflow.canGenerate else { throw ExternalInputError.invalidSelection }
                workflow.generate()
            case .copy:
                guard Self.matchesOutput(workflow.output), workflow.canCopy else { throw ExternalInputError.invalidSelection }
                copiedReturn = nil
                panel.copyOutputAndReturn()
            case .fill:
                guard workflow.source == Self.source, Self.matchesOutput(workflow.output),
                      workflow.canFill else { throw ExternalInputError.invalidSelection }
                workflow.fill()
            case .restore:
                guard workflow.source == Self.source, Self.matchesOutput(workflow.output),
                      await router.external.liveRestorationIsValid(),
                      router.external.canRestoreOriginal else { throw ExternalInputError.invalidSelection }
                restored = nil
                panel.restoreHostOriginal()
            case .showLauncher:
                copiedReturn = nil
                restored = nil
                panel.showCollapsed()
            case .showCurrent: await panel.open()
            case .focusMode, .persistentMode:
                var preferences = settings.preferences
                preferences.launcherMode = command.action == .focusMode ? .focusedInput : .persistent
                try settings.savePreferences(preferences)
            case .state: break
            case .quit: router.external.clear()
            }
        } catch let error as ExternalInputError { errorName = String(describing: error) }
        catch { errorName = "commandFailed" }
        publish(command, errorName: errorName)
    }

    private func recordReplacementTrace(_ value: String) {
        if replacementTrace.count < 100 { replacementTrace.append(value) }
    }

    private func publish(_ command: Command, errorName: String?) {
        // During replacement the input intentionally differs from the old snapshot.
        // The writer owns verification until receipt completion; a status request
        // must not validate/invalidate that obsolete snapshot in the middle of a write.
        let snapshot = router.isExternal && !panel.isBusy ? router.external.snapshot() : nil
        let available = snapshot != nil
        let front = NSWorkspace.shared.frontmostApplication
        let foreground = front?.bundleIdentifier == bundle ? "host"
            : front?.processIdentifier == NSRunningApplication.current.processIdentifier ? "self" : "other"
        let broker = brokerCache
        let result = Result(id: command.id, succeeded: errorName == nil, error: errorName,
            failedAttribute: router.external.lastReadFailure,
            captureOutcome: Self.captureOutcome, captureError: Self.captureError,
            captureFailedAttribute: Self.captureFailedAttribute,
            connected: broker.connected, brokerConnected: broker.connected,
            brokerEpoch: ExplicitOptional(value: broker.epoch),
            brokerStatus: ExplicitOptional(value: broker.status),
            permissionKnown: broker.permissionKnown,
            host: workflow.externalHostName, phase: String(describing: workflow.phase),
            sourceMatchesFixture: workflow.source == Self.source, outputMatchesFixture: Self.matchesOutput(workflow.output),
            editedOutputMatchesFixture: workflow.output == Self.editedOutput,
            replacementRecordMatchesFixture: workflow.replacementRecord.map { $0.originalText == Self.source && Self.matchesOutput($0.writtenText) } ?? false,
            launcherMode: settings.preferences.launcherMode.rawValue, focusState: panel.uiTestFocusState,
            contextMenuTracking: panel.uiTestContextMenuTracking,
            clipboardMatchesFixture: panel.uiTestClipboardString == Self.output, targetAvailable: available,
            fullInputCapture: snapshot?.captureScope == .entireInput,
            contextCandidatePresent: snapshot?.contextID != nil,
            replacementApproved: snapshot?.supportsDirectFill == true,
            canGenerate: workflow.canGenerate, canCopy: workflow.canCopy, canFill: workflow.canFill,
            replacementReceiptVerified: workflow.phase == .filled,
            writeAttempts: router.external.writeAttempts, replacementTrace: replacementTrace,
            canRestoreOriginal: !panel.isBusy && router.external.canRestoreOriginal, restoreSucceeded: restored,
            busy: panel.isBusy,
            panelVisible: panel.uiTestWindow.isVisible, panelIsKeyWindow: panel.uiTestWindow.isKeyWindow,
            panelWidth: panel.uiTestWindow.frame.width,
            frontmost: foreground,
            ownIdentityMatchesFrontmost: front?.processIdentifier == NSRunningApplication.current.processIdentifier
                && (front?.bundleIdentifier ?? "") == (Bundle.main.bundleIdentifier ?? ""),
            copyReturnSucceeded: copiedReturn,
            valueEvents: valueEvents, selectionEvents: selectionEvents,
            lastObservedChange: lastObservedChange)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(result).write(to: directory.appendingPathComponent("result.json"), options: .atomic)
        } catch { print("Could not save external acceptance result.") }
        if command.action == .quit { timer?.invalidate(); NSApp.terminate(nil) }
    }
}

#endif
