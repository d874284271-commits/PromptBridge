import AppKit
import ApplicationServices
import AccessibilityContracts

/// Explicit read-only capability inventory. Never reads draft text, context values,
/// history, or the clipboard, and never activates or writes to another application.
@MainActor enum InputSupportProbe {
    struct Report: Encodable {
        var status = "unavailable"
        var bundle = ""
        var version = ""
        var build = ""
        var permission = false
        var role = "unavailable"
        var fullRangeReadExposed = false
        var characterCountExposed = false
        var selectionSettable = false
        var valueSettable = false
        var focusSettable = false
        var windowDocumentExposed = false
        var inputDocumentExposed = false
        var replacementApproved = false
        let textReads = 0
        let contextValueReads = 0
        let hostWrites = 0
    }

    /// Production broker probe. The only target is the current frontmost
    /// allowlisted host; caller-supplied bundle strings never select a process.
    static func probeData() throws -> Data {
        let report = inspectFrontmost()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    static func runCommand() {
        let args = CommandLine.arguments
        guard let hostIndex = args.firstIndex(of: "--probe-input-host"), args.indices.contains(hostIndex + 1),
              let outputIndex = args.firstIndex(of: "--probe-output"), args.indices.contains(outputIndex + 1) else { Darwin.exit(1) }
        let requestedBundle = args[hostIndex + 1]
        guard requestedBundle != BrokerIdentity.bundle, requestedBundle != BrokerIdentity.clientBundle else { Darwin.exit(1) }
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == requestedBundle else { Darwin.exit(1) }
        guard let data = try? probeData() else { Darwin.exit(1) }
        do {
            let destination = URL(fileURLWithPath: args[outputIndex + 1])
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch { Darwin.exit(1) }
    }

    private static func inspectFrontmost() -> Report {
        var report = Report()
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundle = application.bundleIdentifier,
              bundle != BrokerIdentity.bundle, bundle != BrokerIdentity.clientBundle,
              !application.isTerminated else {
            report.status = "unsupportedFrontApplication"
            return report
        }
        report.bundle = bundle
        report.permission = AXIsProcessTrusted()
        guard report.permission else {
            report.status = "permissionRequired"
            return report
        }
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.35)
        guard let window = element(app, kAXFocusedWindowAttribute),
              let input = element(app, kAXFocusedUIElementAttribute),
              owner(window) == application.processIdentifier,
              owner(input) == application.processIdentifier else {
            report.status = "focusedInputUnavailable"
            return report
        }
        let role = string(input, kAXRoleAttribute)
        let subrole = string(input, kAXSubroleAttribute)
        if subrole == kAXSecureTextFieldSubrole as String || role == kAXSecureTextFieldSubrole as String {
            report.status = "secureInput"
        } else if role == kAXTextAreaRole as String || role == kAXTextFieldRole as String {
            report.role = role == kAXTextAreaRole as String ? "textArea" : "textField"
            let inputAttributes = attributes(input)
            report.characterCountExposed = inputAttributes.contains(kAXNumberOfCharactersAttribute as String)
            report.selectionSettable = settable(input, kAXSelectedTextRangeAttribute)
            report.valueSettable = settable(input, kAXValueAttribute)
            report.focusSettable = settable(input, kAXFocusedAttribute)
            report.windowDocumentExposed = attributes(window).contains(kAXDocumentAttribute as String)
            report.inputDocumentExposed = inputAttributes.contains(kAXDocumentAttribute as String)
            var names: CFArray?
            if AXUIElementCopyParameterizedAttributeNames(input, &names) == .success {
                report.fullRangeReadExposed = (names as? [String] ?? []).contains(kAXStringForRangeParameterizedAttribute as String)
            }
            report.status = report.windowDocumentExposed || report.inputDocumentExposed
                ? "contextRequiresVerification" : "noContextAttribute"
        } else { report.status = "noFocusedTextInput" }
        let metadata = application.bundleURL.flatMap { Bundle(url: $0) }
        report.version = metadata?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        report.build = metadata?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return report
    }

    private static func element(_ source: AXUIElement, _ name: String) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(source, 0.35)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, name as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private static func owner(_ source: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(source, &pid) == .success ? pid : nil
    }
    private static func string(_ source: AXUIElement, _ name: String) -> String? {
        AXUIElementSetMessagingTimeout(source, 0.35)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(source, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
    private static func attributes(_ source: AXUIElement) -> Set<String> {
        AXUIElementSetMessagingTimeout(source, 0.35)
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(source, &names) == .success else { return [] }
        return Set(names as? [String] ?? [])
    }
    private static func settable(_ source: AXUIElement, _ name: String) -> Bool {
        var value = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(source, name as CFString, &value) == .success && value.boolValue
    }
}
