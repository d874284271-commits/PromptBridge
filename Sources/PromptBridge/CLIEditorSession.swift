import AppKit
import AccessibilityContracts
import DraftCore

@MainActor final class CLIEditorSession: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var finishing = false
    @Published private(set) var needsConsent = false
    @Published private(set) var awaitingDraft = false
    @Published private(set) var message: String?
    @Published private(set) var readIntent: CLIReadIntent?
    @Published private(set) var outcome: CLIEditorOutcome?
    @Published private(set) var outcomeIsUnknown = false
    private(set) var outcomeDocumentID: UUID?
    private var request: CLIEditorPreflight?
    private var requestURL: URL?
    private var permission: CLIEditorReadPermission?
    private var monitor: Task<Void, Never>?
    private var finishDeadline: ContinuousClock.Instant?
    private var leaseDeadline = ContinuousClock.now
    private var leaseSequence: UInt64 = 0
    private var acceptedResponseSent = false
    private var draftLoaded = false
    private var draftLoading = false
    private let workflow: DraftWorkflow
    private let host: HostRouter
    private let verifyIdentity: (CLIEditorPreflight) -> Bool
    var onDraftReady: (() -> Void)?
    var onFinished: ((CLITerminalSession, CLIEditorCompletion) -> Void)?
    var requestID: UUID? { request?.id }

    init(workflow: DraftWorkflow, host: HostRouter,
         verifyIdentity: @escaping (CLIEditorPreflight) -> Bool = CLIEditorSession.validateIdentity) {
        self.workflow = workflow; self.host = host; self.verifyIdentity = verifyIdentity
    }
    nonisolated static func validateIdentity(_ request: CLIEditorPreflight) -> Bool {
        guard request.registration.session.isCurrent,
              let helper = CLIProcessSnapshot.inspect(pid: request.helperPID),
              helper.startTimeMicros == request.helperStartTimeMicros,
              helper.parentPID == request.registration.session.pid,
              helper.tty == request.registration.session.tty,
              helper.processGroup == request.registration.session.processGroup,
              let stored = try? CLISessionStore().load(request.registration.session.id), stored == request.registration else { return false }
        return true
    }
    var deliveryText: String {
        guard let request else { return workflow.output }
        return CLIHostAdapter.deliveryText(workflow.output, for: request.registration.session.kind)
    }
    var outputIsNormalized: Bool { deliveryText == workflow.output }
    var canSave: Bool {
        active && draftLoaded && !finishing && workflow.canSaveCLI && !deliveryText.isEmpty
            && !CLIHostAdapter.hasUnverifiedObjects(workflow.source) && !CLIHostAdapter.hasUnverifiedObjects(deliveryText)
    }
    @discardableResult func beginRead(sessionID: UUID, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !active, readIntent == nil, workflow.canSwitchDraft, workflow.phase != .translating else { return false }
        outcome = nil
        outcomeIsUnknown = false; outcomeDocumentID = nil
        readIntent = CLIReadIntent(sessionID: sessionID, now: now)
        message = "正在等待 CLI 提供草稿…"
        return true
    }
    func failRead(_ reason: String) { readIntent = nil; outcome = nil; message = reason }
    func expireRead(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if let readIntent, now > readIntent.deadline { failRead("快捷键已触发，但未收到 CLI 草稿。请确认光标位于输入框，或手动打开外部编辑器。") }
    }
    func receive(_ url: URL, busy: Bool) async -> Bool {
        do {
            let incoming = try CLIEditorExchange.readPreflight(url)
            guard request?.id != incoming.id,
                  !FileManager.default.fileExists(atPath: CLIEditorExchange.file("response.json", for: url).path) else { return false }
            guard !active, !busy, workflow.phase != .translating, workflow.canSwitchDraft, verifyIdentity(incoming) else {
                try CLIEditorExchange.write(CLIEditorResponse(id: incoming.id, disposition: .rejected,
                    message: "CLI 来源失效或 PromptBridge 正忙；未读取正文。"), to: CLIEditorExchange.file("response.json", for: url))
                return false
            }
            let now = ProcessInfo.processInfo.systemUptime
            expireRead(now: now)
            if let intent = readIntent, !intent.accepts(incoming, now: now) {
                try CLIEditorExchange.write(CLIEditorResponse(id: incoming.id, disposition: .rejected,
                    message: "编辑请求不属于当前读取目标；未读取正文。"), to: CLIEditorExchange.file("response.json", for: url))
                return false
            }
            active = true; request = incoming; requestURL = url; outcome = nil
            acceptedResponseSent = false
            outcomeIsUnknown = false; outcomeDocumentID = nil
            awaitingDraft = true; draftLoaded = false; draftLoading = false; leaseSequence = 0
            try refreshLease()
            if let intent = readIntent {
                readIntent = nil
                try authorize(intentID: intent.id)
            } else {
                needsConsent = true
                message = "\(incoming.registration.session.kind.rawValue) 请求编辑草稿。点击“读取草稿”后才会读取内容。"
            }
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled, let self, self.request?.id == incoming.id else { return }
                    if self.poll() { return }
                    await self.receiveDraft()
                }
            }
            return true
        } catch {
            if requestURL == url { CLIEditorExchange.cleanup(url); end("CLI 交接失败：\(error.localizedDescription)") }
            return false
        }
    }
    func acceptPending() {
        guard needsConsent, let request, verifyIdentity(request) else { return }
        do { try authorize(intentID: UUID()) }
        catch { cancel() }
    }
    private func authorize(intentID: UUID) throws {
        guard let request, let requestURL else { throw CLIEditorFailure.invalidRequest }
        let permission = CLIEditorReadPermission(id: request.id, intentID: intentID)
        try CLIEditorExchange.write(permission, to: CLIEditorExchange.file("permission.json", for: requestURL))
        self.permission = permission; needsConsent = false
        message = "正在读取 CLI 草稿…"
    }
    func receiveDraft() async {
        guard !draftLoaded, !draftLoading, !finishing, let request, let requestURL, let permission,
              FileManager.default.fileExists(atPath: CLIEditorExchange.file("draft.json", for: requestURL).path) else { return }
        draftLoading = true
        defer { draftLoading = false }
        do {
            let draft = try CLIEditorExchange.read(CLIEditorDraft.self, from: CLIEditorExchange.file("draft.json", for: requestURL))
            guard draft.id == request.id, draft.intentID == permission.intentID, verifyIdentity(request) else { throw CLIEditorFailure.invalidRequest }
            guard !draft.source.isEmpty else { cancel(); message = "CLI 输入为空，保留浮窗中的原有草稿。"; return }
            guard await workflow.prepareForEntrySwitch(), self.request?.id == request.id, !finishing else { return }
            host.useCLI(draft.source, id: draft.id)
            await workflow.captureSelection()
            guard self.request?.id == request.id, !finishing else { return }
            draftLoaded = true; awaitingDraft = false
            message = CLIHostAdapter.hasUnverifiedObjects(draft.source)
                ? "草稿包含暂不支持直接替换的对象标记。可复制译文后手动粘贴。"
                : "CLI 草稿已读取。生成译文后，点击“替换并返回”；不会自动发送。"
            onDraftReady?()
        } catch { cancel(); message = "CLI 编辑请求已失效，请重新读取草稿。" }
    }
    private func endUnknown(_ message: String) {
        guard acceptedResponseSent else {
            outcomeIsUnknown = false; outcomeDocumentID = nil
            end("CLI 交接已结束，未提交替换。已有草稿已保留。")
            return
        }
        outcomeIsUnknown = true
        outcomeDocumentID = workflow.sourceDocumentID
        end(message)
    }
    func save() {
        guard canSave else { return }
        let text = deliveryText
        if text != workflow.output { workflow.editOutput(text) }
        respond(.accepted, text: text)
    }
    func cancel() {
        if readIntent != nil { failRead("已取消读取，之后收到的草稿不会导入。") }
        guard active, !finishing else { return }
        if draftLoaded { workflow.cancel() }
        respond(.cancelled)
    }
    private func respond(_ disposition: CLIEditorResponse.Disposition, text: String? = nil) {
        guard let request, let requestURL else { return }
        do {
            try CLIEditorExchange.write(CLIEditorResponse(id: request.id, disposition: disposition, text: text),
                to: CLIEditorExchange.file("response.json", for: requestURL))
            acceptedResponseSent = disposition == .accepted
            finishing = true; needsConsent = false
            finishDeadline = ContinuousClock.now.advanced(by: .seconds(15))
            message = disposition == .accepted ? "正在保存并返回 CLI…" : "正在取消 CLI 编辑…"
        } catch { CLIEditorExchange.cleanup(requestURL); end("CLI 交接失败；结果仍可复制。") }
    }
    @discardableResult func poll(now: ContinuousClock.Instant = .now) -> Bool {
        guard let request, let requestURL else { return true }
        let completionURL = CLIEditorExchange.file("completion.json", for: requestURL)
        if FileManager.default.fileExists(atPath: completionURL.path) {
            do {
                let completion = try CLIEditorExchange.read(CLIEditorCompletion.self, from: completionURL)
                guard (finishing || completion.status == .failed), completion.id == request.id else { throw CLIEditorFailure.invalidRequest }
                outcome = CLIEditorOutcome(completion)
                try CLIEditorExchange.write(request.id, to: CLIEditorExchange.file("finished", for: requestURL))
                end(completion.message)
                onFinished?(request.registration.session, completion)
            } catch { endUnknown("无法确认草稿是否已保存。请检查 CLI；译文仍可复制。") }
            return true
        }
        if !verifyIdentity(request) || !FileManager.default.fileExists(atPath: requestURL.path) {
            CLIEditorExchange.cleanup(requestURL); endUnknown("CLI 连接已失效，无法确认草稿是否已保存。译文仍可复制。")
            return true
        }
        if let finishDeadline, now >= finishDeadline {
            do {
                let aborted = try CLIEditorExchange.withCommitLock(for: requestURL, nonBlocking: true) {
                    if FileManager.default.fileExists(atPath: completionURL.path) { return false }
                    try CLIEditorExchange.write(request.id, to: CLIEditorExchange.file("aborted", for: requestURL))
                    return true
                }
                if aborted == true { endUnknown("保存确认超时，结果尚不确定。请检查 CLI；不会自动重试。"); return true }
                if aborted == false { return poll() }
                self.finishDeadline = nil; message = "正在写入 CLI 草稿，请等待保存结果；此时无法取消。"
            } catch { self.finishDeadline = nil; message = "无法确认保存状态，请检查 CLI。" }
        }
        if now >= leaseDeadline {
            do { try refreshLease() }
            catch { if !finishing { CLIEditorExchange.cleanup(requestURL); end("CLI 交接中断，已解除关联。"); return true } }
        }
        return false
    }
    private func end(_ text: String) {
        if draftLoaded && workflow.phase == .translating { workflow.cancel() }
        monitor?.cancel(); monitor = nil; request = nil; requestURL = nil; permission = nil
        active = false; finishing = false; needsConsent = false; awaitingDraft = false
        finishDeadline = nil; message = text
    }
    func reportReturn(_ text: String, requestID: UUID, focus: CLIEditorOutcome.Focus) {
        guard !active, outcome?.id == requestID else { return }
        outcome?.focus = focus
        message = text
    }
    func clearMessage() { if !active { outcome = nil; message = nil } }
    private func refreshLease() throws {
        guard let request, let requestURL else { throw CLIEditorFailure.invalidRequest }
        leaseSequence &+= 1
        try CLIEditorExchange.write(CLIEditorLease(id: request.id, sequence: leaseSequence),
            to: CLIEditorExchange.file("received", for: requestURL))
        leaseDeadline = .now.advanced(by: .seconds(3))
    }
}
