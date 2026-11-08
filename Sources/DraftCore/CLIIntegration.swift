import AccessibilityContracts
import Darwin
import Foundation

public enum CLIIntegrationError: Error, LocalizedError {
    case conflict(String), invalidEditor, recursiveEditor, missingHelper

    public var errorDescription: String? {
        switch self {
        case .conflict(let path): "CLI 接入文件已被修改或无法识别，未覆盖：\(path)"
        case .invalidEditor: "原编辑器命令无法安全解析，请检查 EDITOR / VISUAL。"
        case .recursiveEditor: "原编辑器仍指向 PromptBridge，无法转交此文件。"
        case .missingHelper: "应用内的 CLI 助手缺失，请先安装完整的 PromptBridge 应用。"
        }
    }
}

public struct CLIIntegrationStatus: Sendable {
    public let enabledHosts: Set<CLIHostKind>
    public let installed: Bool
    public let issues: [String]
    public let shellConflicts: Set<CLIHostKind>
}

/// A compare-before-write snapshot. Contains configuration bytes only, never prompts or CLI argv.
public struct CLIIntegrationSnapshot: Equatable, Sendable {
    fileprivate enum Entry: Equatable, Sendable { case absent, bytes(Data), symlink(String) }
    fileprivate let entries: [String: Entry]
}

/// Owns a marked zshrc block and a small installation under the supplied home.
/// Merely constructing or inspecting this object never writes configuration.
public struct CLIIntegrationInstaller {
    public let home: URL
    public let applicationURL: URL
    public let root: URL
    public var helperURL: URL { root.appendingPathComponent("bin/promptbridge-editor") }
    private var scriptURL: URL { root.appendingPathComponent("integration.zsh") }
    private var manifestURL: URL { root.appendingPathComponent("installation.json") }
    private var zshrcURL: URL { home.appendingPathComponent(".zshrc") }
    private var bundledHelper: URL { applicationURL.appendingPathComponent("Contents/MacOS/promptbridge-editor") }
    private static let begin = "# >>> PromptBridge CLI >>>"
    private static let end = "# <<< PromptBridge CLI <<<"

