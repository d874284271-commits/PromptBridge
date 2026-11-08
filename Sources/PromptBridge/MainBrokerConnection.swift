import AppKit
import AccessibilityContracts
import Darwin
import Foundation
import Security

@MainActor
protocol BrokerEndpoint: AnyObject {
    var onEvent: ((Data) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }
    func exchange(_ message: Data) async throws -> Data
    func disconnect()
}

enum BrokerTransportError: Error {
    case unavailable
    case timeout
    case invalidIdentity
    case incompatibleProtocol
    case invalidResponse
}

/// The production endpoint supplies the peer EUID from NSXPC. Keeping the
/// comparison as a small pure policy lets Foundation-only fixtures exercise
/// the rejection branch without pretending to be a real XPC peer.
enum BrokerPeerIdentityPolicy {
    static func accepts(peerUserIdentifier: uid_t, currentUserIdentifier: uid_t) -> Bool {
        peerUserIdentifier == currentUserIdentifier
    }
}

struct BrokerRemoteError: Error {
    let code: BrokerErrorCode
    let response: BrokerResponse
}

private enum BrokerSigning {
    static func requirement(_ text: String) -> SecRequirement? {
        var value: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &value) == errSecSuccess else { return nil }
        return value
    }

    static func ownMatches(_ text: String) -> Bool {
        var code: SecCode?
        guard let requirement = requirement(text),
              SecCodeCopySelf([], &code) == errSecSuccess,
              let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

private final class BrokerCallbackReceiver: NSObject, BrokerXPCClientProtocol, @unchecked Sendable {
    private let handler: @Sendable (Data) -> Void

    init(handler: @escaping @Sendable (Data) -> Void) {
        self.handler = handler
    }

    nonisolated func receive(_ message: Data) {
        let handler = self.handler
        Task { @MainActor in handler(message) }
    }
}

private final class BrokerContinuationGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var completed = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard !completed else {
            continuation.resume(throwing: BrokerTransportError.unavailable)
            return
        }
        self.continuation = continuation
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() { finish(.failure(CancellationError())) }
}

@MainActor
private final class SignedXPCEndpoint: NSObject, BrokerEndpoint {
    var onEvent: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?

    private let connection: NSXPCConnection
    private var callback: BrokerCallbackReceiver?
    private var disconnected = false

    init(certificate: String) throws {
        guard Bundle.main.bundleIdentifier == BrokerIdentity.clientBundle else {
            throw BrokerTransportError.invalidIdentity
        }
        let productionCertificate = try BrokerIdentity.productionCertificate(certificate)
        let requirement = try BrokerIdentity.requirement(bundle: BrokerIdentity.bundle, certificate: productionCertificate)
        let ownRequirement = try BrokerIdentity.requirement(bundle: BrokerIdentity.clientBundle, certificate: productionCertificate)
        guard BrokerSigning.ownMatches(ownRequirement) else { throw BrokerTransportError.invalidIdentity }

        let connection = NSXPCConnection(machServiceName: BrokerIdentity.service)
        self.connection = connection
        self.callback = nil
        super.init()
        let callback = BrokerCallbackReceiver { [weak self] data in
            Task { @MainActor in self?.onEvent?(data) }
        }
        self.callback = callback
        connection.remoteObjectInterface = BrokerXPCInterface.make()
        connection.exportedInterface = BrokerXPCClientInterface.make()
        connection.exportedObject = callback
        connection.setCodeSigningRequirement(requirement)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.markDisconnected() }
        }
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.markDisconnected() }
        }
        connection.resume()
    }

    func exchange(_ message: Data) async throws -> Data {
        guard !disconnected else { throw BrokerTransportError.unavailable }
        let gate = BrokerContinuationGate<Data>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !disconnected else {
                    gate.finish(.failure(BrokerTransportError.unavailable))
                    return
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                    gate.finish(.failure(error))
                }
                guard let proxy = proxy as? BrokerXPCProtocol else {
                    gate.finish(.failure(BrokerTransportError.unavailable))
                    return
                }
                proxy.perform(message) { data in gate.finish(.success(data)) }
            }
        }, onCancel: {
            gate.cancel()
        })
    }

    func disconnect() {
        markDisconnected()
        connection.invalidate()
    }

    private func markDisconnected() {
        guard !disconnected else { return }
        disconnected = true
        onDisconnect?()
    }

    var processIdentifier: pid_t { connection.processIdentifier }
    var peerUserIdentifier: uid_t { connection.effectiveUserIdentifier }
}

