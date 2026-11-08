import AccessibilityContracts
import AccessibilityRuntime
import AppKit
@preconcurrency import ApplicationServices
import Security

private enum Signing {
    static func requirement(_ text: String) -> SecRequirement? {
        var value: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &value) == errSecSuccess else { return nil }
        return value
    }
    static func ownMatches(_ text: String) -> Bool {
        var code: SecCode?
        guard let requirement = requirement(text), SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
    static func peerMatches(pid: pid_t, text: String) -> Bool {
        var code: SecCode?
        guard let requirement = requirement(text),
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

private typealias Admission = BrokerAdmission

@MainActor private func describeClient(_ pid: pid_t) -> BrokerApplicationIdentity? {
    guard let peer = NSRunningApplication(processIdentifier: pid), !peer.isTerminated,
          peer.bundleIdentifier == BrokerIdentity.clientBundle,
          let url = peer.bundleURL, let bundle = Bundle(url: url),
          let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
          let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return nil }
    return BrokerApplicationIdentity(pid: Int32(pid), bundle: BrokerIdentity.clientBundle,
        path: url.standardizedFileURL.path, version: version, build: build)
}

@MainActor private func currentStatus(certificate: String) -> BrokerStatus {
    BrokerStatus(pid: Int32(ProcessInfo.processInfo.processIdentifier),
        bundle: Bundle.main.bundleIdentifier ?? "", path: Bundle.main.bundleURL.path,
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
        certificateSHA1: certificate, permission: AXIsProcessTrusted(),
        supportedOperations: BrokerOperation.requiredProductionOperations,
        terminalAutomation: NativeCLITerminalAccess.automationPermission(ask: false))
}

@MainActor private func showPermissionHelp(certificate: String) {
    let alert = NSAlert()
    alert.messageText = "PromptBridge 外部输入访问组件"
    let current = currentStatus(certificate: certificate)
    alert.informativeText = "组件：\(current.path)\n版本：\(current.version) / \(current.build)\n辅助功能权限："
        + (current.permission ? "已信任当前组件进程" : "尚未信任当前组件进程")
        + "\nTerminal 自动化权限：" + (current.terminalAutomation == .granted ? "已授权" : "尚未授权")
        + "\n\n权限由此独立组件申请。系统认证由你本人完成。组件不读取模型配置或会话历史，也不会发送消息。"
    alert.addButton(withTitle: "完成")
    if !current.permission { alert.addButton(withTitle: "申请辅助功能权限…") }
    if current.terminalAutomation != .granted { alert.addButton(withTitle: "申请 Terminal 自动化权限…") }
    NSApplication.shared.activate(ignoringOtherApps: true)
    let choice = alert.runModal()
    if !current.permission && choice == .alertSecondButtonReturn {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    } else if current.terminalAutomation != .granted &&
                choice == (current.permission ? .alertSecondButtonReturn : .alertThirdButtonReturn) {
        _ = NativeCLITerminalAccess.automationPermission(ask: true)
    }
}

#if PROMPTBRIDGE_TESTING
private struct ProbeFailure: Error {
    let code: BrokerErrorCode
    let hostRejection: BrokerHostRejection?
    let axFailure: BrokerAXFailure?
    init(code: BrokerErrorCode, hostRejection: BrokerHostRejection? = nil, axFailure: BrokerAXFailure? = nil) {
        self.code = code; self.hostRejection = hostRejection; self.axFailure = axFailure
    }
}

@MainActor private func probeClaude(peerPID: pid_t) throws -> BrokerMetadata {
    let frontmost = NSWorkspace.shared.frontmostApplication
    let foreground: BrokerHostRejection.Foreground
    if let frontmost {
        if frontmost.bundleIdentifier == "com.anthropic.claudefordesktop" { foreground = .expectedHost }
        else if frontmost.processIdentifier == ProcessInfo.processInfo.processIdentifier { foreground = .component }
        else if frontmost.processIdentifier == peerPID { foreground = .client }
        else { foreground = .other }
    } else { foreground = .unavailable }
    func rejected(_ reason: BrokerHostRejection.Reason, version: String? = nil, build: String? = nil) -> ProbeFailure {
        ProbeFailure(code: .hostRejected, hostRejection: BrokerHostRejection(reason: reason,
            foreground: foreground, componentActive: NSApplication.shared.isActive,
            observedClaudeVersion: version, observedClaudeBuild: build))
    }
    guard let app = frontmost else { throw rejected(.noFrontmostApplication) }
    guard foreground == .expectedHost else { throw rejected(.unexpectedFrontmostApplication) }
    guard !app.isTerminated else { throw rejected(.hostTerminated) }
    guard let url = app.bundleURL, let bundle = Bundle(url: url) else { throw rejected(.hostBundleUnavailable) }
    guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else {
        throw rejected(.hostVersionUnavailable)
    }
    guard let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String else {
        throw rejected(.hostBuildUnavailable, version: version)
    }
    guard (version == "2.19675.0" && build == "2.19675.0") || (version == "2.19675.1" && build == "2.19675.1")
            || (version == "2.26454.0" && build == "2.26454.0")
            || (version == "2.26454.2" && build == "2.26454.2") else {
        throw rejected(.hostVersionRejected, version: version, build: build)
    }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    var successfulReads: UInt32 = 0
    func failed(_ stage: BrokerAXFailure.Stage, _ operation: BrokerAXFailure.Operation,
                _ kind: BrokerAXFailure.Kind, error: AXError? = nil, code: BrokerErrorCode = .unavailable) -> ProbeFailure {
        ProbeFailure(code: code, axFailure: BrokerAXFailure(stage: stage, operation: operation,
            kind: kind, rawAXError: error?.rawValue, successfulAttributeReads: successfulReads))
    }
    func read(_ element: AXUIElement, _ attribute: CFString, stage: BrokerAXFailure.Stage) throws -> CFTypeRef {
        let timeoutResult = AXUIElementSetMessagingTimeout(element, 0.35)
        guard timeoutResult == .success else { throw failed(stage, .configureTimeout, .apiError, error: timeoutResult) }
        var result: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &result)
        guard error == .success else { throw failed(stage, .copyAttribute, .apiError, error: error) }
        guard let result else { throw failed(stage, .copyAttribute, .missingValue, error: .success) }
        successfulReads += 1
        return result
    }
    func element(_ attribute: CFString, stage: BrokerAXFailure.Stage) throws -> AXUIElement {
        let value = try read(application, attribute, stage: stage)
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw failed(stage, .decodeElement, .unexpectedValueType)
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    func owned(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == app.processIdentifier
    }
    let window = try element(kAXFocusedWindowAttribute as CFString, stage: .focusedWindow)
    let input = try element(kAXFocusedUIElementAttribute as CFString, stage: .focusedInput)
    guard owned(window), owned(input),
          let windowRole = try read(window, kAXRoleAttribute as CFString, stage: .windowRole) as? String, windowRole == kAXWindowRole,
          let role = try read(input, kAXRoleAttribute as CFString, stage: .inputRole) as? String,
          role == kAXTextAreaRole || role == kAXTextFieldRole else { throw ProbeFailure(code: .identityChanged) }
    // Match the existing production optional-attribute contract only here.
    // Preserve native evidence so a missing value cannot mean an unread field.
    let subrole: String?
    let subroleEvidence: BrokerSubroleEvidence
    do {
        guard let value = try read(input, kAXSubroleAttribute as CFString, stage: .inputSubrole) as? String else {
            throw failed(.inputSubrole, .decodeSubrole, .unexpectedValueType)
        }
        subrole = value
        subroleEvidence = .observed
    } catch let failure as ProbeFailure {
        guard failure.code == .unavailable, let trace = failure.axFailure,
              trace.stage == .inputSubrole, trace.operation == .copyAttribute, trace.kind == .apiError else {
            throw failure
        }
        switch trace.rawAXError {
        case AXError.noValue.rawValue: subroleEvidence = .noValue
        case AXError.attributeUnsupported.rawValue: subroleEvidence = .attributeUnsupported
        default: throw failure
        }
        subrole = nil
    }
    guard subrole != kAXSecureTextFieldSubrole else { throw ProbeFailure(code: .secureInput) }
    var settable = DarwinBoolean(false)
    let editableError = AXUIElementIsAttributeSettable(input, kAXValueAttribute as CFString, &settable)
    guard editableError == .success else { throw failed(.editability, .checkSettable, .apiError, error: editableError, code: .notEditable) }
    guard settable.boolValue else { throw ProbeFailure(code: .notEditable) }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
          !app.isTerminated, CFEqual(window, try element(kAXFocusedWindowAttribute as CFString, stage: .focusedWindowRecheck)),
          CFEqual(input, try element(kAXFocusedUIElementAttribute as CFString, stage: .focusedInputRecheck)), owned(window), owned(input) else {
        throw ProbeFailure(code: .identityChanged)
    }
    return BrokerMetadata(hostPID: app.processIdentifier, hostVersion: version, hostBuild: build,
                          role: role, subrole: subrole, editable: true, stableFocusedIdentity: true,
                          subroleEvidence: subroleEvidence)
}

// NSXPC owns this connection; the sink keeps it weak and accesses it only on
// the same main actor that serializes runtime events.
#endif
private final class ClientEventSink: @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let admission: Admission
    private let token: UUID
    init(connection: NSXPCConnection, admission: Admission, token: UUID) {
        self.connection = connection; self.admission = admission; self.token = token
    }
    @MainActor func send(_ data: Data) {
        guard admission.isCurrent(token),
              let proxy = connection?.remoteObjectProxyWithErrorHandler({ _ in }) as? BrokerXPCClientProtocol else { return }
        proxy.receive(data)
    }
}

