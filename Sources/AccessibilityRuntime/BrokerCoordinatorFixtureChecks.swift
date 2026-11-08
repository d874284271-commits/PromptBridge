import Foundation
import AccessibilityContracts

/// Synthetic broker checks.  The fake host below contains no AX objects and
/// is used only to exercise the coordinator's protocol and lifecycle rules.
@MainActor public enum BrokerCoordinatorFixtureChecks {
    private static let identity = BrokerApplicationIdentity(pid: 7,
        bundle: "fixture.client", path: "/fixture/client", version: "1", build: "1")

    public static func run() async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func record(_ name: String, _ value: Bool) { results.append((name, value)) }

        let fake = FixtureHost()
        let clock = FixtureClock()
        let permissionState = FixturePermission()
        var events = 0
        var exits = 0
        let coordinator = BrokerCoordinator(certificate: String(repeating: "A", count: 40),
            resolveClient: { pid in pid == identity.pid ? identity : nil },
            makeHost: { _ in fake },
            status: {
                BrokerStatus(pid: 1, bundle: "fixture.broker", path: "/fixture/broker",
                    version: "1", build: "1", certificateSHA1: String(repeating: "A", count: 40),
                    permission: permissionState.value,
                    supportedOperations: BrokerOperation.requiredProductionOperations)
            },
            permissionHelp: {},
            claudeProbe: { _ in .failure(BrokerProbeFailure(code: .hostRejected)) },
            clock: clock,
            exit: { exits += 1 })

        let malformed = await coordinator.perform(Data([0x7B]), token: UUID(), peerPID: identity.pid) { _ in }
        record("invalid payload is rejected before host creation", decode(malformed)?.error == .invalidMessage && fake.captureCount == 0)

        let lease = BrokerAdmission()
        guard let initialToken = lease.acquire() else {
            record("single-client admission keeps one lease", false)
            return results
        }
        record("single-client admission rejects a second client", lease.acquire() == nil)
        lease.markDisconnected(initialToken)
        record("disconnected lease remains occupied until cleanup", lease.acquire() == nil)
        _ = lease.release(initialToken)
        guard let reacquired = lease.acquire() else {
            record("admission can be reacquired after cleanup", false)
            return results
        }
        record("admission can be reacquired after cleanup", true)
        _ = lease.release(reacquired)
        let preHandshakeToken = UUID()
        guard coordinator.admitConnection(preHandshakeToken) else {
            record("accepted connection gates idle before handshake", false)
            return results
        }
        _ = await waitUntil { clock.sleepCount > 0 }
        clock.release = true
        await Task.yield()
        record("accepted connection gates idle before handshake", exits == 0)
        clock.release = false
        await coordinator.disconnect(preHandshakeToken)
        _ = await waitUntil { clock.sleepCount > 1 }
        record("pre-handshake disconnect re-arms the idle lifetime", exits == 0 && clock.sleepCount > 1)
        guard let token = lease.acquire(), coordinator.admitConnection(token) else {
            record("admitted token is required for handshake", false)
            return results
        }

        let handshakeRequest = BrokerRequest(operation: .handshake)
        guard let handshakeData = try? BrokerCodec.encode(handshakeRequest) else {
            record("fixture handshake encodes", false)
            return results
        }
        let handshake = await coordinator.perform(handshakeData, token: token, peerPID: identity.pid) { _ in events += 1 }
        guard let handshakeResponse = decode(handshake), let epoch = handshakeResponse.epoch else {
            record("verified client handshake creates an epoch", false)
            return results
        }
        record("verified client handshake creates an epoch", handshakeResponse.verifiedClient == identity)

        let staleCapture = request(.capture, epoch: UUID(), payload: BrokerPayload(scope: .entireInput))
        let stale = await perform(staleCapture, coordinator: coordinator, token: token)
        record("stale epoch is rejected before AX", stale?.error == .staleEpoch && fake.captureCount == 0)

