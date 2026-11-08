import Foundation
import Security
import CryptoKit

public enum BrokerIdentity {
    public static let bundle = "local.promptbridge.accessibility"
    public static let clientBundle = "local.promptbridge.prototype"
    public static let service = "local.promptbridge.accessibility.xpc"
    public static let signerKey = "PromptBridgeSignerSHA1"
    /// The current executable's verified signature anchors peer trust. Ad-hoc
    /// builds have no certificate and cannot connect to an installed component.
    public static func signingCertificate() throws -> String {
        var code: SecCode?
        var disk: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &disk) == errSecSuccess, let disk else {
            throw BrokerContractError.invalidIdentity
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(disk, flags, nil) == errSecSuccess else {
            throw BrokerContractError.invalidIdentity
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(disk, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { throw BrokerContractError.invalidCertificate }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
            .map { String(format: "%02X", $0) }.joined()
    }

    public static func certificate(_ value: String) throws -> String {
        guard value.utf8.count == 40, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw BrokerContractError.invalidCertificate }
        return value.uppercased()
    }

    /// Signed metadata must agree with the actual executable certificate.
    public static func productionCertificate(_ value: String) throws -> String {
        let normalized = try certificate(value)
        guard normalized == (try signingCertificate()) else {
            throw BrokerContractError.invalidCertificate
        }
        return normalized
    }

    public static func requirement(bundle: String, certificate: String) throws -> String {
        guard bundle == self.bundle || bundle == clientBundle else {
            throw BrokerContractError.invalidIdentity
        }
        return "identifier \"\(bundle)\" and certificate leaf = H\"\(try self.certificate(certificate))\""
    }
}

public enum BrokerContractError: Error { case invalidCertificate, invalidIdentity, invalidMessage, staleResponse }

/// IPC v3 requires a matching main application and component; older wire schemas are rejected.
public enum BrokerOperation: String, Codable, Sendable, Hashable {
    case handshake, status, showPermissionHelp, probeClaudeFixture
    case capture, validate, replace, restore, returnFocus
    case acquireScope, releaseScope, subscribe, cancel, invalidate
    case probeCodex, probeInputSupport
    case cliQueryTarget, cliTriggerEditor, cliReturnTarget
}

public enum BrokerErrorCode: String, Codable, Sendable {
    case invalidMessage, incompatibleProtocol, handshakeRequired, staleEpoch, busy
    case permissionRequired, hostRejected, unavailable, secureInput, notEditable, identityChanged
    case targetChanged, compositionActive, protectedContent, cancelled, outcomeUnknown
    case duplicateOperation, disconnected, scopeRejected
    case cliNotValidated, automationRequired, cliKeyBindingUnsupported
    case clipboardUnavailable, clipboardChanged, selectionUnavailable
}

public struct BrokerRequest: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let operation: BrokerOperation
    public let epoch: UUID?
    public let payload: BrokerPayload?

    public init(operation: BrokerOperation, epoch: UUID? = nil, requestID: UUID = UUID(),
                protocolVersion: Int = 3, payload: BrokerPayload? = nil) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.operation = operation
        self.epoch = epoch
        self.payload = payload
    }

    public func validate() throws {
        guard protocolVersion == 3,
              (operation == .handshake ? epoch == nil : epoch != nil) else {
            throw BrokerContractError.invalidMessage
        }
        if operation.isLegacy {
            guard payload == nil else { throw BrokerContractError.invalidMessage }
        } else {
            guard let payload else { throw BrokerContractError.invalidMessage }
            try payload.validate(for: operation)
        }
    }
}

