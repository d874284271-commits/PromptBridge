import AccessibilityContracts
import Darwin
import DraftCore
import Foundation

@main enum CLIIntegrationChecks {
    static func main() throws {
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("CLI integration ' fixture \(UUID())")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let app = fixture.appendingPathComponent("Prompt Bridge.app")
        let helper = app.appendingPathComponent("Contents/MacOS/promptbridge-editor")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write("#!/bin/sh\nprintf '%s\\n' \"$@\"\n", helper); chmod(helper.path, 0o700)
        let home = fixture.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let installer = CLIIntegrationInstaller(home: home, applicationURL: app)
        let zshrc = home.appendingPathComponent(".zshrc")
        try write("# original without final newline", zshrc)
        try check(!installer.inspect().installed, "initial status does not install")
        let before = try installer.snapshot()
        let installed = try installer.setEnabled([.codex], expected: before)
        try check(installed.installed && installed.enabledHosts == [.codex], "install selected host")
        try check(FileManager.default.destinationOfSymbolicLink(atPath: installer.helperURL.path) == helper.path, "stable helper resolves installed app")
        let script = installer.root.appendingPathComponent("integration.zsh")
        let wrapped = try shell("source \(quote(script.path)); codex 'draft with spaces' '--model' 'model x'")
        try check(wrapped.text == "--launch\ncodex\n--\ndraft with spaces\n--model\nmodel x\n", "wrapper preserves argv and quotes installed paths")
        let alias = try shell("alias codex='echo preserved-alias'; source \(quote(script.path)); alias codex")
        try check(alias.text.contains("preserved-alias"), "runtime preserves preexisting alias")
        let function = try shell("function codex { print preserved-function; }; source \(quote(script.path)); codex")
        try check(function.text == "preserved-function\n", "runtime preserves preexisting function")
        let runtimeBin = fixture.appendingPathComponent("runtime-bin")
        try FileManager.default.createDirectory(at: runtimeBin, withIntermediateDirectories: false)
        let realCLI = runtimeBin.appendingPathComponent("codex")
        try write("#!/bin/sh\nprintf 'original:%s\\n' \"$1\"\nexit 17\n", realCLI); chmod(realCLI.path, 0o700)
        try FileManager.default.removeItem(at: helper)
        let missing = try shell("export PATH=\(quote(runtimeBin.path)):/usr/bin:/bin; source \(quote(script.path)); codex 'a b'")
        try check(missing.text == "original:a b\n" && missing.exitCode == 17, "missing helper transparently falls back with exit code")
        try write("#!/bin/sh\nexit 0\n", helper); chmod(helper.path, 0o700)
        _ = try installer.setEnabled([.codex, .claude])
        try check(installer.inspect().enabledHosts == [.codex, .claude], "hosts independently enabled")
        _ = try installer.setEnabled([.claude])
        try check(!(try String(contentsOf: script, encoding: .utf8)).contains("function codex"), "disable one preserves the other")
        let current = try String(contentsOf: zshrc, encoding: .utf8)
        try write(current + "# later user line\n", zshrc)
        _ = try installer.setEnabled([])
        try check(try String(contentsOf: zshrc, encoding: .utf8) == "# original without final newline\n# later user line\n", "uninstall preserves user lines and their separation")
        try check(!FileManager.default.fileExists(atPath: script.path), "last host removes owned script")

        // Stale snapshots and edited managed files are rejected without overwriting user content.
        _ = try installer.setEnabled([.codex])
        let stale = try installer.snapshot()
        try write((try String(contentsOf: zshrc, encoding: .utf8)) + "# concurrent change\n", zshrc)
        try expectFailure { _ = try installer.setEnabled([.claude], expected: stale) }
        try write("# custom replacement\n", script)
        try expectFailure { _ = try installer.setEnabled([.claude]) }
        try check(try String(contentsOf: script, encoding: .utf8) == "# custom replacement\n", "repair does not overwrite edited script")
        try FileManager.default.removeItem(at: script)
        _ = try installer.setEnabled([.codex])
        try check(installer.inspect().installed, "repair restores missing owned script")
        let zshrcOwned = try String(contentsOf: zshrc, encoding: .utf8)
        try write(zshrcOwned.replacingOccurrences(of: "source ", with: "# changed source "), zshrc)
        try expectFailure { _ = try installer.setEnabled([]) }
        try write(zshrcOwned, zshrc)
        _ = try installer.setEnabled([])
        try check(CLIIntegrationInstaller.shellConflicts(in: "alias codex='x'\nfunction claude { x; }\n") == [.codex, .claude], "static shell conflict detection")

        try invocationChecks()
        try editorChecks(helper: helper)
        let detection = CLIExecutableProbe.detect(host: .codex, path: runtimeBin.path, runner: { url, argv, timeout in
            try check(url == realCLI && argv == ["--version"] && timeout == 2, "probe requests only bounded version")
            return CLIProcessOutput(exitCode: 0, text: "codex-cli 0.157.1\n")
        })
        try check(detection.version == "0.157.1", "version detection is diagnostic")
        let future = CLIExecutableProbe.detect(host: .codex, path: runtimeBin.path, runner: { _, _, _ in .init(exitCode: 0, text: "codex-cli 0.999.1") })
        try check(future.version == "0.999.1" && future.executable == realCLI && future.reason == nil, "future versions do not impose an admission reason")
        for response in [CLIProcessOutput(exitCode: 1, text: ""), CLIProcessOutput(exitCode: 0, text: "new version format"),
                         CLIProcessOutput(exitCode: -1, text: "", timedOut: true)] {
            let unknown = CLIExecutableProbe.detect(host: .codex, path: runtimeBin.path, runner: { _, _, _ in response })
            try check(unknown.version == nil && unknown.executable == realCLI, "failed version probe retains executable")
        }
        let timeout = try CLIExecutableProbe.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], 0.03)
        try check(timeout.timedOut, "process version probe timeout is bounded")
        print("CLI integration checks passed (fixture home; no real CLI session or settings changed)")
    }

    static func invocationChecks() throws {
        let accepted: [(CLIHostKind, [String])] = [(.codex, []), (.codex, ["--model", "x"]), (.codex, ["resume", "--last"]), (.codex, ["fork", "session"]), (.codex, ["please change this"]), (.codex, ["hello"]), (.codex, ["unknown"]), (.codex, ["--config", "x=y"]), (.codex, ["--future-option", "value"]), (.codex, ["--", "hello"]), (.claude, []), (.claude, ["-c"]), (.claude, ["-r", "session"]), (.claude, ["--model=x", "a prompt"]), (.claude, ["--settings", "x"]), (.claude, ["--unknown"])]
        for (host, arguments) in accepted {
            try check(CLIInvocationPolicy.isInteractive(host: host, arguments: arguments, isTTY: true), "interactive \(host): \(arguments)")
            try check(!CLIInvocationPolicy.isInteractive(host: host, arguments: arguments, isTTY: false), "non TTY never intercepted")
        }
        let rejected: [(CLIHostKind, [String])] = [(.codex, ["exec", "hello"]), (.codex, ["remote"]), (.codex, ["--help"]), (.codex, ["--version"]), (.claude, ["-p", "hello"]), (.claude, ["--print", "hello"]), (.claude, ["mcp"]), (.claude, ["--version"]) ]
        for (host, arguments) in rejected { try check(!CLIInvocationPolicy.isInteractive(host: host, arguments: arguments, isTTY: true), "explicit noninteractive passthrough \(arguments)") }
        try check(!CLIInvocationPolicy.isInteractive(host: .codex, arguments: ["--model", "x", "exec", "hello"], isTTY: true), "utility after global options bypasses bridge")
        try check(CLIInvocationPolicy.isInteractive(host: .codex, arguments: ["--model", "exec", "hello"], isTTY: true), "option value is not a utility subcommand")
        try check(CLIInvocationPolicy.isInteractive(host: .codex, arguments: ["--future-option", "exec", "hello"], isTTY: true), "unknown option values cannot disable connection")
        try check(CLIInvocationPolicy.isInteractive(host: .claude, arguments: ["--future-option", "mcp"], isTTY: true), "unknown Claude option values cannot disable connection")
        try check(!CLIInvocationPolicy.isInteractive(host: .codex, arguments: ["resume", "--help"], isTTY: true), "interactive subcommand help still bypasses bridge")
    }

    static func editorChecks(helper: URL) throws {
        try check(CLIEditorCommand.selected(visual: "", editor: "vi", host: .claude) == "vi", "Claude empty VISUAL falls back to EDITOR")
        try check(CLIEditorCommand.selected(visual: "", editor: "", host: .claude) == nil, "Claude empty editor variables use native default")
        try check(CLIEditorCommand.selected(visual: nil, editor: "", host: .claude) == nil, "Claude empty EDITOR is not a command")
        try check(CLIEditorCommand.selected(visual: "", editor: "vi", host: .codex) == "", "Codex retains its own empty VISUAL semantics")
        try check(CLIEditorCommand.arguments("'/Applications/My Editor.app/editor' --wait \"a b\"", host: .codex) == ["/Applications/My Editor.app/editor", "--wait", "a b"], "Codex shell_words quoted paths")
        try check(CLIEditorCommand.arguments("editor a\\ b '' \"c\\qd\" # comment\n--wait", host: .codex) == ["editor", "a b", "", "c\\qd", "--wait"], "Codex escapes comments and empty arguments")
        try check(CLIEditorCommand.arguments("editor $(echo hello)", host: .codex) == ["editor", "$(echo", "hello)"], "command substitution stays literal")
        try expectFailure { _ = try CLIEditorCommand.arguments("editor 'unclosed", host: .codex) }
        try check(CLIEditorCommand.arguments("editor  --wait 'a b'", host: .claude) == ["editor", "", "--wait", "'a", "b'"], "Claude literal-space splitting")
        try expectFailure { _ = try CLIEditorCommand.fallback("promptbridge-editor", host: .claude, helperURL: helper) }
        try expectFailure { _ = try CLIEditorCommand.fallback("env promptbridge-editor", host: .codex, helperURL: helper) }
        try check(CLIEditorCommand.fallback("vi", host: .codex, helperURL: helper) == ["vi"], "ordinary original editor retained")
    }

    static func shell(_ command: String) throws -> CLIProcessOutput { try CLIExecutableProbe.run(URL(fileURLWithPath: "/bin/zsh"), ["-f", "-c", command], 2) }
    static func quote(_ value: String) -> String { CLIIntegrationInstaller.quote(value) }
    static func write(_ text: String, _ url: URL) throws { try Data(text.utf8).write(to: url) }
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw NSError(domain: "CLIIntegrationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
    }
    static func expectFailure(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw NSError(domain: "CLIIntegrationChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "expected failure"])
    }
}
