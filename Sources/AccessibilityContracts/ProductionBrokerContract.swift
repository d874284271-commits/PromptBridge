import Foundation

public struct BrokerApplicationIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bundle: String
    public let path: String
    public let version: String
    public let build: String

    public init(pid: Int32, bundle: String, path: String, version: String, build: String) {
        self.pid = pid; self.bundle = bundle; self.path = path
        self.version = version; self.build = build
    }

    public func validate() throws {
        guard pid > 0, !bundle.isEmpty, !path.isEmpty, !version.isEmpty, !build.isEmpty else {
            throw BrokerContractError.invalidMessage
        }
    }
}

public struct BrokerRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width >= 0, height >= 0 else { throw BrokerContractError.invalidMessage }
    }
}

public struct BrokerTargetReference: Codable, Equatable, Sendable {
    public let captureToken: UUID
    public let revision: UInt64

    public init(captureToken: UUID, revision: UInt64) {
        self.captureToken = captureToken; self.revision = revision
    }

    public func validate() throws {
        // UUID and revision are opaque protocol values; zero is a valid initial revision.
    }
}

public struct BrokerWritePayload: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let target: BrokerTargetReference
    public let expected: InputSnapshot
    public let text: String

    public init(operationID: UUID, target: BrokerTargetReference,
                expected: InputSnapshot, text: String) {
        self.operationID = operationID; self.target = target
        self.expected = expected; self.text = text
    }

    public func validate() throws {
        guard let captureID = expected.captureID,
              captureID == target.captureToken,
              expected.revision == target.revision,
              expected.captureScope == .entireInput,
              expected.supportsDirectFill,
              expected.fullText != nil else {
            throw BrokerContractError.invalidMessage
        }
    }
}

public struct BrokerRestorePayload: Codable, Equatable, Sendable {
    public let operationID: UUID
    public let restorationToken: UUID

    public init(operationID: UUID, restorationToken: UUID) {
        self.operationID = operationID; self.restorationToken = restorationToken
    }
}

public enum BrokerScopeKind: String, Codable, Sendable {
    case panel, menu
}

public struct BrokerScopePayload: Codable, Equatable, Sendable {
    public let kind: BrokerScopeKind
    public let target: BrokerTargetReference?

    public init(kind: BrokerScopeKind, target: BrokerTargetReference? = nil) {
        self.kind = kind; self.target = target
    }
}

public struct BrokerScopeReceipt: Codable, Equatable, Sendable {
    public let scopeID: UUID
    public let kind: BrokerScopeKind
    public let captureToken: UUID?

    public init(scopeID: UUID, kind: BrokerScopeKind, captureToken: UUID? = nil) {
        self.scopeID = scopeID; self.kind = kind; self.captureToken = captureToken
    }

    public func validate() throws {
        // UUID is intentionally opaque. The component owns its scope namespace.
    }
}

public struct BrokerPayload: Codable, Equatable, Sendable {
    public let scope: CaptureScope?
    public let target: BrokerTargetReference?
    public let write: BrokerWritePayload?
    public let restore: BrokerRestorePayload?
    public let scopeRequest: BrokerScopePayload?
    public let scopeID: UUID?
    public let operationID: UUID?
    public let restorationToken: UUID?
    public let launcherMode: LauncherMode?
    public let allowInvalidTarget: Bool?
    public let cliSession: CLITerminalSession?
    public let cliTarget: CLITerminalTarget?

    public init(scope: CaptureScope? = nil, target: BrokerTargetReference? = nil,
                write: BrokerWritePayload? = nil, restore: BrokerRestorePayload? = nil,
                scopeRequest: BrokerScopePayload? = nil, scopeID: UUID? = nil,
                operationID: UUID? = nil, restorationToken: UUID? = nil,
                launcherMode: LauncherMode? = nil,
                allowInvalidTarget: Bool? = nil, cliSession: CLITerminalSession? = nil,
                cliTarget: CLITerminalTarget? = nil) {
        self.scope = scope; self.target = target; self.write = write; self.restore = restore
        self.scopeRequest = scopeRequest; self.scopeID = scopeID; self.operationID = operationID
        self.restorationToken = restorationToken
        self.launcherMode = launcherMode; self.allowInvalidTarget = allowInvalidTarget
        self.cliSession = cliSession; self.cliTarget = cliTarget
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case scope, target, write, restore, scopeRequest, scopeID, operationID
        case restorationToken, launcherMode, allowInvalidTarget, cliSession, cliTarget
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(scope: try container.decodeIfPresent(CaptureScope.self, forKey: .scope),
            target: try container.decodeIfPresent(BrokerTargetReference.self, forKey: .target),
            write: try container.decodeIfPresent(BrokerWritePayload.self, forKey: .write),
            restore: try container.decodeIfPresent(BrokerRestorePayload.self, forKey: .restore),
            scopeRequest: try container.decodeIfPresent(BrokerScopePayload.self, forKey: .scopeRequest),
            scopeID: try container.decodeIfPresent(UUID.self, forKey: .scopeID),
            operationID: try container.decodeIfPresent(UUID.self, forKey: .operationID),
            restorationToken: try container.decodeIfPresent(UUID.self, forKey: .restorationToken),
            launcherMode: try container.decodeIfPresent(LauncherMode.self, forKey: .launcherMode),
            allowInvalidTarget: try container.decodeIfPresent(Bool.self, forKey: .allowInvalidTarget),
            cliSession: try container.decodeIfPresent(CLITerminalSession.self, forKey: .cliSession),
            cliTarget: try container.decodeIfPresent(CLITerminalTarget.self, forKey: .cliTarget))
    }

