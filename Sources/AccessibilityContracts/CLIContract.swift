import Foundation
import Darwin

public enum CLIHostKind: String, Codable, Sendable, CaseIterable { case codex, claude }

public struct CLITerminalSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: CLIHostKind
    public let version: String
    public let pid: Int32
    public let startTimeMicros: UInt64
    public let processGroup: Int32
    public let tty: String
    public let executablePath: String

    public init(id: UUID, kind: CLIHostKind, version: String, pid: Int32,
                startTimeMicros: UInt64, processGroup: Int32, tty: String, executablePath: String) {
        self.id = id; self.kind = kind; self.version = version; self.pid = pid
        self.startTimeMicros = startTimeMicros; self.processGroup = processGroup
        self.tty = tty; self.executablePath = executablePath
    }
    public func validate() throws {
        guard pid > 0, processGroup > 0, startTimeMicros > 0, !version.isEmpty,
              tty.hasPrefix("/dev/tty"), !tty.contains(".."), !tty.contains("\0"),
              executablePath.hasPrefix("/"), !executablePath.contains("\0") else {
            throw BrokerContractError.invalidMessage
        }
    }
    public var isCurrent: Bool { CLIProcessSnapshot.inspect(pid: pid)?.matches(session: self) == true }
}

/// Metadata only: no command line, environment, terminal contents or history.
public struct CLIProcessSnapshot: Codable, Equatable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let startTimeMicros: UInt64
    public let processGroup: Int32
    public let executablePath: String
    public let tty: String
    public let foregroundProcessGroup: Int32
    public init(pid: Int32, parentPID: Int32, startTimeMicros: UInt64, processGroup: Int32,
                executablePath: String, tty: String, foregroundProcessGroup: Int32 = 0) {
        self.pid = pid; self.parentPID = parentPID; self.startTimeMicros = startTimeMicros
        self.processGroup = processGroup; self.executablePath = executablePath
        self.tty = tty; self.foregroundProcessGroup = foregroundProcessGroup
    }
    public func matches(session: CLITerminalSession) -> Bool {
        pid == session.pid && startTimeMicros == session.startTimeMicros &&
        processGroup == session.processGroup && tty == session.tty && executablePath == session.executablePath
    }
    public static func inspect(pid: Int32) -> CLIProcessSnapshot? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_status != UInt32(SZOMB) else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = String(cString: path)
        var tty = ""
        for fd: Int32 in [0, 1, 2] {
            var vnode = vnode_fdinfowithpath()
            let vnodeSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &vnode, vnodeSize) == vnodeSize else { continue }
            let candidate = withUnsafePointer(to: &vnode.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            var metadata = stat()
            if candidate.hasPrefix("/dev/tty"), lstat(candidate, &metadata) == 0,
               metadata.st_mode & S_IFMT == S_IFCHR, UInt32(bitPattern: metadata.st_rdev) == info.e_tdev {
                tty = candidate; break
            }
        }
        return CLIProcessSnapshot(pid: pid, parentPID: Int32(info.pbi_ppid),
            startTimeMicros: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
            processGroup: Int32(info.pbi_pgid), executablePath: executable, tty: tty,
            foregroundProcessGroup: Int32(bitPattern: info.e_tpgid))
    }
}

public enum CLIAutomationPermission: String, Codable, Sendable {
    case granted, denied, notDetermined, unavailable, unknown
}

public struct CLITerminalTarget: Codable, Equatable, Sendable {
    public let token: UUID
    public let session: CLITerminalSession
    public let terminalPID: Int32
    public let terminalStartTimeMicros: UInt64
    public let windowID: Int32
    public init(token: UUID, session: CLITerminalSession, terminalPID: Int32,
                terminalStartTimeMicros: UInt64, windowID: Int32) {
        self.token = token; self.session = session; self.terminalPID = terminalPID
        self.terminalStartTimeMicros = terminalStartTimeMicros; self.windowID = windowID
    }
    public func validate() throws {
        try session.validate()
        guard terminalPID > 0, terminalStartTimeMicros > 0, windowID > 0 else { throw BrokerContractError.invalidMessage }
    }
}

public enum CLIActionDisposition: String, Codable, Sendable { case triggered, returned, userMovedFocus }
public struct CLIActionReceipt: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let targetToken: UUID
    public let disposition: CLIActionDisposition
    public init(operationID: UUID, targetToken: UUID, disposition: CLIActionDisposition) {
        self.operationID = operationID; self.targetToken = targetToken; self.disposition = disposition
    }
}
