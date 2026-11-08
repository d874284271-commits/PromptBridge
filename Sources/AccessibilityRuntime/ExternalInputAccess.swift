import AppKit
import ApplicationServices
import AccessibilityContracts

struct ExternalApplication: Equatable {
    let pid: pid_t
    let bundle: String
    let version: String
    let build: String
}

/// Attribute-level OS boundary. Text is read through the explicit range operation.
/// Content checks inspect only role/owner/children inside the captured input.
enum ExternalAttribute: String {
    case focusedWindow = "AXFocusedWindow", focusedInput = "AXFocusedUIElement"
    case role = "AXRole", subrole = "AXSubrole"
    case selectedText = "AXSelectedText", selectedRange = "AXSelectedTextRange"
    case characterCount = "AXNumberOfCharacters", position = "AXPosition", size = "AXSize"
    case main = "AXMain"
    case document = "AXDocument", value = "AXValue", markedRange = "AXTextInputMarkedRange"
}

@MainActor protocol ExternalObservation: AnyObject, Sendable { func stop() }

@MainActor protocol ExternalInputAccess: AnyObject {
    var hasPermission: Bool { get }
    var onSetterIssued: (() -> Void)? { get set }
    var ownApplication: ExternalApplication { get }
    func frontmost() -> ExternalApplication?
    func isRunning(_ application: ExternalApplication) -> Bool
    func applicationElement(_ application: ExternalApplication) -> AXUIElement
    func owner(_ element: AXUIElement) -> pid_t?
    func read(_ element: AXUIElement, _ attribute: ExternalAttribute, optional: Bool) throws -> CFTypeRef?
    func isEditable(_ element: AXUIElement) -> Bool
    func string(_ element: AXUIElement, for range: CFRange) throws -> String
    /// Returns optional document metadata exposed by the focused window, if any.
    /// The production implementation deliberately does not search the AX tree or use
    /// arbitrary control metadata as a conversation identity.
    func contextID(window: AXUIElement, input: AXUIElement) throws -> String?
    func replacementCapabilities(application: ExternalApplication, window: AXUIElement,
                                 input: AXUIElement, host: ExternalInput.Host) -> ExternalReplacementCapabilities
    func focus(window: AXUIElement, input: AXUIElement) async throws
    func setSelectedRange(_ range: CFRange, in input: AXUIElement) throws
    func canSetSelectedRange(_ input: AXUIElement) -> Bool
    func requiresPaste(_ input: AXUIElement) -> Bool
    func selectAll(in input: AXUIElement, count: Int) async throws
    func prepareWrite(_ text: String, to input: AXUIElement) throws
    func finishWrite(verified: Bool)
    func writeFullText(_ text: String, to input: AXUIElement, validate: () throws -> Void) throws
    func observe(application: AXUIElement, window: AXUIElement, input: AXUIElement,
                 pid: pid_t, requireSelectionEvents: Bool,
                 receive: @escaping @MainActor (String) -> Void) throws -> any ExternalObservation
    func activate(_ application: ExternalApplication) -> Bool
}

extension ExternalInputAccess {
    func canSetSelectedRange(_ input: AXUIElement) -> Bool { true }
    func requiresPaste(_ input: AXUIElement) -> Bool { false }
    func selectAll(in input: AXUIElement, count: Int) async throws {
        try setSelectedRange(CFRange(location: 0, length: count), in: input)
    }
    func prepareWrite(_ text: String, to input: AXUIElement) throws {}
    func finishWrite(verified: Bool) {}
}

@MainActor final class SystemExternalInputAccess: ExternalInputAccess {
    private let client: BrokerApplicationIdentity
    var onSetterIssued: (() -> Void)?
    private var clipboard: ClipboardWriteTransaction?
    private var pasteInput: AXUIElement?
    private var pasteIssued = false

    init(client: BrokerApplicationIdentity) {
        self.client = client
    }

    var hasPermission: Bool { AXIsProcessTrusted() }
    var ownApplication: ExternalApplication {
        ExternalApplication(pid: pid_t(client.pid), bundle: client.bundle,
            version: client.version, build: client.build)
    }