    public func validate(for operation: BrokerOperation) throws {
        func require(_ condition: Bool) throws {
            guard condition else { throw BrokerContractError.invalidMessage }
        }
        if operation == .cliQueryTarget || operation == .cliTriggerEditor || operation == .cliReturnTarget {
            try require(scope == nil && target == nil && write == nil && restore == nil && scopeRequest == nil &&
                scopeID == nil && restorationToken == nil && launcherMode == nil && allowInvalidTarget == nil)
            if operation == .cliQueryTarget {
                try require(cliSession != nil && cliTarget == nil && operationID == nil)
                try cliSession?.validate()
            } else {
                try require(cliSession == nil && cliTarget != nil && operationID != nil)
                try cliTarget?.validate()
            }
            return
        }
        try require(cliSession == nil && cliTarget == nil)
        switch operation {
        case .capture:
            try require(scope != nil && target == nil && write == nil && restore == nil &&
                scopeRequest == nil && scopeID == nil && operationID == nil && restorationToken == nil && launcherMode == nil &&
                allowInvalidTarget == nil)
        case .validate:
            try require(scope == nil && (target == nil) != (restorationToken == nil) &&
                write == nil && restore == nil && scopeRequest == nil && scopeID == nil &&
                operationID == nil && launcherMode == nil && allowInvalidTarget == nil)
        case .replace:
            try require(scope == nil && target == nil && write != nil && restore == nil &&
                scopeRequest == nil && scopeID == nil && operationID == nil && restorationToken == nil && launcherMode == nil &&
                allowInvalidTarget == nil)
            try write?.validate()
        case .restore:
            try require(scope == nil && target == nil && write == nil && restore != nil &&
                scopeRequest == nil && scopeID == nil && operationID == nil && restorationToken == nil && launcherMode == nil &&
                allowInvalidTarget == nil)
        case .returnFocus:
            try require(scope == nil && write == nil && restore == nil &&
                scopeRequest == nil && scopeID == nil && operationID == nil && restorationToken == nil && launcherMode == nil)
        case .acquireScope:
            try require(scope == nil && target == nil && write == nil && restore == nil &&
                scopeRequest != nil && scopeID == nil && operationID == nil && restorationToken == nil && launcherMode == nil &&
                allowInvalidTarget == nil)
        case .releaseScope:
            try require(scope == nil && target == nil && write == nil && restore == nil &&
                scopeRequest == nil && scopeID != nil && operationID == nil && restorationToken == nil && launcherMode == nil &&
                allowInvalidTarget == nil)
        case .subscribe:
            try require(scope == nil && target == nil && write == nil && restore == nil &&
                scopeRequest == nil && scopeID == nil && operationID == nil && restorationToken == nil && launcherMode != nil &&
                allowInvalidTarget == nil)
        case .cancel:
            try require(scope == nil && target == nil && write == nil && restore == nil &&
                scopeRequest == nil && scopeID == nil && operationID != nil && restorationToken == nil && launcherMode == nil &&
                allowInvalidTarget == nil)
        case .invalidate:
            try require(scope == nil && target != nil && write == nil && restore == nil &&
                scopeRequest == nil && scopeID == nil && operationID == nil && restorationToken == nil && launcherMode == nil &&
                allowInvalidTarget == nil)
        case .probeCodex, .probeInputSupport:
            try require(scope == nil && target == nil && write == nil && restore == nil &&
                scopeRequest == nil && scopeID == nil && operationID == nil && restorationToken == nil && launcherMode == nil &&
                allowInvalidTarget == nil)
        default:
            throw BrokerContractError.invalidMessage
        }
        try target?.validate()
        try scopeRequest?.target?.validate()
        try write?.target.validate()
    }
}

