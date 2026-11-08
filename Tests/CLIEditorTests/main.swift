import AccessibilityContracts
import Darwin
import DraftCore
import Foundation

@main enum CLIEditorChecks {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CLI checks \(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("草稿 with spaces.txt")
        let original = "请修改这个文件\n```swift\nprint(\"你好\")\n```\n/路径 with spaces\n"
        try Data(original.utf8).write(to: url)
        try CLIEditorFile(url: url).commit("translated\n")
        try check(String(contentsOf: url, encoding: .utf8) == "translated\n", "confirmed save")
        try Data(original.utf8).write(to: url)
        let cancelled = try CLIEditorFile(url: url)
        try expectFailure { try cancelled.commit("changed", shouldCancel: { true }) }
        try check(String(contentsOf: url, encoding: .utf8) == original, "cancel preserves exact bytes")
        chmod(url.path, 0o600)
        let privateFile = try CLIEditorFile(url: url)
        var privateStage = false
        var stagingChecks = 0
        let priorMask = umask(0o022)
        defer { umask(priorMask) }
        try expectFailure {
            try privateFile.commit("sensitive result", shouldCancel: {
                stagingChecks += 1
                if let staged = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                    .first(where: { $0.lastPathComponent.hasPrefix(".promptbridge-") }),
                   let attributes = try? FileManager.default.attributesOfItem(atPath: staged.path),
                   let permissions = attributes[.posixPermissions] as? NSNumber,
                   let size = attributes[.size] as? NSNumber, size.intValue == 0 {
                    privateStage = permissions.intValue == 0o600
                }
                return stagingChecks > 1
            })
        }
        try check(privateStage, "private 0600 draft never exposes staged result with umask 022")
        let changed = try CLIEditorFile(url: url)
        try Data("external edit".utf8).write(to: url)
        try expectFailure { try changed.commit("changed") }
        try check(String(contentsOf: url, encoding: .utf8) == "external edit", "content conflict preserves external edit")
        let replaced = try CLIEditorFile(url: url)
        try Data("external edit".utf8).write(to: url, options: .atomic)
        try expectFailure { try replaced.commit("changed") }
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        try expectFailure { _ = try CLIEditorFile(url: link) }
        try expectFailure { _ = try CLIEditorFile(url: directory) }
        try Data([0xff]).write(to: url)
        try expectFailure { _ = try CLIEditorFile(url: url) }
        let request = CLIEditorPreflight(helperPID: 321, helperStartTimeMicros: 123_456,
            registration: registration(kind: .codex, directory: directory), createdUptime: 100)
        let requestURL = try CLIEditorExchange.create(request)
        defer { CLIEditorExchange.cleanup(requestURL) }
        try check(CLIEditorExchange.readPreflight(requestURL) == request, "v2 private metadata preflight roundtrip")
        let locked = try CLIEditorExchange.withCommitLock(for: requestURL) {
            let competing = try CLIEditorExchange.withCommitLock(for: requestURL, nonBlocking: true) { true }
            try check(competing == nil, "termination cannot pass an in-flight commit lock")
            return true
        }
        try check(locked == true, "commit lock released after operation")
        _ = try CLIEditorExchange.withCommitLock(for: requestURL) {
            try CLIEditorExchange.write(request.id, to: CLIEditorExchange.file("aborted", for: requestURL))
        }
        try Data(original.utf8).write(to: url)
        let late = try CLIEditorFile(url: url)
        try expectFailure {
            _ = try CLIEditorExchange.withCommitLock(for: requestURL) {
                try late.commit("late result", shouldCancel: {
                    FileManager.default.fileExists(atPath: CLIEditorExchange.file("aborted", for: requestURL).path)
                })
            }
        }
        try check(String(contentsOf: url, encoding: .utf8) == original, "ended request cannot commit a late result")
        try CLIEditorExchange.write(CLIEditorResponse(id: request.id, disposition: .cancelled),
            to: CLIEditorExchange.file("response.json", for: requestURL))
        try check(CLIEditorExchange.read(CLIEditorResponse.self,
            from: CLIEditorExchange.file("response.json", for: requestURL)).disposition == .cancelled, "cancel exchange")
        chmod(requestURL.path, 0o644)
        try expectFailure { _ = try CLIEditorExchange.readPreflight(requestURL) }
        CLIEditorExchange.cleanup(requestURL)
        try check(!FileManager.default.fileExists(atPath: requestURL.deletingLastPathComponent().path), "exchange cleanup")
        try check(FileManager.default.contentsOfDirectory(atPath: directory.path).allSatisfy { !$0.hasPrefix(".promptbridge-") }, "staged file cleanup")
        try admissionChecks(directory: directory)
        try adapterChecks(directory: directory)
        try normalizationChecks()
        try intentChecks(directory: directory)
        try preflightChecks(directory: directory)
        print("CLI editor checks passed: v2 metadata admission, context boundary, host paths, normalization, intent correlation, save/cancel/conflicts, private exchange and cleanup; synthetic files only")
    }

