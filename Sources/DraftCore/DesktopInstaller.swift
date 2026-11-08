import AccessibilityContracts
import AppKit
import Darwin
import Foundation

public enum DesktopInstallError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}

/// Native user-level installation. Callers quiesce the app and helper first.
/// System effects are injectable so transaction failures can be checked offline.
public struct DesktopInstaller: Sendable {
    public typealias Verify = @Sendable (URL, String, String) throws -> Void
    public typealias Service = @Sendable ([String]) throws -> Int32
    public let home: URL
    private let verify: Verify
    private let service: Service
    private let ensureQuiescent: @Sendable () throws -> Void
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                verify: @escaping Verify = ApplicationSignature.verify,
                service: @escaping Service = DesktopInstaller.launchctl,
                ensureQuiescent: @escaping @Sendable () throws -> Void = DesktopInstaller.requireIdle) {
        self.home = home; self.verify = verify; self.service = service; self.ensureQuiescent = ensureQuiescent
    }
    public var application: URL { home.appendingPathComponent("Applications/PromptBridge.app") }
    public var component: URL { home.appendingPathComponent("Applications/PromptBridge Accessibility.app") }
    public var agent: URL { home.appendingPathComponent("Library/LaunchAgents/" + BrokerIdentity.bundle + ".plist") }
    private var domain: String { "gui/\(getuid())" }
    private var serviceName: String { domain + "/" + BrokerIdentity.bundle }

    public static func requireIdle() throws {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let anotherApp = NSRunningApplication.runningApplications(withBundleIdentifier: BrokerIdentity.clientBundle)
            .contains { !$0.isTerminated && $0.processIdentifier != ownPID }
        let activeHelper = NSRunningApplication.runningApplications(withBundleIdentifier: BrokerIdentity.bundle)
            .contains { !$0.isTerminated }
        guard !anotherApp && !activeHelper else {
            throw DesktopInstallError.message("应用或辅助组件重新进入使用状态，安装已暂停。请完成操作后重试。")
        }
    }

    public static func launchctl(_ arguments: [String]) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if arguments.first == "print", task.terminationStatus == 0 {
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let program = home.appendingPathComponent("Applications/PromptBridge Accessibility.app/Contents/MacOS/AccessibilityBroker").path
            let plist = home.appendingPathComponent("Library/LaunchAgents/" + BrokerIdentity.bundle + ".plist").path
            guard lines.contains("program = " + program), lines.contains("path = " + plist) else {
                throw DesktopInstallError.message("已注册服务的来源与当前安装不符，请先检查接入。")
            }
        }
        return task.terminationStatus
    }

    private func configuration() throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "Label": BrokerIdentity.bundle,
            "ProgramArguments": [component.appendingPathComponent("Contents/MacOS/AccessibilityBroker").path],
            "MachServices": [BrokerIdentity.service: true], "RunAtLoad": false, "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive"
        ], format: .xml, options: 0)
    }

    private func validateAgent() throws {
        guard stamp(agent) != nil else { return }
        try rejectLink(agent)
        let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as? [String: Any]
        guard values?["Label"] as? String == BrokerIdentity.bundle,
              values?["ProgramArguments"] as? [String] == [component.appendingPathComponent("Contents/MacOS/AccessibilityBroker").path],
              values?["MachServices"] as? [String: Bool] == [BrokerIdentity.service: true] else {
            throw DesktopInstallError.message("辅助服务配置已被修改，请先检查现有接入。")
        }
    }

    public func install(from source: URL, certificate: String) throws {
        let fm = FileManager.default
        let apps = application.deletingLastPathComponent()
        try prepareDirectory(apps)
        try prepareDirectory(agent.deletingLastPathComponent())
        let lock = apps.appendingPathComponent(".promptbridge-install.lock")
        let lockFD = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw DesktopInstallError.message("无法创建安装锁。") }
        defer { Darwin.close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw DesktopInstallError.message("另一份应用正在安装，请稍后重试。") }
        defer { flock(lockFD, LOCK_UN) }

        let embedded = source.appendingPathComponent("Contents/Helpers/PromptBridge Accessibility.app")
        try rejectLink(source); try rejectLink(embedded)
        try verify(source, BrokerIdentity.clientBundle, certificate)
        try verify(embedded, BrokerIdentity.bundle, certificate)
        guard Bundle(url: source)?.object(forInfoDictionaryKey: "PromptBridgeIPCProtocol") as? Int == 3,
              Bundle(url: embedded)?.object(forInfoDictionaryKey: "PromptBridgeIPCProtocol") as? Int == 3 else {
            throw DesktopInstallError.message("应用与辅助组件版本不匹配，请重新下载完整安装包。")
        }
        let replacingMain = source.standardizedFileURL != application.standardizedFileURL
        for (url, bundle) in [(application, BrokerIdentity.clientBundle), (component, BrokerIdentity.bundle)] where stamp(url) != nil {
            try rejectLink(url); try verify(url, bundle, certificate)
        }
        try validateAgent()
        let previouslyRegistered = try service(["print", serviceName]) == 0
        guard !previouslyRegistered || stamp(agent) != nil else {
            throw DesktopInstallError.message("已有辅助服务缺少可验证的配置，请先检查接入。")
        }

        // Read the verified old installation before replacing its bundle.
        if let previous = Bundle(url: application) {
            let old = (previous.object(forInfoDictionaryKey: "PromptBridgeConfigFile") as? String).map { URL(fileURLWithPath: $0) }
            let environment = (previous.object(forInfoDictionaryKey: "PromptBridgeEnvironmentFile") as? String).map { URL(fileURLWithPath: $0) }
            try ApplicationStorage.migrate(from: old, environment: environment,
                to: home.appendingPathComponent("Library/Application Support/PromptBridge"))
        }
        let transaction = apps.appendingPathComponent(".PromptBridge-install-" + UUID().uuidString)
        try fm.createDirectory(at: transaction, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var changes: [(destination: URL, backup: URL, original: Stamp?, published: Stamp?)] = []
        var stopped = false
        var newRegistered = false
        do {
            let candidates: [(URL?, URL)] = (replacingMain ? [(source, application)] : []) + [(embedded, component), (nil, agent)]
            var staged: [(URL, URL, Stamp?)] = []
            for (input, destination) in candidates {
                let stage = transaction.appendingPathComponent("new-" + destination.lastPathComponent)
                if let input { try fm.copyItem(at: input, to: stage) }
                else { try configuration().write(to: stage, options: .withoutOverwriting) }
                if input != nil { try verify(stage, destination == application ? BrokerIdentity.clientBundle : BrokerIdentity.bundle, certificate) }
                staged.append((stage, destination, stamp(destination)))
            }
            try ensureQuiescent()
            if previouslyRegistered {
                guard try service(["bootout", serviceName]) == 0 else { throw DesktopInstallError.message("辅助服务未能停止，安装未开始。") }
                stopped = true
            }
            for (stage, destination, expected) in staged {
                guard stamp(destination) == expected else { throw DesktopInstallError.message("安装目标已变化，请重新安装。") }
                let backup = transaction.appendingPathComponent("old-" + destination.lastPathComponent)
                if expected != nil { try moveExclusive(destination, backup) }
                changes.append((destination, backup, expected, nil))
                try moveExclusive(stage, destination)
                changes[changes.count - 1].published = stamp(destination)
            }
            guard try service(["bootstrap", domain, agent.path]) == 0 else {
                throw DesktopInstallError.message("辅助服务注册失败，正在恢复原安装。")
            }
            newRegistered = true
            guard try service(["print", serviceName]) == 0 else {
                throw DesktopInstallError.message("辅助服务未能连接，正在恢复原安装。")
            }
            // Keep the previous pair in this transaction directory for recovery.
            if changes.allSatisfy({ $0.original == nil }) { try? fm.removeItem(at: transaction) }
        } catch {
            var complete = true
            if newRegistered { complete = (try? service(["bootout", serviceName])) == 0 }
            for change in changes.reversed() {
                do {
                    if let published = change.published {
                        guard stamp(change.destination) == published else { throw DesktopInstallError.message("安装目标已变化。") }
                        if change.destination == agent {
                            guard try Data(contentsOf: agent) == configuration() else { throw DesktopInstallError.message("服务配置已变化。") }
                        } else {
                            try verify(change.destination, change.destination == application ? BrokerIdentity.clientBundle : BrokerIdentity.bundle, certificate)
                        }
                        try fm.removeItem(at: change.destination)
                    }
                    if change.original != nil { try moveExclusive(change.backup, change.destination) }
                } catch { complete = false }
            }
            if previouslyRegistered && stopped && complete { complete = (try? service(["bootstrap", domain, agent.path])) == 0 }
            if !complete {
                throw DesktopInstallError.message("安装未完成，部分文件已变化，备份保留在 \(transaction.path)。请检查后修复接入。")
            }
            try? fm.removeItem(at: transaction)
            throw error
        }
    }

    /// Removes only the helper service and its signed app. User data and the
    /// running main app remain; CLI shell integration is removed by its owner.
    public func uninstall(certificate: String) throws {
        try prepareDirectory(application.deletingLastPathComponent())
        try prepareDirectory(agent.deletingLastPathComponent())
        let lock = application.deletingLastPathComponent().appendingPathComponent(".promptbridge-install.lock")
        let descriptor = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw DesktopInstallError.message("无法创建安装锁。") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw DesktopInstallError.message("另一份应用正在更改安装。") }
        defer { flock(descriptor, LOCK_UN) }
        try validateAgent()
        if stamp(component) != nil { try rejectLink(component); try verify(component, BrokerIdentity.bundle, certificate) }
        try ensureQuiescent()
        if try service(["print", serviceName]) == 0 {
            guard try service(["bootout", serviceName]) == 0 else { throw DesktopInstallError.message("辅助服务仍在运行，请稍后重试。") }
        }
        if stamp(agent) != nil { try FileManager.default.removeItem(at: agent) }
        if stamp(component) != nil { try FileManager.default.removeItem(at: component) }
    }

    private struct Stamp: Equatable { let device: dev_t; let inode: ino_t }
    private func stamp(_ url: URL) -> Stamp? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return nil }
        return Stamp(device: value.st_dev, inode: value.st_ino)
    }
    private func rejectLink(_ url: URL) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT != S_IFLNK else {
            throw DesktopInstallError.message("安装目标不存在或是符号链接：\(url.lastPathComponent)")
        }
    }
    private func prepareDirectory(_ url: URL) throws {
        // Reject redirecting any destination ancestor outside the user's tree.
        var current = url
        while current.path.count >= home.path.count {
            if stamp(current) != nil { try rejectLink(current) }
            if current == home { break }
            current.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    private func moveExclusive(_ source: URL, _ destination: URL) throws {
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw DesktopInstallError.message("安装文件冲突：\(destination.lastPathComponent)")
        }
    }
}
