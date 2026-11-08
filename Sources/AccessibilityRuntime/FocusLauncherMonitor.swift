import AppKit
import ApplicationServices
import AccessibilityContracts

/// These retained identities are compared locally only. They never issue an AX read.
struct FocusLauncherIdentity: Equatable, @unchecked Sendable {
    private enum Value { case element(AXUIElement), fixture(Int) }
    private let value: Value

    init(_ element: AXUIElement) { value = .element(element) }
    init(fixture: Int) { value = .fixture(fixture) }

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (.element(a), .element(b)): CFEqual(a, b)
        case let (.fixture(a), .fixture(b)): a == b
        default: false
        }
    }
}

struct FocusLauncherTarget: Equatable, Sendable {
    let pid: pid_t
    let bundle: String
    let windowIdentity: FocusLauncherIdentity
    let inputIdentity: FocusLauncherIdentity
    /// Global AppKit coordinates; the receiving panel chooses/clamps to this screen.
    let anchor: NSRect
}

enum FocusLauncherState: Equatable, Sendable {
    case target(FocusLauncherTarget)
    case ownApplication
    case unavailable
}

enum FocusLauncherPolicy {
    static func supports(bundle: String, version: String, build: String) -> Bool {
        bundle != BrokerIdentity.bundle && bundle != BrokerIdentity.clientBundle && bundle != "com.apple.Terminal"
    }

    static func supportsInput(role: String, subrole: String? = nil, bundle: String, editable: Bool) -> Bool {
        editable && subrole != kAXSecureTextFieldSubrole && (role == kAXTextAreaRole ||
            role == kAXTextFieldRole)
    }

    static func appKitFrame(position: CGPoint, size: CGSize, primaryScreenTop: CGFloat,
                           screens: [CGRect]) -> CGRect? {
        guard position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              primaryScreenTop.isFinite, size.width > 0, size.height > 0 else { return nil }
        let result = CGRect(x: position.x, y: primaryScreenTop - position.y - size.height,
                            width: size.width, height: size.height)
        guard result.minX.isFinite, result.maxX.isFinite, result.minY.isFinite, result.maxY.isFinite,
              screens.contains(where: { !$0.intersection(result).isEmpty }) else { return nil }
        return result
    }
}

@MainActor protocol FocusLauncherSampling: AnyObject {
    func sample() async -> FocusLauncherState
}

/// Only identifies whether a supported editable input is focused. It never captures
/// draft text, selection, document/context metadata, children, or history.
@MainActor final class SystemFocusLauncherSampler: FocusLauncherSampling {
    private let client: BrokerApplicationIdentity

    init(client: BrokerApplicationIdentity) {
        self.client = client
    }

    private struct Application: Equatable, Sendable {
        let pid: pid_t
        let bundle: String
        let path: String
        let version: String
        let build: String
    }

    private let reader = MetadataReader()

