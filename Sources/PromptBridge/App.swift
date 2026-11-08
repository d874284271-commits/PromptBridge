import AppKit
import DraftCore
import AccessibilityContracts

@main @MainActor enum PromptBridgeApp {
    static func main() async {
        #if PROMPTBRIDGE_TESTING
        if CommandLine.arguments.contains("--probe-input-support") {
            await runBrokerProbe(.probeInputSupport)
            return
        }
        if CommandLine.arguments.contains("--probe-codex") {
            await runBrokerProbe(.probeCodex)
            return
        }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }

    #if PROMPTBRIDGE_TESTING
    private static func runBrokerProbe(_ operation: BrokerOperation) async {
        do {
            let response = try await BrokerClient.shared.request(operation, payload: BrokerPayload())
            guard let report = response.probeReport else { throw BrokerTransportError.invalidResponse }
            if let output = try probeOutputURL() {
                try report.write(to: output, options: .atomic)
            } else {
                FileHandle.standardOutput.write(report)
                FileHandle.standardOutput.write(Data([0x0A]))
            }
        } catch {
            let message = Data("broker probe failed: \(error)\n".utf8)
            FileHandle.standardError.write(message)
            Darwin.exit(1)
        }
    }

    private static func probeOutputURL() throws -> URL? {
        guard let index = CommandLine.arguments.firstIndex(of: "--probe-output") else { return nil }
        guard CommandLine.arguments.indices.contains(index + 1),
              !CommandLine.arguments[index + 1].isEmpty else {
            throw BrokerTransportError.invalidResponse
        }
        return URL(fileURLWithPath: CommandLine.arguments[index + 1])
    }
    #endif
}

