import AppKit
import AccessibilityContracts

@MainActor enum GenericInputChecks {
    static func run() async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func record(_ name: String, _ value: Bool) { results.append((name, value)) }
        for route in ["range", "value", "selected text", "paste", "delayed paste"] {
            let f = ExternalInputFixture()
            f.application = ExternalApplication(pid: 7, bundle: "fixture.generic", version: "", build: "")
            f.foreground = f.application
            f.role = route == "value" ? "AXTextField" : "AXTextArea"
            f.fullDraft = "中文 😀\nEnglish e\u{301}"
            let original = f.fullDraft
            f.range = CFRange(location: 1, length: 2)
            f.replacementApproved = true
            f.contextID = nil
            f.notificationsSupported = false
            f.emitSelectionEvents = false
            f.rangeReadUnavailable = route == "value" || route == "selected text"
            f.valueReadable = route == "value"
            f.selectionAvailable = route != "value"
            f.selectionSettable = route != "value"
            f.pasteRequired = route.contains("paste")
            f.pasteCommitDelayMilliseconds = route == "delayed paste" ? 250 : 0
            let input = ExternalInput(access: f)
            do {
                try await input.captureFullInput()
                guard let snapshot = input.snapshot() else { throw ExternalInputError.unavailable }
                _ = try await input.replaceSelection(with: "translated 😀\n第二行", expected: snapshot)
                let verified = f.verifiedClipboardCompletion == true
                _ = try await input.restoreOriginalInput()
                record("generic \(route) captures whole draft without required notifications, writes once and restores",
                    snapshot.fullText == original && snapshot.identity.bundleIdentifier == "fixture.generic"
                    && f.writeCount == 2 && input.writeAttempts == 2 && f.fullDraft == original && verified)
            } catch { record("generic \(route) captures whole draft without required notifications, writes once and restores", false) }
        }

        for failure in [FillError.clipboardUnavailable, .clipboardChanged, .selectionUnavailable] {
            let f = ExternalInputFixture()
            f.fullDraft = "source"; f.range = CFRange(location: 0, length: 0)
            f.replacementApproved = true; f.pasteRequired = true
            f.prepareWriteError = failure
            let input = ExternalInput(access: f)
            do {
                try await input.captureFullInput()
                guard let snapshot = input.snapshot() else { throw ExternalInputError.unavailable }
                do {
                    _ = try await input.replaceSelection(with: "replacement", expected: snapshot)
                    record("\(failure) before paste remains a zero-write failure", false)
                } catch let error as FillError {
                    record("\(failure) before paste remains a zero-write failure",
                        error == failure && f.writeCount == 0 && input.writeAttempts == 0 && f.fullDraft == "source")
                }
            } catch { record("\(failure) before paste remains a zero-write failure", false) }
        }
        for condition in ["not applied", "late cancel"] {
            let f = ExternalInputFixture()
            f.fullDraft = "source"; f.range = CFRange(location: 0, length: 0)
            f.replacementApproved = true; f.pasteRequired = true
            f.writeApplies = condition != "not applied"
            let input = ExternalInput(access: f)
            do {
                try await input.captureFullInput()
                guard let snapshot = input.snapshot() else { throw ExternalInputError.unavailable }
                let task = Task { try await input.replaceSelection(with: "replacement", expected: snapshot) }
                if condition == "late cancel" {
                    while f.writeCount == 0 { await Task.yield() }
                    task.cancel()
                }
                do {
                    _ = try await task.value
                    record("paste \(condition) never retries or reports untouched", condition == "late cancel"
                        && f.writeCount == 1 && f.verifiedClipboardCompletion == true)
                } catch let error as FillError {
                    record("paste \(condition) never retries or reports untouched", error == .outcomeUnknown
                        && f.writeCount == 1 && f.verifiedClipboardCompletion == false)
                }
            } catch { record("paste \(condition) never retries or reports untouched", false) }
        }

