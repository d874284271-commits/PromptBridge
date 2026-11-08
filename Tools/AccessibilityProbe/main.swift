import AccessibilityContracts
import AppKit
import ApplicationServices
import Security

@MainActor private final class Probe: NSObject, NSApplicationDelegate {
    private var connection: NSXPCConnection?
    private var epoch: UUID?
    private var sequence: UInt64 = 0
    private var certificate = ""
    private var operation: BrokerOperation = .status
    private var output: URL?
    private var expectedPath = ""
    private var currentRequest: UUID?
    private var finished = false
    private var report: [String: Any] = [:]
    private var requestEvidenceURL: URL?
    private var responseEvidenceURL: URL?
    private var validatedResponseCount = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count == 4, args[0] == "--result-directory", args[1].hasPrefix("/"),
                  args[2] == "--operation", let op = BrokerOperation(rawValue: args[3]),
                  op == .status || op == .probeClaudeFixture,
                  Bundle.main.bundleIdentifier == BrokerIdentity.clientBundle,
                  let signer = Bundle.main.object(forInfoDictionaryKey: BrokerIdentity.signerKey) as? String else {
                throw BrokerContractError.invalidMessage
            }
            operation = op
            certificate = try BrokerIdentity.productionCertificate(signer)
            expectedPath = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/PromptBridge Accessibility.app").path
            guard signedSelfMatches(try BrokerIdentity.requirement(bundle: BrokerIdentity.clientBundle, certificate: certificate)) else {
                throw BrokerContractError.invalidIdentity
            }
            guard let workspace = Bundle.main.object(forInfoDictionaryKey: "PromptBridgeProbeWorkspace") as? String,
                  workspace.hasPrefix("/") else { throw BrokerContractError.invalidMessage }
            let resultDirectory = URL(fileURLWithPath: args[1], isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
            let resultRoot = URL(fileURLWithPath: workspace).appendingPathComponent(".build/accessibility-poc/results")
                .resolvingSymlinksInPath().standardizedFileURL.path
            guard resultDirectory.path.hasPrefix(resultRoot + "/") else { throw BrokerContractError.invalidMessage }
            let runDirectory = resultDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: runDirectory.path) else { throw BrokerContractError.invalidMessage }
            try fileManager.createDirectory(at: runDirectory, withIntermediateDirectories: false)
            let requests = runDirectory.appendingPathComponent("requests.jsonl")
            let responses = runDirectory.appendingPathComponent("responses.jsonl")
            try Data().write(to: requests, options: [.withoutOverwriting])
            try Data().write(to: responses, options: [.withoutOverwriting])
            output = runDirectory
            requestEvidenceURL = requests
            responseEvidenceURL = responses
            report = ["clientPID": ProcessInfo.processInfo.processIdentifier,
                      "clientBundle": Bundle.main.bundleIdentifier ?? "",
                      "clientPath": Bundle.main.bundleURL.path,
                      "clientVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                      "clientBuild": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                      "clientCertificateSHA1": certificate,
                      // PoC diagnostic only; production UI will query the broker.
                      "clientHasOwnAXPermission": AXIsProcessTrusted(),
                      "probeMarker": probeMarker, "operation": operation.rawValue,
                      "hostTextRead": false, "hostWrites": 0, "modelCalls": 0,
                      "evidenceDirectory": runDirectory.path,
                      "requestEvidence": requests.lastPathComponent,
                      "responseEvidence": responses.lastPathComponent,
                      "validatedResponseCount": 0]
            let connection = NSXPCConnection(machServiceName: BrokerIdentity.service)
            connection.remoteObjectInterface = BrokerXPCInterface.make()
            connection.setCodeSigningRequirement(try BrokerIdentity.requirement(bundle: BrokerIdentity.bundle, certificate: certificate))
            connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.finish(error: "connectionInvalidated") } }
            connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.finish(error: "connectionInterrupted") } }
            self.connection = connection
            connection.resume()
            send(.handshake)
        } catch { finish(error: "invalidSignedProbeConfiguration") }
    }

    private var probeMarker: String {
        #if ACCESSIBILITY_PROBE_CLAUDE_2264542
        "diagnostic-G"
        #elseif ACCESSIBILITY_PROBE_COMPATIBLE_UPDATE
        "update-F"
        #elseif ACCESSIBILITY_PROBE_OPTIONAL_SUBROLE
        "diagnostic-E"
        #elseif ACCESSIBILITY_PROBE_AX_DIAGNOSTIC
        "diagnostic-D"
        #elseif ACCESSIBILITY_PROBE_DIAGNOSTIC
        "diagnostic-C"
        #elseif ACCESSIBILITY_PROBE_UPDATE
        "update-B"
        #else
        "baseline-A"
        #endif
    }

    private func signedSelfMatches(_ text: String) -> Bool {
        var requirement: SecRequirement?, code: SecCode?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecCodeCopySelf([], &code) == errSecSuccess, let requirement, let code else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    private func send(_ action: BrokerOperation) {
        guard let connection, !finished else { return }
        let request = BrokerRequest(operation: action, epoch: action == .handshake ? nil : epoch)
        currentRequest = request.requestID
        do {
            let data = try BrokerCodec.encode(request)
            try appendRequestEvidence(request, data: data)
            guard let remote = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                Task { @MainActor in self?.finish(error: "peerRejectedOrUnavailable") }
            }) as? BrokerXPCProtocol else { finish(error: "missingProxy"); return }
            remote.perform(data) { [weak self] data in
                Task { @MainActor in self?.receive(data, for: request) }
            }
            Task { [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, !self.finished, self.currentRequest == request.requestID else { return }
                self.finish(error: "responseTimeout")
            }
        } catch { finish(error: "invalidRequest") }
    }

    private func receive(_ data: Data, for request: BrokerRequest) {
        guard !finished, currentRequest == request.requestID else { return }
        var failureClassification = "responseIdentityOrContractMismatch"
        do {
            let response = try BrokerCodec.response(data, for: request, after: sequence)
            let peerUID = connection?.effectiveUserIdentifier
            let peerPID = connection?.processIdentifier
            guard peerUID == getuid() else {
                failureClassification = "sameUIDMismatch"
                throw BrokerContractError.invalidIdentity
            }
            if response.error == .busy, request.operation == .handshake {
                try appendResponseEvidence(request: request, response: response,
                    peerUID: peerUID, peerPID: peerPID, classification: nil)
                epoch = response.epoch
                sequence = response.stateSequence
                report["protocolVersion"] = response.protocolVersion
                report["lastRequestID"] = response.requestID.uuidString
                report["lastEpoch"] = response.epoch?.uuidString ?? NSNull()
                report["lastStateSequence"] = response.stateSequence
                report["epoch"] = response.epoch?.uuidString ?? NSNull()
                report["stateSequence"] = response.stateSequence
                report["peerPID"] = peerPID ?? NSNull()
                report["peerUID"] = peerUID ?? NSNull()
                report["sameUID"] = true
                validatedResponseCount += 1
                report["validatedResponseCount"] = validatedResponseCount
                finish(error: "busy")
                return
            }
            guard let status = response.status,
                  status.bundle == BrokerIdentity.bundle, status.certificateSHA1 == certificate,
                  URL(fileURLWithPath: status.path).standardizedFileURL.path == expectedPath,
                  peerPID == status.pid else {
                failureClassification = "statusIdentityMismatch"
                throw BrokerContractError.invalidIdentity
            }
            try status.validateSupportedOperations()
            if request.operation == .handshake {
                guard let verifiedClient = response.verifiedClient,
                      verifiedClient == ownIdentity else {
                    failureClassification = "verifiedClientMismatch"
                    throw BrokerContractError.invalidIdentity
                }
            } else if let verifiedClient = response.verifiedClient, verifiedClient != ownIdentity {
                failureClassification = "verifiedClientMismatch"
                throw BrokerContractError.invalidIdentity
            }
            try appendResponseEvidence(request: request, response: response,
                peerUID: peerUID, peerPID: peerPID, classification: nil)
            epoch = response.epoch; sequence = response.stateSequence
            report["component"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(status))
            report["protocolVersion"] = response.protocolVersion
            report["lastRequestID"] = response.requestID.uuidString
            report["lastEpoch"] = response.epoch?.uuidString ?? NSNull()
            report["lastStateSequence"] = response.stateSequence
            report["epoch"] = response.epoch?.uuidString ?? NSNull()
            report["stateSequence"] = response.stateSequence
            report["peerPID"] = peerPID ?? NSNull()
            report["peerUID"] = peerUID ?? NSNull()
            report["sameUID"] = true
            if let verifiedClient = response.verifiedClient {
                report["verifiedClient"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(verifiedClient))
            }
            validatedResponseCount += 1
            report["validatedResponseCount"] = validatedResponseCount
            if let diagnostic = response.hostRejection {
                report["hostRejection"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(diagnostic))
            }
            if let diagnostic = response.axFailure {
                report["axFailure"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(diagnostic))
            }
            if let error = response.error { finish(error: error.rawValue); return }
            if request.operation == .handshake {
                if operation == .probeClaudeFixture, !status.permission {
                    finish(error: BrokerErrorCode.permissionRequired.rawValue)
                } else {
                    send(operation)
                }
                return
            }
            if let metadata = response.metadata { report["metadata"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(metadata)) }
            finish(error: nil)
        } catch {
            if responseEvidenceURL != nil {
                try? appendResponseEvidence(request: request, response: nil,
                    peerUID: connection?.effectiveUserIdentifier,
                    peerPID: connection?.processIdentifier,
                    classification: failureClassification)
            }
            finish(error: "responseIdentityOrContractMismatch")
        }
    }

    private var ownIdentity: BrokerApplicationIdentity {
        BrokerApplicationIdentity(
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            bundle: Bundle.main.bundleIdentifier ?? "",
            path: Bundle.main.bundleURL.standardizedFileURL.path,
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    private func appendRequestEvidence(_ request: BrokerRequest, data: Data) throws {
        guard let url = requestEvidenceURL else { throw BrokerContractError.invalidMessage }
        let envelope = try JSONSerialization.jsonObject(with: data)
        guard let object = envelope as? [String: Any] else { throw BrokerContractError.invalidMessage }
        try appendEvidence(["requestID": request.requestID.uuidString,
                            "operation": request.operation.rawValue,
                            "epoch": request.epoch?.uuidString ?? NSNull(),
                            "request": object], to: url)
    }

    private func appendResponseEvidence(request: BrokerRequest, response: BrokerResponse?,
                                        peerUID: uid_t?, peerPID: pid_t?,
                                        classification: String?) throws {
        guard let url = responseEvidenceURL else { throw BrokerContractError.invalidMessage }
        var row: [String: Any] = ["requestID": request.requestID.uuidString,
                                   "operation": request.operation.rawValue,
                                   "peerPID": peerPID ?? NSNull(),
                                   "peerUID": peerUID ?? NSNull(),
                                   "sameUID": peerUID == getuid()]
        if let response {
            row["validated"] = true
            row["responseID"] = response.requestID.uuidString
            row["epoch"] = response.epoch?.uuidString ?? NSNull()
            row["stateSequence"] = response.stateSequence
            row["error"] = response.error?.rawValue ?? NSNull()
            if let status = response.status {
                row["status"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(status))
            }
            if let verifiedClient = response.verifiedClient {
                row["verifiedClient"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(verifiedClient))
            }
            if let metadata = response.metadata {
                row["metadata"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(metadata))
            }
            if let hostRejection = response.hostRejection {
                row["hostRejection"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(hostRejection))
            }
            if let axFailure = response.axFailure {
                row["axFailure"] = try JSONSerialization.jsonObject(with: BrokerCodec.encode(axFailure))
            }
        } else {
            row["validated"] = false
            row["classification"] = classification ?? "responseIdentityOrContractMismatch"
        }
        try appendEvidence(row, to: url)
    }

    private func appendEvidence(_ object: [String: Any], to url: URL) throws {
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(0x0A)
        let existing = try Data(contentsOf: url)
        var combined = existing
        combined.append(line)
        try combined.write(to: url, options: [.atomic])
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        report["succeeded"] = error == nil
        if let error { report["error"] = error }
        var exitCode: Int32 = error == nil ? 0 : 1
        if let output {
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: output.appendingPathComponent("probe-result.json"), options: .withoutOverwriting)
            } catch { exitCode = 2 }
        }
        connection?.invalidate(); connection = nil
        exit(exitCode)
    }
}

let app = NSApplication.shared
private let delegate = Probe()
app.delegate = delegate
withExtendedLifetime(delegate) { app.run() }
