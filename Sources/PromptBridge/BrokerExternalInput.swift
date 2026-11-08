import AppKit
import AccessibilityContracts
import Foundation

@MainActor
final class ExternalInput: HostInput {
    var onChange: (() -> Void)?
    var onGeometryChange: (() -> Void)?
    var onObservedChange: ((String) -> Void)?
    var onReplacementStage: ((ReplacementStage) -> Void)?

    private let client: BrokerClient
    private var eventSubscription = UUID()
    private var disconnectSubscription = UUID()
    private var routeID = UUID()
    private var stateSequence: UInt64 = 0
    private var runtimeState: BrokerRuntimeState?
    private var target: BrokerTargetReference?
    private var captureReference: BrokerTargetReference?
    private var cachedSnapshot: InputSnapshot?
    private var replacementReceipt: ReplacementReceipt?
    private var lastRestorationToken: UUID?
    private var scopeIDs: Set<UUID> = []
    private var invalidatedCaptureTokens: Set<UUID> = []
    private var pendingCaptureRequestID: UUID?
    private var localWriteAttempts = 0
    private(set) var captureID = UUID()
    private(set) var lastReadFailure: String?
    private(set) var frameOnScreen: NSRect?

    init(client: BrokerClient = .shared) {
        self.client = client
        eventSubscription = client.addEventSubscriber { [weak self] event in
            self?.receive(event)
        }
        disconnectSubscription = client.addDisconnectSubscriber { [weak self] in
            self?.receiveDisconnect()
        }
    }

    static var hasAccessibilityPermission: Bool {
        BrokerClient.shared.cachedStatus?.permission == true
    }

    var isTargetAvailable: Bool { cachedSnapshot != nil }
    var isBrokerConnected: Bool { client.isConnected }
    var hasTarget: Bool { runtimeState?.hasTarget == true && cachedSnapshot != nil }
    var canReturnFocus: Bool { runtimeState?.canReturnFocus == true }
    var hostName: String { runtimeState?.hostName ?? "宿主" }
    var writeAttempts: Int { runtimeState?.writeAttempts ?? localWriteAttempts }
    var canRestoreOriginal: Bool {
        runtimeState?.canRestore == true && lastRestorationToken != nil && replacementReceipt != nil
    }

    func snapshot() -> InputSnapshot? { cachedSnapshot }

    func liveSnapshot() async -> InputSnapshot? {
        guard let target else { return nil }
        let route = routeID
        let epoch = client.epoch
        do {
            let response = try await client.request(.validate, payload: BrokerPayload(target: target))
            guard route == routeID, (epoch == nil || epoch == client.epoch),
                  let state = response.runtimeState,
                  let snapshot = state.snapshot,
                  snapshot.captureID == target.captureToken,
                  snapshot.revision == target.revision else { return nil }
            apply(state, sequence: response.stateSequence, preserveReceipt: true)
            return cachedSnapshot
        } catch {
            applyErrorState(error, route: route)
            return nil
        }
    }

    /// Read-only restoration validation for the post-write state where the
    /// helper intentionally withholds text. It never installs a capture target
    /// or snapshot; the write receipt and restoration token remain local gates.
    func liveRestorationIsValid() async -> Bool {
        guard canRestoreOriginal,
              let restorationToken = lastRestorationToken,
              let expected = replacementReceipt?.expected,
              let expectedCaptureID = expected.captureID else { return false }
        let route = routeID
        let epoch = client.epoch
        let capturedID = captureID
        let expectedRevision = expected.revision
        do {
            let response = try await client.request(.validate,
                payload: BrokerPayload(restorationToken: restorationToken))
            guard route == routeID,
                  (epoch == nil || epoch == client.epoch),
                  capturedID == captureID,
                  response.stateSequence >= stateSequence,
                  let state = response.runtimeState,
                  state.canRestore,
                  state.restorationToken == restorationToken,
                  state.captureToken == expectedCaptureID,
                  state.revision >= expectedRevision else { return false }
            if let snapshot = state.snapshot {
                guard state.hasTarget,
                      snapshot.captureID == expectedCaptureID,
                      snapshot.revision == state.revision else { return false }
            } else {
                guard !state.hasTarget else { return false }
            }
            return true
        } catch {
            return false
        }
    }

