import AppKit
import ApplicationServices
import AccessibilityContracts

/// Reads only the deliberately captured editable input. Every write is bound to
/// its original process, window, control, capture token and live text.
@MainActor final class ExternalInput: HostInput {
    var onChange: (() -> Void)?
    var onGeometryChange: (() -> Void)?
    var onObservedChange: ((String) -> Void)?
    var onReplacementStage: ((ReplacementStage) -> Void)?
    var onWriteIssued: (() -> Void)?
    private(set) var frameOnScreen: NSRect?

    var isTargetAvailable: Bool { target != nil }
    var hasTarget: Bool { capturedApplication != nil }
    var canReturnFocus: Bool { !returnFailed && capturedApplication.map { access.isRunning($0) } == true }
    var hostName: String { capturedHost?.name ?? "宿主" }
    static var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    /// Cached values are deliberately side-effect free. Live validation remains in
    /// `snapshot()` and the operation methods below.
    var cachedSnapshot: InputSnapshot? { target?.snapshot }
    var hasRestoreRecord: Bool {
        confirmedReceipt != nil && originalForRestore != nil && confirmedTarget != nil
    }
    var currentRevision: UInt64 { revision }
    var cachedCanRestoreOriginal: Bool { !replacementInFlight && hasRestoreRecord }
    var cachedCanReturnFocus: Bool {
        !returnFailed && capturedApplication != nil && (target != nil || hasRestoreRecord)
    }
    /// The original capture reference retained by a verified restoration
    /// receipt. It intentionally does not expose the backend's current capture
    /// generation, which rotates when the live target is invalidated.
    var cachedRestorationReference: BrokerTargetReference? {
        guard let captureID = confirmedReceipt?.expected.captureID,
              let receipt = confirmedReceipt else { return nil }
        return BrokerTargetReference(captureToken: captureID, revision: receipt.expected.revision)
    }

    enum Host: Equatable {
        case claude, codex, generic(String)
        var name: String {
            switch self {
            case .claude: return "Claude"
            case .codex: return "ChatGPT / Codex"
            case .generic(let name): return name
            }
        }
        @MainActor static func matching(_ application: ExternalApplication) throws -> Host {
            guard application.bundle != BrokerIdentity.bundle,
                  application.bundle != BrokerIdentity.clientBundle, application.bundle != "com.apple.Terminal" else { throw ExternalInputError.unsupportedApplication }
            switch application.bundle {
            case "com.anthropic.claudefordesktop": return .claude
            case CodexCapabilityProbe.bundleIdentifier: return .codex
            case "com.tencent.xinWeChat": return .generic("微信")
            case "com.tencent.qq": return .generic("QQ")
            default:
                let name = NSRunningApplication(processIdentifier: application.pid)?.localizedName
                    ?? (application.bundle.isEmpty ? "应用 \(application.pid)" : application.bundle)
                return .generic(name)
            }
        }
    }
    private let access: any ExternalInputAccess
    private var revision: UInt64 = 0
    private var target: CapturedTarget?
    private var capturedApplication: ExternalApplication?
    private var capturedHost: Host?
    private var returnFailed = false
    private(set) var captureID = UUID()
    /// Counts attempted full-text write commands, including explicit restoration.
    private(set) var writeAttempts = 0
    private(set) var lastReadFailure: ExternalAttribute?
    private var panelActivationDeadline: Date?
    private var panelActivationCaptureID: UUID?
    private var panelContextMenuDepth = 0
    private var panelContextMenuCaptureID: UUID?
    private var observations: (any ExternalObservation)?
    private var captureScope: CaptureScope?
    private var captureExpectedRange: NSRange?
    private var captureSelectionConfirmed = false
    private var pendingInput: AXUIElement?
    private var captureEventRejected = false
    private var replacementInFlight = false
    private var replacementExternalChange = false
    private var focusHandoffInProgress = false
    private enum ReplacementActivity { case returning, prewrite, writing, verifying }
    private var replacementActivity: ReplacementActivity?
    private var controlledSelection: NSRange?
    private var writeIssued = false
    private var observedWrittenText = false
    private var replacementBeforeText: String?
    private var replacementExpectedText: String?
    private var replacementExpectedContext: String?
    private var originalForRestore: InputSnapshot?
    private var confirmedReceipt: ReplacementReceipt?
    private var confirmedTarget: CapturedTarget?
    // A verified receipt can outlive the source capture after a late notification;
    // restoration installs a fresh observer and uses this reference only for the
    // user-initiated restore operation.
    private var restorationTarget: CapturedTarget?
    private var restorationToken: UUID?

    @MainActor init(access: any ExternalInputAccess) {
        self.access = access
        access.onSetterIssued = { [weak self] in
            guard let self else { return }
            self.writeIssued = true
            self.writeAttempts += 1
            self.onWriteIssued?()
        }
    }

    private struct CapturedTarget {
        let applicationElement: AXUIElement
        let window: AXUIElement
        let input: AXUIElement
        let snapshot: InputSnapshot
    }

    private struct SelectionState {
        let range: NSRange
        let text: String
    }

    deinit {
        // The observer's unretained context stays alive until its main-run-loop source is removed.
        if let observations {
            DispatchQueue.main.async { observations.stop() }
        }
    }

    func captureFrontmost() throws {
        try captureSelectionFrontmost()
    }

    private func captureSelectionFrontmost() throws {
        guard access.hasPermission else {
            clear()
            throw ExternalInputError.permissionRequired
        }
        guard let application = access.frontmost(), access.isRunning(application) else {
            clear()
            throw ExternalInputError.unsupportedApplication
        }
        let host: Host
        do { host = try Host.matching(application) }
        catch { clear(); throw error }
        // Verify the host before creating or reading any AX element.
        clear()
        captureScope = .selection
        captureExpectedRange = nil
        captureEventRejected = false
        let applicationElement = access.applicationElement(application)
        let window = try elementAttribute(applicationElement, .focusedWindow)
        let input = try elementAttribute(applicationElement, .focusedInput)
        try requireProcess(window, application.pid)
        try requireProcess(input, application.pid)
        let selection = try readSelection(input, host: host)
        let frame = try readFrame(input)

        let captureID = self.captureID
        let resources = try access.observe(application: applicationElement, window: window,
            input: input, pid: application.pid, requireSelectionEvents: false,
            receive: { [weak self] notification in
                guard let self, self.captureID == captureID else { return }
                self.receive(notification)
            })
        let identity = InputIdentity(host: host.name,
                                     window: "\(application.pid):ax:\(CFHash(window))",
                                     input: "\(application.pid):ax:\(CFHash(input))",
                                     session: "selected-input", bundleIdentifier: application.bundle)
        let snapshot = InputSnapshot(identity: identity, revision: revision, selection: selection.range,
                                     selectedText: selection.text, supportsDirectFill: false,
                                     captureScope: .selection, fullText: nil, contextID: nil,
                                     captureID: captureID)
        target = CapturedTarget(applicationElement: applicationElement, window: window, input: input, snapshot: snapshot)
        capturedApplication = application
        capturedHost = host
        returnFailed = false
        observations = resources
        updateFrame(frame)
        // Close the gap between the initial read and installing the observer.
        guard validateTarget() else { throw ExternalInputError.invalidSelection }
        onChange?()
    }