public struct BrokerStatus: Codable, Sendable, Equatable {
    public let pid: Int32
    public let bundle: String
    public let path: String
    public let version: String
    public let build: String
    public let certificateSHA1: String
    public let permission: Bool
    /// A nil list identifies the older PoC status shape. Production clients
    /// require an explicit, complete capability list during handshake.
    public let supportedOperations: [BrokerOperation]?
    public let terminalAutomation: CLIAutomationPermission
    public init(pid: Int32, bundle: String, path: String, version: String, build: String,
                certificateSHA1: String, permission: Bool,
                supportedOperations: [BrokerOperation]? = nil,
                terminalAutomation: CLIAutomationPermission = .unknown) {
        self.pid = pid; self.bundle = bundle; self.path = path; self.version = version
        self.build = build; self.certificateSHA1 = certificateSHA1; self.permission = permission
        self.supportedOperations = supportedOperations
        self.terminalAutomation = terminalAutomation
    }

    public func validateSupportedOperations(allowMissing: Bool = false) throws {
        guard let supportedOperations else {
            guard allowMissing else { throw BrokerContractError.invalidMessage }
            return
        }
        guard Set(supportedOperations).count == supportedOperations.count else {
            throw BrokerContractError.invalidMessage
        }
        guard BrokerOperation.requiredProductionOperations.allSatisfy(supportedOperations.contains) else {
            throw BrokerContractError.invalidMessage
        }
    }
}

public extension BrokerOperation {
    static let requiredProductionOperations: [BrokerOperation] = [
        .capture, .validate, .replace, .restore, .returnFocus,
        .acquireScope, .releaseScope, .subscribe, .cancel, .invalidate,
        .probeCodex, .probeInputSupport, .cliQueryTarget, .cliTriggerEditor, .cliReturnTarget
    ]
}

/// Absence is verified only when the native subrole copy returns one of the
/// production contract's two optional-attribute errors. It is not secure proof.
public enum BrokerSubroleEvidence: String, Codable, Sendable {
    case observed, noValue, attributeUnsupported
}

public struct BrokerMetadata: Codable, Sendable, Equatable {
    public let hostPID: Int32
    public let hostVersion: String
    public let hostBuild: String
    public let role: String
    public let subrole: String?
    public let subroleEvidence: BrokerSubroleEvidence?
    public let editable: Bool
    public let stableFocusedIdentity: Bool
    public init(hostPID: Int32, hostVersion: String, hostBuild: String, role: String,
                subrole: String?, editable: Bool, stableFocusedIdentity: Bool,
                subroleEvidence: BrokerSubroleEvidence? = nil) {
        self.hostPID = hostPID; self.hostVersion = hostVersion; self.hostBuild = hostBuild
        self.role = role; self.subrole = subrole; self.editable = editable
        self.stableFocusedIdentity = stableFocusedIdentity
        self.subroleEvidence = subroleEvidence
    }

    public func validateSubrole() throws {
        // Legacy string metadata is observed evidence. A legacy nil cannot
        // establish a native absence and must never become a successful probe.
        switch subroleEvidence {
        case .observed:
            guard let subrole, subrole != "AXSecureTextField" else { throw BrokerContractError.invalidMessage }
        case .noValue, .attributeUnsupported:
            guard subrole == nil else { throw BrokerContractError.invalidMessage }
        case nil:
            guard let subrole, subrole != "AXSecureTextField" else { throw BrokerContractError.invalidMessage }
        }
    }
}

/// A rejected PoC preflight only. No window titles, text or arbitrary app
/// identity are transmitted; non-Claude foreground owners are classified.
public struct BrokerHostRejection: Codable, Sendable, Equatable {
    public enum Reason: String, Codable, Sendable {
        case noFrontmostApplication, unexpectedFrontmostApplication, hostTerminated
        case hostBundleUnavailable, hostVersionUnavailable, hostBuildUnavailable, hostVersionRejected
    }
    public enum Foreground: String, Codable, Sendable { case unavailable, expectedHost, component, client, other }
    public let reason: Reason
    public let foreground: Foreground
    public let componentActive: Bool
    public let observedClaudeVersion: String?
    public let observedClaudeBuild: String?

