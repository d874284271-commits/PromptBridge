import AppKit
import DraftCore
import SwiftUI

private final class SettingsWindow: NSWindow {
    var requestClose: (() -> Void)?
    var compositionStateChanged: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        compositionStateChanged?()
    }
    override func performClose(_ sender: Any?) { requestClose?() }
    override func cancelOperation(_ sender: Any?) {
        guard (firstResponder as? NSTextView)?.hasMarkedText() != true else { return }
        requestClose?()
    }
}

@MainActor final class SettingsController: NSObject, NSWindowDelegate {
    private let settings: TranslationSettings
    private var window: NSWindow?
    private let modelsLoader: ProviderEditor.ModelsLoader
    private var session: SettingsEditingSession?
    var uiTestEditor: ProviderEditor? { session?.provider }
    var uiTestSession: SettingsEditingSession? { session }
    var onClose: (() -> Void)?
    var uiTestWindow: NSWindow? { window }
    var uiTestCLIConnection: CLIConnectionController?

    init(settings: TranslationSettings, modelsLoader: @escaping ProviderEditor.ModelsLoader = { try await ProviderModelsClient().list(using: $0) }) {
        self.settings = settings
        self.modelsLoader = modelsLoader
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        settings.cancelEnvironmentImport()
        session?.provider.cancelModels()
        onClose?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { requestClose(); return false }
    func windowDidChangeScreen(_ notification: Notification) { if let window { fitWindow(window) } }

    func show(initialSection: Int = 0) {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
                                    styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "PromptBridge · 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        let editor = ProviderEditor(library: settings.library, modelsLoader: modelsLoader)
        let session = SettingsEditingSession(settings: settings, provider: editor, initialSection: initialSection)
        self.session = session
        session.nativeCompositionCheck = { [weak window] in
            (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
        }
        window.compositionStateChanged = { [weak session, weak window] in
            let marked = (window?.firstResponder as? NSTextView)?.hasMarkedText() == true
            if session?.nativeIsComposing != marked { session?.nativeIsComposing = marked }
        }
        window.requestClose = { [weak self] in self?.requestClose() }
        let content = NSHostingView(rootView: SettingsRootView(settings: settings, session: session,
            cliConnection: uiTestCLIConnection ?? .shared,
            importEnvironment: { [weak self] in self?.chooseEnvironment() },
            reloadModels: { [weak self] in self?.reloadModels() },
            reloadPreferences: { [weak self] in self?.reloadPreferences() },
            close: { [weak self] in self?.requestClose() }))
        content.sizingOptions = []
        window.contentView = content
        window.center()
        fitWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func fitWindow(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let desired = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 500, height: 620))
        let width = min(desired.width, visible.width)
        let height = min(desired.height, visible.height)
        let previous = window.frame
        let x = min(max(previous.minX, visible.minX), visible.maxX - width)
        let y = min(max(previous.maxY - height, visible.minY), visible.maxY - height)
        window.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    private func requestClose() {
        guard let window, session?.isComposing != true, window.attachedSheet == nil else { return }
        confirmDiscard(pages: session?.dirtyPageNames ?? []) { [weak window] discard in
            if discard { window?.close() }
        }
    }

    func confirmDiscardForTermination(_ completion: @escaping (Bool) -> Void) {
        guard let window, window.isVisible else { completion(true); return }
        guard session?.isComposing != true, window.attachedSheet == nil else { completion(false); return }
        confirmDiscard(pages: session?.dirtyPageNames ?? [], completion: completion)
    }

    private func confirmDiscard(pages: [String], completion: @escaping (Bool) -> Void) {
        guard !pages.isEmpty else { completion(true); return }
        guard let window, window.attachedSheet == nil else { completion(false); return }
        let alert = NSAlert()
        alert.messageText = "还有未保存的修改"
        alert.informativeText = "“\(pages.joined(separator: "”、“"))”中的修改尚未保存。"
        alert.addButton(withTitle: "继续编辑")
        alert.addButton(withTitle: "放弃未保存修改")
        alert.beginSheetModal(for: window) { response in completion(response == .alertSecondButtonReturn) }
    }

    private func reloadModels() {
        guard let session, !session.isComposing else { return }
        confirmDiscard(pages: session.provider.hasChanges ? ["模型连接"] : []) { [weak session] discard in
            if discard { session?.reloadModels() }
        }
    }

    private func reloadPreferences() {
        guard let session, !session.isComposing else { return }
        confirmDiscard(pages: session.preferencesHaveChanges ? ["翻译与浮窗"] : []) { [weak session] discard in
            if discard { session?.reloadPreferences() }
        }
    }

    private func chooseEnvironment() {
        guard let window, let session, !session.isComposing else { return }
        let picker = NSOpenPanel()
        picker.title = "选择本地 DeepSeek 环境文件"
        picker.message = "导入到模型配置草稿，保存后生效。文件内容不会作为脚本执行。"
        picker.prompt = "导入草稿"
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.showsHiddenFiles = true
        if let path = Bundle.main.object(forInfoDictionaryKey: "PromptBridgeEnvironmentFile") as? String {
            picker.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent()
        }
        picker.beginSheetModal(for: window) { [weak session] response in
            guard response == .OK, let url = picker.url else { return }
            session?.importEnvironment(url)
        }
    }
}

private struct SettingsRootView: View {
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var session: SettingsEditingSession
    let cliConnection: CLIConnectionController
    let importEnvironment: () -> Void
    let reloadModels: () -> Void
    let reloadPreferences: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Picker("设置类别", selection: Binding(get: { session.section }, set: { session.selectSection($0) })) {
                Text(session.provider.hasChanges ? "模型连接 ·" : "模型连接").tag(SettingsEditingSession.Section.model)
                Text(session.preferencesHaveChanges ? "翻译与浮窗 ·" : "翻译与浮窗").tag(SettingsEditingSession.Section.preferences)
                Text("CLI 接入").tag(SettingsEditingSession.Section.cli)
            }
            .labelsHidden().pickerStyle(.segmented).accessibilityLabel("设置类别")
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8).disabled(session.isComposing)
            if session.section == .model {
                SettingsView(settings: settings, session: session, editor: session.provider,
                    importEnvironment: importEnvironment, reload: reloadModels, close: close)
            } else if session.section == .preferences {
                TranslationPreferencesView(settings: settings, session: session, reload: reloadPreferences, close: close)
            } else {
                CLIIntegrationView(connection: cliConnection)
                Divider()
                HStack { Button("完成", action: close); Spacer() }.padding(.horizontal, 24).padding(.vertical, 16)
            }
        }
        .tint(InterfaceTheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SettingsView: View {
    @ObservedObject var settings: TranslationSettings
    @ObservedObject var session: SettingsEditingSession
    @ObservedObject var editor: ProviderEditor
    @FocusState private var focusedField: ProviderEditor.Field?
    let importEnvironment: () -> Void
    let reload: () -> Void
    let close: () -> Void
    private var busy: Bool { settings.isLoading || settings.isImporting }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    form.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: editor.fieldIssue) { _, issue in
                    guard let issue else { return }
                    if issue.field == .modelsPath { session.showsAdvancedConnection = true }
                    focusedField = issue.field
                    DispatchQueue.main.async { proxy.scrollTo(issue.field, anchor: .center) }
                }
            }
            footer
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("模型连接").font(.system(size: 20, weight: .semibold))
            if let notice = settings.environmentNotice {
                Text(notice).font(.caption).foregroundStyle(settings.isLoading ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #if PROMPTBRIDGE_TESTING
            Picker("翻译服务", selection: $editor.useAPI) {
                Text("本地演示").tag(false)
                Text("模型 API").tag(true)
            }.pickerStyle(.segmented).disabled(session.isComposing || busy)
            if editor.useAPI { modelFields }
            else {
                Text("本地演示使用固定示例，不调用模型。已保存的供应商预设会保留。")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            #else
            modelFields
            #endif
            if let error = editor.error { Text(error).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true) }
            if let notice = editor.notice { Text(notice).foregroundStyle(.secondary).font(.caption).fixedSize(horizontal: false, vertical: true) }
            Divider()
            DisclosureGroup("配置文件", isExpanded: $session.showsModelFile) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(settings.configFileURL?.path ?? "本地测试（不写文件）")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("重新读取配置", action: reload).disabled(settings.configFileURL == nil || busy || session.isComposing)
                        Button(settings.isImporting ? "正在导入…" : "导入环境文件…", action: importEnvironment)
                            .disabled(busy || session.isComposing)
                    }.font(.caption)
                    Text("导入只填入草稿；保存后生效。重新读取会用文件内容替换本页草稿。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }.disabled(session.isComposing)
        }
    }