@MainActor
private final class ClosureBrokerEndpoint: BrokerEndpoint {
    var onEvent: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    private let exchangeClosure: (Data) async throws -> Data

    init(exchange: @escaping (Data) async throws -> Data) {
        exchangeClosure = exchange
    }

    func exchange(_ message: Data) async throws -> Data { try await exchangeClosure(message) }
    func disconnect() { onDisconnect?() }
}

private final class BrokerExchangeJob: @unchecked Sendable {
    let endpoint: BrokerEndpoint
    let message: Data

    init(endpoint: BrokerEndpoint, message: Data) {
        self.endpoint = endpoint; self.message = message
    }

    @MainActor
    func run() async throws -> Data { try await endpoint.exchange(message) }
}

@MainActor
final class BrokerClient {
    static let shared = BrokerClient()

    private(set) var cachedStatus: BrokerStatus?
    private(set) var cachedRuntimeState: BrokerRuntimeState?
    private(set) var verifiedClient: BrokerApplicationIdentity?
    private(set) var epoch: UUID?
    private(set) var connected = false

    var onEvent: ((BrokerEvent) -> Void)?
    var onDisconnect: (() -> Void)?

    private let ownIdentity: BrokerApplicationIdentity?
    private let helperPath: String
    private let testEndpoint: Bool
    private var endpoint: BrokerEndpoint?
    private var endpointFactory: (() throws -> BrokerEndpoint)?
    private var eventSubscribers: [UUID: (BrokerEvent) -> Void] = [:]
    private var disconnectSubscribers: [UUID: () -> Void] = [:]
    private var latestResponseSequence: UInt64 = 0
    private var latestEventSequence: UInt64 = 0
    private var latestStateSequence: UInt64 = 0
    private var disconnectNotified = false
    private let responseTimeout: Duration
    private var connectionGeneration: UInt64 = 0
    private var handshakeTask: Task<BrokerResponse, Error>?

    private init() {
        ownIdentity = BrokerClient.currentIdentity()
        helperPath = BrokerClient.defaultHelperPath
        testEndpoint = false
        responseTimeout = .seconds(10)
        endpointFactory = { [weak self] in
            guard let self, let identity = self.ownIdentity,
                  let signer = Bundle.main.object(forInfoDictionaryKey: BrokerIdentity.signerKey) as? String else {
                throw BrokerTransportError.invalidIdentity
            }
            let certificate = try BrokerIdentity.productionCertificate(signer)
            _ = identity
            return try SignedXPCEndpoint(certificate: certificate)
        }
    }

    /// Explicit test-only boundary. Production uses `shared`, whose endpoint is
    /// always the signed XPC transport above.
    init(endpoint: BrokerEndpoint, ownIdentity: BrokerApplicationIdentity,
         helperPath: String = BrokerClient.defaultHelperPath,
         initialStatus: BrokerStatus? = nil, initialVerifiedClient: BrokerApplicationIdentity? = nil,
         initialEpoch: UUID? = nil, responseTimeout: Duration = .seconds(10)) {
        self.endpoint = endpoint
        self.endpointFactory = nil
        self.ownIdentity = ownIdentity
        self.helperPath = helperPath
        self.testEndpoint = true
        self.responseTimeout = responseTimeout
        self.cachedStatus = initialStatus
        self.verifiedClient = initialVerifiedClient
        self.epoch = initialEpoch
        self.connected = initialEpoch != nil && initialVerifiedClient != nil
        attach(endpoint)
    }

