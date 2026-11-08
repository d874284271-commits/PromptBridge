#if PROMPTBRIDGE_TESTING
import Foundation
import AccessibilityContracts

/// Foundation-only transport fixtures for the main application's route and
/// connection gates. Every fixture goes through BrokerCodec JSON so it cannot
/// accidentally test an in-memory shape that the wire would reject.
@MainActor
func runBrokerClientChecks() async -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func record(_ name: String, _ passed: Bool) { results.append((name, passed)) }

    record("same UID policy rejects a mismatched fixture peer",
           !BrokerPeerIdentityPolicy.accepts(peerUserIdentifier: 1001, currentUserIdentifier: 1002))

    let firstLazyFixture = BrokerFixtureEndpoint()
    firstLazyFixture.holdHandshake = false
    let secondLazyFixture = BrokerFixtureEndpoint()
    secondLazyFixture.holdHandshake = false
    var lazyFactoryCount = 0
    var lazyFixtures = [firstLazyFixture, secondLazyFixture]
    let lazyClient = BrokerClient(endpointFactory: {
        lazyFactoryCount += 1
        return lazyFixtures.removeFirst()
    }, ownIdentity: fixtureIdentity(), helperPath: fixtureHelperPath)
    let firstLazyResponse = try? await lazyClient.request(.capture,
        payload: BrokerPayload(scope: .selection))
    let firstLazyHandshakeCount = firstLazyFixture.handshakeCount
    lazyClient.disconnect()
    let secondLazyResponse = try? await lazyClient.request(.capture,
        payload: BrokerPayload(scope: .selection))
    record("lazy factory first handshake succeeds and does not reuse old task",
           firstLazyResponse != nil && secondLazyResponse != nil
               && lazyFactoryCount == 2
               && firstLazyHandshakeCount == 1
               && secondLazyFixture.handshakeCount == 1
               && lazyClient.isConnected)

    let oldLazyFixture = BrokerFixtureEndpoint()
    var oldLazyFactoryCount = 0
    let oldLazyClient = BrokerClient(endpointFactory: {
        oldLazyFactoryCount += 1
        return oldLazyFixture
    }, ownIdentity: fixtureIdentity(), helperPath: fixtureHelperPath)
    let oldLazyTask = Task { @MainActor in
        try? await oldLazyClient.request(.capture, payload: BrokerPayload(scope: .selection))
    }
    await yieldFixture()
    oldLazyClient.disconnect()
    oldLazyFixture.releaseHandshake()
    let oldLazyResponse = await oldLazyTask.value
    record("lazy handshake reply after disconnect is rejected",
           oldLazyResponse == nil && oldLazyFactoryCount == 1
               && oldLazyClient.runtimeState == nil && !oldLazyClient.isConnected)

    let overlapOldFixture = BrokerFixtureEndpoint()
    let overlapNewFixture = BrokerFixtureEndpoint()
    overlapNewFixture.holdHandshake = false
    var overlapFactoryCount = 0
    var overlapFixtures = [overlapOldFixture, overlapNewFixture]
    let overlapClient = BrokerClient(endpointFactory: {
        overlapFactoryCount += 1
        return overlapFixtures.removeFirst()
    }, ownIdentity: fixtureIdentity(), helperPath: fixtureHelperPath)
    let overlapOldTask = Task { @MainActor in
        try? await overlapClient.request(.capture, payload: BrokerPayload(scope: .selection))
    }
    await yieldFixture()
    overlapClient.disconnect()
    let overlapNewResponse = try? await overlapClient.request(.capture,
        payload: BrokerPayload(scope: .selection))
    overlapOldFixture.releaseHandshake()
    let overlapOldResponse = await overlapOldTask.value
    record("old lazy handshake cleanup cannot disconnect a newer connection",
           overlapNewResponse != nil && overlapOldResponse == nil
               && overlapFactoryCount == 2
               && overlapClient.isConnected
               && overlapClient.epoch == overlapNewFixture.epoch)

    let handshakeFixture = BrokerFixtureEndpoint()
    let handshakeClient = makeFixtureClient(handshakeFixture)
    let first = Task { @MainActor in
        try? await handshakeClient.request(.capture,
            payload: BrokerPayload(scope: .selection))
    }
    await yieldFixture()
    let second = Task { @MainActor in
        try? await handshakeClient.request(.capture,
            payload: BrokerPayload(scope: .selection))
    }
    await yieldFixture()
    first.cancel()
    handshakeFixture.releaseHandshake()
    let secondResponse = await second.value
    _ = await first.value
    record("concurrent handshake is shared and one waiter cancellation does not cancel another",
           handshakeFixture.handshakeCount == 1 && secondResponse != nil && handshakeClient.isConnected)

    let legacyFixture = BrokerFixtureEndpoint()
    legacyFixture.holdHandshake = false
    legacyFixture.supportedOperationsOverride = nil
    let legacyClient = makeFixtureClient(legacyFixture)
    let legacyResponse = try? await legacyClient.request(.capture,
        payload: BrokerPayload(scope: .selection))
    record("protocol version 1 without production capabilities rejects the old PoC",
           legacyResponse == nil && !legacyClient.isConnected)

    let unverifiedFixture = BrokerFixtureEndpoint()
    unverifiedFixture.holdHandshake = false
    unverifiedFixture.includeVerifiedClient = false
    let unverifiedClient = makeFixtureClient(unverifiedFixture)
    let unverifiedResponse = try? await unverifiedClient.request(.capture,
        payload: BrokerPayload(scope: .selection))
    record("protocol version 1 without verified client identity rejects the old PoC",
           unverifiedResponse == nil && !unverifiedClient.isConnected)

    let incompleteFixture = BrokerFixtureEndpoint()
    incompleteFixture.holdHandshake = false
    incompleteFixture.supportedOperationsOverride = [.capture, .validate, .replace]
    let incompleteClient = makeFixtureClient(incompleteFixture)
    let incompleteResponse = try? await incompleteClient.request(.capture,
        payload: BrokerPayload(scope: .selection))
    record("protocol version 1 with missing production operations is rejected",
           incompleteResponse == nil && !incompleteClient.isConnected)

    let capableFixture = BrokerFixtureEndpoint()
    capableFixture.holdHandshake = false
    let capableClient = makeFixtureClient(capableFixture)
    let capableResponse = try? await capableClient.request(.capture,
        payload: BrokerPayload(scope: .selection))
    record("complete production capability metadata permits the handshake",
           capableResponse != nil && capableClient.isConnected)

    let readonlyFixture = BrokerFixtureEndpoint()
    let readonlyClient = makeConnectedFixtureClient(readonlyFixture)
    let readonlyExternal = ExternalInput(client: readonlyClient)
    try? await readonlyExternal.captureFrontmost()
    let readonlySnapshot = readonlyExternal.snapshot()
    record("selection capture returns a readonly DTO",
           readonlySnapshot?.captureScope == .selection
               && readonlySnapshot?.supportsDirectFill == false
               && readonlySnapshot?.fullText == nil)

    let lateFixture = BrokerFixtureEndpoint()
    lateFixture.holdCapture = true
    let lateClient = makeConnectedFixtureClient(lateFixture)
    let lateRequest = Task { @MainActor in
        try? await lateClient.request(.capture,
            payload: BrokerPayload(scope: .selection))
    }
    await yieldFixture()
    lateClient.disconnect()
    lateFixture.releaseCapture()
    let lateResponse = await lateRequest.value
    record("late response from a disconnected connection cannot update new client state",
           lateResponse == nil && lateClient.runtimeState == nil && !lateClient.isConnected)

    let captureFixture = BrokerFixtureEndpoint()
    captureFixture.holdCapture = true
    let captureClient = makeConnectedFixtureClient(captureFixture)
    let external = ExternalInput(client: captureClient)
    let captureTask = Task { @MainActor in
        try? await external.captureFrontmost()
    }
    await yieldFixture()
    external.clear()
    await yieldFixture()
    captureFixture.releaseCapture()
    _ = await captureTask.value
    await yieldFixture()
    let captureRequest = captureFixture.requests.first(where: { $0.operation == .capture })
    let captureWasCancelled = captureRequest.map {
        captureFixture.cancelledOperationIDs.contains($0.requestID)
    } ?? false
    record("clear cancels the exact pending capture request and rejects its late token",
           captureWasCancelled && external.snapshot() == nil && captureFixture.invalidatedTokenCount == 1)

    let pendingEventFixture = BrokerFixtureEndpoint()
    pendingEventFixture.holdCapture = true
    let pendingEventClient = makeConnectedFixtureClient(pendingEventFixture)
    let pendingEventExternal = ExternalInput(client: pendingEventClient)
    let pendingEventTask = Task { @MainActor in
        try? await pendingEventExternal.captureFullInput()
    }
    let captureStarted = await waitFixture { pendingEventFixture.captureStarted }
    pendingEventFixture.emitPendingCaptureInvalidation()
    pendingEventFixture.releaseCapture()
    _ = await pendingEventTask.value
    record("targetless pending capture invalidation preserves route for its response",
           captureStarted && pendingEventExternal.snapshot()?.captureScope == .entireInput
               && pendingEventExternal.hasTarget
               && pendingEventFixture.invalidatedTokenCount == 0)

    let tokenEventFixture = BrokerFixtureEndpoint()
    let tokenEventClient = makeConnectedFixtureClient(tokenEventFixture)
    let tokenEventExternal = ExternalInput(client: tokenEventClient)
    try? await tokenEventExternal.captureFullInput()
    let oldCaptureToken = tokenEventFixture.lastCaptureToken
    tokenEventExternal.clear()
    tokenEventFixture.holdCapture = true
    tokenEventFixture.captureStarted = false
    let tokenEventTask = Task { @MainActor in
        try? await tokenEventExternal.captureFullInput()
    }
    let tokenCaptureStarted = await waitFixture { tokenEventFixture.captureStarted }
    tokenEventFixture.emitPendingCaptureInvalidation(captureToken: oldCaptureToken)
    tokenEventFixture.releaseCapture()
    _ = await tokenEventTask.value
    await yieldFixture()
    record("token-bearing invalidation still rejects the late capture response",
           tokenCaptureStarted && tokenEventExternal.snapshot() == nil
               && tokenEventFixture.invalidatedTokenCount >= 2)

    let scopeFixture = BrokerFixtureEndpoint()
    scopeFixture.holdScope = true
    let scopeClient = makeConnectedFixtureClient(scopeFixture)
    let scopedExternal = ExternalInput(client: scopeClient)
    let scopeTask = Task { @MainActor in
        try? await scopedExternal.beginPanelContextMenu()
    }
    await yieldFixture()
    scopedExternal.clear()
    scopeFixture.releaseScope()
    _ = await scopeTask.value
    await yieldFixture()
    record("a late scope receipt is released by its exact scope ID",
           scopeFixture.releasedScopeIDs.contains(scopeFixture.lastScopeID ?? UUID())
               && scopeFixture.lastScopeID != nil)

    let restoreEventFixture = BrokerFixtureEndpoint()
    let restoreEventClient = makeConnectedFixtureClient(restoreEventFixture)
    let restoreEventExternal = ExternalInput(client: restoreEventClient)
    try? await restoreEventExternal.captureFullInput()
    if let expected = restoreEventExternal.snapshot() {
        _ = try? await restoreEventExternal.replaceSelection(with: "fixture", expected: expected)
    }
    restoreEventFixture.validateWithSnapshot = true
    let ordinaryReadonlyRestoreValid = await restoreEventExternal.liveRestorationIsValid()
    record("ordinary post-write validate keeps its authoritative snapshot",
           ordinaryReadonlyRestoreValid && restoreEventExternal.snapshot() != nil
               && restoreEventExternal.hasTarget)
    restoreEventFixture.validateWithSnapshot = false
    restoreEventFixture.emitLateRestoreEvent()
    record("post-write snapshotless event disables fill while retaining one restore receipt",
           restoreEventExternal.snapshot() == nil && restoreEventExternal.canRestoreOriginal
               && !restoreEventExternal.hasTarget)
    let restorePanel = try? await restoreEventExternal.prepareForPanelActivation()
    let panelRequest = restoreEventFixture.requests.last(where: {
        $0.operation == .acquireScope && $0.payload?.scopeRequest?.kind == .panel
    })
    let panelTarget = panelRequest?.payload?.scopeRequest?.target
    let retainedPanelReference = panelTarget?.captureToken == restoreEventFixture.lastCaptureToken
        && panelTarget?.revision == 2
        && restoreEventExternal.canRestoreOriginal
    if let restorePanel { await restoreEventExternal.endPanelContextMenu(restorePanel.scopeID) }
    record("snapshotless restore state binds panel scope to retained reference",
           restorePanel != nil && retainedPanelReference)
    let restoreScope = try? await restoreEventExternal.beginPanelContextMenu()
    let scopeRequestHasNoCapture = restoreEventFixture.requests.last(where: {
        $0.operation == .acquireScope
    })?.payload?.scopeRequest?.target == nil
    if let restoreScope { await restoreEventExternal.endPanelContextMenu(restoreScope.scopeID) }
    record("snapshotless menu scope carries no stale capture target", scopeRequestHasNoCapture)
    let validateCountBeforeSnapshotRead = restoreEventFixture.requests.filter { $0.operation == .validate }.count
    let snapshotlessLiveSnapshot = await restoreEventExternal.liveSnapshot()
    let validateCountAfterSnapshotRead = restoreEventFixture.requests.filter { $0.operation == .validate }.count
    record("snapshotless liveSnapshot does not issue a capture-target validate",
           snapshotlessLiveSnapshot == nil && validateCountBeforeSnapshotRead == validateCountAfterSnapshotRead)
    let readonlyRestoreValid = await restoreEventExternal.liveRestorationIsValid()
    var restoreSucceeded = false
    if readonlyRestoreValid {
        restoreSucceeded = (try? await restoreEventExternal.restoreOriginalInput()) != nil
    }
    let repeatedRestoreRejected = (try? await restoreEventExternal.restoreOriginalInput()) == nil
    record("snapshotless validate permits one token-bound restore and rejects repetition",
           readonlyRestoreValid && restoreSucceeded && repeatedRestoreRejected
               && restoreEventFixture.restoreCount == 1)
    restoreEventExternal.clear()
    restoreEventFixture.emitLateRestoreEvent()
    record("cleared route rejects the old snapshotless restore event",
           !restoreEventExternal.canRestoreOriginal && restoreEventExternal.snapshot() == nil)

    let emptyPanelFixture = BrokerFixtureEndpoint()
    let emptyPanelClient = makeConnectedFixtureClient(emptyPanelFixture)
    let emptyPanelExternal = ExternalInput(client: emptyPanelClient)
    let emptyPanelScope = try? await emptyPanelExternal.prepareForPanelActivation()
    record("panel scope without capture or restoration is rejected locally",
           emptyPanelScope == nil
               && !emptyPanelFixture.requests.contains(where: { $0.operation == .acquireScope }))

    let staleRevisionFixture = BrokerFixtureEndpoint()
    let staleRevisionClient = makeConnectedFixtureClient(staleRevisionFixture)
    let staleRevisionExternal = ExternalInput(client: staleRevisionClient)
    try? await staleRevisionExternal.captureFullInput()
    if let expected = staleRevisionExternal.snapshot() {
        _ = try? await staleRevisionExternal.replaceSelection(with: "fixture", expected: expected)
    }
    staleRevisionFixture.emitLateRestoreEvent()
    staleRevisionFixture.holdScope = true
    let staleRevisionTask = Task { @MainActor in
        try? await staleRevisionExternal.prepareForPanelActivation()
    }
    await yieldFixture()
    staleRevisionFixture.emitLateRestoreEvent(revision: 3)
    staleRevisionFixture.releaseScope()
    let staleRevisionScope = await staleRevisionTask.value
    await yieldFixture()
    let staleRevisionRequest = staleRevisionFixture.requests.last(where: {
        $0.operation == .acquireScope
    })
    let staleRevisionWasBound = staleRevisionRequest?.payload?.scopeRequest?.target?.captureToken
        == staleRevisionFixture.lastCaptureToken
        && staleRevisionRequest?.payload?.scopeRequest?.target?.revision == 2
    record("late panel receipt with an old revision is released and rejected",
           staleRevisionScope == nil && staleRevisionWasBound
               && staleRevisionFixture.releasedScopeIDs.contains(staleRevisionFixture.lastScopeID ?? UUID()))

    let staleTokenFixture = BrokerFixtureEndpoint()
    let staleTokenClient = makeConnectedFixtureClient(staleTokenFixture)
    let staleTokenExternal = ExternalInput(client: staleTokenClient)
    try? await staleTokenExternal.captureFullInput()
    if let expected = staleTokenExternal.snapshot() {
        _ = try? await staleTokenExternal.replaceSelection(with: "fixture", expected: expected)
    }
    staleTokenFixture.emitLateRestoreEvent()
    staleTokenFixture.holdScope = true
    let staleTokenTask = Task { @MainActor in
        try? await staleTokenExternal.prepareForPanelActivation()
    }
    await yieldFixture()
    staleTokenFixture.emitLateRestoreEvent(captureToken: UUID())
    staleTokenFixture.releaseScope()
    let staleTokenScope = await staleTokenTask.value
    await yieldFixture()
    let staleTokenRequest = staleTokenFixture.requests.last(where: {
        $0.operation == .acquireScope
    })
    let staleTokenWasBound = staleTokenRequest?.payload?.scopeRequest?.target?.captureToken
        == staleTokenFixture.lastCaptureToken
    record("late panel receipt with an old token is released and rejected",
           staleTokenScope == nil && staleTokenWasBound
               && staleTokenFixture.releasedScopeIDs.contains(staleTokenFixture.lastScopeID ?? UUID()))

    let cancelFixture = BrokerFixtureEndpoint()
    cancelFixture.cancelNextReplaceBeforeSetter = true
    let cancelClient = makeConnectedFixtureClient(cancelFixture)
    let cancelExternal = ExternalInput(client: cancelClient)
    try? await cancelExternal.captureFullInput()
    guard let expected = cancelExternal.snapshot() else {
        record("write cancellation obtains a component disposition without retry", false)
        record("disconnect during write cancellation reports outcome unknown without retry", false)
        return results
    }
    do {
        _ = try await cancelExternal.replaceSelection(with: "fixture", expected: expected)
        record("write cancellation obtains a component disposition without retry", false)
    } catch let error as FillError {
        record("write cancellation obtains a component disposition without retry",
               error == .cancelled && cancelFixture.replaceCount == 1 && cancelFixture.cancelCount == 1
                   && cancelClient.isConnected)
    } catch {
        record("write cancellation obtains a component disposition without retry", false)
    }

    let disconnectFixture = BrokerFixtureEndpoint()
    disconnectFixture.disconnectDuringReplace = true
    let disconnectClient = makeConnectedFixtureClient(disconnectFixture)
    let disconnectExternal = ExternalInput(client: disconnectClient)
    try? await disconnectExternal.captureFullInput()
    if let expected = disconnectExternal.snapshot() {
        do {
            _ = try await disconnectExternal.replaceSelection(with: "fixture", expected: expected)
            record("disconnect during write cancellation reports outcome unknown without retry", false)
        } catch let error as FillError {
            record("disconnect during write cancellation reports outcome unknown without retry",
                   error == .outcomeUnknown && disconnectFixture.replaceCount == 1
                       && disconnectFixture.cancelCount == 0)
        } catch {
            record("disconnect during write cancellation reports outcome unknown without retry", false)
        }
    } else {
        record("disconnect during write cancellation reports outcome unknown without retry", false)
    }

    let cancelledResponseFixture = BrokerFixtureEndpoint()
    cancelledResponseFixture.replaceErrorCode = .cancelled
    let cancelledResponseClient = makeConnectedFixtureClient(cancelledResponseFixture)
    let cancelledResponseExternal = ExternalInput(client: cancelledResponseClient)
    try? await cancelledResponseExternal.captureFullInput()
    if let expected = cancelledResponseExternal.snapshot() {
        do {
            _ = try await cancelledResponseExternal.replaceSelection(with: "fixture", expected: expected)
            record("verified cancelled wire response maps to cancelled without retry", false)
        } catch let error as FillError {
            record("verified cancelled wire response maps to cancelled without retry",
                   error == .cancelled && cancelledResponseFixture.replaceCount == 1
                       && cancelledResponseFixture.cancelCount == 0)
        } catch {
            record("verified cancelled wire response maps to cancelled without retry", false)
        }
    } else {
        record("verified cancelled wire response maps to cancelled without retry", false)
    }

    let unknownResponseFixture = BrokerFixtureEndpoint()
    unknownResponseFixture.replaceErrorCode = .outcomeUnknown
    let unknownResponseClient = makeConnectedFixtureClient(unknownResponseFixture)
    let unknownResponseExternal = ExternalInput(client: unknownResponseClient)
    try? await unknownResponseExternal.captureFullInput()
    if let expected = unknownResponseExternal.snapshot() {
        do {
            _ = try await unknownResponseExternal.replaceSelection(with: "fixture", expected: expected)
            record("verified unknown wire response remains unknown without retry", false)
        } catch let error as FillError {
            record("verified unknown wire response remains unknown without retry",
                   error == .outcomeUnknown && unknownResponseFixture.replaceCount == 1
                       && unknownResponseFixture.cancelCount == 0)
        } catch {
            record("verified unknown wire response remains unknown without retry", false)
        }
    } else {
        record("verified unknown wire response remains unknown without retry", false)
    }

    return results
}

