import AppKit
import AccessibilityContracts

/// The main-process boundary for the production accessibility implementation.
/// AX objects, observers, recovery records, and live validation stay behind this
/// facade; callers exchange only Foundation contract values.
@MainActor public final class AccessibilityRuntimeHost {
    public var onStateChange: (() -> Void)?
    public var onFocusChange: ((BrokerFocusState) -> Void)?
    public var onObservedChange: ((String) -> Void)?
    public var onReplacementStage: ((ReplacementStage) -> Void)?

    public private(set) var setterIssuedForOperation = false

    private struct ScopeRecord {
        let kind: BrokerScopeKind
        let captureToken: UUID?
    }

    private let client: BrokerApplicationIdentity
    private let backend: ExternalInput
    private lazy var focusMonitor: FocusLauncherMonitor = {
        FocusLauncherMonitor(client: client) { [weak self] state in
            self?.receiveFocusState(state)
        }
    }()
    private var scopes: [UUID: ScopeRecord] = [:]
    private var explicitPollingPause = false
    private var restorationToken: UUID?
    private var lastObservedChange: String?
    private var replacementStage: ReplacementStage?
    private var lastFocusTarget: FocusLauncherTarget?
    private var lastFocusState: BrokerFocusState = .unavailable

    public init(client: BrokerApplicationIdentity) {
        self.client = client
        self.backend = ExternalInput(access: SystemExternalInputAccess(client: client))
        installBackendCallbacks()
    }

    /// Fixture-only initializer for Runtime checks. It is internal so the
    /// production broker can only construct the facade from a verified client.
    init(syntheticAccess access: any ExternalInputAccess) {
        self.client = BrokerApplicationIdentity(pid: 1, bundle: "fixture.client",
            path: "/fixture/client", version: "fixture", build: "fixture")
        self.backend = ExternalInput(access: access)
        installBackendCallbacks()
    }

    private func installBackendCallbacks() {
        backend.onChange = { [weak self] in self?.publishState() }
        backend.onGeometryChange = { [weak self] in self?.publishState() }
        backend.onObservedChange = { [weak self] value in
            guard let self else { return }
            lastObservedChange = value
            onObservedChange?(value)
            synchronizeRestorationToken()
            publishState()
        }
        backend.onReplacementStage = { [weak self] stage in
            guard let self else { return }
            replacementStage = stage
            onReplacementStage?(stage)
            publishState()
        }
        backend.onWriteIssued = { [weak self] in
            // This flag intentionally survives backend defer blocks. A setter may
            // have crossed the process boundary before it reports an error.
            self?.setterIssuedForOperation = true
            self?.publishState()
        }
    }

    public func cachedState() -> BrokerRuntimeState {
        makeState()
    }

    public func capture(_ scope: CaptureScope) async throws -> BrokerRuntimeState {
        try await backend.captureFrontmost(scope: scope)
        synchronizeRestorationToken()
        publishState()
        return makeState()
    }

    public func validate(_ target: BrokerTargetReference) async throws -> BrokerRuntimeState {
        try requireCachedTarget(target)
        guard backend.liveSnapshot(target) != nil else { throw ExternalInputError.invalidSelection }
        publishState()
        return makeState()
    }

    /// Performs a live, read-only check of the opaque restoration record. This
    /// path deliberately does not require a current capture snapshot and never
    /// creates a new selection. The backend getter performs the native text,
    /// context, focus, running-process, and saved-control comparison; its
    /// cached counterpart is intentionally not used here.
    public func validateRestoration(_ token: UUID) async throws -> BrokerRuntimeState {
        guard restorationToken == token, backend.hasRestoreRecord else {
            throw FillError.targetChanged
        }
        guard backend.canRestoreOriginal else {
            synchronizeRestorationToken()
            publishState()
            throw FillError.targetChanged
        }
        publishState()
        return makeState()
    }

    public func replace(_ payload: BrokerWritePayload) async throws -> ReplacementReceipt {
        try payload.validate()
        try requireCachedTarget(payload.target)
        guard backend.cachedSnapshot == payload.expected else { throw FillError.targetChanged }
        let receipt = try await backend.replaceSelection(with: payload.text, expected: payload.expected)
        if restorationToken == nil { restorationToken = UUID() }
        publishState()
        return receipt
    }

    public func restore(_ payload: BrokerRestorePayload) async throws -> ReplacementReceipt {
        guard let restorationToken, restorationToken == payload.restorationToken,
              backend.hasRestoreRecord else { throw FillError.targetChanged }
        let receipt = try await backend.restoreOriginalInput()
        self.restorationToken = nil
        publishState()
        return receipt
    }

    public func returnFocus(_ target: BrokerTargetReference?, allowInvalidTarget: Bool) async throws -> Bool {
        if let target {
            try requireReturnTarget(target, allowInvalidTarget: allowInvalidTarget)
        } else if !allowInvalidTarget && backend.cachedSnapshot == nil {
            throw BrokerContractError.staleResponse
        }
        let returned = await backend.returnFocus(allowInvalidTarget: allowInvalidTarget)
        publishState()
        return returned
    }

    public func probeCodex() throws -> Data {
        try CodexCapabilityProbe.probeData()
    }

    public func probeInputSupport() throws -> Data {
        try InputSupportProbe.probeData()
    }