public struct BrokerRuntimeState: Codable, Equatable, Sendable {
    public let snapshot: InputSnapshot?
    public let captureToken: UUID?
    public let revision: UInt64
    public let frame: BrokerRect?
    public let restorationToken: UUID?
    public let canRestore: Bool
    public let canReturnFocus: Bool
    public let hasTarget: Bool
    public let hostName: String
    public let lastReadFailure: String?
    public let writeAttempts: Int
    public let lastObservedChange: String?
    public let replacementStage: ReplacementStage?

    public init(snapshot: InputSnapshot?, captureToken: UUID?, revision: UInt64,
                frame: BrokerRect?, restorationToken: UUID?, canRestore: Bool,
                canReturnFocus: Bool, hasTarget: Bool, hostName: String,
                lastReadFailure: String?, writeAttempts: Int,
                lastObservedChange: String?, replacementStage: ReplacementStage?) {
        self.snapshot = snapshot; self.captureToken = captureToken; self.revision = revision
        self.frame = frame; self.restorationToken = restorationToken; self.canRestore = canRestore
        self.canReturnFocus = canReturnFocus; self.hasTarget = hasTarget; self.hostName = hostName
        self.lastReadFailure = lastReadFailure; self.writeAttempts = writeAttempts
        self.lastObservedChange = lastObservedChange; self.replacementStage = replacementStage
    }

    public func validate() throws {
        try frame?.validate()
        guard writeAttempts >= 0 else { throw BrokerContractError.invalidMessage }
        if let snapshot {
            guard let captureToken, snapshot.captureID == captureToken,
                  snapshot.revision == revision else { throw BrokerContractError.invalidMessage }
        }
        if canRestore { guard restorationToken != nil else { throw BrokerContractError.invalidMessage } }
        if hasTarget { guard captureToken != nil else { throw BrokerContractError.invalidMessage } }
    }
}

public struct BrokerFocusTarget: Codable, Equatable, Sendable {
    public let pid: Int32
    public let bundle: String
    public let windowToken: UUID
    public let inputToken: UUID
    public let anchor: BrokerRect

    public init(pid: Int32, bundle: String, windowToken: UUID, inputToken: UUID,
                anchor: BrokerRect) {
        self.pid = pid; self.bundle = bundle; self.windowToken = windowToken
        self.inputToken = inputToken; self.anchor = anchor
    }

    public func validate() throws {
        guard pid > 0, !bundle.isEmpty else { throw BrokerContractError.invalidMessage }
        try anchor.validate()
    }
}

public enum BrokerFocusState: Codable, Equatable, Sendable {
    case target(BrokerFocusTarget)
    case ownApplication
    case unavailable

    public var kind: String {
        switch self {
        case .target: return "target"
        case .ownApplication: return "ownApplication"
        case .unavailable: return "unavailable"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "target":
            guard container.allKeys.allSatisfy({ $0 == .kind || $0 == .target }) else {
                throw BrokerContractError.invalidMessage
            }
            self = .target(try container.decode(BrokerFocusTarget.self, forKey: .target))
        case "ownApplication":
            guard container.allKeys == [.kind] else { throw BrokerContractError.invalidMessage }
            self = .ownApplication
        case "unavailable":
            guard container.allKeys == [.kind] else { throw BrokerContractError.invalidMessage }
            self = .unavailable
        default:
            throw BrokerContractError.invalidMessage
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(kind, forKey: .kind)
        if case .target(let target) = self { try container.encode(target, forKey: .target) }
    }

    private enum Keys: String, CodingKey { case kind, target }
}

public enum BrokerCancelDisposition: String, Codable, Sendable {
    case cancelledBeforeSetter
    case outcomeUnknown
    case notActive
}

public struct BrokerEvent: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let epoch: UUID
    public let stateSequence: UInt64
    public let runtimeState: BrokerRuntimeState?
    public let focus: BrokerFocusState?
    public let invalidated: Bool

    public init(epoch: UUID, stateSequence: UInt64, runtimeState: BrokerRuntimeState? = nil,
                focus: BrokerFocusState? = nil, invalidated: Bool = false,
                protocolVersion: Int = 3) {
        self.protocolVersion = protocolVersion; self.epoch = epoch; self.stateSequence = stateSequence
        self.runtimeState = runtimeState; self.focus = focus; self.invalidated = invalidated
    }

    public init(protocolVersion: Int, epoch: UUID, stateSequence: UInt64,
                runtimeState: BrokerRuntimeState? = nil, focus: BrokerFocusState? = nil,
                invalidated: Bool = false) {
        self.init(epoch: epoch, stateSequence: stateSequence, runtimeState: runtimeState,
            focus: focus, invalidated: invalidated, protocolVersion: protocolVersion)
    }

