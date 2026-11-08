import Foundation
import AppKit
import Carbon
import AccessibilityContracts

@MainActor enum CLITerminalFixtureChecks {
    private final class Access: CLITerminalAccess {
        var accessibilityGranted = true
        var automationPermission: CLIAutomationPermission = .granted
        var frontmostPID: Int32? = 700
        var snapshot = CLIProcessSnapshot(pid: 101, parentPID: 100, startTimeMicros: 55,
            processGroup: 101, executablePath: "/fixture/codex", tty: "/dev/ttys001", foregroundProcessGroup: 101)
        var terminal = CLIProcessSnapshot(pid: 700, parentPID: 1, startTimeMicros: 44,
            processGroup: 700, executablePath: "/fixture/Terminal", tty: "")
        var metadata = [CLITerminalTab(windowID: 1, tty: "/dev/ttys001", selected: true, frontWindow: true)]
        var sends = 0; var selections = 0; var activations = 0
        var metadataReads = 0
        var onMetadata: (() -> Void)?
        func terminalProcess() -> CLIProcessSnapshot? { terminal }
        func process(_ pid: Int32) -> CLIProcessSnapshot? { pid == snapshot.pid ? snapshot : nil }
        func tabs(terminalPID: Int32) throws -> [CLITerminalTab] { metadataReads += 1; onMetadata?(); return metadata }
        func sendControlG(terminalPID: Int32) throws { sends += 1 }
        func select(tty: String, windowID: Int32, terminalPID: Int32) throws {
            selections += 1; metadata = [CLITerminalTab(windowID: windowID, tty: tty, selected: true, frontWindow: true)]
        }
        func activate(terminalPID: Int32) -> Bool { activations += 1; frontmostPID = terminalPID; return true }
    }
    static func run() -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ name: String, _ body: () throws -> Bool) { results.append(("CLI Terminal: " + name, (try? body()) == true)) }
        func rejects(_ code: BrokerErrorCode, _ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch let failure as BrokerProbeFailure { return failure.code == code } catch { return false }
        }
        func session(_ a: Access) -> CLITerminalSession {
            let p = a.snapshot
            return CLITerminalSession(id: UUID(), kind: .codex, version: "0.157.1", pid: p.pid,
                startTimeMicros: p.startTimeMicros, processGroup: p.processGroup, tty: p.tty, executablePath: p.executablePath)
        }
        func runtime(_ a: Access) -> CLITerminalRuntime { CLITerminalRuntime(access: a) }
        check("native every-window and every-tab selectors use absolute ordinals") {
            let native = NativeCLITerminalAccess()
            for kind: OSType in [0x6377696e, 0x74746162] {
                let specifier = try native.all(kind)
                guard let selector = specifier.forKeyword(AEKeyword(keyAEKeyData)),
                      specifier.descriptorType == typeObjectSpecifier,
                      selector.descriptorType == typeAbsoluteOrdinal,
                      selector.data == NSAppleEventDescriptor(enumCode: OSType(kAEAll)).data else { return false }
            }
            return true
        }
        check("native metadata events use Terminal core/getd and core/setd") {
            for id: AEEventID in [AEEventID(kAEGetData), AEEventID(kAESetData)] {
                let value = id == AEEventID(kAESetData) ? NSAppleEventDescriptor(boolean: true) : nil
                let event = NativeCLITerminalAccess.metadataEvent(eventID: id, descriptor: .null(),
                    value: value, terminalPID: 700)
                guard event.eventClass == AEEventClass(kAECoreSuite), event.eventID == id,
                      event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.descriptorType == typeNull,
                      (event.paramDescriptor(forKeyword: AEKeyword(keyAEData)) != nil) == (value != nil) else { return false }
            }
            return true
        }
        for (kind, version) in [(CLIHostKind.codex, "0.157.1"), (.claude, "2.1.283"),
                                (.codex, "future"), (.claude, "unknown")] {
            check("\(kind.rawValue) \(version) permits one editor trigger") {
                let a = Access(); let r = runtime(a); let p = a.snapshot
                let session = CLITerminalSession(id: UUID(), kind: kind, version: version, pid: p.pid,
                    startTimeMicros: p.startTimeMicros, processGroup: p.processGroup, tty: p.tty, executablePath: p.executablePath)
                let target = try r.query(session)
                return try r.trigger(target, operationID: UUID()).disposition == .triggered
                    && rejects(.duplicateOperation) { _ = try r.trigger(target, operationID: UUID()) } && a.sends == 1
            }
        }
        check("one trigger per operation and per target") {
            let a = Access(); let r = runtime(a); let t = try r.query(session(a)); let id = UUID()
            let result = try r.trigger(t, operationID: id)
            return result.disposition == .triggered && rejects(.duplicateOperation) { _ = try r.trigger(t, operationID: id) } &&
                rejects(.duplicateOperation) { _ = try r.trigger(t, operationID: UUID()) } && a.sends == 1
        }
        check("PID start identity change rejects without terminal reads") {
            let a = Access(); let r = runtime(a); let s = session(a)
            a.snapshot = CLIProcessSnapshot(pid: 101, parentPID: 100, startTimeMicros: 56, processGroup: 101,
                executablePath: "/fixture/codex", tty: "/dev/ttys001", foregroundProcessGroup: 101)
            return rejects(.identityChanged) { _ = try r.query(s) } && a.metadataReads == 0
        }
        check("background process group rejects before metadata") {
            let a = Access(); let r = runtime(a); let s = session(a)
            a.snapshot = CLIProcessSnapshot(pid: 101, parentPID: 100, startTimeMicros: 55, processGroup: 101,
                executablePath: "/fixture/codex", tty: "/dev/ttys001", foregroundProcessGroup: 200)
            return rejects(.targetChanged) { _ = try r.query(s) } && a.metadataReads == 0
        }
        for permission in [CLIAutomationPermission.denied, .notDetermined, .unknown, .unavailable] {
            check("Automation \(permission.rawValue) does not read metadata") {
                let a = Access(); a.automationPermission = permission; let r = runtime(a)
                return rejects(.automationRequired) { _ = try r.query(session(a)) } && a.metadataReads == 0
            }
        }
        check("AX and Automation are independent") {
            let a = Access(); a.accessibilityGranted = false; let r = runtime(a)
            return rejects(.permissionRequired) { _ = try r.query(session(a)) } && a.metadataReads == 0
        }
        check("duplicate TTY and nonselected tabs rejected") {
            let a = Access(); let r = runtime(a); let s = session(a)
            a.metadata.append(CLITerminalTab(windowID: 2, tty: s.tty, selected: true, frontWindow: false))
            guard rejects(.targetChanged, { _ = try r.query(s) }) else { return false }
            a.metadata = [CLITerminalTab(windowID: 1, tty: s.tty, selected: false, frontWindow: true)]
            return rejects(.targetChanged) { _ = try r.query(s) }
        }
        check("tab switch between query and trigger sends zero keys") {
            let a = Access(); let r = runtime(a); let t = try r.query(session(a))
            a.metadata = [CLITerminalTab(windowID: 1, tty: t.session.tty, selected: false, frontWindow: true)]
            return rejects(.targetChanged) { _ = try r.trigger(t, operationID: UUID()) } && a.sends == 0
        }
        check("foreground change during metadata lookup sends zero keys") {
            let a = Access(); let r = runtime(a); let t = try r.query(session(a))
            a.onMetadata = { a.frontmostPID = 999 }
            return rejects(.targetChanged) { _ = try r.trigger(t, operationID: UUID()) } && a.sends == 0
        }
        check("new capture invalidates earlier token") {
            let a = Access(); let r = runtime(a); let s = session(a); let t = try r.query(s); _ = try r.query(s)
            return rejects(.targetChanged) { _ = try r.trigger(t, operationID: UUID()) } && a.sends == 0
        }
        check("return re-finds TTY after moving tab to another window") {
            let a = Access(); let r = runtime(a); let t = try r.query(session(a))
            a.frontmostPID = 800; a.metadata = [CLITerminalTab(windowID: 2, tty: t.session.tty, selected: false, frontWindow: false)]
            let result = try r.returnTarget(t, operationID: UUID(), clientPID: 800)
            return result.disposition == .returned && a.selections == 1 && a.activations == 1 && a.metadata.first?.windowID == 2 && a.sends == 0
        }
        check("user moved away: return does not select or activate") {
            let a = Access(); let r = runtime(a); let t = try r.query(session(a)); a.frontmostPID = 999
            let result = try r.returnTarget(t, operationID: UUID(), clientPID: 800)
            return result.disposition == .userMovedFocus && a.selections == 0 && a.activations == 0
        }
        check("closed target refuses return") {
            let a = Access(); let r = runtime(a); let t = try r.query(session(a)); a.frontmostPID = 800; a.metadata = []
            return rejects(.targetChanged) { _ = try r.returnTarget(t, operationID: UUID(), clientPID: 800) } && a.activations == 0
        }
        check("disconnect clears target and action state") {
            let a = Access(); let r = runtime(a); let t = try r.query(session(a)); r.clear()
            return rejects(.targetChanged) { _ = try r.trigger(t, operationID: UUID()) } && a.sends == 0
        }
        return results
    }
    static func coordinatorCheck() async -> (String, Bool) {
        let a = Access()
        let client = BrokerApplicationIdentity(pid: 800, bundle: BrokerIdentity.clientBundle,
            path: "/fixture/client", version: "2", build: "2")
        let coordinator = BrokerCoordinator(certificate: String(repeating: "A", count: 40),
            resolveClient: { $0 == client.pid ? client : nil },
            makeHost: { _ in AccessibilityRuntimeHost(syntheticAccess: ExternalInputFixture()) },
            status: { BrokerStatus(pid: 900, bundle: BrokerIdentity.bundle, path: "/fixture/broker", version: "2", build: "2",
                certificateSHA1: String(repeating: "A", count: 40), permission: true,
                supportedOperations: BrokerOperation.requiredProductionOperations, terminalAutomation: .granted) },
            permissionHelp: {}, claudeProbe: { _ in .failure(BrokerProbeFailure(code: .hostRejected)) },
            cliRuntime: CLITerminalRuntime(access: a), exit: {})
        let lease = UUID()
        let name = "CLI Terminal: signed-client coordinator routes query, trigger and return with correlated v2 receipts"
        guard coordinator.admitConnection(lease) else { return (name, false) }
        func perform(_ request: BrokerRequest) async throws -> BrokerResponse {
            let response = await coordinator.perform(try BrokerCodec.encode(request), token: lease, peerPID: client.pid) { _ in }
            return try BrokerCodec.response(response, for: request, after: 0)
        }
        do {
            let handshake = try await perform(BrokerRequest(operation: .handshake))
            guard let epoch = handshake.epoch else { throw BrokerContractError.invalidMessage }
            let session = CLITerminalSession(id: UUID(), kind: .codex, version: "0.157.1", pid: 101,
                startTimeMicros: 55, processGroup: 101, tty: "/dev/ttys001", executablePath: "/fixture/codex")
            let query = try await perform(BrokerRequest(operation: .cliQueryTarget, epoch: epoch, payload: BrokerPayload(cliSession: session)))
            guard let target = query.cliTarget else { throw BrokerContractError.invalidMessage }
            let trigger = try await perform(BrokerRequest(operation: .cliTriggerEditor, epoch: epoch,
                payload: BrokerPayload(operationID: UUID(), cliTarget: target)))
            a.frontmostPID = client.pid
            let back = try await perform(BrokerRequest(operation: .cliReturnTarget, epoch: epoch,
                payload: BrokerPayload(operationID: UUID(), cliTarget: target)))
            await coordinator.disconnect(lease)
            return (name, trigger.cliAction?.disposition == .triggered && back.cliAction?.disposition == .returned &&
                a.sends == 1 && a.activations == 1 && query.runtimeState == nil)
        } catch {
            await coordinator.disconnect(lease)
            return (name, false)
        }
    }

}
