import Foundation
import AccessibilityContracts

/// The small host surface used by the broker coordinator.  AX objects and
/// recovery state remain behind `AccessibilityRuntimeHost`; broker tests use a
/// fake implementation of this protocol and therefore never call AX.
@MainActor public protocol BrokerRuntimeHost: AnyObject {
    var onStateChange: (() -> Void)? { get set }
    var onFocusChange: ((BrokerFocusState) -> Void)? { get set }
    var onObservedChange: ((String) -> Void)? { get set }
    var onReplacementStage: ((ReplacementStage) -> Void)? { get set }
    var setterIssuedForOperation: Bool { get }

    func cachedState() -> BrokerRuntimeState
    func capture(_ scope: CaptureScope) async throws -> BrokerRuntimeState
    func validate(_ target: BrokerTargetReference) async throws -> BrokerRuntimeState
    func validateRestoration(_ token: UUID) async throws -> BrokerRuntimeState
    func replace(_ payload: BrokerWritePayload) async throws -> ReplacementReceipt
    func restore(_ payload: BrokerRestorePayload) async throws -> ReplacementReceipt
    func returnFocus(_ target: BrokerTargetReference?, allowInvalidTarget: Bool) async throws -> Bool
    func acquireScope(_ payload: BrokerScopePayload) throws -> BrokerScopeReceipt
    func releaseScope(_ id: UUID) throws
    func setLauncherMode(_ mode: LauncherMode)
    func setPollingPaused(_ paused: Bool)
    func resetOperationWriteState()
    func clear()
    func probeCodex() throws -> Data
    func probeInputSupport() throws -> Data
}

extension AccessibilityRuntimeHost: BrokerRuntimeHost {}

/// Thread-safe single-client lease.  A disconnected lease remains occupied
/// until the coordinator has finished cancelling and clearing its operation;
/// this prevents a second client from racing the old session's cleanup.
public final class BrokerAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var active: UUID?
    private var disconnected = false

    public init() {}

    public func acquire() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { return nil }
        let token = UUID()
        active = token
        disconnected = false
        return token
    }

    public func release(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active == token else { return false }
        active = nil
        disconnected = false
        return true
    }

    public func markDisconnected(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if active == token { disconnected = true }
    }

    public func isCurrent(_ token: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active == token && !disconnected
    }
}

/// A clock boundary keeps the ten-second broker lifetime rule testable without
/// sleeping or terminating a process in fixture checks.
@MainActor public protocol BrokerCoordinatorClock {
    func sleep(for duration: Duration) async throws
}

@MainActor public struct SystemBrokerCoordinatorClock: BrokerCoordinatorClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public struct BrokerProbeFailure: Error, Sendable {
    public let code: BrokerErrorCode
    public let hostRejection: BrokerHostRejection?
    public let axFailure: BrokerAXFailure?

    public init(code: BrokerErrorCode, hostRejection: BrokerHostRejection? = nil,
                axFailure: BrokerAXFailure? = nil) {
        self.code = code
        self.hostRejection = hostRejection
        self.axFailure = axFailure
    }
}

/// The broker's single-client admission and operation state machine.
///
/// Identity, permission, UI, process lifetime, and host creation are injected
/// by the executable.  This keeps those AppKit/Security boundaries in the
/// production executable while making admission, epoch, cancellation, and
/// deduplication behavior executable with a fake host.
@MainActor public final class BrokerCoordinator {
    public typealias ClientResolver = @MainActor (Int32) -> BrokerApplicationIdentity?
    public typealias HostFactory = @MainActor (BrokerApplicationIdentity) -> any BrokerRuntimeHost
    public typealias StatusProvider = @MainActor () -> BrokerStatus
    public typealias PermissionHelp = @MainActor () -> Void
    public typealias ClaudeProbe = @MainActor (Int32) -> Result<BrokerMetadata, BrokerProbeFailure>

    private struct ActiveOperation {
        let id: UUID
        let requestID: UUID
        let isWrite: Bool
        let task: Task<BrokerResponse, Never>
    }