    func captureFrontmost() async throws {
        try await capture(scope: .selection)
    }

    func captureFullInput() async throws {
        try await capture(scope: .entireInput)
    }

    private func capture(scope: CaptureScope) async throws {
        let route = routeID
        let epoch = client.epoch
        let requestID = UUID()
        pendingCaptureRequestID = requestID
        let response: BrokerResponse
        do {
            response = try await client.request(.capture, payload: BrokerPayload(scope: scope), requestID: requestID)
        } catch {
            if pendingCaptureRequestID == requestID { pendingCaptureRequestID = nil }
            applyErrorState(error, route: route)
            throw mapReadError(error)
        }
        if pendingCaptureRequestID == requestID { pendingCaptureRequestID = nil }
        guard route == routeID, (epoch == nil || epoch == client.epoch),
              let state = response.runtimeState,
              let snapshot = state.snapshot,
              let captureToken = state.captureToken,
              snapshot.captureID == captureToken,
              snapshot.revision == state.revision else {
            if let staleSnapshot = response.runtimeState?.snapshot,
               let staleCaptureID = staleSnapshot.captureID {
                let staleTarget = BrokerTargetReference(captureToken: staleCaptureID,
                    revision: staleSnapshot.revision)
                Task { [weak self] in
                    guard let self else { return }
                    _ = try? await self.client.request(.invalidate,
                        payload: BrokerPayload(target: staleTarget))
                }
            }
            throw ExternalInputError.invalidSelection
        }
        apply(state, sequence: response.stateSequence, preserveReceipt: false)
        invalidatedCaptureTokens.remove(captureToken)
        replacementReceipt = nil
        lastRestorationToken = nil
        onChange?()
    }

    func replaceSelection(with text: String, expected: InputSnapshot) async throws -> ReplacementReceipt {
        guard let target,
              let captureID = expected.captureID,
              captureID == target.captureToken,
              expected.revision == target.revision,
              cachedSnapshot == expected else { throw FillError.targetChanged }
        let operationID = UUID()
        let route = routeID
        let epoch = client.epoch
        localWriteAttempts += 1
        onReplacementStage?(.returning)
        let response: BrokerResponse
        do {
            response = try await cancellableMutation(operationID: operationID) {
                try await self.client.request(.replace, payload: BrokerPayload(write: BrokerWritePayload(
                    operationID: operationID, target: target, expected: expected, text: text)))
            }
        } catch {
            applyErrorState(error, route: route)
            throw mapWriteError(error)
        }
        guard route == routeID, epoch == client.epoch,
              let receipt = response.replacementReceipt,
              receipt.expected == expected, receipt.writtenText == text,
              let state = response.runtimeState else { throw FillError.outcomeUnknown }
        apply(state, sequence: response.stateSequence, preserveReceipt: true)
        replacementReceipt = receipt
        lastRestorationToken = state.restorationToken
        onReplacementStage?(.verifying)
        return receipt
    }

    func restoreOriginalInput() async throws -> ReplacementReceipt {
        guard canRestoreOriginal, let restorationToken = lastRestorationToken else {
            throw FillError.targetChanged
        }
        let operationID = UUID()
        let route = routeID
        let epoch = client.epoch
        onReplacementStage?(.returning)
        let response: BrokerResponse
        do {
            response = try await cancellableMutation(operationID: operationID) {
                try await self.client.request(.restore, payload: BrokerPayload(restore: BrokerRestorePayload(
                    operationID: operationID, restorationToken: restorationToken)))
            }
        } catch {
            applyErrorState(error, route: route)
            throw mapWriteError(error)
        }
        guard route == routeID, epoch == client.epoch,
              let receipt = response.replacementReceipt,
              let state = response.runtimeState else { throw FillError.outcomeUnknown }
        apply(state, sequence: response.stateSequence, preserveReceipt: false)
        replacementReceipt = nil
        lastRestorationToken = state.restorationToken
        onReplacementStage?(.verifying)
        return receipt
    }

