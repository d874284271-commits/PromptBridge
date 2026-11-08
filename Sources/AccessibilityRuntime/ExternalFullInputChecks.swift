import Foundation
import AccessibilityContracts

/// Synthetic checks for the full-input capture and replacement contract.
/// These checks use only `ExternalInputFixture`; they never touch a real app or model.
@MainActor enum ExternalFullInputChecks {
    static func run() async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func record(_ name: String, _ value: Bool) { results.append((name, value)) }

        typealias ContentNode = ExternalTextContent.Node<Int>
        let plainNodes = [
            0: ContentNode(pid: 7, role: "AXTextArea", children: [1]),
            1: ContentNode(pid: 7, role: "AXGroup", children: [2, 3]),
            2: ContentNode(pid: 7, role: "AXStaticText", children: []),
            3: ContentNode(pid: 7, role: "AXStaticText", children: []),
        ]
        func inspectContent(_ nodes: [Int: ContentNode]) -> Bool? {
            ExternalTextContent.containsObjects(root: 0, pid: 7, same: ==) { index in
                guard let node = nodes[index] else { throw ExternalInputError.unavailable }
                return node
            }
        }
        record("observed plain text tree permits whole-input content", inspectContent(plainNodes) == false)
        let scrollingText = [0: ContentNode(pid: 7, role: "AXTextArea", children: [1]),
                             1: ContentNode(pid: 7, role: "AXScrollBar", children: [])]
        record("native long text scrollbar is chrome, not embedded content", inspectContent(scrollingText) == false)
        var scrollingWithImage = scrollingText
        scrollingWithImage[0] = ContentNode(pid: 7, role: "AXTextArea", children: [1, 2])
        scrollingWithImage[2] = ContentNode(pid: 7, role: "AXImage", children: [])
        record("native scrollbar does not hide an inline image", inspectContent(scrollingWithImage) == true)
        var inlineObject = plainNodes
        inlineObject[2] = ContentNode(pid: 7, role: "AXImage", children: [])
        record("inline reference image refuses plain-text overwrite", inspectContent(inlineObject) == true)
        var unreadableChild = plainNodes
        unreadableChild[2] = nil
        record("unreadable content subtree stays unknown", inspectContent(unreadableChild) == nil)
        var foreignChild = plainNodes
        foreignChild[2] = ContentNode(pid: 8, role: "AXStaticText", children: [])
        record("foreign content child stays unknown", inspectContent(foreignChild) == nil)
        var cyclic = plainNodes
        cyclic[1] = ContentNode(pid: 7, role: "AXGroup", children: [0])
        record("cyclic content tree stays unknown", inspectContent(cyclic) == nil)
        record("native text leaf supplies text content evidence",
               inspectContent([0: ContentNode(pid: 7, role: "AXTextArea", children: [])]) == false)

        func fixture() -> ExternalInputFixture {
            let value = ExternalInputFixture()
            value.fullDraft = "第一行中文 😀。\n第二行保留按钮“确认删除”。"
            value.range = CFRange(location: 0, length: 0)
            value.replacementApproved = true
            return value
        }

        for (bundle, version, build) in [
            (CodexCapabilityProbe.bundleIdentifier, "26.1002.51308", "13417"),
            (CodexCapabilityProbe.bundleIdentifier, "future", "unknown"),
            ("com.anthropic.claudefordesktop", "future", "unknown"),
            ("com.anthropic.claudefordesktop", "2.19675.0", "different-build"),
            ("com.anthropic.claudefordesktop", "", ""),
        ] {
            do {
                let f = fixture()
                f.application = ExternalApplication(pid: 7, bundle: bundle, version: version, build: build)
                f.foreground = f.application
                let original = f.fullDraft
                let e = ExternalInput(access: f)
                try await e.captureFullInput()
                guard let snapshot = e.snapshot() else { throw ExternalInputError.unavailable }
                let receipt = try await e.replaceSelection(with: "RUNTIME CAPABILITY FIXTURE", expected: snapshot)
                _ = try await e.restoreOriginalInput()
                record("unknown pair \(bundle)/\(version)/\(build) completes runtime write and restore",
                    snapshot.supportsDirectFill && f.writeCount == 2 && f.fullDraft == original
                    && receipt.writtenText == "RUNTIME CAPABILITY FIXTURE" && !e.canRestoreOriginal)
            } catch { record("unknown pair \(bundle)/\(version)/\(build) completes runtime write and restore", false) }
        }