@MainActor
private func yieldFixture() async {
    for _ in 0..<4 { await Task.yield() }
}

@MainActor
private func waitFixture(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private func makeFixtureClient(_ endpoint: BrokerFixtureEndpoint) -> BrokerClient {
    BrokerClient(endpoint: endpoint, ownIdentity: fixtureIdentity(), helperPath: fixtureHelperPath)
}

@MainActor
private func makeConnectedFixtureClient(_ endpoint: BrokerFixtureEndpoint) -> BrokerClient {
    BrokerClient(endpoint: endpoint, ownIdentity: fixtureIdentity(), helperPath: fixtureHelperPath,
        initialVerifiedClient: fixtureIdentity(), initialEpoch: endpoint.epoch)
}

private let fixtureHelperPath = "/fixture/PromptBridge Accessibility.app"

private func fixtureIdentity() -> BrokerApplicationIdentity {
    BrokerApplicationIdentity(pid: 41, bundle: BrokerIdentity.clientBundle,
        path: "/fixture/PromptBridge.app", version: "1", build: "1")
}

@MainActor
private final class BrokerFixtureEndpoint: BrokerEndpoint {
    var onEvent: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?

    let epoch = UUID()
    var requests: [BrokerRequest] = []
    var cancelledOperationIDs: Set<UUID> = []
    var releasedScopeIDs: Set<UUID> = []
    var invalidatedTokenCount = 0
    var handshakeCount = 0
    var replaceCount = 0
    var restoreCount = 0
    var cancelCount = 0
    var disconnectCount = 0
    var lastScopeID: UUID?
    var scopeTargets: [BrokerTargetReference?] = []
    var lastCaptureToken: UUID?
    var lastRestorationToken: UUID?
    var holdHandshake = true
    var holdCapture = false
    var captureStarted = false
    var holdScope = false
    var supportedOperationsOverride: [BrokerOperation]? = BrokerOperation.requiredProductionOperations
    var includeVerifiedClient = true
    var validateWithSnapshot = false
    var cancelNextReplaceBeforeSetter = false
    var disconnectDuringReplace = false
    var replaceErrorCode: BrokerErrorCode?
    private var restoreConsumed = false

    private var handshakeWaiter: CheckedContinuation<Void, Never>?
    private var captureWaiter: CheckedContinuation<Void, Never>?
    private var scopeWaiter: CheckedContinuation<Void, Never>?
    private var sequence: UInt64 = 0

    func releaseHandshake() {
        holdHandshake = false
        handshakeWaiter?.resume()
        handshakeWaiter = nil
    }

    func releaseCapture() {
        holdCapture = false
        captureWaiter?.resume()
        captureWaiter = nil
    }

    func releaseScope() {
        holdScope = false
        scopeWaiter?.resume()
        scopeWaiter = nil
    }

    func exchange(_ message: Data) async throws -> Data {
        let request = try BrokerCodec.request(message)
        requests.append(request)
        switch request.operation {
        case .handshake:
            handshakeCount += 1
            if holdHandshake {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    handshakeWaiter = continuation
                }
            }
            return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: nextSequence(), status: status(),
                verifiedClient: includeVerifiedClient ? fixtureIdentity() : nil))
        case .capture:
            captureStarted = true
            if holdCapture {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    captureWaiter = continuation
                }
            }
            let token = UUID()
            lastCaptureToken = token
            let scope = request.payload?.scope ?? .selection
            let snapshot = fixtureSnapshot(captureID: token, revision: 1, scope: scope,
                supportsDirectFill: scope == .entireInput,
                fullText: scope == .entireInput ? "old" : nil)
            return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: nextSequence(), runtimeState: runtime(snapshot: snapshot)))
        case .acquireScope:
            if holdScope {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    scopeWaiter = continuation
                }
            }
            let scopeID = UUID()
            lastScopeID = scopeID
            scopeTargets.append(request.payload?.scopeRequest?.target)
            let requestScope = request.payload?.scopeRequest?.kind ?? .panel
            return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: nextSequence(), scopeReceipt: BrokerScopeReceipt(scopeID: scopeID,
                    kind: requestScope, captureToken: request.payload?.scopeRequest?.target?.captureToken)))
        case .releaseScope:
            if let scopeID = request.payload?.scopeID { releasedScopeIDs.insert(scopeID) }
            return try encoded(response: emptyResponse(for: request))
        case .validate:
            if let restorationToken = request.payload?.restorationToken,
               restorationToken == lastRestorationToken,
               let captureToken = lastCaptureToken {
                if validateWithSnapshot {
                    let snapshot = fixtureSnapshot(captureID: captureToken, revision: 2,
                        scope: .entireInput, selectedText: "fixture",
                        supportsDirectFill: true, fullText: "fixture")
                    return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                        stateSequence: nextSequence(), runtimeState: runtime(snapshot: snapshot)))
                }
                let state = BrokerRuntimeState(snapshot: nil, captureToken: captureToken, revision: 2,
                    frame: nil, restorationToken: restorationToken, canRestore: true,
                    canReturnFocus: true, hasTarget: false, hostName: "Fixture", lastReadFailure: nil,
                    writeAttempts: replaceCount, lastObservedChange: nil, replacementStage: .verifying)
                return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                    stateSequence: nextSequence(), runtimeState: state))
            }
            return try encoded(response: emptyResponse(for: request))
        case .invalidate:
            if request.payload?.target != nil { invalidatedTokenCount += 1 }
            return try encoded(response: emptyResponse(for: request))
        case .cancel:
            cancelCount += 1
            if let operationID = request.payload?.operationID { cancelledOperationIDs.insert(operationID) }
            return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: nextSequence(), cancelDisposition: .cancelledBeforeSetter))
        case .replace:
            replaceCount += 1
            if disconnectDuringReplace {
                onDisconnect?()
                throw CancellationError()
            }
            if cancelNextReplaceBeforeSetter {
                cancelNextReplaceBeforeSetter = false
                throw CancellationError()
            }
            guard let write = request.payload?.write else { throw BrokerTransportError.invalidResponse }
            if let replaceErrorCode {
                return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                    stateSequence: nextSequence(), error: replaceErrorCode))
            }
            let restorationToken = UUID()
            lastRestorationToken = restorationToken
            let snapshot = fixtureSnapshot(captureID: write.target.captureToken,
                revision: write.target.revision + 1, scope: .entireInput,
                selectedText: write.text, supportsDirectFill: true, fullText: write.text)
            return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: nextSequence(), runtimeState: runtime(snapshot: snapshot),
                replacementReceipt: ReplacementReceipt(expected: write.expected, writtenText: write.text)))
        case .restore:
            restoreCount += 1
            guard let restore = request.payload?.restore,
                  !restoreConsumed, restore.restorationToken == lastRestorationToken,
                  let captureToken = lastCaptureToken else {
                throw BrokerTransportError.invalidResponse
            }
            restoreConsumed = true
            let restored = fixtureSnapshot(captureID: captureToken, revision: 3, scope: .entireInput,
                supportsDirectFill: true, fullText: "old")
            return try encoded(response: BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: nextSequence(), runtimeState: runtime(snapshot: restored),
                replacementReceipt: ReplacementReceipt(expected: restored, writtenText: restored.selectedText)))
        default:
            return try encoded(response: emptyResponse(for: request))
        }
    }

    func disconnect() {
        disconnectCount += 1
    }

    func emitLateRestoreEvent(revision: UInt64 = 2, captureToken: UUID? = nil,
                              restorationToken: UUID? = nil, canRestore: Bool = true) {
        guard let defaultCaptureToken = lastCaptureToken,
              let defaultRestorationToken = lastRestorationToken else { return }
        let emittedCaptureToken = captureToken ?? defaultCaptureToken
        let emittedRestorationToken = restorationToken ?? defaultRestorationToken
        let state = BrokerRuntimeState(snapshot: nil, captureToken: emittedCaptureToken, revision: revision,
            frame: nil, restorationToken: emittedRestorationToken, canRestore: canRestore,
            canReturnFocus: true, hasTarget: false, hostName: "Fixture", lastReadFailure: nil,
            writeAttempts: replaceCount, lastObservedChange: "fixture-write", replacementStage: .verifying)
        let event = BrokerEvent(epoch: epoch, stateSequence: nextSequence(), runtimeState: state)
        guard let data = try? BrokerCodec.encode(event) else { return }
        onEvent?(data)
    }

    func emitPendingCaptureInvalidation(captureToken: UUID? = nil) {
        let state = BrokerRuntimeState(snapshot: nil, captureToken: captureToken, revision: 0,
            frame: nil, restorationToken: nil, canRestore: false,
            canReturnFocus: false, hasTarget: false, hostName: "Fixture",
            lastReadFailure: "capturePending", writeAttempts: replaceCount,
            lastObservedChange: "AXSelectedTextChanged", replacementStage: nil)
        let event = BrokerEvent(epoch: epoch, stateSequence: nextSequence(),
            runtimeState: state, invalidated: true)
        guard let data = try? BrokerCodec.encode(event) else { return }
        onEvent?(data)
    }

    private func status() -> BrokerStatus {
        BrokerStatus(pid: 99, bundle: BrokerIdentity.bundle, path: fixtureHelperPath,
            version: "1", build: "1", certificateSHA1: String(repeating: "A", count: 40),
            permission: true, supportedOperations: supportedOperationsOverride)
    }

    private func runtime(snapshot: InputSnapshot) -> BrokerRuntimeState {
        BrokerRuntimeState(snapshot: snapshot, captureToken: snapshot.captureID, revision: snapshot.revision,
            frame: nil, restorationToken: lastRestorationToken, canRestore: lastRestorationToken != nil,
            canReturnFocus: true,
            hasTarget: true, hostName: "Fixture", lastReadFailure: nil, writeAttempts: replaceCount,
            lastObservedChange: nil, replacementStage: nil)
    }

    private func emptyResponse(for request: BrokerRequest) -> BrokerResponse {
        BrokerResponse(requestID: request.requestID, epoch: epoch, stateSequence: nextSequence())
    }

    private func nextSequence() -> UInt64 {
        sequence += 1
        return sequence
    }

    private func encoded(response: BrokerResponse) throws -> Data {
        try BrokerCodec.encode(response)
    }
}

private func fixtureSnapshot(captureID: UUID, revision: UInt64, scope: CaptureScope,
                            selectedText: String = "old", supportsDirectFill: Bool = false,
                            fullText: String? = nil) -> InputSnapshot {
    InputSnapshot(identity: InputIdentity(host: "fixture", window: "window", input: "input", session: "session"),
        revision: revision, selection: NSRange(location: 0, length: selectedText.utf16.count),
        selectedText: selectedText, supportsDirectFill: supportsDirectFill,
        captureScope: scope, fullText: fullText, captureID: captureID)
}

#endif