    func returnFocus(allowInvalidTarget: Bool = false, requireInputFocus: Bool = true) async -> Bool {
        guard allowInvalidTarget || target != nil else { return false }
        let route = routeID
        let epoch = client.epoch
        do {
            let response = try await client.request(.returnFocus,
                payload: BrokerPayload(target: target, allowInvalidTarget: allowInvalidTarget))
            guard route == routeID, (epoch == nil || epoch == client.epoch) else { return false }
            // The wire contract has one focus result. The legacy parameter is
            // retained for callers; the broker always owns input-focus policy.
            _ = requireInputFocus
            return response.focusReturned == true
        } catch {
            applyErrorState(error, route: route)
            return false
        }
    }

    func prepareForPanelActivation() async throws -> BrokerScopeReceipt {
        try await acquireScope(.panel)
    }

    func beginPanelContextMenu() async throws -> BrokerScopeReceipt {
        try await acquireScope(.menu)
    }

    private func acquireScope(_ kind: BrokerScopeKind) async throws -> BrokerScopeReceipt {
        let route = routeID
        let epoch = client.epoch
        let stateSequenceAtStart = stateSequence
        let restoreTokenAtStart: UUID?
        let scopeTarget: BrokerTargetReference?
        if hasTarget {
            scopeTarget = target
            restoreTokenAtStart = nil
        } else if kind == .panel,
                  canRestoreOriginal,
                  let retainedReference = captureReference,
                  let restorationToken = lastRestorationToken,
                  runtimeState?.canRestore == true,
                  runtimeState?.captureToken == retainedReference.captureToken,
                  runtimeState?.revision == retainedReference.revision {
            // A panel scope may keep the verified restoration record alive
            // after a post-write event hides the text snapshot. The retained
            // reference is opaque and is never promoted back to a fill target.
            scopeTarget = retainedReference
            restoreTokenAtStart = restorationToken
        } else if kind == .panel {
            // Panel activation must bind either the authoritative capture or
            // an existing restoration record. An empty panel scope would ask
            // the helper to invent a host handoff.
            throw ExternalInputError.unavailable
        } else {
            // Menu scopes without a current capture only pause polling.
            scopeTarget = nil
            restoreTokenAtStart = nil
        }
        let response = try await client.request(.acquireScope, payload: BrokerPayload(
            scopeRequest: BrokerScopePayload(kind: kind, target: scopeTarget)))
        let restorationScopeStillValid: Bool
        if let scopeTarget, let restoreTokenAtStart {
            restorationScopeStillValid = kind == .panel
                && stateSequence >= stateSequenceAtStart
                && captureReference == scopeTarget
                && canRestoreOriginal
                && lastRestorationToken == restoreTokenAtStart
                && runtimeState?.canRestore == true
                && runtimeState?.captureToken == scopeTarget.captureToken
                && runtimeState?.revision == scopeTarget.revision
        } else {
            restorationScopeStillValid = true
        }
        guard route == routeID, (epoch == nil || epoch == client.epoch),
              let receipt = response.scopeReceipt,
              receipt.kind == kind,
              receipt.captureToken == scopeTarget?.captureToken,
              restorationScopeStillValid else {
            if let scopeID = response.scopeReceipt?.scopeID {
                Task { [weak self] in
                    guard let self else { return }
                    _ = try? await self.client.request(.releaseScope,
                        payload: BrokerPayload(scopeID: scopeID))
                }
            }
            throw ExternalInputError.unavailable
        }
        scopeIDs.insert(receipt.scopeID)
        return receipt
    }

    func endPanelContextMenu(_ scopeID: UUID) async {
        guard scopeIDs.remove(scopeID) != nil else { return }
        _ = try? await client.request(.releaseScope, payload: BrokerPayload(scopeID: scopeID))
    }

