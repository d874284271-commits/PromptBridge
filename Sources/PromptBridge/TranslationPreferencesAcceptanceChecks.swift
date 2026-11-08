#if PROMPTBRIDGE_TESTING
import DraftCore
import Foundation
import AppKit
import AccessibilityContracts

@MainActor enum TranslationPreferencesAcceptanceChecks {
    static func run() async -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptBridgePreferences-" + UUID().uuidString)
        let file = root.appendingPathComponent("preferences.json")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let settings = TranslationSettings(loadEnvironment: false, preferencesFileURL: file)
            checks.append(("missing preference file uses defaults without writing", settings.preferences == TranslationPreferences() && !FileManager.default.fileExists(atPath: file.path)))
            var changes = 0
            settings.preferencesDidChange = { changes += 1 }
            var value = settings.preferences
            value.targetLanguage = "  Português brasileiro  "
            value.translationTemplate = "Translate faithfully into {{target_language}}. Return only the draft."
            try settings.savePreferences(value)
            checks.append(("save publishes normalized language and one change", settings.preferences.targetLanguage == "Português brasileiro" && changes == 1))
            try settings.savePreferences(settings.preferences)
            checks.append(("unchanged save does not invalidate drafts", changes == 1))
            let reloaded = TranslationSettings(loadEnvironment: false, preferencesFileURL: file)
            checks.append(("preferences survive restart separately from provider", reloaded.preferences == settings.preferences && reloaded.configuration == nil))
            let before = try Data(contentsOf: file)
            var invalid = settings.preferences
            invalid.translationTemplate = "missing variable"
            do { try settings.savePreferences(invalid); checks.append(("invalid template rejected", false)) }
            catch { checks.append(("invalid template rejected", try Data(contentsOf: file) == before && settings.preferences == reloaded.preferences)) }
            settings.canEditPreferences = { false }
            do { try settings.setDefaultLanguage("日本語"); checks.append(("in-flight operation blocks preference mutation", false)) }
            catch { checks.append(("in-flight operation blocks preference mutation", try Data(contentsOf: file) == before)) }
            settings.canEditPreferences = { true }
            try Data("{broken".utf8).write(to: file)
            settings.reloadPreferences()
            do { try settings.savePreferences(value); checks.append(("corrupt preferences cannot be overwritten", false)) }
            catch {
                let persisted = try String(contentsOf: file, encoding: .utf8)
                checks.append(("corrupt preferences cannot be overwritten", settings.preferencesNotice != nil && settings.preferences == reloaded.preferences && persisted == "{broken"))
            }
            try TranslationPreferencesStore(fileURL: file).save(reloaded.preferences)
            settings.reloadPreferences()
            try settings.setDefaultLanguage("Ελληνικά")
            checks.append(("explicit repair and reload restores saving", settings.preferences.targetLanguage == "Ελληνικά" && settings.preferencesNotice == nil))
            let request = try GenerationRequest(source: "合成原稿", intent: .translate, targetLanguage: "Ελληνικά", template: settings.preferences.translationTemplate)
            let demo = try await settings.generate(request)
            checks.append(("demo labels arbitrary language and custom prompts as not a translation", demo.contains("非实际译文") && demo.contains("Ελληνικά") && demo.contains("合成原稿")))
        } catch { checks.append(("preferences integration completes: \(error.localizedDescription)", false)) }
        checks += await statusMenuChecks(preferencesFileURL: root.appendingPathComponent("menu-preferences.json"))
        return checks
    }

    /// Isolated broker wire used by the preference/menu checks. The endpoint
    /// returns only synthetic Codable metadata and receipts; no AX/runtime type
    /// is linked into the main application target.
    private final class StatusMenuWire {
        let epoch: UUID
        let hostName = "ChatGPT / Codex"
        let source = "状态栏菜单合成原文 😀"
        private(set) var activeScopes: Set<UUID> = []
        private var sequence: UInt64 = 0
        private var captureToken = UUID()
        private var revision: UInt64 = 0
        private var text = ""
        private var original = ""
        private var restorationToken: UUID?
        private(set) var writeCount = 0
        private(set) var captureCount = 0
        var rejectValidation = false

        init(epoch: UUID) { self.epoch = epoch }

        func exchange(_ data: Data) throws -> Data {
            let request = try BrokerCodec.request(data)
            sequence += 1
            switch request.operation {
            case .capture:
                captureCount += 1
                captureToken = UUID(); revision += 1; text = source; original = source
                return try response(request, state: state())
            case .validate:
                if rejectValidation { return try response(request, error: .targetChanged) }
                return try response(request, state: state())
            case .acquireScope:
                let kind = request.payload?.scopeRequest?.kind ?? .panel
                let scope = UUID()
                activeScopes.insert(scope)
                return try response(request, receipt: BrokerScopeReceipt(scopeID: scope, kind: kind,
                    captureToken: request.payload?.scopeRequest?.target?.captureToken))
            case .releaseScope:
                if let scope = request.payload?.scopeID { activeScopes.remove(scope) }
                return try response(request)
            case .replace:
                guard let write = request.payload?.write else { throw BrokerContractError.invalidMessage }
                original = text; text = write.text; revision += 1; writeCount += 1
                restorationToken = UUID()
                return try response(request, state: state(canRestore: true),
                    replacement: ReplacementReceipt(expected: write.expected, writtenText: write.text))
            case .restore:
                guard request.payload?.restore?.restorationToken == restorationToken else {
                    throw BrokerContractError.invalidMessage
                }
                text = original; revision += 1; writeCount += 1; restorationToken = nil
                return try response(request, state: state(),
                    replacement: ReplacementReceipt(expected: snapshot(), writtenText: text))
            case .returnFocus:
                return try response(request, focusReturned: true)
            case .invalidate:
                return try response(request)
            default:
                throw BrokerContractError.invalidMessage
            }
        }

        private func snapshot() -> InputSnapshot {
            InputSnapshot(identity: InputIdentity(host: hostName, window: "menu-window",
                input: "menu-input", session: "menu-session"), revision: revision,
                selection: NSRange(location: 0, length: (text as NSString).length),
                selectedText: text, supportsDirectFill: true, captureScope: .entireInput,
                fullText: text, contextID: nil, captureID: captureToken)
        }

        private func state(canRestore: Bool = false) -> BrokerRuntimeState {
            BrokerRuntimeState(snapshot: snapshot(), captureToken: captureToken, revision: revision,
                frame: BrokerRect(x: 100, y: 100, width: 300, height: 40),
                restorationToken: restorationToken, canRestore: canRestore, canReturnFocus: true,
                hasTarget: true, hostName: hostName, lastReadFailure: nil, writeAttempts: writeCount,
                lastObservedChange: nil, replacementStage: nil)
        }

        private func response(_ request: BrokerRequest, state: BrokerRuntimeState? = nil,
                              replacement: ReplacementReceipt? = nil,
                              receipt: BrokerScopeReceipt? = nil,
                              focusReturned: Bool? = nil, error: BrokerErrorCode? = nil) throws -> Data {
            try BrokerCodec.encode(BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: sequence, error: error, runtimeState: state, replacementReceipt: replacement,
                scopeReceipt: receipt, focusReturned: focusReturned))
        }

        func status() -> BrokerStatus {
            BrokerStatus(pid: 99, bundle: BrokerIdentity.bundle, path: "/fixture/PromptBridge Accessibility.app",
                version: "1", build: "1", certificateSHA1: String(repeating: "A", count: 40),
                permission: true, supportedOperations: BrokerOperation.requiredProductionOperations)
        }
    }

    static func runAutomaticFlow() async -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        func button(in window: NSWindow, containing expected: String) -> AnyObject? {
            var queue: [AnyObject] = [window]
            var seen: Set<ObjectIdentifier> = []
            while let element = queue.popLast() {
                guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
                let label = (element.accessibilityLabel?() ?? nil) ?? (element.accessibilityTitle?() ?? nil) ?? ""
                if (element.accessibilityRole?() ?? nil) == .button && label.contains(expected) {
                    return element
                }
                queue.append(contentsOf: (element.accessibilityChildren?() ?? nil)?.map { $0 as AnyObject } ?? [])
            }
            return nil
        }
        func pressConsent(in window: NSWindow, label expected: String = "读取草稿") -> Bool {
            button(in: window, containing: expected)?.accessibilityPerformPress?() == true
        }
        func wait(_ condition: () -> Bool) async -> Bool {
            let end = ContinuousClock.now.advanced(by: .seconds(6))
            while !condition(), ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(20)) }
            return condition()
        }
        let epoch = UUID()
        let wire = StatusMenuWire(epoch: epoch)
        var holdCaptureValidation = false
        var validationCount = 0
        var releaseCapture: CheckedContinuation<Void, Never>?
        let identity = BrokerApplicationIdentity(pid: getpid(), bundle: BrokerIdentity.clientBundle,
            path: Bundle.main.bundleURL.path, version: "fixture", build: "fixture")
        let client = BrokerClient(testExchange: { data in
            if try BrokerCodec.request(data).operation == .validate {
                validationCount += 1
                if holdCaptureValidation && validationCount == 2 {
                    await withCheckedContinuation { releaseCapture = $0 }
                }
            }
            return try wire.exchange(data)
        }, ownIdentity: identity,
            initialStatus: wire.status(), initialVerifiedClient: identity, initialEpoch: epoch)
        let demo = DemoHost()
        let router = HostRouter(demo: demo, external: ExternalInput(client: client))
        let settings = TranslationSettings(loadEnvironment: false)
        let workflow = DraftWorkflow(host: router, translator: settings)
        router.external.onReplacementStage = { workflow.replacementStageDidChange($0) }
        let controller = PanelController(workflow: workflow, host: router, settings: settings,
            openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName(),
            terminalIsFrontmost: { false })
        defer { controller.hideLauncher(); router.external.clear(); demo.window.orderOut(nil) }
        _ = router.useManual()
        await workflow.useManualInput()
        demo.window.makeKeyAndOrderFront(nil)
        router.hideInactiveDemo()
        checks.append(("ordinary route hides the test host even if it was previously visible", !demo.window.isVisible))
        controller.showCollapsed()
        controller.readFromLauncher()
        controller.readFromLauncher()
        let generating = await wait { workflow.phase == .translating }
        checks.append(("default Auto reads once and translates in the nonactivating compact window",
                       generating && controller.isBusy && wire.captureCount == 1
                       && controller.uiTestWindow.frame.width == 186 && !controller.uiTestWindow.isKeyWindow && !demo.window.isVisible))
        let progressButton = button(in: controller.uiTestWindow, containing: "读取输入框全文")
        let progressRawValue: Any? = progressButton?.accessibilityValue?()
        let progressValue = progressRawValue as? String ?? ""
        checks.append(("Auto accessibility describes overwrite, language, active stage, and no sending",
                       (progressButton?.accessibilityLabel?() ?? nil)?.contains("翻译并替换") == true
                       && progressValue.contains("Auto 已开启") && progressValue.contains(settings.preferences.targetLanguage)
                       && progressValue.contains("正在翻译") && progressValue.contains("全程不发送")))
        let filled = await wait { workflow.phase == .filled && !controller.isBusy }
        checks.append(("desktop Auto fills the whole input once without confirmation", filled && wire.writeCount == 1
                       && router.external.snapshot()?.fullText == workflow.output && workflow.replacementRecord?.status == .confirmed))

        do {
            try settings.savePreferences(TranslationPreferences(automaticTranslationAndReplacement: false))
            controller.readFromLauncher()
            let ready = await wait { workflow.phase == .ready }
            checks.append(("Auto off leaves translated text ready for manual confirmation", ready && wire.writeCount == 1
                           && workflow.canFill && controller.uiTestWindow.frame.width == 390))
            try settings.savePreferences(TranslationPreferences())
            controller.showCollapsed()
            controller.readFromLauncher()
            _ = await wait { workflow.phase == .translating }
            controller.hideLauncher()
            try? await Task.sleep(for: .milliseconds(2_200))
            checks.append(("cancelled Auto never applies a late result", !controller.isBusy && wire.writeCount == 1 && workflow.phase != .filled))
            controller.showCollapsed()
            controller.readFromLauncher()
            _ = await wait { workflow.phase == .translating }
            wire.rejectValidation = true
            let stopped = await wait { workflow.phase == .blocked && !controller.isBusy }
            checks.append(("target change stops Auto without a write or retry", stopped && wire.writeCount == 1 && wire.captureCount == 4))
            wire.rejectValidation = false
            validationCount = 0
            holdCaptureValidation = true
            controller.showCollapsed()
            controller.readFromLauncher()
            _ = await wait { releaseCapture != nil }
            let busyBeforeDuplicate = controller.isBusy
            controller.readFromLauncher()
            try? await Task.sleep(for: .milliseconds(100))
            checks.append(("whole-input snapshot wait stays busy and ignores another click", busyBeforeDuplicate && wire.captureCount == 5))
            controller.hideLauncher()
            holdCaptureValidation = false
            releaseCapture?.resume(); releaseCapture = nil
            try? await Task.sleep(for: .milliseconds(2_200))
            checks.append(("cancelled snapshot wait cannot restart Auto after its late capture", !controller.isBusy && wire.writeCount == 1))
        } catch { checks.append(("desktop Auto fixtures complete: \(error)", false)) }
        controller.hideLauncher()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptBridgeAutoCLI-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for kind in [CLIHostKind.codex, .claude] {
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let fileURL = root.appendingPathComponent(kind.rawValue + ".txt")
                let original = "合成 CLI 整稿\n./目录 with spaces/代码.swift\n"
                try Data(original.utf8).write(to: fileURL)
                let file = try CLIEditorFile(url: fileURL)
                let cliSettings = TranslationSettings(loadEnvironment: false)
                let cliRouter = HostRouter(demo: DemoHost())
                _ = cliRouter.useManual()
                let cliWorkflow = DraftWorkflow(host: cliRouter, translator: cliSettings)
                await cliWorkflow.useManualInput()
                var reads = 0
                let session = CLITerminalSession(id: UUID(), kind: kind, version: "unrecorded", pid: getpid(),
                    startTimeMicros: 1, processGroup: 1, tty: "/dev/ttys999", executablePath: "/fixture/cli")
                let registration = CLISessionRegistration(session: session, codexHome: root.path, workingDirectory: root.path)
                let cli = PanelController(workflow: cliWorkflow, host: cliRouter, settings: cliSettings,
                    openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName(),
                    terminalIsFrontmost: { true }, readCLI: { editor in reads += 1; _ = editor.beginRead(sessionID: session.id) },
                    cliIdentityVerifier: { _ in true })
                defer { cli.hideLauncher() }
                cli.showCollapsed()
                cli.readFromLauncher()
                cli.readFromLauncher()
                _ = await wait { cli.cliEditor.readIntent != nil }
                let request = CLIEditorPreflight(helperStartTimeMicros: 1, registration: registration)
                let url = try CLIEditorExchange.create(request)
                defer { CLIEditorExchange.cleanup(url) }
                let accepted = await cli.cliEditor.receive(url, busy: cli.cliReceptionBusy)
                let permission = try CLIEditorExchange.read(CLIEditorReadPermission.self, from: CLIEditorExchange.file("permission.json", for: url))
                try CLIEditorExchange.write(CLIEditorDraft(id: request.id, intentID: permission.intentID, source: original),
                    to: CLIEditorExchange.file("draft.json", for: url))
                await cli.cliEditor.receiveDraft()
                let saved = await wait { cli.cliEditor.finishing }
                let response = try CLIEditorExchange.read(CLIEditorResponse.self, from: CLIEditorExchange.file("response.json", for: url))
                checks.append(("\(kind.rawValue) Auto binds the clicked request and submits once in compact feedback",
                               accepted && saved && reads == 1 && response.disposition == .accepted
                               && response.text == cli.cliEditor.deliveryText && cli.uiTestWindow.frame.width == 186))
                try file.commit(response.text!)
                try CLIEditorExchange.write(CLIEditorCompletion(id: request.id, status: .saved, message: "fixture saved"),
                    to: CLIEditorExchange.file("completion.json", for: url))
                cli.cliEditor.poll()
                _ = await wait { !cli.isBusy }
                let committed = try Data(contentsOf: fileURL)
                cli.cliEditor.save()
                let afterRepeatedSave = try Data(contentsOf: fileURL)
                checks.append(("\(kind.rawValue) completion never repeats a committed write",
                               !cli.isBusy && !cli.cliEditor.active && committed == Data(response.text!.utf8)
                               && afterRepeatedSave == committed))

                cli.readFromLauncher()
                _ = await wait { cli.cliEditor.readIntent != nil }
                cli.cliEditor.expireRead(now: .greatestFiniteMagnitude)
                _ = await wait { !cli.isBusy }
                let late = CLIEditorPreflight(helperStartTimeMicros: 1, registration: registration)
                let lateURL = try CLIEditorExchange.create(late)
                defer { CLIEditorExchange.cleanup(lateURL) }
                _ = await cli.cliEditor.receive(lateURL, busy: cli.cliReceptionBusy)
                checks.append(("\(kind.rawValue) expired Auto needs a new click for late requests",
                               cli.cliEditor.needsConsent && !FileManager.default.fileExists(atPath: CLIEditorExchange.file("permission.json", for: lateURL).path)))
                try? await Task.sleep(for: .milliseconds(100))
                checks.append(("\(kind.rawValue) late request exposes the actual status-page consent button",
                               cli.uiTestWindow.frame.width == 390 && pressConsent(in: cli.uiTestWindow)))
                _ = await wait { FileManager.default.fileExists(atPath: CLIEditorExchange.file("permission.json", for: lateURL).path) }
                let manualPermission = try CLIEditorExchange.read(CLIEditorReadPermission.self, from: CLIEditorExchange.file("permission.json", for: lateURL))
                try CLIEditorExchange.write(CLIEditorDraft(id: late.id, intentID: manualPermission.intentID, source: original),
                    to: CLIEditorExchange.file("draft.json", for: lateURL))
                await cli.cliEditor.receiveDraft()
                let manualSaved = await wait { cli.cliEditor.finishing }
                let manualResponse = try? CLIEditorExchange.read(CLIEditorResponse.self, from: CLIEditorExchange.file("response.json", for: lateURL))
                checks.append(("\(kind.rawValue) explicit manual-handoff consent also runs Auto without another key trigger",
                               manualSaved && reads == 2 && manualResponse?.disposition == .accepted))
                try CLIEditorExchange.write(CLIEditorCompletion(id: late.id, status: .saved, message: "fixture manual saved"),
                    to: CLIEditorExchange.file("completion.json", for: lateURL))
                cli.cliEditor.poll()
                _ = await wait { !cli.isBusy }

                for entry in ["compact", "editor"] {
                    for automatic in [true, false] {
                        try cliSettings.savePreferences(TranslationPreferences(automaticTranslationAndReplacement: automatic))
                        let incoming = CLIEditorPreflight(helperStartTimeMicros: 1, registration: registration)
                        let requestURL = try CLIEditorExchange.create(incoming)
                        defer { CLIEditorExchange.cleanup(requestURL) }
                        _ = await cli.cliEditor.receive(requestURL, busy: cli.cliReceptionBusy)
                        try? await Task.sleep(for: .milliseconds(100))
                        if entry == "compact" { cli.showCollapsed() } else { await cli.open() }
                        try? await Task.sleep(for: .milliseconds(100))
                        if entry == "compact" {
                            let action = button(in: cli.uiTestWindow, containing: "读取 CLI 草稿")
                            let label = (action?.accessibilityLabel?() ?? nil) ?? ""
                            let rawValue: Any? = action?.accessibilityValue?()
                            let value = rawValue as? String ?? ""
                            checks.append(("\(kind.rawValue) consent accessibility matches Auto=\(automatic)",
                                           label.contains("翻译并替换") == automatic
                                           && value.contains(automatic ? "Auto 已开启" : "Auto 已关闭")
                                           && value.contains(cliSettings.preferences.targetLanguage) && value.contains("全程不发送")))
                        }
                        let pressed = pressConsent(in: cli.uiTestWindow, label: "读取")
                        let authorized = await wait { FileManager.default.fileExists(atPath: CLIEditorExchange.file("permission.json", for: requestURL).path) }
                        checks.append(("\(kind.rawValue) \(entry) actual consent authorizes once with Auto=\(automatic)", pressed && authorized && reads == 2))
                        let grant = try CLIEditorExchange.read(CLIEditorReadPermission.self, from: CLIEditorExchange.file("permission.json", for: requestURL))
                        try CLIEditorExchange.write(CLIEditorDraft(id: incoming.id, intentID: grant.intentID, source: original),
                            to: CLIEditorExchange.file("draft.json", for: requestURL))
                        await cli.cliEditor.receiveDraft()
                        if automatic {
                            let submitted = await wait { cli.cliEditor.finishing }
                            checks.append(("\(kind.rawValue) \(entry) consent runs Auto without another confirmation",
                                           submitted && cli.uiTestWindow.frame.width == 186))
                        } else {
                            try? await Task.sleep(for: .milliseconds(100))
                            checks.append(("\(kind.rawValue) \(entry) Auto off only reads until explicit generation",
                                           cliWorkflow.phase == .idle && !cli.cliEditor.finishing
                                           && !FileManager.default.fileExists(atPath: CLIEditorExchange.file("response.json", for: requestURL).path)))
                            cliWorkflow.generate()
                            let ready = await wait { cliWorkflow.phase == .ready }
                            let saveEnabled = await wait {
                                button(in: cli.uiTestWindow, containing: "替换并返回")?.isAccessibilityEnabled?() == true
                            }
                            checks.append(("\(kind.rawValue) \(entry) Auto off waits for the actual save button (ready=\(ready), enabled=\(saveEnabled), canSave=\(cli.cliEditor.canSave))",
                                           ready && saveEnabled && !cli.cliEditor.finishing
                                           && pressConsent(in: cli.uiTestWindow, label: "替换并返回")))
                            _ = await wait { cli.cliEditor.finishing }
                        }
                        let reply = try CLIEditorExchange.read(CLIEditorResponse.self, from: CLIEditorExchange.file("response.json", for: requestURL))
                        checks.append(("\(kind.rawValue) \(entry) submits the current request only once",
                                       reply.id == incoming.id && reply.disposition == .accepted && reads == 2))
                        try CLIEditorExchange.write(CLIEditorCompletion(id: incoming.id, status: .saved, message: "fixture entry saved"),
                            to: CLIEditorExchange.file("completion.json", for: requestURL))
                        cli.cliEditor.poll()
                        _ = await wait { !cli.isBusy }
                    }
                }

                _ = await cliWorkflow.prepareForEntrySwitch()
                _ = cliRouter.useManual()
                await cliWorkflow.useManualInput()
                cliWorkflow.editSource("尚未提交的直接输入稿")
                let untouched = cliWorkflow.source
                let unopened = CLIEditorPreflight(helperStartTimeMicros: 1, registration: registration)
                let unopenedURL = try CLIEditorExchange.create(unopened)
                _ = await cli.cliEditor.receive(unopenedURL, busy: false)
                CLIEditorExchange.cleanup(unopenedURL)
                _ = cli.cliEditor.poll()
                checks.append(("\(kind.rawValue) unsubmitted CLI disconnect preserves manual generation",
                               !cli.cliEditor.outcomeIsUnknown && cliWorkflow.source == untouched
                               && cliWorkflow.canGenerate && cli.uiTestDisplayState.action == .generate))

                let unavailableConfig = root.appendingPathComponent(kind.rawValue + "-invalid-provider.json")
                try Data("{broken".utf8).write(to: unavailableConfig)
                let unavailableSettings = TranslationSettings(loadEnvironment: false, configFileURL: unavailableConfig)
                _ = await wait { !unavailableSettings.isLoading }
                let unavailableWorkflow = DraftWorkflow(host: cliRouter, translator: unavailableSettings)
                let blocked = PanelController(workflow: unavailableWorkflow, host: cliRouter, settings: unavailableSettings,
                    openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName(),
                    cliIdentityVerifier: { _ in true })
                defer { blocked.hideLauncher() }
                let pending = CLIEditorPreflight(helperStartTimeMicros: 1, registration: registration)
                let pendingURL = try CLIEditorExchange.create(pending)
                defer { CLIEditorExchange.cleanup(pendingURL) }
                _ = await blocked.cliEditor.receive(pendingURL, busy: false)
                await blocked.open()
                try? await Task.sleep(for: .milliseconds(100))
                let pressed = pressConsent(in: blocked.uiTestWindow)
                try? await Task.sleep(for: .milliseconds(100))
                checks.append(("\(kind.rawValue) unavailable model blocks actual consent without reading",
                               pressed && !unavailableSettings.canGenerate && blocked.cliEditor.needsConsent
                               && !FileManager.default.fileExists(atPath: CLIEditorExchange.file("permission.json", for: pendingURL).path)))
                blocked.cliEditor.cancel()
                let cancelled = try CLIEditorExchange.read(CLIEditorResponse.self, from: CLIEditorExchange.file("response.json", for: pendingURL))
                try CLIEditorExchange.write(CLIEditorCompletion(id: pending.id, status: .cancelled, message: "fixture cancelled"),
                    to: CLIEditorExchange.file("completion.json", for: pendingURL))
                blocked.cliEditor.poll()
                checks.append(("\(kind.rawValue) blocked consent can be cancelled to release settings access",
                               cancelled.disposition == .cancelled && !blocked.blocksEntrySwitch))
            } catch { checks.append(("\(kind.rawValue) Auto fixture completes: \(error)", false)) }
        }
        return checks
    }

    private static func statusMenuChecks(preferencesFileURL: URL) async -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let epoch = UUID()
        let wire = StatusMenuWire(epoch: epoch)
        let identity = BrokerApplicationIdentity(pid: max(1, Int32(ProcessInfo.processInfo.processIdentifier)),
            bundle: BrokerIdentity.clientBundle, path: Bundle.main.bundleURL.path,
            version: "fixture", build: "fixture")
        let client = BrokerClient(testExchange: { data in try wire.exchange(data) }, ownIdentity: identity,
            initialStatus: wire.status(), initialVerifiedClient: identity, initialEpoch: epoch)
        let external = ExternalInput(client: client)
        let router = HostRouter(demo: DemoHost(), external: external)
        let settings = TranslationSettings(loadEnvironment: false, preferencesFileURL: preferencesFileURL)
        let workflow = DraftWorkflow(host: router, translator: settings)
        _ = router.useManual()
        await workflow.useManualInput()
        let controller = PanelController(workflow: workflow, host: router, settings: settings,
            openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName())
        defer { controller.hideLauncher(); external.clear() }
        func beginMenu() async -> UUID? { try? await controller.beginStatusMenuTracking() }

        controller.showCollapsed()
        _ = await beginMenu()
        _ = await beginMenu()
        controller.setLauncherMode(LauncherMode.focusedInput)
        controller.receiveFocusState(FocusLauncherState.unavailable)
        var nestedStayedPaired = false
        controller.uiTestDuringContextMenu { nestedStayedPaired = controller.uiTestContextMenuTracking }
        let emptyScopeStayedVisible = controller.uiTestWindow.isVisible && controller.uiTestContextMenuTracking
        await controller.endStatusMenuTracking()
        await controller.endStatusMenuTracking()
        checks.append(("status menu without an external target pairs repeated and nested notifications",
                       emptyScopeStayedVisible && nestedStayedPaired && !controller.uiTestContextMenuTracking
                       && !controller.uiTestWindow.isVisible))

        controller.setLauncherMode(LauncherMode.persistent)
        controller.showCollapsed()
        _ = await beginMenu()
        controller.hideLauncher()
        await controller.endStatusMenuTracking()
        checks.append(("closing status menu preserves an explicit hide action", !controller.uiTestWindow.isVisible))
        _ = await beginMenu()
        controller.showCollapsed()
        await controller.endStatusMenuTracking()
        checks.append(("closing status menu preserves an explicit show action", controller.uiTestWindow.isVisible))
        _ = await beginMenu()
        await controller.open()
        await controller.endStatusMenuTracking()
        checks.append(("closing status menu does not collapse an expanded draft",
                       controller.uiTestWindow.isVisible && controller.uiTestWindow.canBecomeKey
                       && controller.uiTestWindow.frame.width == 390))

        do {
            try await router.captureExternalFullInput()
            guard let snapshot = await external.liveSnapshot() else { throw ExternalInputError.unavailable }
            _ = try await external.replaceSelection(with: "STATUS MENU RESULT", expected: snapshot)
            controller.showCollapsed()
            guard await beginMenu() != nil, await beginMenu() != nil else {
                throw ExternalInputError.unavailable
            }
            try await Task.sleep(for: .milliseconds(1_050))
            let retained = external.canRestoreOriginal && controller.uiTestContextMenuTracking
            await controller.endStatusMenuTracking()
            await controller.endStatusMenuTracking()
            _ = try await external.restoreOriginalInput()
            checks.append(("status menu holds external receipt beyond one second and releases exactly once",
                           retained && !controller.uiTestContextMenuTracking
                           && external.snapshot()?.fullText == snapshot.fullText && wire.writeCount == 2))

            guard await beginMenu() != nil else { throw ExternalInputError.unavailable }
            external.clear()
            try await router.captureExternalFullInput()
            let newScope = try await external.beginPanelContextMenu()
            await controller.endStatusMenuTracking()
            let newScopePreserved = wire.activeScopes.contains(newScope.scopeID)
            await external.endPanelContextMenu(newScope.scopeID)
            checks.append(("closing an old status menu cannot end a new capture's menu scope", newScopePreserved))
        } catch { checks.append(("status menu external scope integration completes: \(error.localizedDescription)", false)) }
        return checks
    }
}

#endif
