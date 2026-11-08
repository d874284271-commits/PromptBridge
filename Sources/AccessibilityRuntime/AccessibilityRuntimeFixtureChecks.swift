import Foundation
import AccessibilityContracts

/// Runtime-only fixture checks. They retain the AX fixture policies that used
/// to be embedded in the main UI acceptance runner without touching a real host.
@MainActor public enum AccessibilityRuntimeFixtureChecks {
    public static func run() async -> [(String, Bool)] {
        var results = await ExternalFullInputChecks.run()
        results.append(contentsOf: await GenericInputChecks.run())
        results.append(contentsOf: await FocusLauncherChecks.run())
        results.append(contentsOf: await codexProbePolicy())
        results.append(contentsOf: await externalSelectionPolicy())
        results.append(contentsOf: await setterIssuedChecks())
        results.append(contentsOf: await BrokerCoordinatorFixtureChecks.run())
        results.append(contentsOf: CLITerminalFixtureChecks.run())
        results.append(await CLITerminalFixtureChecks.coordinatorCheck())
        return results
    }

    private static func record(_ results: inout [(String, Bool)], _ name: String, _ passed: Bool) {
        results.append((name, passed))
    }

    private final class CodexProbeFixture: CodexCapabilityProbe.Access {
        var hasPermission = true
        var application = CodexCapabilityProbe.Application(pid: 7,
            bundle: CodexCapabilityProbe.bundleIdentifier,
            version: CodexCapabilityProbe.version, build: CodexCapabilityProbe.build)
        var focusAvailable = true
        var foreignParent = false
        var secure = false
        var identifiersAvailable = true
        var focusCalls = 0
        var reads: [(Int, CodexCapabilityProbe.Attribute)] = []
        let identifier = "FIXTURE_PRIVATE_METADATA_NOT_FOR_REPORT"

        func frontmostApplication() -> CodexCapabilityProbe.Application? { application }
        func focusedInput(in application: CodexCapabilityProbe.Application) -> CodexCapabilityProbe.Element? {
            focusCalls += 1
            return focusAvailable ? .fixture(0) : nil
        }
        func owner(of element: CodexCapabilityProbe.Element) -> pid_t? {
            guard case .fixture(let index) = element else { return nil }
            return foreignParent && index > 0 ? 8 : 7
        }
        func read(_ attribute: CodexCapabilityProbe.Attribute,
                  from element: CodexCapabilityProbe.Element) -> CodexCapabilityProbe.Value {
            guard case .fixture(let index) = element else { return .unavailable(.unavailable) }
            reads.append((index, attribute))
            switch attribute {
            case .role: return .string(index == 0 ? "AXTextArea" : "AXGroup")
            case .subrole: return secure ? .string("AXSecureTextField") : .unavailable(.missing)
            case .identifier: return identifiersAvailable ? .string(identifier) : .unavailable(.unsupported)
            case .parent: return .element(.fixture(index + 1))
            }
        }
    }

    private static func codexProbePolicy() async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        for (bundle, version, build, accepted) in [
            ("com.anthropic.claudefordesktop", "2.19675.0", "2.19675.0", true),
            ("com.anthropic.claudefordesktop", "2.19675.1", "2.19675.1", true),
            ("com.anthropic.claudefordesktop", "2.26454.2", "2.26454.2", true),
            ("com.anthropic.claudefordesktop", "2.26454.2", "2.26454.0", true),
            ("com.anthropic.claudefordesktop", "2.26454.0", "2.26454.2", true),
            ("com.anthropic.claudefordesktop", "2.26454.0", "2.26454.0", true),
            ("com.anthropic.claudefordesktop", "2.26454.3", "2.26454.3", true),
            ("com.anthropic.claudefordesktop", "2.19675.0", "2.19675.1", true),
            ("com.anthropic.claudefordesktop", "2.19675.1", "2.19675.0", true),
            ("com.anthropic.claudefordesktop", "2.19675.2", "2.19675.2", true),
            (CodexCapabilityProbe.bundleIdentifier, "26.930.51102", "13100", true),
            (CodexCapabilityProbe.bundleIdentifier, "26.930.31730", "12947", true),
            (CodexCapabilityProbe.bundleIdentifier, "26.930.51102", "13101", true),
            ("fixture.unsupported", "2.19675.1", "2.19675.1", true),
            ("com.anthropic.claudefordesktop", "", "", true),
        ] {
            let application = ExternalApplication(pid: 7, bundle: bundle, version: version, build: build)
            record(&results,
                   "runtime host eligibility uses bundle without a version whitelist \(bundle)/\(version)/\(build)",
                   ExternalReplacementCapabilities.permitsRuntimeCheck(application) == accepted
                    && ((try? ExternalInput.Host.matching(application)) != nil) == accepted
                    && FocusLauncherPolicy.supports(bundle: bundle, version: version, build: build) == accepted)
        }