    /// Compatibility entry point for callers that want to select the capture scope.
    /// The legacy no-argument method remains synchronous for the existing selection flow.
    func captureFrontmost(scope: CaptureScope) async throws {
        switch scope {
        case .selection: try captureSelectionFrontmost()
        case .entireInput: try await captureFullInput()
        }
    }

    /// Captures the complete focused input through the narrow AX range API. It does not
    /// inspect children, history, or neighboring controls. The temporary full selection
    /// is intentional: AX exposes text for a range, not a reliable draft value contract.
    func captureFullInput() async throws {
        try Task.checkCancellation()
        guard access.hasPermission else { clear(); throw ExternalInputError.permissionRequired }
        guard let application = access.frontmost(), access.isRunning(application) else {
            clear(); throw ExternalInputError.unsupportedApplication
        }
        let host: Host
        do { host = try Host.matching(application) }
        catch { clear(); throw error }

        clear()
        captureScope = .entireInput
        captureExpectedRange = nil
        captureEventRejected = false
        let applicationElement = access.applicationElement(application)
        let window = try elementAttribute(applicationElement, .focusedWindow)
        let input = try elementAttribute(applicationElement, .focusedInput)
        pendingInput = input
        try requireProcess(window, application.pid)
        try requireProcess(input, application.pid)
        try validateFocusedIdentity(applicationElement, window: window, input: input,
                                    application: application)
        try validateInputRole(input, host: host)
        try requireNoComposition(input)
        guard access.isEditable(input) else { throw ExternalInputError.noFocusedInput }

        let captureID = self.captureID
        let resources = try access.observe(application: applicationElement, window: window,
            input: input, pid: application.pid, requireSelectionEvents: false,
            receive: { [weak self] notification in
                guard let self, self.captureID == captureID else { return }
                self.receive(notification)
            })
        observations = resources

        do {
            // Selected-text-only controls require independently observable range/count
            // evidence. No clipboard-change heuristic is used to obtain source text.
            if (try? readFullText(input)) == nil,
               let count = try attribute(input, .characterCount, optional: true) as? NSNumber,
               count.intValue >= 0 {
                captureExpectedRange = NSRange(location: 0, length: count.intValue)
                try await access.selectAll(in: input, count: count.intValue)
                let deadline = Date().addingTimeInterval(0.5)
                while (try? selectedRange(input)) != captureExpectedRange {
                    try validateFocusedIdentity(applicationElement, window: window, input: input, application: application)
                    guard !captureEventRejected, Date() < deadline else { throw ExternalInputError.invalidSelection }
                    try await Task.sleep(for: .milliseconds(15))
                }
            }
            let first = try readFullState(input, window: window, applicationElement: applicationElement,
                                          application: application)
            guard !first.text.isEmpty else { throw ExternalInputError.noSelection }
            let selects = access.canSetSelectedRange(input)
            captureExpectedRange = selects ? NSRange(location: 0, length: first.characterCount) : nil
            let fullRange = CFRange(location: 0, length: first.characterCount)
            captureSelectionConfirmed = first.selection == captureExpectedRange
            if selects && !captureSelectionConfirmed { try access.setSelectedRange(fullRange, in: input) }
            // Electron can acknowledge AXSelectedTextRange before committing it.
            // Wait for the actual range while rechecking the original text and focus;
            // unexpected observer events still reject the capture, including ABA.
            await Task.yield()
            let selectionDeadline = Date().addingTimeInterval(0.5)
            var selectedState: FullInputState?
            var selectionStableSince: Date?
            var selectionRevision = revision
            repeat {
                guard !Task.isCancelled, captureID == self.captureID,
                      pendingInput.map({ CFEqual($0, input) }) == true else {
                    throw ExternalInputError.unavailable
                }
                guard !captureEventRejected else { throw ExternalInputError.invalidSelection }
                guard Date() < selectionDeadline else { throw ExternalInputError.invalidSelection }
                let current = try readFullState(input, window: window, applicationElement: applicationElement,
                                                application: application)
                guard current.text == first.text,
                      current.characterCount == first.characterCount,
                      contextsMatch(current.contextID, first.contextID),
                      !captureEventRejected else { throw ExternalInputError.invalidSelection }
                guard Date() < selectionDeadline else { throw ExternalInputError.invalidSelection }
                if !selects || current.selection == captureExpectedRange {
                    if selectionStableSince == nil || selectionRevision != revision {
                        selectionStableSince = Date()
                        selectionRevision = revision
                    }
                    if Date().timeIntervalSince(selectionStableSince!) >= 0.08 {
                        selectedState = current
                        break
                    }
                } else { selectionStableSince = nil }
                try await Task.sleep(for: .milliseconds(15))
            } while true
            guard let second = selectedState else { throw ExternalInputError.invalidSelection }

            let capabilities = access.replacementCapabilities(application: application, window: window,
                                                               input: input, host: host)
            let identity = InputIdentity(host: host.name,
                window: "\(application.pid):ax:\(CFHash(window))",
                input: "\(application.pid):ax:\(CFHash(input))",
                session: second.contextID ?? "unverified-context", bundleIdentifier: application.bundle)
            let snapshot = InputSnapshot(identity: identity, revision: revision,
                selection: second.selection, selectedText: second.selectedText,
                containsProtectedContent: capabilities.protectedContent == true || second.text.contains("\u{fffc}"),
                supportsDirectFill: capabilities.approved && capabilities.protectedContent == false && !second.text.contains("\u{fffc}"),
                captureScope: .entireInput, fullText: second.text,
                contextID: second.contextID, captureID: captureID)
            target = CapturedTarget(applicationElement: applicationElement, window: window,
                                    input: input, snapshot: snapshot)
            capturedApplication = application
            capturedHost = host
            captureScope = .entireInput
            returnFailed = false
            updateFrame(try readFrame(input))
            guard validateTarget() else { throw ExternalInputError.invalidSelection }
            onChange?()
        } catch {
            if captureID == self.captureID {
                resources.stop()
                observations = nil
                clear()
            }
            throw error
        }
    }