    public func validate() throws {
        guard protocolVersion == 3 else { throw BrokerContractError.invalidMessage }
        try runtimeState?.validate()
        if case .target(let target) = focus { try target.validate() }
    }

    public func validate(for expectedEpoch: UUID, after sequence: UInt64) throws {
        guard protocolVersion == 3, epoch == expectedEpoch, stateSequence > sequence else {
            throw BrokerContractError.staleResponse
        }
        try validate()
    }
}

public extension ReplacementReceipt {
    func validate() throws {
        guard expected.captureID != nil else { throw BrokerContractError.invalidMessage }
    }
}

public extension BrokerOperation {
    var isLegacy: Bool {
        switch self {
        case .handshake, .status, .showPermissionHelp, .probeClaudeFixture: true
        default: false
        }
    }

    var isProduction: Bool { !isLegacy }
}

enum BrokerWireValidation {
    static func requestEnvelope(_ data: Data) throws -> BrokerOperation {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = root as? [String: Any],
              Set(object.keys).isSubset(of: ["protocolVersion", "requestID", "operation", "epoch", "payload"]),
              let rawOperation = object["operation"] as? String,
              let operation = BrokerOperation(rawValue: rawOperation) else {
            throw BrokerContractError.invalidMessage
        }
        if let payloadValue = object["payload"] {
            guard let payload = payloadValue as? [String: Any] else { throw BrokerContractError.invalidMessage }
            try validatePayload(payload)
        }
        return operation
    }

    private static func validatePayload(_ payload: [String: Any]) throws {
        let allowed: Set<String> = ["scope", "target", "write", "restore", "scopeRequest", "scopeID",
                                    "operationID", "restorationToken", "launcherMode", "allowInvalidTarget", "cliSession", "cliTarget"]
        guard Set(payload.keys).isSubset(of: allowed) else { throw BrokerContractError.invalidMessage }
        try optionalObject(payload, key: "cliSession", validate: cliSession)
        try optionalObject(payload, key: "cliTarget", validate: cliTarget)
        try optionalObject(payload, key: "target", keys: ["captureToken", "revision"])
        try optionalObject(payload, key: "scopeRequest", keys: ["kind", "target"], required: ["kind"])
        if let scopeRequest = payload["scopeRequest"] as? [String: Any], scopeRequest["target"] != nil {
            guard let target = scopeRequest["target"] as? [String: Any] else { throw BrokerContractError.invalidMessage }
            try exactKeys(target, ["captureToken", "revision"])
        }
        if let writeValue = payload["write"] {
            guard let write = writeValue as? [String: Any] else { throw BrokerContractError.invalidMessage }
            try exactKeys(write, ["operationID", "target", "expected", "text"])
            guard let target = write["target"] as? [String: Any] else { throw BrokerContractError.invalidMessage }
            try exactKeys(target, ["captureToken", "revision"])
            guard let expected = write["expected"] as? [String: Any] else { throw BrokerContractError.invalidMessage }
            try validateSnapshot(expected)
        }
        if let restoreValue = payload["restore"] {
            guard let restore = restoreValue as? [String: Any] else { throw BrokerContractError.invalidMessage }
            try exactKeys(restore, ["operationID", "restorationToken"])
        }
    }

    private static func validateSnapshot(_ object: [String: Any]) throws {
        try snapshot(object)
    }

    static func responseEnvelope(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = root as? [String: Any] else {
            throw BrokerContractError.invalidMessage
        }
        let required = ["protocolVersion", "requestID", "stateSequence"]
        let allowed = required + ["epoch", "error", "status", "metadata", "hostRejection", "axFailure",
                                  "verifiedClient", "runtimeState", "replacementReceipt",
                                  "scopeReceipt", "focusReturned", "cancelDisposition", "probeReport", "cliTarget", "cliAction"]
        try keys(object, allowed: allowed, required: required)
        try integer(object["protocolVersion"])
        try uuid(object["requestID"])
        try optional(object, key: "epoch", validate: uuid)
        try nonNegativeInteger(object["stateSequence"])
        try optional(object, key: "error") { value in
            guard let raw = value as? String, BrokerErrorCode(rawValue: raw) != nil else {
                throw BrokerContractError.invalidMessage
            }
        }
        try optionalObject(object, key: "cliTarget", validate: cliTarget)
        try optionalObject(object, key: "cliAction", validate: cliAction)
        try optionalObject(object, key: "status", validate: status)
        try optionalObject(object, key: "metadata", validate: metadata)
        try optionalObject(object, key: "hostRejection", validate: hostRejection)
        try optionalObject(object, key: "axFailure", validate: axFailure)
        try optionalObject(object, key: "verifiedClient", validate: applicationIdentity)
        try optionalObject(object, key: "runtimeState", validate: runtimeState)
        try optionalObject(object, key: "replacementReceipt", validate: replacementReceipt)
        try optionalObject(object, key: "scopeReceipt", validate: scopeReceipt)
        try optional(object, key: "focusReturned", validate: bool)
        try optional(object, key: "cancelDisposition") { value in
            guard let raw = value as? String, BrokerCancelDisposition(rawValue: raw) != nil else {
                throw BrokerContractError.invalidMessage
            }
        }
        try optional(object, key: "probeReport", validate: string)
    }

