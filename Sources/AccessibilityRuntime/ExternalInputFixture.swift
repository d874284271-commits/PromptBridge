import AppKit
import ApplicationServices
import AccessibilityContracts

/// Used only by the explicitly launched UI acceptance runner. No OS AX reads or writes.
@MainActor final class ExternalInputFixture: ExternalInputAccess {
    var hasPermission = true
    var application = ExternalApplication(pid: 7, bundle: CodexCapabilityProbe.bundleIdentifier,
        version: CodexCapabilityProbe.version, build: CodexCapabilityProbe.build)
    var ownApplication: ExternalApplication {
        ExternalApplication(pid: 700, bundle: "fixture.promptbridge.client",
            version: "fixture", build: "fixture")
    }
    var foreground: ExternalApplication?
    var running = true
    var role = "AXTextArea"
    var secure = false
    var composing = false
    var subroleUnreadable = false
    var subroleWrongType = false
    var editable = true
    var valueReadable = false
    var selectionAvailable = true
    var selectionSettable = true
    var pasteRequired = false
    var prepareWriteError: FillError?
    var beforeCommit: (() -> Void)?
    private(set) var prepareWriteCount = 0
    var verifiedClipboardCompletion: Bool?
    var foreignInput = false
    var focusedInputChanged = false
    var focusReadHandoff: ExternalApplication?
    var focusReadFailureAt = 2
    var focusReadFailsWithoutHandoff = false
    var focusedInputUnavailable = false
    var focusedWindowUnavailable = false
    var notificationsSupported = true
    var text = "请保留 ./src/登录.ts 和按钮“确认删除” 😀。"
    /// Optional complete draft used by the full-input path. When nil, `text` is used.
    var fullDraft: String?
    var charCount: Int?
    var contextID: String? = "fixture-context"
    var contextReadFails = false
    var replacementApproved = false
    var protectedContentStateKnown = true
    var protectedContent = false
    var focusAccepted = true
    var emitSelectionEvents = true
    var selectionCommitDelayMilliseconds = 0
    var selectionNotificationDelayMilliseconds = 0
    var selectionWriteApplies = true
    var writeApplies = true
    var pasteCommitDelayMilliseconds = 0
    var writeFailsAfterSetter = false
    var writeNotificationDelayMilliseconds = 0
    var mutateOnFocus: String?
    var onFocus: (@MainActor () -> Void)?
    var contextChangesOnWrite: String?
    var focusChangesInput = false
    var focusChangesWindow = false
    private(set) var writeCount = 0
    private(set) var writtenTexts: [String] = []
    var range = CFRange(location: 11, length: 0)
    var rangeText: String?
    var rangeReadUnavailable = false
    var activationAccepted = true
    var activationChangesFrontmost = true
    var activationNeedsInputFocus = false
    var exitsOnActivation = false
    private(set) var activationCount = 0
    private(set) var appElementReads = 0
    private(set) var reads: [ExternalAttribute] = []
    private(set) var rangeReads = 0
    private(set) var selectionEventsRequired = false
    var onSetterIssued: (() -> Void)?
    private var receiver: (@MainActor (String) -> Void)?
    private var observationID: UUID?
    private var focusReads = 0
    private let appElement = AXUIElementCreateApplication(700)
    private let window = AXUIElementCreateApplication(701)
    private let input = AXUIElementCreateApplication(702)
    private let otherInput = AXUIElementCreateApplication(703)
    private let otherWindow = AXUIElementCreateApplication(704)