private final class BrokerSession: NSObject, BrokerXPCProtocol, @unchecked Sendable {
    let token: UUID
    let peerPID: pid_t
    let runtime: BrokerCoordinator
    let admission: Admission
    let eventSink: @MainActor @Sendable (Data) -> Void
    init(token: UUID, peerPID: pid_t, runtime: BrokerCoordinator, admission: Admission, eventSink: @escaping @MainActor @Sendable (Data) -> Void) {
        self.token = token; self.peerPID = peerPID; self.runtime = runtime; self.admission = admission; self.eventSink = eventSink
    }
    func perform(_ message: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task { @MainActor [runtime, token, peerPID, admission, eventSink] in
            guard admission.isCurrent(token) else { reply(Data()); return }
            let result = await runtime.perform(message, token: token, peerPID: peerPID, eventSink: eventSink)
            guard admission.isCurrent(token) else { reply(Data()); return }
            reply(result)
        }
    }
}

private final class BusySession: NSObject, BrokerXPCProtocol {
    func perform(_ message: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? BrokerCodec.request(message) else { reply(Data()); return }
        let response = BrokerResponse(requestID: request.requestID, epoch: nil, stateSequence: 1, error: .busy)
        reply((try? BrokerCodec.encode(response)) ?? Data())
    }
}