    public init(reason: Reason, foreground: Foreground, componentActive: Bool,
                observedClaudeVersion: String? = nil, observedClaudeBuild: String? = nil) {
        self.reason = reason; self.foreground = foreground; self.componentActive = componentActive
        self.observedClaudeVersion = observedClaudeVersion; self.observedClaudeBuild = observedClaudeBuild
    }

    public func validate() throws {
        switch reason {
        case .noFrontmostApplication:
            guard foreground == .unavailable else { throw BrokerContractError.invalidMessage }
        case .unexpectedFrontmostApplication:
            guard foreground == .component || foreground == .client || foreground == .other else {
                throw BrokerContractError.invalidMessage
            }
        default:
            guard foreground == .expectedHost else { throw BrokerContractError.invalidMessage }
        }
        switch reason {
        case .hostBuildUnavailable:
            guard observedClaudeVersion != nil, observedClaudeBuild == nil else { throw BrokerContractError.invalidMessage }
        case .hostVersionRejected:
            guard observedClaudeVersion != nil, observedClaudeBuild != nil else { throw BrokerContractError.invalidMessage }
        default:
            guard observedClaudeVersion == nil, observedClaudeBuild == nil else { throw BrokerContractError.invalidMessage }
        }
    }
}

/// Failure-only telemetry of the existing fixed metadata probe. No AX values,
/// titles, extra attributes, elements or commands cross the connection.
public struct BrokerAXFailure: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        case focusedWindow, focusedInput, windowRole, inputRole, inputSubrole
        case editability, focusedWindowRecheck, focusedInputRecheck
    }
    public enum Operation: String, Codable, Sendable {
        case configureTimeout, copyAttribute, decodeElement, decodeSubrole, checkSettable
    }
    public enum Kind: String, Codable, Sendable { case apiError, missingValue, unexpectedValueType }
    public let stage: Stage
    public let operation: Operation
    public let kind: Kind
    public let rawAXError: Int32?
    public let successfulAttributeReads: UInt32

    public init(stage: Stage, operation: Operation, kind: Kind, rawAXError: Int32? = nil,
                successfulAttributeReads: UInt32) {
        self.stage = stage; self.operation = operation; self.kind = kind
        self.rawAXError = rawAXError; self.successfulAttributeReads = successfulAttributeReads
    }

    public func validate() throws {
        guard successfulAttributeReads <= 7 else { throw BrokerContractError.invalidMessage }
        switch operation {
        case .configureTimeout, .copyAttribute:
            guard stage != .editability else { throw BrokerContractError.invalidMessage }
        case .decodeElement:
            guard [.focusedWindow, .focusedInput, .focusedWindowRecheck, .focusedInputRecheck].contains(stage) else {
                throw BrokerContractError.invalidMessage
            }
        case .decodeSubrole:
            guard stage == .inputSubrole else { throw BrokerContractError.invalidMessage }
        case .checkSettable:
            guard stage == .editability else { throw BrokerContractError.invalidMessage }
        }
        switch kind {
        case .apiError:
            guard let rawAXError, rawAXError != 0,
                  [.configureTimeout, .copyAttribute, .checkSettable].contains(operation) else {
                throw BrokerContractError.invalidMessage
            }
        case .missingValue:
            guard operation == .copyAttribute, rawAXError == 0 else { throw BrokerContractError.invalidMessage }
        case .unexpectedValueType:
            guard [.decodeElement, .decodeSubrole].contains(operation), rawAXError == nil else {
                throw BrokerContractError.invalidMessage
            }
        }
    }
}