        record(&results, "Claude 2.26454.2 metadata approval is not historical full replacement evidence",
               !ExternalReplacementCapabilities.hasReplacementEvidence(ExternalApplication(pid: 7,
                    bundle: "com.anthropic.claudefordesktop", version: "2.26454.2", build: "2.26454.2")))

        for scope in [CaptureScope.selection, .entireInput] {
            let fixture = ExternalInputFixture()
            fixture.application = ExternalApplication(pid: 7,
                bundle: "com.anthropic.claudefordesktop", version: "2.26454.2", build: "2.26454.2")
            fixture.foreground = fixture.application
            fixture.fullDraft = fixture.text
            fixture.range = CFRange(location: 0, length: (fixture.text as NSString).length)
            let input = ExternalInput(access: fixture)
            do {
                if scope == .selection { try input.captureFrontmost() }
                else { try await input.captureFrontmost(scope: scope) }
                record(&results, "Claude 2.26454.2 reaches runtime capture checks for \(scope); fixture only",
                       input.snapshot()?.selectedText == fixture.text && fixture.rangeReads > 0 && fixture.writeCount == 0)
            } catch {
                record(&results, "Claude 2.26454.2 reaches runtime capture checks for \(scope); fixture only", false)
            }
        }

        for scope in [CaptureScope.selection, .entireInput] {
            let fixture = ExternalInputFixture()
            fixture.application = ExternalApplication(pid: 7,
                bundle: "com.anthropic.claudefordesktop", version: "future", build: "unknown")
            fixture.foreground = fixture.application
            fixture.fullDraft = fixture.text
            fixture.range = CFRange(location: 0, length: fixture.text.utf16.count)
            let input = ExternalInput(access: fixture)
            do {
                if scope == .selection { try input.captureFrontmost() }
                else { try await input.captureFrontmost(scope: scope) }
                record(&results, "unknown Claude reaches runtime capture for \(scope)",
                       fixture.appElementReads > 0 && fixture.rangeReads > 0
                       && fixture.writeCount == 0 && input.snapshot()?.selectedText == fixture.text)
            } catch { record(&results, "unknown Claude reaches runtime capture for \(scope)", false) }
        }

        for (version, build, evidence) in [
            ("26.930.31730", "12947", true), ("26.930.51102", "13100", true),
            ("26.930.31730", "13100", false), ("26.930.51102", "12947", false),
            ("26.1002.51308", "13417", false), ("future", "unknown", false),
        ] {
            let fixture = CodexProbeFixture()
            fixture.application = .init(pid: 7, bundle: CodexCapabilityProbe.bundleIdentifier,
                                        version: version, build: build)
            let report = CodexCapabilityProbe.inspect(using: fixture)
            let input = ExternalInputFixture()
            input.application = ExternalApplication(pid: 7, bundle: CodexCapabilityProbe.bundleIdentifier,
                                                    version: version, build: build)
            input.foreground = input.application
            let external = ExternalInput(access: input)
            do {
                try external.captureFrontmost()
                record(&results, "Codex pair \(version)/\(build) reaches runtime capture without version rejection",
                       report.status == .modeUnverified && fixture.focusCalls == 1 && external.snapshot() != nil)
                record(&results, "recorded capture evidence is separate from admission \(version)/\(build)",
                       report.captureBuildEvidenceRecorded == evidence)
                record(&results, "replacement evidence is not inferred for unknown pairs \(version)/\(build)",
                       ExternalReplacementCapabilities.hasReplacementEvidence(input.application)
                           == (version == "26.930.51102" && build == "13100"))
            } catch {
                record(&results, "Codex pair \(version)/\(build) reaches runtime capture without version rejection", false)
                record(&results, "recorded capture evidence is separate from admission \(version)/\(build)", false)
                record(&results, "replacement evidence is not inferred for unknown pairs \(version)/\(build)", false)
            }
        }