    public func acquireScope(_ payload: BrokerScopePayload) throws -> BrokerScopeReceipt {
        let captureToken: UUID?
        switch payload.kind {
        case .panel:
            guard let target = payload.target else { throw BrokerContractError.invalidMessage }
            if backend.cachedSnapshot != nil {
                try requireCachedTarget(target)
            } else {
                // A panel may remain frontmost while the capture generation is
                // invalidated after a verified write.  It can activate only for
                // the retained receipt reference at the current revision; it
                // never authorizes a fresh capture or an arbitrary target.
                guard restorationToken != nil, backend.hasRestoreRecord else {
                    throw BrokerContractError.staleResponse
                }
                try requireReturnTarget(target, allowInvalidTarget: true)
            }
            backend.prepareForPanelActivation(captureToken: target.captureToken)
            captureToken = target.captureToken
        case .menu:
            if let target = payload.target {
                try requireCachedTarget(target)
                guard backend.beginPanelContextMenu(captureToken: target.captureToken) else {
                    throw BrokerContractError.staleResponse
                }
                captureToken = target.captureToken
            } else {
                // A menu without a target only pauses focus polling. It never
                // authorizes an AX read or creates a host handoff.
                captureToken = nil
            }
        }
        let id = UUID()
        scopes[id] = ScopeRecord(kind: payload.kind, captureToken: captureToken)
        updatePollingPause()
        return BrokerScopeReceipt(scopeID: id, kind: payload.kind, captureToken: captureToken)
    }

    public func releaseScope(_ id: UUID) throws {
        guard let record = scopes.removeValue(forKey: id) else {
            throw BrokerContractError.staleResponse
        }
        switch record.kind {
        case .panel:
            if let token = record.captureToken { backend.endPanelActivation(captureToken: token) }
        case .menu:
            if let token = record.captureToken { backend.endPanelContextMenu(captureToken: token) }
        }
        updatePollingPause()
    }

    public func setLauncherMode(_ mode: LauncherMode) {
        focusMonitor.setMode(mode)
    }

    public func setPollingPaused(_ paused: Bool) {
        explicitPollingPause = paused
        updatePollingPause()
    }

    public func resetOperationWriteState() {
        setterIssuedForOperation = false
    }

    public func clear() {
        backend.clear()
        scopes.removeAll()
        restorationToken = nil
        replacementStage = nil
        lastObservedChange = nil
        explicitPollingPause = false
        focusMonitor.setPollingPaused(false)
        publishState()
    }

    private func requireCachedTarget(_ target: BrokerTargetReference) throws {
        guard let snapshot = backend.cachedSnapshot,
              snapshot.captureID == target.captureToken,
              snapshot.revision == target.revision else {
            throw BrokerContractError.staleResponse
        }
    }

    private func requireReturnTarget(_ target: BrokerTargetReference,
                                     allowInvalidTarget: Bool) throws {
        if backend.cachedSnapshot != nil {
            try requireCachedTarget(target)
            return
        }
        guard allowInvalidTarget else { throw BrokerContractError.staleResponse }
        if let restorationReference = backend.cachedRestorationReference {
            guard target.captureToken == restorationReference.captureToken,
                  target.revision == backend.currentRevision else {
                throw BrokerContractError.staleResponse
            }
            return
        }
        guard backend.hasTarget, target.captureToken == backend.captureID,
              target.revision == backend.currentRevision else {
            throw BrokerContractError.staleResponse
        }
    }

    private func synchronizeRestorationToken() {
        if !backend.hasRestoreRecord { restorationToken = nil }
    }

    private func updatePollingPause() {
        let menuWithoutTarget = scopes.values.contains { $0.kind == .menu && $0.captureToken == nil }
        focusMonitor.setPollingPaused(explicitPollingPause || menuWithoutTarget)
    }

    private func publishState() {
        synchronizeRestorationToken()
        onStateChange?()
    }

    private func makeState() -> BrokerRuntimeState {
        let snapshot = backend.cachedSnapshot
        let restorationReference = backend.cachedRestorationReference
        let captureToken = snapshot?.captureID ?? restorationReference?.captureToken
            ?? (backend.hasTarget ? backend.captureID : nil)
        let stateRevision = snapshot?.revision ?? backend.currentRevision
        return BrokerRuntimeState(
            snapshot: snapshot,
            captureToken: captureToken,
            revision: stateRevision,
            frame: backend.frameOnScreen.map(Self.rect),
            restorationToken: restorationToken,
            canRestore: backend.cachedCanRestoreOriginal && restorationToken != nil,
            canReturnFocus: backend.cachedCanReturnFocus,
            // The captured application may remain retained solely for a verified
            // restoration record after a late value/focus notification.  That
            // record permits one restore/return-focus path, but the invalidated
            // capture must not remain a fillable target in the wire state.
            hasTarget: snapshot != nil,
            hostName: backend.hostName,
            lastReadFailure: backend.lastReadFailure?.rawValue,
            writeAttempts: backend.writeAttempts,
            lastObservedChange: lastObservedChange,
            replacementStage: replacementStage)
    }

    private func receiveFocusState(_ state: FocusLauncherState) {
        let broker: BrokerFocusState
        switch state {
        case .ownApplication:
            lastFocusTarget = nil
            broker = .ownApplication
        case .unavailable:
            lastFocusTarget = nil
            broker = .unavailable
        case .target(let target):
            let tokens: (UUID, UUID)
            if let previous = lastFocusTarget,
               previous.windowIdentity == target.windowIdentity,
               previous.inputIdentity == target.inputIdentity,
               case .target(let old) = lastFocusState {
                tokens = (old.windowToken, old.inputToken)
            } else {
                tokens = (UUID(), UUID())
            }
            lastFocusTarget = target
            broker = .target(BrokerFocusTarget(pid: Int32(target.pid), bundle: target.bundle,
                windowToken: tokens.0, inputToken: tokens.1, anchor: Self.rect(target.anchor)))
        }
        guard broker != lastFocusState else { return }
        lastFocusState = broker
        onFocusChange?(broker)
    }

    private static func rect(_ value: NSRect) -> BrokerRect {
        BrokerRect(x: value.origin.x, y: value.origin.y,
                   width: value.size.width, height: value.size.height)
    }
}
