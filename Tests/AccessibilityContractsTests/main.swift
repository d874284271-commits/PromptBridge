import AccessibilityContracts
import Foundation

var failures = 0
var count = 0
@MainActor func check(_ name: String, _ body: () throws -> Bool) {
    count += 1
    do { if try body() { print("PASS \(name)"); return } } catch {}
    failures += 1; print("FAIL \(name)")
}
func rejects(_ body: () throws -> Void) -> Bool {
    do { try body(); return false } catch { return true }
}

let certificate = String(repeating: "A1", count: 20)
check("certificate normalized") { try BrokerIdentity.certificate(certificate.lowercased()) == certificate }
for value in ["-", "PromptBridge Local Code Signing", String(repeating: "A", count: 39), String(repeating: "G", count: 40), certificate + "\" or true"] {
    check("reject unsafe certificate \(value.count)") { rejects { _ = try BrokerIdentity.certificate(value) } }
}
check("exact bundle and certificate requirement") {
    try BrokerIdentity.requirement(bundle: BrokerIdentity.bundle, certificate: certificate)
        == "identifier \"local.promptbridge.accessibility\" and certificate leaf = H\"\(certificate)\""
}
check("reject arbitrary peer bundle") { rejects { _ = try BrokerIdentity.requirement(bundle: "com.other.app", certificate: certificate) } }
let handshake = BrokerRequest(operation: .handshake)
check("handshake round trip") { try BrokerCodec.request(BrokerCodec.encode(handshake)) == handshake }
check("nil epoch omitted") {
    let value = try JSONSerialization.jsonObject(with: BrokerCodec.encode(handshake)) as! [String: Any]
    return value["epoch"] == nil
}
let epoch = UUID()
let statusRequest = BrokerRequest(operation: .status, epoch: epoch)
check("status round trip") { try BrokerCodec.request(BrokerCodec.encode(statusRequest)) == statusRequest }
for request in [BrokerRequest(operation: .status), BrokerRequest(operation: .handshake, epoch: epoch), BrokerRequest(operation: .status, epoch: epoch, protocolVersion: 1)] {
    check("reject invalid request boundary \(request.operation)") { rejects { _ = try BrokerCodec.request(BrokerCodec.encode(request)) } }
}
for json in [
    "{}", "{\"protocolVersion\":1,\"requestID\":\"bad\",\"operation\":\"handshake\"}",
    "{\"protocolVersion\":1,\"requestID\":\"\(UUID())\",\"operation\":\"executeShell\"}",
    "{\"protocolVersion\":1,\"requestID\":\"\(UUID())\",\"operation\":\"handshake\",\"text\":\"must not be accepted\"}"
] { check("reject malformed or unapproved operation") { rejects { _ = try BrokerCodec.request(Data(json.utf8)) } } }
let status = BrokerStatus(pid: 123, bundle: BrokerIdentity.bundle, path: "/fixture/Component.app", version: "1.0.0", build: "1", certificateSHA1: certificate, permission: true)
let response = BrokerResponse(requestID: statusRequest.requestID, epoch: epoch, stateSequence: 1, status: status)
check("response round trip") { try JSONDecoder().decode(BrokerResponse.self, from: BrokerCodec.encode(response)) == response }
check("valid correlated response") { try response.validate(for: statusRequest, after: 0); return true }
check("reject old sequence") { rejects { try response.validate(for: statusRequest, after: 1) } }
check("reject wrong request") { rejects { try response.validate(for: BrokerRequest(operation: .status, epoch: epoch), after: 0) } }
check("reject wrong epoch") { rejects { try response.validate(for: BrokerRequest(operation: .status, epoch: UUID(), requestID: statusRequest.requestID), after: 0) } }
check("reject false probe success") {
    let request = BrokerRequest(operation: .probeClaudeFixture, epoch: epoch)
    return rejects { try BrokerResponse(requestID: request.requestID, epoch: epoch, stateSequence: 2, status: status).validate(for: request, after: 1) }
}
check("busy handshake cannot be mistaken for success") {
    let busy = BrokerResponse(requestID: handshake.requestID, epoch: nil, stateSequence: 1, error: .busy)
    try busy.validate(for: handshake, after: 0)
    return busy.status == nil && busy.error == .busy
}
for subrole: String? in [nil, "AXSecureTextField"] {
    check("reject unknown or secure probe metadata") {
        let request = BrokerRequest(operation: .probeClaudeFixture, epoch: epoch)
        let metadata = BrokerMetadata(hostPID: 123, hostVersion: "2.19675.1", hostBuild: "2.19675.1",
            role: "AXTextArea", subrole: subrole, editable: true, stableFocusedIdentity: true)
        return rejects { try BrokerResponse(requestID: request.requestID, epoch: epoch, stateSequence: 2, status: status, metadata: metadata).validate(for: request, after: 1) }
    }
}
func subroleResponse(_ subrole: String?, evidence: BrokerSubroleEvidence?) -> BrokerResponse {
    let metadata = BrokerMetadata(hostPID: 123, hostVersion: "2.26454.0", hostBuild: "2.26454.0",
        role: "AXTextArea", subrole: subrole, editable: true, stableFocusedIdentity: true, subroleEvidence: evidence)
    return BrokerResponse(requestID: optionalRequest.requestID, epoch: epoch, stateSequence: 2, status: status, metadata: metadata)
}
let optionalRequest = BrokerRequest(operation: .probeClaudeFixture, epoch: epoch)
for evidence: BrokerSubroleEvidence in [.noValue, .attributeUnsupported] {
    check("accept explicitly verified subrole absence \(evidence)") {
        let response = subroleResponse(nil, evidence: evidence)
        let decoded = try JSONDecoder().decode(BrokerResponse.self, from: BrokerCodec.encode(response))
        try decoded.validate(for: optionalRequest, after: 1)
        let object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(decoded.metadata!)) as! [String: Any]
        return decoded == response && object["subrole"] == nil && object["subroleEvidence"] as? String == evidence.rawValue
    }
    for value in ["AXUnknown", "AXSecureTextField"] {
        check("reject absent evidence with value \(evidence) \(value)") {
            rejects { try subroleResponse(value, evidence: evidence).validate(for: optionalRequest, after: 1) }
        }
    }
}
check("accept observed ordinary subrole") {
    try subroleResponse("AXUnknown", evidence: .observed).validate(for: optionalRequest, after: 1); return true
}
for value: String? in [nil, "AXSecureTextField"] {
    check("reject observed nil or secure subrole") {
        rejects { try subroleResponse(value, evidence: .observed).validate(for: optionalRequest, after: 1) }
    }
}
check("legacy string response remains valid") {
    var object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(subroleResponse("AXUnknown", evidence: nil))) as! [String: Any]
    var metadata = object["metadata"] as! [String: Any]; metadata.removeValue(forKey: "subroleEvidence"); object["metadata"] = metadata
    let decoded = try JSONDecoder().decode(BrokerResponse.self, from: JSONSerialization.data(withJSONObject: object))
    try decoded.validate(for: optionalRequest, after: 1); return true
}
check("legacy absent subrole evidence remains rejected after decoding") {
    let decoded = try JSONDecoder().decode(BrokerResponse.self, from: BrokerCodec.encode(subroleResponse(nil, evidence: nil)))
    return rejects { try decoded.validate(for: optionalRequest, after: 1) }
}
for evidence: Any in ["notRead", "futureUnknown", 1, true] {
    check("reject unknown or wrong-type subrole evidence") {
        var object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(subroleResponse(nil, evidence: nil))) as! [String: Any]
        var metadata = object["metadata"] as! [String: Any]; metadata["subroleEvidence"] = evidence; object["metadata"] = metadata
        return rejects { _ = try JSONDecoder().decode(BrokerResponse.self, from: JSONSerialization.data(withJSONObject: object)) }
    }
}
let probeRequest = BrokerRequest(operation: .probeClaudeFixture, epoch: epoch)
let rejectedHost = BrokerHostRejection(reason: .unexpectedFrontmostApplication, foreground: .component, componentActive: true)
let rejectedResponse = BrokerResponse(requestID: probeRequest.requestID, epoch: epoch, stateSequence: 2,
    error: .hostRejected, status: status, hostRejection: rejectedHost)