    func clear() {
        let oldTarget = captureReference ?? target ?? runtimeState?.captureToken.map {
            BrokerTargetReference(captureToken: $0, revision: runtimeState?.revision ?? 0)
        }
        let oldCaptureRequestID = pendingCaptureRequestID
        pendingCaptureRequestID = nil
        if let captureToken = oldTarget?.captureToken ?? runtimeState?.captureToken {
            invalidatedCaptureTokens.insert(captureToken)
        }
        routeID = UUID()
        target = nil
        captureReference = nil
        cachedSnapshot = nil
        runtimeState = nil
        stateSequence = 0
        frameOnScreen = nil
        lastReadFailure = nil
        replacementReceipt = nil
        lastRestorationToken = nil
        captureID = UUID()
        let scopes = scopeIDs
        scopeIDs.removeAll()
        if oldTarget != nil || !scopes.isEmpty { onChange?(); onGeometryChange?() }
        if let oldTarget {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.client.request(.invalidate, payload: BrokerPayload(target: oldTarget))
            }
        }
        if let oldCaptureRequestID {
            Task { [weak self] in
                guard let self else { return }
                _ = await self.client.cancel(operationID: oldCaptureRequestID)
            }
        }
        for scopeID in scopes {
            Task { [weak self] in
                guard let self else { return }
                _ = try? await self.client.request(.releaseScope, payload: BrokerPayload(scopeID: scopeID))
            }
        }
    }

    private func cancellableMutation(operationID: UUID,
                                     body: @escaping () async throws -> BrokerResponse) async throws -> BrokerResponse {
        do {
            return try await body()
        } catch is CancellationError {
            let disposition = await Task { @MainActor [client] in
                await client.cancel(operationID: operationID)
            }.value
            guard let disposition else {
                throw FillError.outcomeUnknown
            }
            switch disposition {
            case .cancelledBeforeSetter: throw FillError.cancelled
            case .outcomeUnknown: throw FillError.outcomeUnknown
            case .notActive: throw FillError.outcomeUnknown
            }
        }
    }

    private func apply(_ state: BrokerRuntimeState, sequence: UInt64, preserveReceipt: Bool) {
        guard sequence >= stateSequence else { return }
        let hadFrame = frameOnScreen
        stateSequence = sequence
        runtimeState = state
        if let snapshot = state.snapshot {
            cachedSnapshot = snapshot
            target = snapshot.captureID.map { BrokerTargetReference(captureToken: $0, revision: snapshot.revision) }
            captureReference = target
        } else if state.canRestore {
            // A post-write notification may intentionally omit text while the
            // restoration receipt remains valid. Keep the token for focus and
            // invalidation, but clear the cached snapshot so fill/generate stay disabled.
            cachedSnapshot = nil
            target = nil
            if let captureToken = state.captureToken {
                captureReference = BrokerTargetReference(captureToken: captureToken, revision: state.revision)
            }
        } else if !state.hasTarget {
            cachedSnapshot = nil
            target = nil
            captureReference = nil
        }
        if let captureToken = state.captureToken { captureID = captureToken }
        frameOnScreen = state.frame.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
        lastReadFailure = state.lastReadFailure
        lastRestorationToken = state.restorationToken
        if !preserveReceipt && !state.canRestore { replacementReceipt = nil }
        if hadFrame != frameOnScreen { onGeometryChange?() }
        if let change = state.lastObservedChange { onObservedChange?(change) }
        if let stage = state.replacementStage { onReplacementStage?(stage) }
    }

    private func receive(_ event: BrokerEvent) {
        guard event.stateSequence >= stateSequence else { return }
        if event.invalidated,
           pendingCaptureRequestID != nil,
           target == nil,
           captureReference == nil,
           let state = event.runtimeState,
           state.snapshot == nil,
           state.captureToken == nil,
           !state.hasTarget,
           !state.canRestore {
            // During a full capture the runtime publishes a targetless
            // invalidation while it waits for the selection/range commit.
            // It is capture progress metadata, not cancellation of this
            // request. Keep the route and pending request until its response.
            apply(state, sequence: event.stateSequence, preserveReceipt: true)
            return
        }
        if event.invalidated {
            let hadFrame = frameOnScreen
            if let captureToken = captureReference?.captureToken ?? target?.captureToken ?? event.runtimeState?.captureToken {
                invalidatedCaptureTokens.insert(captureToken)
            }
            pendingCaptureRequestID = nil
            stateSequence = event.stateSequence
            routeID = UUID()
            target = nil
            captureReference = nil
            cachedSnapshot = nil
            runtimeState = event.runtimeState
            frameOnScreen = event.runtimeState?.frame.map {
                NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            }
            replacementReceipt = nil
            lastRestorationToken = nil
            captureID = UUID()
            onChange?()
            if hadFrame != frameOnScreen { onGeometryChange?() }
        } else if let state = event.runtimeState {
            if let captureToken = state.captureToken,
               invalidatedCaptureTokens.contains(captureToken) { return }
            if let captureToken = state.snapshot?.captureID,
               invalidatedCaptureTokens.contains(captureToken) { return }
            if state.snapshot == nil && state.canRestore && replacementReceipt == nil { return }
            apply(state, sequence: event.stateSequence, preserveReceipt: true)
        }
    }

    private func receiveDisconnect() {
        let hadFrame = frameOnScreen
        if let captureToken = captureReference?.captureToken ?? target?.captureToken ?? runtimeState?.captureToken {
            invalidatedCaptureTokens.insert(captureToken)
        }
        pendingCaptureRequestID = nil
        routeID = UUID()
        stateSequence = 0
        target = nil
        captureReference = nil
        cachedSnapshot = nil
        runtimeState = nil
        frameOnScreen = nil
        lastReadFailure = nil
        replacementReceipt = nil
        lastRestorationToken = nil
        captureID = UUID()
        onChange?()
        if hadFrame != frameOnScreen { onGeometryChange?() }
    }

    private func applyErrorState(_ error: Error, route: UUID) {
        guard route == routeID,
              let remote = error as? BrokerRemoteError,
              let state = remote.response.runtimeState else { return }
        apply(state, sequence: remote.response.stateSequence, preserveReceipt: false)
    }

    private func mapReadError(_ error: Error) -> Error {
        if let remote = error as? BrokerRemoteError {
            switch remote.code {
            case .permissionRequired: return ExternalInputError.permissionRequired
            case .hostRejected: return ExternalInputError.unsupportedApplication
            case .secureInput: return ExternalInputError.secureInput
            case .compositionActive: return ExternalInputError.compositionActive
            case .notEditable: return ExternalInputError.noFocusedInput
            case .targetChanged, .identityChanged: return ExternalInputError.invalidSelection
            case .unavailable, .disconnected, .staleEpoch, .handshakeRequired: return ExternalInputError.unavailable
            default: return ExternalInputError.unavailable
            }
        }
        return ExternalInputError.unavailable
    }

    private func mapWriteError(_ error: Error) -> Error {
        if let fill = error as? FillError { return fill }
        if let remote = error as? BrokerRemoteError {
            switch remote.code {
            case .targetChanged, .identityChanged, .notEditable: return FillError.targetChanged
            case .compositionActive: return FillError.compositionActive
            case .clipboardUnavailable: return FillError.clipboardUnavailable
            case .clipboardChanged: return FillError.clipboardChanged
            case .selectionUnavailable: return FillError.selectionUnavailable
            case .protectedContent: return FillError.protectedContent
            // A verified component-level cancelled response is only emitted
            // before the setter. Transport cancellation and missing replies
            // never arrive here and remain outcomeUnknown below.
            case .cancelled: return FillError.cancelled
            case .outcomeUnknown: return FillError.outcomeUnknown
            default: return FillError.outcomeUnknown
            }
        }
        return FillError.outcomeUnknown
    }
}