    /// An accepted activation request is not proof that the target became frontmost.
    func returnFocus(allowInvalidTarget: Bool = false, requireInputFocus: Bool = true) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard canReturnFocus, (allowInvalidTarget || target != nil), let application = capturedApplication else { return false }
        let captureID = self.captureID
        let previousHandoff = focusHandoffInProgress
        focusHandoffInProgress = true
        defer { focusHandoffInProgress = previousHandoff }
        guard access.activate(application) else {
            if self.captureID == captureID { returnFailed = true }
            return false
        }
        let deadline = Date().addingTimeInterval(1)
        repeat {
            guard self.captureID == captureID, capturedApplication == application, access.isRunning(application) else {
                if self.captureID == captureID { returnFailed = true }
                return false
            }
            if access.frontmost() == application {
                if !requireInputFocus || (allowInvalidTarget && target == nil) { return true }
                guard let target else { return false }
                do { try await focusTarget(target, application: application) }
                catch {
                    if self.captureID == captureID, !Task.isCancelled { returnFailed = true }
                    return false
                }
                return self.captureID == captureID && targetIsFocused(target, application: application)
            }
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch {
                if Task.isCancelled { return false }
                break
            }
        } while Date() < deadline
        if self.captureID == captureID, !Task.isCancelled { returnFailed = true }
        return false
    }

    func clear() {
        let hadTarget = hasTarget
        captureID = UUID()
        lastReadFailure = nil
        panelActivationDeadline = nil
        panelActivationCaptureID = nil
        panelContextMenuDepth = 0
        panelContextMenuCaptureID = nil
        target = nil
        capturedApplication = nil
        capturedHost = nil
        captureScope = nil
        captureExpectedRange = nil
        pendingInput = nil
        captureEventRejected = false
        captureSelectionConfirmed = false
        replacementInFlight = false
        replacementExternalChange = false
        focusHandoffInProgress = false
        replacementActivity = nil
        writeIssued = false
        observedWrittenText = false
        replacementBeforeText = nil
        replacementExpectedText = nil
        replacementExpectedContext = nil
        originalForRestore = nil
        confirmedReceipt = nil
        confirmedTarget = nil
        restorationTarget = nil
        restorationToken = nil
        returnFailed = false
        revision += 1
        observations?.stop()
        observations = nil
        updateFrame(nil)
        if hadTarget { onChange?() }
    }

    func snapshot() -> InputSnapshot? {
        guard validateTarget() else { return nil }
        return target?.snapshot
    }

    /// Performs the live AX validation used by a broker operation after the
    /// caller has matched the opaque capture token and revision.
    func liveSnapshot(_ reference: BrokerTargetReference) -> InputSnapshot? {
        guard let snapshot = cachedSnapshot,
              snapshot.captureID == reference.captureToken,
              snapshot.revision == reference.revision,
              validateTarget() else { return nil }
        return target?.snapshot
    }

    var canRestoreOriginal: Bool {
        guard !replacementInFlight else { return false }
        guard let receipt = confirmedReceipt, let original = originalForRestore,
              let target = confirmedTarget,
              let application = capturedApplication,
              access.isRunning(application), surfaceIsAllowed() else { return false }
        // Opening our panel intentionally transfers focus. Availability concerns
        // the saved input's contents; restore itself reacquires strict focus before writing.
        guard let currentText = try? readFullText(target.input) else { return false }
        let contextID = try? access.contextID(window: target.window, input: target.input)
        guard currentText == receipt.writtenText, contextsMatch(contextID, original.contextID) else {
            discardRestoreRecord()
            if self.target != nil { invalidateTarget() }
            return false
        }
        return true
    }

    func replaceSelection(with text: String, expected: InputSnapshot) async throws -> ReplacementReceipt {
        guard expected.captureScope == .entireInput,
              expected.supportsDirectFill,
              let target,
              target.snapshot == expected,
              let application = capturedApplication,
              access.isRunning(application) else { throw FillError.notEditable }
        guard !replacementInFlight else { throw FillError.targetChanged }

        let operationCaptureID = captureID
        guard expected.captureID == operationCaptureID else { throw FillError.targetChanged }
        let originalSnapshot = expected
        replacementInFlight = true
        replacementExternalChange = false
        replacementActivity = .returning
        writeIssued = false
        replacementBeforeText = expected.fullText
        replacementExpectedText = text
        replacementExpectedContext = expected.contextID
        onReplacementStage?(.returning)
        defer {
            replacementInFlight = false
            replacementActivity = nil
            writeIssued = false
            replacementBeforeText = nil
            replacementExpectedText = nil
            replacementExpectedContext = nil
        }

        guard !Task.isCancelled else { throw FillError.cancelled }
        focusHandoffInProgress = true
        let returned = await returnFocus(requireInputFocus: false)
        if Task.isCancelled {
            focusHandoffInProgress = false
            throw FillError.cancelled
        }
        guard returned, captureID == operationCaptureID else {
            focusHandoffInProgress = false
            throw FillError.targetChanged
        }
        do { try await focusTarget(target, application: application) }
        catch {
            focusHandoffInProgress = false
            throw error
        }
        focusHandoffInProgress = false
        guard !Task.isCancelled else { throw FillError.cancelled }
        replacementActivity = .prewrite
        try requireCurrentReplacementCapabilities(target, application: application)
        guard captureID == operationCaptureID, !replacementExternalChange,
              target.snapshot == expected,
              let current = try? readFullState(target.input, window: target.window,
                                               applicationElement: target.applicationElement,
                                               application: application),
              current.text == expected.fullText,
              contextsMatch(current.contextID, expected.contextID) else {
            throw FillError.targetChanged
        }
        guard access.isEditable(target.input) else { throw FillError.notEditable }

        onReplacementStage?(.writing)
        guard !Task.isCancelled, captureID == operationCaptureID,
              !replacementExternalChange else { throw FillError.cancelled }
        try validateWritableReplacementTarget(target, application: application)
        guard !Task.isCancelled, captureID == operationCaptureID,
              !replacementExternalChange else { throw FillError.cancelled }
        let finalState = try await performFullWrite(text, target: target, application: application,
            beforeText: expected.fullText ?? expected.selectedText, contextID: expected.contextID,
            operationCaptureID: operationCaptureID)
        let writtenSnapshot = InputSnapshot(identity: expected.identity, revision: revision,
            selection: finalState.selection, selectedText: finalState.selectedText,
            containsProtectedContent: false,
            supportsDirectFill: expected.supportsDirectFill, captureScope: .entireInput,
            fullText: text, contextID: expected.contextID, captureID: operationCaptureID)
        let writtenTarget = CapturedTarget(applicationElement: target.applicationElement,
            window: target.window, input: target.input, snapshot: writtenSnapshot)
        self.target = writtenTarget
        let receipt = ReplacementReceipt(expected: originalSnapshot, writtenText: text)
        originalForRestore = originalSnapshot
        confirmedReceipt = receipt
        confirmedTarget = writtenTarget
        return receipt
    }

    func restoreOriginalInput() async throws -> ReplacementReceipt {
        guard let receipt = confirmedReceipt, let original = originalForRestore,
              let target = confirmedTarget,
              let application = capturedApplication,
              access.isRunning(application), surfaceIsAllowed(),
              let currentText = try? readFullText(target.input), currentText == receipt.writtenText,
              contextsMatch(try? access.contextID(window: target.window, input: target.input),
                            original.contextID) else { throw FillError.targetChanged }
        guard !replacementInFlight else { throw FillError.targetChanged }
        let operationCaptureID = captureID
        replacementInFlight = true
        replacementExternalChange = false
        replacementActivity = .returning
        writeIssued = false
        replacementBeforeText = receipt.writtenText
        replacementExpectedText = original.fullText ?? original.selectedText
        replacementExpectedContext = original.contextID
        restorationTarget = target
        let token = UUID()
        restorationToken = token
        var resources: (any ExternalObservation)?
        defer {
            if let resources {
                resources.stop()
                if let current = self.observations, current === resources { self.observations = nil }
            }
            replacementInFlight = false
            replacementActivity = nil
            writeIssued = false
            replacementBeforeText = nil
            replacementExpectedText = nil
            replacementExpectedContext = nil
            restorationTarget = nil
            restorationToken = nil
        }
        resources = try access.observe(application: target.applicationElement,
            window: target.window, input: target.input,
            pid: application.pid, requireSelectionEvents: false,
            receive: { [weak self] notification in
                guard let self, self.restorationToken == token else { return }
                self.receive(notification)
            })
        let previousObservations = observations
        observations = resources
        previousObservations?.stop()
        onReplacementStage?(.returning)
        focusHandoffInProgress = true
        let returned = await returnFocus(allowInvalidTarget: true, requireInputFocus: false)
        if Task.isCancelled {
            focusHandoffInProgress = false
            throw FillError.cancelled
        }
        guard returned, operationCaptureID == captureID else {
            focusHandoffInProgress = false
            throw FillError.targetChanged
        }
        do { try await focusTarget(target, application: application) }
        catch {
            focusHandoffInProgress = false
            throw error
        }
        focusHandoffInProgress = false
        try requireCurrentReplacementCapabilities(target, application: application)
        guard let before = try? readFullState(target.input, window: target.window,
                                               applicationElement: target.applicationElement,
                                               application: application),
              before.text == receipt.writtenText, contextsMatch(before.contextID, original.contextID),
              !Task.isCancelled, !replacementExternalChange,
              operationCaptureID == captureID else { throw FillError.targetChanged }
        guard access.isEditable(target.input) else { throw FillError.notEditable }
        onReplacementStage?(.writing)
        guard !Task.isCancelled, operationCaptureID == captureID,
              !replacementExternalChange else { throw FillError.cancelled }
        try validateWritableReplacementTarget(target, application: application)
        guard !Task.isCancelled, captureID == operationCaptureID,
              !replacementExternalChange else { throw FillError.cancelled }
        let verifiedState = try await performFullWrite(original.fullText ?? original.selectedText,
            target: target, application: application, beforeText: receipt.writtenText,
            contextID: original.contextID, operationCaptureID: operationCaptureID)
        let restoredSnapshot = InputSnapshot(identity: original.identity, revision: revision,
            selection: verifiedState.selection, selectedText: verifiedState.selectedText,
            containsProtectedContent: false,
            supportsDirectFill: original.supportsDirectFill, captureScope: .entireInput,
            fullText: original.fullText, contextID: original.contextID, captureID: operationCaptureID)
        self.target = CapturedTarget(applicationElement: target.applicationElement,
            window: target.window, input: target.input, snapshot: restoredSnapshot)
        let restored = ReplacementReceipt(expected: receipt.expected, writtenText: original.fullText ?? original.selectedText)
        confirmedReceipt = nil
        originalForRestore = nil
        confirmedTarget = nil
        return restored
    }

    private func performFullWrite(_ text: String, target: CapturedTarget,
                                  application: ExternalApplication, beforeText: String,
                                  contextID: String?, operationCaptureID: UUID) async throws -> FullInputState {
        var verified = false
        defer {
            access.finishWrite(verified: verified)
            controlledSelection = nil
        }
        let paste = access.requiresPaste(target.input)
        func validateOriginal(requireSelection: Bool) throws -> FullInputState {
            guard !Task.isCancelled else { throw FillError.cancelled }
            try requireCurrentReplacementCapabilities(target, application: application)
            guard operationCaptureID == captureID, !replacementExternalChange,
                  let current = try? readFullState(target.input, window: target.window,
                      applicationElement: target.applicationElement, application: application),
                  current.text == beforeText, contextsMatch(current.contextID, contextID) else {
                throw FillError.targetChanged
            }
            if requireSelection {
                guard (try? selectedRange(target.input)) == controlledSelection else { throw FillError.selectionUnavailable }
            }
            // Last native reads at the submit boundary. An unchanged retained input
            // cannot authorize a key event to a different currently focused control.
            do {
                try validateFocusedIdentity(target.applicationElement, window: target.window,
                    input: target.input, application: application)
            } catch { throw FillError.targetChanged }
            guard !Task.isCancelled else { throw FillError.cancelled }
            return current
        }
        if text == beforeText {
            // Identical text is not evidence that an asynchronous paste was consumed.
            // Complete without a setter, V event, selection change or clipboard takeover.
            return try validateOriginal(requireSelection: false)
        }
        if paste {
            controlledSelection = NSRange(location: 0, length: (beforeText as NSString).length)
            try await access.selectAll(in: target.input, count: controlledSelection!.length)
            let deadline = Date().addingTimeInterval(0.6)
            while (try? selectedRange(target.input)) != controlledSelection {
                try validateWritableReplacementTarget(target, application: application)
                guard !Task.isCancelled else { throw FillError.cancelled }
                guard !replacementExternalChange, operationCaptureID == captureID,
                      Date() < deadline else { throw FillError.selectionUnavailable }
                try await Task.sleep(for: .milliseconds(15))
            }
        }
        try access.prepareWrite(text, to: target.input)
        replacementActivity = .writing
        observedWrittenText = false
        do {
            try access.writeFullText(text, to: target.input) {
                _ = try validateOriginal(requireSelection: paste)
            }
        } catch {
            if writeIssued { throw FillError.outcomeUnknown }
            if let error = error as? FillError { throw error }
            throw FillError.notEditable
        }
        replacementActivity = .verifying
        onReplacementStage?(.verifying)
        let final = try await verifyFullWrite(target, application: application, text: text,
            contextID: contextID, operationCaptureID: operationCaptureID)
        verified = true
        return final
    }

    /// Electron can deliver the activation/selection/value events after the AX
    /// setter returns. Observe the same target until text, focus and revision settle;
    /// never issue another write while waiting, including after cancellation.
    private func verifyFullWrite(_ target: CapturedTarget, application: ExternalApplication,
                                 text: String, contextID: String?,
                                 operationCaptureID: UUID) async throws -> FullInputState {
        let deadline = Date().addingTimeInterval(0.8)
        var stableSince: Date?
        var stableRevision: UInt64?
        var selectedForVerification = false
        repeat {
            checkWriteSurface()
            guard !replacementExternalChange, captureID == operationCaptureID else { throw FillError.outcomeUnknown }
            let current: (text: String, contextID: String?)?
            do {
                try validateFocusedIdentity(target.applicationElement, window: target.window,
                    input: target.input, application: application)
                if !selectedForVerification, (try? readFullText(target.input)) == nil,
                   let count = try? attribute(target.input, .characterCount, optional: true) as? NSNumber,
                   count.intValue == (text as NSString).length {
                    selectedForVerification = true
                    try await access.selectAll(in: target.input, count: count.intValue)
                }
                current = (try readFullText(target.input),
                           try? access.contextID(window: target.window, input: target.input))
            } catch ExternalInputError.unsupportedApplication {
                throw FillError.outcomeUnknown
            } catch ExternalInputError.noFocusedInput {
                // A known different app/window/input is not transient unavailability.
                throw FillError.outcomeUnknown
            } catch { current = nil }
            if let current {
                guard contextsMatch(current.contextID, contextID) else { throw FillError.outcomeUnknown }
                if current.text == text {
                    observedWrittenText = true
                    if stableRevision != revision {
                        stableRevision = revision
                        stableSince = Date()
                    }
                    if let stableSince, Date().timeIntervalSince(stableSince) >= 0.05,
                       let host = capturedHost {
                        let capabilities = access.replacementCapabilities(application: application,
                            window: target.window, input: target.input, host: host)
                        guard capabilities.approved, capabilities.protectedContent == false,
                              let final = try? readFullState(target.input, window: target.window,
                                  applicationElement: target.applicationElement, application: application),
                              final.text == text, contextsMatch(final.contextID, contextID),
                              stableRevision == revision, !replacementExternalChange,
                              operationCaptureID == captureID, Date() < deadline else { throw FillError.outcomeUnknown }
                        lastReadFailure = nil
                        return final
                    }
                } else {
                    guard !observedWrittenText, current.text == replacementBeforeText else { throw FillError.outcomeUnknown }
                    stableSince = nil
                    stableRevision = nil
                }
            } else {
                // A transiently unreadable focused element is pending, not success.
                stableSince = nil
                stableRevision = nil
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { continuation.resume() }
            }
        } while Date() < deadline
        throw FillError.outcomeUnknown
    }

    /// A capture-time approval cannot authorize a later write if the current object
    /// state becomes unknown during focus handoff. Recovery is a new write
    /// and must pass exactly the same current-state gate.
    private func requireCurrentReplacementCapabilities(_ target: CapturedTarget,
                                                       application: ExternalApplication) throws {
        guard let host = capturedHost else { throw FillError.targetChanged }
        try validateWritableReplacementTarget(target, application: application)
        let capabilities = access.replacementCapabilities(application: application, window: target.window,
                                                           input: target.input, host: host)
        if capabilities.protectedContent == true || (try? readFullText(target.input))?.contains("\u{fffc}") == true {
            throw FillError.protectedContent
        }
        guard capabilities.protectedContent == false, capabilities.approved else {
            throw FillError.notEditable
        }
    }

    /// A rejection before issuing the setter is a known block, not an unknown write.
    /// Recheck after callbacks as well as at the shared capability gate.
    private func validateWritableReplacementTarget(_ target: CapturedTarget,
                                                    application: ExternalApplication) throws {
        do {
            try validateFocusedIdentity(target.applicationElement, window: target.window,
                input: target.input, application: application)
        } catch { throw FillError.targetChanged }
        guard let host = capturedHost else { throw FillError.targetChanged }
        do { try validateInputRole(target.input, host: host) }
        catch { throw FillError.notEditable }
        do { try requireNoComposition(target.input) }
        catch ExternalInputError.compositionActive { throw FillError.compositionActive }
        catch { throw FillError.notEditable }
        guard access.isEditable(target.input) else { throw FillError.notEditable }
    }

    private func invalidateTarget(preserveRestore: Bool = false) {
        panelContextMenuDepth = 0
        panelContextMenuCaptureID = nil
        guard target != nil else { return }
        // Release captured text and stop all AX reads as soon as any target change is detected.
        target = nil
        captureID = UUID()
        panelActivationDeadline = nil
        revision += 1
        observations?.stop()
        observations = nil
        captureScope = nil
        captureExpectedRange = nil
        captureEventRejected = false
        captureSelectionConfirmed = false
        panelActivationDeadline = nil
        panelActivationCaptureID = nil
        if replacementInFlight { replacementExternalChange = true }
        if !preserveRestore { discardRestoreRecord() }
        updateFrame(nil)
        onChange?()
    }

    private func discardRestoreRecord() {
        confirmedTarget = nil
        confirmedReceipt = nil
        originalForRestore = nil
    }

    /// Returns false before an AX read if the user has switched to any other external application.
    private func surfaceIsAllowed() -> Bool {
        guard access.hasPermission, let application = capturedApplication,
              access.isRunning(application), let frontmost = access.frontmost() else { return false }
        return frontmost == application || isOwnApplication(frontmost)
    }

    func prepareForPanelActivation(captureToken: UUID? = nil) {
        guard target != nil || hasRestoreRecord else { return }
        let currentToken = target?.snapshot.captureID ?? confirmedTarget?.snapshot.captureID
        guard captureToken == nil || captureToken == currentToken else { return }
        panelActivationCaptureID = currentToken
        panelActivationDeadline = Date().addingTimeInterval(1)
    }

    func endPanelActivation(captureToken: UUID) {
        guard panelActivationCaptureID == captureToken else { return }
        panelActivationCaptureID = nil
        panelActivationDeadline = nil
    }

    /// Paired with the actual native menu dispatch, including nested menus. A menu
    /// can temporarily remove the host's focused input without activating our app.
    @discardableResult func beginPanelContextMenu(captureToken: UUID? = nil) -> Bool {
        guard !replacementInFlight, surfaceIsAllowed(),
              target != nil || (confirmedReceipt != nil && confirmedTarget != nil) else { return false }
        let currentToken = target?.snapshot.captureID ?? confirmedTarget?.snapshot.captureID
        guard captureToken == nil || captureToken == currentToken else { return false }
        if panelContextMenuDepth == 0 {
            panelContextMenuCaptureID = currentToken
        } else if panelContextMenuCaptureID != currentToken {
            return false
        }
        panelContextMenuDepth += 1
        return true
    }

    func endPanelContextMenu() {
        guard panelContextMenuDepth > 0 else { return }
        panelContextMenuDepth -= 1
        if panelContextMenuDepth == 0 {
            panelContextMenuCaptureID = nil
            prepareForPanelActivation(captureToken: target?.snapshot.captureID ?? confirmedTarget?.snapshot.captureID)
        }
    }

    func endPanelContextMenu(captureToken: UUID) {
        guard panelContextMenuCaptureID == captureToken else { return }
        endPanelContextMenu()
    }

    private func isOwnApplication(_ application: ExternalApplication?) -> Bool {
        guard let application else { return false }
        let own = access.ownApplication
        return application.pid == own.pid && application.bundle == own.bundle
    }

    private func isOwnActivationHandoff() -> Bool {
        let frontmost = access.frontmost()
        if isOwnApplication(frontmost) { return true }
        let currentToken = target?.snapshot.captureID ?? confirmedTarget?.snapshot.captureID
        let panelHandoff = panelActivationDeadline.map { Date() < $0 } == true
            && panelActivationCaptureID == currentToken
        let menuHandoff = panelContextMenuDepth > 0 && panelContextMenuCaptureID == currentToken
        return (target != nil || confirmedTarget != nil) && frontmost == capturedApplication
            && (focusHandoffInProgress || menuHandoff || panelHandoff)
    }

    /// Missing focus is tolerated only during our own handoff. Check each readable
    /// identity immediately so a later unavailable attribute cannot hide a mismatch.
    private func validateRetainedTargetIdentity(_ target: CapturedTarget,
                                                application: ExternalApplication) throws {
        let frontmost = access.frontmost()
        guard frontmost == application || isOwnApplication(frontmost) else {
            throw ExternalInputError.unsupportedApplication
        }
        if panelContextMenuDepth == 0,
           isOwnApplication(frontmost) || focusHandoffInProgress { return }
        for (attribute, expected) in [(ExternalAttribute.focusedWindow, target.window),
                                       (.focusedInput, target.input)] {
            let current: AXUIElement
            do { current = try elementAttribute(target.applicationElement, attribute) }
            catch {
                guard isOwnActivationHandoff() else { throw error }
                lastReadFailure = nil
                continue
            }
            guard CFEqual(current, expected) else { throw ExternalInputError.noFocusedInput }
        }
    }

    @discardableResult private func validateTarget() -> Bool {
        guard let target else { return false }
        guard surfaceIsAllowed(), let application = capturedApplication, let host = capturedHost else {
            invalidateTarget()
            return false
        }
        do {
            try validateRetainedTargetIdentity(target, application: application)
            if target.snapshot.captureScope == .entireInput {
                let current = try readFullState(target.input, window: target.window,
                                                applicationElement: target.applicationElement,
                                                application: application,
                                                requireFocus: !isOwnActivationHandoff())
                guard current.text == target.snapshot.fullText,
                      contextsMatch(current.contextID, target.snapshot.contextID) else {
                    invalidateTarget()
                    return false
                }
                guard (confirmedReceipt == nil && isOwnActivationHandoff()) || current.selection == target.snapshot.selection else {
                    // Selection can collapse while opening the panel. It invalidates
                    // the capture, but a verified text receipt can still be restored.
                    if confirmedReceipt != nil { handlePostReceiptMutation() }
                    else { invalidateTarget() }
                    return false
                }
            } else {
                let current = try readSelection(target.input, host: host)
                guard current.range == target.snapshot.selection,
                      current.text == target.snapshot.selectedText else {
                    invalidateTarget()
                    return false
                }
            }
            updateFrame(try readFrame(target.input))
            return true
        } catch {
            invalidateTarget()
            return false
        }
    }

    private func receive(_ notification: String) {
        if notification != "poll" { revision &+= 1 }
        if captureScope == .entireInput, target == nil, restorationTarget == nil {
            onObservedChange?(notification)
            switch notification {
            case kAXSelectedTextChangedNotification:
                let expected = captureExpectedRange
                guard let expected,
                      let target = try? pendingInputElement(),
                      (try? selectedRange(target)) == expected else {
                    captureEventRejected = true
                    return
                }
                captureSelectionConfirmed = true
            case kAXValueChangedNotification, kAXFocusedWindowChangedNotification,
                 kAXFocusedUIElementChangedNotification, kAXUIElementDestroyedNotification,
                 kAXMovedNotification, kAXResizedNotification, "workspace":
                captureEventRejected = true
            default:
                break
            }
            return
        }
        guard target != nil || restorationTarget != nil else { return }
        onObservedChange?(notification)
        if replacementInFlight {
            switch notification {
            case kAXValueChangedNotification, kAXSelectedTextChangedNotification:
                handleReplacementMutation(notification)
                return
            case kAXUIElementDestroyedNotification:
                replacementExternalChange = true
                return
            case kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
                 kAXMovedNotification, kAXResizedNotification,
                 "workspace":
                if focusHandoffInProgress { return }
                if writeIssued { checkWriteSurface() }
                else { replacementExternalChange = true }
                return
            case "poll":
                handleReplacementPoll()
                return
            default:
                replacementExternalChange = true
                return
            }
        }
        switch notification {
        case kAXValueChangedNotification, kAXSelectedTextChangedNotification, kAXUIElementDestroyedNotification:
            if notification == kAXSelectedTextChangedNotification, confirmedReceipt == nil,
               target?.snapshot.captureScope == .entireInput, isOwnActivationHandoff() {
                // Native editors can collapse selection when our preview becomes key.
                // Full draft authorization is still tied to the live text and control.
                validateTarget()
                return
            }
            if confirmedReceipt != nil, notification != kAXUIElementDestroyedNotification {
                handlePostReceiptMutation()
                return
            }
            // Invalidate on the event, even if A -> B -> A has restored the old value by now.
            invalidateTarget()
        case kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification:
            if panelContextMenuDepth > 0 {
                validateTarget()
                return
            }
            if isOwnActivationHandoff() { return }
            invalidateTarget()
        case kAXMovedNotification, kAXResizedNotification:
            guard surfaceIsAllowed(), let target else {
                invalidateTarget()
                return
            }
            do { updateFrame(try readFrame(target.input)) }
            catch { invalidateTarget() }
        case "workspace", "poll": validateTarget()
        default: break
        }
    }

    private func handlePostReceiptMutation() {
        guard let receipt = confirmedReceipt, let original = originalForRestore,
              let target = confirmedTarget, let application = capturedApplication,
              access.isRunning(application), surfaceIsAllowed() else {
            discardRestoreRecord()
            invalidateTarget()
            return
        }
        do {
            try validateRetainedTargetIdentity(target, application: application)
            let text = try readFullText(target.input)
            let contextID = try? access.contextID(window: target.window, input: target.input)
            guard text == receipt.writtenText, contextsMatch(contextID, original.contextID) else {
                throw ExternalInputError.invalidSelection
            }
        } catch {
            discardRestoreRecord()
            invalidateTarget()
            return
        }
        // The notification was delivered after the verified receipt. Keep the
        // recovery record, but do not revive the captured target or ignore future
        // changes; explicit restore rechecks the saved references and current focus.
        invalidateTarget(preserveRestore: true)
    }

    private func handleReplacementMutation(_ notification: String) {
        guard let target = target ?? restorationTarget else {
            replacementExternalChange = true
            return
        }
        if !writeIssued, notification == kAXSelectedTextChangedNotification,
           let controlledSelection, (try? selectedRange(target.input)) == controlledSelection,
           (try? readFullText(target.input)) == replacementBeforeText { return }
        guard writeIssued,
              (replacementActivity == .writing || replacementActivity == .verifying) else {
            replacementExternalChange = true
            return
        }
        checkWriteSurface()
        guard !replacementExternalChange else { return }
        guard let currentText = try? readFullText(target.input) else { return }
        let contextID = try? access.contextID(window: target.window, input: target.input)
        if notification == kAXSelectedTextChangedNotification, !observedWrittenText,
           let controlledSelection, currentText == replacementBeforeText,
           (try? selectedRange(target.input)) == controlledSelection,
           contextsMatch(contextID, replacementExpectedContext) {
            // A queued full-selection event can arrive before asynchronous paste
            // consumption. It is pending only while the entire original is selected.
            return
        }
        guard currentText == replacementExpectedText,
              contextsMatch(contextID, replacementExpectedContext) else {
            replacementExternalChange = true
            return
        }
        observedWrittenText = true
        // Expected value/selection events are reconciled while the single command
        // settles. verifyFullWrite still requires a quiet revision and strict focus.
        // This does not promise atomic detection of an unobserved cross-process ABA.
    }

    private func checkWriteSurface() {
        guard let target = target ?? restorationTarget, let application = capturedApplication,
              access.isRunning(application), access.frontmost() == application else {
            replacementExternalChange = true
            return
        }
        if let window = try? elementAttribute(target.applicationElement, .focusedWindow), !CFEqual(window, target.window) {
            replacementExternalChange = true
        }
        if let input = try? elementAttribute(target.applicationElement, .focusedInput), !CFEqual(input, target.input) {
            replacementExternalChange = true
        }
    }

    private func handleReplacementPoll() {
        if writeIssued {
            // The 25ms writer verification loop owns text/focus settling now.
            checkWriteSurface()
            return
        }
        guard !focusHandoffInProgress,
              let target = target ?? restorationTarget, let application = capturedApplication,
              targetIsFocused(target, application: application),
              let expectedText = writeIssued ? replacementExpectedText : replacementBeforeText,
              let current = try? readFullState(target.input, window: target.window,
                                                applicationElement: target.applicationElement,
                                                application: application),
              current.text == expectedText, contextsMatch(current.contextID, replacementExpectedContext) else {
            if !focusHandoffInProgress { replacementExternalChange = true }
            return
        }
    }

    private func pendingInputElement() throws -> AXUIElement {
        guard let pendingInput else { throw ExternalInputError.unavailable }
        return pendingInput
    }

    private func updateFrame(_ frame: NSRect?) {
        guard frameOnScreen != frame else { return }
        frameOnScreen = frame
        onGeometryChange?()
    }

    private struct FullInputState {
        let text: String
        let characterCount: Int
        let selection: NSRange
        let selectedText: String
        let contextID: String?
    }

    private func requireNoComposition(_ input: AXUIElement) throws {
        // Only an exposed active marked range blocks the operation. Absence is
        // not a capability gate for applications that do not publish IME metadata.
        guard let raw = try attribute(input, .markedRange, optional: true) else { return }
        guard CFGetTypeID(raw) == AXValueGetTypeID() else { throw ExternalInputError.unavailable }
        let value = unsafeDowncast(raw, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &range) else {
            throw ExternalInputError.unavailable
        }
        if range.location >= 0 && range.location != NSNotFound && range.length > 0 {
            throw ExternalInputError.compositionActive
        }
    }

    private func validateInputRole(_ input: AXUIElement, host: Host) throws {
        guard let role = try attribute(input, .role) as? String else {
            throw ExternalInputError.noFocusedInput
        }
        let rawSubrole = try attribute(input, .subrole, optional: true)
        if let rawSubrole, !(rawSubrole is String) { throw ExternalInputError.unavailable }
        let subrole = rawSubrole as? String
        guard role != kAXSecureTextFieldSubrole, subrole != kAXSecureTextFieldSubrole else {
            throw ExternalInputError.secureInput
        }
        guard role == kAXTextAreaRole || role == kAXTextFieldRole else {
            throw ExternalInputError.noFocusedInput
        }
    }

    private func validateFocusedIdentity(_ applicationElement: AXUIElement, window: AXUIElement,
                                         input: AXUIElement,
                                         application: ExternalApplication) throws {
        guard access.frontmost() == application else { throw ExternalInputError.unsupportedApplication }
        let focusedWindow = try elementAttribute(applicationElement, .focusedWindow)
        let focusedInput = try elementAttribute(applicationElement, .focusedInput)
        guard CFEqual(window, focusedWindow), CFEqual(input, focusedInput),
              access.owner(window) == application.pid, access.owner(input) == application.pid else {
            throw ExternalInputError.noFocusedInput
        }
    }

    /// Optional metadata can detect a known change; absence is not a prerequisite
    /// failure for the user's manual replacement flow.
    private func contextsMatch(_ current: String?, _ expected: String?) -> Bool {
        guard let current, let expected else { return true }
        return current == expected
    }

    private func readFullState(_ input: AXUIElement, window: AXUIElement,
                               applicationElement: AXUIElement,
                               application: ExternalApplication,
                               requireFocus: Bool = true) throws -> FullInputState {
        if requireFocus {
            try validateFocusedIdentity(applicationElement, window: window, input: input,
                                        application: application)
        }
        let text = try readFullText(input)
        let count = (text as NSString).length
        let selected = (try? selectedRange(input)) ?? NSRange(location: 0, length: 0)
        guard selected.location <= count, selected.length <= count - selected.location else {
            throw ExternalInputError.invalidSelection
        }
        let selectedText = (text as NSString).substring(with: selected)
        // Optional metadata strengthens change detection when exposed. A missing or
        // unreadable document must not block the user's manual replacement contract.
        let contextID = try? access.contextID(window: window, input: input)
        return FullInputState(text: text, characterCount: count, selection: selected,
                              selectedText: selectedText, contextID: contextID)
    }

    /// Text observations during an issued write must not discard an observed edit
    /// just because the selection range has not caught up with its new length yet.
    private func readFullText(_ input: AXUIElement) throws -> String {
        guard let application = capturedApplication ?? access.frontmost(),
              access.isRunning(application) else { throw ExternalInputError.unavailable }
        try requireProcess(input, application.pid)
        try validateInputRole(input, host: Host.matching(application))
        let count = (try? attribute(input, .characterCount, optional: true) as? NSNumber)?.intValue
        if let count, count >= 0,
           let text = try? access.string(input, for: CFRange(location: 0, length: count)),
           (text as NSString).length == count { return text }
        if let text = try attribute(input, .value, optional: true) as? String {
            // A reported count and value must describe the same complete text.
            guard count == nil || count == (text as NSString).length else { throw ExternalInputError.invalidSelection }
            return text
        }
        if let count, count >= 0,
           (try? selectedRange(input)) == NSRange(location: 0, length: count),
           let text = try attribute(input, .selectedText, optional: true) as? String,
           (text as NSString).length == count { return text }
        throw ExternalInputError.invalidSelection
    }

    private func selectedRange(_ input: AXUIElement) throws -> NSRange {
        guard let rawRange = try attribute(input, .selectedRange),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else {
            throw ExternalInputError.invalidSelection
        }
        let axRange = unsafeDowncast(rawRange, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axRange) == .cfRange,
              AXValueGetValue(axRange, .cfRange, &range), range.location >= 0,
              range.length >= 0 else { throw ExternalInputError.invalidSelection }
        return NSRange(location: range.location, length: range.length)
    }

    private func targetIsFocused(_ target: CapturedTarget, application: ExternalApplication) -> Bool {
        guard access.frontmost() == application else { return false }
        do {
            let focusedWindow = try elementAttribute(target.applicationElement, .focusedWindow)
            let focusedInput = try elementAttribute(target.applicationElement, .focusedInput)
            return CFEqual(focusedWindow, target.window) && CFEqual(focusedInput, target.input)
        } catch { return false }
    }

    private func focusTarget(_ target: CapturedTarget,
                             application: ExternalApplication) async throws {
        if targetIsFocused(target, application: application) { return }
        do { try await access.focus(window: target.window, input: target.input) }
        catch { throw FillError.targetChanged }
        let deadline = Date().addingTimeInterval(0.8)
        repeat {
            guard access.frontmost() == application else { throw FillError.targetChanged }
            do {
                let focusedWindow = try elementAttribute(target.applicationElement, .focusedWindow)
                let focusedInput = try elementAttribute(target.applicationElement, .focusedInput)
                if CFEqual(focusedWindow, target.window), CFEqual(focusedInput, target.input) { return }
            } catch {
                if Date() >= deadline { throw FillError.targetChanged }
            }
            do { try await Task.sleep(for: .milliseconds(25)) }
            catch { throw FillError.cancelled }
        } while Date() < deadline
        throw FillError.targetChanged
    }

    private func readSelection(_ input: AXUIElement, host: Host) throws -> SelectionState {
        // Static text, web areas, and arbitrary containers could expose conversation history.
        try validateInputRole(input, host: host)
        guard access.isEditable(input) else { throw ExternalInputError.noFocusedInput }
        guard let selectedText = try attribute(input, .selectedText) as? String,
              let rawRange = try attribute(input, .selectedRange),
              CFGetTypeID(rawRange) == AXValueGetTypeID() else {
            throw ExternalInputError.invalidSelection
        }
        let axRange = unsafeDowncast(rawRange, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axRange) == .cfRange, AXValueGetValue(axRange, .cfRange, &range) else {
            throw ExternalInputError.invalidSelection
        }
        guard range.length > 0, !selectedText.isEmpty else { throw ExternalInputError.noSelection }
        guard range.location >= 0, range.length <= Int.max - range.location,
              (selectedText as NSString).length == range.length else {
            throw ExternalInputError.invalidSelection
        }
        let nsRange = NSRange(location: range.location, length: range.length)
        if let total = try attribute(input, .characterCount, optional: true) as? NSNumber {
            guard range.location <= total.intValue, range.length <= total.intValue - range.location else {
                throw ExternalInputError.invalidSelection
            }
        }
        // Read only the selected range, never the full draft or surrounding conversation.
        guard try access.string(input, for: range) == selectedText else { throw ExternalInputError.invalidSelection }
        return SelectionState(range: nsRange, text: selectedText)
    }

    private func readFrame(_ input: AXUIElement) throws -> NSRect? {
        guard let positionValue = try attribute(input, .position, optional: true),
              let sizeValue = try attribute(input, .size, optional: true) else { return nil }
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            throw ExternalInputError.unavailable
        }
        let axPosition = unsafeDowncast(positionValue, to: AXValue.self)
        let axSize = unsafeDowncast(sizeValue, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetType(axPosition) == .cgPoint, AXValueGetValue(axPosition, .cgPoint, &position),
              AXValueGetType(axSize) == .cgSize, AXValueGetValue(axSize, .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, let primaryScreen = NSScreen.screens.first else { return nil }
        return NSRect(x: position.x, y: primaryScreen.frame.maxY - position.y - size.height,
                      width: size.width, height: size.height)
    }

    private func attribute(_ element: AXUIElement, _ name: ExternalAttribute, optional: Bool = false) throws -> CFTypeRef? {
        do { return try access.read(element, name, optional: optional) }
        catch { lastReadFailure = name; throw error }
    }

    private func elementAttribute(_ element: AXUIElement, _ name: ExternalAttribute) throws -> AXUIElement {
        guard let value = try attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw ExternalInputError.noFocusedInput
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func requireProcess(_ element: AXUIElement, _ expected: pid_t) throws {
        guard access.owner(element) == expected else { throw ExternalInputError.noFocusedInput }
    }
}
