import AccessibilityContracts
import Foundation

/// Stable, Foundation-only checks for the production wire contract.
/// The executable test runner may call this without starting AX, XPC, or a host.
func runProductionContractChecks() -> [(String, Bool)] {
    var checks: [(String, Bool)] = []
    func check(_ name: String, _ body: () throws -> Bool) {
        do { checks.append((name, try body())) } catch { checks.append((name, false)) }
    }
    func rejects(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return true }
    }

    let epoch = UUID()
    let capture = UUID()
    let operationID = UUID()
    let identity = InputIdentity(host: "Codex", window: "window", input: "input", session: "session")
    let snapshot = InputSnapshot(identity: identity, revision: 7,
        selection: NSRange(location: 0, length: 3), selectedText: "old",
        supportsDirectFill: true, captureScope: .entireInput, fullText: "old",
        contextID: nil, captureID: capture)
    let selectionSnapshot = InputSnapshot(identity: identity, revision: 7,
        selection: NSRange(location: 0, length: 3), selectedText: "old",
        supportsDirectFill: false, captureScope: .selection, fullText: nil,
        contextID: nil, captureID: capture)
    let target = BrokerTargetReference(captureToken: capture, revision: snapshot.revision)
    let write = BrokerWritePayload(operationID: operationID, target: target,
        expected: snapshot, text: String(repeating: "x", count: 6000))
    let state = BrokerRuntimeState(snapshot: snapshot, captureToken: capture,
        revision: snapshot.revision, frame: BrokerRect(x: 1, y: 2, width: 30, height: 20),
        restorationToken: nil, canRestore: false, canReturnFocus: true, hasTarget: true,
        hostName: "Codex", lastReadFailure: nil, writeAttempts: 0,
        lastObservedChange: nil, replacementStage: nil)
    let client = BrokerApplicationIdentity(pid: 42, bundle: "local.client",
        path: "/Applications/Client.app", version: "1", build: "1")

    let captureRequest = BrokerRequest(operation: .capture, epoch: epoch,
        payload: BrokerPayload(scope: .selection))
    check("production request round trip permits text payload") {
        let decoded = try BrokerCodec.request(BrokerCodec.encode(BrokerRequest(
            operation: .replace, epoch: epoch, payload: BrokerPayload(write: write))))
        return decoded == BrokerRequest(operation: .replace, epoch: epoch,
            requestID: decoded.requestID, payload: BrokerPayload(write: write))
    }
    check("capture requires scope") {
        rejects { try BrokerRequest(operation: .capture, epoch: epoch,
            payload: BrokerPayload(launcherMode: .focusedInput)).validate() }
    }
    check("capture rejects unrelated launcher mode") {
        rejects { try BrokerRequest(operation: .capture, epoch: epoch,
            payload: BrokerPayload(scope: .selection, launcherMode: .focusedInput)).validate() }
    }
    check("return focus may bind an explicit current target") {
        let request = BrokerRequest(operation: .returnFocus, epoch: epoch,
            payload: BrokerPayload(target: target, allowInvalidTarget: true))
        try request.validate(); return true
    }
    check("subscribe requires launcher mode") {
        let valid = BrokerRequest(operation: .subscribe, epoch: epoch,
            payload: BrokerPayload(launcherMode: .focusedInput))
        try valid.validate()
        return rejects { try BrokerRequest(operation: .subscribe, epoch: epoch,
            payload: BrokerPayload()).validate() }
    }
    check("write target must match captured snapshot") {
        let wrong = BrokerWritePayload(operationID: operationID,
            target: BrokerTargetReference(captureToken: UUID(), revision: snapshot.revision),
            expected: snapshot, text: "x")
        return rejects { try BrokerRequest(operation: .replace, epoch: epoch,
            payload: BrokerPayload(write: wrong)).validate() }
    }
    check("selection capture cannot be used for a write") {
        let selectionWrite = BrokerWritePayload(operationID: operationID,
            target: BrokerTargetReference(captureToken: capture, revision: selectionSnapshot.revision),
            expected: selectionSnapshot, text: "x")
        return rejects { try BrokerRequest(operation: .replace, epoch: epoch,
            payload: BrokerPayload(write: selectionWrite)).validate() }
    }
    check("unknown nested request key is rejected before decode") {
        var object = try JSONSerialization.jsonObject(
            with: BrokerCodec.encode(captureRequest)) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        payload["unexpected"] = true
        object["payload"] = payload
        return rejects { _ = try BrokerCodec.request(JSONSerialization.data(withJSONObject: object)) }
    }
    check("invalid nested field type is rejected") {
        var object = try JSONSerialization.jsonObject(
            with: BrokerCodec.encode(captureRequest)) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        payload["scope"] = 1
        object["payload"] = payload
        return rejects { _ = try BrokerCodec.request(JSONSerialization.data(withJSONObject: object)) }
    }
    check("production request has no legacy envelope cap") {
        let data = try BrokerCodec.encode(BrokerRequest(operation: .replace, epoch: epoch,
            payload: BrokerPayload(write: write)))
        let decoded = try BrokerCodec.request(data)
        return data.count > 4096 && decoded.payload?.write?.text.count == 6000
    }
    check("legacy envelope remains bounded") {
        let request = BrokerRequest(operation: .status, epoch: epoch)
        let decoded = try BrokerCodec.request(BrokerCodec.encode(request))
        return rejects { _ = try BrokerCodec.request(Data(repeating: 32, count: 4097)) } && decoded == request
    }
    check("capture response requires correlated runtime snapshot") {
        let response = BrokerResponse(requestID: captureRequest.requestID, epoch: epoch,
            stateSequence: 1, runtimeState: BrokerRuntimeState(snapshot: selectionSnapshot,
                captureToken: capture, revision: selectionSnapshot.revision, frame: state.frame,
                restorationToken: nil, canRestore: false, canReturnFocus: true, hasTarget: true,
                hostName: "Codex", lastReadFailure: nil, writeAttempts: 0,
                lastObservedChange: nil, replacementStage: nil))
        try response.validate(for: captureRequest, after: 0)
        return true
    }
    check("selection capture rejects a full input response") {
        let response = BrokerResponse(requestID: captureRequest.requestID, epoch: epoch,
            stateSequence: 1, runtimeState: state)
        return rejects { try response.validate(for: captureRequest, after: 0) }
    }
    check("replace response requires receipt and state") {
        let receipt = ReplacementReceipt(expected: snapshot, writtenText: write.text)
        let request = BrokerRequest(operation: .replace, epoch: epoch,
            payload: BrokerPayload(write: write))
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 2, runtimeState: state, replacementReceipt: receipt)
        try response.validate(for: request, after: 1)
        return true
    }
    check("replace accepts post-write revision advance") {
        let receipt = ReplacementReceipt(expected: snapshot, writtenText: write.text)
        let advancedSnapshot = InputSnapshot(identity: snapshot.identity, revision: snapshot.revision + 1,
            selection: snapshot.selection, selectedText: write.text, supportsDirectFill: true,
            captureScope: snapshot.captureScope, fullText: write.text, captureID: capture)
        let advancedState = BrokerRuntimeState(snapshot: advancedSnapshot, captureToken: capture,
            revision: advancedSnapshot.revision, frame: state.frame, restorationToken: nil,
            canRestore: false, canReturnFocus: true, hasTarget: true, hostName: "Codex",
            lastReadFailure: nil, writeAttempts: 1, lastObservedChange: nil, replacementStage: .verifying)
        let request = BrokerRequest(operation: .replace, epoch: epoch,
            payload: BrokerPayload(write: BrokerWritePayload(operationID: operationID, target: target,
                expected: snapshot, text: write.text)))
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 2, runtimeState: advancedState, replacementReceipt: receipt)
        try response.validate(for: request, after: 1)
        return true
    }
    check("production error may carry helper status metadata") {
        let request = BrokerRequest(operation: .capture, epoch: epoch,
            payload: BrokerPayload(scope: .selection))
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 2, error: .permissionRequired, status: BrokerStatus(
                pid: 42, bundle: BrokerIdentity.bundle, path: "/helper", version: "1", build: "1",
                certificateSHA1: String(repeating: "A", count: 40), permission: false))
        try response.validate(for: request, after: 1)
        return true
    }
    check("return focus response requires boolean") {
        let request = BrokerRequest(operation: .returnFocus, epoch: epoch,
            payload: BrokerPayload(allowInvalidTarget: true))
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 3, focusReturned: true)
        try response.validate(for: request, after: 2)
        return true
    }
    check("restoration validate uses a token instead of creating a capture target") {
        let restorationToken = UUID()
        let request = BrokerRequest(operation: .validate, epoch: epoch,
            payload: BrokerPayload(restorationToken: restorationToken))
        try request.validate()
        let restorationState = BrokerRuntimeState(snapshot: nil, captureToken: capture,
            revision: snapshot.revision + 1, frame: state.frame, restorationToken: restorationToken,
            canRestore: true, canReturnFocus: true, hasTarget: false, hostName: "Codex",
            lastReadFailure: nil, writeAttempts: 1, lastObservedChange: nil,
            replacementStage: .verifying)
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 6, runtimeState: restorationState)
        try response.validate(for: request, after: 5)
        let ordinaryState = BrokerRuntimeState(snapshot: snapshot, captureToken: capture,
            revision: snapshot.revision, frame: state.frame, restorationToken: restorationToken,
            canRestore: true, canReturnFocus: true, hasTarget: true, hostName: "Codex",
            lastReadFailure: nil, writeAttempts: 1, lastObservedChange: nil,
            replacementStage: .verifying)
        let ordinaryResponse = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 7, runtimeState: ordinaryState)
        try ordinaryResponse.validate(for: request, after: 6)
        let wrong = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 7, runtimeState: BrokerRuntimeState(snapshot: nil, captureToken: capture,
                revision: snapshot.revision + 1, frame: state.frame, restorationToken: UUID(),
                canRestore: true, canReturnFocus: true, hasTarget: false, hostName: "Codex",
                lastReadFailure: nil, writeAttempts: 1, lastObservedChange: nil,
                replacementStage: .verifying))
        let wrongShape = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 8, runtimeState: BrokerRuntimeState(snapshot: nil, captureToken: capture,
                revision: snapshot.revision + 1, frame: state.frame, restorationToken: restorationToken,
                canRestore: true, canReturnFocus: true, hasTarget: true, hostName: "Codex",
                lastReadFailure: nil, writeAttempts: 1, lastObservedChange: nil,
                replacementStage: .verifying))
        return rejects { try wrong.validate(for: request, after: 6) }
            && rejects { try wrongShape.validate(for: request, after: 7) }
    }
    check("validate rejects target and restoration token together") {
        return rejects { try BrokerRequest(operation: .validate, epoch: epoch,
            payload: BrokerPayload(target: target, restorationToken: UUID())).validate() }
    }
    check("cancel response requires disposition") {
        let request = BrokerRequest(operation: .cancel, epoch: epoch,
            payload: BrokerPayload(operationID: operationID))
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 4, cancelDisposition: .cancelledBeforeSetter)
        try response.validate(for: request, after: 3)
        return true
    }
    check("event validates epoch, sequence, and runtime token") {
        let event = BrokerEvent(epoch: epoch, stateSequence: 5, runtimeState: state,
            focus: .ownApplication)
        try event.validate(for: epoch, after: 4)
        return true
    }
    check("event rejects stale epoch") {
        let event = BrokerEvent(epoch: epoch, stateSequence: 5)
        return rejects { try event.validate(for: UUID(), after: 4) }
    }
    check("focus state has fixed kind wire shape") {
        let data = try BrokerCodec.encode(BrokerFocusState.unavailable)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return object.keys.count == 1 && object["kind"] as? String == "unavailable"
    }
    check("client callback interface is Data-only") {
        _ = BrokerXPCClientInterface.make()
        return true
    }
    check("non-success response cannot carry pseudo-success metadata") {
        let request = BrokerRequest(operation: .capture, epoch: epoch,
            payload: BrokerPayload(scope: .selection))
        return rejects {
            try BrokerResponse(requestID: request.requestID, epoch: epoch, stateSequence: 1,
                error: .targetChanged, replacementReceipt: ReplacementReceipt(expected: snapshot,
                    writtenText: "x")).validate(for: request, after: 0)
        }
    }
    check("application identity validates") {
        try client.validate(); return true
    }
    check("rectangle rejects negative size or non-finite values") {
        try BrokerRect(x: -20, y: 4, width: 1, height: 2).validate()
        return rejects { try BrokerRect(x: 0, y: 4, width: -1, height: 2).validate() }
            && rejects { try BrokerRect(x: .infinity, y: 0, width: 1, height: 1).validate() }
    }
    check("ad-hoc checks cannot claim a production signing identity") {
        let fixture = String(repeating: "A", count: 40)
        return rejects { _ = try BrokerIdentity.productionCertificate(fixture) }
            && (try? BrokerIdentity.certificate(fixture.lowercased())) == fixture
    }
    check("response rejects unknown top-level and nested fields before decode") {
        let response = BrokerResponse(requestID: captureRequest.requestID, epoch: epoch,
            stateSequence: 9, runtimeState: state)
        var object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(response)) as! [String: Any]
        object["unexpected"] = true
        let topLevelRejected = rejects {
            try BrokerCodec.response(JSONSerialization.data(withJSONObject: object),
                for: captureRequest, after: 0)
        }
        object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(response)) as! [String: Any]
        var runtime = object["runtimeState"] as! [String: Any]
        runtime["unexpected"] = true
        object["runtimeState"] = runtime
        let nestedRejected = rejects {
            try BrokerCodec.response(JSONSerialization.data(withJSONObject: object),
                for: captureRequest, after: 0)
        }
        return topLevelRejected && nestedRejected
    }
    check("event rejects unknown fields before decode") {
        let event = BrokerEvent(epoch: epoch, stateSequence: 10, runtimeState: state)
        var object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(event)) as! [String: Any]
        object["unexpected"] = true
        return rejects {
            try BrokerCodec.event(JSONSerialization.data(withJSONObject: object), for: epoch, after: 0)
        }
    }
    check("response primitive integers reject string bool fraction negative and overflow") {
        let response = BrokerResponse(requestID: captureRequest.requestID, epoch: epoch,
            stateSequence: 11, runtimeState: state)
        var object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(response)) as! [String: Any]
        let invalidValues: [Any] = ["11", true, 11.5, -1, "18446744073709551616"]
        return invalidValues.allSatisfy { value in
            object["stateSequence"] = value
            return rejects {
                try BrokerCodec.response(JSONSerialization.data(withJSONObject: object),
                    for: captureRequest, after: 0)
            }
        }
    }
    check("probe counters use non-negative primitive integer types") {
        let request = BrokerRequest(operation: .probeCodex, epoch: epoch, payload: BrokerPayload())
        let base: [String: Any] = [
            "status": "modeUnverified", "nodes": [], "metadataReads": 0,
            "focusedInputReads": 0, "selectionReads": 0, "hostWrites": 0,
            "modeVerified": false, "captureBuildEvidenceRecorded": false
        ]
        let invalid: [Any] = ["0", true, 1.5, -1, "18446744073709551616"]
        return invalid.allSatisfy { value in
            var report = base
            report["metadataReads"] = value
            let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: 12, probeReport: try! JSONSerialization.data(withJSONObject: report))
            return rejects {
                try BrokerCodec.response(try BrokerCodec.encode(response), for: request, after: 0)
            }
        }
    }
    check("probe node depth rejects non-integer and negative values") {
        let request = BrokerRequest(operation: .probeCodex, epoch: epoch, payload: BrokerPayload())
        let base: [String: Any] = [
            "status": "modeUnverified", "nodes": [["depth": 0, "role": "group",
                "subroleSupport": "missing", "identifierSupport": "missing"]],
            "metadataReads": 0, "focusedInputReads": 0, "selectionReads": 0,
            "hostWrites": 0, "modeVerified": false, "captureBuildEvidenceRecorded": false
        ]
        return ["0", true, 1.5, -1].allSatisfy { value in
            var report = base
            report["nodes"] = [["depth": value, "role": "group",
                "subroleSupport": "missing", "identifierSupport": "missing"]]
            let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
                stateSequence: 13, probeReport: try! JSONSerialization.data(withJSONObject: report))
            return rejects {
                try BrokerCodec.response(try BrokerCodec.encode(response), for: request, after: 0)
            }
        }
    }
    check("probe boolean fields reject numeric values") {
        let request = BrokerRequest(operation: .probeCodex, epoch: epoch, payload: BrokerPayload())
        var report: [String: Any] = [
            "status": "modeUnverified", "nodes": [], "metadataReads": 0,
            "focusedInputReads": 0, "selectionReads": 0, "hostWrites": 0,
            "modeVerified": false, "captureBuildEvidenceRecorded": false
        ]
        report["modeVerified"] = 1
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch,
            stateSequence: 14, probeReport: try! JSONSerialization.data(withJSONObject: report))
        return rejects {
            try BrokerCodec.response(try BrokerCodec.encode(response), for: request, after: 0)
        }
    }
    return checks
}