        let denied = CodexProbeFixture()
        denied.hasPermission = false
        let deniedReport = CodexCapabilityProbe.inspect(using: denied)
        record(&results, "no permission stops before focused element and metadata reads",
               deniedReport.status == .permissionRequired && denied.focusCalls == 0 && denied.reads.isEmpty)

        let otherApp = CodexProbeFixture()
        otherApp.application = .init(pid: 7, bundle: "fixture.unsupported",
                                     version: CodexCapabilityProbe.version, build: CodexCapabilityProbe.build)
        let otherReport = CodexCapabilityProbe.inspect(using: otherApp)
        record(&results, "unsupported application stops before AX access",
               otherReport.status == .unsupportedFrontApplication && otherApp.focusCalls == 0 && otherApp.reads.isEmpty)

        let unknownBuild = CodexProbeFixture()
        unknownBuild.application = .init(pid: 7, bundle: CodexCapabilityProbe.bundleIdentifier,
                                         version: "unverified", build: "other")
        let unknownReport = CodexCapabilityProbe.inspect(using: unknownBuild)
        record(&results, "unknown build reaches read-only metadata without claiming verification",
               unknownReport.status == .modeUnverified && unknownBuild.focusCalls == 1
                   && !unknownReport.captureBuildEvidenceRecorded && !unknownBuild.reads.isEmpty)

        let missingFocus = CodexProbeFixture()
        missingFocus.focusAvailable = false
        record(&results, "missing focused input reads no metadata",
               CodexCapabilityProbe.inspect(using: missingFocus).status == .focusedInputUnavailable
                   && missingFocus.reads.isEmpty)

        let secure = CodexProbeFixture()
        secure.secure = true
        record(&results, "secure field stops before identifier or parent",
               CodexCapabilityProbe.inspect(using: secure).status == .secureInput
                   && secure.reads.map(\.1) == [.role, .subrole])

        let foreign = CodexProbeFixture()
        foreign.foreignParent = true
        record(&results, "foreign parent is rejected before its attributes are read",
               CodexCapabilityProbe.inspect(using: foreign).status == .foreignElement
                   && foreign.reads.allSatisfy { $0.0 == 0 })

        let fixture = CodexProbeFixture()
        let report = CodexCapabilityProbe.inspect(using: fixture)
        record(&results, "single parent chain stops at four ancestors",
               report.nodes.count == 5 && fixture.reads.filter { $0.1 == .parent }.count == 4
                   && fixture.reads.count == 19)
        record(&results, "available metadata never claims verified mode, selection access or host writes",
               report.status == .modeUnverified && !report.modeVerified
                   && report.selectionReads == 0 && report.hostWrites == 0)
        let encoded = String(decoding: (try? JSONEncoder().encode(report)) ?? Data(), as: UTF8.self)
        record(&results, "report never exports raw identifier values", !encoded.contains(fixture.identifier))

