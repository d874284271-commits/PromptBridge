import Darwin
import Foundation

public enum CLIEditorFailure: Error, LocalizedError {
    case invalidFile, changedFile, invalidRequest, cancelled, unavailable, contextIncluded

    public var errorDescription: String? {
        switch self {
        case .invalidFile: "CLI 草稿必须是可读取的普通 UTF-8 文件。"
        case .changedFile: "CLI 草稿文件已变化，未写回。结果仍可在浮窗复制。"
        case .invalidRequest: "CLI 编辑请求无效或已结束。"
        case .cancelled: "CLI 编辑已中断，未写回。"
        case .unavailable: "未找到支持 CLI 编辑器的 PromptBridge 应用。"
        case .contextIncluded: "Claude 外部编辑文件包含上一回复。请关闭 Show last response in external editor 后重新读取。"
        }
    }
}

public struct CLIEditorResponse: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case accepted, cancelled, rejected }
    public let id: UUID
    public let disposition: Disposition
    public let text: String?
    public let message: String?

    public init(id: UUID, disposition: Disposition, text: String? = nil, message: String? = nil) {
        self.id = id
        self.disposition = disposition
        self.text = text
        self.message = message
    }
}

public struct CLIEditorCompletion: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case saved, cancelled, failed }
    public let id: UUID
    public let status: Status
    public let message: String

    public init(id: UUID, status: Status, message: String) {
        self.id = id
        self.status = status
        self.message = message
    }
}

public struct CLIEditorLease: Codable, Sendable {
    public let id: UUID
    public let sequence: UInt64
    public init(id: UUID, sequence: UInt64) { self.id = id; self.sequence = sequence }
}

public struct CLIEditorFile {
    public let url: URL
    public let source: String
    private let original: Data
    private let device: dev_t
    private let inode: ino_t
    private let permissions: mode_t

    public init(url: URL) throws {
        let value = try Self.read(url)
        try self.init(url: url, data: value.data, metadata: value.metadata)
    }

    init(url: URL, data: Data, metadata: stat) throws {
        self.url = url.standardizedFileURL
        guard let text = String(data: data, encoding: .utf8) else { throw CLIEditorFailure.invalidFile }
        source = text
        original = data
        device = metadata.st_dev
        inode = metadata.st_ino
        permissions = metadata.st_mode & 0o777
    }

    public func commit(_ text: String, shouldCancel: () -> Bool = { false }) throws {
        let staged = url.deletingLastPathComponent().appendingPathComponent(".promptbridge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        let descriptor = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CLIEditorFailure.invalidFile }
        defer { Darwin.close(descriptor) }
        guard !shouldCancel() else { throw CLIEditorFailure.cancelled }
        try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).write(contentsOf: Data(text.utf8))
        guard chmod(staged.path, permissions) == 0 else { throw CLIEditorFailure.invalidFile }
        let current = try Self.read(url)
        guard current.metadata.st_dev == device, current.metadata.st_ino == inode,
              current.data == original else { throw CLIEditorFailure.changedFile }
        guard !shouldCancel() else { throw CLIEditorFailure.cancelled }
        guard rename(staged.path, url.path) == 0 else { throw CLIEditorFailure.invalidFile }
    }

    private static func read(_ url: URL) throws -> (data: Data, metadata: stat) {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw CLIEditorFailure.invalidFile }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw CLIEditorFailure.invalidFile
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return (try handle.readToEnd() ?? Data(), metadata)
    }
}

public enum CLIEditorExchange {
    public static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PromptBridgeCLI", isDirectory: true)
    }

    public static func create(_ request: CLIEditorPreflight) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try verifyPrivate(root, directory: true)
        let directory = root.appendingPathComponent(request.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("request.promptbridge-edit")
        do { try write(request, to: url) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        return url
    }

    public static func readPreflight(_ url: URL) throws -> CLIEditorPreflight {
        let directory = url.deletingLastPathComponent()
        guard url.lastPathComponent == "request.promptbridge-edit",
              directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw CLIEditorFailure.invalidRequest
        }
        try verifyPrivate(root, directory: true)
        try verifyPrivate(directory, directory: true)
        let request = try read(CLIEditorPreflight.self, from: url)
        guard request.version == CLIEditorProtocol.version, request.id.uuidString == directory.lastPathComponent,
              request.registration.version == CLIEditorProtocol.version,
              request.createdUptime.isFinite, request.createdUptime >= 0 else { throw CLIEditorFailure.invalidRequest }
        return request
    }

    public static func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try data.write(to: staged, options: .withoutOverwriting)
        guard chmod(staged.path, 0o600) == 0 else { throw CLIEditorFailure.invalidRequest }
        guard rename(staged.path, url.path) == 0 else { throw CLIEditorFailure.invalidRequest }
    }

    public static func read<Value: Decodable>(_ type: Value.Type, from url: URL) throws -> Value {
        try verifyPrivate(url, directory: false)
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    public static func file(_ name: String, for requestURL: URL) -> URL {
        requestURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    public static func cleanup(_ requestURL: URL) {
        let directory = requestURL.deletingLastPathComponent()
        guard directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil else { return }
        guard (try? verifyPrivate(directory, directory: true)) != nil else { return }
        guard chmod(directory.path, 0o700) == 0 else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    public static func withCommitLock<Value>(for requestURL: URL, nonBlocking: Bool = false,
                                             operation: () throws -> Value) throws -> Value? {
        let url = file("commit.lock", for: requestURL)
        let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CLIEditorFailure.invalidRequest }
        defer { Darwin.close(descriptor) }
        try verifyPrivate(url, directory: false)
        guard flock(descriptor, LOCK_EX | (nonBlocking ? LOCK_NB : 0)) == 0 else {
            if nonBlocking && errno == EWOULDBLOCK { return nil }
            throw CLIEditorFailure.invalidRequest
        }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    public static func verifyPrivate(_ url: URL, directory: Bool) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_uid == geteuid(),
              metadata.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              metadata.st_mode & 0o077 == 0 else { throw CLIEditorFailure.invalidRequest }
    }
}