private final class BrokerListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let requirement: String
    let runtime: BrokerCoordinator
    let admission = Admission()
    init(requirement: String, runtime: BrokerCoordinator) { self.requirement = requirement; self.runtime = runtime }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              Signing.peerMatches(pid: connection.processIdentifier, text: requirement),
              NSRunningApplication(processIdentifier: connection.processIdentifier)?.bundleIdentifier == BrokerIdentity.clientBundle else { return false }
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = BrokerXPCInterface.make()
        connection.remoteObjectInterface = BrokerXPCClientInterface.make()
        guard let token = admission.acquire() else {
            connection.exportedObject = BusySession()
            connection.resume()
            return true
        }
        guard runtime.admitConnection(token) else {
            _ = admission.release(token)
            connection.exportedObject = BusySession()
            connection.resume()
            return true
        }
        let admission = self.admission
        let clientEvents = ClientEventSink(connection: connection, admission: admission, token: token)
        let sink: @MainActor @Sendable (Data) -> Void = { data in clientEvents.send(data) }
        connection.exportedObject = BrokerSession(token: token, peerPID: connection.processIdentifier, runtime: runtime, admission: admission, eventSink: sink)
        let runtime = self.runtime
        connection.invalidationHandler = {
            admission.markDisconnected(token)
            Task { @MainActor in
                await runtime.disconnect(token)
                _ = admission.release(token)
            }
        }
        connection.resume()
        return true
    }
}

@MainActor private func run() {
    do {
        guard Bundle.main.bundleIdentifier == BrokerIdentity.bundle,
              let value = Bundle.main.object(forInfoDictionaryKey: BrokerIdentity.signerKey) as? String else {
            throw BrokerContractError.invalidIdentity
        }
        let certificate = try BrokerIdentity.productionCertificate(value)
        guard Signing.ownMatches(try BrokerIdentity.requirement(bundle: BrokerIdentity.bundle, certificate: certificate)) else {
            throw BrokerContractError.invalidIdentity
        }
        _ = NSApplication.shared
        let runtime = BrokerCoordinator(certificate: certificate,
            resolveClient: { pid in describeClient(pid_t(pid)) },
            makeHost: { client in AccessibilityRuntimeHost(client: client) },
            status: { currentStatus(certificate: certificate) },
            permissionHelp: { showPermissionHelp(certificate: certificate) },
            claudeProbe: { pid in
                #if PROMPTBRIDGE_TESTING
                do {
                    return .success(try probeClaude(peerPID: pid_t(pid)))
                } catch let failure as ProbeFailure {
                    return .failure(BrokerProbeFailure(code: failure.code,
                        hostRejection: failure.hostRejection, axFailure: failure.axFailure))
                } catch {
                    return .failure(BrokerProbeFailure(code: .unavailable))
                }
                #else
                return .failure(BrokerProbeFailure(code: .unavailable))
                #endif
            },
            cliRuntime: CLITerminalRuntime(access: NativeCLITerminalAccess()),
            exit: { NSApplication.shared.terminate(nil) })
        let delegate = BrokerListener(requirement: try BrokerIdentity.requirement(bundle: BrokerIdentity.clientBundle, certificate: certificate), runtime: runtime)
        let listener = NSXPCListener(machServiceName: BrokerIdentity.service)
        listener.delegate = delegate; listener.resume()
        withExtendedLifetime((listener, delegate, runtime)) { NSApplication.shared.run() }
    } catch { fputs("AccessibilityBroker: signed app identity required; no fallback.\n", stderr); exit(1) }
}

run()
