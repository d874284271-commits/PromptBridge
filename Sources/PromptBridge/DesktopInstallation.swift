import AccessibilityContracts
import AppKit
import DraftCore
import SwiftUI

@MainActor final class DesktopInstallation: ObservableObject {
    static let shared = DesktopInstallation()
    @Published private(set) var busy = false
    @Published private(set) var installed = false
    @Published private(set) var message: String?
    var beforeChange: (() async throws -> Void)?
    var afterChange: (() -> Void)?

    #if PROMPTBRIDGE_TESTING
    func withPausedOperations(_ action: () async throws -> Void) async rethrows {
        busy = true
        defer { busy = false }
        try await action()
    }
    #endif

    func refresh() {
        let installer = DesktopInstaller()
        installed = FileManager.default.fileExists(atPath: installer.component.path)
            && FileManager.default.fileExists(atPath: installer.agent.path)
    }

    func install() { perform(removing: false) }
    func uninstall() { perform(removing: true) }

    private func perform(removing: Bool) {
        guard !busy else { return }
        busy = true
        message = removing ? "正在停用输入框接入…" : "正在安装应用与辅助组件…"
        Task {
            defer { busy = false; refresh(); afterChange?() }
            do {
                let certificate = try BrokerIdentity.signingCertificate()
                let others = NSRunningApplication.runningApplications(withBundleIdentifier: BrokerIdentity.clientBundle)
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
                guard others.isEmpty else { throw DesktopInstallError.message("请先退出另一份 PromptBridge，再安装或修复。当前草稿会保留。") }
                guard let beforeChange else { throw DesktopInstallError.message("应用尚未准备好，请稍后重试。") }
                try await beforeChange()
                // Disconnect waits for outstanding writes inside the helper;
                // allow its normal idle exit rather than killing an operation.
                let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                while NSRunningApplication.runningApplications(withBundleIdentifier: BrokerIdentity.bundle).contains(where: { !$0.isTerminated }) {
                    guard ContinuousClock.now < deadline else {
                        throw DesktopInstallError.message("辅助组件仍在使用中，请完成当前操作后重试。")
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
                let source = Bundle.main.bundleURL
                if removing {
                    let cli = CLIIntegrationInstaller(applicationURL: DesktopInstaller().application)
                    _ = try cli.setEnabled([], expected: cli.snapshot())
                }
                try await Task.detached {
                    let installer = DesktopInstaller()
                    if removing { try installer.uninstall(certificate: certificate) }
                    else { try installer.install(from: source, certificate: certificate) }
                }.value
                if removing {
                    message = "输入框与 CLI 接入已停用，模型配置和草稿已保留。"
                } else {
                    message = "安装完成。下次从“用户应用程序”打开 PromptBridge；当前草稿可继续使用。"
                }
            } catch {
                message = (error as? LocalizedError)?.errorDescription ?? "安装未完成，请检查安装目录后重试。"
            }
        }
    }

    func requestPermission() {
        Task {
            do { _ = try await BrokerClient.shared.request(.showPermissionHelp) }
            catch { message = "辅助组件尚未连接，请先安装或修复输入框接入。" }
        }
    }
}

struct DesktopInstallationView: View {
    @ObservedObject private var installation = DesktopInstallation.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输入框接入").font(.callout.weight(.medium))
            Text("直接输入无需授权；读取和替换其他应用的输入框需要辅助组件。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(installation.installed ? "修复接入" : "安装并启用") { installation.install() }
                if installation.installed {
                    Button("辅助功能权限…") { installation.requestPermission() }
                }
                if installation.busy { ProgressView().controlSize(.small) }
            }.disabled(installation.busy)
            if let message = installation.message {
                Text(message).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            if installation.installed {
                DisclosureGroup("停用接入") {
                    Button("停用输入框与 CLI 接入") { installation.uninstall() }.disabled(installation.busy)
                    Text("保留模型配置；主应用仍可用于直接输入。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.task { installation.refresh() }
    }
}