        for scenario in ["unchanged", "focus changed at commit", "preview collapses selection", "preview changes text"] {
            let f = ExternalInputFixture()
            f.fullDraft = "source"; f.range = CFRange(location: 0, length: 0)
            f.replacementApproved = true; f.pasteRequired = true
            let input = ExternalInput(access: f)
            do {
                try await input.captureFullInput()
                guard let snapshot = input.snapshot() else { throw ExternalInputError.unavailable }
                if scenario.hasPrefix("preview") {
                    input.prepareForPanelActivation()
                    f.foreground = f.ownApplication
                    f.range = CFRange(location: 0, length: 0)
                    if scenario == "preview changes text" { f.fullDraft = "different" }
                    f.emit("AXSelectedTextChanged")
                    record(scenario, (input.snapshot() != nil) == (scenario == "preview collapses selection"))
                } else {
                    if scenario == "focus changed at commit" { f.beforeCommit = { f.focusedInputChanged = true } }
                    do {
                        let receipt = try await input.replaceSelection(with: scenario == "unchanged" ? "source" : "next", expected: snapshot)
                        record(scenario, scenario == "unchanged" && receipt.writtenText == "source"
                            && f.writeCount == 0 && input.writeAttempts == 0 && f.prepareWriteCount == 0)
                    } catch FillError.targetChanged {
                        record(scenario, scenario == "focus changed at commit" && f.writeCount == 0 && input.writeAttempts == 0)
                    }
                }
            } catch { record(scenario, false) }
        }

        for stage in ["capture", "submit"] {
            let f = ExternalInputFixture()
            f.fullDraft = "source"; f.range = CFRange(location: 0, length: 0)
            f.replacementApproved = true
            let input = ExternalInput(access: f)
            if stage == "capture" { f.composing = true }
            do {
                try await input.captureFullInput()
                guard let snapshot = input.snapshot() else { throw ExternalInputError.unavailable }
                f.composing = true
                _ = try await input.replaceSelection(with: "translated", expected: snapshot)
                record("active IME blocks \(stage) before writing", false)
            } catch {
                record("active IME blocks \(stage) before writing", f.writeCount == 0 && input.writeAttempts == 0
                    && (stage != "capture" || f.rangeReads == 0))
            }
        }

        // Named pasteboard only: these checks cannot touch the user's clipboard.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("fixture.custom")
        let original = NSPasteboardItem()
        original.setString("original", forType: .string)
        original.setData(Data([0, 1, 255]), forType: .png)
        original.setData(Data([3, 4, 5]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("second item", forType: .string)
        board.clearContents(); board.writeObjects([original, second])
        do {
            let transaction = try ClipboardWriteTransaction(text: "translation 😀", board: board)
            try transaction.prepare()
            record("paste transaction marks its payload", transaction.isOwned && board.string(forType: .string) == "translation 😀")
            transaction.restoreIfOwned()
            let items = board.pasteboardItems ?? []
            record("clipboard restores every item and representation", items.count == 2
                && items[0].data(forType: .png) == Data([0, 1, 255])
                && items[0].data(forType: custom) == Data([3, 4, 5])
                && items[0].string(forType: .string) == "original"
                && items[1].string(forType: .string) == "second item")
            let conflict = try ClipboardWriteTransaction(text: "translation", board: board)
            try conflict.prepare()
            board.clearContents(); board.setString("new user clipboard", forType: .string)
            conflict.restoreIfOwned()
            record("concurrent clipboard owner survives restoration", !conflict.isOwned
                && board.string(forType: .string) == "new user clipboard")
        } catch { record("clipboard transaction supports a complete backup", false) }
        for failure in ["empty", "partial", "concurrent"] {
            board.clearContents(); board.setString("valuable original", forType: .string)
            do {
                let transaction = try ClipboardWriteTransaction(text: "next", board: board, publish: { items in
                    if failure == "partial" {
                        let partial = NSPasteboardItem()
                        partial.setData(items[0].data(forType: ClipboardWriteTransaction.markerType)!, forType: ClipboardWriteTransaction.markerType)
                        _ = board.writeObjects([partial])
                    } else if failure == "concurrent" {
                        board.clearContents(); board.setString("concurrent owner", forType: .string)
                    }
                    return false
                })
                do { try transaction.prepare(); record("failed clipboard publish \(failure)", false) }
                catch {
                    transaction.restoreIfOwned()
                    record("failed clipboard publish \(failure)", board.string(forType: .string)
                        == (failure == "concurrent" ? "concurrent owner" : "valuable original"))
                }
            } catch { record("failed clipboard publish \(failure)", false) }
        }
        board.clearContents(); board.setString("original", forType: .string)
        do {
            let transaction = try ClipboardWriteTransaction(text: "next", board: board)
            try transaction.prepare()
            var submitted = false
            do {
                try transaction.validateSubmission {
                    board.clearContents(); board.setString("concurrent during AX", forType: .string)
                }
                submitted = true
            } catch FillError.clipboardChanged { }
            transaction.restoreIfOwned()
            record("clipboard change during commit validation prevents key submission", !submitted
                && board.string(forType: .string) == "concurrent during AX")
        } catch { record("clipboard change during commit validation prevents key submission", false) }
        return results
    }
}