        let captureID = UUID()
        let captureRequest = request(.capture, epoch: epoch, id: captureID,
            payload: BrokerPayload(scope: .entireInput))
        let captured = await perform(captureRequest, coordinator: coordinator, token: token)
        guard let capturedState = captured?.runtimeState,
              let snapshot = capturedState.snapshot,
              capturedState.captureToken != nil else {
            record("capture returns a target token", false)
            return results
        }
        record("capture returns a target token", captured?.error == nil)

        let lateCancel = request(.cancel, epoch: epoch,
            payload: BrokerPayload(operationID: captureID))
        let cancelledCapture = await perform(lateCancel, coordinator: coordinator, token: token)
        record("late capture cancel clears its own token", cancelledCapture?.cancelDisposition == .cancelledBeforeSetter && fake.clearCount == 1)

        let secondCaptureID = UUID()
        let secondCapture = request(.capture, epoch: epoch, id: secondCaptureID,
            payload: BrokerPayload(scope: .entireInput))
        let secondCaptured = await perform(secondCapture, coordinator: coordinator, token: token)
        guard let secondState = secondCaptured?.runtimeState,
              let secondSnapshot = secondState.snapshot,
              let secondToken = secondState.captureToken else {
            record("second capture remains available", false)
            return results
        }
        let staleLateCancel = request(.cancel, epoch: epoch,
            payload: BrokerPayload(operationID: captureID))
        let staleCancelResponse = await perform(staleLateCancel, coordinator: coordinator, token: token)
        record("late cancel cannot clear a newer capture", staleCancelResponse?.cancelDisposition == .notActive
            && fake.cachedState().captureToken == secondToken)

        let subscribe = request(.subscribe, epoch: epoch,
            payload: BrokerPayload(launcherMode: .focusedInput))
        _ = await perform(subscribe, coordinator: coordinator, token: token)
        fake.emitStateChange()
        await Task.yield()
        record("state notification remains available after subscribe", events == 1)

        let beforeSetterID = UUID()
        fake.blockWrite = true
        let beforeSetterPayload = BrokerWritePayload(operationID: beforeSetterID,
            target: BrokerTargetReference(captureToken: secondToken, revision: secondState.revision),
            expected: secondSnapshot, text: "before-setter")
        let beforeSetterRequest = request(.replace, epoch: epoch, id: beforeSetterID,
            payload: BrokerPayload(write: beforeSetterPayload))
        let beforeSetterTask = Task { await perform(beforeSetterRequest, coordinator: coordinator, token: token) }
        _ = await waitUntil { fake.writeStarted && fake.writeWaiting }
        record("active write pauses polling", fake.pollingPaused)
        let activeSubscribe = await perform(subscribe, coordinator: coordinator, token: token)
        record("notification request remains serviceable during an active write", activeSubscribe?.error == nil)
        let cancelBeforeSetter = request(.cancel, epoch: epoch,
            payload: BrokerPayload(operationID: beforeSetterID))
        let beforeSetterCancel = await perform(cancelBeforeSetter, coordinator: coordinator, token: token)
        _ = await waitUntil { fake.cancellationObserved }
        fake.blockWrite = false
        let beforeSetterResult = await beforeSetterTask.value
        let beforeSetterPassed = beforeSetterCancel?.cancelDisposition == .cancelledBeforeSetter
            && beforeSetterResult?.error == .cancelled && fake.writeCount == 0
        record("cancel before setter is classified precisely", beforeSetterPassed)
        record("polling resumes after active operation", !fake.pollingPaused)

        let afterSetterID = UUID()
        fake.blockAfterSetter = true
        let afterSetterPayload = BrokerWritePayload(operationID: afterSetterID,
            target: BrokerTargetReference(captureToken: secondToken, revision: secondState.revision),
            expected: secondSnapshot, text: "after-setter-cancel")
        let afterSetterRequest = request(.replace, epoch: epoch, id: afterSetterID,
            payload: BrokerPayload(write: afterSetterPayload))
        let afterSetterTask = Task { await perform(afterSetterRequest, coordinator: coordinator, token: token) }
        _ = await waitUntil { fake.writeStarted && fake.writeWaiting && fake.setterIssuedForOperation }
        let cancelAfterSetter = request(.cancel, epoch: epoch,
            payload: BrokerPayload(operationID: afterSetterID))
        let afterSetterCancel = await perform(cancelAfterSetter, coordinator: coordinator, token: token)
        _ = await waitUntil { fake.cancellationObserved }
        fake.blockAfterSetter = false
        let afterSetterResult = await afterSetterTask.value
        record("cancel after setter is classified as outcome-unknown", afterSetterCancel?.cancelDisposition == .outcomeUnknown
            && afterSetterResult?.error == .outcomeUnknown && fake.writeCount == 1)