public struct BrokerResponse: Codable, Sendable, Equatable {
    public let protocolVersion: Int
    public let requestID: UUID
    public let epoch: UUID?
    public let stateSequence: UInt64
    public let error: BrokerErrorCode?
    public let status: BrokerStatus?
    public let metadata: BrokerMetadata?
    public let hostRejection: BrokerHostRejection?
    public let axFailure: BrokerAXFailure?
    public let verifiedClient: BrokerApplicationIdentity?
    public let runtimeState: BrokerRuntimeState?
    public let replacementReceipt: ReplacementReceipt?
    public let scopeReceipt: BrokerScopeReceipt?
    public let focusReturned: Bool?
    public let cancelDisposition: BrokerCancelDisposition?
    public let probeReport: Data?
    public let cliTarget: CLITerminalTarget?
    public let cliAction: CLIActionReceipt?

    public init(requestID: UUID, epoch: UUID?, stateSequence: UInt64, error: BrokerErrorCode? = nil,
                status: BrokerStatus? = nil, metadata: BrokerMetadata? = nil,
                hostRejection: BrokerHostRejection? = nil, axFailure: BrokerAXFailure? = nil,
                verifiedClient: BrokerApplicationIdentity? = nil,
                runtimeState: BrokerRuntimeState? = nil,
                replacementReceipt: ReplacementReceipt? = nil,
                scopeReceipt: BrokerScopeReceipt? = nil,
                focusReturned: Bool? = nil,
                cancelDisposition: BrokerCancelDisposition? = nil,
                probeReport: Data? = nil,
                cliTarget: CLITerminalTarget? = nil, cliAction: CLIActionReceipt? = nil) {
        self.protocolVersion = 3; self.requestID = requestID; self.epoch = epoch
        self.stateSequence = stateSequence; self.error = error; self.status = status; self.metadata = metadata
        self.hostRejection = hostRejection; self.axFailure = axFailure
        self.verifiedClient = verifiedClient; self.runtimeState = runtimeState
        self.replacementReceipt = replacementReceipt; self.scopeReceipt = scopeReceipt
        self.focusReturned = focusReturned; self.cancelDisposition = cancelDisposition
        self.probeReport = probeReport
        self.cliTarget = cliTarget; self.cliAction = cliAction
    }

    public func validate(for request: BrokerRequest, after sequence: UInt64) throws {
        guard protocolVersion == 3, requestID == request.requestID, stateSequence > sequence else {
            throw BrokerContractError.staleResponse
        }
        try request.validate()
        if request.operation != .cliQueryTarget && request.operation != .cliTriggerEditor && request.operation != .cliReturnTarget {
            guard cliTarget == nil, cliAction == nil else { throw BrokerContractError.invalidMessage }
        }
        if request.operation.isProduction {
            try validateProduction(for: request)
            return
        }
        if let axFailure {
            guard request.operation == .probeClaudeFixture,
                  error == .unavailable || error == .notEditable,
                  metadata == nil, hostRejection == nil else { throw BrokerContractError.invalidMessage }
            try axFailure.validate()
            guard (axFailure.operation == .checkSettable) == (error == .notEditable) else {
                throw BrokerContractError.invalidMessage
            }
        }
        if let hostRejection {
            guard request.operation == .probeClaudeFixture, error == .hostRejected, metadata == nil else {
                throw BrokerContractError.invalidMessage
            }
            try hostRejection.validate()
        }
        if error == .busy, request.operation == .handshake, epoch == nil { return }
        guard let epoch, request.operation == .handshake || request.epoch == epoch else {
            throw BrokerContractError.staleResponse
        }
        if error == nil {
            guard status != nil, request.operation != .probeClaudeFixture || metadata != nil else {
                throw BrokerContractError.invalidMessage
            }
            if request.operation == .probeClaudeFixture {
                guard let metadata, metadata.editable, metadata.stableFocusedIdentity,
                      metadata.hostPID > 0, ["AXTextArea", "AXTextField"].contains(metadata.role),
                      status?.permission == true else { throw BrokerContractError.invalidMessage }
                try metadata.validateSubrole()
            }
        }
    }