    /// Explicit lazy-factory injection for transport checks. Production never
    /// uses this path; it always constructs the signed XPC endpoint above.
    init(endpointFactory: @escaping () throws -> BrokerEndpoint,
         ownIdentity: BrokerApplicationIdentity,
         helperPath: String = BrokerClient.defaultHelperPath,
         initialStatus: BrokerStatus? = nil, initialVerifiedClient: BrokerApplicationIdentity? = nil,
         initialEpoch: UUID? = nil, responseTimeout: Duration = .seconds(10)) {
        self.endpoint = nil
        self.endpointFactory = endpointFactory
        self.ownIdentity = ownIdentity
        self.helperPath = helperPath
        self.testEndpoint = true
        self.responseTimeout = responseTimeout
        self.cachedStatus = initialStatus
        self.verifiedClient = initialVerifiedClient
        self.epoch = initialEpoch
        self.connected = initialEpoch != nil && initialVerifiedClient != nil
    }

    /// Closure injection keeps isolated UI checks independent of NSXPC while
    /// retaining the same Data request/response codec and correlation checks.
    convenience init(testExchange: @escaping (Data) async throws -> Data,
         ownIdentity: BrokerApplicationIdentity,
         helperPath: String = BrokerClient.defaultHelperPath,
         initialStatus: BrokerStatus? = nil, initialVerifiedClient: BrokerApplicationIdentity? = nil,
         initialEpoch: UUID? = nil, responseTimeout: Duration = .seconds(10)) {
        self.init(endpoint: ClosureBrokerEndpoint(exchange: testExchange), ownIdentity: ownIdentity,
            helperPath: helperPath, initialStatus: initialStatus,
            initialVerifiedClient: initialVerifiedClient, initialEpoch: initialEpoch,
            responseTimeout: responseTimeout)
    }