    func sample() async -> FocusLauncherState {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return .unavailable }
        if Self.isVerifiedClient(frontmost, client: client) { return .ownApplication }
        guard AXIsProcessTrusted(), let application = Self.describe(frontmost),
              FocusLauncherPolicy.supports(bundle: application.bundle, version: application.version,
                                           build: application.build),
              let primaryScreen = NSScreen.screens.first else { return .unavailable }
        let state = await reader.sample(application, primaryScreenTop: primaryScreen.frame.maxY,
                                        screens: NSScreen.screens.map(\.frame))
        guard !Task.isCancelled, AXIsProcessTrusted(),
              let current = NSWorkspace.shared.frontmostApplication else { return .unavailable }
        if Self.isVerifiedClient(current, client: client) { return .ownApplication }
        guard Self.describe(current) == application else { return .unavailable }
        return state
    }

    private static func describe(_ app: NSRunningApplication) -> Application? {
        guard !app.isTerminated, let id = app.bundleIdentifier,
              let url = app.bundleURL else { return nil }
        let bundle = Bundle(url: url)
        return Application(pid: app.processIdentifier, bundle: id, path: url.path,
                           version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                           build: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
    }

    private static func isVerifiedClient(_ app: NSRunningApplication,
                                         client: BrokerApplicationIdentity) -> Bool {
        guard let described = describe(app) else { return false }
        return described.pid == pid_t(client.pid) && described.bundle == client.bundle
            && described.path == client.path && described.version == client.version
            && described.build == client.build
    }

    /// AX calls can wait for another process. Keep them off the UI actor and impose
    /// both a per-message timeout and a whole-sample deadline. No retries in a sample.
    private actor MetadataReader {
        func sample(_ app: Application, primaryScreenTop: CGFloat, screens: [CGRect]) -> FocusLauncherState {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(180))
            func withinBudget() -> Bool { !Task.isCancelled && ContinuousClock.now < deadline }
            func read(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
                guard withinBudget(), AXUIElementSetMessagingTimeout(element, 0.025) == .success else { return nil }
                var result: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, name, &result) == .success else { return nil }
                return result
            }
            func element(_ root: AXUIElement, _ name: CFString) -> AXUIElement? {
                guard let value = read(root, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return unsafeDowncast(value, to: AXUIElement.self)
            }
            func owned(_ element: AXUIElement) -> Bool {
                guard withinBudget() else { return false }
                var pid: pid_t = 0
                return AXUIElementGetPid(element, &pid) == .success && pid == app.pid
            }
            func subrole(_ input: AXUIElement) -> (readable: Bool, value: String?) {
                guard withinBudget(), AXUIElementSetMessagingTimeout(input, 0.025) == .success else { return (false, nil) }
                var value: CFTypeRef?
                let result = AXUIElementCopyAttributeValue(input, kAXSubroleAttribute as CFString, &value)
                // An optional attribute being unsupported is distinct from a failed read.
                if result == .attributeUnsupported || result == .noValue { return (true, nil) }
                guard result == .success, let value = value as? String else { return (false, nil) }
                return (true, value)
            }

            let application = AXUIElementCreateApplication(app.pid)
            guard let window = element(application, kAXFocusedWindowAttribute as CFString), owned(window),
                  let input = element(application, kAXFocusedUIElementAttribute as CFString), owned(input),
                  let windowRole = read(window, kAXRoleAttribute as CFString) as? String,
                  windowRole == kAXWindowRole,
                  let role = read(input, kAXRoleAttribute as CFString) as? String,
                  withinBudget() else { return .unavailable }
            var writableValue = DarwinBoolean(false)
            var writableSelection = DarwinBoolean(false)
            _ = AXUIElementIsAttributeSettable(input, kAXValueAttribute as CFString, &writableValue)
            _ = AXUIElementIsAttributeSettable(input, kAXSelectedTextAttribute as CFString, &writableSelection)
            let editable = (read(input, "AXEditable" as CFString) as? Bool)
                ?? (writableValue.boolValue || writableSelection.boolValue)
            let inputSubrole = subrole(input)
            guard inputSubrole.readable,
                  FocusLauncherPolicy.supportsInput(role: role, subrole: inputSubrole.value,
                      bundle: app.bundle, editable: editable),
                  let positionValue = read(input, kAXPositionAttribute as CFString),
                  let sizeValue = read(input, kAXSizeAttribute as CFString),
                  CFGetTypeID(positionValue) == AXValueGetTypeID(),
                  CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return .unavailable }
            let axPosition = unsafeDowncast(positionValue, to: AXValue.self)
            let axSize = unsafeDowncast(sizeValue, to: AXValue.self)
            var position = CGPoint.zero
            var size = CGSize.zero
            guard AXValueGetType(axPosition) == .cgPoint, AXValueGetValue(axPosition, .cgPoint, &position),
                  AXValueGetType(axSize) == .cgSize, AXValueGetValue(axSize, .cgSize, &size),
                  let frame = FocusLauncherPolicy.appKitFrame(position: position, size: size,
                      primaryScreenTop: primaryScreenTop, screens: screens),
                  let finalWindow = element(application, kAXFocusedWindowAttribute as CFString),
                  let finalInput = element(application, kAXFocusedUIElementAttribute as CFString),
                  CFEqual(window, finalWindow), CFEqual(input, finalInput), withinBudget() else { return .unavailable }
            return .target(FocusLauncherTarget(pid: app.pid, bundle: app.bundle,
                windowIdentity: FocusLauncherIdentity(window), inputIdentity: FocusLauncherIdentity(input), anchor: frame))
        }
    }
}

/// The panel owns visibility policy (manual hiding, expanded/busy/settings state).
/// This monitor publishes metadata only and cannot show, activate, or write anything.
@MainActor final class FocusLauncherMonitor {
    private let sampler: any FocusLauncherSampling
    private let receive: @MainActor (FocusLauncherState) -> Void
    private let automaticScheduling: Bool
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var samplingTask: Task<Void, Never>?
    private var generation = UUID()
    private var active = false
    private var paused = false
    private(set) var state: FocusLauncherState = .unavailable

    convenience init(client: BrokerApplicationIdentity,
                     automaticScheduling: Bool = true,
                     receive: @escaping @MainActor (FocusLauncherState) -> Void) {
        self.init(sampler: SystemFocusLauncherSampler(client: client),
                  automaticScheduling: automaticScheduling, receive: receive)
    }

    init(sampler: any FocusLauncherSampling,
         automaticScheduling: Bool = true,
         receive: @escaping @MainActor (FocusLauncherState) -> Void) {
        self.sampler = sampler
        self.automaticScheduling = automaticScheduling
        self.receive = receive
    }

    func setMode(_ mode: LauncherMode) {
        guard mode == .focusedInput else { stop(); return }
        guard !active else { return }
        active = true
        generation = UUID()
        if automaticScheduling {
            let workspace = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didActivateApplicationNotification,
                         NSWorkspace.didTerminateApplicationNotification,
                         NSWorkspace.activeSpaceDidChangeNotification] {
                observe(workspace, name) { $0.refresh() }
            }
            observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.refresh() }
            observe(.default, NSApplication.willTerminateNotification) { $0.stop() }
            let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            timer.tolerance = 0.06
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        refresh()
    }

    func setPollingPaused(_ paused: Bool) {
        self.paused = paused
        if paused { samplingTask?.cancel(); samplingTask = nil }
        else if active { refresh() }
    }

    func stop() {
        active = false
        generation = UUID()
        samplingTask?.cancel()
        samplingTask = nil
        timer?.invalidate()
        timer = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        publish(.unavailable)
    }

    func refresh() {
        guard active, !paused, samplingTask == nil else { return }
        let currentGeneration = generation
        samplingTask = Task { [weak self] in
            guard let self else { return }
            let sampled = await sampler.sample()
            guard active, generation == currentGeneration, !Task.isCancelled else { return }
            samplingTask = nil
            publish(sampled)
        }
    }

    /// Allows deterministic fixture checks without timers, workspace events, or AX.
    func waitForPendingRefresh() async { await samplingTask?.value }

    private func publish(_ newState: FocusLauncherState) {
        guard state != newState else { return }
        state = newState
        receive(newState)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         action: @escaping @MainActor (FocusLauncherMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }
}
