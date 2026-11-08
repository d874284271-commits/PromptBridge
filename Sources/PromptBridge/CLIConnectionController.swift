import AppKit
import AccessibilityContracts
import DraftCore
import SwiftUI

@MainActor final class CLIConnectionController: ObservableObject {
    static let shared = CLIConnectionController()
    @Published private(set) var registrations: [CLISessionRegistration] = []
    @Published private(set) var installation: CLIIntegrationStatus
    @Published private(set) var detections: [CLIHostKind: CLIExecutableDetection] = [:]
    @Published private(set) var message: String?
    @Published private(set) var terminalFrontmost = false
    @Published private(set) var automaticReadEnabled: Bool
    private let testingPreferences: UserDefaults
    private static let testingPreferenceKey = "CLIUserTestingEnabled"
    private var timer: Task<Void, Never>?
    private var targets: [UUID: CLITerminalTarget] = [:]
    private let installer: CLIIntegrationInstaller
    private let store: CLISessionStore
    private let liveInspection: Bool
    private let broker: BrokerClient
    private let applicationURL: URL
    static var installedApplicationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/PromptBridge.app")
    }
    init(broker: BrokerClient = .shared, home: URL = FileManager.default.homeDirectoryForCurrentUser,
         applicationURL: URL = CLIConnectionController.installedApplicationURL, liveInspection: Bool = true,
         testingPreferences: UserDefaults = .standard, initialRegistrations: [CLISessionRegistration] = []) {
        self.broker = broker; self.liveInspection = liveInspection; store = CLISessionStore(home: home)
        self.applicationURL = applicationURL
        self.testingPreferences = testingPreferences
        automaticReadEnabled = testingPreferences.object(forKey: Self.testingPreferenceKey) as? Bool ?? true
        installer = CLIIntegrationInstaller(home: home, applicationURL: applicationURL)
        installation = installer.inspect()
        if !liveInspection { registrations = initialRegistrations }
    }
    func setAutomaticReadEnabled(_ enabled: Bool) {
        automaticReadEnabled = enabled
        testingPreferences.set(enabled, forKey: Self.testingPreferenceKey)
        message = enabled ? "浮窗读取已开启。回到已连接的 CLI 输入框，再点击浮窗读取草稿。" : "浮窗读取已关闭，仍可手动打开 CLI 外部编辑器。"
    }
    func start() {
        guard timer == nil else { return }
        refreshSessions()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                self.refreshSessions()
            }
        }
    }
    func stop() { timer?.cancel(); timer = nil }
    func refreshSessions() {
        guard liveInspection else { return }
        terminalFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal"
        registrations = store.all().filter {
            if kill($0.session.pid, 0) != 0 { store.remove($0.session.id); return false }
            return $0.session.isCurrent
        }
    }
    func detect() {
        installation = installer.inspect(); refreshSessions()
        guard liveInspection else { return }
        let path = CLIExecutableProbe.searchPath()
        Task {
            let values = await Task.detached {
                CLIHostKind.allCases.map { ($0, CLIExecutableProbe.detect(host: $0, path: path)) }
            }.value
            detections = Dictionary(uniqueKeysWithValues: values)
        }
    }
    func setEnabled(_ kind: CLIHostKind, enabled: Bool) {
        guard !DesktopInstallation.shared.busy else { message = "正在更改应用接入，请稍后再试。"; return }
        if enabled, let shell = getpwuid(getuid())?.pointee.pw_shell, !String(cString: shell).hasSuffix("/zsh") {
            message = "自动接入仅支持 zsh。请点击“选择项目并启动”。"; return
        }
        do {
            var selected = installer.inspect().enabledHosts
            if enabled { selected.insert(kind) } else { selected.remove(kind) }
            installation = try installer.setEnabled(selected, expected: installer.snapshot())
            message = installation.issues.first ?? (enabled ? "接入已启用，下次打开终端后生效。正在运行的 CLI 无需退出。" : "已停用所选 CLI 接入。")
        } catch { message = error.localizedDescription }
    }
    func repair() {
        guard !DesktopInstallation.shared.busy else { message = "正在更改应用接入，请稍后再试。"; return }
        do { installation = try installer.setEnabled(installation.enabledHosts, expected: installer.snapshot()); message = "已检查并修复可识别的接入文件。" }
        catch { message = error.localizedDescription }
    }
    func read(using editor: CLIEditorSession) async {
        guard !DesktopInstallation.shared.busy else { message = "正在更改应用接入，请稍后再试。"; return }
        guard !editor.active, editor.readIntent == nil else { return }
        refreshSessions()
        guard automaticReadEnabled else { editor.failRead("浮窗读取已关闭，仍可手动打开 CLI 外部编辑器。"); return }
        let candidates = registrations
        guard !candidates.isEmpty else {
            editor.failRead("当前 CLI 未连接。请在设置中启用接入，再新开会话。")
            return
        }
        var stage = "定位 Terminal 标签页"
        do {
            var selected: CLITerminalTarget?
            for registration in candidates {
                do {
                    selected = try await broker.request(.cliQueryTarget,
                        payload: BrokerPayload(cliSession: registration.session)).cliTarget
                    if selected != nil { break }
                } catch let error as BrokerRemoteError where error.code == .targetChanged { continue }
            }
            guard let selected else {
                editor.failRead("当前选中的终端标签页没有可关联的 CLI。"); return
            }
            guard !Task.isCancelled else { editor.failRead("读取已取消；未触发编辑器。"); return }
            guard automaticReadEnabled else {
                editor.failRead("浮窗读取已关闭，未打开外部编辑器。"); return
            }
            guard editor.beginRead(sessionID: selected.session.id) else { return }
            targets[selected.session.id] = selected
            stage = "触发外部编辑快捷键"
            _ = try await broker.request(.cliTriggerEditor,
                payload: BrokerPayload(operationID: UUID(), cliTarget: selected))
            Task { [weak editor] in
                try? await Task.sleep(for: .seconds(15))
                editor?.expireRead()
            }
        } catch { editor.failRead("CLI 读取失败（\(stage)）：\(describe(error))") }
    }
    func prepareReturn(for session: CLITerminalSession) async {
        guard !DesktopInstallation.shared.busy else { message = "正在更改应用接入，请稍后再试。"; return }
        guard targets[session.id] == nil,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal" else { return }
        if let result = try? await broker.request(.cliQueryTarget, payload: BrokerPayload(cliSession: session)),
           let target = result.cliTarget { targets[session.id] = target }
    }
    func finish(session: CLITerminalSession, completion: CLIEditorCompletion, editor: CLIEditorSession) async {
        guard let target = targets.removeValue(forKey: session.id) else {
            editor.reportReturn(completion.message + " 未能定位原标签页，请在终端继续。", requestID: completion.id, focus: .failed); return
        }
        do {
            let result = try await broker.request(.cliReturnTarget, payload: BrokerPayload(operationID: UUID(), cliTarget: target))
            let suffix = result.cliAction?.disposition == .returned ? " 已返回原标签页。" : " 你已切换到其他窗口，因此未切回终端。"
            editor.reportReturn(completion.message + suffix, requestID: completion.id,
                focus: result.cliAction?.disposition == .returned ? .returned : .userMovedFocus)
        } catch { editor.reportReturn(completion.message + " 未能返回原标签页：" + describe(error), requestID: completion.id, focus: .failed) }
    }
    func requestPermissionHelp() {
        guard !DesktopInstallation.shared.busy else { message = "正在更改应用接入，请稍后再试。"; return }
        Task { do { _ = try await broker.request(.showPermissionHelp) }
            catch { message = "无法打开配套组件：\(describe(error))" } }
    }
    func launchProject(_ kind: CLIHostKind) {
        guard !DesktopInstallation.shared.busy else { message = "正在更改应用接入，请稍后再试。"; return }
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.allowsMultipleSelection = false; picker.prompt = "启动 \(kind.rawValue)"
        guard picker.runModal() == .OK, let directory = picker.url else { return }
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PromptBridgeLaunch")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try CLIEditorExchange.verifyPrivate(root, directory: true)
            let file = root.appendingPathComponent(UUID().uuidString + ".command")
            func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
            let script = "#!/bin/zsh\nexport PATH=\(quote(CLIExecutableProbe.searchPath()))\nrm -- \"$0\"\ncd -- \(quote(directory.path)) || exit 1\nexec \(quote(applicationURL.appendingPathComponent("Contents/MacOS/promptbridge-editor").path)) --launch \(kind.rawValue) --\n"
            try Data(script.utf8).write(to: file, options: .withoutOverwriting)
            guard chmod(file.path, 0o700) == 0 else { throw CLIEditorFailure.unavailable }
            NSWorkspace.shared.open([file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { try? FileManager.default.removeItem(at: file) }
            }
        } catch { message = error.localizedDescription }
    }
    private func describe(_ error: Error) -> String {
        if let transport = error as? BrokerTransportError {
            switch transport {
            case .unavailable: return "无法连接辅助组件，请检查组件运行状态。"
            case .timeout: return "辅助组件响应超时；未自动重试。"
            case .invalidIdentity: return "辅助组件签名身份校验失败。"
            case .incompatibleProtocol: return "主应用与组件协议不匹配，请更新主应用和配套组件。"
            case .invalidResponse: return "辅助组件回执无效；未继续操作。"
            }
        }
        guard let remote = error as? BrokerRemoteError else { return "辅助组件请求失败；未继续操作。" }
        switch remote.code {
        case .automationRequired: return "请允许辅助组件自动化控制 Terminal。"
        case .permissionRequired: return "请为辅助组件开启辅助功能权限。"
        case .targetChanged, .identityChanged: return "终端标签页或 CLI 进程已变化，请回到输入区重新读取。"
        case .cliNotValidated, .cliKeyBindingUnsupported: return "组件仍使用旧接入规则，请更新配套组件。"
        default: return remote.code.rawValue
        }
    }
}

