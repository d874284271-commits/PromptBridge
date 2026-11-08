import Darwin
import Foundation

public enum ProviderLibraryError: Error, Equatable, Sendable, LocalizedError {
    case unsupportedVersion(Int)
    case emptyName
    case duplicateID
    case missingActivePreset
    case invalidConfiguration
    case unreadable
    case malformed
    case insecurePermissions
    case notRegularFile
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "模型服务预设文件版本不受支持，请升级应用或重新保存。"
        case .emptyName: "模型服务预设名称不能为空。"
        case .duplicateID: "模型服务预设列表包含重复 ID，无法保存。"
        case .missingActivePreset: "当前模型服务预设不存在，无法保存。"
        case .invalidConfiguration: "模型服务预设配置无效，请检查消息格式、基础地址、API Key 和模型设置。"
        case .unreadable: "无法读取模型服务预设文件，请检查文件权限后重试。"
        case .malformed: "模型服务预设文件格式无效，请修正文件后点击“重新读取配置”。"
        case .insecurePermissions: "模型服务预设文件权限过宽，请将权限设为 600。"
        case .notRegularFile: "模型服务预设路径不是普通文件。"
        case .writeFailed: "模型服务预设保存失败，请检查磁盘空间和文件权限。"
        }
    }
}

public struct ProviderPreset: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var configuration: ProviderConfiguration

    public init(id: UUID = UUID(), name: String, configuration: ProviderConfiguration) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }
}

public struct ProviderLibrary: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var activePresetID: UUID?
    public var presets: [ProviderPreset]

    public init(presets: [ProviderPreset] = [], activePresetID: UUID? = nil) {
        self.activePresetID = activePresetID
        self.presets = presets
    }

    public var activeConfiguration: ProviderConfiguration? {
        guard let activePresetID else { return nil }
        return presets.first(where: { $0.id == activePresetID })?.configuration
    }

    public func validate() throws {
        guard version == 1 else { throw ProviderLibraryError.unsupportedVersion(version) }

        var ids = Set<UUID>()
        for preset in presets {
            guard !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProviderLibraryError.emptyName
            }
            guard ids.insert(preset.id).inserted else { throw ProviderLibraryError.duplicateID }

            // Inactive entries may intentionally omit a model while the user
            // browses a provider's model list. Validate the connection and
            // models path without requiring an endpoint model.
            do { _ = try preset.configuration.connectionURL(appending: preset.configuration.modelsPath) }
            catch { throw ProviderLibraryError.invalidConfiguration }
        }

        guard let activePresetID else { return }
        guard let activePreset = presets.first(where: { $0.id == activePresetID }) else {
            throw ProviderLibraryError.missingActivePreset
        }
        do { _ = try activePreset.configuration.endpointURL() }
        catch { throw ProviderLibraryError.invalidConfiguration }
    }
}

public struct ProviderLibraryStore: Sendable {
    public let fileURL: URL
    private static let maximumBytes = 1_048_576

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> ProviderLibrary? {
        let data = try readData()
        guard let data else { return nil }
        let library: ProviderLibrary
        do {
            library = try JSONDecoder().decode(ProviderLibrary.self, from: data)
        } catch {
            throw ProviderLibraryError.malformed
        }
        try library.validate()
        return library
    }

    public func save(_ library: ProviderLibrary) throws {
        try library.validate()
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(library)
        } catch {
            throw ProviderLibraryError.writeFailed
        }
        guard data.count <= Self.maximumBytes else { throw ProviderLibraryError.writeFailed }

        let parent = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw ProviderLibraryError.writeFailed
        }

        try rejectExistingSymlinkOrNonFile()

        let temporary = parent.appendingPathComponent("." + fileURL.lastPathComponent + ".tmp.XXXXXX")
        var template = Array(temporary.path.utf8) + [0]
        let descriptor = template.withUnsafeMutableBufferPointer { buffer -> Int32 in
            Darwin.mkstemp(buffer.baseAddress)
        }
        guard descriptor >= 0 else { throw ProviderLibraryError.writeFailed }
        let temporaryPath = String(decoding: template.dropLast(), as: UTF8.self)
        var openDescriptor = descriptor
        defer {
            if openDescriptor >= 0 { Darwin.close(openDescriptor) }
            _ = Darwin.unlink(temporaryPath)
        }

        guard Darwin.fchmod(openDescriptor, 0o600) == 0 else {
            throw ProviderLibraryError.writeFailed
        }
        do {
            try writeAll(data, to: openDescriptor)
        } catch {
            throw ProviderLibraryError.writeFailed
        }
        guard Darwin.fsync(openDescriptor) == 0 else { throw ProviderLibraryError.writeFailed }
        let closed = Darwin.close(openDescriptor)
        openDescriptor = -1
        guard closed == 0 else { throw ProviderLibraryError.writeFailed }

        guard Darwin.rename(temporaryPath, fileURL.path) == 0 else {
            throw ProviderLibraryError.writeFailed
        }
    }

    private func readData() throws -> Data? {
        let descriptor = Darwin.open(fileURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw ProviderLibraryError.notRegularFile }
            throw ProviderLibraryError.unreadable
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw ProviderLibraryError.unreadable }
        guard metadata.st_mode & S_IFMT == S_IFREG else { throw ProviderLibraryError.notRegularFile }
        guard metadata.st_mode & 0o077 == 0 else { throw ProviderLibraryError.insecurePermissions }
        guard metadata.st_size >= 0, metadata.st_size <= off_t(Self.maximumBytes) else {
            throw ProviderLibraryError.malformed
        }

        var data = Data(capacity: Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ProviderLibraryError.unreadable
            }
            if count == 0 { break }
            guard data.count + count <= Self.maximumBytes else { throw ProviderLibraryError.malformed }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func rejectExistingSymlinkOrNonFile() throws {
        var metadata = stat()
        if lstat(fileURL.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG else { throw ProviderLibraryError.notRegularFile }
            return
        }
        guard errno == ENOENT else { throw ProviderLibraryError.writeFailed }
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return -1 }
                return Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw ProviderLibraryError.writeFailed }
            offset += written
        }
    }
}
