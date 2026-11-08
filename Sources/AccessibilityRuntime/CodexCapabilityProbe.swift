import AppKit
import ApplicationServices

/// Metadata-only preflight. This does not read selections or change the host.
@MainActor enum CodexCapabilityProbe {
    static let bundleIdentifier = "com.openai.codex"
    static let version = "26.930.51102"
    static let build = "13100"

    /// Recorded fixture evidence, not a runtime admission rule or final acceptance.
    static func hasCaptureEvidence(version: String, build: String) -> Bool {
        switch (version, build) {
        case ("26.930.31730", "12947"), ("26.930.51102", "13100"): true
        default: false
        }
    }

    struct Application {
        let pid: pid_t
        let bundle: String
        let version: String
        let build: String
    }

    enum Element {
        case system(AXUIElement)
        case fixture(Int)
    }

    enum Attribute: String, Codable {
        case role = "AXRole"
        case subrole = "AXSubrole"
        case identifier = "AXIdentifier"
        case parent = "AXParent"
    }

    enum Support: String, Codable {
        case present, empty, unsupported, missing, unavailable, unexpectedType
    }

    enum Value {
        case string(String)
        case element(Element)
        case unavailable(Support)
    }

    enum Role: String, Codable {
        case textArea, textField, group, webArea, window, application, other, unavailable
    }

    enum Status: String, Codable {
        case permissionRequired, unsupportedFrontApplication, unknownBuild
        case focusedInputUnavailable, foreignElement, secureInput
        case modeMetadataMissing, modeUnverified
    }

    struct Node: Codable {
        let depth: Int
        let role: Role
        let subroleSupport: Support
        let identifierSupport: Support
    }

    struct Report: Codable {
        let status: Status
        let applicationVersion: String?
        let applicationBuild: String?
        let nodes: [Node]
        let metadataReads: Int
        let focusedInputReads: Int
        let selectionReads: Int
        let hostWrites: Int
        let modeVerified: Bool
        let captureBuildEvidenceRecorded: Bool
    }

    @MainActor protocol Access: AnyObject {
        var hasPermission: Bool { get }
        func frontmostApplication() -> Application?
        func focusedInput(in application: Application) -> Element?
        func owner(of element: Element) -> pid_t?
        func read(_ attribute: Attribute, from element: Element) -> Value
    }

    static func inspect(using access: any Access) -> Report {
        var nodes: [Node] = []
        var reads = 0
        var focusReads = 0
        var acceptedApplication: Application?
        func report(_ status: Status) -> Report {
            Report(status: status, applicationVersion: acceptedApplication?.version,
                applicationBuild: acceptedApplication?.build, nodes: nodes,
                metadataReads: reads, focusedInputReads: focusReads,
                selectionReads: 0, hostWrites: 0, modeVerified: false,
                captureBuildEvidenceRecorded: acceptedApplication.map {
                    hasCaptureEvidence(version: $0.version, build: $0.build)
                } ?? false)
        }
        guard access.hasPermission else { return report(.permissionRequired) }
        guard let application = access.frontmostApplication(), application.bundle == bundleIdentifier else {
            return report(.unsupportedFrontApplication)
        }
        acceptedApplication = application
        focusReads += 1
        guard var element = access.focusedInput(in: application) else { return report(.focusedInputUnavailable) }
        for depth in 0...4 {
            guard access.owner(of: element) == application.pid else { return report(.foreignElement) }
            reads += 1
            let roleValue = access.read(.role, from: element)
            reads += 1
            let subroleValue = access.read(.subrole, from: element)
            if case .string(let subrole) = subroleValue, subrole == kAXSecureTextFieldSubrole {
                return report(.secureInput)
            }
            if case .string(let role) = roleValue, role == kAXSecureTextFieldSubrole {
                return report(.secureInput)
            }
            reads += 1
            let identifier = access.read(.identifier, from: element)
            nodes.append(Node(depth: depth, role: classifyRole(roleValue),
                subroleSupport: support(subroleValue), identifierSupport: support(identifier)))
            guard depth < 4 else { break }
            reads += 1
            guard case .element(let parent) = access.read(.parent, from: element) else { break }
            element = parent
        }
        // A non-empty identifier still needs a verified Codex-vs-Chat matcher.
        // Metadata availability by itself never enables capture.
        return report(nodes.contains { $0.identifierSupport == .present } ? .modeUnverified : .modeMetadataMissing)
    }

    /// Production broker probe. It only inspects the approved Codex frontmost
    /// application and returns the existing read-only report as Foundation data.
    static func probeData() throws -> Data {
        let report = inspect(using: SystemAccess())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    private static func support(_ value: Value) -> Support {
        switch value {
        case .string(let string): string.isEmpty ? .empty : .present
        case .element: .unexpectedType
        case .unavailable(let status): status
        }
    }

    private static func classifyRole(_ value: Value) -> Role {
        guard case .string(let role) = value else { return .unavailable }
        switch role {
        case kAXTextAreaRole: return .textArea
        case kAXTextFieldRole: return .textField
        case kAXGroupRole: return .group
        case "AXWebArea": return .webArea
        case kAXWindowRole: return .window
        case kAXApplicationRole: return .application
        default: return .other
        }
    }

    static func runCommand() {
        do {
            let data = try probeData()
            let report = try JSONDecoder().decode(Report.self, from: data)
            if let index = CommandLine.arguments.firstIndex(of: "--probe-output") {
                guard CommandLine.arguments.indices.contains(index + 1) else { Darwin.exit(1) }
                let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
            }
            print(String(decoding: data, as: UTF8.self))
            // Preflight completion is not an adapter acceptance result.
            Darwin.exit(report.status == .permissionRequired ? 2 : 0)
        } catch {
            print("Could not save Codex metadata preflight report.")
            Darwin.exit(1)
        }
    }

    @MainActor private final class SystemAccess: Access {
        var hasPermission: Bool { AXIsProcessTrusted() }

        func frontmostApplication() -> Application? {
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.bundleIdentifier == bundleIdentifier, !app.isTerminated,
                  let url = app.bundleURL,
                  let data = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
            return Application(pid: app.processIdentifier, bundle: bundleIdentifier,
                version: info["CFBundleShortVersionString"] as? String ?? "",
                build: info["CFBundleVersion"] as? String ?? "")
        }

        func focusedInput(in application: Application) -> Element? {
            let app = AXUIElementCreateApplication(application.pid)
            AXUIElementSetMessagingTimeout(app, 0.35)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            let input = unsafeDowncast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(input, 0.35)
            return .system(input)
        }

        func owner(of element: Element) -> pid_t? {
            guard case .system(let element) = element else { return nil }
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success ? pid : nil
        }

        func read(_ attribute: Attribute, from element: Element) -> Value {
            guard case .system(let element) = element else { return .unavailable(.unavailable) }
            AXUIElementSetMessagingTimeout(element, 0.35)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, attribute.rawValue as CFString, &value)
            switch status {
            case .attributeUnsupported: return .unavailable(.unsupported)
            case .noValue: return .unavailable(.missing)
            case .success:
                guard let value else { return .unavailable(.missing) }
                if attribute == .parent {
                    guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return .unavailable(.unexpectedType) }
                    return .element(.system(unsafeDowncast(value, to: AXUIElement.self)))
                }
                guard let string = value as? String else { return .unavailable(.unexpectedType) }
                return .string(string)
            default: return .unavailable(.unavailable)
            }
        }
    }
}