    private var modelFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("供应商", selection: Binding(get: { editor.form.id }, set: { editor.select($0) })) {
                    ForEach(editor.presets) { Text($0.name.isEmpty ? "未命名供应商" : $0.name).tag($0.id) }
                    if !editor.presets.contains(where: { $0.id == editor.form.id }) { Text("新供应商").tag(editor.form.id) }
                }.accessibilityLabel("供应商列表")
                Button("新增") { editor.add() }
                Button("删除") { editor.delete() }.disabled(editor.presets.isEmpty)
            }.disabled(session.isComposing || busy)
            VStack(alignment: .leading, spacing: 6) {
                Text("名称").font(.callout.weight(.medium))
                TextField("例如：DeepSeek、公司代理", text: $editor.form.name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("供应商名称").focused($focusedField, equals: .name)
                fieldError(.name)
            }.id(ProviderEditor.Field.name)
            Picker("消息格式", selection: Binding(get: { editor.form.configuration.format }, set: { editor.setFormat($0) })) {
                ForEach(APIFormat.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }.accessibilityLabel("消息格式").disabled(session.isComposing || busy)
            VStack(alignment: .leading, spacing: 6) {
                Text("Base URL").font(.callout.weight(.medium))
                TextField("https://你的服务地址/v1", text: Binding(get: { editor.form.configuration.baseURL }, set: { editor.setBaseURL($0) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("API 基础地址").focused($focusedField, equals: .baseURL)
                fieldError(.baseURL)
            }.id(ProviderEditor.Field.baseURL)
            VStack(alignment: .leading, spacing: 6) {
                Text("API Key").font(.callout.weight(.medium))
                SecureField("输入此供应商的 API Key", text: Binding(get: { editor.form.configuration.apiKey }, set: { editor.setKey($0) }))
                    .textFieldStyle(.roundedBorder).accessibilityLabel("API Key").focused($focusedField, equals: .apiKey)
                fieldError(.apiKey)
            }.id(ProviderEditor.Field.apiKey)
            VStack(alignment: .leading, spacing: 6) {
                Text("模型").font(.callout.weight(.medium))
                HStack {
                    TextField("填写或从列表选择模型 ID", text: $editor.form.configuration.model)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("模型 ID").focused($focusedField, equals: .model)
                    if editor.isFetchingModels {
                        ProgressView().controlSize(.small)
                        Button("取消获取") { editor.cancelModels() }.disabled(session.isComposing)
                    } else {
                        Button("获取模型列表") { editor.fetchModels() }.disabled(busy || session.isComposing)
                    }
                }
                fieldError(.model)
                if !editor.models.isEmpty {
                    Menu("从模型列表选择") {
                        ForEach(editor.models) { model in
                            Button(model.displayName.map { "\($0)（\(model.id)）" } ?? model.id) { editor.form.configuration.model = model.id }
                        }
                    }.accessibilityLabel("模型列表").disabled(session.isComposing)
                }
                if let error = editor.modelListError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                if let notice = editor.modelListNotice { Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }.id(ProviderEditor.Field.model)
            DisclosureGroup("高级连接设置", isExpanded: Binding(get: { session.showsAdvancedConnection }, set: {
                if !session.isComposing { session.showsAdvancedConnection = $0 }
            })) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("模型列表路径").font(.callout.weight(.medium))
                    TextField("models", text: Binding(get: { editor.form.configuration.modelsPath }, set: { editor.setModelsPath($0) }))
                        .textFieldStyle(.roundedBorder).accessibilityLabel("模型列表路径").focused($focusedField, equals: .modelsPath)
                    fieldError(.modelsPath)
                    Text("拼接在 Base URL 后，默认为 models；服务要求 /model 时填写 model。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8).id(ProviderEditor.Field.modelsPath)
            }
            if editor.removesActivePreset {
                Text("当前启用的预设已标记删除：保存预设后需要重新选择模型；“保存并使用”会启用当前选择。")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }.disabled(settings.activeLoadKind == .savedConfiguration)
    }

    @ViewBuilder private func fieldError(_ field: ProviderEditor.Field) -> some View {
        if let issue = editor.fieldIssue, issue.presetID == editor.form.id, issue.field == field {
            Text(issue.message).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if editor.useAPI {
                Text("保存预设保留当前启用项；修改正在使用的预设会立即生效。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24)
            }
            HStack {
                Button("完成", action: close)
                Spacer(minLength: 8)
                if editor.useAPI {
                    Button("保存预设") { session.saveModels(activateSelected: false) }
                        .disabled(busy || session.isComposing || !editor.hasPresetChanges)
                }
                Button(editor.useAPI ? "保存并使用" : "保存设置") { session.saveModels(activateSelected: true) }
                    .buttonStyle(PrimaryActionStyle()).disabled(busy || session.isComposing)
            }.padding(.horizontal, 24).padding(.bottom, 16)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
