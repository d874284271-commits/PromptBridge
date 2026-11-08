import AppKit
import AccessibilityContracts

/// Deterministic metadata fixtures: never accesses a real application or its input.
@MainActor enum FocusLauncherChecks {
    private final class Sampler: FocusLauncherSampling {
        var state: FocusLauncherState = .unavailable
        var calls = 0
        var suspend = false
        var continuation: CheckedContinuation<FocusLauncherState, Never>?

        func sample() async -> FocusLauncherState {
            calls += 1
            guard suspend else { return state }
            return await withCheckedContinuation { continuation = $0 }
        }

        func finish(_ value: FocusLauncherState) {
            let saved = continuation
            continuation = nil
            saved?.resume(returning: value)
        }
    }

    static func run() async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func record(_ name: String, _ value: Bool) { results.append((name, value)) }
        let claude = "com.anthropic.claudefordesktop"
        let codex = "com.openai.codex"
        record("focused launcher allows exact verified Claude build",
               FocusLauncherPolicy.supports(bundle: claude, version: "2.19675.0", build: "2.19675.0"))
        record("focused launcher allows exact verified Claude 2.19675.1 build",
               FocusLauncherPolicy.supports(bundle: claude, version: "2.19675.1", build: "2.19675.1"))
        record("focused launcher admits Claude version/build mismatches and unrecorded builds",
               FocusLauncherPolicy.supports(bundle: claude, version: "2.19675.0", build: "2.19675.1") &&
               FocusLauncherPolicy.supports(bundle: claude, version: "2.19675.1", build: "2.19675.0") &&
               FocusLauncherPolicy.supports(bundle: claude, version: "2.26454.0", build: "2.26454.0"))
        record("focused launcher admits absent Claude version metadata",
               FocusLauncherPolicy.supports(bundle: claude, version: "", build: ""))
        record("focused launcher allows exact verified Codex build",
               FocusLauncherPolicy.supports(bundle: codex, version: "26.930.51102", build: "13100"))
        record("focused launcher admits older Codex pair to runtime sampling",
               FocusLauncherPolicy.supports(bundle: codex, version: "26.930.31730", build: "12947"))
        record("focused launcher ignores version pairing for Codex sampling",
               FocusLauncherPolicy.supports(bundle: codex, version: "26.930.51102", build: "12947"))
        record("focused launcher admits generic applications",
               FocusLauncherPolicy.supports(bundle: codex, version: "26.930.51103", build: "13101") &&
               FocusLauncherPolicy.supports(bundle: "com.openai.chat", version: "26.930.51102", build: "13100"))
        record("focused launcher follows verified role boundaries",
               FocusLauncherPolicy.supportsInput(role: "AXTextArea", bundle: codex, editable: true) &&
               FocusLauncherPolicy.supportsInput(role: "AXTextField", bundle: claude, editable: true) &&
               FocusLauncherPolicy.supportsInput(role: "AXTextField", bundle: codex, editable: true) &&
               !FocusLauncherPolicy.supportsInput(role: "AXWebArea", bundle: codex, editable: true) &&
               !FocusLauncherPolicy.supportsInput(role: "AXTextArea", bundle: codex, editable: false))