    private final class LifecycleGate: @unchecked Sendable {
        private let lock = NSLock()
        private var token: UUID?

        func admit(_ token: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard self.token == nil else { return false }
            self.token = token
            return true
        }

        func release(_ token: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard self.token == token else { return false }
            self.token = nil
            return true
        }

        func contains(_ token: UUID) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return self.token == token
        }

        var hasAdmission: Bool {
            lock.lock(); defer { lock.unlock() }
            return token != nil
        }
    }

    public let certificate: String
    private let resolveClient: ClientResolver
    private let makeHost: HostFactory
    private let statusProvider: StatusProvider
    private let permissionHelp: PermissionHelp
    private let claudeProbe: ClaudeProbe
    private let cliRuntime: CLITerminalRuntime?
    private let clock: any BrokerCoordinatorClock
    private let exitHandler: @MainActor () -> Void
    private let lifecycle = LifecycleGate()

    private var active: UUID?
    private var epoch: UUID?
    private var clientIdentity: BrokerApplicationIdentity?
    private var sequence: UInt64 = 0
    private var host: (any BrokerRuntimeHost)?
    private var sendEvent: ((Data) -> Void)?
    private var idleTask: Task<Void, Never>?
    private var idleGeneration: UInt64 = 0
    private var permissionUIActive = false
    private var disconnected = false
    private var subscribed = false
    private var seenWrites: Set<UUID> = []
    private var completedCapture: (operationID: UUID, captureToken: UUID)?
    private var operation: ActiveOperation?

    public init(certificate: String, resolveClient: @escaping ClientResolver,
                makeHost: @escaping HostFactory, status: @escaping StatusProvider,
                permissionHelp: @escaping PermissionHelp,
                claudeProbe: @escaping ClaudeProbe,
                cliRuntime: CLITerminalRuntime? = nil,
                clock: any BrokerCoordinatorClock = SystemBrokerCoordinatorClock(),
                exit: @escaping @MainActor () -> Void) {
        self.certificate = certificate
        self.resolveClient = resolveClient
        self.makeHost = makeHost
        self.statusProvider = status
        self.permissionHelp = permissionHelp
        self.claudeProbe = claudeProbe
        self.cliRuntime = cliRuntime
        self.clock = clock
        self.exitHandler = exit
        scheduleIdleExit()
    }

    /// The listener calls this synchronously after its signed/UID admission and
    /// before enabling the NSXPC connection.  The lock is deliberately only a
    /// single token gate; all broker state remains serialized on MainActor.
    public nonisolated func admitConnection(_ token: UUID) -> Bool {
        lifecycle.admit(token)
    }

    public func disconnect(_ token: UUID) async {
        guard active == token || lifecycle.contains(token) else { return }
        disconnected = true
        sendEvent = nil
        subscribed = false
        host?.setLauncherMode(.persistent)
        if let operation {
            operation.task.cancel()
            _ = await operation.task.value
        }
        host?.clear()
        host = nil
        operation = nil
        epoch = nil
        clientIdentity = nil
        active = nil
        _ = lifecycle.release(token)
        seenWrites.removeAll()
        cliRuntime?.clear()
        completedCapture = nil
        scheduleIdleExit()
    }

    private func scheduleIdleExit() {
        idleTask?.cancel()
        idleGeneration &+= 1
        let generation = idleGeneration
        idleTask = Task { [weak self] in
            do { try await self?.clock.sleep(for: .seconds(10)) } catch { return }
            guard let self, self.active == nil, self.operation == nil,
                  !self.permissionUIActive, !self.lifecycle.hasAdmission,
                  self.idleGeneration == generation else { return }
            self.exitHandler()
        }
    }

    public func perform(_ data: Data, token: UUID, peerPID: Int32,
                        eventSink: @escaping (Data) -> Void) async -> Data {
        let request: BrokerRequest
        do {
            request = try BrokerCodec.request(data)
        } catch {
            return encode(BrokerResponse(requestID: UUID(), epoch: nil,
                stateSequence: nextSequence(), error: .invalidMessage))
        }

        if request.operation == .handshake {
            guard active == nil, lifecycle.contains(token), let peer = resolveClient(peerPID),
                  (try? statusProvider().validateSupportedOperations()) != nil else {
                return encode(makeResponse(request, error: active == nil ? .invalidMessage : .busy))
            }
            active = token
            epoch = UUID()
            clientIdentity = peer
            disconnected = false
            subscribed = false
            sendEvent = eventSink
            idleTask?.cancel()
            let runtime = makeHost(peer)
            host = runtime
            runtime.onStateChange = { [weak self] in self?.publishState() }
            runtime.onFocusChange = { [weak self] focus in self?.publishFocus(focus) }
            return encode(makeResponse(request, verifiedClient: peer))
        }

        guard active == token, !disconnected, let epoch else {
            return encode(makeResponse(request, error: .handshakeRequired))
        }
        guard request.epoch == epoch else {
            return encode(makeResponse(request, error: .staleEpoch))
        }
        guard let clientIdentity, resolveClient(peerPID) == clientIdentity else {
            return encode(makeResponse(request, error: .invalidMessage))
        }

        switch request.operation {
        case .handshake:
            return encode(makeResponse(request, error: .invalidMessage))
        case .status:
            return encode(makeResponse(request))
        case .cliQueryTarget, .cliTriggerEditor, .cliReturnTarget:
            guard operation == nil, !permissionUIActive, let cliRuntime else {
                return encode(makeResponse(request, error: .busy))
            }
            do {
                switch request.operation {
                case .cliQueryTarget:
                    guard let session = request.payload?.cliSession else { throw BrokerContractError.invalidMessage }
                    return encode(makeResponse(request, cliTarget: try cliRuntime.query(session)))
                case .cliTriggerEditor:
                    guard let target = request.payload?.cliTarget, let id = request.payload?.operationID else { throw BrokerContractError.invalidMessage }
                    return encode(makeResponse(request, cliAction: try cliRuntime.trigger(target, operationID: id)))
                case .cliReturnTarget:
                    guard let target = request.payload?.cliTarget, let id = request.payload?.operationID else { throw BrokerContractError.invalidMessage }
                    return encode(makeResponse(request, cliAction: try cliRuntime.returnTarget(target, operationID: id, clientPID: peerPID)))
                default: throw BrokerContractError.invalidMessage
                }
            } catch { return encode(makeResponse(request, error: errorCode(error))) }
        case .showPermissionHelp:
            guard operation == nil, !permissionUIActive else {
                return encode(makeResponse(request, error: .busy))
            }
            permissionUIActive = true
            host?.clear()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.permissionHelp()
                self.permissionUIActive = false
                if self.active == nil { self.scheduleIdleExit() }
            }
            return encode(makeResponse(request))
        case .cancel:
            guard let id = request.payload?.operationID else {
                return encode(makeResponse(request, error: .invalidMessage))
            }
            let disposition: BrokerCancelDisposition
            if let operation, operation.id == id {
                operation.task.cancel()
                disposition = operation.isWrite && host?.setterIssuedForOperation == true
                    ? .outcomeUnknown : .cancelledBeforeSetter
            } else if let completedCapture, completedCapture.operationID == id,
                      host?.cachedState().captureToken == completedCapture.captureToken,
                      operation == nil {
                host?.clear()
                self.completedCapture = nil
                disposition = .cancelledBeforeSetter
            } else {
                disposition = seenWrites.contains(id) ? .outcomeUnknown : .notActive
            }
            return encode(makeResponse(request, cancelDisposition: disposition))
        case .subscribe:
            guard let mode = request.payload?.launcherMode else {
                return encode(makeResponse(request, error: .invalidMessage))
            }
            subscribed = true
            host?.setLauncherMode(mode)
            return encode(makeResponse(request, state: host?.cachedState()))
        case .releaseScope:
            guard let scopeID = request.payload?.scopeID else {
                return encode(makeResponse(request, error: .invalidMessage))
            }
            do {
                try host?.releaseScope(scopeID)
                return encode(makeResponse(request, state: host?.cachedState()))
            } catch {
                return encode(makeResponse(request, error: .scopeRejected))
            }
        case .invalidate:
            guard operation == nil, let target = request.payload?.target,
                  let current = host?.cachedState(), current.captureToken == target.captureToken,
                  target.revision <= current.revision else {
                return encode(makeResponse(request, error: .targetChanged))
            }
            host?.clear()
            completedCapture = nil
            return encode(makeResponse(request, state: host?.cachedState()))
        case .acquireScope:
            guard operation == nil, !permissionUIActive,
                  let payload = request.payload?.scopeRequest else {
                return encode(makeResponse(request, error: .busy))
            }
            do {
                return encode(makeResponse(request, scopeReceipt: try host?.acquireScope(payload)))
            } catch {
                return encode(makeResponse(request, error: .scopeRejected))
            }
        default:
            guard operation == nil, !permissionUIActive, let host else {
                return encode(makeResponse(request, error: .busy))
            }
            guard statusProvider().permission else {
                host.clear()
                return encode(makeResponse(request, error: .permissionRequired))
            }
            let writeID = request.payload?.write?.operationID ?? request.payload?.restore?.operationID
            let id = writeID ?? request.requestID
            if let writeID {
                guard seenWrites.insert(writeID).inserted else {
                    return encode(makeResponse(request, error: .duplicateOperation))
                }
            }
            host.resetOperationWriteState()
            host.setPollingPaused(true)
            let task = Task { @MainActor [weak self, host] in
                guard let self else {
                    return BrokerResponse(requestID: request.requestID, epoch: request.epoch,
                        stateSequence: 1, error: .disconnected)
                }
                do {
                    try Task.checkCancellation()
                    switch request.operation {
                    case .capture:
                        guard let scope = request.payload?.scope else { throw BrokerContractError.invalidMessage }
                        let state = try await host.capture(scope)
                        try Task.checkCancellation()
                        if let captureToken = state.captureToken {
                            self.completedCapture = (id, captureToken)
                        }
                        return self.makeResponse(request, state: state)
                    case .validate:
                        let state: BrokerRuntimeState
                        if let restorationToken = request.payload?.restorationToken {
                            state = try await host.validateRestoration(restorationToken)
                        } else if let target = request.payload?.target {
                            state = try await host.validate(target)
                        } else {
                            throw BrokerContractError.invalidMessage
                        }
                        try Task.checkCancellation()
                        return self.makeResponse(request, state: state)
                    case .replace:
                        guard let payload = request.payload?.write else { throw BrokerContractError.invalidMessage }
                        let receipt = try await host.replace(payload)
                        guard !Task.isCancelled else { throw FillError.outcomeUnknown }
                        return self.makeResponse(request, state: host.cachedState(), replacementReceipt: receipt)
                    case .restore:
                        guard let payload = request.payload?.restore else { throw BrokerContractError.invalidMessage }
                        let receipt = try await host.restore(payload)
                        guard !Task.isCancelled else { throw FillError.outcomeUnknown }
                        return self.makeResponse(request, state: host.cachedState(), replacementReceipt: receipt)
                    case .returnFocus:
                        let returned = try await host.returnFocus(request.payload?.target,
                            allowInvalidTarget: request.payload?.allowInvalidTarget ?? false)
                        try Task.checkCancellation()
                        return self.makeResponse(request, focusReturned: returned)
                    case .probeCodex:
                        return self.makeResponse(request, probeReport: try host.probeCodex())
                    case .probeInputSupport:
                        return self.makeResponse(request, probeReport: try host.probeInputSupport())
                    case .probeClaudeFixture:
                        switch self.claudeProbe(peerPID) {
                        case .success(let metadata):
                            return self.makeResponse(request, metadata: metadata)
                        case .failure(let failure):
                            return self.makeResponse(request, error: failure.code,
                                hostRejection: failure.hostRejection, axFailure: failure.axFailure)
                        }
                    default:
                        throw BrokerContractError.invalidMessage
                    }
                } catch {
                    let code = writeID != nil && (host.setterIssuedForOperation || self.disconnected)
                        ? BrokerErrorCode.outcomeUnknown : self.errorCode(error)
                    if request.operation == .capture {
                        host.clear()
                        self.completedCapture = nil
                    }
                    return self.makeResponse(request, error: code)
                }
            }
            operation = ActiveOperation(id: id, requestID: request.requestID,
                isWrite: writeID != nil, task: task)
            let response = await task.value
            if operation?.id == id { operation = nil }
            host.setPollingPaused(false)
            return encode(response)
        }
    }

    private func errorCode(_ error: Error) -> BrokerErrorCode {
        if let code = error as? FillError {
            switch code {
            case .targetChanged: return .targetChanged
            case .compositionActive: return .compositionActive
            case .protectedContent: return .protectedContent
            case .notEditable: return .notEditable
            case .clipboardUnavailable: return .clipboardUnavailable
            case .clipboardChanged: return .clipboardChanged
            case .selectionUnavailable: return .selectionUnavailable
            case .cancelled: return .cancelled
            case .outcomeUnknown: return .outcomeUnknown
            }
        }
        if let code = error as? ExternalInputError {
            switch code {
            case .permissionRequired: return .permissionRequired
            case .unsupportedApplication: return .hostRejected
            case .secureInput: return .secureInput
            case .compositionActive: return .compositionActive
            case .writeOutcomeUnknown: return .outcomeUnknown
            case .noFocusedInput, .noSelection, .invalidSelection: return .targetChanged
            case .unavailable, .monitoringUnavailable: return .unavailable
            }
        }
        if let code = error as? BrokerProbeFailure { return code.code }
        if error is CancellationError { return .cancelled }
        if error is BrokerContractError { return .targetChanged }
        return .unavailable
    }

    private func nextSequence() -> UInt64 {
        sequence += 1
        return sequence
    }

    private func makeResponse(_ request: BrokerRequest, error: BrokerErrorCode? = nil,
                              verifiedClient: BrokerApplicationIdentity? = nil,
                              state: BrokerRuntimeState? = nil,
                              replacementReceipt: ReplacementReceipt? = nil,
                              scopeReceipt: BrokerScopeReceipt? = nil,
                              focusReturned: Bool? = nil,
                              cancelDisposition: BrokerCancelDisposition? = nil,
                              probeReport: Data? = nil,
                              metadata: BrokerMetadata? = nil,
                              hostRejection: BrokerHostRejection? = nil,
                              axFailure: BrokerAXFailure? = nil,
                              cliTarget: CLITerminalTarget? = nil, cliAction: CLIActionReceipt? = nil) -> BrokerResponse {
        BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: nextSequence(), error: error, status: statusProvider(),
            metadata: metadata, hostRejection: hostRejection, axFailure: axFailure,
            verifiedClient: verifiedClient, runtimeState: state,
            replacementReceipt: replacementReceipt, scopeReceipt: scopeReceipt,
            focusReturned: focusReturned, cancelDisposition: cancelDisposition,
            probeReport: probeReport, cliTarget: cliTarget, cliAction: cliAction)
    }

    private func encode(_ value: BrokerResponse) -> Data {
        (try? BrokerCodec.encode(value)) ?? Data()
    }

    private func publishState() {
        guard subscribed, !disconnected, let epoch, let state = host?.cachedState() else { return }
        let event = BrokerEvent(epoch: epoch, stateSequence: nextSequence(),
            // A late post-receipt notification invalidates the capture generation
            // while retaining the one verified restoration record.  Keep the
            // event on the state path so clients preserve that restoration token;
            // only a state without a recoverable receipt invalidates the route.
            runtimeState: state, invalidated: state.snapshot == nil && !state.canRestore)
        if let data = try? BrokerCodec.encode(event) { sendEvent?(data) }
    }

    private func publishFocus(_ focus: BrokerFocusState) {
        guard subscribed, !disconnected, let epoch else { return }
        let event = BrokerEvent(epoch: epoch, stateSequence: nextSequence(), focus: focus)
        if let data = try? BrokerCodec.encode(event) { sendEvent?(data) }
    }
}
