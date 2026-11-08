import Foundation
import AccessibilityContracts

public struct CLITerminalTab: Equatable, Sendable {
    public let windowID: Int32
    public let tty: String
    public let selected: Bool
    public let frontWindow: Bool
    public init(windowID: Int32, tty: String, selected: Bool, frontWindow: Bool) {
        self.windowID = windowID; self.tty = tty; self.selected = selected; self.frontWindow = frontWindow
    }
}

/// This interface deliberately cannot request terminal text, titles or arbitrary events.
@MainActor public protocol CLITerminalAccess: AnyObject {
    var accessibilityGranted: Bool { get }
    var automationPermission: CLIAutomationPermission { get }
    var frontmostPID: Int32? { get }
    func terminalProcess() -> CLIProcessSnapshot?
    func process(_ pid: Int32) -> CLIProcessSnapshot?
    func tabs(terminalPID: Int32) throws -> [CLITerminalTab]
    func sendControlG(terminalPID: Int32) throws
    func select(tty: String, windowID: Int32, terminalPID: Int32) throws
    func activate(terminalPID: Int32) -> Bool
}

@MainActor public final class CLITerminalRuntime {
    private let access: any CLITerminalAccess
    private var targets: [UUID: CLITerminalTarget] = [:]
    private var operations: Set<UUID> = []
    private var triggered: Set<UUID> = []
    public init(access: any CLITerminalAccess) { self.access = access }
    public func clear() { targets.removeAll(); operations.removeAll(); triggered.removeAll() }
    private func checkSession(_ session: CLITerminalSession, foreground: Bool) throws {
        try session.validate()
        guard let current = access.process(session.pid), current.matches(session: session) else {
            throw BrokerProbeFailure(code: .identityChanged)
        }
        if foreground, current.foregroundProcessGroup != session.processGroup {
            throw BrokerProbeFailure(code: .targetChanged)
        }
    }
    private func checkPermissions() throws {
        guard access.accessibilityGranted else { throw BrokerProbeFailure(code: .permissionRequired) }
        guard access.automationPermission == .granted else { throw BrokerProbeFailure(code: .automationRequired) }
    }
    private func uniqueTab(_ session: CLITerminalSession, terminalPID: Int32) throws -> CLITerminalTab {
        let matches = try access.tabs(terminalPID: terminalPID).filter { $0.tty == session.tty }
        guard matches.count == 1, let tab = matches.first else { throw BrokerProbeFailure(code: .targetChanged) }
        return tab
    }
    public func query(_ session: CLITerminalSession) throws -> CLITerminalTarget {
        try checkSession(session, foreground: true)
        try checkPermissions()
        guard let terminal = access.terminalProcess(), access.frontmostPID == terminal.pid else {
            throw BrokerProbeFailure(code: .targetChanged)
        }
        let tab = try uniqueTab(session, terminalPID: terminal.pid)
        guard tab.selected, tab.frontWindow else { throw BrokerProbeFailure(code: .targetChanged) }
        // Replace prior query tokens for this session, so old UI operations cannot trigger it.
        targets = targets.filter { $0.value.session.id != session.id }
        let target = CLITerminalTarget(token: UUID(), session: session, terminalPID: terminal.pid,
            terminalStartTimeMicros: terminal.startTimeMicros, windowID: tab.windowID)
        targets[target.token] = target
        return target
    }
    private func checkTarget(_ target: CLITerminalTarget, foreground: Bool) throws -> CLITerminalTab {
        try target.validate()
        guard targets[target.token] == target,
              let terminal = access.terminalProcess(), terminal.pid == target.terminalPID,
              terminal.startTimeMicros == target.terminalStartTimeMicros else { throw BrokerProbeFailure(code: .targetChanged) }
        try checkSession(target.session, foreground: foreground)
        try checkPermissions()
        return try uniqueTab(target.session, terminalPID: terminal.pid)
    }
    public func trigger(_ target: CLITerminalTarget, operationID: UUID) throws -> CLIActionReceipt {
        guard operations.insert(operationID).inserted, triggered.insert(target.token).inserted else {
            throw BrokerProbeFailure(code: .duplicateOperation)
        }
        let tab = try checkTarget(target, foreground: true)
        guard access.frontmostPID == target.terminalPID, tab.selected, tab.frontWindow,
              tab.windowID == target.windowID else { throw BrokerProbeFailure(code: .targetChanged) }
        // Recheck after metadata IPC before issuing the one fixed key pair.
        try checkSession(target.session, foreground: true)
        guard access.frontmostPID == target.terminalPID else { throw BrokerProbeFailure(code: .targetChanged) }
        try access.sendControlG(terminalPID: target.terminalPID)
        return CLIActionReceipt(operationID: operationID, targetToken: target.token, disposition: .triggered)
    }
    public func returnTarget(_ target: CLITerminalTarget, operationID: UUID, clientPID: Int32) throws -> CLIActionReceipt {
        guard operations.insert(operationID).inserted else { throw BrokerProbeFailure(code: .duplicateOperation) }
        defer { targets.removeValue(forKey: target.token) }
        let tab = try checkTarget(target, foreground: false)
        // Never steal focus after the user has switched away from PromptBridge.
        guard access.frontmostPID == clientPID else {
            return CLIActionReceipt(operationID: operationID, targetToken: target.token, disposition: .userMovedFocus)
        }
        try checkSession(target.session, foreground: false)
        guard access.frontmostPID == clientPID else {
            return CLIActionReceipt(operationID: operationID, targetToken: target.token, disposition: .userMovedFocus)
        }
        try access.select(tty: target.session.tty, windowID: tab.windowID, terminalPID: target.terminalPID)
        guard access.frontmostPID == clientPID, access.activate(terminalPID: target.terminalPID) else {
            return CLIActionReceipt(operationID: operationID, targetToken: target.token, disposition: .userMovedFocus)
        }
        let returned = try uniqueTab(target.session, terminalPID: target.terminalPID)
        guard returned.selected, returned.frontWindow, access.frontmostPID == target.terminalPID else {
            throw BrokerProbeFailure(code: .targetChanged)
        }
        return CLIActionReceipt(operationID: operationID, targetToken: target.token, disposition: .returned)
    }
}