    private struct Manifest: Codable {
        let version: Int
        let enabledHosts: [CLIHostKind]
        let helperPath: String
        let insertedLeadingNewline: Bool
    }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, applicationURL: URL) {
        self.home = home.standardizedFileURL
        self.applicationURL = applicationURL.standardizedFileURL
        root = home.standardizedFileURL.appendingPathComponent(".local/share/promptbridge/cli", isDirectory: true)
    }

    public func snapshot() throws -> CLIIntegrationSnapshot {
        var entries: [String: CLIIntegrationSnapshot.Entry] = [:]
        for url in [zshrcURL, scriptURL, manifestURL, helperURL] { entries[url.path] = try Self.entry(url) }
        return CLIIntegrationSnapshot(entries: entries)
    }

    public func inspect() -> CLIIntegrationStatus {
        do {
            let state = try snapshot()
            let manifest = try readManifest(state)
            let hosts = Set(manifest?.enabledHosts ?? [])
            let zshrc = try text(state, zshrcURL) ?? ""
            var issues: [String] = []
            if let manifest {
                if try text(state, scriptURL) != script(hosts: hosts) { issues.append("接入脚本缺失或已修改") }
                if state.entries[helperURL.path] != .symlink(manifest.helperPath) { issues.append("CLI 助手链接缺失或已修改") }
                if !FileManager.default.isExecutableFile(atPath: manifest.helperPath) { issues.append("应用内的 CLI 助手不可用") }
                if !zshrc.contains(block) { issues.append(".zshrc 接入块缺失或已修改") }
                if manifest.helperPath != bundledHelper.path { issues.append("接入仍指向另一份应用，可修复为当前应用") }
            } else if state.entries[scriptURL.path] != .absent || state.entries[helperURL.path] != .absent || zshrc.contains(Self.begin) {
                issues.append("发现未完成或无法识别的 CLI 接入")
            }
            return CLIIntegrationStatus(enabledHosts: hosts, installed: manifest != nil && issues.isEmpty,
                                        issues: issues, shellConflicts: Self.shellConflicts(in: zshrc))
        } catch {
            return CLIIntegrationStatus(enabledHosts: [], installed: false, issues: [error.localizedDescription], shellConflicts: [])
        }
    }

    /// Enable, disable or repair the selected hosts. User edits outside the exact marked block survive.
    /// Passing a prior snapshot makes a UI's read/modify/write operation reject intervening changes.
    @discardableResult
    public func setEnabled(_ hosts: Set<CLIHostKind>, expected: CLIIntegrationSnapshot? = nil) throws -> CLIIntegrationStatus {
        let before = try snapshot()
        if let expected, expected != before { throw CLIIntegrationError.conflict(root.path) }
        let old = try readManifest(before)
        let oldHosts = Set(old?.enabledHosts ?? [])
        let originalZshrc = try text(before, zshrcURL) ?? ""
        var zshrc = originalZshrc
        let existingScript = try text(before, scriptURL)
        // Missing product files are repairable. Existing unknown content is never replaced.
        if let existingScript, existingScript != script(hosts: old == nil ? hosts : oldHosts) {
            throw CLIIntegrationError.conflict(scriptURL.path)
        }
        let link = before.entries[helperURL.path] ?? .absent
        if link != .absent && link != .symlink(old?.helperPath ?? bundledHelper.path) {
            throw CLIIntegrationError.conflict(helperURL.path)
        }
        if zshrc.contains(Self.begin) || zshrc.contains(Self.end) {
            guard zshrc.components(separatedBy: Self.begin).count == 2,
                  zshrc.components(separatedBy: Self.end).count == 2,
                  let range = zshrc.range(of: block) else { throw CLIIntegrationError.conflict(zshrcURL.path) }
            var start = range.lowerBound
            if old?.insertedLeadingNewline == true, range.upperBound == zshrc.endIndex, start > zshrc.startIndex,
               zshrc[zshrc.index(before: start)] == "\n" { start = zshrc.index(before: start) }
            zshrc.removeSubrange(start..<range.upperBound)
        }
        let needsNewline = !zshrc.isEmpty && !zshrc.hasSuffix("\n")
        if !hosts.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: bundledHelper.path) else { throw CLIIntegrationError.missingHelper }
            if needsNewline { zshrc += "\n" }
            zshrc += block
        }
        if hosts.isEmpty && old == nil && existingScript == nil && link == .absent && zshrc == originalZshrc { return inspect() }

        // Preflight every owned path before the first mutation; individual replacements compare again.
        guard try snapshot() == before else { throw CLIIntegrationError.conflict(root.path) }
        if !hosts.isEmpty {
            try FileManager.default.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try replace(Data(script(hosts: hosts).utf8), at: scriptURL, expected: before.entries[scriptURL.path] ?? .absent)
            try replaceLink(to: bundledHelper.path, expected: link)
        }
        if zshrc != originalZshrc {
            try replace(Data(zshrc.utf8), at: zshrcURL, expected: before.entries[zshrcURL.path] ?? .absent)
        }
        if hosts.isEmpty {
            try remove(scriptURL, expected: before.entries[scriptURL.path] ?? .absent)
            try remove(helperURL, expected: link)
            try remove(manifestURL, expected: before.entries[manifestURL.path] ?? .absent)
            // rmdir only removes empty product directories, preserving unrelated files.
            _ = rmdir(helperURL.deletingLastPathComponent().path)
            _ = rmdir(root.path)
        } else {
            let manifest = Manifest(version: 1, enabledHosts: hosts.sorted { $0.rawValue < $1.rawValue },
                                    helperPath: bundledHelper.path, insertedLeadingNewline: needsNewline)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try replace(encoder.encode(manifest), at: manifestURL, expected: before.entries[manifestURL.path] ?? .absent)
        }
        return inspect()
    }

    private var block: String {
        "\(Self.begin)\nif [[ -r \(Self.quote(scriptURL.path)) ]]; then\n  source \(Self.quote(scriptURL.path))\nfi\n\(Self.end)\n"
    }

    private func script(hosts: Set<CLIHostKind>) -> String {
        var result = "# PromptBridge CLI integration v1 — managed by PromptBridge.\n"
        for host in hosts.sorted(by: { $0.rawValue < $1.rawValue }) {
            let name = host.rawValue
            result += """
            if (( ! $+aliases[\(name)] && ! $+functions[\(name)] )); then
              function \(name) {
                if [[ -x \(Self.quote(helperURL.path)) ]]; then
                  \(Self.quote(helperURL.path)) --launch \(name) -- "$@"
                else
                  command \(name) "$@"
                fi
              }
            fi

            """
        }
        return result
    }

    public static func shellConflicts(in source: String) -> Set<CLIHostKind> {
        var result = Set<CLIHostKind>()
        for host in [CLIHostKind.codex, .claude] {
            let name = host.rawValue
            let pattern = "(?m)^\\s*(?:(?:alias|function)\\s+" + name + "(?:\\s|=|\\(|$)|" + name + "\\s*\\(\\s*\\))"
            if source.range(of: pattern, options: .regularExpression) != nil { result.insert(host) }
        }
        return result
    }

    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func readManifest(_ state: CLIIntegrationSnapshot) throws -> Manifest? {
        guard let entry = state.entries[manifestURL.path], entry != .absent else { return nil }
        guard case .bytes(let data) = entry, let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, !manifest.enabledHosts.isEmpty,
              Set(manifest.enabledHosts).count == manifest.enabledHosts.count,
              manifest.helperPath.hasSuffix(".app/Contents/MacOS/promptbridge-editor") else {
            throw CLIIntegrationError.conflict(manifestURL.path)
        }
        return manifest
    }

    private func text(_ snapshot: CLIIntegrationSnapshot, _ url: URL) throws -> String? {
        switch snapshot.entries[url.path] ?? .absent {
        case .absent: return nil
        case .bytes(let data):
            guard let string = String(data: data, encoding: .utf8) else { throw CLIIntegrationError.conflict(url.path) }
            return string
        case .symlink: throw CLIIntegrationError.conflict(url.path)
        }
    }

    private static func entry(_ url: URL) throws -> CLIIntegrationSnapshot.Entry {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return .absent }
            throw CLIIntegrationError.conflict(url.path)
        }
        if info.st_mode & S_IFMT == S_IFLNK { return .symlink(try FileManager.default.destinationOfSymbolicLink(atPath: url.path)) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw CLIIntegrationError.conflict(url.path) }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw CLIIntegrationError.conflict(url.path) }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw CLIIntegrationError.conflict(url.path)
        }
        return .bytes(try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data())
    }

    private func replace(_ data: Data, at url: URL, expected: CLIIntegrationSnapshot.Entry) throws {
        if expected == .bytes(data) { return }
        let stage = url.deletingLastPathComponent().appendingPathComponent(".promptbridge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: stage) }
        let fd = Darwin.open(stage.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CLIIntegrationError.conflict(url.path) }
        defer { Darwin.close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        guard try Self.entry(url) == expected else { throw CLIIntegrationError.conflict(url.path) }
        var old = stat()
        if lstat(url.path, &old) == 0 { guard fchmod(fd, old.st_mode & 0o777) == 0 else { throw CLIIntegrationError.conflict(url.path) } }
        guard rename(stage.path, url.path) == 0 else { throw CLIIntegrationError.conflict(url.path) }
    }

    private func replaceLink(to target: String, expected: CLIIntegrationSnapshot.Entry) throws {
        if expected == .symlink(target) { return }
        let stage = helperURL.deletingLastPathComponent().appendingPathComponent(".promptbridge-\(UUID())")
        defer { try? FileManager.default.removeItem(at: stage) }
        try FileManager.default.createSymbolicLink(atPath: stage.path, withDestinationPath: target)
        guard try Self.entry(helperURL) == expected, rename(stage.path, helperURL.path) == 0 else { throw CLIIntegrationError.conflict(helperURL.path) }
    }

    private func remove(_ url: URL, expected: CLIIntegrationSnapshot.Entry) throws {
        guard try Self.entry(url) == expected else { throw CLIIntegrationError.conflict(url.path) }
        if expected != .absent { try FileManager.default.removeItem(at: url) }
    }
}

public struct CLIProcessOutput: Sendable {
    public let exitCode: Int32
    public let text: String
    public let timedOut: Bool
    public init(exitCode: Int32, text: String, timedOut: Bool = false) {
        self.exitCode = exitCode; self.text = text; self.timedOut = timedOut
    }
}

public struct CLIExecutableDetection: Sendable {
    public let executable: URL?
    public let version: String?
    public let reason: String?
}

public enum CLIExecutableProbe {
    public static func searchPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        ([environment["PATH"] ?? "", home.appendingPathComponent(".local/bin").path,
          "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]).joined(separator: ":")
    }
    public typealias Runner = (URL, [String], TimeInterval) throws -> CLIProcessOutput

    public static func resolve(host: CLIHostKind, path: String) -> URL? {
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            // PATH's empty/relative segments refer to cwd and must retain ordinary exec lookup semantics.
            let url = URL(fileURLWithPath: directory.isEmpty ? "." : String(directory), isDirectory: true).appendingPathComponent(host.rawValue)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: url.path) { return url.standardizedFileURL }
        }
        return nil
    }

    public static func detect(host: CLIHostKind, path: String, runner: Runner? = nil) -> CLIExecutableDetection {
        guard let executable = resolve(host: host, path: path) else {
            return CLIExecutableDetection(executable: nil, version: nil, reason: "PATH 中未找到 \(host.rawValue)")
        }
        do {
            let result = try (runner ?? run)(executable, ["--version"], 2)
            guard !result.timedOut, result.exitCode == 0,
                  let range = result.text.range(of: "(?<![A-Za-z0-9.])[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?(?![A-Za-z0-9.])", options: .regularExpression) else {
                return CLIExecutableDetection(executable: executable, version: nil, reason: "版本未知；仍可尝试接入")
            }
            let version = String(result.text[range])
            return CLIExecutableDetection(executable: executable, version: version, reason: nil)
        } catch { return CLIExecutableDetection(executable: executable, version: nil, reason: "版本未知；仍可尝试接入") }
    }

    /// Runs only the caller's explicit executable/argv, with bounded output and wall time. No shell.
    public static func run(_ executable: URL, _ arguments: [String], _ timeout: TimeInterval) throws -> CLIProcessOutput {
        let process = Process(); let pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let fd = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        try process.run()
        try? pipe.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        func drain() {
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { return }
                if data.count < 8192 { data.append(contentsOf: buffer.prefix(min(count, 8192 - data.count))) }
                if ProcessInfo.processInfo.systemUptime >= deadline { return }
            }
        }
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { drain(); Thread.sleep(forTimeInterval: 0.01) }
        let timedOut = process.isRunning
        if timedOut { process.terminate(); if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) } }
        process.waitUntilExit()
        drain()
        try? pipe.fileHandleForReading.close()
        return CLIProcessOutput(exitCode: process.terminationStatus, text: String(decoding: data, as: UTF8.self), timedOut: timedOut)
    }
}

