import AccessibilityContracts
import Darwin
import Foundation

public enum CLIEditorProtocol { public static let version = 2 }

/// Local presentation state. A file receipt cannot prove that the CLI reloaded it.
public struct CLIEditorOutcome: Equatable, Sendable {
    public enum Handoff: Sendable { case successfulExitRequested, notCommitted }
    public enum Focus: Sendable { case pending, returned, userMovedFocus, failed }
    public let id: UUID
    public let status: CLIEditorCompletion.Status
    public let handoff: Handoff
    public var focus: Focus = .pending
    public init(_ completion: CLIEditorCompletion) {
        id = completion.id; status = completion.status
        handoff = completion.status == .saved ? .successfulExitRequested : .notCommitted
    }
}

public struct CLISessionRegistration: Codable, Equatable, Sendable {
    public let version: Int
    public let session: CLITerminalSession
    public let originalVisual: String?
    public let originalEditor: String?
    public let codexHome: String
    public let claudeTempRoot: String
    public let workingDirectory: String
    public let createdUptime: TimeInterval
    /// Legacy persisted field. Runtime admission ignores it; new registrations write true.
    public let automaticReadEligible: Bool

    public init(session: CLITerminalSession, originalVisual: String? = nil, originalEditor: String? = nil,
                codexHome: String, claudeTempRoot: String = "/tmp", workingDirectory: String,
                createdUptime: TimeInterval = ProcessInfo.processInfo.systemUptime, automaticReadEligible: Bool = true) {
        self.automaticReadEligible = automaticReadEligible
        version = CLIEditorProtocol.version; self.session = session
        self.originalVisual = originalVisual; self.originalEditor = originalEditor
        self.codexHome = codexHome; self.claudeTempRoot = claudeTempRoot
        self.workingDirectory = workingDirectory; self.createdUptime = createdUptime
    }
}

public struct CLISessionStore: Sendable {
    public let directory: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        directory = home.appendingPathComponent("Library/Application Support/PromptBridge/CLI/sessions")
    }
    public func save(_ registration: CLISessionRegistration) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try CLIEditorExchange.verifyPrivate(directory, directory: true)
        try CLIEditorExchange.write(registration, to: url(registration.session.id))
    }
    public func load(_ id: UUID) throws -> CLISessionRegistration {
        try CLIEditorExchange.verifyPrivate(directory, directory: true)
        let value = try CLIEditorExchange.read(CLISessionRegistration.self, from: url(id))
        guard value.version == CLIEditorProtocol.version, value.session.id == id else { throw CLIEditorFailure.invalidRequest }
        return value
    }
    public func all() -> [CLISessionRegistration] {
        guard (try? CLIEditorExchange.verifyPrivate(directory, directory: true)) != nil,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls.compactMap { url in
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            return try? load(id)
        }
    }
    public func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
    public func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
}

public struct CLIReadIntent: Equatable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let createdUptime: TimeInterval
    public let deadline: TimeInterval
    public init(sessionID: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        id = UUID(); self.sessionID = sessionID; createdUptime = now; deadline = now + 15
    }
    public func accepts(_ preflight: CLIEditorPreflight, now: TimeInterval) -> Bool {
        preflight.registration.session.id == sessionID && now <= deadline
            && preflight.createdUptime >= createdUptime && preflight.createdUptime <= now
    }
}

public struct CLIEditorPreflight: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let helperPID: Int32
    public let helperStartTimeMicros: UInt64
    public let registration: CLISessionRegistration
    public let createdUptime: TimeInterval
    public init(id: UUID = UUID(), helperPID: Int32 = getpid(), helperStartTimeMicros: UInt64,
                registration: CLISessionRegistration, createdUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        version = CLIEditorProtocol.version; self.id = id; self.helperPID = helperPID
        self.helperStartTimeMicros = helperStartTimeMicros; self.registration = registration
        self.createdUptime = createdUptime
    }
}

public struct CLIEditorReadPermission: Codable, Sendable {
    public let id: UUID
    public let intentID: UUID
    public init(id: UUID, intentID: UUID) { self.id = id; self.intentID = intentID }
}

public struct CLIEditorDraft: Codable, Sendable {
    public let id: UUID
    public let intentID: UUID
    public let source: String
    public init(id: UUID, intentID: UUID, source: String) { self.id = id; self.intentID = intentID; self.source = source }
}

public enum CLIHostAdapter {
    public static let claudeContextHeader = "# ─── Claude's last response (for reference; removed on save) ───\n"

    public static func deliveryText(_ text: String, for host: CLIHostKind) -> String {
        if host == .claude {
            var scalars = text.unicodeScalars
            if scalars.last == "\n", scalars.dropLast().last != "\n" { scalars.removeLast() }
            return String(scalars)
        }
        var scalars = text.unicodeScalars
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }
    public static func hasUnverifiedObjects(_ text: String) -> Bool {
        text.range(of: #"\[(?:Image|Pasted text|Attachment)\s*#?\d"#, options: .regularExpression) != nil
    }
    public static func isDraftFile(_ url: URL, registration: CLISessionRegistration,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard url.pathExtension == "md" else { return false }
        switch registration.session.kind {
        case .claude:
            let root = URL(fileURLWithPath: registration.claudeTempRoot)
                .appendingPathComponent("claude-\(geteuid())").resolvingSymlinksInPath().standardizedFileURL
            let name = url.deletingPathExtension().lastPathComponent
            return parent == root && name.hasPrefix("claude-prompt-")
                && UUID(uuidString: String(name.dropFirst("claude-prompt-".count))) != nil
        case .codex:
            let homes = [URL(fileURLWithPath: registration.codexHome), home.appendingPathComponent(".codex"),
                         URL(fileURLWithPath: registration.workingDirectory).appendingPathComponent(".codex")]
            return homes.contains { $0.resolvingSymlinksInPath().appendingPathComponent("editor").standardizedFileURL == parent }
                && url.lastPathComponent.hasPrefix(".tmp")
        }
    }
}

/// Holds the same descriptor across metadata admission and the bounded context check.
/// Construction never reads file content; read() is called only after App permission.
public final class CLIEditorFileAdmission {
    private let descriptor: Int32
    private let metadata: stat
    public let url: URL
    public init(url: URL) throws {
        self.url = url.standardizedFileURL
        descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CLIEditorFailure.invalidFile }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid() else { Darwin.close(descriptor); throw CLIEditorFailure.invalidFile }
        self.metadata = metadata
    }
    deinit { Darwin.close(descriptor) }
    public func read(host: CLIHostKind) throws -> CLIEditorFile {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw CLIEditorFailure.invalidFile }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        if host == .claude {
            let header = Data(CLIHostAdapter.claudeContextHeader.utf8)
            data = try handle.read(upToCount: header.count) ?? Data()
            guard data != header else { throw CLIEditorFailure.contextIncluded }
        }
        data.append(try handle.readToEnd() ?? Data())
        var current = stat()
        guard fstat(descriptor, &current) == 0, current.st_size == metadata.st_size,
              current.st_mtimespec.tv_sec == metadata.st_mtimespec.tv_sec,
              current.st_mtimespec.tv_nsec == metadata.st_mtimespec.tv_nsec else { throw CLIEditorFailure.changedFile }
        return try CLIEditorFile(url: url, data: data, metadata: metadata)
    }
}