    nonisolated static var defaultHelperPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PromptBridge Accessibility.app")
            .standardizedFileURL.path
    }

    var isConnected: Bool { connected }
    var status: BrokerStatus? { cachedStatus }
    var runtimeState: BrokerRuntimeState? { cachedRuntimeState }

    var connectionDescription: String {
        guard connected else { return "Accessibility helper 未连接" }
        guard let status = cachedStatus else { return "Accessibility helper 已连接" }
        return "Accessibility helper \(status.version)/\(status.build) · 权限\(status.permission ? "已授权" : "未授权")"
    }

    @discardableResult
    func addEventSubscriber(_ handler: @escaping (BrokerEvent) -> Void) -> UUID {
        let id = UUID(); eventSubscribers[id] = handler; return id
    }

    func removeEventSubscriber(_ id: UUID) { eventSubscribers.removeValue(forKey: id) }

    @discardableResult
    func addDisconnectSubscriber(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID(); disconnectSubscribers[id] = handler; return id
    }

    func removeDisconnectSubscriber(_ id: UUID) { disconnectSubscribers.removeValue(forKey: id) }

    func request(_ operation: BrokerOperation, payload: BrokerPayload? = nil) async throws -> BrokerResponse {
        try await request(operation, payload: payload, requestID: UUID())
    }

    func request(_ operation: BrokerOperation, payload: BrokerPayload? = nil,
                 requestID: UUID) async throws -> BrokerResponse {
        guard !DesktopInstallation.shared.busy else { throw BrokerTransportError.unavailable }
        try Task.checkCancellation()
        if operation == .handshake {
            return try await handshake()
        }
        try await ensureHandshake()
        try Task.checkCancellation()
        guard let epoch else { throw BrokerTransportError.unavailable }
        let request = BrokerRequest(operation: operation, epoch: epoch, requestID: requestID, payload: payload)
        return try await send(request)
    }

    func cancel(operationID: UUID) async -> BrokerCancelDisposition? {
        do {
            let response = try await request(.cancel, payload: BrokerPayload(operationID: operationID))
            return response.cancelDisposition
        } catch {
            return nil
        }
    }

    func disconnect() {
        connectionGeneration &+= 1
        handshakeTask = nil
        let endpoint = self.endpoint
        let shouldNotify = !disconnectNotified
        self.endpoint = nil
        connected = false
        epoch = nil
        latestResponseSequence = 0
        latestEventSequence = 0
        latestStateSequence = 0
        cachedRuntimeState = nil
        disconnectNotified = true
        endpoint?.onEvent = nil
        endpoint?.onDisconnect = nil
        endpoint?.disconnect()
        if shouldNotify { notifyDisconnect() }
    }

    private func ensureEndpoint() throws -> BrokerEndpoint {
        if let endpoint { return endpoint }
        guard let endpointFactory else { throw BrokerTransportError.unavailable }
        let endpoint = try endpointFactory()
        self.endpoint = endpoint
        attach(endpoint)
        return endpoint
    }

    private func attach(_ endpoint: BrokerEndpoint) {
        connectionGeneration &+= 1
        let generation = connectionGeneration
        disconnectNotified = false
        endpoint.onEvent = { [weak self] data in self?.receiveEvent(data, generation: generation) }
        endpoint.onDisconnect = { [weak self] in self?.handleDisconnect(generation: generation) }
    }

    private func ensureHandshake() async throws {
        guard !connected else { return }
        _ = try await handshake()
    }

    private func handshake() async throws -> BrokerResponse {
        if connected, let epoch {
            _ = epoch
            throw BrokerRemoteError(code: .duplicateOperation,
                response: BrokerResponse(requestID: UUID(), epoch: epoch,
                    stateSequence: latestResponseSequence, error: .duplicateOperation))
        }
        if let handshakeTask { return try await handshakeTask.value }
        // The factory may attach a brand-new endpoint and advance the
        // connection generation. Bind the handshake to that generation only
        // after lazy endpoint creation, so its first reply is not rejected as
        // belonging to an older connection.
        if endpoint == nil { _ = try ensureEndpoint() }
        let generation = connectionGeneration
        let task = Task { @MainActor [weak self] () throws -> BrokerResponse in
            guard let self else { throw BrokerTransportError.unavailable }
            return try await self.performHandshake(generation: generation)
        }
        handshakeTask = task
        return try await task.value
    }

    private func performHandshake(generation: UInt64) async throws -> BrokerResponse {
        defer {
            if connectionGeneration == generation { handshakeTask = nil }
        }
        let request = BrokerRequest(operation: .handshake)
        let response: BrokerResponse
        do { response = try await send(request) }
        catch {
            if !(error is CancellationError) { disconnect(generation: generation) }
            throw error
        }
        guard generation == connectionGeneration else {
            throw BrokerTransportError.unavailable
        }
        guard response.error == nil,
              let status = response.status,
              let verifiedClient = response.verifiedClient,
              let ownIdentity,
              (try? ownIdentity.validate()) != nil,
              verifiedClient == ownIdentity else {
            disconnect(generation: generation)
            throw BrokerTransportError.invalidIdentity
        }
        do { try validateHelperStatus(status) }
        catch {
            disconnect(generation: generation)
            throw error
        }
        do { try status.validateSupportedOperations() }
        catch {
            disconnect(generation: generation)
            throw BrokerTransportError.incompatibleProtocol
        }
        cachedStatus = status
        self.verifiedClient = verifiedClient
        self.epoch = response.epoch
        connected = response.epoch != nil
        guard connected else {
            disconnect(generation: generation)
            throw BrokerTransportError.invalidIdentity
        }
        return response
    }

    private func send(_ request: BrokerRequest) async throws -> BrokerResponse {
        try Task.checkCancellation()
        let baseline = latestResponseSequence
        let generation = connectionGeneration
        let data: Data
        do {
            try request.validate()
            data = try BrokerCodec.encode(request)
        }
        catch { throw BrokerTransportError.invalidResponse }
        let replyData: Data
        do { replyData = try await exchange(data) }
        catch {
            if !(error is CancellationError) { disconnect(generation: generation) }
            throw error
        }
        guard generation == connectionGeneration,
              request.operation == .handshake || request.epoch == epoch else {
            throw BrokerTransportError.unavailable
        }
        let response: BrokerResponse
        do { response = try BrokerCodec.response(replyData, for: request, after: baseline) }
        catch {
            if !(error is CancellationError) { disconnect(generation: generation) }
            throw error
        }
        guard generation == connectionGeneration,
              request.operation == .handshake || request.epoch == epoch else {
            throw BrokerTransportError.unavailable
        }
        latestResponseSequence = max(latestResponseSequence, response.stateSequence)
        if let state = response.runtimeState, response.stateSequence > latestStateSequence {
            try? state.validate()
            cachedRuntimeState = state
            latestStateSequence = response.stateSequence
        }
        if let status = response.status {
            do {
                try status.validateSupportedOperations(allowMissing: true)
                try validateHelperStatus(status)
            }
            catch { disconnect(generation: generation); throw error }
            cachedStatus = status
        }
        if let error = response.error { throw BrokerRemoteError(code: error, response: response) }
        return response
    }

    private func exchange(_ data: Data) async throws -> Data {
        let endpoint = try ensureEndpoint()
        let job = BrokerExchangeJob(endpoint: endpoint, message: data)
        return try await withThrowingTaskGroup(of: Data.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await job.run() }
            group.addTask {
                try await Task.sleep(for: self.responseTimeout)
                throw BrokerTransportError.timeout
            }
            guard let result = try await group.next() else { throw BrokerTransportError.unavailable }
            return result
        }
    }

    private func receiveEvent(_ data: Data, generation: UInt64) {
        guard generation == connectionGeneration, connected, let epoch else { return }
        do {
            let event = try BrokerCodec.event(data, for: epoch, after: latestEventSequence)
            latestEventSequence = event.stateSequence
            if let state = event.runtimeState, event.stateSequence > latestStateSequence {
                try state.validate()
                cachedRuntimeState = state
                latestStateSequence = event.stateSequence
            }
            onEvent?(event)
            for subscriber in eventSubscribers.values { subscriber(event) }
        } catch {
            // A trusted helper that emits an invalid epoch, sequence, or state
            // cannot remain connected to this client.
            disconnect(generation: generation)
        }
    }

    private func validateHelperStatus(_ status: BrokerStatus) throws {
        guard status.pid > 0,
              status.bundle == BrokerIdentity.bundle,
              URL(fileURLWithPath: status.path).standardizedFileURL.path == helperPath,
              endpoint != nil else { throw BrokerTransportError.invalidIdentity }
        if !testEndpoint {
            guard status.certificateSHA1.uppercased() == (try BrokerIdentity.signingCertificate()) else {
                throw BrokerTransportError.invalidIdentity
            }
            guard let signedEndpoint = endpoint as? SignedXPCEndpoint,
                  status.pid == signedEndpoint.processIdentifier,
                  BrokerPeerIdentityPolicy.accepts(
                      peerUserIdentifier: signedEndpoint.peerUserIdentifier,
                      currentUserIdentifier: getuid()) else {
                throw BrokerTransportError.invalidIdentity
            }
        }
    }

    private func handleDisconnect(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        guard !disconnectNotified else { return }
        connectionGeneration &+= 1
        handshakeTask = nil
        disconnectNotified = true
        endpoint = nil
        connected = false
        epoch = nil
        cachedRuntimeState = nil
        latestResponseSequence = 0
        latestEventSequence = 0
        latestStateSequence = 0
        notifyDisconnect()
    }

    private func disconnect(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        disconnect()
    }

    private func notifyDisconnect() {
        onDisconnect?()
        for subscriber in disconnectSubscribers.values { subscriber() }
    }

    private static func currentIdentity() -> BrokerApplicationIdentity? {
        guard Bundle.main.bundleIdentifier == BrokerIdentity.clientBundle else { return nil }
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return BrokerApplicationIdentity(
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            bundle: BrokerIdentity.clientBundle,
            path: path,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }
}