    private func validateProduction(for request: BrokerRequest) throws {
        guard let responseEpoch = epoch, responseEpoch == request.epoch else {
            throw BrokerContractError.staleResponse
        }
        try runtimeState?.validate()
        if let runtimeState, let snapshot = runtimeState.snapshot,
           let captureToken = runtimeState.captureToken {
            guard snapshot.captureID == captureToken,
                  snapshot.revision == runtimeState.revision else {
                throw BrokerContractError.invalidMessage
            }
        }
        if error != nil {
            guard verifiedClient == nil, replacementReceipt == nil, scopeReceipt == nil,
                  focusReturned == nil, cancelDisposition == nil, probeReport == nil,
                  metadata == nil, hostRejection == nil, axFailure == nil, cliTarget == nil, cliAction == nil else {
                throw BrokerContractError.invalidMessage
            }
            return
        }

        guard metadata == nil, hostRejection == nil, axFailure == nil else {
            throw BrokerContractError.invalidMessage
        }
        switch request.operation {
        case .cliQueryTarget, .cliTriggerEditor, .cliReturnTarget:
            guard runtimeState == nil, replacementReceipt == nil, scopeReceipt == nil,
                  focusReturned == nil, cancelDisposition == nil, probeReport == nil,
                  verifiedClient == nil else { throw BrokerContractError.invalidMessage }
            if request.operation == .cliQueryTarget {
                guard let cliTarget, cliAction == nil,
                      cliTarget.session == request.payload?.cliSession else { throw BrokerContractError.invalidMessage }
                try cliTarget.validate()
            } else {
                guard cliTarget == nil, let cliAction,
                      cliAction.operationID == request.payload?.operationID,
                      cliAction.targetToken == request.payload?.cliTarget?.token else { throw BrokerContractError.invalidMessage }
                guard request.operation == .cliTriggerEditor ? cliAction.disposition == .triggered :
                        [.returned, .userMovedFocus].contains(cliAction.disposition) else { throw BrokerContractError.invalidMessage }
            }
        case .capture:
            guard replacementReceipt == nil, scopeReceipt == nil, focusReturned == nil,
                  cancelDisposition == nil, probeReport == nil, let runtimeState,
                  let snapshot = runtimeState.snapshot,
                  let captureToken = runtimeState.captureToken,
                  snapshot.captureID == captureToken,
                  snapshot.revision == runtimeState.revision,
                  snapshot.captureScope == request.payload?.scope else {
                throw BrokerContractError.invalidMessage
            }
        case .validate:
            guard replacementReceipt == nil, scopeReceipt == nil, focusReturned == nil,
                  cancelDisposition == nil, probeReport == nil, let runtimeState else {
                throw BrokerContractError.invalidMessage
            }
            if let target = request.payload?.target {
                guard let snapshot = runtimeState.snapshot,
                      let captureToken = runtimeState.captureToken,
                      snapshot.captureID == captureToken,
                      snapshot.captureID == target.captureToken,
                      snapshot.revision == target.revision,
                      runtimeState.revision == target.revision else {
                    throw BrokerContractError.invalidMessage
                }
            } else if let restorationToken = request.payload?.restorationToken {
                guard runtimeState.canRestore,
                      runtimeState.restorationToken == restorationToken,
                      runtimeState.captureToken != nil else {
                    throw BrokerContractError.invalidMessage
                }
                if let snapshot = runtimeState.snapshot {
                    guard runtimeState.hasTarget,
                          snapshot.captureID == runtimeState.captureToken,
                          snapshot.revision == runtimeState.revision else {
                        throw BrokerContractError.invalidMessage
                    }
                } else {
                    guard !runtimeState.hasTarget else { throw BrokerContractError.invalidMessage }
                }
            } else {
                throw BrokerContractError.invalidMessage
            }
        case .replace, .restore:
            guard let runtimeState, runtimeState.snapshot != nil,
                  replacementReceipt != nil,
                  scopeReceipt == nil, focusReturned == nil,
                  cancelDisposition == nil, probeReport == nil else {
                throw BrokerContractError.invalidMessage
            }
            if request.operation == .replace, let write = request.payload?.write,
               let replacementReceipt, let responseSnapshot = runtimeState.snapshot {
                guard replacementReceipt.expected.captureID == write.target.captureToken,
                      replacementReceipt.expected.revision == write.target.revision,
                      replacementReceipt.expected == write.expected,
                      replacementReceipt.writtenText == write.text,
                      responseSnapshot.captureID == write.target.captureToken,
                      responseSnapshot.revision >= write.target.revision else {
                    throw BrokerContractError.invalidMessage
                }
            }
            try replacementReceipt?.validate()
        case .acquireScope:
            guard let scopeReceipt, replacementReceipt == nil, runtimeState == nil,
                  focusReturned == nil, cancelDisposition == nil, probeReport == nil else {
                throw BrokerContractError.invalidMessage
            }
            try scopeReceipt.validate()
            if let target = request.payload?.scopeRequest?.target {
                guard scopeReceipt.captureToken == target.captureToken else {
                    throw BrokerContractError.invalidMessage
                }
            }
        case .returnFocus:
            guard let focusReturned, replacementReceipt == nil, scopeReceipt == nil,
                  runtimeState == nil, cancelDisposition == nil, probeReport == nil else {
                throw BrokerContractError.invalidMessage
            }
            _ = focusReturned
        case .cancel:
            guard cancelDisposition != nil, replacementReceipt == nil, scopeReceipt == nil,
                  focusReturned == nil, probeReport == nil, runtimeState == nil else {
                throw BrokerContractError.invalidMessage
            }
        case .probeCodex, .probeInputSupport:
            guard let probeReport,
                  replacementReceipt == nil, scopeReceipt == nil, focusReturned == nil,
                  cancelDisposition == nil, runtimeState == nil else {
                throw BrokerContractError.invalidMessage
            }
            try BrokerProbeReport.validate(probeReport, for: request.operation)
        case .subscribe, .invalidate, .releaseScope:
            guard replacementReceipt == nil, scopeReceipt == nil, focusReturned == nil,
                  cancelDisposition == nil, probeReport == nil else {
                throw BrokerContractError.invalidMessage
            }
        default:
            throw BrokerContractError.invalidMessage
        }
        try verifiedClient?.validate()
    }
}