    static func registration(kind: CLIHostKind, directory: URL, id: UUID = UUID()) -> CLISessionRegistration {
        let session = CLITerminalSession(id: id, kind: kind, version: kind == .codex ? "0.157.1" : "2.1.283",
            pid: 123, startTimeMicros: 55, processGroup: 123, tty: "/dev/ttys001", executablePath: "/fixture/" + kind.rawValue)
        return CLISessionRegistration(session: session, originalVisual: "fixture-editor --wait", originalEditor: "vi",
            codexHome: directory.appendingPathComponent("Codex Home").path,
            claudeTempRoot: directory.appendingPathComponent("private temp").path,
            workingDirectory: directory.appendingPathComponent("Project").path, createdUptime: 90)
    }

    static func admissionChecks(directory: URL) throws {
        let invalid = directory.appendingPathComponent("metadata-only.md")
        try Data([0xff, 0xfe, 0xfd]).write(to: invalid)
        let metadataOnly = try CLIEditorFileAdmission(url: invalid)
        try check(metadataOnly.url == invalid.standardizedFileURL, "metadata admission succeeds without UTF-8 decoding")
        try expectFailure(.invalidFile, "only admitted read decodes UTF-8") { _ = try metadataOnly.read(host: .codex) }
        let link = directory.appendingPathComponent("metadata-symlink.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: invalid)
        try expectFailure(.invalidFile, "metadata admission rejects symlink") { _ = try CLIEditorFileAdmission(url: link) }
        try expectFailure(.invalidFile, "metadata admission rejects directory") { _ = try CLIEditorFileAdmission(url: directory) }

        let context = directory.appendingPathComponent("context.md")
        var data = Data(CLIHostAdapter.claudeContextHeader.utf8)
        data.append(Data([0xff, 0xfe]))
        try data.write(to: context)
        let contextual = try CLIEditorFileAdmission(url: context)
        try expectFailure(.contextIncluded, "fixed Claude header rejects before decoding remaining bytes") { _ = try contextual.read(host: .claude) }
        let ordinary = ["# 普通 Markdown 标题\n请翻译这段文字\n", "# ─── 用户自己的标题 ───\n正文", "#", "", "正文\n" + CLIHostAdapter.claudeContextHeader]
        for (index, text) in ordinary.enumerated() {
            let file = directory.appendingPathComponent("ordinary-\(index).md")
            try Data(text.utf8).write(to: file)
            let admitted = try CLIEditorFileAdmission(url: file)
            try check(admitted.read(host: .claude).source == text, "ordinary # text remains unchanged (\(index))")
        }
        let codex = directory.appendingPathComponent("codex-with-heading.md")
        try Data(CLIHostAdapter.claudeContextHeader.utf8).write(to: codex)
        try check(CLIEditorFileAdmission(url: codex).read(host: .codex).source == CLIHostAdapter.claudeContextHeader,
            "Claude context sentinel does not reject Codex text")
    }

    static func adapterChecks(directory: URL) throws {
        let home = directory.appendingPathComponent("fixture home")
        let codex = registration(kind: .codex, directory: directory)
        let claude = registration(kind: .claude, directory: directory)
        let codexRoots = [URL(fileURLWithPath: codex.codexHome), home.appendingPathComponent(".codex"),
            URL(fileURLWithPath: codex.workingDirectory).appendingPathComponent(".codex")]
        for (index, root) in codexRoots.enumerated() {
            let editor = root.appendingPathComponent("editor")
            try FileManager.default.createDirectory(at: editor, withIntermediateDirectories: true)
            let valid = editor.appendingPathComponent(".tmpA1b2c3.md")
            try check(CLIHostAdapter.isDraftFile(valid, registration: codex, home: home), "Codex candidate home accepted (\(index))")
            try check(!CLIHostAdapter.isDraftFile(editor.appendingPathComponent("prompt.md"), registration: codex, home: home),
                "Codex non-temporary prefix rejected (\(index))")
            try check(!CLIHostAdapter.isDraftFile(editor.appendingPathComponent(".tmpA1b2c3.txt"), registration: codex, home: home),
                "Codex non-Markdown suffix rejected (\(index))")
            try check(!CLIHostAdapter.isDraftFile(root.appendingPathComponent("editor-other/.tmpA1b2c3.md"), registration: codex, home: home),
                "Codex sibling directory rejected (\(index))")
            try check(!CLIHostAdapter.isDraftFile(editor.appendingPathComponent("nested/.tmpA1b2c3.md"), registration: codex, home: home),
                "Codex nested directory rejected (\(index))")
        }
        let claudeRoot = URL(fileURLWithPath: claude.claudeTempRoot).appendingPathComponent("claude-\(geteuid())")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let name = "claude-prompt-\(UUID()).md"
        try check(CLIHostAdapter.isDraftFile(claudeRoot.appendingPathComponent(name), registration: claude, home: home), "Claude private user temp and UUID filename accepted")
        for wrongName in ["prompt-\(UUID()).md", "claude-prompt-invalid.md", "claude-prompt-.md", "claude-prompt-\(UUID()).txt"] {
            try check(!CLIHostAdapter.isDraftFile(claudeRoot.appendingPathComponent(wrongName), registration: claude, home: home),
                "Claude invalid filename rejected: \(wrongName)")
        }
        for wrongDirectory in [claudeRoot.deletingLastPathComponent(), claudeRoot.appendingPathComponent("nested"),
                               claudeRoot.deletingLastPathComponent().appendingPathComponent("claude-\(geteuid() + 1)")] {
            try check(!CLIHostAdapter.isDraftFile(wrongDirectory.appendingPathComponent(name), registration: claude, home: home),
                "Claude wrong directory rejected: \(wrongDirectory.lastPathComponent)")
        }
        try check(!CLIHostAdapter.isDraftFile(claudeRoot.appendingPathComponent(name), registration: codex, home: home), "host rules do not cross-admit drafts")
        try check(CLIHostAdapter.hasUnverifiedObjects("正文 [Image #1]"), "image marker blocks unverified automatic refill")
        try check(CLIHostAdapter.hasUnverifiedObjects("[Pasted text #2]"), "folded paste marker remains unverified")
        try check(!CLIHostAdapter.hasUnverifiedObjects("普通 [链接](https://example.com) # 标题"), "ordinary Markdown does not imply attached objects")
    }

    static func normalizationChecks() throws {
        // Confirmed Claude behavior removes LF only when there is exactly one
        // final LF. Double LF is retained; CRLF removes LF but preserves CR.
        let fixtures: [(String, String, String, String)] = [
            ("no newline", "正文", "正文", "正文"),
            ("single LF", "正文\n", "正文", "正文"),
            ("double LF", "正文\n\n", "正文", "正文\n\n"),
            ("CRLF", "正文\r\n", "正文", "正文\r"),
            ("trailing spaces", "正文 \t", "正文", "正文 \t"),
            ("spaces before LF", "正文 \t\n", "正文", "正文 \t"),
            ("Unicode NEL", "正文\u{0085}", "正文", "正文\u{0085}"),
            ("Unicode FEFF", "正文\u{FEFF}", "正文\u{FEFF}", "正文\u{FEFF}"),
            ("FEFF then LF", "正文\u{FEFF}\n", "正文\u{FEFF}", "正文\u{FEFF}"),
            ("Unicode NBSP and line separators", "正文\u{00A0}\u{2028}\u{2029}", "正文", "正文\u{00A0}\u{2028}\u{2029}"),
            ("empty", "", "", ""),
            ("only LF", "\n", "", ""),
            ("only whitespace", " \t\r\n", "", " \t\r")
        ]
        for (name, input, codex, claude) in fixtures {
            for (host, expected) in [(CLIHostKind.codex, codex), (CLIHostKind.claude, claude)] {
                let delivered = CLIHostAdapter.deliveryText(input, for: host)
                try check(delivered == expected, "\(host.rawValue) normalization: \(name)")
                try check(CLIHostAdapter.deliveryText(delivered, for: host) == delivered, "\(host.rawValue) normalization idempotent: \(name)")
            }
        }
    }

    static func intentChecks(directory: URL) throws {
        let registration = registration(kind: .codex, directory: directory)
        let intent = CLIReadIntent(sessionID: registration.session.id, now: 100)
        func preflight(_ time: TimeInterval, registration override: CLISessionRegistration? = nil) -> CLIEditorPreflight {
            CLIEditorPreflight(helperPID: 321, helperStartTimeMicros: 123_456,
                registration: override ?? registration, createdUptime: time)
        }
        try check(intent.deadline == 115, "read intent has a 15 second deadline")
        try check(intent.accepts(preflight(100), now: 100), "same-session request at intent creation admitted")
        try check(intent.accepts(preflight(110), now: 115), "same-session request at deadline admitted")
        try check(!intent.accepts(preflight(110), now: 115.001), "expired intent rejects late admission")
        try check(!intent.accepts(preflight(99.999), now: 110), "request created before current intent rejected")
        try check(!intent.accepts(preflight(111), now: 110), "future request timestamp rejected")
        try check(!intent.accepts(preflight(100), now: 99), "clock before intent cannot admit request")
        let other = self.registration(kind: .codex, directory: directory)
        try check(!intent.accepts(preflight(105, registration: other), now: 110), "other CLI session cannot consume read intent")
        let nextIntent = CLIReadIntent(sessionID: registration.session.id, now: 120)
        try check(!nextIntent.accepts(preflight(110), now: 125), "old request cannot bind to a later intent")
    }

    static func preflightChecks(directory: URL) throws {
        let preflight = CLIEditorPreflight(helperPID: 321, helperStartTimeMicros: 123_456,
            registration: registration(kind: .claude, directory: directory), createdUptime: 100)
        let url = try CLIEditorExchange.create(preflight)
        defer { CLIEditorExchange.cleanup(url) }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        try check(object["source"] == nil && object["text"] == nil && object["version"] as? Int == 2,
            "preflight wire carries v2 metadata without draft text")
        try check(CLIEditorExchange.readPreflight(url) == preflight, "v2 preflight rereads exact metadata")
        let permission = CLIEditorReadPermission(id: preflight.id, intentID: UUID())
        let permissionURL = CLIEditorExchange.file("read-permission.json", for: url)
        try CLIEditorExchange.write(permission, to: permissionURL)
        let decoded = try CLIEditorExchange.read(CLIEditorReadPermission.self, from: permissionURL)
        try check(decoded.id == preflight.id && decoded.intentID == permission.intentID, "read authorization correlates request and intent")
        let draft = CLIEditorDraft(id: preflight.id, intentID: permission.intentID, source: "两阶段草稿\n")
        let draftURL = CLIEditorExchange.file("draft.json", for: url)
        try CLIEditorExchange.write(draft, to: draftURL)
        let readDraft = try CLIEditorExchange.read(CLIEditorDraft.self, from: draftURL)
        try check(readDraft.id == preflight.id && readDraft.intentID == permission.intentID && readDraft.source == draft.source,
            "authorized draft retains request and intent identity")
        var invalid = object
        invalid["version"] = 1
        try JSONSerialization.data(withJSONObject: invalid).write(to: url)
        try expectFailure(.invalidRequest, "old editor protocol rejected") { _ = try CLIEditorExchange.readPreflight(url) }
        try CLIEditorExchange.write(preflight, to: url)
        invalid = object; invalid["id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: invalid).write(to: url)
        try expectFailure(.invalidRequest, "preflight ID must match private directory") { _ = try CLIEditorExchange.readPreflight(url) }
        try CLIEditorExchange.write(preflight, to: url)
        chmod(url.deletingLastPathComponent().path, 0o755)
        try expectFailure(.invalidRequest, "non-private exchange directory rejected") { _ = try CLIEditorExchange.readPreflight(url) }
        chmod(url.deletingLastPathComponent().path, 0o700)
        let store = CLISessionStore(home: directory.appendingPathComponent("store-home"))
        try store.save(preflight.registration)
        try check(store.load(preflight.registration.session.id) == preflight.registration, "private v2 session registration roundtrip")
        try check(store.all().count == 1, "session inventory returns saved metadata")
        store.remove(preflight.registration.session.id)
        try check(store.all().isEmpty, "session registration removal is scoped to the requested ID")
    }

    static func expectFailure(_ expected: CLIEditorFailure, _ label: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch let failure as CLIEditorFailure {
            try check(String(describing: failure) == String(describing: expected), label)
            return
        }
        throw NSError(domain: "expected rejection: " + label, code: 1)
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw NSError(domain: label, code: 1) }
        print("PASS \(label)")
    }

    static func expectFailure(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw NSError(domain: "expected rejection", code: 1)
    }
}