public enum CLIInvocationPolicy {
    /// TTY invocations may connect; only explicit utility/noninteractive calls bypass the bridge.
    public static func isInteractive(host: CLIHostKind, arguments: [String], isTTY: Bool) -> Bool {
        guard isTTY else { return false }
        let utilities: Set<String> = host == .codex
            ? ["agents", "exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "remote-control", "remote", "app", "completion", "update", "doctor", "sandbox", "debug", "apply", "a", "queue", "archive", "delete", "migrate-rollouts", "unarchive", "cloud", "exec-server", "features", "help"]
            : ["auth", "mcp", "plugin", "plugins", "install", "update", "upgrade", "doctor", "setup-token", "help"]
        let passthrough: Set<String> = host == .claude
            ? ["--help", "-h", "--version", "-v", "-p", "--print"]
            : ["--help", "-h", "--version", "-V"]
        if arguments.prefix(while: { $0 != "--" }).contains(where: {
            passthrough.contains($0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0)
        }) { return false }
        // Known value options are skipped only to distinguish a subcommand from an option value.
        // Unknown options still permit connection and the original CLI validates all argv.
        let valueOptions: Set<String> = host == .codex
            ? ["--model", "-m", "--cd", "-C", "--sandbox", "-s", "--ask-for-approval", "-a", "--config", "-c", "--enable", "--disable", "--profile", "-p", "--image", "-i", "--add-dir", "--local-provider", "--remote", "--remote-auth-token-env"]
            : ["--model", "--permission-mode", "--effort", "--settings", "--append-system-prompt", "--system-prompt"]
        let switches: Set<String> = host == .codex
            ? ["--no-alt-screen", "--full-auto", "--search", "--last", "--all", "--oss", "--approve-for-me", "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-hook-trust", "--worktree", "--strict-config", "--no-daemon"]
            : ["--continue", "-c", "--verbose", "--dangerously-skip-permissions"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { return true }
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if passthrough.contains(option) { return false }
            if valueOptions.contains(argument) { index += 2; continue }
            if argument.hasPrefix("-") {
                if switches.contains(argument) || argument.contains("=") { index += 1; continue }
                // An unknown option may consume the next token. Do not misclassify its value as a utility.
                return true
            }
            return !utilities.contains(argument)
        }
        return true
    }
}

public enum CLIEditorCommand {
    public static func selected(visual: String?, editor: String?, host: CLIHostKind) -> String? {
        if host == .claude { return [visual, editor].compactMap { $0 }.first { !$0.isEmpty } }
        return visual ?? editor
    }
    /// Codex uses shell_words; Claude 2.1.283 splits on the literal ASCII space.
    public static func arguments(_ command: String, host: CLIHostKind) throws -> [String] {
        if host == .claude {
            let parts = command.components(separatedBy: " ")
            guard let first = parts.first, !first.isEmpty, parts.allSatisfy({ !$0.contains("\0") }) else { throw CLIIntegrationError.invalidEditor }
            return parts
        }
        enum Quote { case none, single, double }
        var quote = Quote.none, result: [String] = [], word = "", started = false
        let chars = Array(command); var index = 0
        while index < chars.count {
            let char = chars[index]
            guard char != "\0" else { throw CLIIntegrationError.invalidEditor }
            switch quote {
            case .single:
                if char == "'" { quote = .none } else { word.append(char) }
            case .double:
                if char == "\"" { quote = .none }
                else if char == "\\" {
                    guard index + 1 < chars.count else { throw CLIIntegrationError.invalidEditor }
                    let next = chars[index + 1]
                    if ["$", "`", "\"", "\\", "\n"].contains(next) {
                        index += 1; if next != "\n" { word.append(next) }
                    } else { word.append(char) }
                } else { word.append(char) }
            case .none:
                if char == "'" { quote = .single; started = true }
                else if char == "\"" { quote = .double; started = true }
                else if char == "\\" {
                    guard index + 1 < chars.count else { throw CLIIntegrationError.invalidEditor }
                    index += 1
                    if chars[index] != "\n" { word.append(chars[index]); started = true }
                } else if char == " " || char == "\t" || char == "\n" {
                    if started { result.append(word); word = ""; started = false }
                } else if char == "#" && !started {
                    while index < chars.count && chars[index] != "\n" { index += 1 }
                    continue
                } else { word.append(char); started = true }
            }
            index += 1
        }
        guard quote == .none else { throw CLIIntegrationError.invalidEditor }
        if started { result.append(word) }
        guard let first = result.first, !first.isEmpty else { throw CLIIntegrationError.invalidEditor }
        return result
    }