        for condition in ["no permission", "secure", "foreign owner", "readonly", "no focused input"] {
            let f = fixture()
            f.application = ExternalApplication(pid: 7, bundle: "com.anthropic.claudefordesktop", version: "future", build: "unknown")
            f.foreground = f.application
            if condition == "no permission" { f.hasPermission = false }
            if condition == "secure" { f.secure = true }
            if condition == "foreign owner" { f.foreignInput = true }
            if condition == "readonly" { f.editable = false }
            if condition == "no focused input" { f.focusedInputUnavailable = true }
            let e = ExternalInput(access: f)
            let original = f.fullDraft
            do {
                try await e.captureFullInput()
                record("unknown Claude rejects \(condition) without writing", false)
            } catch {
                record("unknown Claude rejects \(condition) without writing",
                       e.snapshot() == nil && f.writeCount == 0 && f.fullDraft == original
                       && (condition != "no permission" || f.appElementReads == 0))
            }
        }

        for condition in ["embedded object", "changed original"] {
            let f = fixture()
            f.application = ExternalApplication(pid: 7, bundle: "com.anthropic.claudefordesktop", version: "future", build: "unknown")
            f.foreground = f.application
            let e = ExternalInput(access: f)
            do {
                try await e.captureFullInput()
                guard let snapshot = e.snapshot() else { throw ExternalInputError.unavailable }
                if condition == "embedded object" { f.protectedContent = true }
                else { f.fullDraft = "USER CHANGED THE ORIGINAL" }
                let before = f.fullDraft
                do {
                    _ = try await e.replaceSelection(with: "MUST NOT WRITE", expected: snapshot)
                    record("unknown Claude rejects \(condition) before replacement", false)
                } catch {
                    record("unknown Claude rejects \(condition) before replacement", f.writeCount == 0 && f.fullDraft == before)
                }
            } catch { record("unknown Claude rejects \(condition) before replacement", false) }
        }

        for condition in ["secure", "unreadable subrole", "wrong subrole type"] {
            let f = fixture()
            if condition == "secure" { f.secure = true }
            if condition == "unreadable subrole" { f.subroleUnreadable = true }
            if condition == "wrong subrole type" { f.subroleWrongType = true }
            let e = ExternalInput(access: f)
            do {
                try await e.captureFullInput()
                record("runtime capture rejects \(condition) before content reads", false)
            } catch {
                record("runtime capture rejects \(condition) before content reads",
                    f.rangeReads == 0 && f.writeCount == 0 && !e.hasTarget)
            }
        }