public enum BrokerCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func request(_ data: Data) throws -> BrokerRequest {
        let operation = try BrokerWireValidation.requestEnvelope(data)
        if operation.isLegacy { guard data.count <= 4096 else { throw BrokerContractError.invalidMessage } }
        let request = try JSONDecoder().decode(BrokerRequest.self, from: data)
        try request.validate()
        return request
    }

    public static func response(_ data: Data, for request: BrokerRequest,
                                after sequence: UInt64) throws -> BrokerResponse {
        try BrokerWireValidation.responseEnvelope(data)
        let response = try JSONDecoder().decode(BrokerResponse.self, from: data)
        try response.validate(for: request, after: sequence)
        return response
    }

    public static func event(_ data: Data, for epoch: UUID,
                             after sequence: UInt64) throws -> BrokerEvent {
        try BrokerWireValidation.eventEnvelope(data)
        let event = try JSONDecoder().decode(BrokerEvent.self, from: data)
        try event.validate(for: epoch, after: sequence)
        return event
    }
}

@objc public protocol BrokerXPCProtocol {
    func perform(_ message: Data, reply: @escaping @Sendable (Data) -> Void)
}

public enum BrokerXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: BrokerXPCProtocol.self)
        let selector = #selector(BrokerXPCProtocol.perform(_:reply:))
        let classes = NSSet(array: [NSData.self]) as! Set<AnyHashable>
        interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: false)
        interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: true)
        return interface
    }
}