    private func describe(_ app: NSRunningApplication) -> ExternalApplication {
        let bundle = app.bundleURL.flatMap { Bundle(url: $0) }
        return ExternalApplication(pid: app.processIdentifier, bundle: app.bundleIdentifier ?? "",
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }
    func frontmost() -> ExternalApplication? { NSWorkspace.shared.frontmostApplication.map(describe) }
    func isRunning(_ application: ExternalApplication) -> Bool {
        guard let current = NSRunningApplication(processIdentifier: application.pid), !current.isTerminated else { return false }
        return describe(current) == application
    }
    func applicationElement(_ application: ExternalApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(application.pid)
        AXUIElementSetMessagingTimeout(element, 0.35)
        return element
    }
    func owner(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
    func read(_ element: AXUIElement, _ attribute: ExternalAttribute, optional: Bool) throws -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.35)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
        if optional && (result == .attributeUnsupported || result == .noValue) { return nil }
        guard result == .success, let value else { throw ExternalInputError.unavailable }
        return value
    }
    private func settable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var writable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &writable) == .success && writable.boolValue
    }
    func isEditable(_ element: AXUIElement) -> Bool {
        // AXEditable is exposed by web editors even when AXValue is read-only.
        // A writable selected-text attribute is another independent editing contract.
        var explicit: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXEditable" as CFString, &explicit) == .success,
           let editable = explicit as? Bool { return editable }
        return settable(element, kAXValueAttribute) || settable(element, kAXSelectedTextAttribute)
    }
    func canSetSelectedRange(_ input: AXUIElement) -> Bool { settable(input, kAXSelectedTextRangeAttribute) }
    func requiresPaste(_ input: AXUIElement) -> Bool { !settable(input, kAXValueAttribute) }
    func selectAll(in input: AXUIElement, count: Int) async throws {
        if requiresPaste(input) {
            let deadline = Date().addingTimeInterval(0.8)
            while !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty {
                guard Date() < deadline else { throw FillError.selectionUnavailable }
                try await Task.sleep(for: .milliseconds(15))
            }
        }
        if canSetSelectedRange(input) {
            try setSelectedRange(CFRange(location: 0, length: count), in: input)
        } else {
            let deadline = Date().addingTimeInterval(0.8)
            while !CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty {
                guard Date() < deadline else { throw FillError.selectionUnavailable }
                try await Task.sleep(for: .milliseconds(15))
            }
            guard let pid = owner(input), NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let focused = try read(AXUIElementCreateApplication(pid), .focusedInput, optional: false),
                  CFEqual(focused, input) else { throw FillError.targetChanged }
            try postCommand(0, to: pid)
        }
    }
    private func containsProtectedContent(_ input: AXUIElement) -> Bool? {
        guard let pid = owner(input) else { return nil }
        return ExternalTextContent.containsObjects(root: input, pid: pid, same: { CFEqual($0, $1) }) { element in
            AXUIElementSetMessagingTimeout(element, 0.35)
            guard let owner = self.owner(element), owner == pid,
                  let role = try self.read(element, .role, optional: false) as? String else {
                throw ExternalInputError.unavailable
            }
            var children: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            if result == .attributeUnsupported || result == .noValue {
                return ExternalTextContent.Node(pid: owner, role: role, children: [])
            }
            guard result == .success, let children, CFGetTypeID(children) == CFArrayGetTypeID(),
                  let values = children as? [AXUIElement],
                  values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else {
                throw ExternalInputError.unavailable
            }
            return ExternalTextContent.Node(pid: owner, role: role, children: values)
        }
    }
    func string(_ element: AXUIElement, for range: CFRange) throws -> String {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { throw ExternalInputError.invalidSelection }
        var text: CFTypeRef?
        let result = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, value, &text)
        guard result == .success, let text = text as? String else { throw ExternalInputError.invalidSelection }
        return text
    }
    func contextID(window: AXUIElement, input: AXUIElement) throws -> String? {
        // AXDocument on the focused window is the only production context candidate.
        // Do not fall back to input/window hashes, titles, or arbitrary descendants:
        // they cannot distinguish a reused composer across conversations.
        guard let value = try read(window, .document, optional: true) else { return nil }
        guard let document = value as? String, !document.isEmpty else { return nil }
        return document
    }
    func replacementCapabilities(application: ExternalApplication, window: AXUIElement,
                                 input: AXUIElement, host: ExternalInput.Host) -> ExternalReplacementCapabilities {
        // User-confirmed whole-input replacement does not require an external IME
        // state API. Conversation metadata is optional; inline objects remain protected.
        let candidate = (try? contextID(window: window, input: input)) != nil
        let approved = ExternalReplacementCapabilities.permitsRuntimeCheck(application) && isEditable(input)
        let protectedContent = approved ? containsProtectedContent(input) : nil
        return ExternalReplacementCapabilities(contextCandidatePresent: candidate,
            approved: approved, protectedContent: protectedContent,
            explanation: approved && protectedContent == false
                ? "支持用户确认后整框替换；写前核对原文，写后核验结果。"
                : "当前输入框未通过纯文本替换校验，可保留复制结果。")
    }
    func focus(window: AXUIElement, input: AXUIElement) async throws {
        if let main = try read(window, .main, optional: true) as? Bool, !main {
            var writable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(window, kAXMainAttribute as CFString, &writable) == .success,
               writable.boolValue {
                try setBoolean(true, on: window, attribute: kAXMainAttribute)
            }
        }
        try setBoolean(true, on: input, attribute: kAXFocusedAttribute)
    }
    func setSelectedRange(_ range: CFRange, in input: AXUIElement) throws {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { throw ExternalInputError.invalidSelection }
        let result = AXUIElementSetAttributeValue(input, kAXSelectedTextRangeAttribute as CFString, value)
        guard result == .success else { throw ExternalInputError.unavailable }
    }
    func writeFullText(_ text: String, to input: AXUIElement, validate: () throws -> Void) throws {
        guard isEditable(input) else { throw ExternalInputError.noFocusedInput }
        if let clipboard {
            guard let pasteInput, CFEqual(pasteInput, input), clipboard.isOwned,
                  let pid = owner(input) else { throw FillError.clipboardChanged }
            try postCommand(9, to: pid) { // V; no send/return key is ever posted.
                try clipboard.validateSubmission(validate)
                pasteIssued = true
                onSetterIssued?()
            }
            return
        }
        guard !requiresPaste(input) else { throw FillError.notEditable }
        try validate()
        onSetterIssued?()
        let result = AXUIElementSetAttributeValue(input, kAXValueAttribute as CFString, text as CFString)
        guard result == .success else { throw ExternalInputError.unavailable }
    }
    func prepareWrite(_ text: String, to input: AXUIElement) throws {
        guard clipboard == nil else { throw FillError.clipboardChanged }
        guard requiresPaste(input) else { return }
        let transaction = try ClipboardWriteTransaction(text: text)
        clipboard = transaction
        pasteInput = input
        pasteIssued = false
        try transaction.prepare()
    }
    func finishWrite(verified: Bool) {
        if let clipboard, verified || !pasteIssued { clipboard.restoreIfOwned() }
        clipboard = nil
        pasteInput = nil
        pasteIssued = false
    }
    private func postCommand(_ key: CGKeyCode, to pid: pid_t, willPost: () throws -> Void = {}) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw FillError.selectionUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        try willPost()
        down.postToPid(pid)
        up.postToPid(pid)
    }
    func activate(_ application: ExternalApplication) -> Bool {
        guard isRunning(application) else { return false }
        return NSRunningApplication(processIdentifier: application.pid)?.activate(options: []) == true
    }

    var verifiedClient: BrokerApplicationIdentity { client }

    private func setBoolean(_ value: Bool, on element: AXUIElement, attribute: String) throws {
        let result = AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean)
        guard result == .success else { throw ExternalInputError.unavailable }
    }

    func observe(application: AXUIElement, window: AXUIElement, input: AXUIElement,
                 pid: pid_t, requireSelectionEvents: Bool,
                 receive: @escaping @MainActor (String) -> Void) throws -> any ExternalObservation {
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, _, notification, context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemExternalObservation>.fromOpaque(context).takeUnretainedValue().receive(notification as String)
            }
        }, &observer) == .success, let observer else { throw ExternalInputError.monitoringUnavailable }
        let resources = SystemExternalObservation(observer: observer, receive: receive)
        do {
            for name in [kAXValueChangedNotification, kAXSelectedTextChangedNotification,
                         kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification] {
                try resources.add(input, name, required: false)
            }
            for name in [kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification] {
                try resources.add(application, name, required: false)
            }
            for name in [kAXUIElementDestroyedNotification, kAXMovedNotification, kAXResizedNotification] {
                try resources.add(window, name, required: false)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
                resources.tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { receive("workspace") }
                })
            }
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                MainActor.assumeIsolated { receive("poll") }
            }
            timer.tolerance = 0.2
            resources.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            return resources
        } catch {
            resources.stop()
            throw error
        }
    }
}

@MainActor private final class SystemExternalObservation: ExternalObservation {
    let observer: AXObserver
    let receive: @MainActor (String) -> Void
    var tokens: [NSObjectProtocol] = []
    var timer: Timer?
    private var registrations: [(AXUIElement, String)] = []
    private var stopped = false

    init(observer: AXObserver, receive: @escaping @MainActor (String) -> Void) {
        self.observer = observer
        self.receive = receive
    }
    func add(_ element: AXUIElement, _ notification: String, required: Bool) throws {
        let result = AXObserverAddNotification(observer, element, notification as CFString,
            Unmanaged.passUnretained(self).toOpaque())
        switch result {
        case .success: registrations.append((element, notification))
        case .notificationUnsupported where !required: break
        default: throw ExternalInputError.monitoringUnavailable
        }
    }
    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        for (element, notification) in registrations { AXObserverRemoveNotification(observer, element, notification as CFString) }
        registrations.removeAll()
        for token in tokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        tokens.removeAll()
    }
}