        let noIdentifiers = CodexProbeFixture()
        noIdentifiers.identifiersAvailable = false
        record(&results, "missing identifiers are reported without a permissive fallback",
               CodexCapabilityProbe.inspect(using: noIdentifiers).status == .modeMetadataMissing)
        return results
    }

    private static func externalSelectionPolicy() async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func rejected(_ fixture: ExternalInputFixture, _ expected: ExternalInputError) {
            let external = ExternalInput(access: fixture)
            var matched = false
            do { try external.captureFrontmost() }
            catch let error as ExternalInputError { matched = error == expected }
            catch { matched = false }
            record(&results, "reject \(expected)", matched)
            record(&results, "reject \(expected) before selection reads",
                   !fixture.reads.contains(.selectedText) && fixture.rangeReads == 0)
        }

        let denied = ExternalInputFixture(); denied.hasPermission = false
        rejected(denied, .permissionRequired)
        let wrong = ExternalInputFixture()
        wrong.application = ExternalApplication(pid: 7, bundle: BrokerIdentity.clientBundle, version: "", build: "")
        wrong.foreground = wrong.application
        rejected(wrong, .unsupportedApplication)
        record(&results, "unsupported bundle never creates AX app element", wrong.appElementReads == 0)
        let version = ExternalInputFixture()
        version.application = ExternalApplication(pid: 7, bundle: CodexCapabilityProbe.bundleIdentifier,
                                                  version: "other", build: "other")
        version.foreground = version.application
        let runtimeInput = ExternalInput(access: version)
        do {
            try runtimeInput.captureFrontmost()
            record(&results, "unknown Codex build captures only after runtime selection validation",
                   runtimeInput.snapshot() != nil && version.rangeReads > 0)
        } catch { record(&results, "unknown Codex build captures only after runtime selection validation", false) }
        let group = ExternalInputFixture(); group.role = "AXGroup"; rejected(group, .noFocusedInput)
        let search = ExternalInputFixture(); search.role = "AXStaticText"; rejected(search, .noFocusedInput)
        let secure = ExternalInputFixture(); secure.secure = true; rejected(secure, .secureInput)
        let readonly = ExternalInputFixture(); readonly.editable = false; rejected(readonly, .noFocusedInput)
        let foreign = ExternalInputFixture(); foreign.foreignInput = true; rejected(foreign, .noFocusedInput)

        for kind in 0...3 {
            let fixture = ExternalInputFixture()
            if kind == 0 { fixture.range.length = 0; fixture.text = "" }
            if kind == 1 { fixture.range.length -= 1 }
            if kind == 2 { fixture.range.location = -1 }
            if kind == 3 { fixture.rangeText = "different range text" }
            let external = ExternalInput(access: fixture)
            var rejected = false
            do { try external.captureFrontmost() } catch is ExternalInputError { rejected = true } catch { }
            record(&results, "invalid/empty UTF-16 selection \(kind) never establishes target",
                   rejected && !external.hasTarget)
        }

        let unsupported = ExternalInputFixture(); unsupported.notificationsSupported = false
        do {
            let input = ExternalInput(access: unsupported)
            try input.captureFrontmost()
            record(&results, "missing notifications uses live selection validation", input.snapshot() != nil)
        } catch { record(&results, "missing notifications uses live selection validation", false) }

        let fixture = ExternalInputFixture()
        let external = ExternalInput(access: fixture)
        do {
            try external.captureFrontmost()
            record(&results, "Codex editable text area captures verified UTF-16 selection without mode identifiers",
                   external.snapshot()?.selectedText == fixture.text && !fixture.selectionEventsRequired)
        } catch { record(&results, "Codex editable text area captures verified UTF-16 selection without mode identifiers", false) }

        let ownHandoff = ExternalInputFixture()
        ownHandoff.focusReadHandoff = ownHandoff.ownApplication
        let ownCapture = ExternalInput(access: ownHandoff)
        do {
            try ownCapture.captureFrontmost()
            record(&results, "own-panel activation during focus IPC retains the verified selection",
                   ownCapture.snapshot() != nil && ownCapture.lastReadFailure == nil)
        } catch { record(&results, "own-panel activation during focus IPC retains the verified selection", false) }

        let pendingHandoff = ExternalInputFixture()
        pendingHandoff.focusReadFailureAt = 3
        pendingHandoff.focusReadFailsWithoutHandoff = true
        let pendingCapture = ExternalInput(access: pendingHandoff)
        do {
            try pendingCapture.captureFrontmost()
            pendingCapture.prepareForPanelActivation()
            record(&results, "explicit panel activation tolerates focus IPC lag while revalidating the captured range",
                   pendingCapture.snapshot() != nil)
        } catch { record(&results, "explicit panel activation tolerates focus IPC lag while revalidating the captured range", false) }

        let missingFocus = ExternalInputFixture()
        missingFocus.focusReadFailureAt = 3
        missingFocus.focusReadFailsWithoutHandoff = true
        let missingCapture = ExternalInput(access: missingFocus)
        do {
            try missingCapture.captureFrontmost()
            record(&results, "missing host focus without our activation request still invalidates",
                   missingCapture.snapshot() == nil)
        } catch { record(&results, "missing host focus without our activation request still invalidates", false) }

        pendingHandoff.foreground = ExternalApplication(pid: 8, bundle: "fixture.other", version: "", build: "")
        record(&results, "panel activation deadline never allows another foreground application",
               pendingCapture.snapshot() == nil)
        let foreignHandoff = ExternalInputFixture()
        foreignHandoff.focusReadHandoff = ExternalApplication(pid: 8, bundle: "fixture.other", version: "", build: "")
        let foreignCapture = ExternalInput(access: foreignHandoff)
        var foreignRejected = false
        do { try foreignCapture.captureFrontmost() } catch is ExternalInputError { foreignRejected = true } catch { }
        record(&results, "foreign activation during focus IPC refuses further selection reads",
               foreignRejected && !foreignCapture.isTargetAvailable
                   && foreignHandoff.reads.filter { $0 == .selectedText }.count == 1)

        fixture.foreground = fixture.ownApplication
        fixture.emit("AXFocusedUIElementChanged")
        record(&results, "own UI test bundle and PID retain target while panel is frontmost", external.snapshot() != nil)
        fixture.emit("AXSelectedTextChanged")
        record(&results, "selection A-B-A notification invalidates restored selection", external.snapshot() == nil)
        let readCount = fixture.reads.count
        fixture.emit("poll")
        record(&results, "invalidated target stops all AX reads", fixture.reads.count == readCount)
        for event in ["AXValueChanged", "AXFocusedWindowChanged", "AXUIElementDestroyed"] {
            let f = ExternalInputFixture(); let e = ExternalInput(access: f)
            do {
                try e.captureFrontmost(); f.emit(event)
                record(&results, "\(event) invalidates target", e.snapshot() == nil)
            } catch { record(&results, "\(event) invalidates target", false) }
        }

        let changed = ExternalInputFixture(); let c = ExternalInput(access: changed)
        do {
            try c.captureFrontmost(); changed.focusedInputChanged = true; changed.emit("poll")
            record(&results, "focused control change invalidates before selection reread", c.snapshot() == nil)
        } catch { record(&results, "focused control change invalidates before selection reread", false) }
        let switched = ExternalInputFixture(); let sw = ExternalInput(access: switched)
        do {
            try sw.captureFrontmost(); let before = switched.reads.count
            switched.foreground = ExternalApplication(pid: 8, bundle: "fixture.other", version: "", build: "")
            switched.emit("workspace")
            record(&results, "host switch invalidates before AX access", sw.snapshot() == nil && switched.reads.count == before)
        } catch { record(&results, "host switch invalidates before AX access", false) }
        let claude = ExternalInputFixture()
        claude.application = ExternalApplication(pid: 7, bundle: "com.anthropic.claudefordesktop",
            version: "2.19675.0", build: "2.19675.0")
        claude.foreground = claude.application; claude.role = "AXTextField"; claude.notificationsSupported = false
        let ce = ExternalInput(access: claude)
        do {
            try ce.captureFrontmost()
            record(&results, "Claude preserves existing text-field and notification policy",
                   ce.snapshot()?.identity.host == "Claude" && !claude.selectionEventsRequired)
        } catch { record(&results, "Claude preserves existing text-field and notification policy", false) }

        for failure in 0...2 {
            let f = ExternalInputFixture(); let e = ExternalInput(access: f)
            do {
                try e.captureFrontmost(); f.foreground = f.ownApplication
                if failure == 0 { f.activationAccepted = false }
                if failure == 1 { f.activationChangesFrontmost = false }
                if failure == 2 { f.exitsOnActivation = true }
                let returned = await e.returnFocus()
                record(&results, "return failure \(failure) disables further activation attempts",
                       !returned && !e.canReturnFocus)
                _ = await e.returnFocus()
                record(&results, "return failure \(failure) does not retry", f.activationCount == 1)
            } catch {
                record(&results, "return failure \(failure) disables further activation attempts", false)
                record(&results, "return failure \(failure) does not retry", false)
            }
        }

        let recaptured = ExternalInputFixture(); let re = ExternalInput(access: recaptured)
        do {
            try re.captureFrontmost()
            let staleEvent = recaptured.queuedEvent("AXValueChanged")
            recaptured.foreground = recaptured.ownApplication; recaptured.activationChangesFrontmost = false
            let pending = Task { await re.returnFocus() }
            _ = await waitUntil { recaptured.activationCount == 1 }
            recaptured.foreground = recaptured.application
            try re.captureFrontmost()
            let readsBeforeStaleEvent = recaptured.reads.count
            staleEvent()
            record(&results, "queued event from old capture cannot invalidate or read new capture",
                   re.isTargetAvailable && recaptured.reads.count == readsBeforeStaleEvent)
            let oldReturned = await pending.value
            record(&results, "old return cannot succeed or downgrade new capture in the same PID",
                   !oldReturned && re.canReturnFocus && re.snapshot() != nil)
        } catch {
            record(&results, "queued event from old capture cannot invalidate or read new capture", false)
            record(&results, "old return cannot succeed or downgrade new capture in the same PID", false)
        }

        let queuedFixture = ExternalInputFixture(); let queuedInput = ExternalInput(access: queuedFixture)
        do {
            try queuedInput.captureFrontmost(); queuedFixture.foreground = queuedFixture.ownApplication
            let queuedReturn = Task { await queuedInput.returnFocus() }
            queuedFixture.emit("AXValueChanged")
            let queuedReturned = await queuedReturn.value
            record(&results, "selection invalidation prevents queued return from activating old host",
                   !queuedReturned && queuedFixture.activationCount == 0 && !queuedInput.isTargetAvailable)
        } catch { record(&results, "selection invalidation prevents queued return from activating old host", false) }

        let waitingFixture = ExternalInputFixture(); let waitingInput = ExternalInput(access: waitingFixture)
        do {
            try waitingInput.captureFrontmost(); waitingFixture.foreground = waitingFixture.ownApplication
            waitingFixture.activationChangesFrontmost = false
            let waitingReturn = Task { await waitingInput.returnFocus() }
            _ = await waitUntil { waitingFixture.activationCount == 1 }
            waitingFixture.emit("AXSelectedTextChanged")
            let waitingReturned = await waitingReturn.value
            record(&results, "selection invalidation expires in-flight return token and prevents retry",
                   !waitingReturned && waitingFixture.activationCount == 1 && !waitingInput.isTargetAvailable)
            _ = await waitingInput.returnFocus()
            record(&results, "invalid selection cannot start another automatic return", waitingFixture.activationCount == 1)
            queuedFixture.activationChangesFrontmost = true
            let explicitReturned = await queuedInput.returnFocus(allowInvalidTarget: true)
            record(&results, "explicit recapture navigation can return to known host without reviving selection",
                   explicitReturned && queuedFixture.activationCount == 1)
        } catch {
            record(&results, "selection invalidation expires in-flight return token and prevents retry", false)
            record(&results, "invalid selection cannot start another automatic return", false)
            record(&results, "explicit recapture navigation can return to known host without reviving selection", false)
        }
        return results
    }

    private static func setterIssuedChecks() async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func fixture() -> ExternalInputFixture {
            let value = ExternalInputFixture()
            value.fullDraft = "setter boundary fixture"
            value.range = CFRange(location: 0, length: 0)
            value.replacementApproved = true
            return value
        }
        func payload(_ state: BrokerRuntimeState, _ snapshot: InputSnapshot) -> BrokerWritePayload? {
            guard let token = state.captureToken else { return nil }
            return BrokerWritePayload(
                operationID: UUID(),
                target: BrokerTargetReference(captureToken: token, revision: state.revision),
                expected: snapshot,
                text: "setter boundary output")
        }

        do {
            let access = fixture()
            let host = AccessibilityRuntimeHost(syntheticAccess: access)
            let state = try await host.capture(.entireInput)
            guard let snapshot = state.snapshot, let request = payload(state, snapshot) else {
                record(&results, "setter precheck rejection leaves setter flag false", false)
                record(&results, "setter error after entry marks setter flag true", false)
                return results
            }

            host.resetOperationWriteState()
            access.editable = false
            do {
                _ = try await host.replace(request)
                record(&results, "setter precheck rejection leaves setter flag false", false)
            } catch {
                record(&results, "setter precheck rejection leaves setter flag false",
                       host.setterIssuedForOperation == false && access.writeCount == 0)
            }

            host.resetOperationWriteState()
            access.editable = true
            access.writeFailsAfterSetter = true
            do {
                _ = try await host.replace(request)
                record(&results, "setter error after entry marks setter flag true", false)
            } catch let error as FillError {
                record(&results, "setter error after entry marks setter flag true",
                       error == .outcomeUnknown && host.setterIssuedForOperation && access.writeCount == 1)
            } catch {
                record(&results, "setter error after entry marks setter flag true", false)
            }
        } catch {
            record(&results, "setter precheck rejection leaves setter flag false", false)
            record(&results, "setter error after entry marks setter flag true", false)
        }
        return results
    }

    private static func waitUntil(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}