check("correlated rejected preflight diagnostic round trip") {
    let decoded = try JSONDecoder().decode(BrokerResponse.self, from: BrokerCodec.encode(rejectedResponse))
    try decoded.validate(for: probeRequest, after: 1)
    return decoded == rejectedResponse
}
check("absent diagnostic omitted for legacy response") {
    let object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(response)) as! [String: Any]
    return object["hostRejection"] == nil && object["axFailure"] == nil
}
check("diagnostic cannot accompany successful response") {
    rejects { try BrokerResponse(requestID: statusRequest.requestID, epoch: epoch, stateSequence: 2,
        status: status, hostRejection: rejectedHost).validate(for: statusRequest, after: 1) }
}
check("diagnostic only allowed for metadata host rejection") {
    rejects { try BrokerResponse(requestID: statusRequest.requestID, epoch: epoch, stateSequence: 2,
        error: .hostRejected, status: status, hostRejection: rejectedHost).validate(for: statusRequest, after: 1) }
}
check("foreign foreground never carries claimed Claude version") {
    rejects { try BrokerHostRejection(reason: .unexpectedFrontmostApplication, foreground: .other,
        componentActive: false, observedClaudeVersion: "2.26454.0").validate() }
}
check("unknown diagnostic reason rejected") {
    rejects { _ = try JSONDecoder().decode(BrokerHostRejection.self,
        from: Data("{\"reason\":\"unknown\",\"foreground\":\"other\",\"componentActive\":false}".utf8)) }
}
check("rejection diagnostic cannot carry AX metadata") {
    let metadata = BrokerMetadata(hostPID: 123, hostVersion: "2.26454.0", hostBuild: "2.26454.0",
        role: "AXTextArea", subrole: "AXUnknown", editable: true, stableFocusedIdentity: true)
    return rejects { try BrokerResponse(requestID: probeRequest.requestID, epoch: epoch, stateSequence: 2,
        error: .hostRejected, status: status, metadata: metadata, hostRejection: rejectedHost).validate(for: probeRequest, after: 1) }
}
check("early host failure cannot carry version fields") {
    rejects { try BrokerHostRejection(reason: .hostTerminated, foreground: .expectedHost,
        componentActive: false, observedClaudeVersion: "2.26454.0").validate() }
}
check("missing build diagnostic cannot claim a build") {
    rejects { try BrokerHostRejection(reason: .hostBuildUnavailable, foreground: .expectedHost,
        componentActive: false, observedClaudeVersion: "2.26454.0", observedClaudeBuild: "2.26454.0").validate() }
}
let axDiagnostic = BrokerAXFailure(stage: .inputSubrole, operation: .copyAttribute, kind: .apiError,
    rawAXError: -25205, successfulAttributeReads: 4)
