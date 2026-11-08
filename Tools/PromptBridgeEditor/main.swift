import AppKit
import AccessibilityContracts
import Darwin
import DraftCore
import Foundation

nonisolated(unsafe) private var editorSignal: Int32 = 0

@main @MainActor enum PromptBridgeEditor {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("Usage: promptbridge-editor [--] <file> | --launch codex|claude -- [arguments]")
            return
        }
        if args.first == "--launch" {
            guard args.count >= 3, let kind = CLIHostKind(rawValue: args[1]), args[2] == "--" else { fail("Invalid launch arguments", code: 2) }
            await launch(kind: kind, arguments: Array(args.dropFirst(3)))
            return
        }
        let paths = args.first == "--" ? Array(args.dropFirst()) : args
        guard paths.count == 1, !paths[0].isEmpty, args.first == "--" || !paths[0].hasPrefix("-") else {
            fail("Usage: promptbridge-editor [--] <file>", code: 2)
        }
        signal(SIGINT) { editorSignal = $0 }; signal(SIGTERM) { editorSignal = $0 }
        var saved = false
        do {
            let env = ProcessInfo.processInfo.environment
            guard let raw = env["PROMPTBRIDGE_CLI_SESSION"], let id = UUID(uuidString: raw) else {
                throw CLIEditorFailureMessage(text: "此 CLI 尚未接入。请在 PromptBridge 设置中启用接入，并新开 CLI 会话。")
            }
            let registration = try CLISessionStore().load(id)
            let sourceURL = URL(fileURLWithPath: paths[0])
            guard let helper = CLIProcessSnapshot.inspect(pid: getpid()), registration.session.isCurrent,
                  helper.parentPID == registration.session.pid, helper.tty == registration.session.tty,
                  helper.processGroup == registration.session.processGroup else { throw CLIEditorFailure.invalidRequest }
            if !CLIHostAdapter.isDraftFile(sourceURL, registration: registration) {
                let command = CLIEditorCommand.selected(visual: registration.originalVisual,
                    editor: registration.originalEditor, host: registration.session.kind) ?? defaultEditor()
                let argv = try CLIEditorCommand.fallback(command, host: registration.session.kind,
                    helperURL: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath())
                execute(argv + [sourceURL.path])
            }
            let admission = try CLIEditorFileAdmission(url: sourceURL) // metadata only
            let appURL = try applicationURL()
            let request = CLIEditorPreflight(helperStartTimeMicros: helper.startTimeMicros, registration: registration)
            let requestURL = try CLIEditorExchange.create(request)
            defer { CLIEditorExchange.cleanup(requestURL) }
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            let application = try await NSWorkspace.shared.open([requestURL], withApplicationAt: appURL, configuration: configuration)
            var deadline = ContinuousClock.now.advanced(by: .seconds(15))
            var lease: UInt64 = 0
            let permissionURL = CLIEditorExchange.file("permission.json", for: requestURL)
            while !FileManager.default.fileExists(atPath: permissionURL.path) {
                try await waitTick(request: request, url: requestURL, app: application, deadline: &deadline, lease: &lease)
                if FileManager.default.fileExists(atPath: CLIEditorExchange.file("response.json", for: requestURL).path) {
                    throw CLIEditorFailure.cancelled
                }
            }
            let permission = try CLIEditorExchange.read(CLIEditorReadPermission.self, from: permissionURL)
            guard permission.id == request.id, registration.session.isCurrent else { throw CLIEditorFailure.invalidRequest }
            try checkSignal()
            let file: CLIEditorFile
            do { file = try admission.read(host: registration.session.kind) }
            catch {
                try? CLIEditorExchange.write(CLIEditorCompletion(id: request.id, status: .failed,
                    message: error.localizedDescription), to: CLIEditorExchange.file("completion.json", for: requestURL))
                await waitForFinished(requestURL, app: application)
                throw error
            }
            try CLIEditorExchange.write(CLIEditorDraft(id: request.id, intentID: permission.intentID, source: file.source),
                to: CLIEditorExchange.file("draft.json", for: requestURL))
            let responseURL = CLIEditorExchange.file("response.json", for: requestURL)
            while !FileManager.default.fileExists(atPath: responseURL.path) {
                try await waitTick(request: request, url: requestURL, app: application, deadline: &deadline, lease: &lease)
            }
            try checkSignal()
            let response = try CLIEditorExchange.read(CLIEditorResponse.self, from: responseURL)
            guard response.id == request.id else { throw CLIEditorFailure.invalidRequest }
            guard response.disposition == .accepted else {
                try? CLIEditorExchange.write(CLIEditorCompletion(id: request.id, status: .cancelled,
                    message: "已取消，CLI 原文未修改。终端可能提示编辑器已退出。"),
                    to: CLIEditorExchange.file("completion.json", for: requestURL))
                await waitForFinished(requestURL, app: application)
                throw CLIEditorFailure.cancelled
            }
            guard let text = response.text, !text.isEmpty,
                  text == CLIHostAdapter.deliveryText(text, for: registration.session.kind),
                  !CLIHostAdapter.hasUnverifiedObjects(file.source), !CLIHostAdapter.hasUnverifiedObjects(text) else {
                throw CLIEditorFailure.invalidRequest
            }
            try CLIEditorExchange.withCommitLock(for: requestURL) {
                try file.commit(text, shouldCancel: {
                    editorSignal != 0 || application.isTerminated || !registration.session.isCurrent
                        || !FileManager.default.fileExists(atPath: requestURL.path)
                        || FileManager.default.fileExists(atPath: CLIEditorExchange.file("aborted", for: requestURL).path)
                })
                saved = true
                // Once committed, every controlled exit must be successful so the CLI adopts it.
                try? CLIEditorExchange.write(CLIEditorCompletion(id: request.id, status: .saved,
                    message: "草稿已保存，正在返回 CLI。请确认输入框已显示新内容。"),
                    to: CLIEditorExchange.file("completion.json", for: requestURL))
            }
            await waitForFinished(requestURL, app: application)
        } catch {
            if saved { return }
            fail((error as? LocalizedError)?.errorDescription ?? "CLI 编辑交接失败；未写回。",
                code: editorSignal == 0 ? 1 : 128 + editorSignal)
        }
    }

    private static func waitTick(request: CLIEditorPreflight, url: URL, app: NSRunningApplication,
                                 deadline: inout ContinuousClock.Instant, lease: inout UInt64) async throws {
        try checkSignal()
        guard !app.isTerminated, FileManager.default.fileExists(atPath: url.path), request.registration.session.isCurrent else {
            throw CLIEditorFailure.invalidRequest
        }
        let leaseURL = CLIEditorExchange.file("received", for: url)
        if FileManager.default.fileExists(atPath: leaseURL.path) {
            let update = try CLIEditorExchange.read(CLIEditorLease.self, from: leaseURL)
            guard update.id == request.id else { throw CLIEditorFailure.invalidRequest }
            if update.sequence > lease { lease = update.sequence; deadline = .now.advanced(by: .seconds(15)) }
        }
        guard ContinuousClock.now < deadline else { throw CLIEditorFailureMessage(text: "CLI 编辑交接超时；未读取或写回新的内容。") }
        try await Task.sleep(for: .milliseconds(100))
    }
    private static func waitForFinished(_ url: URL, app: NSRunningApplication) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: CLIEditorExchange.file("finished", for: url).path),
              !app.isTerminated, ContinuousClock.now < deadline, editorSignal == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    private static func launch(kind: CLIHostKind, arguments: [String]) async {
        let env = ProcessInfo.processInfo.environment
        let searchPath = CLIExecutableProbe.searchPath(environment: env)
        guard let executable = CLIExecutableProbe.resolve(host: kind, path: searchPath) else {
            fail("未找到 \(kind.rawValue)", code: 127)
        }
        let native = executable.resolvingSymlinksInPath().path
        guard CLIInvocationPolicy.isInteractive(host: kind, arguments: arguments, isTTY: isatty(0) == 1 && isatty(1) == 1),
              let own = CLIProcessSnapshot.inspect(pid: getpid()), !own.tty.isEmpty else { execute([native] + arguments) }
        var registrationID: UUID?
        do {
            let app = try applicationURL()
            let nativeHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: native))
            let magic = try nativeHandle.read(upToCount: 4); try nativeHandle.close()
            guard let magic, [Data([0xcf,0xfa,0xed,0xfe]), Data([0xca,0xfe,0xba,0xbe]), Data([0xca,0xfe,0xba,0xbf])].contains(magic) else {
                execute([native] + arguments)
            }
            let probe = CLIExecutableProbe.detect(host: kind, path: searchPath)
            let version = probe.version ?? "unknown"
            let id = UUID(); registrationID = id
            let session = CLITerminalSession(id: id, kind: kind, version: version, pid: own.pid,
                startTimeMicros: own.startTimeMicros, processGroup: own.processGroup, tty: own.tty, executablePath: native)
            let home = FileManager.default.homeDirectoryForCurrentUser
            let registration = CLISessionRegistration(session: session, originalVisual: env["VISUAL"], originalEditor: env["EDITOR"],
                codexHome: env["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path,
                claudeTempRoot: env["CLAUDE_CODE_TMPDIR"] ?? "/tmp", workingDirectory: FileManager.default.currentDirectoryPath,
                automaticReadEligible: true)
            try CLISessionStore().save(registration)
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
            let bin = app.appendingPathComponent("Contents/MacOS").path
            guard FileManager.default.isExecutableFile(atPath: bin + "/promptbridge-editor") else { throw CLIEditorFailure.unavailable }
            setenv("PROMPTBRIDGE_CLI_SESSION", id.uuidString, 1)
            setenv("PATH", bin + ":" + searchPath, 1)
            setenv("VISUAL", "promptbridge-editor", 1); setenv("EDITOR", "promptbridge-editor", 1)
        } catch {
            if let registrationID { CLISessionStore().remove(registrationID) }
            // A failed bridge registration never prevents the original CLI from starting.
        }
        execute([native] + arguments)
    }
    private static func execute(_ arguments: [String]) -> Never {
        let pointers = arguments.map { strdup($0) } + [nil]
        pointers.withUnsafeBufferPointer { _ = execvp(arguments[0], $0.baseAddress!) }
        pointers.forEach { free($0) }
        fail("无法启动 \(arguments[0])", code: 127)
    }
    private static func defaultEditor() -> String {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for command in ["code", "vi", "nano"] {
            if let path = paths.map({ $0 + "/" + command }).first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return path }
        }
        return "/usr/bin/vi"
    }
    private static func applicationURL() throws -> URL {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = app.pathExtension == "app" ? app : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/PromptBridge.app")
        guard let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "local.promptbridge.prototype",
              info["PromptBridgeCLIEditorProtocol"] as? Int == CLIEditorProtocol.version else { throw CLIEditorFailure.unavailable }
        return url
    }
    private static func checkSignal() throws { if editorSignal != 0 { throw CLIEditorFailure.cancelled } }
    private static func fail(_ text: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data((text + "\n").utf8)); Darwin.exit(code)
    }
}
private struct CLIEditorFailureMessage: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
