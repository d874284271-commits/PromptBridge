#if PROMPTBRIDGE_TESTING
import AppKit
import DraftCore
import AccessibilityContracts
import SwiftUI

/// Runs explicit local fixture instructions inside the real AppKit application.
/// Normal launches do not construct this runner or read its script.
@MainActor final class UIAcceptanceSuite {
    private struct Script: Decodable { let scenarios: [String] }
    private struct Check: Codable {
        let scenario: String
        let assertion: String
        let passed: Bool
    }
    private struct Snapshot: Codable {
        let scenario: String
        let image: String
        let frame: String
        let phase: String
        let canGenerate: Bool
        let canFill: Bool
        let canCopy: Bool
    }
    private struct Report: Codable {
        let checks: [Check]
        let snapshots: [Snapshot]
        let failures: [String]
    }
    private enum Failure: Error { case assertion(String) }
    private let host: DemoHost
    private let router: HostRouter
    private let workflow: DraftWorkflow
    private let panel: PanelController
    private let settings: TranslationSettings
    private let settingsController: SettingsController
    private let reopen: () -> Void
    private let sample = "请保留按钮文案“确认删除”和路径 ./src/登录.ts。"
    private var scenario = "startup"
    private var outputDirectory = URL(fileURLWithPath: ".build/ui-acceptance", isDirectory: true)
    private var checks: [Check] = []
    private var snapshots: [Snapshot] = []
    private var failures: [String] = []

    init(host: DemoHost, router: HostRouter, workflow: DraftWorkflow, panel: PanelController,
         settings: TranslationSettings, settingsController: SettingsController,
         reopen: @escaping () -> Void) {
        self.host = host
        self.router = router
        self.workflow = workflow
        self.panel = panel
        self.settings = settings
        self.settingsController = settingsController
        self.reopen = reopen
    }