        let failedID = UUID()
        fake.failAfterSetter = true
        let failedPayload = BrokerWritePayload(operationID: failedID,
            target: BrokerTargetReference(captureToken: secondToken, revision: secondState.revision),
            expected: secondSnapshot, text: "after-setter")
        let failedRequest = request(.replace, epoch: epoch, id: failedID,
            payload: BrokerPayload(write: failedPayload))
        let failed = await perform(failedRequest, coordinator: coordinator, token: token)
        let writesAfterFailure = fake.writeCount
        let duplicate = await perform(failedRequest, coordinator: coordinator, token: token)
        record("setter failure is outcome-unknown", failed?.error == .outcomeUnknown && fake.setterIssuedForOperation)
        record("failed operation ID is deduplicated without another setter", duplicate?.error == .duplicateOperation
            && fake.writeCount == writesAfterFailure)
        fake.failAfterSetter = false

        let disconnectID = UUID()
        fake.blockWrite = true
        let disconnectPayload = BrokerWritePayload(operationID: disconnectID,
            target: BrokerTargetReference(captureToken: secondToken, revision: secondState.revision),
            expected: secondSnapshot, text: "disconnect")
        let disconnectRequest = request(.replace, epoch: epoch, id: disconnectID,
            payload: BrokerPayload(write: disconnectPayload))
        let disconnectTask = Task { await perform(disconnectRequest, coordinator: coordinator, token: token) }
        _ = await waitUntil { fake.writeStarted && fake.writeWaiting }
        await coordinator.disconnect(token)
        fake.blockWrite = false
        let disconnectResult = await disconnectTask.value
        let disconnectPassed = disconnectResult?.error == .outcomeUnknown
            && fake.clearCount >= 2 && fake.writeCount == writesAfterFailure
        record("disconnect clears a pending write as unknown without retry", disconnectPassed)

        clock.release = false
        record("old write cleanup keeps the admission lease occupied", lease.acquire() == nil)
        _ = lease.release(token)
        guard let newToken = lease.acquire(), coordinator.admitConnection(newToken) else {
            record("new admitted connection can handshake after old cleanup", false)
            return results
        }
        let newHandshake = await coordinator.perform(handshakeData, token: newToken, peerPID: identity.pid) { _ in }
        permissionState.value = false
        guard let newEpoch = decode(newHandshake)?.epoch else {
            record("permission revocation can be observed by the next client", false)
            return results
        }
        let revokedCapture = request(.capture, epoch: newEpoch,
            payload: BrokerPayload(scope: .entireInput))
        let revoked = await perform(revokedCapture, coordinator: coordinator, token: newToken)
        record("revoked permission invalidates runtime work", revoked?.error == .permissionRequired && fake.clearCount >= 3)

        clock.release = true
        await coordinator.disconnect(newToken)
        _ = lease.release(newToken)
        _ = await waitUntil { exits == 1 }
        record("idle exit is injected and fires after disconnect", exits == 1)