    static func eventEnvelope(_ data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = root as? [String: Any] else {
            throw BrokerContractError.invalidMessage
        }
        let required = ["protocolVersion", "epoch", "stateSequence", "invalidated"]
        try keys(object, allowed: required + ["runtimeState", "focus"], required: required)
        try integer(object["protocolVersion"])
        try uuid(object["epoch"])
        try nonNegativeInteger(object["stateSequence"])
        try bool(object["invalidated"])
        try optionalObject(object, key: "runtimeState", validate: runtimeState)
        try optionalObject(object, key: "focus", validate: focus)
    }

    private static func keys(_ object: [String: Any], allowed: [String], required: [String]) throws {
        guard Set(object.keys).isSubset(of: Set(allowed)),
              Set(required).isSubset(of: Set(object.keys)) else {
            throw BrokerContractError.invalidMessage
        }
    }

    private static func optional(_ object: [String: Any], key: String,
                                 validate: (Any) throws -> Void) throws {
        guard let value = object[key], !(value is NSNull) else { return }
        try validate(value)
    }

    private static func optionalObject(_ object: [String: Any], key: String,
                                      validate: ([String: Any]) throws -> Void) throws {
        guard let value = object[key], !(value is NSNull) else { return }
        guard let nested = value as? [String: Any] else { throw BrokerContractError.invalidMessage }
        try validate(nested)
    }

    private static func string(_ value: Any) throws {
        guard value is String else { throw BrokerContractError.invalidMessage }
    }