    func run() async {
        do {
            let args = CommandLine.arguments
            guard let inputIndex = args.firstIndex(of: "--ui-test-script"),
                  args.indices.contains(inputIndex + 1),
                  let outputIndex = args.firstIndex(of: "--ui-test-output"),
                  args.indices.contains(outputIndex + 1) else {
                throw Failure.assertion("Expected --ui-test-script PATH --ui-test-output DIRECTORY")
            }
            outputDirectory = URL(fileURLWithPath: args[outputIndex + 1], isDirectory: true)
            let script = try JSONDecoder().decode(Script.self, from: Data(contentsOf: URL(fileURLWithPath: args[inputIndex + 1])))
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try check(!script.scenarios.isEmpty, "script contains scenarios")
            try check(settings.isDemo && settings.canGenerate, "test launch uses local demo without environment loading")
            for name in script.scenarios {
                scenario = name
                FileHandle.standardOutput.write(Data("START \(name)\n".utf8))
                do {
                    try settings.apply(nil)
                    for editor in editors() where editor.hasMarkedText() { editor.unmarkText() }
                    panel.uiTestScreenFrame = nil
                    panel.uiTestSetLargeEditor(false)
                    settingsController.uiTestWindow?.close()
                    switch name {
                    case "cli-import": try await cliImport()
                    case "cli-editor": try await cliEditor()
                    case "cli-settings": try await cliSettings()
                    case "cli-launcher": try await cliLauncher()
                    case "automatic-flow":
                        for (assertion, passed) in await TranslationPreferencesAcceptanceChecks.runAutomaticFlow() { try check(passed, assertion) }
                    case "host-text-change": try await hostTextChange()
                    case "selection-cycle": try await selectionCycle()
                    case "reopen": try await reopenPreservesTarget()
                    case "manual-after-capture-failure": try await manualAfterCaptureFailure()
                    case "manual-reopen-after-capture-failure": try await manualAfterCaptureFailure(reopenExisting: true)
                    case "native-ime": try await nativeComposition()
                    case "settings-ime": try await settingsComposition()
                    case "position": try await positionPersistence()
                    case "collapsed-launcher": try await collapsedLauncher()
                    case "brand-assets": try await brandAssets()
                    case "panel-failure-status": try await panelFailureStatus()
                    case "ui-refinement": try await uiRefinement()
                    case "copy-preview": try await copyPreview()
                    case "release-product": try await releaseProduct()
                    case "launcher-drag": try await launcherDrag()
                    case "long-draft": try await longDraft()
                    case "small-screen": try await smallScreen()
                    case "fullscreen": try await fullScreen()
                    case "codex-probe-policy", "external-selection-policy", "full-input-policy", "focus-launcher-policy":
                        throw Failure.assertion("AX/runtime policy migrated to AccessibilityRuntimeFixtureChecks")
                    case "external-selection-flow":
                        try await externalSelectionFlow()
                    case "broker-client-contract":
                        for (assertion, passed) in await runBrokerClientChecks() { try check(passed, assertion) }
                        for (assertion, passed) in try await mainFocusLauncherLifecycle() { try check(passed, assertion) }
                    case "focus-launcher-visibility": try await focusLauncherVisibility()
                    case "translation-preferences":
                        for (assertion, passed) in await TranslationPreferencesAcceptanceChecks.run() { try check(passed, assertion) }
                    case "language-combo-events": try languageComboEvents()
                    case "language-combo-composition": try await languageComboComposition()
                    case "full-input-flow": try await fullInputFlow()
                    case "saved-external-draft-open": try await savedExternalDraftOpen()
                    case "draft-recovery": try await draftRecovery()
                    case "editor-undo": try await editorUndoIsolation()
                    case "adaptive-layout": try await adaptiveLayout()
                    case "settings-recovery":
                        try await manual()
                        for (assertion, passed) in await SettingsAcceptanceChecks.run() { try check(passed, assertion) }
                    case "settings-interactions":
                        for (assertion, passed) in await SettingsInteractionChecks.run() { try check(passed, assertion) }
                    case "settings-form": try await settingsForm()
                    default: throw Failure.assertion("Unknown scenario: \(name)")
                    }
                    print("PASS \(name)")
                } catch {
                    failures.append("\(name): \(error)")
                    try? await snapshot("\(name)-failure")
                    print("FAIL \(name): \(error)")
                }
            }
        } catch { failures.append("\(scenario): \(error)") }
        if host.window.styleMask.contains(.fullScreen) {
            host.window.toggleFullScreen(nil)
            try? await wait("leave fullscreen") { !self.host.window.styleMask.contains(.fullScreen) }
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Report(checks: checks, snapshots: snapshots, failures: failures))
                .write(to: outputDirectory.appendingPathComponent("report.json"), options: .atomic)
        } catch { failures.append("Could not write report: \(error)") }
        print("\(checks.filter(\.passed).count)/\(checks.count) assertions; \(failures.count) failures; \(outputDirectory.path)")
        Darwin.exit(failures.isEmpty ? 0 : 1)
    }

    private func check(_ condition: Bool, _ assertion: String) throws {
        checks.append(Check(scenario: scenario, assertion: assertion, passed: condition))
        if !condition { throw Failure.assertion(assertion) }
    }

    private func cliImport() async throws {
        try await manual("独立桌面草稿")
        let source = "请保留中文\n```swift\nprint(\"你好\")\n```\n./目录 with spaces/文件.swift\n"
        panel.uiTestSetClipboard(source)
        await panel.importCLIDraft()
        try check(workflow.entry == .cli && workflow.source == source, "explicit clipboard import preserves Unicode, lines, code and paths")
        try check(router.isCLI && !router.isExternal && !workflow.canFill, "CLI route never permits AX fill")
        panel.uiTestSetClipboard(" \n")
        await panel.importCLIDraft()
        try check(workflow.source == source, "empty clipboard preserves draft")
        try await generate()
        try check(workflow.canSaveCLI && workflow.canCopy, "current CLI result can be confirmed or copied")
        workflow.setTargetLanguage("日本語")
        try check(!workflow.canSaveCLI && workflow.staleReason != nil, "language edit disables stale result save")
        try await generate()
        workflow.setIntent(.optimize)
        try check(!workflow.canSaveCLI, "mode edit disables stale result save")
        try await generate()
        workflow.editSource(source + "新增要求")
        try check(!workflow.canSaveCLI && workflow.canCopy, "source edit leaves stale result copyable but unsavable")
        guard await workflow.prepareForEntrySwitch() else { throw Failure.assertion("entry switch failed") }
        router.useManual()
        await workflow.useManualInput()
        try check(workflow.source == "独立桌面草稿", "desktop draft remains isolated")
        guard await workflow.prepareForEntrySwitch() else { throw Failure.assertion("entry switch failed") }
        router.useCLI("")
        await workflow.useCLIInput()
        try check(workflow.source == source + "新增要求" && workflow.canGenerate, "CLI saved entry resumes independently")
    }

    private func cliLauncher() async throws {
        panel.hideLauncher()
        let localSettings = TranslationSettings(loadEnvironment: false)
        try localSettings.savePreferences(TranslationPreferences(automaticTranslationAndReplacement: false))
        let localWorkflow = DraftWorkflow(host: router, translator: DemoTranslator())
        await localWorkflow.openSavedEntry(.cli)
        localWorkflow.editSource("PREVIOUS FIXTURE DRAFT")
        var reads = 0
        var desktopReads = 0
        var settingsOpened = false
        var finishRead: CheckedContinuation<Void, Never>?
        weak var readWindow: NSWindow?
        var expandedBeforeRead = false
        let reason = "快捷键已触发，但未收到 CLI 草稿。请确认光标位于输入框，或手动打开外部编辑器。"
        let controller = PanelController(workflow: localWorkflow, host: router, settings: localSettings,
            openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName(),
            captureFullInput: { desktopReads += 1 }, openCLISettings: { settingsOpened = true },
            terminalIsFrontmost: { true },
            readCLI: { editor in
                reads += 1
                expandedBeforeRead = readWindow?.frame.width == 390 && readWindow?.isKeyWindow == false
                await withCheckedContinuation { finishRead = $0 }
                editor.failRead(reason)
            })
        defer { controller.hideLauncher() }
        controller.showCollapsed()
        try await settle()
        let window = controller.uiTestWindow
        readWindow = window
        try check(window.frame.width == 186 && !window.isKeyWindow, "CLI launcher starts collapsed without keyboard focus")
        controller.readFromLauncher()
        controller.readFromLauncher()
        try await settle()
        try check(window.isVisible && window.frame.width == 390, "CLI launcher click expands feedback without a Dock click")
        try check(expandedBeforeRead && reads == 1 && controller.isBusy,
            "status expands without keyboard activation before trigger and duplicate click is ignored")
        finishRead?.resume(); finishRead = nil
        try await settle()
        try check(controller.cliEditor.message == reason && reads == 1 && desktopReads == 0,
            "CLI read failure is displayed without a desktop capture")
        try check(localWorkflow.source == "PREVIOUS FIXTURE DRAFT" && localWorkflow.phase != .translating,
            "failed CLI read preserves the previous draft without generation")
        try check(!descendants(window.contentView).contains { $0 is CompositionTextView },
            "CLI read status does not expose previous draft editors as current CLI content")
        guard let settingsButton = accessibilityElements(window).first(where: {
            (($0.accessibilityLabel?() ?? nil) ?? ($0.accessibilityTitle?() ?? nil) ?? "") == "CLI 接入设置"
        }) else { throw Failure.assertion("Missing CLI settings recovery button") }
        try check(settingsButton.accessibilityPerformPress?() == true && settingsOpened,
            "CLI read failure opens integration settings through its recovery button")
        controller.applicationLostFocus()
        try check(window.isVisible && window.frame.width == 390, "CLI instructions remain expanded while returning to Terminal manually")
        try await snapshot("cli-launcher-unavailable", window: window, state: localWorkflow)
    }

    private func cliSettings() async throws {
        let directory = outputDirectory.appendingPathComponent("CLI settings fixture")
        let app = directory.appendingPathComponent("Applications/PromptBridge.app")
        let helper = app.appendingPathComponent("Contents/MacOS/promptbridge-editor")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        chmod(helper.path, 0o700)
        defer { try? FileManager.default.removeItem(at: directory); settingsController.uiTestCLIConnection = nil }
        let suite = "local.promptbridge.cli-testing-fixture.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let connection = CLIConnectionController(home: directory, applicationURL: app, liveInspection: false,
            testingPreferences: preferences)
        try check(connection.automaticReadEnabled, "ordinary package enables automatic reads by default")
        connection.setAutomaticReadEnabled(false)
        let reopened = CLIConnectionController(home: directory, applicationURL: app, liveInspection: false,
            testingPreferences: preferences)
        try check(!reopened.automaticReadEnabled, "explicitly disabled reads persist across controller restart")
        connection.setAutomaticReadEnabled(true)
        let regular = CLIConnectionController(home: directory, applicationURL: app, liveInspection: false,
            testingPreferences: preferences)
        try check(regular.automaticReadEnabled, "ordinary package honors enabled preference without signed version lists")
        // Exercise the actual read entrypoint with old persisted metadata and unrelated configuration.
        let config = directory.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("notify = ['fixture']\n[agents]\n[plugins.fixture]\n[profiles.custom]\n[unknown]\n".utf8).write(to: config)
        for kind in CLIHostKind.allCases {
            let keyFile = directory.appendingPathComponent(kind == .codex ? ".codex/keybindings.json" : ".claude/keybindings.json")
            try FileManager.default.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("unrelated fixture configuration".utf8).write(to: keyFile)
            let identity = CLITerminalSession(id: UUID(), kind: kind, version: "future", pid: 101,
                startTimeMicros: 55, processGroup: 101, tty: "/dev/ttys999", executablePath: "/fixture/cli")
            let registration = CLISessionRegistration(session: identity, codexHome: directory.appendingPathComponent("custom config").path,
                claudeTempRoot: directory.appendingPathComponent("custom temp").path, workingDirectory: directory.path,
                automaticReadEligible: false)
            let epoch = UUID()
            let target = CLITerminalTarget(token: UUID(), session: identity, terminalPID: 700,
                terminalStartTimeMicros: 44, windowID: 1)
            let own = BrokerApplicationIdentity(pid: getpid(), bundle: BrokerIdentity.clientBundle,
                path: Bundle.main.bundleURL.path, version: "fixture", build: "fixture")
            var operations: [BrokerOperation] = []
            var sequence: UInt64 = 0
            var onQuery: (() -> Void)?
            let broker = BrokerClient(testExchange: { message in
                let request = try BrokerCodec.request(message)
                operations.append(request.operation); sequence += 1
                if request.operation == .cliQueryTarget {
                    onQuery?()
                    return try BrokerCodec.encode(BrokerResponse(requestID: request.requestID, epoch: epoch,
                        stateSequence: sequence, cliTarget: target))
                }
                guard request.operation == .cliTriggerEditor, let operationID = request.payload?.operationID else {
                    throw BrokerTransportError.invalidResponse
                }
                return try BrokerCodec.encode(BrokerResponse(requestID: request.requestID, epoch: epoch,
                    stateSequence: sequence, cliAction: CLIActionReceipt(operationID: operationID,
                        targetToken: target.token, disposition: .triggered)))
            }, ownIdentity: own, initialVerifiedClient: own, initialEpoch: epoch)
            let connected = CLIConnectionController(broker: broker, home: directory, applicationURL: app,
                liveInspection: false, testingPreferences: preferences, initialRegistrations: [registration])
            let editor = CLIEditorSession(workflow: workflow, host: router)
            connected.setAutomaticReadEnabled(false)
            await connected.read(using: editor)
            try check(operations.isEmpty && editor.readIntent == nil, "disabled \(kind) reads never query or trigger")
            connected.setAutomaticReadEnabled(true)
            await connected.read(using: editor)
            try check(operations == [.cliQueryTarget, .cliTriggerEditor] && editor.readIntent?.sessionID == identity.id,
                "\(kind) future version and old false registration reach one trigger despite unrelated/custom configuration")
            await connected.read(using: editor)
            try check(operations.count == 2, "pending \(kind) read ignores duplicate clicks")
            editor.expireRead(now: (editor.readIntent?.deadline ?? 0) + 1)
            try check(editor.readIntent == nil && editor.message?.contains("快捷键已触发") == true && operations.count == 2,
                "\(kind) timeout explains missing handoff without another trigger")
            onQuery = { connected.setAutomaticReadEnabled(false) }
            await connected.read(using: editor)
            onQuery = nil
            try check(operations == [.cliQueryTarget, .cliTriggerEditor, .cliQueryTarget] && editor.readIntent == nil,
                "disabling \(kind) automatic reads during query prevents the subsequent trigger")
            connected.setAutomaticReadEnabled(true)
            broker.disconnect()
        }
        settingsController.uiTestCLIConnection = connection
        settingsController.show(initialSection: 2)
        try await settle()
        connection.setEnabled(.codex, enabled: true)
        try check(connection.installation.installed && connection.installation.enabledHosts == [.codex], "CLI settings enables selected host in fixture home")
        try check(connection.registrations.isEmpty, "installed does not mean connected")
        if let window = settingsController.uiTestWindow {
            try check(window.isVisible && window.frame.height <= (window.screen?.visibleFrame.height ?? 10000), "CLI settings remains visible within screen")
            try await snapshot("cli-settings", window: window)
        }
        connection.setEnabled(.codex, enabled: false)
        try check(!connection.installation.installed && connection.installation.enabledHosts.isEmpty, "CLI settings disables fixture integration")
        settingsController.uiTestWindow?.close()
    }

    private func cliEditor() async throws {
        let previousPreferences = settings.preferences
        try settings.savePreferences(TranslationPreferences(automaticTranslationAndReplacement: false))
        defer { try? settings.savePreferences(previousPreferences) }
        let directory = outputDirectory.appendingPathComponent("CLI synthetic files")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = "合成编辑器草稿\n./path with spaces\n"
        let fileURL = directory.appendingPathComponent("original draft.txt")
        try Data(original.utf8).write(to: fileURL)
        let file = try CLIEditorFile(url: fileURL)
        let session = panel.cliEditor
        let oldFinished = session.onFinished; session.onFinished = nil
        defer { session.onFinished = oldFinished }
        let identity = CLITerminalSession(id: UUID(), kind: .codex, version: "0.157.1", pid: getpid(),
            startTimeMicros: 1, processGroup: 1, tty: "/dev/ttys999", executablePath: "/fixture/codex")
        let registration = CLISessionRegistration(session: identity, codexHome: directory.path, workingDirectory: directory.path)
        var urls: [URL] = []
        defer { urls.forEach { CLIEditorExchange.cleanup($0) } }
        func makeRequest() throws -> (CLIEditorPreflight, URL) {
            let request = CLIEditorPreflight(helperStartTimeMicros: 1, registration: registration)
            let url = try CLIEditorExchange.create(request); urls.append(url); return (request, url)
        }
        func deliver(_ request: CLIEditorPreflight, _ url: URL, source: String = "合成编辑器草稿\n./path with spaces\n") async throws {
            session.acceptPending()
            let grant = try CLIEditorExchange.read(CLIEditorReadPermission.self, from: CLIEditorExchange.file("permission.json", for: url))
            try CLIEditorExchange.write(CLIEditorDraft(id: request.id, intentID: grant.intentID, source: source),
                to: CLIEditorExchange.file("draft.json", for: url))
            await session.receiveDraft()
        }
        let (_, busyURL) = try makeRequest()
        panel.externalCapturing = true
        let denied = await session.receive(busyURL, busy: panel.cliReceptionBusy)
        try check(!denied && !session.active, "desktop capture rejects CLI preflight before body")
        panel.externalCapturing = false
        let (request, url) = try makeRequest()
        let previous = workflow.source
        let received = await session.receive(url, busy: false)
        try check(received && session.needsConsent && workflow.source == previous, "manual request presents metadata without replacing draft")
        try check(!FileManager.default.fileExists(atPath: CLIEditorExchange.file("permission.json", for: url).path), "no body read permission before consent")
        panel.showCollapsed()
        panel.readFromLauncher()
        try await settle()
        try check(panel.uiTestWindow.frame.width == 390 && session.awaitingDraft && !session.needsConsent,
            "manual consent click expands the waiting page without a Dock click")
        try check(workflow.source == previous, "manual waiting page preserves the previous draft until body arrives")
        try await deliver(request, url)
        try await settle()
        try check(workflow.source == original && !session.awaitingDraft && workflow.phase != .translating,
            "consent loads original without starting model")
        try check(!editors().isEmpty && panel.uiTestWindow.frame.width == 390,
            "successful handoff replaces the waiting page with the CLI draft editor")
        let (_, secondURL) = try makeRequest()
        let second = await session.receive(secondURL, busy: false)
        try check(!second && workflow.source == original, "concurrent editor request cannot overwrite current draft")
        try await generate()
        try check(String(contentsOf: fileURL, encoding: .utf8) == original, "generation never writes CLI file")
        workflow.editOutput("translated\n ")
        try check(session.deliveryText == "translated" && !session.outputIsNormalized && session.canSave,
            "preview uses Codex final delivery normalization")
        session.save()
        let response = try CLIEditorExchange.read(CLIEditorResponse.self, from: CLIEditorExchange.file("response.json", for: url))
        try check(response.text == "translated" && session.finishing, "save freezes normalized delivery")
        session.cancel(); try check(session.finishing, "cannot cancel in-flight commit")
        try file.commit(response.text!)
        try CLIEditorExchange.write(CLIEditorCompletion(id: request.id, status: .saved, message: "saved fixture"),
            to: CLIEditorExchange.file("completion.json", for: url))
        session.poll()
        try check(!session.active && session.outcome?.status == .saved, "completion records file save without inventing UI reload")
        try check(String(contentsOf: fileURL, encoding: .utf8) == "translated", "confirmed text written to fixture")
        session.save(); try check(!session.active, "ended request cannot submit twice")
        try check(session.beginRead(sessionID: identity.id), "new read invalidates prior delivery feedback")
        let readingNotice = session.message
        session.reportReturn("old return while reading", requestID: request.id, focus: .returned)
        try check(session.message == readingNotice, "old return cannot replace pending read status")
        session.failRead("new read failed")
        session.reportReturn("old return after failure", requestID: request.id, focus: .returned)
        try check(session.message == "new read failed", "old return cannot replace new read failure")
        let (cancelled, cancelURL) = try makeRequest()
        _ = await session.receive(cancelURL, busy: false); try await deliver(cancelled, cancelURL)
        let currentNotice = session.message
        session.reportReturn("old return callback", requestID: request.id, focus: .returned)
        try check(session.message == currentNotice, "previous return callback cannot replace new draft status")
        workflow.generate(); session.cancel()
        let cancellation = try CLIEditorExchange.read(CLIEditorResponse.self, from: CLIEditorExchange.file("response.json", for: cancelURL))
        try check(cancellation.disposition == .cancelled && cancellation.text == nil, "cancel provides no replacement")
        try CLIEditorExchange.write(CLIEditorCompletion(id: cancelled.id, status: .cancelled, message: "cancelled fixture"),
            to: CLIEditorExchange.file("completion.json", for: cancelURL))
        session.poll(); try await settle()
        try check(!session.active && !workflow.canSaveCLI, "late generation cannot revive cancelled session")
        let (object, objectURL) = try makeRequest()
        _ = await session.receive(objectURL, busy: false); try await deliver(object, objectURL, source: "Inspect [Image #1]")
        try await generate()
        try check(!session.canSave, "unverified object markers block automatic delivery")
        CLIEditorExchange.cleanup(objectURL); session.poll()
        try check(!session.active, "helper cleanup detaches pending request")
        try check(session.beginRead(sessionID: identity.id), "automatic read creates one intent")
        let (automatic, autoURL) = try makeRequest()
        _ = await session.receive(autoURL, busy: false)
        try check(!session.needsConsent && session.readIntent == nil, "matching first preflight consumes read intent")
        let grant = try CLIEditorExchange.read(CLIEditorReadPermission.self, from: CLIEditorExchange.file("permission.json", for: autoURL))
        try CLIEditorExchange.write(CLIEditorDraft(id: automatic.id, intentID: UUID(), source: "wrong intent"),
            to: CLIEditorExchange.file("draft.json", for: autoURL))
        await session.receiveDraft()
        try check(session.finishing && workflow.source != "wrong intent" && grant.id == automatic.id, "wrong draft intent refused")
        CLIEditorExchange.cleanup(autoURL); session.poll()
        let (timed, timedURL) = try makeRequest()
        _ = await session.receive(timedURL, busy: false); try await deliver(timed, timedURL)
        try await generate(); session.save()
        _ = try CLIEditorExchange.withCommitLock(for: timedURL) {
            session.poll(now: .now.advanced(by: .seconds(16)))
            try check(session.active && session.finishing, "commit lock retains request past timeout")
        }
        try CLIEditorExchange.write(CLIEditorCompletion(id: timed.id, status: .saved, message: "saved after wait"),
            to: CLIEditorExchange.file("completion.json", for: timedURL))
        session.poll()
        let (aborted, abortedURL) = try makeRequest()
        _ = await session.receive(abortedURL, busy: false); try await deliver(aborted, abortedURL)
        try await generate(); session.save(); session.poll(now: .now.advanced(by: .seconds(16)))
        try check(!session.active && FileManager.default.fileExists(atPath: CLIEditorExchange.file("aborted", for: abortedURL).path),
            "timeout outside commit lock forbids late write")
        let (failed, failedURL) = try makeRequest()
        _ = await session.receive(failedURL, busy: false); session.acceptPending()
        let sourceBeforeFailure = workflow.source
        try CLIEditorExchange.write(CLIEditorCompletion(id: failed.id, status: .failed, message: "关闭上一回复上下文后重试"),
            to: CLIEditorExchange.file("completion.json", for: failedURL))
        session.poll()
        try check(!session.active && session.message == "关闭上一回复上下文后重试" && workflow.source == sourceBeforeFailure,
            "pre-draft read error reaches UI without overwriting source")
    }

    private func wait(_ assertion: String, timeout: TimeInterval = 8, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try check(condition(), assertion)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(300)) }

    private func manual(_ source: String? = nil) async throws {
        _ = router.useManual()
        await workflow.useManualInput()
        workflow.editSource(source ?? sample)
        await panel.open()
        panel.resetPosition()
        try await settle()
    }

    private func captureNativeHost() async throws {
        host.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = router.useDemo()
        // A real NSTextView edit and its delegate callbacks, not a workflow-state assignment.
        host.editor.insertText(sample, replacementRange: NSRange(location: 0, length: (host.editor.string as NSString).length))
        host.editor.setSelectedRange(NSRange(location: 0, length: (sample as NSString).length))
        await workflow.captureSelection()
        await panel.open()
        panel.resetPosition()
        try await settle()
        try check(workflow.canGenerate, "native host selection can generate")
    }

    private func generate() async throws {
        workflow.generate()
        try await wait("generation reaches ready") { self.workflow.phase == .ready }
        try await settle()
        try check(!workflow.output.isEmpty, "result rendered from local translator")
    }

    private func hostTextChange() async throws {
        try await captureNativeHost()
        try await generate()
        let output = workflow.output
        host.editor.insertText("修改后的合成原文。", replacementRange: NSRange(location: 0, length: (host.editor.string as NSString).length))
        try await wait("native text-change delegate invalidates target") { self.workflow.phase == .blocked }
        try check(!workflow.canGenerate && !workflow.canFill, "stale target disables generation and fill")
        try check(workflow.output == output && workflow.canCopy, "stale target preserves copyable English")
        panel.copyOutputAndReturn()
        try check(panel.uiTestClipboardString == output, "production copy action writes exact result to isolated pasteboard")
        try check(workflow.staleReason != nil, "copy feedback keeps persistent stale warning")
        try await snapshot(scenario)
    }

    private func selectionCycle() async throws {
        try await captureNativeHost()
        try await generate()
        let output = workflow.output
        let original = host.editor.selectedRange()
        host.editor.setSelectedRange(NSRange(location: 0, length: 0))
        host.editor.setSelectedRange(original)
        try await wait("selection A-B-A invalidates target") { self.workflow.phase == .blocked }
        try check(workflow.output == output && workflow.canCopy && !workflow.canFill, "selection cycle keeps result but prevents stale fill")
        await workflow.captureSelection()
        try check(workflow.canGenerate && workflow.output.isEmpty, "recapture associates current selection and clears old result")
        try await snapshot(scenario)
    }

    private func reopenPreservesTarget() async throws {
        try await captureNativeHost()
        try await generate()
        let source = workflow.source
        let output = workflow.output
        let label = workflow.targetLabel
        reopen()
        try await settle()
        try check(workflow.targetLabel == label && !workflow.isManualInput, "AppDelegate reopen preserves host association")
        try check(workflow.source == source && workflow.output == output && workflow.canFill, "AppDelegate reopen preserves draft and valid result")
        try await snapshot(scenario)
    }

    private func manualAfterCaptureFailure(reopenExisting: Bool = false) async throws {
        try await manual()
        try await generate()
        workflow.editOutput("MANUALLY EDITED TRANSLATION")
        let source = workflow.source
        let output = workflow.output
        let sourceDocument = workflow.sourceDocumentID
        let outputDocument = workflow.outputDocumentID

        // UI fixtures inject a failed capture without accessing an external application.
        panel.readAndTranslate()
        try await wait("failed external capture finishes") {
            !self.panel.blocksEntrySwitch
        }
        try check(router.isManual && workflow.staleReason == ExternalInputError.noFocusedInput.errorDescription,
                  "failed capture preserves the manual route and actual failure reason")
        if reopenExisting {
            reopen()
            try await settle()
            try check(workflow.canGenerate, "reopening the existing manual draft permits generation without selecting direct input")
        } else {
            guard let item = NSApp.mainMenu?.items.first?.submenu?.item(withTitle: "直接输入"),
                  let action = item.action else { throw Failure.assertion("Missing direct input menu action") }
            try check(NSApp.sendAction(action, to: item.target, from: item), "actual direct input menu action is dispatched")
            try await wait("direct input restores generation after a failed capture") { self.workflow.canGenerate }
        }
        try check(workflow.source == source && workflow.output == output && workflow.staleReason != nil,
                  "manual reentry preserves source and edited old translation")
        try check(workflow.sourceDocumentID == sourceDocument && workflow.outputDocumentID == outputDocument,
                  "manual reentry preserves editor documents and undo history")
        try check(!workflow.canFill, "manual reentry never revives external write permission")
        try await settle()
        guard let editor = editors().first else { throw Failure.assertion("Missing manual source editor") }
        editor.insertText("", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try check(workflow.source.isEmpty && !workflow.canGenerate, "empty direct input still disables generation")
        editor.insertText(sample, replacementRange: NSRange(location: 0, length: 0))
        try check(workflow.canGenerate, "native direct input enables generation after reentry")
        try commandReturn()
        try await wait("manual draft generates through the panel action") { self.workflow.phase == .ready }
        try check(workflow.canCopy && !workflow.canFill, "generated manual translation can be copied")
        try await snapshot(scenario)
    }

    private func editors() -> [CompositionTextView] {
        descendants(panel.uiTestWindow.contentView).compactMap { $0 as? CompositionTextView }
    }

    private func descendants(_ root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants($0) }
    }

    private func commandReturn() throws {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.uiTestWindow.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw Failure.assertion("Cannot construct keyboard event")
        }
        _ = panel.uiTestWindow.performKeyEquivalent(with: event)
    }

    private func nativeComposition() async throws {
        try await manual()
        guard let sourceEditor = editors().first else { throw Failure.assertion("Missing native source editor") }
        sourceEditor.setSelectedRange(NSRange(location: (sourceEditor.string as NSString).length, length: 0))
        sourceEditor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(sourceEditor.hasMarkedText() && workflow.sourceIsComposing, "native marked text reaches workflow")
        try commandReturn()
        panel.collapse()
        try check(!workflow.canGenerate && workflow.phase != .translating, "marked source blocks real panel generation action")
        try check(panel.uiTestWindow.frame.width == 390, "marked source prevents collapse")
        try await snapshot("source-ime")
        sourceEditor.insertText("你", replacementRange: sourceEditor.markedRange())
        try check(!workflow.sourceIsComposing && workflow.canGenerate, "committed candidate restores generation")
        try commandReturn()
        try await wait("command Return generates after commit") { self.workflow.phase == .ready }
        try await settle()
        guard let outputEditor = editors().last, outputEditor !== sourceEditor else { throw Failure.assertion("Missing native output editor") }
        outputEditor.setSelectedRange(NSRange(location: (outputEditor.string as NSString).length, length: 0))
        outputEditor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(workflow.outputIsComposing && !workflow.canCopy && !workflow.canGenerate, "output candidate blocks copy and generation")
        panel.copyOutputAndReturn()
        try check(panel.uiTestClipboardString != workflow.output, "copy action ignores uncommitted output")
        try await snapshot("output-ime")
        outputEditor.insertText("你", replacementRange: outputEditor.markedRange())
        try check(!workflow.outputIsComposing && workflow.canCopy, "committed output restores copy")
    }

    private func settingsComposition() async throws {
        try await manual()
        try settings.apply(ProviderConfiguration(format: .chatCompletions, baseURL: "http://127.0.0.1:1", model: "fixture-model", apiKey: ""))
        // Only configuring a fixture; this scenario never generates or opens a network connection.
        panel.suspendForSettings()
        settingsController.show()
        try await settle()
        guard let window = settingsController.uiTestWindow,
              let field = descendants(window.contentView).compactMap({ $0 as? NSTextField }).first(where: { $0.isEditable && $0.stringValue == "fixture-model" }),
              window.makeFirstResponder(field), let fieldEditor = window.firstResponder as? NSTextView else {
            throw Failure.assertion("Missing model field editor")
        }
        fieldEditor.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        window.cancelOperation(nil)
        try check(window.isVisible && fieldEditor.hasMarkedText(), "settings cancel action preserves active candidate")
        try await snapshot("settings-ime", window: window)
        fieldEditor.unmarkText()
        window.cancelOperation(nil)
        try await settle()
        try check(window.isVisible && window.attachedSheet != nil, "settings protects committed unsaved edits with close prompt")
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        try await settle()
        window.close()
        try settings.apply(nil)
    }

    private func settingsForm() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PromptBridgeForm-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config/providers.json")
        let isolated = TranslationSettings(loadEnvironment: false, configFileURL: file)
        try await wait("isolated configuration load") { !isolated.isLoading }
        let controller = SettingsController(settings: isolated, modelsLoader: { _ in [ModelOption(id: "fixture-selected", displayName: "测试模型")] })
        controller.show()
        try await settle()
        guard let window = controller.uiTestWindow, let editor = controller.uiTestEditor else { throw Failure.assertion("Missing settings window") }
        defer { window.close() }
        func press(_ title: String) throws {
            guard let button = accessibilityElements(window).first(where: {
                let role = $0.accessibilityRole?() ?? nil
                let label = ($0.accessibilityLabel?() ?? nil) ?? ($0.accessibilityTitle?() ?? nil) ?? ""
                return role == .button && label.contains(title)
            }), button.accessibilityPerformPress?() == true else { throw Failure.assertion("Missing settings button: \(title)") }
        }
        editor.add()
        editor.form.name = "123"
        editor.setFormat(.responses)
        editor.setBaseURL("https://supplier.example/custom/v1")
        editor.setKey("SYNTHETIC_KEY_123")
        editor.form.configuration.model = "fixture-manual"
        try await settle()
        try check(descendants(window.contentView).compactMap { $0 as? NSSecureTextField }.first?.stringValue == "SYNTHETIC_KEY_123", "custom supplier key appears in secure field")
        try press("获取模型")
        try await wait("model list fetched") { !editor.isFetchingModels }
        try check(editor.models.map(\.id) == ["fixture-selected"] && editor.form.configuration.model == "fixture-manual", "fetch models populates selection without overwriting manual model")
        editor.form.configuration.model = editor.models[0].id
        try press("保存预设")
        try check(window.isVisible && isolated.presets.first?.name == "123" && isolated.isDemo, "save preset writes named supplier without selecting a new active supplier")
        let first = editor.form.id
        try press("新增")
        editor.form.name = "ABC"
        editor.setBaseURL("https://second.example/v1")
        editor.setKey("SYNTHETIC_KEY_ABC")
        editor.form.configuration.model = "second-model"
        try await settle()
        try press("保存预设")
        editor.select(first)
        try await settle()
        try check(editor.form.name == "123" && editor.form.configuration.apiKey == "SYNTHETIC_KEY_123" && editor.form.configuration.format == .responses, "select saved supplier restores its format URL key and model")
        try await snapshot("settings-custom-providers", window: window)
        try press("保存并使用")
        try check(window.isVisible && isolated.activePresetID == first && isolated.configuration?.model == "fixture-selected", "save and use activates chosen model")
        let disk = try ProviderLibraryStore(fileURL: file).load()
        try check(disk == isolated.library && disk?.presets.count == 2, "settings buttons persist both suppliers and active choice to JSON")
        controller.show()
        try await settle()
        guard let reopened = controller.uiTestWindow else { throw Failure.assertion("Missing reopened settings") }
        controller.uiTestSession?.showsModelFile = true
        try await settle()
        let importButton = accessibilityElements(reopened).first { (($0.accessibilityLabel?() ?? nil) ?? ($0.accessibilityTitle?() ?? nil) ?? "").contains("导入环境文件") }
        try check(importButton?.accessibilityPerformPress?() == true, "native import button remains available")
        try await settle()
        guard let picker = reopened.attachedSheet as? NSOpenPanel else { throw Failure.assertion("Missing native file picker") }
        picker.cancel(nil)
        try await settle()
        try check(reopened.isVisible && isolated.library == disk && !isolated.isImporting, "cancel native picker preserves saved configuration")
        reopened.close()
    }

    private func accessibilityElements(_ root: AnyObject) -> [AnyObject] {
        var queue: [AnyObject] = [root]
        var seen: Set<ObjectIdentifier> = []
        var result: [AnyObject] = []
        while let element = queue.popLast() {
            guard seen.insert(ObjectIdentifier(element)).inserted else { continue }
            result.append(element)
            queue.append(contentsOf: (element.accessibilityChildren?() ?? nil)?.map { $0 as AnyObject } ?? [])
        }
        return result
    }

    @MainActor
    private final class FocusLauncherWire: BrokerEndpoint {
        var onEvent: ((Data) -> Void)?
        var onDisconnect: (() -> Void)?
        let epoch = UUID()
        private(set) var subscriptions: [LauncherMode] = []
        private(set) var helperMode: LauncherMode?
        var failNextFocusedSubscription = false
        var holdPersistent = false
        private var sequence: UInt64 = 0
        private var persistentWaiter: CheckedContinuation<Void, Never>?

        func exchange(_ data: Data) async throws -> Data {
            let request = try BrokerCodec.request(data)
            sequence += 1
            if request.operation == .subscribe {
                let mode = request.payload?.launcherMode ?? .persistent
                subscriptions.append(mode)
                if mode == .focusedInput, failNextFocusedSubscription {
                    failNextFocusedSubscription = false
                    return try BrokerCodec.encode(BrokerResponse(requestID: request.requestID, epoch: epoch,
                        stateSequence: sequence, error: .unavailable))
                }
                if mode == .persistent, holdPersistent {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                        persistentWaiter = continuation
                    }
                }
                helperMode = mode
            }
            return try BrokerCodec.encode(BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: sequence))
        }

        func disconnect() {}

        func releasePersistent() {
            holdPersistent = false
            persistentWaiter?.resume()
            persistentWaiter = nil
        }

        func emit(_ focus: BrokerFocusState) throws {
            sequence += 1
            let event = BrokerEvent(epoch: epoch, stateSequence: sequence, focus: focus)
            onEvent?(try BrokerCodec.encode(event))
        }
    }

    /// A Foundation-only broker endpoint. It speaks the production Codable wire
    /// contract so this flow exercises live capture, scope, replace, restore and
    /// focus decisions without importing the AX runtime or retaining native handles.
    @MainActor
    private final class WireInputFixture: BrokerEndpoint {
        var onEvent: ((Data) -> Void)?
        var onDisconnect: (() -> Void)?
        let epoch: UUID
        let hostName: String
        let source: String
        private let initialFullText: String
        private let initialSelectedText: String
        private let initialSelectionLocation: Int
        private let withholdRestoreSnapshotValidation: Bool
        private var sequence: UInt64 = 0
        private var token = UUID()
        private var revision: UInt64 = 0
        private var text = ""
        private var selectedText = ""
        private var selectionLocation = 0
        private var originalSelectionRange = NSRange(location: 0, length: 0)
        private var scope: CaptureScope = .entireInput
        private var restorationToken: UUID?
        private var original = ""
        private var writeAttempts = 0
        private(set) var acquiredScopeCount = 0
        private(set) var lastScopeTarget: BrokerTargetReference?
        var scopeBusy = false
        var replacementError: BrokerErrorCode?
        var rejectValidation = false
        var disconnectOnValidation = false
        private(set) var returnFocusCount = 0

        init(epoch: UUID, hostName: String, source: String,
             fullText: String? = nil, selectedText: String? = nil, selectionLocation: Int = 0,
             withholdRestoreSnapshotValidation: Bool = false) {
            self.epoch = epoch; self.hostName = hostName; self.source = source
            initialFullText = fullText ?? source
            initialSelectedText = selectedText ?? source
            initialSelectionLocation = selectionLocation
            self.withholdRestoreSnapshotValidation = withholdRestoreSnapshotValidation
        }

        func exchange(_ data: Data) async throws -> Data {
            try handle(data)
        }

        func disconnect() { onDisconnect?() }

        private func handle(_ data: Data) throws -> Data {
            let request = try BrokerCodec.request(data)
            sequence += 1
            switch request.operation {
            case .capture:
                token = UUID(); revision += 1; text = initialFullText; original = initialFullText
                selectedText = initialSelectedText; selectionLocation = initialSelectionLocation
                originalSelectionRange = NSRange(location: initialSelectionLocation,
                    length: initialSelectedText.utf16.count)
                scope = request.payload?.scope ?? .entireInput
                return try response(request, state: state())
            case .validate:
                if disconnectOnValidation {
                    onDisconnect?()
                    throw BrokerTransportError.unavailable
                }
                if rejectValidation { return try response(request, error: .targetChanged) }
                if withholdRestoreSnapshotValidation, restorationToken != nil {
                    return try response(request, state: restorationState())
                }
                return try response(request, state: state())
            case .acquireScope:
                let kind = request.payload?.scopeRequest?.kind ?? .panel
                acquiredScopeCount += 1
                lastScopeTarget = request.payload?.scopeRequest?.target
                if scopeBusy { return try response(request, error: .busy) }
                let captured = request.payload?.scopeRequest?.target?.captureToken
                return try response(request, receipt: BrokerScopeReceipt(scopeID: UUID(), kind: kind, captureToken: captured))
            case .replace:
                if let replacementError { return try response(request, error: replacementError) }
                guard let write = request.payload?.write else { throw BrokerContractError.invalidMessage }
                guard scope == .entireInput else { throw BrokerContractError.invalidMessage }
                original = text
                let range = write.expected.selection
                guard range.location >= 0, range.length >= 0,
                      NSMaxRange(range) <= (text as NSString).length else {
                    throw BrokerContractError.invalidMessage
                }
                text = (text as NSString).replacingCharacters(in: range, with: write.text)
                selectedText = write.text; selectionLocation = range.location
                writeAttempts += 1; revision += 1
                restorationToken = UUID()
                let receipt = ReplacementReceipt(expected: write.expected, writtenText: write.text)
                return try response(request, state: state(), replacement: receipt)
            case .restore:
                guard request.payload?.restore?.restorationToken == restorationToken else {
                    throw BrokerContractError.invalidMessage
                }
                text = original
                let range = originalSelectionRange
                guard range.location >= 0, NSMaxRange(range) <= (text as NSString).length else {
                    throw BrokerContractError.invalidMessage
                }
                selectedText = (text as NSString).substring(with: range)
                revision += 1; restorationToken = nil; writeAttempts += 1
                let expected = snapshot()
                return try response(request, state: state(), replacement: ReplacementReceipt(expected: expected, writtenText: text))
            case .returnFocus:
                returnFocusCount += 1
                return try response(request, focusReturned: true)
            case .releaseScope, .invalidate, .subscribe:
                return try response(request)
            default:
                throw BrokerContractError.invalidMessage
            }
        }

        func emitRestorationState() throws {
            sequence += 1
            let event = BrokerEvent(epoch: epoch, stateSequence: sequence,
                runtimeState: restorationState())
            onEvent?(try BrokerCodec.encode(event))
        }

        private func snapshot() -> InputSnapshot {
            let selected = scope == .selection ? selectedText : text
            let range = scope == .selection
                ? NSRange(location: selectionLocation, length: selected.utf16.count)
                : NSRange(location: 0, length: (text as NSString).length)
            return InputSnapshot(identity: InputIdentity(host: hostName, window: "wire-window", input: "wire-input", session: "wire-session", bundleIdentifier: hostName == "微信" ? "com.tencent.xinWeChat" : hostName == "QQ" ? "com.tencent.qq" : nil),
                revision: revision, selection: range,
                selectedText: selected, supportsDirectFill: scope == .entireInput, captureScope: scope,
                fullText: scope == .entireInput ? text : nil, contextID: nil, captureID: token)
        }

        private func state() -> BrokerRuntimeState {
            let canRestore = restorationToken != nil
            return BrokerRuntimeState(snapshot: snapshot(), captureToken: token, revision: revision,
                frame: BrokerRect(x: 100, y: 100, width: 300, height: 40), restorationToken: restorationToken,
                canRestore: canRestore, canReturnFocus: true, hasTarget: true, hostName: hostName,
                lastReadFailure: nil, writeAttempts: writeAttempts, lastObservedChange: nil,
                replacementStage: nil)
        }

        private func restorationState() -> BrokerRuntimeState {
            BrokerRuntimeState(snapshot: nil, captureToken: token, revision: revision,
                frame: BrokerRect(x: 100, y: 100, width: 300, height: 40),
                restorationToken: restorationToken, canRestore: true, canReturnFocus: true,
                hasTarget: false, hostName: hostName, lastReadFailure: nil,
                writeAttempts: writeAttempts, lastObservedChange: nil, replacementStage: nil)
        }

        private func response(_ request: BrokerRequest, state: BrokerRuntimeState? = nil,
                              replacement: ReplacementReceipt? = nil, receipt: BrokerScopeReceipt? = nil,
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

    private func mainFocusLauncherLifecycle() async throws -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let wire = FocusLauncherWire()
        let identity = BrokerApplicationIdentity(pid: max(1, Int32(ProcessInfo.processInfo.processIdentifier)),
            bundle: BrokerIdentity.clientBundle, path: Bundle.main.bundleURL.path,
            version: "fixture", build: "fixture")
        let client = BrokerClient(endpoint: wire, ownIdentity: identity,
            initialVerifiedClient: identity, initialEpoch: wire.epoch)
        var states: [FocusLauncherState] = []
        let launcher = MainFocusLauncher(client: client) { states.append($0) }
        let target = BrokerFocusState.target(BrokerFocusTarget(pid: 42, bundle: "com.openai.codex",
            windowToken: UUID(), inputToken: UUID(), anchor: BrokerRect(x: 100, y: 100, width: 240, height: 50)))

        launcher.setMode(.focusedInput)
        try await Task.sleep(for: .milliseconds(50))
        try wire.emit(target)
        try await Task.sleep(for: .milliseconds(50))
        checks.append(("focused broker subscription publishes metadata target", launcher.state != .unavailable
                       && states.contains(where: { if case .target = $0 { return true }; return false })
                       && wire.subscriptions.last == .focusedInput))

        wire.holdPersistent = true
        launcher.stop()
        try await Task.sleep(for: .milliseconds(50))
        try wire.emit(target)
        launcher.setMode(.focusedInput)
        try await Task.sleep(for: .milliseconds(50))
        let persistentPending = wire.subscriptions.last == .persistent && wire.helperMode == .focusedInput
        wire.releasePersistent()
        try await Task.sleep(for: .milliseconds(50))
        try wire.emit(target)
        try await Task.sleep(for: .milliseconds(50))
        checks.append(("mode commands stay serial and final helper mode remains focused after delayed persistent ack",
                       persistentPending && wire.helperMode == .focusedInput && launcher.state != .unavailable))

        wire.failNextFocusedSubscription = true
        launcher.setMode(.focusedInput)
        try await Task.sleep(for: .milliseconds(50))
        let failedSubscriptions = wire.subscriptions.count
        launcher.setMode(.focusedInput)
        try await Task.sleep(for: .milliseconds(50))
        try wire.emit(target)
        checks.append(("failed focused subscription clears local subscriber for explicit retry",
                       wire.subscriptions.count == failedSubscriptions + 1 && launcher.state != .unavailable))

        wire.holdPersistent = true
        launcher.stop()
        try await Task.sleep(for: .milliseconds(50))
        let beforePause = wire.subscriptions.count
        launcher.suspendForInstallation()
        try await Task.sleep(for: .milliseconds(25))
        checks.append(("installation suspension sends no new subscription", wire.subscriptions.count == beforePause))
        launcher.setMode(.focusedInput)
        wire.releasePersistent()
        try await Task.sleep(for: .milliseconds(100))
        try wire.emit(target)
        checks.append(("explicit resume restarts a cancelled in-flight mode command",
            wire.helperMode == .focusedInput && launcher.state != .unavailable))
        let beforeBlocked = wire.subscriptions.count
        await DesktopInstallation.shared.withPausedOperations {
            do {
                _ = try await client.request(.subscribe, payload: BrokerPayload(launcherMode: .focusedInput))
                checks.append(("installation prevents new broker operations", false))
            } catch {
                checks.append(("installation prevents new broker operations", wire.subscriptions.count == beforeBlocked))
            }
        }

        client.disconnect()
        try wire.emit(.target(BrokerFocusTarget(pid: 43, bundle: "com.openai.codex",
            windowToken: UUID(), inputToken: UUID(), anchor: BrokerRect(x: 100, y: 100, width: 240, height: 50))))
        checks.append(("broker disconnect immediately clears launcher target metadata",
                       launcher.state == .unavailable))
        return checks
    }

    private func fullInputFlow() async throws {
        panel.hideLauncher()
        for hostName in ["Claude", "ChatGPT / Codex", "微信", "QQ"] {
            let epoch = UUID()
            let wire = WireInputFixture(epoch: epoch, hostName: hostName, source: ExternalAcceptanceBridge.source,
                withholdRestoreSnapshotValidation: true)
            let identity = BrokerApplicationIdentity(pid: max(1, Int32(ProcessInfo.processInfo.processIdentifier)),
                bundle: BrokerIdentity.clientBundle, path: Bundle.main.bundleURL.path,
                version: "fixture", build: "fixture")
            let client = BrokerClient(endpoint: wire, ownIdentity: identity,
                initialVerifiedClient: identity, initialEpoch: epoch)
            let input = ExternalInput(client: client)
            let localRouter = HostRouter(demo: host, external: input)
            let localSettings = TranslationSettings(loadEnvironment: false)
            try localSettings.savePreferences(TranslationPreferences(automaticTranslationAndReplacement: false))
            let localWorkflow = DraftWorkflow(host: localRouter, translator: DemoTranslator())
            localRouter.onChange = { [weak localWorkflow] in localWorkflow?.hostDidChange() }
            input.onReplacementStage = { [weak localWorkflow] in localWorkflow?.replacementStageDidChange($0) }
            let controller = PanelController(workflow: localWorkflow, host: localRouter, settings: localSettings,
                openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName(),
                captureFullInput: { try await localRouter.captureExternalFullInput() })
            controller.showCollapsed()
            try await settle()
            let window = controller.uiTestWindow
            defer { controller.hideLauncher() }
            try check(!window.canBecomeKey && !window.hidesOnDeactivate,
                      "\(hostName) pinned launcher is nonactivating before live broker capture")
            func press(_ label: String) throws {
                guard let button = accessibilityElements(window).first(where: {
                    let title = ($0.accessibilityLabel?() ?? nil) ?? ($0.accessibilityTitle?() ?? nil) ?? ""
                    return ($0.accessibilityRole?() ?? nil) == .button && title.contains(label)
                }), button.accessibilityPerformPress?() == true else {
                    throw Failure.assertion("Missing full-input action: \(label)")
                }
            }
            try press("读取输入框全文")
            try await wait("\(hostName) click captures and translates") { localWorkflow.phase == .ready || localWorkflow.phase == .blocked }
            try check(localWorkflow.source == ExternalAcceptanceBridge.source && localWorkflow.phase == .ready,
                      "\(hostName) launcher reads whole draft through live broker metadata and translates")
            try check(input.snapshot()?.selection.location == 0 && input.snapshot()?.selection.length == (ExternalAcceptanceBridge.source as NSString).length,
                      "\(hostName) broker capture reports the entire UTF16 input range")
            try check(localWorkflow.canFill && !localWorkflow.isCopyOnlyTarget,
                      "\(hostName) approved whole-input capture enables replacement without context ID")
            localWorkflow.editOutput("EDITED ENGLISH FIXTURE")
            try await settle()
            try await snapshot(hostName == "Claude" ? "claude-full-input-ready" : hostName == "微信" ? "wechat-full-input-ready" : hostName == "QQ" ? "qq-full-input-ready" : "codex-full-input-ready", window: window, state: localWorkflow)
            try press("确认替换")
            try await wait("\(hostName) replacement finishes") { localWorkflow.phase != .filling }
            try wire.emitRestorationState()
            try check(localWorkflow.phase == .filled && input.snapshot() == nil
                      && input.canRestoreOriginal && localWorkflow.canCopy
                      && !localWorkflow.canFill && input.writeAttempts == 1,
                      "\(hostName) replacement writes once and retains only a live restoration receipt when snapshot reads are unavailable")
            try await settle()
            try check(window.frame.width == 186,
                      "\(hostName) verified write collapses after broker receipt")
            guard await input.liveRestorationIsValid() else { throw Failure.assertion("Live restoration validation lost replacement receipt") }
            try check(input.canRestoreOriginal && input.writeAttempts == 1,
                      "\(hostName) live validation preserves the restoration receipt")
            await controller.open()
            try await settle()
            if hostName == "Claude", let record = localWorkflow.replacementRecord {
                let recordWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                    styleMask: [.titled], backing: .buffered, defer: false)
                recordWindow.contentView = NSHostingView(rootView: ReplacementRecordView(record: record, copy: { _ in }, close: {}))
                recordWindow.orderFront(nil)
                try await snapshot("replacement-record", window: recordWindow, state: localWorkflow)
                recordWindow.orderOut(nil)
            }
            try check(input.canRestoreOriginal && input.writeAttempts == 1,
                      "\(hostName) opening the panel does not consume the restoration receipt")
            guard try await controller.beginStatusMenuTracking() != nil else {
                throw Failure.assertion("Snapshotless restoration could not acquire the native menu scope")
            }
            try check(controller.uiTestContextMenuTracking && input.hasTarget == false
                      && wire.lastScopeTarget == nil,
                      "snapshotless restoration expands and tracks a native menu without reviving the old target")
            await controller.endStatusMenuTracking()
            try press("恢复原文")
            try await wait("\(hostName) original restored") { !controller.isBusy }
            try check(input.snapshot()?.fullText == ExternalAcceptanceBridge.source && input.writeAttempts == 2,
                      "\(hostName) explicit recovery restores original whole draft exactly once")
            try check(!input.canRestoreOriginal, "\(hostName) recovery receipt is consumed")
            let repeatedRestore = try? await input.restoreOriginalInput()
            try check(repeatedRestore == nil && input.writeAttempts == 2 && !input.canRestoreOriginal,
                      "\(hostName) repeated recovery is rejected without another write")
        }
    }

    private func externalSelectionFlow() async throws {
        panel.hideLauncher()
        let selected = ExternalAcceptanceBridge.source
        let prefix = "保留前缀："
        let suffix = "：保留后缀 😀"
        let fullText = prefix + selected + suffix
        let selectionLocation = (prefix as NSString).length
        let epoch = UUID()
        let wire = WireInputFixture(epoch: epoch, hostName: "ChatGPT / Codex", source: selected,
            fullText: fullText, selectedText: selected, selectionLocation: selectionLocation)
        let identity = BrokerApplicationIdentity(pid: max(1, Int32(ProcessInfo.processInfo.processIdentifier)),
            bundle: BrokerIdentity.clientBundle, path: Bundle.main.bundleURL.path,
            version: "fixture", build: "fixture")
        let client = BrokerClient(endpoint: wire, ownIdentity: identity,
            initialStatus: wire.status(), initialVerifiedClient: identity, initialEpoch: epoch)
        let input = ExternalInput(client: client)
        let localRouter = HostRouter(demo: host, external: input)
        let localSettings = TranslationSettings(loadEnvironment: false)
        let localWorkflow = DraftWorkflow(host: localRouter, translator: DemoTranslator())
        let controller = PanelController(workflow: localWorkflow, host: localRouter, settings: localSettings,
            openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName())
        defer { controller.hideLauncher(); input.clear() }

        try await localRouter.captureExternal()
        await localWorkflow.captureSelection()
        guard let snapshot = await input.liveSnapshot() else { throw ExternalInputError.unavailable }
        let expectedRange = NSRange(location: selectionLocation, length: (selected as NSString).length)
        try check(snapshot.captureScope == .selection && snapshot.selectedText == selected
                  && snapshot.fullText == nil && !snapshot.supportsDirectFill
                  && snapshot.selection == expectedRange,
                  "external selection capture preserves selected text and UTF16 range without carrying whole-input text")
        try check(localWorkflow.source == selected && localWorkflow.canGenerate
                  && localWorkflow.isCopyOnlyTarget && !localWorkflow.canFill,
                  "external selection flow is copy-only and cannot authorize direct fill")
        await controller.open()
        localWorkflow.generate()
        try await wait("selection generation reaches ready") { localWorkflow.phase == .ready }
        try check(localWorkflow.canCopy && !localWorkflow.canFill,
                  "selection generation enables copying while keeping fill disabled")
        localWorkflow.editOutput("SELECTION RESULT")
        localWorkflow.fill()
        try await settle()
        try check(localWorkflow.phase == .ready && input.writeAttempts == 0 && !input.canRestoreOriginal,
                  "selection fill attempt is rejected without a setter or restoration receipt")
        let previousFocus = controller.uiTestWindow.firstResponder
        let returnCount = wire.returnFocusCount
        controller.copyOutputOnly()
        try check(controller.uiTestWindow.frame.width == 390 && controller.uiTestWindow.firstResponder === previousFocus
                  && wire.returnFocusCount == returnCount && input.writeAttempts == 0,
                  "copy-only preserves expanded panel and responder without returning or writing")
        let scopesBeforeCopyReturn = wire.acquiredScopeCount
        var copyReturned: Bool?
        controller.onCopyReturn = { copyReturned = $0 }
        controller.copyOutputAndReturn()
        try await wait("selection copy returns to host") { copyReturned != nil }
        try check(wire.acquiredScopeCount == scopesBeforeCopyReturn + 1,
                  "copy and return acquires a broker UI scope before changing responders")
        try check(controller.uiTestClipboardString == "SELECTION RESULT" && copyReturned == true
                  && !controller.isBusy && input.writeAttempts == 0 && !input.canRestoreOriginal,
                  "selection copies the generated result and returns focus without writing or restoring")

        for failure in ["target changed", "component disconnected"] {
            try await localRouter.captureExternal()
            await localWorkflow.captureSelection()
            localWorkflow.generate()
            try await wait("copy recovery draft reaches ready") { localWorkflow.phase == .ready }
            let source = localWorkflow.source
            let output = localWorkflow.output
            let focusCount = wire.returnFocusCount
            var callbacks: [Bool] = []
            controller.onCopyReturn = { callbacks.append($0) }
            wire.rejectValidation = failure == "target changed"
            wire.disconnectOnValidation = failure == "component disconnected"
            controller.copyOutputAndReturn()
            try await wait("copy failure reports its outcome") { !callbacks.isEmpty }
            try check(!controller.isBusy && callbacks == [false]
                      && controller.uiTestClipboardString == output && localWorkflow.output == output
                      && localWorkflow.source == source && wire.returnFocusCount == focusCount,
                      "copy return \(failure) releases busy, preserves text, and reports once without returning focus")
            await controller.open()
            try check(controller.uiTestWindow.frame.width == 390 && localWorkflow.canCopy,
                      "copy return \(failure) permits reopening and copying the preserved result")
            controller.copyOutputAndReturn()
            try await wait("another copy completes after \(failure)") { !controller.isBusy }
            try check(controller.uiTestClipboardString == output && !controller.isBusy,
                      "copy return \(failure) permits another copy and releases busy again")
            wire.rejectValidation = false
            guard await localWorkflow.prepareForEntrySwitch() else { throw Failure.assertion("copy failure blocks entry switch") }
            _ = localRouter.useManual()
            await localWorkflow.useManualInput()
            try check(localWorkflow.isManualInput, "copy return \(failure) permits changing entry")
        }
    }

    private func savedExternalDraftOpen() async throws {
        let epoch = UUID()
        let wire = WireInputFixture(epoch: epoch, hostName: "ChatGPT / Codex", source: ExternalAcceptanceBridge.source)
        let identity = BrokerApplicationIdentity(pid: max(1, Int32(ProcessInfo.processInfo.processIdentifier)),
            bundle: BrokerIdentity.clientBundle, path: Bundle.main.bundleURL.path,
            version: "fixture", build: "fixture")
        let client = BrokerClient(endpoint: wire, ownIdentity: identity,
            initialVerifiedClient: identity, initialEpoch: epoch)
        let input = ExternalInput(client: client)
        let localRouter = HostRouter(demo: host, external: input)
        let localSettings = TranslationSettings(loadEnvironment: false)
        let localWorkflow = DraftWorkflow(host: localRouter, translator: DemoTranslator())
        let controller = PanelController(workflow: localWorkflow, host: localRouter, settings: localSettings,
            openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName())
        defer { controller.hideLauncher(); input.clear() }

        try await localRouter.captureExternal()
        await localWorkflow.captureSelection()
        localWorkflow.generate()
        try await wait("saved external draft generation reaches ready") { localWorkflow.phase == .ready }
        let savedSource = localWorkflow.source
        let savedOutput = localWorkflow.output
        guard await localWorkflow.prepareForEntrySwitch() else { throw Failure.assertion("Could not leave external draft") }
        _ = localRouter.useManual()
        await localWorkflow.useManualInput()
        localRouter.useExternalDraft()
        await localWorkflow.openSavedEntry(.codex)
        await controller.open()
        try check(controller.uiTestWindow.isVisible && controller.uiTestWindow.canBecomeKey
                  && localWorkflow.entry == .codex && localWorkflow.phase == .blocked
                  && localWorkflow.source == savedSource && localWorkflow.output == savedOutput,
                  "saved external draft opens as a preserved copyable draft without a live target")
        try check(!input.hasTarget && wire.acquiredScopeCount == 0 && !localWorkflow.canFill && localWorkflow.canCopy,
                  "opening a saved external draft neither revives an old token nor acquires a write scope")
        let scopesBeforeBusy = wire.acquiredScopeCount
        wire.scopeBusy = true
        var busyRejected = false
        do { _ = try await controller.beginStatusMenuTracking() } catch { busyRejected = true }
        wire.scopeBusy = false
        try check(busyRejected && !controller.uiTestContextMenuTracking
                  && wire.acquiredScopeCount == scopesBeforeBusy + 1,
                  "connected broker scope failure rejects a no-target menu instead of falling back locally")
        let scopesBeforeDisconnect = wire.acquiredScopeCount
        client.disconnect()
        try check(!input.hasTarget && !input.canRestoreOriginal && localWorkflow.canCopy,
                  "broker disconnect preserves the saved copyable draft without a target or restore receipt")
        controller.copyOutputAndReturn()
        try check(controller.uiTestClipboardString == savedOutput && !input.hasTarget && !input.canRestoreOriginal,
                  "disconnected saved draft still copies without attempting an external write")
        controller.hideLauncher()
        await controller.open()
        try check(controller.uiTestWindow.isVisible && controller.uiTestWindow.canBecomeKey,
                  "disconnected saved draft can reopen the expanded panel")
        guard try await controller.beginStatusMenuTracking() != nil else {
            throw Failure.assertion("Disconnected saved draft could not open the local native menu")
        }
        try check(controller.uiTestContextMenuTracking && wire.acquiredScopeCount == scopesBeforeDisconnect,
                  "disconnected saved draft uses local menu tracking without a broker scope")
        await controller.endStatusMenuTracking()
        _ = localRouter.useManual()
        await localWorkflow.useManualInput()
        localWorkflow.editSource("manual fallback draft")
        await controller.open()
        try check(localRouter.isManual && !localRouter.isExternal && !input.hasTarget && !input.canRestoreOriginal
                  && controller.uiTestWindow.isVisible,
                  "disconnected saved draft can enter manual input without reviving external state")
    }

    private func languageComboComposition() async throws {
        try await manual()
        try await generate()
        guard let combo = descendants(panel.uiTestWindow.contentView).compactMap({ $0 as? NSComboBox }).first else {
            throw Failure.assertion("Missing native language combo")
        }
        combo.selectText(nil)
        guard let field = combo.currentEditor() as? NSTextView else { throw Failure.assertion("Missing language field editor") }
        let result = workflow.output
        let clipboard = panel.uiTestClipboardString
        field.setMarkedText(workflow.targetLanguage, selectedRange: NSRange(location: 0, length: 0),
                            replacementRange: NSRange(location: 0, length: (field.string as NSString).length))
        try check(field.hasMarkedText() && panel.isBusy, "same-text language composition blocks local actions independently of pending text")
        panel.collapse()
        panel.hideLauncher()
        panel.applicationLostFocus()
        try check(panel.uiTestWindow.isVisible && panel.uiTestWindow.frame.width == 390,
                  "language composition preserves expanded editor through collapse hide and deactivation")
        panel.copyOutputAndReturn()
        try check(panel.uiTestClipboardString == clipboard && workflow.output == result,
                  "language composition prevents copying a possibly obsolete target-language result")
        field.unmarkText()
        try await settle()
        try check(!panel.isBusy && panel.uiTestWindow.firstResponder === field,
                  "confirming language candidate restores actions while keeping field focus")
        panel.uiTestWindow.makeFirstResponder(nil)
        try await settle()
        try check(!panel.isBusy && workflow.output == result, "ending language composition restores actions without regenerating")
    }

    private func languageComboEvents() throws {
        var value = "English"
        var committed: [String] = []
        let control = LanguageComboBox(text: Binding(get: { value }, set: { value = $0 }), onCommit: { committed.append($0) })
        let delegate = control.makeCoordinator()
        let box = NSComboBox()
        box.stringValue = value
        let event = Notification(name: NSControl.textDidEndEditingNotification, object: box)
        delegate.controlTextDidBeginEditing(event)
        delegate.controlTextDidEndEditing(event)
        try check(committed.isEmpty, "focus without editing does not overwrite the global language default")
        delegate.controlTextDidBeginEditing(event)
        box.stringValue = "Português brasileiro"
        delegate.controlTextDidChange(event)
        delegate.controlTextDidEndEditing(event)
        try check(value == "Português brasileiro" && committed == [value], "custom language commits once after editing")
        delegate.controlTextDidBeginEditing(event)
        box.stringValue = "temporary"
        delegate.controlTextDidChange(event)
        // Restore the original edit value, even though the binding tracks keystrokes.
        box.stringValue = "Português brasileiro"
        delegate.controlTextDidChange(event)
        delegate.controlTextDidEndEditing(event)
        try check(committed.count == 1, "reverting a language edit does not change the default")
        box.addItems(withObjectValues: ["日本語"])
        box.selectItem(at: 0)
        delegate.comboBoxSelectionDidChange(event)
        delegate.controlTextDidEndEditing(event)
        try check(value == "日本語" && committed == ["Português brasileiro", "日本語"], "explicit dropdown selection commits once without a second end-edit save")
    }

    private func focusLauncherVisibility() async throws {
        try await manual()
        defer { panel.setLauncherMode(.persistent); panel.showCollapsed() }
        panel.setLauncherMode(.focusedInput)
        panel.receiveFocusState(.unavailable)
        panel.showCollapsed()
        try check(!panel.uiTestWindow.isVisible, "focus mode starts hidden without supported input")
        let frame = NSScreen.main!.visibleFrame
        let target = FocusLauncherTarget(pid: 42, bundle: "com.openai.codex",
            windowIdentity: .init(fixture: 1), inputIdentity: .init(fixture: 2),
            anchor: NSRect(x: frame.midX, y: frame.midY, width: 240, height: 50))
        panel.receiveFocusState(.target(target))
        try check(panel.uiTestWindow.isVisible && !panel.uiTestWindow.isKeyWindow, "focused input displays nonactivating launcher")
        var menuStayedVisible = false
        panel.uiTestDuringContextMenu {
            panel.receiveFocusState(.unavailable)
            menuStayedVisible = panel.uiTestWindow.isVisible && panel.uiTestContextMenuTracking
        }
        try check(menuStayedVisible, "focus sampling preserves a tracked launcher menu without a captured target")
        try check(!panel.uiTestWindow.isVisible && !panel.uiTestContextMenuTracking,
                  "dismissed menu immediately resumes current focus visibility policy")
        panel.receiveFocusState(.target(target))
        await panel.uiTestDuringAsyncContextMenu { [self] in
            self.panel.receiveFocusState(.unavailable)
            await self.panel.open()
        }
        try check(panel.uiTestWindow.isVisible, "opening the draft from a tracked menu keeps the expanded editor visible")
        panel.receiveFocusState(.target(target))
        panel.showCollapsed()
        panel.hideLauncher()
        panel.showCollapsed(explicit: false)
        panel.receiveFocusState(.target(target))
        try check(!panel.uiTestWindow.isVisible, "internal completion and focus callbacks preserve manual hide")
        panel.showCaptureFailure("合成复制返回失败")
        try check(!panel.uiTestWindow.isVisible, "late failure feedback preserves manual hide")
        panel.showCollapsed()
        try check(panel.uiTestWindow.isVisible, "explicit show restores launcher")
        await panel.open()
        panel.receiveFocusState(.unavailable)
        try check(panel.uiTestWindow.isVisible, "focus sampling does not hide expanded editor")
        panel.suspendForSettings()
        panel.hideLauncher()
        panel.resumeAfterSettings()
        try check(!panel.uiTestWindow.isVisible, "closing settings preserves manual hide")
        await panel.open()
        panel.showCollapsed(explicit: false)
        try check(!panel.uiTestWindow.isVisible, "collapsed focus mode hides for unrelated target")
    }

    private func brandAssets() async throws {
        for (name, ext) in [("AppIcon", "png"), ("MenuBarTemplate", "png"), ("AppIcon", "icns")] {
            let url = Bundle.main.url(forResource: name, withExtension: ext)
            try check(url.flatMap { NSImage(contentsOf: $0) } != nil,
                      "packaged artwork loads without a SwiftPM build directory: \(name).\(ext)")
        }
        try check(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "AppIcon.icns",
                  "Finder and Dock use the packaged application icon")
        try check(BrandAssets.appIcon != nil && BrandAssets.menuBarIcon?.isTemplate == true,
                  "floating icon and monochrome menu template load")
        let size = BrandAssets.menuBarIcon?.size ?? .zero
        try check(size.width > 0 && size.width <= 22 && size.height > 0 && size.height <= 22,
                  "menu template fits a square status item without clipping")
        let appearance = NSApp.appearance
        let windowAppearance = panel.uiTestWindow.appearance
        let preferences = settings.preferences
        defer {
            NSApp.appearance = appearance
            panel.uiTestWindow.appearance = windowAppearance
            try? settings.savePreferences(preferences)
        }
        try await manual("请保留原意，翻译成自然清晰的英文。")
        try await generate()
        for (name, style) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: style)
            panel.uiTestWindow.appearance = NSAppearance(named: style)
            for automatic in [true, false] {
                var current = preferences
                current.automaticTranslationAndReplacement = automatic
                try settings.savePreferences(current)
                panel.collapse()
                try await snapshot("brand-launcher-\(name)-\(automatic ? "auto" : "manual")")
            }
            await panel.open()
            try await snapshot("brand-editor-\(name)")
        }
    }

    private func panelFailureStatus() async throws {
        for failure: BrokerErrorCode in [.clipboardChanged, .outcomeUnknown, .targetChanged] {
            let epoch = UUID()
            let wire = WireInputFixture(epoch: epoch, hostName: "微信", source: sample)
            wire.replacementError = failure
            let identity = BrokerApplicationIdentity(pid: getpid(), bundle: BrokerIdentity.clientBundle,
                path: Bundle.main.bundleURL.path, version: "fixture", build: "fixture")
            let client = BrokerClient(endpoint: wire, ownIdentity: identity,
                initialStatus: wire.status(), initialVerifiedClient: identity, initialEpoch: epoch)
            let input = ExternalInput(client: client)
            let router = HostRouter(demo: host, external: input)
            let settings = TranslationSettings(loadEnvironment: false)
            let workflow = DraftWorkflow(host: router, translator: settings)
            let controller = PanelController(workflow: workflow, host: router, settings: settings,
                openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName())
            defer { controller.hideLauncher(); input.clear() }
            try await router.captureExternalFullInput()
            await workflow.captureSelection()
            workflow.generate()
            try await wait("failure fixture generated") { workflow.phase == .ready }
            await controller.open()
            workflow.fill()
            try await wait("failure fixture terminated") { workflow.phase != .filling }
            try check(workflow.replacementRecord?.failure?.rawValue == failure.rawValue,
                      "\(failure.rawValue) retains typed failure on frozen replacement record")
            let message = controller.uiTestDisplayState.message
            controller.copyOutputOnly()
            try check(controller.uiTestDisplayState.message == message && controller.uiTestDisplayState.warning
                      && !workflow.canFill && controller.uiTestClipboardString == workflow.output,
                      "\(failure.rawValue) survives copy feedback and prohibits another fill")
            try await snapshot("refinement-\(failure.rawValue)", window: controller.uiTestWindow, state: workflow)
            let source = workflow.source, output = workflow.output
            controller.returnToInput()
            try await wait("explicit return finished") { !controller.isBusy }
            try check(wire.returnFocusCount == 1 && source == workflow.source && output == workflow.output
                      && !workflow.canFill && !workflow.canGenerate,
                      "return input keeps draft and only returns once without reading or generating")
            if failure == .outcomeUnknown {
                await controller.open()
                try check(controller.uiTestDisplayState.warning && controller.uiTestDisplayState.message.contains("未确认"),
                          "returning and reopening the same draft preserves unknown outcome")
                try await router.captureExternalFullInput()
                await workflow.captureSelection()
                try check(!controller.uiTestDisplayState.message.contains("未确认"),
                          "fresh capture releases prior unknown outcome from current operation")
            }
        }
    }

    private func uiRefinement() async throws {
        try await manual("焦点与复制测试 😀\n保留第二行")
        guard let source = panel.uiTestEditor(.source) else { throw Failure.assertion("missing registered source") }
        panel.uiTestWindow.makeFirstResponder(source)
        source.setSelectedRange(NSRange(location: 2, length: 1))
        panel.collapse()
        try await settle()
        await panel.open()
        try await settle()
        try check(panel.uiTestWindow.firstResponder === source && source.selectedRange() == NSRange(location: 2, length: 1),
                  "reopening restores registered source and selection")
        panel.uiTestGenerate()
        try await wait("generated result focus") { workflow.phase == .ready }
        try await settle()
        guard let output = panel.uiTestEditor(.output) else { throw Failure.assertion("missing registered output") }
        try check(panel.uiTestWindow.firstResponder === output, "uninterrupted generation focuses result editor")
        output.setSelectedRange(NSRange(location: 1, length: 2))
        panel.copyOutputOnly()
        try check(panel.uiTestWindow.firstResponder === output && output.selectedRange() == NSRange(location: 1, length: 2)
                  && panel.uiTestWindow.frame.width == 390 && panel.uiTestClipboardString == workflow.output,
                  "copy only keeps result selection and expanded panel")
        panel.suspendForSettings()
        panel.resumeAfterSettings()
        try await settle()
        try check(panel.uiTestWindow.firstResponder === output, "settings return restores result role")
        panel.uiTestGenerate()
        try await settle()
        panel.uiTestWindow.makeFirstResponder(source)
        try await wait("generation without stealing source focus") { workflow.phase == .ready }
        try await settle()
        try check(panel.uiTestWindow.firstResponder === source, "late result preserves deliberate focus change")
        workflow.editSource(workflow.source + " 新内容")
        try await settle()
        try check(panel.uiTestDisplayState.action == .generate && panel.uiTestDisplayState.title == "重新生成",
                  "stale result promotes regenerate and cannot replace")
        let warning = panel.uiTestDisplayState.message
        panel.copyOutputOnly()
        try check(panel.uiTestDisplayState.message == warning, "copy feedback never masks stale warning")
        try await snapshot("refinement-stale")
        panel.showCaptureFailure("模型配置尚未就绪，请先打开设置。", kind: .configuration)
        panel.uiTestGenerate()
        try await wait("regenerate after configuration recovery") { workflow.phase == .ready }
        try check(!panel.uiTestDisplayState.warning && !panel.uiTestDisplayState.message.contains("配置尚未就绪"),
                  "successful generation clears resolved configuration issue")
        panel.showCaptureFailure("替换结果未确认，请到原应用检查。", kind: .restore(.outcomeUnknown))
        panel.copyOutputOnly()
        try check(panel.uiTestDisplayState.warning && panel.uiTestDisplayState.message.contains("未确认"),
                  "copy feedback never masks recovery outcome warning")
        try await snapshot("refinement-unknown")
        try await manual("新稿")
        try await snapshot("refinement-manual")
    }

    private func releaseProduct() async throws {
        let productionSettings = TranslationSettings(loadEnvironment: false, allowDemo: false)
        try check(!productionSettings.canGenerate && !productionSettings.isDemo, "unconfigured release settings cannot generate or use demo")
        let request = try GenerationRequest(source: "fixture", intent: .translate,
            targetLanguage: "English", template: TranslationPreferences().translationTemplate)
        do {
            _ = try await productionSettings.generate(request)
            throw Failure.assertion("unconfigured release generated a result")
        } catch is TranslationFailure { }
        try productionSettings.apply(ProviderConfiguration(format: .chatCompletions,
            baseURL: "https://example.invalid/v1", model: "your-model", apiKey: "fixture-only"))
        let demo = DemoHost()
        let route = HostRouter(demo: demo)
        route.useManual()
        let draft = DraftWorkflow(host: route, translator: DemoTranslator())
        await draft.useManualInput()
        draft.editSource("修复登录失败的问题，并补充必要的测试。", isComposing: false)
        let controller = PanelController(workflow: draft, host: route, settings: productionSettings,
            openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName())
        defer { controller.uiTestWindow.close(); demo.window.close() }
        await controller.open()
        draft.generate()
        for _ in 0..<120 where draft.phase == .translating { try await Task.sleep(for: .milliseconds(25)) }
        try check(draft.phase == .ready, "preview fixture generated without network")
        try check(productionSettings.canGenerate && !productionSettings.isDemo, "configured release uses model state")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            controller.uiTestWindow.appearance = NSAppearance(named: appearance)
            try await snapshot(appearance == .aqua ? "release-translation" : "release-translation-dark", window: controller.uiTestWindow, state: draft)
        }
        try productionSettings.apply(nil)
        try check(!productionSettings.canGenerate, "removing active model returns to unconfigured state")
    }

    private func copyPreview() async throws {
        settingsController.show()
        try await settle()
        if let editor = settingsController.uiTestEditor {
            editor.add()
            editor.form.name = "示例服务"
            editor.setBaseURL("https://api.example.com/v1")
            editor.form.configuration.model = "example-model"
        }
        if let window = settingsController.uiTestWindow {
            try await snapshot("copy-model-settings", window: window)
            window.close()
        }
        settingsController.show(initialSection: 1)
        if let window = settingsController.uiTestWindow {
            try await snapshot("copy-translation-settings", window: window)
            window.close()
        }
    }

    private func collapsedLauncher() async throws {
        try await manual()
        try await generate()
        let draft = workflow.output
        panel.collapse()
        try await settle()
        let window = panel.uiTestWindow
        try check(window.frame.size == NSSize(width: 186, height: 52), "collapsed launcher retains compact dimensions")
        try await snapshot("collapsed-launcher")
        let elements = accessibilityElements(window)
        guard let button = elements.first(where: {
            let label = ($0.accessibilityLabel?() ?? nil) ?? ($0.accessibilityTitle?() ?? nil) ?? ""
            return ($0.accessibilityRole?() ?? nil) == .button && label.contains("读取输入框全文")
        }), let frame = button.accessibilityFrame?() else {
            let description = elements.map { element in
                "\(element.accessibilityRole?()?.rawValue ?? "nil"):\(element.accessibilityLabel?() ?? nil ?? ""):\(String(describing: element.accessibilityFrame?()))"
            }.joined(separator: "; ")
            throw Failure.assertion("Missing collapsed launcher button: " + description)
        }
        try check(abs(frame.midY - window.frame.midY) < 1, "collapsed launcher button vertically centered without titlebar inset: button=\(frame), window=\(window.frame)")
        try check(window.canBecomeKey == false && !window.hidesOnDeactivate, "collapsed launcher stays visible without taking keyboard focus")
        let previousPreferences = settings.preferences
        defer { try? settings.savePreferences(previousPreferences) }
        for automatic in [true, false] {
            var preferences = previousPreferences
            preferences.automaticTranslationAndReplacement = automatic
            try settings.savePreferences(preferences)
            try await settle()
            guard let action = accessibilityElements(window).first(where: {
                ($0.accessibilityRole?() ?? nil) == .button
                    && (($0.accessibilityLabel?() ?? nil) ?? "").contains("读取输入框全文")
            }) else { throw Failure.assertion("Missing launcher accessibility action") }
            let label = (action.accessibilityLabel?() ?? nil) ?? ""
            let rawValue: Any? = action.accessibilityValue?()
            let value = rawValue as? String ?? ""
            try check(label.contains("翻译并替换") == automatic && value.contains(automatic ? "Auto 已开启" : "Auto 已关闭")
                      && value.contains(preferences.targetLanguage),
                      "collapsed launcher accessibility matches Auto=\(automatic) and its target language")
        }
        await panel.open()
        try await settle()
        try check(window.frame.width == 390 && workflow.output == draft, "opening existing draft preserves it without recapturing")
        try await snapshot("collapsed-launcher-expanded")
    }

    private func launcherDrag() async throws {
        panel.hideLauncher()
        let localSettings = TranslationSettings(loadEnvironment: false)
        let localWorkflow = DraftWorkflow(host: router, translator: DemoTranslator())
        var captures = 0
        let controller = PanelController(workflow: localWorkflow, host: router, settings: localSettings,
            openSettings: {}, openManual: {}, openExternalHelp: {}, pasteboard: NSPasteboard.withUniqueName(),
            captureFullInput: {
                captures += 1
                throw ExternalInputError.noFocusedInput
            })
        defer { controller.hideLauncher() }
        controller.showCollapsed()
        try await settle()
        let window = controller.uiTestWindow
        let center = NSPoint(x: window.frame.width / 2, y: window.frame.height / 2)
        func dispatch(_ type: NSEvent.EventType, at point: NSPoint) throws {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
                throw Failure.assertion("Could not construct local launcher pointer event")
            }
            window.sendEvent(event)
        }
        try dispatch(.leftMouseDown, at: center)
        let offset = NSPoint(x: center.x + 20, y: center.y)
        try dispatch(.leftMouseDragged, at: offset)
        try dispatch(.leftMouseUp, at: offset)
        try await settle()
        try check(captures == 0, "dragging inside the button without window movement does not capture")

        try dispatch(.leftMouseDown, at: center)
        try await settle()
        let initial = window.frame.origin
        window.setFrameOrigin(NSPoint(x: initial.x - 30, y: initial.y - 20))
        try dispatch(.leftMouseDragged, at: center)
        try dispatch(.leftMouseUp, at: center)
        try await settle()
        try check(window.frame.origin != initial, "launcher drag changes the window position")
        try check(captures == 0, "releasing a moved launcher does not invoke capture")

        try dispatch(.leftMouseDown, at: center)
        let moved = window.frame.origin
        window.setFrameOrigin(NSPoint(x: moved.x - 30, y: moved.y - 20))
        try dispatch(.leftMouseDragged, at: center)
        window.setFrameOrigin(moved)
        try dispatch(.leftMouseDragged, at: center)
        try dispatch(.leftMouseUp, at: center)
        try await settle()
        try check(captures == 0, "dragging away and back still cancels the launcher click")

        try dispatch(.leftMouseDown, at: center)
        let jitter = NSPoint(x: center.x + 1, y: center.y + 1)
        try dispatch(.leftMouseDragged, at: jitter)
        try dispatch(.leftMouseUp, at: jitter)
        try await settle()
        try check(captures == 1, "the next ordinary mouse click with minor jitter captures exactly once")
        controller.showCollapsed()
        try await settle()
        controller.resetPosition()
        let automatic = window.frame.origin
        window.setFrameOrigin(NSPoint(x: automatic.x - 1, y: automatic.y))
        try dispatch(.leftMouseDown, at: center)
        controller.resetPosition()
        try dispatch(.leftMouseUp, at: center)
        try await settle()
        try check(captures == 2, "minor automatic repositioning is not mistaken for a user window drag")

        controller.showCollapsed()
        try await settle()
        try dispatch(.leftMouseDown, at: center)
        let beforeAX = window.frame.origin
        window.setFrameOrigin(NSPoint(x: beforeAX.x - 30, y: beforeAX.y - 20))
        try dispatch(.leftMouseUp, at: center)
        try await settle()
        guard let button = accessibilityElements(window).first(where: {
            (($0.accessibilityLabel?() ?? nil) ?? "").contains("读取输入框全文")
        }) else { throw Failure.assertion("Missing launcher accessibility button") }
        try check(button.accessibilityPerformPress?() == true, "launcher retains its independent accessibility action")
        try await settle()
        try check(captures == 3, "accessibility activation after a drag captures exactly once")
    }

    private func positionPersistence() async throws {
        try await manual()
        try await generate()
        let screen = router.screenFrame
        let desired = NSPoint(x: screen.minX + 32, y: screen.maxY - 40)
        panel.uiTestWindow.setFrameTopLeftPoint(desired)
        try await settle()
        let moved = NSPoint(x: panel.uiTestWindow.frame.minX, y: panel.uiTestWindow.frame.maxY)
        panel.collapse()
        await panel.open()
        try await settle()
        let reopened = NSPoint(x: panel.uiTestWindow.frame.minX, y: panel.uiTestWindow.frame.maxY)
        try check(abs(moved.x - reopened.x) < 1 && abs(moved.y - reopened.y) < 1, "native move notification preserves top-left after collapse/open")
        try await snapshot("position-preserved")
        panel.resetPosition()
        try await settle()
        try check(abs(panel.uiTestWindow.frame.minX - moved.x) > 1, "reset position resumes following host")
        try await snapshot("position-reset")
    }

    private func longDraft() async throws {
        try await manual((1...80).map { "第 \($0) 段：保留“确认删除”和 ./src/登录.ts。" }.joined(separator: "\n"))
        panel.uiTestSetLargeEditor(true)
        try await generate()
        try check(editors().count == 2, "long draft has both native editors")
        try check(editors().allSatisfy { $0.enclosingScrollView?.hasVerticalScroller == true }, "long draft uses native scroll views")
        try await snapshot("long-draft-large")
        panel.uiTestSetLargeEditor(false)
        try await settle()
        try await snapshot("long-draft-compact")
    }

    private func draftRecovery() async throws {
        try await manual()
        try await generate()
        workflow.editOutput("MANUAL EDITED FIXTURE")
        workflow.editSource(sample + " 需要保留人工修改。")
        try await settle()
        try check(workflow.output == "MANUAL EDITED FIXTURE" && workflow.staleReason != nil,
                  "editing source preserves editable stale English")
        try check(editors().count == 2 && editors().last?.isEditable == true, "stale English stays visible and editable")
        panel.copyOutputAndReturn()
        try check(panel.uiTestClipboardString == "MANUAL EDITED FIXTURE" && workflow.staleReason != nil,
                  "copy writes stale text without dismissing warning")
        try await snapshot("stale-result")
        try await generate()
        let replacement = workflow.output
        await workflow.restorePreviousDraft()
        try await settle()
        try check(workflow.output == "MANUAL EDITED FIXTURE" && workflow.canGenerate && !workflow.canFill,
                  "manual recovery retains previous English and requires regeneration")
        await workflow.restorePreviousDraft()
        try check(workflow.output == replacement, "recovery is reversible with one alternative")
        workflow.editOutput("")
        try await settle()
        try check(editors().count == 2 && !workflow.canCopy, "empty manual result keeps native editor")
        try await snapshot("recovered-empty-editor")
    }

    private func editorUndoIsolation() async throws {
        try await captureNativeHost()
        try await generate()
        guard let source = editors().first, let output = editors().last else { throw Failure.assertion("Missing undo editors") }
        try check(source.undoManager !== output.undoManager, "source and result own independent undo managers")
        let originalSource = source.string
        source.insertText("合成修改", replacementRange: NSRange(location: 0, length: 2))
        source.breakUndoCoalescing()
        output.insertText("MANUAL ", replacementRange: NSRange(location: 0, length: 0))
        output.breakUndoCoalescing()
        let editedOutput = output.string
        source.undoManager?.undo()
        try await settle()
        try check(source.string == originalSource && output.string == editedOutput,
                  "source undo does not undo independent English edits")
        output.undoManager?.undo()
        try await settle()
        try check(output.string != editedOutput && workflow.output == output.string, "native result undo updates workflow")
        source.insertText("NEW", replacementRange: NSRange(location: 0, length: 2))
        source.breakUndoCoalescing()
        try check(source.undoManager?.canUndo == true, "source records ordinary manual edit")
        await workflow.captureSelection()
        try await settle()
        guard let recaptured = editors().first else { throw Failure.assertion("Missing recaptured source") }
        try check(recaptured.undoManager?.canUndo == false, "recapture resets old undo history")
        recaptured.undoManager?.undo()
        try check(recaptured.string == sample && workflow.source == sample, "undo cannot mix old text into recaptured document")
        try await generate()
        guard let result = editors().last else { throw Failure.assertion("Missing replacement result") }
        result.insertText("MANUAL", replacementRange: NSRange(location: 0, length: 4))
        result.breakUndoCoalescing()
        try check(result.undoManager?.canUndo == true, "English editor retains manual undo")
        try await generate()
        try check(editors().last?.undoManager?.canUndo == false, "new generated result resets previous English undo")
        await workflow.restorePreviousDraft()
        try await settle()
        try check(editors().allSatisfy { $0.undoManager?.canUndo == false }, "recovery resets both document undo stacks")
        try await snapshot("undo-isolation")
    }

    private func adaptiveLayout() async throws {
        try await manual("短稿")
        let short = panel.uiTestWindow.frame.height
        workflow.editSource((1...20).map { "第 \($0) 行合成测试文字。" }.joined(separator: "\n"))
        try await settle()
        let long = panel.uiTestWindow.frame.height
        try check(long > short, "multiline content grows compact editor and panel")
        try check(long <= router.screenFrame.height - 24, "adaptive panel remains within screen height limit")
        try await snapshot("adaptive-long-source")
        workflow.editSource("短稿")
        try await settle()
        try check(panel.uiTestWindow.frame.height < long, "short draft shrinks panel after long draft")
        try await snapshot("adaptive-short-source")
    }

    private func smallScreen() async throws {
        try await manual()
        let screen = router.screenFrame
        let fixture = NSRect(x: screen.minX, y: screen.maxY - 400, width: 420, height: 400)
        panel.uiTestScreenFrame = fixture
        panel.resetPosition()
        try await generate()
        panel.uiTestSetLargeEditor(true)
        try await settle()
        try check(fixture.insetBy(dx: 12, dy: 12).contains(panel.uiTestWindow.frame), "panel fits 420x400 fixture with screen margins")
        try check(panel.uiTestWindow.frame.height <= 376 && workflow.canCopy, "small screen keeps copy available within height limit")
        try await snapshot(scenario)
        guard let outerScroll = descendants(panel.uiTestWindow.contentView).compactMap({ $0 as? NSScrollView })
            .first(where: { $0.documentView != nil && !($0.documentView is NSTextView) }),
              let document = outerScroll.documentView else {
            throw Failure.assertion("Missing outer scroll view on small screen")
        }
        let clip = outerScroll.contentView
        clip.scroll(to: NSPoint(x: clip.bounds.minX,
            y: document.isFlipped ? max(0, document.bounds.height - clip.bounds.height) : 0))
        outerScroll.reflectScrolledClipView(clip)
        try await settle()
        try check(clip.bounds.minY > 0 || document.bounds.height <= clip.bounds.height + 1, "small-screen result is reachable by fitting or scrolling")
        try await snapshot("small-screen-result")
        panel.uiTestScreenFrame = nil
        panel.position()
    }

    private func fullScreen() async throws {
        try await captureNativeHost()
        try await generate()
        panel.deactivate()
        host.window.makeKeyAndOrderFront(nil)
        host.window.toggleFullScreen(nil)
        try await wait("native host enters fullscreen") { self.host.window.styleMask.contains(.fullScreen) }
        try await settle()
        await panel.open()
        try await settle()
        try check(host.window.isOnActiveSpace && panel.uiTestWindow.isOnActiveSpace && panel.uiTestWindow.isVisible,
                  "panel and native fullscreen host share active Space")
        try check(workflow.phase == .ready && workflow.canFill, "fullscreen keeps valid generated result")
        try await snapshot("fullscreen-panel")
        try await snapshot("fullscreen-host", window: host.window)
        panel.deactivate()
        host.window.toggleFullScreen(nil)
        try await wait("native host exits fullscreen") { !self.host.window.styleMask.contains(.fullScreen) }
    }

    private func snapshot(_ name: String, window: NSWindow? = nil, state: DraftWorkflow? = nil) async throws {
        let workflow = state ?? self.workflow
        try await settle()
        let target = window ?? panel.uiTestWindow
        try check(target.isVisible, "screenshot window is visible: \(name)")
        guard let view = target.contentView else { throw Failure.assertion("Missing screenshot content") }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure.assertion("Cannot create screenshot bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // cacheDisplay omits the window's system backdrop. Resolve the actual
        // appearance so light and dark fixture captures retain readable text.
        guard let opaque = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: bitmap.pixelsWide,
            pixelsHigh: bitmap.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: opaque) else {
            throw Failure.assertion("Cannot create screenshot background")
        }
        guard let capturedImage = bitmap.cgImage else { throw Failure.assertion("Cannot read captured screenshot") }
        let bounds = CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
        let graphics = context.cgContext
        var background = CGColor(gray: 1, alpha: 1)
        target.effectiveAppearance.performAsCurrentDrawingAppearance {
            background = NSColor.windowBackgroundColor.cgColor
        }
        graphics.setFillColor(background)
        graphics.fill(bounds)
        graphics.setBlendMode(.normal)
        graphics.draw(capturedImage, in: bounds)
        graphics.flush()
        guard let png = opaque.representation(using: .png, properties: [:]) else { throw Failure.assertion("Cannot encode screenshot") }
        let image = "\(name).png"
        try png.write(to: outputDirectory.appendingPathComponent(image), options: .atomic)
        snapshots.append(Snapshot(scenario: scenario, image: image, frame: NSStringFromRect(target.frame),
            phase: String(describing: workflow.phase), canGenerate: workflow.canGenerate,
            canFill: workflow.canFill, canCopy: workflow.canCopy))
    }
}

#endif
