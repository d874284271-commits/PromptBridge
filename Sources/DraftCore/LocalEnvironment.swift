import Foundation
import Darwin

public enum EnvironmentFailure: Error, LocalizedError {
    case unreadable, malformed, insecurePermissions, wrongDestination
    public var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取本地环境文件。"
        case .malformed: "本地环境文件格式无效，请按 .env.example 填写。"
        case .insecurePermissions: "本地环境文件权限过宽，请将权限设为 600。"
        case .wrongDestination: "DEEPSEEK 环境配置只允许 DeepSeek 官方 HTTPS 地址。"
        }
    }
}

public enum LocalEnvironment {
    private static let keys: Set<String> = ["DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DEEPSEEK_MODEL"]

    /// Plain data only: never evaluates shell expressions or interpolates other variables.
    public static func parse(_ contents: String) throws -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in contents.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let separator = line.firstIndex(of: "=") else { throw EnvironmentFailure.malformed }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard keys.contains(key) else { continue }
            guard values[key] == nil else { throw EnvironmentFailure.malformed }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                guard value.count >= 2, value.last == quote else { throw EnvironmentFailure.malformed }
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    public static func configuration(fileURL: URL?, environment: [String: String]) throws -> ProviderConfiguration? {
        let values: [String: String]
        // A process key is never combined with a destination from a different file.
        if environment["DEEPSEEK_API_KEY"] != nil {
            values = environment
        } else if let fileURL {
            guard let contents = try readFile(fileURL) else { return nil }
            values = try parse(contents)
        } else { return nil }
        guard let key = values["DEEPSEEK_API_KEY"], !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let configuration = ProviderConfiguration(format: .chatCompletions,
            baseURL: values["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com",
            model: values["DEEPSEEK_MODEL"] ?? "deepseek-flash", apiKey: key)
        let url = try configuration.endpointURL()
        guard url.scheme == "https", url.host == "api.deepseek.com", url.port == nil || url.port == 443,
              ["/chat/completions", "/v1/chat/completions"].contains(url.path) else {
            throw EnvironmentFailure.wrongDestination
        }
        return configuration
    }

    private static func readFile(_ url: URL) throws -> String? {
        // fstat checks permissions without asking Foundation to enumerate extended attributes.
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw EnvironmentFailure.unreadable
        }
        defer { Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw EnvironmentFailure.unreadable
        }
        guard metadata.st_mode & 0o077 == 0 else { throw EnvironmentFailure.insecurePermissions }
        guard metadata.st_size >= 0, metadata.st_size <= 16_384 else { throw EnvironmentFailure.malformed }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw EnvironmentFailure.unreadable
            }
            if count == 0 { break }
            guard data.count + count <= 16_384 else { throw EnvironmentFailure.malformed }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard let result = String(data: data, encoding: .utf8) else { throw EnvironmentFailure.malformed }
        return result
    }
}
