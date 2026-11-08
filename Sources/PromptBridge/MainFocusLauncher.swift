import AppKit
import AccessibilityContracts

/// The main application receives only broker-owned focus metadata. It never
/// retains AX handles or performs a native accessibility read.
struct FocusLauncherIdentity: Equatable, @unchecked Sendable {
    private enum Value: Equatable { case token(UUID), fixture(Int) }
    private let value: Value

    init(_ token: UUID) { value = .token(token) }
    init(fixture: Int) { value = .fixture(fixture) }
}

struct FocusLauncherTarget: Equatable, Sendable {
    let pid: pid_t
    let bundle: String
    let windowIdentity: FocusLauncherIdentity
    let inputIdentity: FocusLauncherIdentity
    let anchor: NSRect
}

enum FocusLauncherState: Equatable, Sendable {
    case target(FocusLauncherTarget)
    case ownApplication
    case unavailable
}

@MainActor final class MainFocusLauncher {
    private let client: BrokerClient
    private let receive: (FocusLauncherState) -> Void
    private var eventSubscription: UUID?
    private var disconnectSubscription: UUID?
    private var commandTask: Task<Void, Never>?
    private var commandTaskID: UUID?
    private var desiredMode: LauncherMode = .persistent
    private var generation = UUID()
    private var eventGeneration: UUID?
    private var commandBlocked = false
    private var restartAfterCancellation = false
    private(set) var state: FocusLauncherState = .unavailable

    init(client: BrokerClient = .shared,
         receive: @escaping @MainActor (FocusLauncherState) -> Void) {
        self.client = client
        self.receive = receive
        disconnectSubscription = client.addDisconnectSubscriber { [weak self] in
            guard let self else { return }
            self.generation = UUID()
            self.commandBlocked = true
            self.restartAfterCancellation = true
            self.commandTask?.cancel()
            self.removeEventSubscription()
            self.publish(.unavailable)
        }
    }

    func setMode(_ mode: LauncherMode) {
        desiredMode = mode
        commandBlocked = false
        generation = UUID()
        let currentGeneration = generation
        removeEventSubscription()
        if mode == .focusedInput {
            eventGeneration = currentGeneration
            eventSubscription = client.addEventSubscriber { [weak self] event in
                guard let self, self.desiredMode == .focusedInput,
                      self.eventGeneration == currentGeneration else { return }
                if let focus = event.focus { self.publish(Self.map(focus)) }
                else if event.invalidated { self.publish(.unavailable) }
            }
        } else {
            publish(.unavailable)
        }
        restartAfterCancellation = commandTask?.isCancelled == true
        ensureCommandLoop()
    }

    func stop() { setMode(.persistent) }

    func suspendForInstallation() {
        commandBlocked = true
        restartAfterCancellation = false
        generation = UUID()
        commandTask?.cancel()
        removeEventSubscription()
        publish(.unavailable)
    }

    private func removeEventSubscription() {
        guard let eventSubscription else { eventGeneration = nil; return }
        client.removeEventSubscriber(eventSubscription)
        self.eventSubscription = nil
        eventGeneration = nil
    }

    private func ensureCommandLoop() {
        guard commandTask == nil, !commandBlocked else { return }
        let taskID = UUID()
        commandTaskID = taskID
        commandTask = Task { @MainActor [weak self] in
            await self?.runCommandLoop(taskID: taskID)
        }
    }

    private func runCommandLoop(taskID: UUID) async {
        defer {
            if commandTaskID == taskID {
                commandTask = nil
                commandTaskID = nil
                if restartAfterCancellation, !commandBlocked {
                    restartAfterCancellation = false
                    ensureCommandLoop()
                }
            }
        }
        while !Task.isCancelled, !commandBlocked {
            let mode = desiredMode
            let requestGeneration = generation
            do {
                _ = try await client.request(.subscribe,
                    payload: BrokerPayload(launcherMode: mode), requestID: requestGeneration)
            } catch {
                guard !commandBlocked else { return }
                guard desiredMode != mode || generation != requestGeneration else {
                    if mode == .focusedInput { removeEventSubscription(); publish(.unavailable) }
                    return
                }
                continue
            }
            guard desiredMode == mode, generation == requestGeneration else { continue }
            return
        }
    }

    private func publish(_ newState: FocusLauncherState) {
        guard state != newState else { return }
        state = newState
        receive(newState)
    }

    private static func map(_ focus: BrokerFocusState) -> FocusLauncherState {
        switch focus {
        case .ownApplication: return .ownApplication
        case .unavailable: return .unavailable
        case .target(let target):
            let anchor = NSRect(x: target.anchor.x, y: target.anchor.y,
                                width: target.anchor.width, height: target.anchor.height)
            return .target(FocusLauncherTarget(pid: pid_t(target.pid), bundle: target.bundle,
                windowIdentity: FocusLauncherIdentity(target.windowToken),
                inputIdentity: FocusLauncherIdentity(target.inputToken), anchor: anchor))
        }
    }
}