struct CLIIntegrationView: View {
    @ObservedObject var connection: CLIConnectionController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CLI 接入").font(.title2.bold())
                Text("本页操作立即生效。启用或停用影响之后启动的会话；已连接会话保持原有状态。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(Bundle.main.bundleURL.standardizedFileURL == CLIConnectionController.installedApplicationURL.standardizedFileURL
                    ? "当前使用：已安装的 PromptBridge"
                    : "当前是归档副本。请退出后打开桌面的 PromptBridge。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("启用接入后，照常在 Terminal 中启动 CLI。Auto 开启时，点击浮窗即可读取、翻译并替换原文；关闭后，生成预览并由你确认替换。不会发送消息。").font(.callout)
                ForEach(CLIHostKind.allCases, id: \.self) { kind in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(kind == .codex ? "Codex CLI" : "Claude Code").font(.headline)
                            if let detection = connection.detections[kind] {
                                Text(detection.version.map { "检测到 \($0)" } ?? detection.reason ?? "未找到 CLI").font(.caption)
                            }
                            Text(connection.installation.enabledHosts.contains(kind) ? "已启用接入" : "尚未启用接入")
                            if connection.installation.shellConflicts.contains(kind) {
                                Text("检测到同名 alias/function，已保留原设置。请点击“选择项目并启动”。").font(.caption).foregroundStyle(.orange)
                            }
                            let count = connection.registrations.filter { $0.session.kind == kind }.count
                            Text(count > 0 ? "当前已连接 \(count) 个会话" : "暂无已连接的会话").font(.caption)
                            HStack {
                                Button(connection.installation.enabledHosts.contains(kind) ? "停用接入" : "启用接入") {
                                    connection.setEnabled(kind, enabled: !connection.installation.enabledHosts.contains(kind))
                                }
                                Button("选择项目并启动") { connection.launchProject(kind) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("点击浮窗读取 CLI 草稿", isOn: Binding(get: { connection.automaticReadEnabled }, set: { connection.setAutomaticReadEnabled($0) }))
                        Text("开启后，点击浮窗会尝试用 Ctrl+G 读取草稿。关闭后仍可手动打开外部编辑器。是否自动翻译并替换，由“翻译与浮窗”中的 Auto 开关控制。")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("每次点击只尝试读取一次，不会自动重试。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("重新检测") { connection.detect() }
                    Button("修复接入") { connection.repair() }
                    Button("组件与权限") { connection.requestPermissionHelp() }
                }
                ForEach(connection.installation.issues, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                if let message = connection.message { Text(message).font(.caption).fixedSize(horizontal: false, vertical: true) }
            }.padding(24)
        }.tint(InterfaceTheme.accent).onAppear { connection.detect() }
    }
}