@MainActor private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    #if PROMPTBRIDGE_TESTING
    private var host: DemoHost?
    #endif
    private var panel: PanelController?
    private var workflow: DraftWorkflow?
    private var settingsController: SettingsController?
    private var translationSettings: TranslationSettings?
    private var router: HostRouter?
    private var hotKey: SelectionHotKey?
    private var statusItem: NSStatusItem?
    #if PROMPTBRIDGE_TESTING
    private var uiAcceptance: UIAcceptanceSuite?
    private var externalAcceptance: ExternalAcceptanceBridge?
    #endif
    private var focusMonitor: MainFocusLauncher?
    private var statusMenu: NSMenu?
    private var statusMenuRequestID = UUID()
    private var externalCaptureRequestID = UUID()
    private var startupEditorURLs: [URL] = []
    private var editorReady = false
    #if PROMPTBRIDGE_TESTING
    private let externalTestMode = CommandLine.arguments.contains("--external-test-directory")
    private let preferencesUITestMode = CommandLine.arguments.contains("--preferences-ui-test")
    private let uiTestMode = CommandLine.arguments.contains("--ui-test-script")
        || CommandLine.arguments.contains("--external-test-directory")
        || CommandLine.arguments.contains("--preferences-ui-test")
    #else
    private let externalTestMode = false
    private let preferencesUITestMode = false
    private let uiTestMode = false
    #endif
    private let backgroundLaunch = CommandLine.arguments.contains("--background")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMenu()
        #if PROMPTBRIDGE_TESTING
        let host = DemoHost()
        let router = HostRouter(demo: host)
        #else
        let router = HostRouter()
        #endif
        self.router = router
        let settings = TranslationSettings(loadEnvironment: !uiTestMode)
        translationSettings = settings
        let translator: any DraftTranslator = settings
        let workflow = DraftWorkflow(host: router, translator: translator)
        settings.willChange = { [weak workflow] in workflow?.translationSettingsDidChange() }
        let settingsController = SettingsController(settings: settings)
        self.settingsController = settingsController
        let testCapture: (@MainActor @Sendable () async throws -> Void)?
        #if PROMPTBRIDGE_TESTING
        if externalTestMode {
            let args = CommandLine.arguments
            guard let index = args.firstIndex(of: "--external-test-host"), args.indices.contains(index + 1),
                  ExternalAcceptanceBridge.supports(bundle: args[index + 1]) else { Darwin.exit(1) }
            let bundle = args[index + 1]
            testCapture = { try await ExternalAcceptanceBridge.captureFullInput(router: router, bundle: bundle) }
        } else if uiTestMode { testCapture = { throw ExternalInputError.noFocusedInput } }
        else { testCapture = nil }
        #else
        testCapture = nil
        #endif
        let cliVerifier: (CLIEditorPreflight) -> Bool
        if uiTestMode { cliVerifier = { _ in true } }
        else { cliVerifier = CLIEditorSession.validateIdentity }
        let panel = PanelController(workflow: workflow, host: router, settings: settings,
            openSettings: { [weak self] in self?.showSettings() },
            openManual: { [weak self] in self?.showManual() },
            continueManual: { [weak self] in self?.continueManual() },
            openSavedEntry: { [weak self] entry in self?.showSavedEntry(entry) },
            openExternalHelp: { [weak self] in self?.showExternalHelp() },
            pasteboard: uiTestMode ? NSPasteboard.withUniqueName() : .general,
            captureFullInput: testCapture,
            openCLISettings: { [weak self] in self?.showCLISettings() },
            cliIdentityVerifier: cliVerifier)
        router.external.onReplacementStage = { [weak workflow] in workflow?.replacementStageDidChange($0) }
        settingsController.onClose = { [weak panel] in panel?.resumeAfterSettings() }
        #if PROMPTBRIDGE_TESTING
        self.host = host
        #endif
        self.workflow = workflow
        self.panel = panel
        panel.cliEditor.onFinished = { [weak panel] session, outcome in
            guard let panel else { return }
            Task { await panel.cliConnection.finish(session: session, completion: outcome, editor: panel.cliEditor) }
        }
        if !uiTestMode { panel.cliConnection.start() }
        settings.canEditPreferences = { [weak panel, weak workflow] in
            panel?.isBusy != true && workflow?.canSwitchDraft == true
        }
        panel.setLauncherMode(settings.preferences.launcherMode)
        if !uiTestMode || externalTestMode {
            let monitor = MainFocusLauncher(receive: { [weak panel] state in panel?.receiveFocusState(state) })
            focusMonitor = monitor
            monitor.setMode(settings.preferences.launcherMode)
        }
        settings.preferencesDidChange = { [weak self, weak workflow, weak panel, weak settings] in
            workflow?.preferencesDidChange()
            guard !DesktopInstallation.shared.busy, let mode = settings?.preferences.launcherMode else { return }
            panel?.setLauncherMode(mode)
            self?.focusMonitor?.setMode(mode)
        }
        router.onChange = { [weak workflow] in workflow?.hostDidChange() }
        router.onGeometryChange = { [weak panel] in panel?.position() }
        #if PROMPTBRIDGE_TESTING
        host.onChange = { [weak router] in
            guard let router, !router.isExternal, !router.isManual, !router.isCLI else { return }
            router.onChange?()
        }
        host.onOpen = { [weak self, weak router, weak workflow, weak panel] in
            guard panel?.blocksEntrySwitch != true, workflow?.allowDraftSwitch() == true else { return }
            self?.externalCaptureRequestID = UUID()
            Task { @MainActor in
                if router?.isManual == true || router?.isExternal == true || router?.isCLI == true { _ = await workflow?.prepareForEntrySwitch() }
                if router?.useDemo() == true {
                    if workflow?.hasSavedDraft(.demo) == true { await workflow?.openSavedEntry(.demo) }
                    else { await workflow?.captureSelection() }
                }
                await panel?.open()
            }
        }
        host.onExternalHelp = { [weak self] in self?.showExternalHelp() }
        host.onGeometryChange = { [weak panel, weak router] in
            if router?.isManual == false && router?.isExternal == false && router?.isCLI == false { panel?.position() }
        }
        host.onVisibilityChange = { [weak panel, weak router] visible in
            if router?.isExternal == false && router?.isManual == false && router?.isCLI == false { panel?.setVisible(visible) }
        }
        #endif
        if !uiTestMode {
            hotKey = SelectionHotKey { [weak self] in self?.readFullInput() }
            installStatusMenu()
        } else if externalTestMode && CommandLine.arguments.contains("--external-test-status-menu") {
            // Exercise the actual status menu without loading user configuration
            // or competing with the user's normal instance for its global hotkey.
            installStatusMenu()
        }
        if !uiTestMode {
            DesktopInstallation.shared.beforeChange = { [weak self, weak panel, weak workflow] in
                guard let self, panel?.canChangeInstallation == true, panel?.cliEditor.active == false,
                      workflow?.phase != .translating, workflow?.phase != .filling else {
                    throw DesktopInstallError.message("请先完成当前翻译或 CLI 编辑，再更改接入。")
                }
                self.focusMonitor?.suspendForInstallation()
                panel?.cliConnection.stop()
                BrokerClient.shared.disconnect()
            }
            DesktopInstallation.shared.afterChange = { [weak self, weak panel, weak settings] in
                guard DesktopInstallation.shared.installed else { return }
                if let mode = settings?.preferences.launcherMode { self?.focusMonitor?.setMode(mode) }
                panel?.cliConnection.start()
            }
        }
        router.useManual()
        Task { [weak self] in
            await workflow.useManualInput()
            guard let self else { return }
            self.editorReady = true
            let pending = self.startupEditorURLs
            self.startupEditorURLs.removeAll()
            for url in pending { await self.receiveEditor(url) }
        }
        #if PROMPTBRIDGE_TESTING
        if preferencesUITestMode {
            Task { await panel.open() }
            return
        }
        if uiTestMode {
            NSApp.appearance = NSAppearance(named: .aqua)
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--external-test-directory") {
                guard args.indices.contains(index + 1),
                      let hostIndex = args.firstIndex(of: "--external-test-host"), args.indices.contains(hostIndex + 1) else {
                    Darwin.exit(1)
                }
                do {
                    externalAcceptance = try ExternalAcceptanceBridge(
                        directory: URL(fileURLWithPath: args[index + 1], isDirectory: true),
                        bundle: args[hostIndex + 1], router: router, workflow: workflow, panel: panel, settings: settings)
                } catch { Darwin.exit(1) }
                return
            }
            let suite = UIAcceptanceSuite(host: host, router: router, workflow: workflow,
                panel: panel, settings: settings, settingsController: settingsController,
                reopen: { [weak self] in _ = self?.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true) })
            uiAcceptance = suite
            Task { await suite.run() }
        } else if !backgroundLaunch { panel.showCollapsed() }
        #else
        if !backgroundLaunch { panel.showCollapsed() }
        #endif
    }

    func applicationDidResignActive(_ notification: Notification) {
        panel?.applicationLostFocus()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        router?.hideInactiveDemo()
        if panel?.hasBeenPresented == false && !backgroundLaunch && !uiTestMode { panel?.showCollapsed() }
        else { panel?.activate() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening restores the current draft and host; only an explicit menu action switches modes.
        Task { await panel?.open() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel?.cliEditor.cancel()
        panel?.cliConnection.stop()
        focusMonitor?.stop()
        hotKey?.stop()
        router?.external.clear()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !DesktopInstallation.shared.busy, panel?.cliEditor.finishing != true, panel?.isBusy != true else { return .terminateCancel }
        guard let settingsController else { return .terminateNow }
        var immediateReply: Bool?
        var awaitingSheet = false
        settingsController.confirmDiscardForTermination { shouldQuit in
            if awaitingSheet { sender.reply(toApplicationShouldTerminate: shouldQuit) }
            else { immediateReply = shouldQuit }
        }
        if let immediateReply { return immediateReply ? .terminateNow : .terminateCancel }
        awaitingSheet = true
        return .terminateLater
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        if !editorReady { startupEditorURLs.append(contentsOf: urls); return }
        for url in urls { Task { await receiveEditor(url) } }
    }

    private func receiveEditor(_ url: URL) async {
        guard let panel else { return }
        if DesktopInstallation.shared.busy {
            _ = await panel.cliEditor.receive(url, busy: true)
            return
        }
        if let request = try? CLIEditorExchange.readPreflight(url), CLIEditorSession.validateIdentity(request) {
            await panel.cliConnection.prepareReturn(for: request.registration.session)
        }
        if await panel.cliEditor.receive(url, busy: panel.cliReceptionBusy) {
            externalCaptureRequestID = UUID()
            if panel.cliEditor.needsConsent { panel.showCollapsed(explicit: false) }
        }
    }

    @objc private func importCLIDraft() {
        Task { await panel?.importCLIDraft() }
    }

    @objc private func readFullInput() { panel?.readFromLauncher() }
    @objc private func showCurrentDraft() { Task { await panel?.open() } }
    @objc private func showLauncher() { panel?.showCollapsed() }
    @objc private func hideLauncher() { panel?.hideLauncher() }

    @objc private func captureExternal() {
        // The external acceptance mode permits only its fixture-checked full capture.
        guard !preferencesUITestMode, !externalTestMode, panel?.blocksEntrySwitch != true else { return }
        let requestID = UUID()
        externalCaptureRequestID = requestID
        Task { @MainActor [weak self] in
            guard let self, let panel = self.panel, !panel.blocksEntrySwitch else { return }
            panel.externalCapturing = true
            defer { panel.externalCapturing = false }
            guard await self.workflow?.prepareForEntrySwitch() == true else { return }
            guard self.externalCaptureRequestID == requestID else { return }
            do {
                try await self.router?.captureExternal()
                guard self.externalCaptureRequestID == requestID, self.router?.isCLI != true else { return }
                await self.workflow?.captureSelection()
                guard self.externalCaptureRequestID == requestID else { return }
                await self.panel?.open()
            } catch {
                guard self.externalCaptureRequestID == requestID, self.router?.isCLI != true else { return }
                if self.router?.isManual == true { await self.workflow?.useManualInput() }
                let message = (error as? ExternalInputError)?.userMessage ?? "请重新选择输入框文字后再试。"
                if self.router?.isManual == false { self.workflow?.captureDidFail(message) }
                self.panel?.showCaptureFailure(message)
            }
        }
    }

    @objc private func showExternalHelp() {
        let shortcut = hotKey?.isRegistered == true ? "点击要翻译的输入框，再按 ⌥T（Option＋T）处理整个草稿，不受选区影响。" : "快捷键未能注册，请用菜单栏的整框翻译入口。"
        let alert = NSAlert()
        alert.messageText = "输入框翻译说明"
        let appPath = Bundle.main.bundleURL.path
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let broker = BrokerClient.shared
        let status = broker.cachedStatus
        let connection = broker.connected ? "已连接" : "未连接"
        let trust = !broker.connected ? "服务未连接，权限状态未知"
            : (status?.permission == true ? "组件已获辅助功能权限" : "组件尚未获辅助功能权限")
        let componentPath = broker.connected ? (status?.path ?? BrokerClient.defaultHelperPath) : BrokerClient.defaultHelperPath
        let componentVersion = broker.connected ? (status.map { "\($0.version) / \($0.build)" } ?? "未知") : "未知（服务未连接）"
        alert.informativeText = shortcut + "\n\nAuto 开启时，读取全文、翻译并自动替换；关闭时，自动生成译文，你可以修改后点击“确认替换”。始终不发送消息。\n\nTerminal 使用 CLI 编辑器接入。\n\n辅助功能组件连接：" + connection
            + "\n组件权限：" + trust
            + "\n组件路径：" + componentPath
            + "\n组件版本：" + componentVersion
            + "\n当前应用：" + appPath + "\n版本：" + version + " / " + build
        alert.addButton(withTitle: "完成")
        if status?.permission != true { alert.addButton(withTitle: "申请辅助功能权限…") }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            Task { try? await BrokerClient.shared.request(.showPermissionHelp) }
        }
    }

    #if PROMPTBRIDGE_TESTING
    @objc private func showDemo() {
        guard panel?.blocksEntrySwitch != true, workflow?.allowDraftSwitch() == true else { return }
        externalCaptureRequestID = UUID()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.router?.isManual == true || self.router?.isExternal == true || self.router?.isCLI == true {
                guard await self.workflow?.prepareForEntrySwitch() == true else { return }
            }
            let changed = self.router?.useDemo() == true
            self.host?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            if changed {
                if self.workflow?.hasSavedDraft(.demo) == true { await self.workflow?.openSavedEntry(.demo) }
                else { await self.workflow?.captureSelection() }
            }
            self.panel?.showCollapsed()
        }
    }

    #endif
    private var readInputMenuTitle: String {
        if translationSettings?.preferences.automaticTranslationAndReplacement == true {
            return "读取全文、翻译并替换"
        }
        if panel?.cliEditor.needsConsent == true || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" {
            return "读取 CLI 草稿"
        }
        return "读取全文并翻译"
    }

    private func installStatusMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = BrandAssets.menuBarIcon
            ?? NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "PromptBridge")
        item.button?.image?.isTemplate = true
        item.button?.setAccessibilityLabel("PromptBridge")
        item.button?.toolTip = "PromptBridge"
        let menu = NSMenu()
        menu.delegate = self
        for (title, action) in [
            (readInputMenuTitle + (hotKey?.isRegistered == true ? "  ⌥T" : ""), #selector(readFullInput)),
            ("打开已有草稿", #selector(showCurrentDraft)),
            ("显示浮窗", #selector(showLauncher)),
            ("隐藏浮窗", #selector(hideLauncher)),
            ("输入框翻译说明…", #selector(showExternalHelp)),
            ("设置…", #selector(showSettings)),
        ] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        #if PROMPTBRIDGE_TESTING
        menu.addItem(developerMenu())
        #endif
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 PromptBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = nil
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        statusMenu = menu
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let requestID = UUID()
        statusMenuRequestID = requestID
        Task { @MainActor [weak self] in
            guard let self, let menu = self.statusMenu,
                  let button = self.statusItem?.button else { return }
            do {
                guard let scope = try await self.panel?.beginStatusMenuTracking() else { return }
                guard self.statusMenuRequestID == requestID else {
                    await self.panel?.endStatusMenuTracking()
                    return
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
                _ = scope
            } catch {
                self.statusMenuRequestID = UUID()
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Refresh display text only; the broker scope is acquired before popUp.
        guard menu === statusMenu else { return }
        menu.items.first(where: { $0.action == #selector(readFullInput) })?.title = readInputMenuTitle + (hotKey?.isRegistered == true ? "  ⌥T" : "")
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        Task { await panel?.endStatusMenuTracking() }
    }

    #if PROMPTBRIDGE_TESTING
    private func developerMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "开发与验证", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "开发与验证")
        let demo = NSMenuItem(title: "测试宿主", action: #selector(showDemo), keyEquivalent: "")
        demo.target = self
        submenu.addItem(demo)
        item.submenu = submenu
        return item
    }

    #endif
    @objc private func showSettings() {
        guard !externalTestMode, panel?.isBusy != true, workflow?.allowDraftSwitch() == true else { return }
        panel?.suspendForSettings()
        settingsController?.show()
    }

    private func showCLISettings() {
        guard !externalTestMode, panel?.isBusy != true, workflow?.allowDraftSwitch() == true else { return }
        panel?.suspendForSettings()
        settingsController?.show(initialSection: 2)
    }

    @objc private func showManual() {
        guard panel?.blocksEntrySwitch != true, workflow?.allowDraftSwitch() == true else { return }
        externalCaptureRequestID = UUID()
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.router?.isManual == false { guard await self.workflow?.prepareForEntrySwitch() == true else { return } }
            _ = self.router?.useManual()
            // A failed external capture can invalidate the draft while the router stays manual.
            await self.workflow?.useManualInput()
            await self.panel?.open()
        }
    }

    private func continueManual() {
        guard panel?.blocksEntrySwitch != true else { return }
        externalCaptureRequestID = UUID()
        Task { @MainActor [weak self] in
            guard let self, await self.workflow?.prepareForEntrySwitch() == true else { return }
            _ = self.router?.useManual()
            await self.workflow?.continueAsManualInput()
            await self.panel?.open()
        }
    }

    private func showSavedEntry(_ entry: DraftEntry) {
        guard entry != .manual, panel?.blocksEntrySwitch != true else { return }
        externalCaptureRequestID = UUID()
        Task { @MainActor [weak self] in
            guard let self, await self.workflow?.prepareForEntrySwitch() == true else { return }
            #if PROMPTBRIDGE_TESTING
            if entry == .demo {
                _ = self.router?.useDemo()
                self.host?.window.makeKeyAndOrderFront(nil)
            } else if entry == .cli { self.router?.useCLI("") }
            else { self.router?.useExternalDraft() }
            #else
            guard entry != .demo else { return }
            if entry == .cli { self.router?.useCLI("") }
            else { self.router?.useExternalDraft() }
            #endif
            if entry == .cli { await self.workflow?.useCLIInput() }
            else { await self.workflow?.openSavedEntry(entry) }
            await self.panel?.open()
        }
    }

    private func installMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let manualItem = NSMenuItem(title: "直接输入", action: #selector(showManual), keyEquivalent: "n")
        manualItem.target = self
        appMenu.addItem(manualItem)
        let cliItem = NSMenuItem(title: "导入 CLI 草稿", action: #selector(importCLIDraft), keyEquivalent: "")
        cliItem.target = self
        appMenu.addItem(cliItem)
        let externalHelp = NSMenuItem(title: "输入框翻译说明…", action: #selector(showExternalHelp), keyEquivalent: "")
        externalHelp.target = self
        appMenu.addItem(externalHelp)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 PromptBridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
            ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
            ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a"),
        ] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        #if PROMPTBRIDGE_TESTING
        menu.addItem(developerMenu())
        #endif
        NSApp.mainMenu = menu
    }
}