    init() {
        foreground = application
        range.length = (text as NSString).length
    }
    private var draft: String { fullDraft ?? text }
    func frontmost() -> ExternalApplication? { foreground }
    func isRunning(_ application: ExternalApplication) -> Bool { running && application == self.application }
    func applicationElement(_ application: ExternalApplication) -> AXUIElement {
        appElementReads += 1
        return appElement
    }
    func owner(_ element: AXUIElement) -> pid_t? { foreignInput && CFEqual(element, input) ? 8 : application.pid }
    func read(_ element: AXUIElement, _ attribute: ExternalAttribute, optional: Bool) throws -> CFTypeRef? {
        reads.append(attribute)
        switch attribute {
        case .focusedWindow:
            if focusedWindowUnavailable { throw ExternalInputError.unavailable }
            return focusChangesWindow ? otherWindow : window
        case .focusedInput:
            focusReads += 1
            if focusedInputUnavailable { throw ExternalInputError.unavailable }
            if focusReads == focusReadFailureAt, focusReadHandoff != nil || focusReadFailsWithoutHandoff {
                if let focusReadHandoff { foreground = focusReadHandoff }
                throw ExternalInputError.unavailable
            }
            return (focusedInputChanged || focusChangesInput) ? otherInput : input
        case .role: return role as CFString
        case .subrole:
            if subroleUnreadable { throw ExternalInputError.unavailable }
            if subroleWrongType { return NSNumber(value: 1) }
            return secure ? "AXSecureTextField" as CFString : nil
        case .selectedText:
            if fullDraft == nil && charCount == nil { return text as CFString }
            let ns = draft as NSString
            guard range.location >= 0, range.location <= ns.length,
                  range.length >= 0, range.length <= ns.length - range.location else {
                return "" as CFString
            }
            return ns.substring(with: NSRange(location: range.location, length: range.length)) as CFString
        case .markedRange:
            guard composing else { return nil }
            var marked = CFRange(location: 0, length: 1)
            return AXValueCreate(.cfRange, &marked)
        case .value: return valueReadable ? draft as CFString : nil
        case .selectedRange:
            if !selectionAvailable { return nil }
            var value = range
            return AXValueCreate(.cfRange, &value)
        case .characterCount:
            if fullDraft != nil || charCount != nil { return NSNumber(value: charCount ?? (draft as NSString).length) }
            return NSNumber(value: range.location + range.length + 20)
        case .position, .size: return nil
        case .main: return true as CFBoolean
        case .document: return contextID as CFString?
        }
    }
    func canSetSelectedRange(_ input: AXUIElement) -> Bool { selectionSettable }
    func requiresPaste(_ input: AXUIElement) -> Bool { pasteRequired }
    func prepareWrite(_ text: String, to input: AXUIElement) throws { prepareWriteCount += 1; if let prepareWriteError { throw prepareWriteError } }
    func finishWrite(verified: Bool) { verifiedClipboardCompletion = verified }
    func isEditable(_ element: AXUIElement) -> Bool { editable }
    func string(_ element: AXUIElement, for range: CFRange) throws -> String {
        rangeReads += 1
        if rangeReadUnavailable { throw ExternalInputError.invalidSelection }
        if let rangeText { return rangeText }
        if fullDraft == nil && charCount == nil { return text }
        let ns = draft as NSString
        guard range.location >= 0, range.length >= 0,
              range.location <= ns.length, range.length <= ns.length - range.location else {
            throw ExternalInputError.invalidSelection
        }
        return ns.substring(with: NSRange(location: range.location, length: range.length))
    }
    func contextID(window: AXUIElement, input: AXUIElement) throws -> String? {
        if contextReadFails { throw ExternalInputError.unavailable }
        return contextID
    }
    func replacementCapabilities(application: ExternalApplication, window: AXUIElement,
                                 input: AXUIElement, host: ExternalInput.Host) -> ExternalReplacementCapabilities {
        ExternalReplacementCapabilities(contextCandidatePresent: contextID != nil,
            approved: replacementApproved && !protectedContent,
            protectedContent: protectedContentStateKnown ? protectedContent : nil,
            explanation: replacementApproved ? "fixture approved" : "fixture replacement disabled")
    }
    func focus(window: AXUIElement, input: AXUIElement) async throws {
        guard focusAccepted else { throw ExternalInputError.unavailable }
        foreground = application
        if activationNeedsInputFocus { focusChangesInput = false }
        onFocus?()
        if let mutateOnFocus {
            fullDraft = mutateOnFocus
            self.mutateOnFocus = nil
            receiver?(kAXValueChangedNotification)
        }
    }
    func setSelectedRange(_ range: CFRange, in input: AXUIElement) throws {
        guard range.location >= 0, range.length >= 0,
              range.location <= (draft as NSString).length,
              range.length <= (draft as NSString).length - range.location else {
            throw ExternalInputError.invalidSelection
        }
        guard selectionWriteApplies else { return }
        if selectionCommitDelayMilliseconds > 0 {
            let delay = selectionCommitDelayMilliseconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self else { return }
                self.range = range
                self.notifySelectionChange()
            }
        } else {
            self.range = range
            notifySelectionChange()
        }
    }
    private func notifySelectionChange() {
        guard emitSelectionEvents else { return }
        if selectionNotificationDelayMilliseconds > 0 {
            let delay = selectionNotificationDelayMilliseconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                self?.receiver?(kAXSelectedTextChangedNotification)
            }
        } else { receiver?(kAXSelectedTextChangedNotification) }
    }
    func writeFullText(_ text: String, to input: AXUIElement, validate: () throws -> Void) throws {
        guard editable, replacementApproved else { throw ExternalInputError.noFocusedInput }
        beforeCommit?()
        try validate()
        onSetterIssued?()
        writeCount += 1
        writtenTexts.append(text)
        if writeFailsAfterSetter { throw ExternalInputError.unavailable }
        guard writeApplies else { return }
        if let contextChangesOnWrite {
            contextID = contextChangesOnWrite
            self.contextChangesOnWrite = nil
        }
        if pasteCommitDelayMilliseconds > 0 {
            receiver?(kAXSelectedTextChangedNotification)
            let delay = pasteCommitDelayMilliseconds
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self else { return }
                self.fullDraft = text
                self.text = text
                self.range = CFRange(location: (text as NSString).length, length: 0)
                self.receiver?(kAXValueChangedNotification)
            }
            return
        }
        fullDraft = text
        self.text = text
        range = CFRange(location: 0, length: (text as NSString).length)
        if writeNotificationDelayMilliseconds > 0 {
            let delay = writeNotificationDelayMilliseconds
            let receive = receiver
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(delay))
                receive?(kAXSelectedTextChangedNotification)
                receive?(kAXValueChangedNotification)
                receive?("workspace")
                receive?(kAXFocusedUIElementChangedNotification)
            }
        } else { receiver?(kAXValueChangedNotification) }
    }
    func observe(application: AXUIElement, window: AXUIElement, input: AXUIElement,
                 pid: pid_t, requireSelectionEvents: Bool,
                 receive: @escaping @MainActor (String) -> Void) throws -> any ExternalObservation {
        selectionEventsRequired = requireSelectionEvents
        if requireSelectionEvents && !notificationsSupported { throw ExternalInputError.monitoringUnavailable }
        let id = UUID()
        observationID = id
        receiver = receive
        return FixtureObservation { [weak self] in
            guard let self, self.observationID == id else { return }
            self.receiver = nil
            self.observationID = nil
        }
    }
    func emit(_ notification: String) { receiver?(notification) }
    func queuedEvent(_ notification: String) -> @MainActor () -> Void {
        let callback = receiver
        return { callback?(notification) }
    }
    func activate(_ application: ExternalApplication) -> Bool {
        activationCount += 1
        if exitsOnActivation { running = false }
        if activationAccepted && activationChangesFrontmost {
            foreground = application
            if activationNeedsInputFocus {
                focusChangesInput = true
                receiver?("workspace")
            }
        }
        return activationAccepted
    }
}

@MainActor private final class FixtureObservation: ExternalObservation {
    private let cleanup: @MainActor () -> Void
    init(cleanup: @escaping @MainActor () -> Void) { self.cleanup = cleanup }
    func stop() { cleanup() }
}