        _ = snapshot // keep the target evidence explicit in this check.
        results.append(await facadeRestorationEventCheck())
        results.append(await queuedInvalidateRecoveryCheck())
        results.append(await afterSetterDisconnectCheck())
        return results
    }

    private static func afterSetterDisconnectCheck() async -> (String, Bool) {
        let name = "disconnect after setter is outcome-unknown without retry"
        let fake = FixtureHost()
        let clock = FixtureClock()
        let coordinator = BrokerCoordinator(certificate: String(repeating: "A", count: 40),
            resolveClient: { pid in pid == identity.pid ? identity : nil },
            makeHost: { _ in fake },
            status: {
                BrokerStatus(pid: 1, bundle: "fixture.broker", path: "/fixture/broker",
                    version: "1", build: "1", certificateSHA1: String(repeating: "A", count: 40),
                    permission: true, supportedOperations: BrokerOperation.requiredProductionOperations)
            },
            permissionHelp: {},
            claudeProbe: { _ in .failure(BrokerProbeFailure(code: .hostRejected)) },
            clock: clock,
            exit: {})
        let lease = UUID()
        guard coordinator.admitConnection(lease),
              let epoch = decode(await coordinator.perform(
                try! BrokerCodec.encode(BrokerRequest(operation: .handshake)),
                token: lease, peerPID: identity.pid) { _ in })?.epoch,
              let state = await perform(request(.capture, epoch: epoch,
                payload: BrokerPayload(scope: .entireInput)),
                coordinator: coordinator, token: lease)?.runtimeState,
              let snapshot = state.snapshot, let captureToken = state.captureToken else {
            await coordinator.disconnect(lease)
            clock.release = true
            return (name, false)
        }

        fake.blockAfterSetter = true
        let operationID = UUID()
        let write = request(.replace, epoch: epoch, id: operationID,
            payload: BrokerPayload(write: BrokerWritePayload(operationID: operationID,
                target: BrokerTargetReference(captureToken: captureToken,
                    revision: snapshot.revision), expected: snapshot, text: "after-setter-disconnect")))
        let pending = Task { await perform(write, coordinator: coordinator, token: lease) }
        guard await waitUntil({ fake.writeStarted && fake.writeWaiting && fake.setterIssuedForOperation }) else {
            fake.blockAfterSetter = false
            await coordinator.disconnect(lease)
            _ = await pending.value
            clock.release = true
            return (name, false)
        }
        let disconnecting = Task { await coordinator.disconnect(lease) }
        let cancellationObserved = await waitUntil { fake.cancellationObserved }
        fake.blockAfterSetter = false
        await disconnecting.value
        let receipt = await pending.value
        clock.release = true
        return (name, cancellationObserved && receipt?.error == .outcomeUnknown
            && fake.writeCount == 1 && fake.cachedState().captureToken == nil
            && fake.clearCount == 1)
    }

    private static func facadeRestorationEventCheck() async -> (String, Bool) {
        let access = ExternalInputFixture()
        access.fullDraft = "facade recovery fixture"
        access.range = CFRange(location: 0, length: 0)
        access.replacementApproved = true
        let clock = FixtureClock()
        var events: [Data] = []
        var exits = 0
        let coordinator = BrokerCoordinator(certificate: String(repeating: "A", count: 40),
            resolveClient: { pid in pid == identity.pid ? identity : nil },
            makeHost: { _ in AccessibilityRuntimeHost(syntheticAccess: access) },
            status: {
                BrokerStatus(pid: 1, bundle: "fixture.broker", path: "/fixture/broker",
                    version: "1", build: "1", certificateSHA1: String(repeating: "A", count: 40),
                    permission: true, supportedOperations: BrokerOperation.requiredProductionOperations)
            },
            permissionHelp: {},
            claudeProbe: { _ in .failure(BrokerProbeFailure(code: .hostRejected)) },
            clock: clock,
            exit: { exits += 1 })
        let lease = UUID()
        guard coordinator.admitConnection(lease) else {
            return ("facade late notification preserves recovery through broker event", false)
        }
        let handshake = await coordinator.perform(
            try! BrokerCodec.encode(BrokerRequest(operation: .handshake)),
            token: lease, peerPID: identity.pid) { data in events.append(data) }
        guard let epoch = decode(handshake)?.epoch else {
            return ("facade late notification preserves recovery through broker event", false)
        }
        let capture = await perform(request(.capture, epoch: epoch,
            payload: BrokerPayload(scope: .entireInput)), coordinator: coordinator, token: lease)
        guard let state = capture?.runtimeState, let snapshot = state.snapshot,
              let captureToken = state.captureToken else {
            return ("facade late notification preserves recovery through broker event", false)
        }
        _ = await perform(request(.subscribe, epoch: epoch,
            payload: BrokerPayload(launcherMode: .focusedInput)), coordinator: coordinator, token: lease)
        let operationID = UUID()
        let write = BrokerWritePayload(operationID: operationID,
            target: BrokerTargetReference(captureToken: captureToken, revision: state.revision),
            expected: snapshot, text: "facade recovery output")
        let written = await perform(request(.replace, epoch: epoch, id: operationID,
            payload: BrokerPayload(write: write)), coordinator: coordinator, token: lease)
        guard written?.error == nil, let receipt = written?.replacementReceipt else {
            return ("facade late notification preserves recovery through broker event", false)
        }
        // This is the delayed value notification emitted after a verified write.
        // The facade must retain its opaque restoration record while dropping the
        // captured generation from the externally usable snapshot.
        access.emit("AXValueChanged")
        await Task.yield()
        guard let event = events.last.flatMap({ try? JSONDecoder().decode(BrokerEvent.self, from: $0) }) else {
            clock.release = true
            await coordinator.disconnect(lease)
            return ("facade late notification preserves recovery through broker event", false)
        }
        let eventState = event.runtimeState
        let eventPreservesRecovery = !event.invalidated && eventState?.snapshot == nil
            && eventState?.hasTarget == false && eventState?.canRestore == true
            && eventState?.restorationToken != nil
            && eventState?.captureToken == receipt.expected.captureID
            && (eventState?.revision ?? 0) > receipt.expected.revision
        guard let restorationToken = eventState?.restorationToken else {
            clock.release = true
            await coordinator.disconnect(lease)
            _ = exits
            return ("facade late notification preserves recovery through broker event", false)
        }
        let wrongValidation = await perform(request(.validate, epoch: epoch,
            payload: BrokerPayload(restorationToken: UUID())), coordinator: coordinator, token: lease)
        let liveValidationRequest = request(.validate, epoch: epoch,
            payload: BrokerPayload(restorationToken: restorationToken))
        let liveValidationData = await coordinator.perform(liveValidationRequest,
            token: lease, peerPID: identity.pid) { _ in }
        let liveValidation = decode(liveValidationData)
        let responseContractPassed: Bool
        if let decodedRequest = try? BrokerCodec.request(liveValidationRequest) {
            responseContractPassed = (try? BrokerCodec.response(liveValidationData,
                for: decodedRequest, after: 0)) != nil
        } else {
            responseContractPassed = false
        }
        let validationPassed = wrongValidation?.error == .targetChanged
            && liveValidation?.error == nil && liveValidation?.runtimeState?.snapshot == nil
            && liveValidation?.runtimeState?.canRestore == true && access.writeCount == 1
            && responseContractPassed
        let restorationReference = BrokerTargetReference(captureToken: receipt.expected.captureID!,
            revision: eventState?.revision ?? receipt.expected.revision)
        let nilPanel = await perform(request(.acquireScope, epoch: epoch,
            payload: BrokerPayload(scopeRequest: BrokerScopePayload(kind: .panel))),
            coordinator: coordinator, token: lease)
        let wrongPanel = await perform(request(.acquireScope, epoch: epoch,
            payload: BrokerPayload(scopeRequest: BrokerScopePayload(kind: .panel,
                target: BrokerTargetReference(captureToken: UUID(), revision: restorationReference.revision)))),
            coordinator: coordinator, token: lease)
        let oldPanel = await perform(request(.acquireScope, epoch: epoch,
            payload: BrokerPayload(scopeRequest: BrokerScopePayload(kind: .panel,
                target: BrokerTargetReference(captureToken: restorationReference.captureToken,
                    revision: receipt.expected.revision)))), coordinator: coordinator, token: lease)
        let panel = await perform(request(.acquireScope, epoch: epoch,
            payload: BrokerPayload(scopeRequest: BrokerScopePayload(kind: .panel,
                target: restorationReference))), coordinator: coordinator, token: lease)
        let panelReceipt = panel?.scopeReceipt
        let panelReleased: Bool
        if let scopeID = panelReceipt?.scopeID {
            let release = await perform(request(.releaseScope, epoch: epoch,
                payload: BrokerPayload(scopeID: scopeID)), coordinator: coordinator, token: lease)
            panelReleased = release?.error == nil
        } else {
            panelReleased = false
        }
        let panelPassed = panel?.error == nil
            && panelReceipt?.captureToken == restorationReference.captureToken
            && panelReceipt?.kind == .panel && panelReleased
        let returnedFocus = await perform(request(.returnFocus, epoch: epoch,
            payload: BrokerPayload(target: restorationReference, allowInvalidTarget: true)),
            coordinator: coordinator, token: lease)
        let returnFocusPassed = returnedFocus?.error == nil && returnedFocus?.focusReturned == true
        let restored = await perform(request(.restore, epoch: epoch,
            payload: BrokerPayload(restore: BrokerRestorePayload(operationID: UUID(),
                restorationToken: restorationToken))), coordinator: coordinator, token: lease)
        let repeatedRestore = await perform(request(.restore, epoch: epoch,
            payload: BrokerPayload(restore: BrokerRestorePayload(operationID: UUID(),
                restorationToken: restorationToken))), coordinator: coordinator, token: lease)
        let noRestorePanel = await perform(request(.acquireScope, epoch: epoch,
            payload: BrokerPayload(scopeRequest: BrokerScopePayload(kind: .panel,
                target: restorationReference))), coordinator: coordinator, token: lease)
        let restoredState = restored?.runtimeState
        clock.release = true
        await coordinator.disconnect(lease)
        let changedAccess = ExternalInputFixture()
        changedAccess.fullDraft = "changed-text fixture"
        changedAccess.range = CFRange(location: 0, length: 0)
        changedAccess.replacementApproved = true
        let changedHost = AccessibilityRuntimeHost(syntheticAccess: changedAccess)
        let changedState = try? await changedHost.capture(.entireInput)
        var changedValidationRejected = false
        if let changedSnapshot = changedState?.snapshot, let changedToken = changedState?.captureToken,
           let changedReceipt = try? await changedHost.replace(BrokerWritePayload(operationID: UUID(),
               target: BrokerTargetReference(captureToken: changedToken,
                   revision: changedState?.revision ?? 0),
               expected: changedSnapshot, text: "changed-text output")) {
            _ = changedReceipt
            changedAccess.emit("AXValueChanged")
            await Task.yield()
            if let liveToken = changedHost.cachedState().restorationToken {
                changedAccess.fullDraft = "user changed before validation"
                do { _ = try await changedHost.validateRestoration(liveToken) }
                catch { changedValidationRejected = true }
            }
        }
        let changedReadOnly = changedValidationRejected && changedAccess.writeCount == 1
            && changedHost.cachedState().canRestore == false
        return ("facade live restoration validation is token-bound, read-only, and one-shot",
                eventPreservesRecovery && validationPassed
                && nilPanel?.error == .scopeRejected
                && wrongPanel?.error == .scopeRejected
                && oldPanel?.error == .scopeRejected
                && panelPassed && returnFocusPassed
                && restored?.error == nil
                && repeatedRestore?.error == .targetChanged
                && noRestorePanel?.error == .scopeRejected
                && restoredState?.canRestore == false && access.writeCount == 2 && changedReadOnly)
    }

    private static func queuedInvalidateRecoveryCheck() async -> (String, Bool) {
        let access = ExternalInputFixture()
        access.fullDraft = "queued invalidate fixture"
        access.range = CFRange(location: 0, length: 0)
        access.replacementApproved = true
        let clock = FixtureClock()
        var runtimeHost: AccessibilityRuntimeHost?
        let coordinator = BrokerCoordinator(certificate: String(repeating: "A", count: 40),
            resolveClient: { pid in pid == identity.pid ? identity : nil },
            makeHost: { _ in
                let host = AccessibilityRuntimeHost(syntheticAccess: access)
                runtimeHost = host
                return host
            },
            status: {
                BrokerStatus(pid: 1, bundle: "fixture.broker", path: "/fixture/broker",
                    version: "1", build: "1", certificateSHA1: String(repeating: "A", count: 40),
                    permission: true, supportedOperations: BrokerOperation.requiredProductionOperations)
            },
            permissionHelp: {},
            claudeProbe: { _ in .failure(BrokerProbeFailure(code: .hostRejected)) },
            clock: clock,
            exit: {})
        let lease = UUID()
        guard coordinator.admitConnection(lease) else {
            return ("queued post-write invalidate clears restoration before late event", false)
        }
        let handshake = await coordinator.perform(
            try! BrokerCodec.encode(BrokerRequest(operation: .handshake)),
            token: lease, peerPID: identity.pid) { _ in }
        guard let epoch = decode(handshake)?.epoch,
              let captured = await perform(request(.capture, epoch: epoch,
                  payload: BrokerPayload(scope: .entireInput)), coordinator: coordinator, token: lease),
              let state = captured.runtimeState, let snapshot = state.snapshot,
              let captureToken = state.captureToken else {
            clock.release = true
            await coordinator.disconnect(lease)
            return ("queued post-write invalidate clears restoration before late event", false)
        }
        let writeID = UUID()
        let write = BrokerWritePayload(operationID: writeID,
            target: BrokerTargetReference(captureToken: captureToken, revision: state.revision),
            expected: snapshot, text: "queued invalidate output")
        let written = await perform(request(.replace, epoch: epoch, id: writeID,
            payload: BrokerPayload(write: write)), coordinator: coordinator, token: lease)
        guard written?.error == nil, let receipt = written?.replacementReceipt,
              let writtenState = written?.runtimeState,
              let oldCaptureToken = receipt.expected.captureID,
              writtenState.captureToken == oldCaptureToken,
              let restorationToken = writtenState.restorationToken else {
            clock.release = true
            await coordinator.disconnect(lease)
            return ("queued post-write invalidate clears restoration before late event", false)
        }
        access.emit("AXValueChanged")
        await Task.yield()
        let lateState = runtimeHost?.cachedState()
        let lateEventPreserved = lateState?.snapshot == nil && lateState?.canRestore == true
            && lateState?.captureToken == oldCaptureToken
            && (lateState?.revision ?? 0) > writtenState.revision
        let invalidate = await perform(request(.invalidate, epoch: epoch,
            payload: BrokerPayload(target: BrokerTargetReference(
                captureToken: oldCaptureToken,
                revision: writtenState.revision))),
            coordinator: coordinator, token: lease)
        let repeated = await perform(request(.restore, epoch: epoch,
            payload: BrokerPayload(restore: BrokerRestorePayload(operationID: UUID(),
                restorationToken: restorationToken))), coordinator: coordinator, token: lease)
        clock.release = true
        await coordinator.disconnect(lease)
        return ("queued post-write invalidate clears restoration before late event",
                lateEventPreserved && invalidate?.error == nil && invalidate?.runtimeState?.canRestore == false
                && repeated?.error == .targetChanged && access.writeCount == 1)
    }

    private static func request(_ operation: BrokerOperation, epoch: UUID, id: UUID = UUID(),
                                payload: BrokerPayload? = nil) -> Data {
        try! BrokerCodec.encode(BrokerRequest(operation: operation, epoch: epoch,
            requestID: id, payload: payload))
    }

    private static func perform(_ data: Data, coordinator: BrokerCoordinator,
                                token: UUID) async -> BrokerResponse? {
        let result = await coordinator.perform(data, token: token, peerPID: identity.pid) { _ in }
        return decode(result)
    }

    private static func decode(_ data: Data) -> BrokerResponse? {
        try? JSONDecoder().decode(BrokerResponse.self, from: data)
    }

    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    @MainActor private final class FixtureClock: BrokerCoordinatorClock {
        var release = false
        private(set) var sleepCount = 0
        func sleep(for _: Duration) async throws {
            sleepCount += 1
            while !release {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
    }

    @MainActor private final class FixturePermission {
        var value = true
    }

    @MainActor private final class FixtureHost: BrokerRuntimeHost {
        var onStateChange: (() -> Void)?
        var onFocusChange: ((BrokerFocusState) -> Void)?
        var onObservedChange: ((String) -> Void)?
        var onReplacementStage: ((ReplacementStage) -> Void)?
        private(set) var setterIssuedForOperation = false
        private(set) var captureCount = 0
        private(set) var clearCount = 0
        private(set) var writeCount = 0
        private(set) var writeStarted = false
        private(set) var writeWaiting = false
        private(set) var cancellationObserved = false
        var blockWrite = false
        var blockAfterSetter = false
        var failAfterSetter = false
        private(set) var pollingPaused = false
        private var state: BrokerRuntimeState

        init() {
            state = BrokerRuntimeState(snapshot: nil, captureToken: nil, revision: 0,
                frame: nil, restorationToken: nil, canRestore: false,
                canReturnFocus: false, hasTarget: false, hostName: "fixture",
                lastReadFailure: nil, writeAttempts: 0, lastObservedChange: nil,
                replacementStage: nil)
        }

        func cachedState() -> BrokerRuntimeState { state }

        func capture(_ scope: CaptureScope) async throws -> BrokerRuntimeState {
            captureCount += 1
            while blockWrite {
                try Task.checkCancellation()
                await Task.yield()
            }
            let token = UUID()
            let snapshot = InputSnapshot(identity: InputIdentity(host: "fixture.host",
                    window: "window", input: "input", session: "session"), revision: 1,
                selection: NSRange(location: 0, length: 1), selectedText: "x",
                captureScope: scope, fullText: "x", captureID: token)
            state = BrokerRuntimeState(snapshot: snapshot, captureToken: token, revision: 1,
                frame: nil, restorationToken: nil, canRestore: false,
                canReturnFocus: true, hasTarget: true, hostName: "fixture",
                lastReadFailure: nil, writeAttempts: 0, lastObservedChange: nil,
                replacementStage: nil)
            return state
        }

        func validate(_ target: BrokerTargetReference) async throws -> BrokerRuntimeState {
            guard state.captureToken == target.captureToken, state.revision == target.revision else {
                throw BrokerContractError.staleResponse
            }
            return state
        }

        func validateRestoration(_ token: UUID) async throws -> BrokerRuntimeState {
            guard state.restorationToken == token, state.canRestore else {
                throw FillError.targetChanged
            }
            return state
        }

        func replace(_ payload: BrokerWritePayload) async throws -> ReplacementReceipt {
            writeStarted = true
            do {
                writeWaiting = blockWrite
                while blockWrite {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            } catch {
                cancellationObserved = true
                throw error
            }
            setterIssuedForOperation = true
            writeCount += 1
            do {
                writeWaiting = blockAfterSetter
                while blockAfterSetter {
                    try Task.checkCancellation()
                    await Task.yield()
                }
            } catch {
                cancellationObserved = true
                throw error
            }
            if failAfterSetter { throw FillError.outcomeUnknown }
            return ReplacementReceipt(expected: payload.expected, writtenText: payload.text)
        }

        func restore(_ payload: BrokerRestorePayload) async throws -> ReplacementReceipt {
            throw FillError.targetChanged
        }

        func returnFocus(_ target: BrokerTargetReference?, allowInvalidTarget: Bool) async throws -> Bool { true }
        func acquireScope(_ payload: BrokerScopePayload) throws -> BrokerScopeReceipt {
            BrokerScopeReceipt(scopeID: UUID(), kind: payload.kind, captureToken: payload.target?.captureToken)
        }
        func releaseScope(_ id: UUID) throws {}
        func setLauncherMode(_ mode: LauncherMode) {}
        func setPollingPaused(_ paused: Bool) { pollingPaused = paused }
        func resetOperationWriteState() {
            setterIssuedForOperation = false
            writeStarted = false
            writeWaiting = false
            cancellationObserved = false
        }
        func clear() { clearCount += 1; state = BrokerRuntimeState(snapshot: nil, captureToken: nil,
            revision: state.revision + 1, frame: nil, restorationToken: nil, canRestore: false,
            canReturnFocus: false, hasTarget: false, hostName: "fixture", lastReadFailure: nil,
            writeAttempts: state.writeAttempts, lastObservedChange: nil, replacementStage: nil) }
        func probeCodex() throws -> Data { Data("{}".utf8) }
        func probeInputSupport() throws -> Data { Data("{}".utf8) }
        func emitStateChange() { onStateChange?() }
    }
}