        for operation in ["replacement", "restoration"] {
            for timing in ["focus handoff", "immediately before setter"] {
                for condition in ["secure", "unreadable subrole", "wrong subrole type", "readonly",
                                  "changed input", "changed window", "foreign owner"] {
                    let name = "\(operation) rejects \(condition) at \(timing) without issuing a write"
                    do {
                        let f = fixture()
                        let e = ExternalInput(access: f)
                        try await e.captureFullInput()
                        guard let snapshot = e.snapshot() else { throw ExternalInputError.unavailable }
                        if operation == "restoration" {
                            _ = try await e.replaceSelection(with: "RESTORE CAPABILITY FIXTURE", expected: snapshot)
                        }
                        let before = f.fullDraft
                        let writes = f.writeCount
                        let change: @MainActor () -> Void = {
                            if condition == "secure" { f.secure = true }
                            if condition == "unreadable subrole" { f.subroleUnreadable = true }
                            if condition == "wrong subrole type" { f.subroleWrongType = true }
                            if condition == "readonly" { f.editable = false }
                            if condition == "changed input" { f.focusChangesInput = true }
                            if condition == "changed window" { f.focusChangesWindow = true }
                            if condition == "foreign owner" { f.foreignInput = true }
                        }
                        if timing == "focus handoff" { f.activationNeedsInputFocus = true; f.onFocus = change }
                        else { e.onReplacementStage = { stage in if stage == .writing { change() } } }
                        do {
                            if operation == "restoration" { _ = try await e.restoreOriginalInput() }
                            else { _ = try await e.replaceSelection(with: "MUST NOT WRITE", expected: snapshot) }
                            record(name, false)
                        } catch let error as FillError {
                            let identityChanged = ["changed input", "changed window", "foreign owner"].contains(condition)
                            let expectedError = identityChanged ? FillError.targetChanged : .notEditable
                            record(name, String(describing: error) == String(describing: expectedError)
                                && f.writeCount == writes && e.writeAttempts == writes && f.fullDraft == before)
                        } catch { record(name, false) }
                    } catch { record(name, false) }
                }
            }
        }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            let s = e.snapshot()
            record("capture full input", s?.captureScope == .entireInput && s?.fullText == f.fullDraft)
            record("full UTF-16 selection", s?.selection == NSRange(location: 0, length: (f.fullDraft! as NSString).length))
            record("approved profile enables direct fill", s?.supportsDirectFill == true && s?.contextID == f.contextID)
        } catch { record("capture full input", false) }

        do {
            let f = fixture()
            f.rangeReadUnavailable = true
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            record("selected text fallback requires full AX range evidence", e.snapshot()?.fullText == f.fullDraft && f.writeCount == 0)
        } catch { record("selected text fallback requires full AX range evidence", false) }

        do {
            let f = fixture()
            f.selectionCommitDelayMilliseconds = 60
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            record("asynchronous selection commit is awaited", e.snapshot()?.fullText == f.fullDraft)
        } catch { record("asynchronous selection commit is awaited", false) }

        do {
            let f = fixture()
            f.selectionNotificationDelayMilliseconds = 60
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            try await Task.sleep(for: .milliseconds(80))
            record("selection notification settles before target is frozen", e.snapshot()?.fullText == f.fullDraft)
        } catch { record("selection notification settles before target is frozen", false) }

        do {
            let f = fixture()
            f.selectionWriteApplies = false
            let e = ExternalInput(access: f)
            do { try await e.captureFullInput(); record("unapplied selection times out", false) }
            catch { record("unapplied selection times out", e.snapshot() == nil && f.writeCount == 0) }
        }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            let old = Task { () -> Bool in
                do { try await e.captureFullInput(); return true }
                catch { return false }
            }
            old.cancel()
            try await e.captureFullInput()
            let oldSucceeded = await old.value
            record("cancelled unstarted capture cannot clear new target", !oldSucceeded && e.snapshot()?.fullText == f.fullDraft)
        } catch { record("cancelled unstarted capture cannot clear new target", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            f.foreground = f.ownApplication
            record("own panel foreground keeps captured full target", e.snapshot() != nil)
            f.foreground = ExternalApplication(pid: 8, bundle: "fixture.other", version: "", build: "")
            record("third-party foreground invalidates full target", e.snapshot() == nil)
        } catch {
            record("own panel foreground keeps captured full target", false)
            record("third-party foreground invalidates full target", false)
        }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            f.foreground = f.ownApplication
            f.activationNeedsInputFocus = true
            let returned = await e.returnFocus()
            record("copy return restores original input across activation handoff",
                   returned && e.snapshot()?.fullText == f.fullDraft && f.writeCount == 0)
        } catch { record("copy return restores original input across activation handoff", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            e.prepareForPanelActivation()
            f.focusReadFailureAt = f.reads.filter { $0 == .focusedInput }.count + 2
            f.focusReadHandoff = f.ownApplication
            record("full snapshot avoids duplicate focus check during own handoff", e.snapshot()?.fullText == f.fullDraft)
            f.focusReadHandoff = nil
            f.focusChangesInput = true
            record("own handoff still rejects another source input", e.snapshot() == nil)
        } catch {
            record("full snapshot avoids duplicate focus check during own handoff", false)
            record("own handoff still rejects another source input", false)
        }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            let first = Task { () -> Bool in
                do { try await e.captureFullInput(); return true }
                catch { return false }
            }
            await Task.yield()
            first.cancel()
            try await e.captureFullInput()
            _ = await first.value
            record("cancelled capture cannot clear reentrant capture", e.snapshot()?.fullText == f.fullDraft)
        } catch { record("cancelled capture cannot clear reentrant capture", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            f.fullDraft = "外部修改"
            f.emit("poll")
            record("source change invalidates", e.snapshot() == nil)
        } catch { record("source change invalidates", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            f.contextID = "another-context"
            f.emit("poll")
            record("context change invalidates", e.snapshot() == nil)
        } catch { record("context change invalidates", false) }

        do {
            let f = fixture()
            f.contextID = nil
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            let s = e.snapshot()
            record("nil context supports manual replacement", s?.fullText == f.fullDraft && s?.supportsDirectFill == true)
            guard let s else { throw ExternalInputError.unavailable }
            let original = f.fullDraft
            let receipt = try await e.replaceSelection(with: "MANUAL ENGLISH FIXTURE", expected: s)
            record("nil context writes once with matching receipt", f.writeCount == 1 && f.fullDraft == receipt.writtenText && receipt.expected == s)
            _ = try await e.restoreOriginalInput()
            record("nil context restores original once", f.writeCount == 2 && f.fullDraft == original && !e.canRestoreOriginal)
        } catch { record("nil context replacement and restoration", false) }

        do {
            let f = fixture()
            f.contextReadFails = true
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            let original = f.fullDraft
            _ = try await e.replaceSelection(with: "OPTIONAL METADATA FIXTURE", expected: s)
            record("unreadable optional context does not block manual write", s.contextID == nil && f.writeCount == 1)
            _ = try await e.restoreOriginalInput()
            record("unreadable optional context permits verified restoration", f.writeCount == 2 && f.fullDraft == original)
        } catch { record("unreadable optional context write and restore", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            let original = f.fullDraft
            f.contextReadFails = true
            _ = try await e.replaceSelection(with: "TRANSIENT METADATA FIXTURE", expected: s)
            _ = try await e.restoreOriginalInput()
            record("context becoming unreadable preserves manual write and restore", s.contextID != nil && f.writeCount == 2 && f.fullDraft == original)
        } catch { record("context becoming unreadable preserves manual write and restore", false) }

        for unknownState in ["protected content", "approval"] {
            do {
                let f = fixture()
                f.contextID = nil
                if unknownState == "protected content" { f.protectedContentStateKnown = false }
                if unknownState == "approval" { f.replacementApproved = false }
                let e = ExternalInput(access: f)
                try await e.captureFullInput()
                guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
                do {
                    _ = try await e.replaceSelection(with: "must not write", expected: s)
                    record("nil context still requires \(unknownState)", false)
                } catch {
                    record("nil context still requires \(unknownState)", !s.supportsDirectFill && f.writeCount == 0)
                }
            } catch { record("nil context still requires \(unknownState)", false) }
        }

        for operation in ["replacement", "restoration"] {
            for lostState in ["protected content", "approval"] {
                let name = "\(operation) rechecks \(lostState) after focus handoff"
                do {
                    let f = fixture()
                    f.contextID = nil
                    let e = ExternalInput(access: f)
                    try await e.captureFullInput()
                    guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
                    if operation == "restoration" {
                        _ = try await e.replaceSelection(with: "KNOWN TRANSLATION", expected: s)
                    }
                    let before = f.fullDraft
                    let writes = f.writeCount
                    f.activationNeedsInputFocus = true
                    f.activationNeedsInputFocus = true
            f.onFocus = { [weak f] in
                        if lostState == "protected content" { f?.protectedContentStateKnown = false }
                        if lostState == "approval" { f?.replacementApproved = false }
                    }
                    do {
                        if operation == "restoration" { _ = try await e.restoreOriginalInput() }
                        else { _ = try await e.replaceSelection(with: "MUST NOT WRITE", expected: s) }
                        record(name, false)
                    } catch FillError.notEditable {
                        record(name, f.writeCount == writes && f.fullDraft == before)
                    } catch { record(name, false) }
                } catch { record(name, false) }
            }
        }

        do {
            let f = fixture()
            f.contextID = nil
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            f.activationNeedsInputFocus = true
            f.mutateOnFocus = "changed after capture"
            do {
                _ = try await e.replaceSelection(with: "must not write", expected: s)
                record("nil context still rejects changed original", false)
            } catch { record("nil context still rejects changed original", f.writeCount == 0) }
        } catch { record("nil context still rejects changed original", false) }

        do {
            let f = fixture()
            f.contextID = nil
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            f.focusChangesInput = true
            do {
                _ = try await e.replaceSelection(with: "must not write", expected: s)
                record("nil context still rejects wrong input focus", false)
            } catch { record("nil context still rejects wrong input focus", f.writeCount == 0) }
        } catch { record("nil context still rejects wrong input focus", false) }

        do {
            let f = fixture()
            f.editable = false
            let e = ExternalInput(access: f)
            do { try await e.captureFullInput(); record("non-writable target rejected", false) }
            catch { record("non-writable target rejected", e.snapshot() == nil) }
        }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            f.activationNeedsInputFocus = true
            f.focusAccepted = false
            if let s = e.snapshot() {
                do { _ = try await e.replaceSelection(with: "focus failure", expected: s); record("focus failure blocks write", false) }
                catch { record("focus failure blocks write", f.writeCount == 0) }
            } else { record("focus failure blocks write", false) }
        } catch { record("focus failure blocks write", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            f.editable = false
            if let s = e.snapshot() {
                do { _ = try await e.replaceSelection(with: "zero write", expected: s); record("noneditable write is not unknown", false) }
                catch FillError.notEditable { record("noneditable write is not unknown", f.writeCount == 0) }
                catch { record("noneditable write is not unknown", false) }
            } else { record("noneditable write is not unknown", false) }
        } catch { record("noneditable write is not unknown", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            f.activationNeedsInputFocus = true
            f.mutateOnFocus = "A then B before write"
            if let s = e.snapshot() {
                do { _ = try await e.replaceSelection(with: "must not write", expected: s); record("prewrite value ABA blocks write", false) }
                catch { record("prewrite value ABA blocks write", f.writeCount == 0) }
            } else { record("prewrite value ABA blocks write", false) }
        } catch { record("prewrite value ABA blocks write", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            if let s = e.snapshot() {
                f.focusChangesInput = true
                do { _ = try await e.replaceSelection(with: "wrong focus", expected: s); record("wrong input focus blocks write", false) }
                catch { record("wrong input focus blocks write", f.writeCount == 0) }
            } else { record("wrong input focus blocks write", false) }
        } catch { record("wrong input focus blocks write", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            if let s = e.snapshot() {
                f.focusChangesWindow = true
                do { _ = try await e.replaceSelection(with: "wrong window", expected: s); record("wrong window focus blocks write", false) }
                catch { record("wrong window focus blocks write", f.writeCount == 0) }
            } else { record("wrong window focus blocks write", false) }
        } catch { record("wrong window focus blocks write", false) }

        do {
            let f = fixture()
            f.activationChangesFrontmost = false
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            f.foreground = f.ownApplication
            if let s = e.snapshot() {
                let task = Task { () -> Bool in
                    do { _ = try await e.replaceSelection(with: "cancelled", expected: s); return false }
                    catch FillError.cancelled { return true }
                    catch { return false }
                }
                await Task.yield()
                task.cancel()
                let cancelled = await task.value
                f.activationChangesFrontmost = true
                f.foreground = f.ownApplication
                let retried = await e.returnFocus(requireInputFocus: false)
                record("cancel before write and retry", cancelled && retried && e.canReturnFocus && f.writeCount == 0)
            } else { record("cancel before write and retry", false) }
        } catch { record("cancel before write and retry", false) }

        do {
            let f = fixture()
            f.writeApplies = false
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            if let s = e.snapshot() {
                do { _ = try await e.replaceSelection(with: "unknown", expected: s); record("unknown write is reported", false) }
                catch FillError.outcomeUnknown { record("unknown write is reported", f.writeCount == 1) }
                catch { record("unknown write is reported", false) }
            } else { record("unknown write is reported", false) }
        } catch { record("unknown write is reported", false) }

        do {
            let f = fixture()
            f.contextChangesOnWrite = "changed-during-write"
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            if let s = e.snapshot() {
                do { _ = try await e.replaceSelection(with: "context changes", expected: s); record("context change during write is unknown", false) }
                catch FillError.outcomeUnknown { record("context change during write is unknown", f.writeCount == 1) }
                catch { record("context change during write is unknown", false) }
            } else { record("context change during write is unknown", false) }
        } catch { record("context change during write is unknown", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            if let s = e.snapshot() {
                let originalText = s.fullText
                let receipt = try await e.replaceSelection(with: "English draft", expected: s)
                record("normal write once", receipt.writtenText == "English draft" && f.writeCount == 1 && f.writtenTexts == ["English draft"])
                f.emit("poll")
                record("post-write poll preserves restore", e.canRestoreOriginal)
                f.emit("AXValueChanged")
                record("late own notification preserves strict restore record", e.canRestoreOriginal)
                record("restore is user initiated and verified", e.canRestoreOriginal)
                let restored = try await e.restoreOriginalInput()
                record("restore original once", restored.writtenText == originalText && f.writeCount == 2)
            } else { record("normal write once", false) }
        } catch { record("normal write once", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            if let s = e.snapshot() {
                _ = try await e.replaceSelection(with: "English draft", expected: s)
                f.fullDraft = "user changed"
                f.emit("AXValueChanged")
                record("user change rejects recovery", !e.canRestoreOriginal)
            } else { record("user change rejects recovery", false) }
        } catch { record("user change rejects recovery", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            if let s = e.snapshot() {
                let originalText = s.fullText
                _ = try await e.replaceSelection(with: "English draft", expected: s)
                f.emit("AXValueChanged")
                f.activationNeedsInputFocus = true
            f.mutateOnFocus = originalText
                do {
                    _ = try await e.restoreOriginalInput()
                    record("delayed receipt restore ABA writes zero", false)
                } catch {
                    record("delayed receipt restore ABA writes zero", f.writeCount == 1)
                }
            } else { record("delayed receipt restore ABA writes zero", false) }
        } catch { record("delayed receipt restore ABA writes zero", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            _ = try await e.replaceSelection(with: "English draft", expected: s)
            // No late notification first: restoration must replace a still-live
            // observer without its old stop() detaching the new observer.
            f.activationNeedsInputFocus = true
            f.onFocus = { [weak f] in
                f?.fullDraft = "intervening user edit"
                f?.emit("AXValueChanged")
                f?.fullDraft = "English draft"
                f?.emit("AXValueChanged")
            }
            do {
                _ = try await e.restoreOriginalInput()
                record("normal receipt restoration rejects notified value ABA", false)
            } catch FillError.targetChanged {
                record("normal receipt restoration rejects notified value ABA", f.writeCount == 1)
            } catch { record("normal receipt restoration rejects notified value ABA", false) }
        } catch { record("normal receipt restoration rejects notified value ABA", false) }

        do {
            let f = fixture()
            f.writeNotificationDelayMilliseconds = 30
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            let original = f.fullDraft
            e.onReplacementStage = { stage in
                if stage == .verifying {
                    f.focusReadFailureAt = f.reads.filter { $0 == .focusedInput }.count + 1
                    f.focusReadFailsWithoutHandoff = true
                }
            }
            let receipt = try await e.replaceSelection(with: "ASYNC ENGLISH", expected: s)
            record("delayed own notifications and transient focus produce one verified write",
                   receipt.writtenText == f.fullDraft && f.writeCount == 1)
            _ = try await e.restoreOriginalInput()
            record("restoration also waits for delayed own notifications",
                   f.fullDraft == original && f.writeCount == 2 && !e.canRestoreOriginal)
        } catch { record("asynchronous write and restore receipt", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            _ = try await e.replaceSelection(with: "ENGLISH FOR RECOVERY", expected: s)
            var getterWasRead = false
            var getterWasFalse = false
            e.onReplacementStage = { [weak e] stage in
                if stage == .verifying {
                    getterWasRead = true
                    getterWasFalse = e?.canRestoreOriginal == false
                }
            }
            _ = try await e.restoreOriginalInput()
            record("restore availability getter cannot invalidate an in-flight restoration",
                   getterWasRead && getterWasFalse && f.writeCount == 2 && f.fullDraft == s.fullText)
        } catch { record("restore availability getter cannot invalidate an in-flight restoration", false) }

        for mutation in ["text", "focus"] {
            let name = "observed \(mutation) ABA during verification is still unknown"
            do {
                let f = fixture()
                let e = ExternalInput(access: f)
                try await e.captureFullInput()
                guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
                e.onReplacementStage = { stage in
                    if stage == .verifying {
                        if mutation == "text" {
                            f.fullDraft = "ANOTHER EDIT"
                            f.emit("AXValueChanged")
                            f.fullDraft = "EXPECTED ENGLISH"
                            f.emit("AXValueChanged")
                        } else {
                            f.focusChangesInput = true
                            f.emit("AXFocusedUIElementChanged")
                            f.focusChangesInput = false
                            f.emit("AXFocusedUIElementChanged")
                        }
                    }
                }
                do {
                    _ = try await e.replaceSelection(with: "EXPECTED ENGLISH", expected: s)
                    record(name, false)
                } catch FillError.outcomeUnknown { record(name, f.writeCount == 1) }
                catch { record(name, false) }
            } catch { record(name, false) }
        }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            e.onReplacementStage = { stage in
                if stage == .verifying {
                    f.focusChangesInput = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(15))
                        f.focusChangesInput = false
                    }
                }
            }
            do {
                _ = try await e.replaceSelection(with: "FOCUS ABA ENGLISH", expected: s)
                record("unnotified focus ABA observed by verification stays unknown", false)
            } catch FillError.outcomeUnknown {
                try await Task.sleep(for: .milliseconds(25))
                record("unnotified focus ABA observed by verification stays unknown",
                       !f.focusChangesInput && f.writeCount == 1)
            } catch { record("unnotified focus ABA observed by verification stays unknown", false) }
        } catch { record("unnotified focus ABA observed by verification stays unknown", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            e.onReplacementStage = { stage in
                if stage == .verifying {
                    f.fullDraft = s.fullText
                    f.range = CFRange(location: 0, length: 0)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(15))
                        f.fullDraft = "TEXT ABA ENGLISH"
                    }
                }
            }
            do {
                _ = try await e.replaceSelection(with: "TEXT ABA ENGLISH", expected: s)
                record("unnotified original reversion after an observed write stays unknown", false)
            } catch FillError.outcomeUnknown {
                try await Task.sleep(for: .milliseconds(25))
                record("unnotified original reversion after an observed write stays unknown",
                       f.fullDraft == "TEXT ABA ENGLISH" && f.writeCount == 1)
            } catch { record("unnotified original reversion after an observed write stays unknown", false) }
        } catch { record("unnotified original reversion after an observed write stays unknown", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            _ = try await e.replaceSelection(with: "RECOVER AFTER OPENING", expected: s)
            f.focusReadFailureAt = f.reads.filter { $0 == .focusedInput }.count + 1
            f.focusReadFailsWithoutHandoff = true
            let recoveryStayedAvailable = e.canRestoreOriginal
            f.focusReadFailsWithoutHandoff = false
            f.foreground = f.ownApplication
            _ = try await e.restoreOriginalInput()
            record("opening recovery does not discard receipt on unavailable host focus",
                   recoveryStayedAvailable && f.fullDraft == s.fullText && f.writeCount == 2)
        } catch { record("opening recovery does not discard receipt on unavailable host focus", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            _ = try await e.replaceSelection(with: "MENU RECOVERY ENGLISH", expected: s)
            let began = e.beginPanelContextMenu()
            f.focusedInputUnavailable = true
            try await Task.sleep(for: .milliseconds(1_050))
            for notification in ["poll", "AXFocusedUIElementChanged", "AXFocusedWindowChanged", "workspace"] {
                f.emit(notification)
            }
            let menuKeptReceipt = e.snapshot() != nil && e.canRestoreOriginal
            e.endPanelContextMenu()
            let activationGraceKeptReceipt = e.snapshot() != nil && e.canRestoreOriginal
            f.foreground = f.ownApplication
            f.focusedInputUnavailable = false
            _ = try await e.restoreOriginalInput()
            record("native menu lifetime preserves receipt beyond activation timeout and restores once",
                   began && menuKeptReceipt && activationGraceKeptReceipt
                   && f.fullDraft == s.fullText && f.writeCount == 2)
        } catch { record("native menu lifetime preserves receipt beyond activation timeout and restores once", false) }

        for notification in ["poll", "AXSelectedTextChanged"] {
            let name = "menu selection collapse preserves verified receipt via \(notification)"
            do {
                let f = fixture()
                let e = ExternalInput(access: f)
                try await e.captureFullInput()
                guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
                _ = try await e.replaceSelection(with: "SELECTION MENU ENGLISH", expected: s)
                guard e.beginPanelContextMenu() else { throw ExternalInputError.unavailable }
                f.focusedInputUnavailable = true
                f.range = CFRange(location: 0, length: 0)
                f.emit(notification)
                let retained = e.snapshot() == nil && e.canRestoreOriginal
                e.endPanelContextMenu()
                f.foreground = f.ownApplication
                f.focusedInputUnavailable = false
                _ = try await e.restoreOriginalInput()
                record(name, retained && f.fullDraft == s.fullText && f.writeCount == 2)
            } catch { record(name, false) }
        }

        for change in ["text", "context", "window with unreadable input", "input with unreadable window", "other application", "own app with changed input"] {
            let name = "native menu rejects \(change)"
            do {
                let f = fixture()
                let e = ExternalInput(access: f)
                try await e.captureFullInput()
                guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
                _ = try await e.replaceSelection(with: "UNCHANGED MENU ENGLISH", expected: s)
                guard e.beginPanelContextMenu() else { throw ExternalInputError.unavailable }
                switch change {
                case "text": f.fullDraft = "different content"; f.focusedInputUnavailable = true
                case "context": f.contextID = "different context"; f.focusedInputUnavailable = true
                case "window with unreadable input": f.focusChangesWindow = true; f.focusedInputUnavailable = true
                case "input with unreadable window": f.focusedWindowUnavailable = true; f.focusChangesInput = true
                case "other application": f.foreground = ExternalApplication(pid: 8, bundle: "fixture.other", version: "", build: "")
                default: f.foreground = f.ownApplication; f.focusChangesInput = true
                }
                f.emit("AXFocusedUIElementChanged")
                e.endPanelContextMenu()
                record(name, e.snapshot() == nil && !e.canRestoreOriginal && f.writeCount == 1)
            } catch { record(name, false) }
        }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            try await e.captureFullInput()
            guard let s = e.snapshot() else { throw ExternalInputError.unavailable }
            _ = try await e.replaceSelection(with: "CANCELLED MENU ENGLISH", expected: s)
            guard e.beginPanelContextMenu() else { throw ExternalInputError.unavailable }
            f.focusedInputUnavailable = true
            e.endPanelContextMenu()
            try await Task.sleep(for: .milliseconds(1_050))
            f.emit("poll")
            record("closed menu does not permanently tolerate unavailable host focus",
                   e.snapshot() == nil && !e.canRestoreOriginal && f.writeCount == 1)
        } catch { record("closed menu does not permanently tolerate unavailable host focus", false) }

        do {
            let f = fixture()
            let e = ExternalInput(access: f)
            let emptyMenuRejected = !e.beginPanelContextMenu()
            try await e.captureFullInput()
            guard e.beginPanelContextMenu() else { throw ExternalInputError.unavailable }
            e.clear()
            try await e.captureFullInput()
            e.endPanelContextMenu()
            f.focusedInputUnavailable = true
            record("cleared menu cannot grant a later capture an activation handoff",
                   emptyMenuRejected && e.snapshot() == nil && f.writeCount == 0)
        } catch { record("cleared menu cannot grant a later capture an activation handoff", false) }

        return results
    }
}