check("correlated AX failure diagnostic round trip") {
    let value = BrokerResponse(requestID: probeRequest.requestID, epoch: epoch, stateSequence: 2,
        error: .unavailable, status: status, axFailure: axDiagnostic)
    let decoded = try JSONDecoder().decode(BrokerResponse.self, from: BrokerCodec.encode(value))
    try decoded.validate(for: probeRequest, after: 1)
    return decoded == value
}
check("AX diagnostic cannot accompany success") {
    rejects { try BrokerResponse(requestID: probeRequest.requestID, epoch: epoch, stateSequence: 2,
        status: status, axFailure: axDiagnostic).validate(for: probeRequest, after: 1) }
}
check("AX diagnostic cannot accompany host rejection") {
    rejects { try BrokerResponse(requestID: probeRequest.requestID, epoch: epoch, stateSequence: 2,
        error: .hostRejected, status: status, hostRejection: rejectedHost, axFailure: axDiagnostic).validate(for: probeRequest, after: 1) }
}
check("AX api error cannot claim success code") {
    rejects { try BrokerAXFailure(stage: .focusedWindow, operation: .configureTimeout,
        kind: .apiError, rawAXError: 0, successfulAttributeReads: 0).validate() }
}
check("AX diagnostic operation restricted to fixed stage") {
    rejects { try BrokerAXFailure(stage: .windowRole, operation: .decodeSubrole,
        kind: .unexpectedValueType, successfulAttributeReads: 3).validate() }
}
check("Data-only XPC interface initializes") { _ = BrokerXPCInterface.make(); return true }
for (name, passed) in runProductionContractChecks() { check(name) { passed } }
for (name, passed) in runCLIContractChecks() { check(name) { passed } }
print("AccessibilityContracts: \(count - failures)/\(count) passed; no system registration, AX reads or model requests.")
exit(failures == 0 ? 0 : 1)