    private static func bool(_ value: Any) throws {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) == "c" else {
            throw BrokerContractError.invalidMessage
        }
    }

    private static func uuid(_ value: Any) throws {
        guard let value = value as? String, UUID(uuidString: value) != nil else {
            throw BrokerContractError.invalidMessage
        }
    }

    private static func integer(_ value: Any?) throws {
        guard let value, isPrimitiveInteger(value) else { throw BrokerContractError.invalidMessage }
    }

    private static func nonNegativeInteger(_ value: Any?) throws {
        guard let value, isPrimitiveInteger(value),
              let number = value as? NSNumber,
              number.doubleValue >= 0,
              number.doubleValue <= Double(UInt64.max) else {
            throw BrokerContractError.invalidMessage
        }
    }

    private static func finiteNumber(_ value: Any) throws {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.isFinite else {
            throw BrokerContractError.invalidMessage
        }
    }

    private static func isPrimitiveInteger(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        return ["s", "S", "i", "I", "l", "L", "q", "Q"].contains(type)
    }

    private static func cliSession(_ object: [String: Any]) throws {
        try exactKeys(object, ["id", "kind", "version", "pid", "startTimeMicros", "processGroup", "tty", "executablePath"])
        try uuid(object["id"] as Any)
        for key in ["version", "tty", "executablePath"] { try string(object[key] as Any) }
        for key in ["pid", "startTimeMicros", "processGroup"] { try nonNegativeInteger(object[key]) }
        guard let kind = object["kind"] as? String, CLIHostKind(rawValue: kind) != nil else { throw BrokerContractError.invalidMessage }
    }
    private static func cliTarget(_ object: [String: Any]) throws {
        try exactKeys(object, ["token", "session", "terminalPID", "terminalStartTimeMicros", "windowID"])
        try uuid(object["token"] as Any)
        guard let session = object["session"] as? [String: Any] else { throw BrokerContractError.invalidMessage }
        try cliSession(session)
        for key in ["terminalPID", "terminalStartTimeMicros", "windowID"] { try nonNegativeInteger(object[key]) }
    }
    private static func cliAction(_ object: [String: Any]) throws {
        try exactKeys(object, ["operationID", "targetToken", "disposition"])
        try uuid(object["operationID"] as Any); try uuid(object["targetToken"] as Any)
        guard let raw = object["disposition"] as? String, CLIActionDisposition(rawValue: raw) != nil else { throw BrokerContractError.invalidMessage }
    }

    private static func status(_ object: [String: Any]) throws {
        try keys(object,
            allowed: ["pid", "bundle", "path", "version", "build", "certificateSHA1",
                      "permission", "supportedOperations", "terminalAutomation"],
            required: ["pid", "bundle", "path", "version", "build", "certificateSHA1", "permission", "terminalAutomation"])
        try nonNegativeInteger(object["pid"])
        for key in ["bundle", "path", "version", "build", "certificateSHA1"] {
            try string(object[key] as Any)
        }
        try bool(object["permission"] as Any)
        guard let permission = object["terminalAutomation"] as? String, CLIAutomationPermission(rawValue: permission) != nil else { throw BrokerContractError.invalidMessage }
        try optional(object, key: "supportedOperations") { value in
            guard let array = value as? [Any] else { throw BrokerContractError.invalidMessage }
            var operations: [BrokerOperation] = []
            for item in array {
                guard let raw = item as? String, let operation = BrokerOperation(rawValue: raw) else {
                    throw BrokerContractError.invalidMessage
                }
                operations.append(operation)
            }
            guard Set(operations).count == operations.count else { throw BrokerContractError.invalidMessage }
        }
    }

    private static func metadata(_ object: [String: Any]) throws {
        try keys(object,
            allowed: ["hostPID", "hostVersion", "hostBuild", "role", "subrole",
                      "subroleEvidence", "editable", "stableFocusedIdentity"],
            required: ["hostPID", "hostVersion", "hostBuild", "role", "editable",
                       "stableFocusedIdentity"])
        try nonNegativeInteger(object["hostPID"])
        for key in ["hostVersion", "hostBuild", "role"] { try string(object[key] as Any) }
        try optional(object, key: "subrole", validate: string)
        try optional(object, key: "subroleEvidence") { value in
            guard let raw = value as? String, BrokerSubroleEvidence(rawValue: raw) != nil else {
                throw BrokerContractError.invalidMessage
            }
        }
        try bool(object["editable"] as Any)
        try bool(object["stableFocusedIdentity"] as Any)
    }

    private static func hostRejection(_ object: [String: Any]) throws {
        try keys(object,
            allowed: ["reason", "foreground", "componentActive", "observedClaudeVersion",
                      "observedClaudeBuild"],
            required: ["reason", "foreground", "componentActive"])
        guard let reason = object["reason"] as? String,
              BrokerHostRejection.Reason(rawValue: reason) != nil,
              let foreground = object["foreground"] as? String,
              BrokerHostRejection.Foreground(rawValue: foreground) != nil else {
            throw BrokerContractError.invalidMessage
        }
        try bool(object["componentActive"] as Any)
        try optional(object, key: "observedClaudeVersion", validate: string)
        try optional(object, key: "observedClaudeBuild", validate: string)
    }

    private static func axFailure(_ object: [String: Any]) throws {
        try keys(object,
            allowed: ["stage", "operation", "kind", "rawAXError", "successfulAttributeReads"],
            required: ["stage", "operation", "kind", "successfulAttributeReads"])
        guard let stage = object["stage"] as? String, BrokerAXFailure.Stage(rawValue: stage) != nil,
              let operation = object["operation"] as? String, BrokerAXFailure.Operation(rawValue: operation) != nil,
              let kind = object["kind"] as? String, BrokerAXFailure.Kind(rawValue: kind) != nil else {
            throw BrokerContractError.invalidMessage
        }
        try optional(object, key: "rawAXError", validate: integer)
        try nonNegativeInteger(object["successfulAttributeReads"])
    }

    private static func applicationIdentity(_ object: [String: Any]) throws {
        try keys(object, allowed: ["pid", "bundle", "path", "version", "build"],
                 required: ["pid", "bundle", "path", "version", "build"])
        try nonNegativeInteger(object["pid"])
        for key in ["bundle", "path", "version", "build"] { try string(object[key] as Any) }
    }

    private static func runtimeState(_ object: [String: Any]) throws {
        try keys(object,
            allowed: ["snapshot", "captureToken", "revision", "frame", "restorationToken",
                      "canRestore", "canReturnFocus", "hasTarget", "hostName", "lastReadFailure",
                      "writeAttempts", "lastObservedChange", "replacementStage"],
            required: ["revision", "canRestore", "canReturnFocus", "hasTarget", "hostName", "writeAttempts"])
        try optionalObject(object, key: "snapshot", validate: snapshot)
        try optional(object, key: "captureToken", validate: uuid)
        try nonNegativeInteger(object["revision"])
        try optionalObject(object, key: "frame", validate: rect)
        try optional(object, key: "restorationToken", validate: uuid)
        for key in ["canRestore", "canReturnFocus", "hasTarget"] { try bool(object[key] as Any) }
        try string(object["hostName"] as Any)
        try optional(object, key: "lastReadFailure", validate: string)
        try nonNegativeInteger(object["writeAttempts"])
        try optional(object, key: "lastObservedChange", validate: string)
        try optional(object, key: "replacementStage") { value in
            guard let raw = value as? String, ReplacementStage(rawValue: raw) != nil else {
                throw BrokerContractError.invalidMessage
            }
        }
    }

    private static func snapshot(_ object: [String: Any]) throws {
        let required = ["identity", "revision", "selection", "selectedText", "isComposing",
                        "containsProtectedContent", "supportsDirectFill", "captureScope"]
        try keys(object, allowed: required + ["fullText", "contextID", "captureID"], required: required)
        guard let identity = object["identity"] as? [String: Any] else { throw BrokerContractError.invalidMessage }
        try keys(identity, allowed: ["host", "window", "input", "session", "bundleIdentifier"],
                 required: ["host", "window", "input", "session"])
        for key in ["host", "window", "input", "session"] { try string(identity[key] as Any) }
        try optional(identity, key: "bundleIdentifier", validate: string)
        try nonNegativeInteger(object["revision"])
        guard let selection = object["selection"] as? [String: Any] else { throw BrokerContractError.invalidMessage }
        try keys(selection, allowed: ["location", "length"], required: ["location", "length"])
        try nonNegativeInteger(selection["location"])
        try nonNegativeInteger(selection["length"])
        try string(object["selectedText"] as Any)
        for key in ["isComposing", "containsProtectedContent", "supportsDirectFill"] {
            try bool(object[key] as Any)
        }
        guard let scope = object["captureScope"] as? String, CaptureScope(rawValue: scope) != nil else {
            throw BrokerContractError.invalidMessage
        }
        try optional(object, key: "fullText", validate: string)
        try optional(object, key: "contextID", validate: string)
        try optional(object, key: "captureID", validate: uuid)
    }

    private static func rect(_ object: [String: Any]) throws {
        try keys(object, allowed: ["x", "y", "width", "height"],
                 required: ["x", "y", "width", "height"])
        for key in ["x", "y", "width", "height"] { try finiteNumber(object[key] as Any) }
    }

    private static func replacementReceipt(_ object: [String: Any]) throws {
        try keys(object, allowed: ["expected", "writtenText"],
                 required: ["expected", "writtenText"])
        guard let expected = object["expected"] as? [String: Any] else {
            throw BrokerContractError.invalidMessage
        }
        try snapshot(expected)
        try string(object["writtenText"] as Any)
    }

    private static func scopeReceipt(_ object: [String: Any]) throws {
        try keys(object, allowed: ["scopeID", "kind", "captureToken"],
                 required: ["scopeID", "kind"])
        try uuid(object["scopeID"] as Any)
        guard let kind = object["kind"] as? String, BrokerScopeKind(rawValue: kind) != nil else {
            throw BrokerContractError.invalidMessage
        }
        try optional(object, key: "captureToken", validate: uuid)
    }

    private static func focus(_ object: [String: Any]) throws {
        guard let kind = object["kind"] as? String else { throw BrokerContractError.invalidMessage }
        switch kind {
        case "target":
            try keys(object, allowed: ["kind", "target"], required: ["kind", "target"])
            guard let target = object["target"] as? [String: Any] else {
                throw BrokerContractError.invalidMessage
            }
            try keys(target, allowed: ["pid", "bundle", "windowToken", "inputToken", "anchor"],
                     required: ["pid", "bundle", "windowToken", "inputToken", "anchor"])
            try nonNegativeInteger(target["pid"])
            try string(target["bundle"] as Any)
            try uuid(target["windowToken"] as Any)
            try uuid(target["inputToken"] as Any)
            guard let anchor = target["anchor"] as? [String: Any] else {
                throw BrokerContractError.invalidMessage
            }
            try rect(anchor)
        case "ownApplication", "unavailable":
            try keys(object, allowed: ["kind"], required: ["kind"])
        default:
            throw BrokerContractError.invalidMessage
        }
    }

    private static func optionalObject(_ object: [String: Any], key: String, keys: [String],
                                      required: [String] = []) throws {
        guard let value = object[key] else { return }
        guard let nested = value as? [String: Any] else { throw BrokerContractError.invalidMessage }
        guard Set(nested.keys).isSubset(of: Set(keys)), Set(required).isSubset(of: Set(nested.keys)) else {
            throw BrokerContractError.invalidMessage
        }
    }

    private static func exactKeys(_ object: [String: Any], _ keys: [String]) throws {
        guard Set(object.keys) == Set(keys) else { throw BrokerContractError.invalidMessage }
    }
}