    public static func fallback(_ command: String?, host: CLIHostKind, helperURL: URL) throws -> [String] {
        guard let command, !command.isEmpty else { throw CLIIntegrationError.invalidEditor }
        let words = try arguments(command, host: host)
        // Also reject env/wrapper invocations that explicitly name this helper.
        for word in words {
            if URL(fileURLWithPath: word).lastPathComponent == "promptbridge-editor" ||
                (word.hasPrefix("/") && URL(fileURLWithPath: word).resolvingSymlinksInPath() == helperURL.resolvingSymlinksInPath()) {
                throw CLIIntegrationError.recursiveEditor
            }
        }
        let program = words[0]
        let shellNames: Set<String> = ["sh", "bash", "zsh", "fish", "csh", "tcsh", "dash", "ksh"]
        if shellNames.contains(URL(fileURLWithPath: program).lastPathComponent), words.dropFirst().contains(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ic" }) {
            // An opaque shell program can call the installed wrapper again; it is not an editor argv.
            throw CLIIntegrationError.invalidEditor
        }
        let resolvedProgram: URL?
        if program.contains("/") { resolvedProgram = URL(fileURLWithPath: program) }
        else {
            resolvedProgram = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin").components(separatedBy: ":")
                .map { URL(fileURLWithPath: $0.isEmpty ? "." : $0).appendingPathComponent(program) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        if resolvedProgram?.resolvingSymlinksInPath() == helperURL.resolvingSymlinksInPath() { throw CLIIntegrationError.recursiveEditor }
        return words
    }
}