        record("focused launcher rejects secure subrole before offering input",
               !FocusLauncherPolicy.supportsInput(role: "AXTextArea", subrole: "AXSecureTextField",
                   bundle: codex, editable: true))
        record("focused launcher permits optional absent subrole on ordinary text area",
               FocusLauncherPolicy.supportsInput(role: "AXTextArea", subrole: nil,
                   bundle: codex, editable: true))

        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: -1280, y: 200, width: 1280, height: 1024)]
        let frame = FocusLauncherPolicy.appKitFrame(position: CGPoint(x: 100, y: 600),
            size: CGSize(width: 700, height: 90), primaryScreenTop: 900, screens: screens)
        record("focused input AX position converts to AppKit coordinates",
               frame == CGRect(x: 100, y: 210, width: 700, height: 90))
        record("focused input coordinates retain second-screen offsets",
               FocusLauncherPolicy.appKitFrame(position: CGPoint(x: -1100, y: -100),
                    size: CGSize(width: 600, height: 60), primaryScreenTop: 900, screens: screens)
               == CGRect(x: -1100, y: 940, width: 600, height: 60))
        record("focused launcher rejects invalid or entirely offscreen geometry",
               FocusLauncherPolicy.appKitFrame(position: CGPoint(x: CGFloat.nan, y: 10),
                    size: CGSize(width: 20, height: 20), primaryScreenTop: 900, screens: screens) == nil &&
               FocusLauncherPolicy.appKitFrame(position: CGPoint(x: 0, y: 0),
                    size: .zero, primaryScreenTop: 900, screens: screens) == nil &&
               FocusLauncherPolicy.appKitFrame(position: CGPoint(x: 5000, y: 5000),
                    size: CGSize(width: 20, height: 20), primaryScreenTop: 900, screens: screens) == nil)

        let target = FocusLauncherTarget(pid: 7, bundle: codex,
            windowIdentity: .init(fixture: 1), inputIdentity: .init(fixture: 2),
            anchor: CGRect(x: 100, y: 210, width: 700, height: 90))
        let sampler = Sampler()
        var received: [FocusLauncherState] = []
        let monitor = FocusLauncherMonitor(sampler: sampler, automaticScheduling: false) { received.append($0) }
        monitor.setMode(.persistent)
        monitor.refresh()
        await monitor.waitForPendingRefresh()
        record("persistent mode never samples external metadata", sampler.calls == 0)
        sampler.state = .target(target)
        monitor.setMode(.focusedInput)
        await monitor.waitForPendingRefresh()
        record("focused mode publishes metadata target", monitor.state == .target(target) && received == [.target(target)])
        monitor.refresh()
        await monitor.waitForPendingRefresh()
        record("unchanged sample produces no duplicate UI callback", sampler.calls == 2 && received.count == 1)
        let moved = FocusLauncherTarget(pid: target.pid, bundle: target.bundle,
            windowIdentity: target.windowIdentity, inputIdentity: target.inputIdentity,
            anchor: target.anchor.offsetBy(dx: 50, dy: 20))
        sampler.state = .target(moved)
        monitor.refresh()
        await monitor.waitForPendingRefresh()
        record("geometry changes publish while input identity stays constant", monitor.state == .target(moved) && received.count == 2)
        let otherInput = FocusLauncherTarget(pid: target.pid, bundle: target.bundle,
            windowIdentity: .init(fixture: 3), inputIdentity: .init(fixture: 4), anchor: moved.anchor)
        sampler.state = .target(otherInput)
        monitor.refresh()
        await monitor.waitForPendingRefresh()
        record("new window or input identity publishes despite matching geometry", received.last == .target(otherInput) && received.count == 3)
        sampler.state = .ownApplication
        monitor.refresh()
        await monitor.waitForPendingRefresh()
        record("own app focus has distinct state for panel and settings protection", monitor.state == .ownApplication)
        sampler.state = .unavailable
        monitor.refresh()
        await monitor.waitForPendingRefresh()
        record("unrelated or unreadable focus reports unavailable", monitor.state == .unavailable)

        sampler.suspend = true
        monitor.refresh()
        for _ in 0..<100 where sampler.continuation == nil { await Task.yield() }
        let pendingStarted = sampler.continuation != nil
        let count = sampler.calls
        for _ in 0..<20 { monitor.refresh() }
        record("slow metadata samples are single-flight", pendingStarted && sampler.calls == count)
        let awaitingSample = Task { await monitor.waitForPendingRefresh() }
        await Task.yield()
        monitor.stop()
        sampler.finish(.target(target))
        await awaitingSample.value
        record("stopped monitor discards late metadata without showing widget", monitor.state == .unavailable && received.last == .unavailable)
        monitor.refresh()
        await monitor.waitForPendingRefresh()
        record("stop prevents further metadata sampling", sampler.calls == count)
        sampler.suspend = false
        sampler.state = .target(target)
        monitor.setMode(.focusedInput)
        await monitor.waitForPendingRefresh()
        record("focused monitoring can restart after stop", monitor.state == .target(target) && sampler.calls == count + 1)
        monitor.setMode(.persistent)
        record("changing back to persistent stops focused monitoring", monitor.state == .unavailable)
        monitor.stop()
        return results
    }
}
