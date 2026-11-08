import Foundation
import AccessibilityContracts

@MainActor func runCLIContractChecks() -> [(String, Bool)] {
    var results: [(String, Bool)] = []
    func check(_ name: String, _ body: () throws -> Bool) { results.append(("CLI v2: " + name, (try? body()) == true)) }
    func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
    let epoch = UUID()
    let session = CLITerminalSession(id: UUID(), kind: .codex, version: "0.157.1", pid: 101,
        startTimeMicros: 55, processGroup: 101, tty: "/dev/ttys001", executablePath: "/fixture/codex")
    let target = CLITerminalTarget(token: UUID(), session: session, terminalPID: 700,
        terminalStartTimeMicros: 44, windowID: 1)
    let query = BrokerRequest(operation: .cliQueryTarget, epoch: epoch, payload: BrokerPayload(cliSession: session))
    check("query contains metadata only and round trips") {
        let data = try BrokerCodec.encode(query)
        return try BrokerCodec.request(data) == query && !String(decoding: data, as: UTF8.self).contains("contents") && query.protocolVersion == 3
    }
    check("v1 request rejected explicitly") {
        rejects { _ = try BrokerCodec.request(BrokerCodec.encode(BrokerRequest(operation: .handshake, protocolVersion: 1))) }
    }
    check("query result must refer to requested session") {
        let response = BrokerResponse(requestID: query.requestID, epoch: epoch, stateSequence: 1, cliTarget: target)
        return try BrokerCodec.response(BrokerCodec.encode(response), for: query, after: 0) == response
    }
    for operation in [BrokerOperation.cliTriggerEditor, .cliReturnTarget] {
        check("\(operation.rawValue) requires an operation ID and target") {
            rejects { _ = try BrokerCodec.request(BrokerCodec.encode(BrokerRequest(operation: operation, epoch: epoch, payload: BrokerPayload(cliTarget: target)))) }
        }
        check("\(operation.rawValue) correlates receipt and target") {
            let id = UUID()
            let request = BrokerRequest(operation: operation, epoch: epoch, payload: BrokerPayload(operationID: id, cliTarget: target))
            let receipt = CLIActionReceipt(operationID: id, targetToken: target.token, disposition: operation == .cliTriggerEditor ? .triggered : .returned)
            let response = BrokerResponse(requestID: request.requestID, epoch: epoch, stateSequence: 1, cliAction: receipt)
            return try BrokerCodec.request(BrokerCodec.encode(request)) == request && BrokerCodec.response(BrokerCodec.encode(response), for: request, after: 0) == response
        }
    }
    check("text injected into session rejected") {
        var object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(query)) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        var nested = payload["cliSession"] as! [String: Any]; nested["text"] = "not permitted"
        payload["cliSession"] = nested; object["payload"] = payload
        return rejects { _ = try BrokerCodec.request(JSONSerialization.data(withJSONObject: object)) }
    }
    check("fractional and bool process identities rejected") {
        var object = try JSONSerialization.jsonObject(with: BrokerCodec.encode(query)) as! [String: Any]
        var payload = object["payload"] as! [String: Any]
        var nested = payload["cliSession"] as! [String: Any]
        for value: Any in [true, 1.5, "101"] {
            nested["pid"] = value; payload["cliSession"] = nested; object["payload"] = payload
            guard rejects({ _ = try BrokerCodec.request(JSONSerialization.data(withJSONObject: object)) }) else { return false }
        }
        return true
    }
    check("CLI fields rejected on desktop operation") {
        let request = BrokerRequest(operation: .capture, epoch: epoch, payload: BrokerPayload(scope: .entireInput, cliSession: session))
        return rejects { _ = try BrokerCodec.request(BrokerCodec.encode(request)) }
    }
    check("CLI action cannot claim desktop runtime snapshot") {
        let request = BrokerRequest(operation: .capture, epoch: epoch, payload: BrokerPayload(scope: .entireInput))
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch, stateSequence: 1, error: .unavailable, cliTarget: target)
        return rejects { _ = try BrokerCodec.response(BrokerCodec.encode(response), for: request, after: 0) }
    }
    check("trigger cannot return a success receipt from different action") {
        let id = UUID(); let request = BrokerRequest(operation: .cliTriggerEditor, epoch: epoch, payload: BrokerPayload(operationID: id, cliTarget: target))
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch, stateSequence: 1,
            cliAction: CLIActionReceipt(operationID: id, targetToken: target.token, disposition: .returned))
        return rejects { _ = try BrokerCodec.response(BrokerCodec.encode(response), for: request, after: 0) }
    }
    check("Automation status is independently represented") {
        let status = BrokerStatus(pid: 42, bundle: BrokerIdentity.bundle, path: "/fixture/helper", version: "2", build: "2",
            certificateSHA1: String(repeating: "A", count: 40), permission: true,
            supportedOperations: BrokerOperation.requiredProductionOperations, terminalAutomation: .denied)
        let request = BrokerRequest(operation: .status, epoch: epoch)
        let response = BrokerResponse(requestID: request.requestID, epoch: epoch, stateSequence: 1, status: status)
        let decoded = try BrokerCodec.response(BrokerCodec.encode(response), for: request, after: 0)
        return decoded.status?.permission == true && decoded.status?.terminalAutomation == .denied
    }
    check("old v1 event rejected") {
        let event = BrokerEvent(epoch: epoch, stateSequence: 1, protocolVersion: 1)
        return rejects { _ = try BrokerCodec.event(BrokerCodec.encode(event), for: epoch, after: 0) }
    }
    return results
}