enum BrokerProbeReport {
    static func validate(_ data: Data, for operation: BrokerOperation) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []),
              let object = root as? [String: Any] else { throw BrokerContractError.invalidMessage }
        switch operation {
        case .probeCodex:
            let keys = ["status", "applicationVersion", "applicationBuild", "nodes", "metadataReads",
                        "focusedInputReads", "selectionReads", "hostWrites", "modeVerified",
                        "captureBuildEvidenceRecorded"]
            let optional = ["applicationVersion", "applicationBuild"]
            guard Set(object.keys).isSubset(of: Set(keys)),
                  Set(keys.filter { !optional.contains($0) }).isSubset(of: Set(object.keys)),
                  object["status"] is String,
                  object["nodes"] is [Any], isInteger(object["metadataReads"]),
                  isInteger(object["focusedInputReads"]), isInteger(object["selectionReads"]),
                  isInteger(object["hostWrites"]), isBoolean(object["modeVerified"]),
                  isBoolean(object["captureBuildEvidenceRecorded"]) else {
                throw BrokerContractError.invalidMessage
            }
            guard let status = object["status"] as? String,
                  ["permissionRequired", "unsupportedFrontApplication", "unknownBuild",
                   "focusedInputUnavailable", "foreignElement", "secureInput",
                   "modeMetadataMissing", "modeUnverified"].contains(status) else {
                throw BrokerContractError.invalidMessage
            }
            guard let nodes = object["nodes"] as? [Any] else { throw BrokerContractError.invalidMessage }
            for value in nodes {
                guard let node = value as? [String: Any],
                      Set(node.keys) == ["depth", "role", "subroleSupport", "identifierSupport"],
                      isInteger(node["depth"]), node["role"] is String,
                      node["subroleSupport"] is String, node["identifierSupport"] is String else {
                    throw BrokerContractError.invalidMessage
                }
                guard let role = node["role"] as? String,
                      ["textArea", "textField", "group", "webArea", "window",
                       "application", "other", "unavailable"].contains(role),
                      let subroleSupport = node["subroleSupport"] as? String,
                      ["present", "empty", "unsupported", "missing", "unavailable",
                       "unexpectedType"].contains(subroleSupport),
                      let identifierSupport = node["identifierSupport"] as? String,
                      ["present", "empty", "unsupported", "missing", "unavailable",
                       "unexpectedType"].contains(identifierSupport) else {
                    throw BrokerContractError.invalidMessage
                }
            }
        case .probeInputSupport:
            let keys = ["status", "bundle", "version", "build", "permission", "role",
                        "fullRangeReadExposed", "characterCountExposed", "selectionSettable",
                        "valueSettable", "focusSettable", "windowDocumentExposed", "inputDocumentExposed",
                        "replacementApproved", "textReads", "contextValueReads", "hostWrites"]
            guard Set(object.keys) == Set(keys), object["status"] is String,
                  object["bundle"] is String, object["version"] is String, object["build"] is String,
                  isBoolean(object["permission"]), object["role"] is String,
                  isBoolean(object["fullRangeReadExposed"]), isBoolean(object["characterCountExposed"]),
                  isBoolean(object["selectionSettable"]), isBoolean(object["valueSettable"]),
                  isBoolean(object["focusSettable"]), isBoolean(object["windowDocumentExposed"]),
                  isBoolean(object["inputDocumentExposed"]), isBoolean(object["replacementApproved"]),
                  isInteger(object["textReads"]), isInteger(object["contextValueReads"]),
                  isInteger(object["hostWrites"]) else { throw BrokerContractError.invalidMessage }
            guard let status = object["status"] as? String,
                  ["unavailable", "permissionRequired", "applicationNotRunning",
                   "focusedInputUnavailable", "secureInput", "noFocusedTextInput",
                   "contextRequiresVerification", "noContextAttribute"].contains(status) else {
                throw BrokerContractError.invalidMessage
            }
        default:
            throw BrokerContractError.invalidMessage
        }
    }

    private static func isInteger(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        guard ["s", "S", "i", "I", "l", "L", "q", "Q"].contains(type) else { return false }
        return number.doubleValue >= 0 && number.doubleValue <= Double(UInt64.max)
    }

    private static func isBoolean(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return String(cString: number.objCType) == "c"
    }
}

@objc public protocol BrokerXPCClientProtocol {
    func receive(_ message: Data)
}

public enum BrokerXPCClientInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: BrokerXPCClientProtocol.self)
        let selector = #selector(BrokerXPCClientProtocol.receive(_:))
        let classes = NSSet(array: [NSData.self]) as! Set<AnyHashable>
        interface.setClasses(classes, for: selector, argumentIndex: 0, ofReply: false)
        return interface
    }
}
