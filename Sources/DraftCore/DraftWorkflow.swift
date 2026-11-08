import Combine
import Foundation

@MainActor public protocol DraftTranslator {
    var progressMessage: String { get }
    var preferences: TranslationPreferences { get }
    var configurationIdentity: String { get }
    func generate(_ request: GenerationRequest) async throws -> String
}

public extension DraftTranslator {
    var progressMessage: String { "正在生成译文…" }
    var preferences: TranslationPreferences { .init() }
    var configurationIdentity: String { "demo" }
}

public struct GenerationRecord: Equatable, Sendable {
    public let source: String
    public let sourceRevision: UInt64
    public let intent: DraftIntent
    public let targetLanguage: String
    public let templateRevision: String
    public let configurationIdentity: String
}

public enum ReplacementStatus: Equatable, Sendable {
    case pending, confirmed, cancelled, blocked, unknown
}

/// The captured original and exact submitted result never change with later editor changes.
public struct ReplacementRecord: Equatable, Sendable {
    public let originalText: String
    public let writtenText: String
    public let captureID: UUID?
    public let status: ReplacementStatus
    public var failure: FillError? = nil
    public var documentID: UUID? = nil
}

public enum DraftEntry: Hashable, Sendable {
    case manual, claude, codex, demo, cli
    case external(bundleIdentifier: String)
}

public enum ResultValidity: Equatable, Sendable {
    case none, current, stale(String)
}

@MainActor public final class DraftWorkflow: ObservableObject {
    public enum Phase: Equatable { case idle, translating, ready, filling, filled, blocked, failed }

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var source = ""
    @Published public private(set) var output = ""
    @Published public private(set) var message = "选择文字或直接输入原文。"
    @Published public private(set) var targetLabel = "未关联输入框"
    @Published public private(set) var sourceIsComposing = false
    @Published public private(set) var outputIsComposing = false
    @Published public private(set) var intent: DraftIntent = .translate
    @Published public private(set) var entry: DraftEntry?
    @Published public private(set) var resultValidity: ResultValidity = .none
    @Published public private(set) var hasOutputEditor = false
    @Published public private(set) var sourceDocumentID = UUID()
    @Published public private(set) var outputDocumentID = UUID()
    @Published public private(set) var canRestore = false
    @Published public private(set) var fillStage: ReplacementStage?
    @Published public private(set) var targetLanguage = "English"
    @Published public private(set) var sourceRevision: UInt64 = 0
    @Published public private(set) var generationRecord: GenerationRecord?
    @Published public private(set) var replacementRecord: ReplacementRecord?

    private struct DraftRecord {
        var source: String
        var output: String
        var intent: DraftIntent
        var targetLanguage: String
        var sourceRevision: UInt64
        var generation: GenerationRecord?
        var validity: ResultValidity
        var hasOutputEditor: Bool
        static func empty(targetLanguage: String) -> DraftRecord {
            DraftRecord(source: "", output: "", intent: .translate, targetLanguage: targetLanguage,
                sourceRevision: 0, generation: nil, validity: .none, hasOutputEditor: false)
        }
    }
    private struct DraftSlot {
        var current: DraftRecord
        var previous: DraftRecord?
    }
    private var drafts: [DraftEntry: DraftSlot] = [:]
    private var externalNames: [DraftEntry: String] = [:]
    public var externalDraftEntries: [(entry: DraftEntry, name: String)] {
        externalNames.map { (entry: $0.key, name: $0.value) }.sorted { $0.name < $1.name }
    }
    private var replacements: [DraftEntry: ReplacementRecord] = [:]
    private let host: any HostInput
    private let translator: any DraftTranslator
    private var captured: InputSnapshot?
    private var requestID: UUID?
    private var captureRequestID: UUID?
    private var liveValidationID = UUID()
    private var entryRequestID = UUID()
    private var routeID = UUID()
    private var pending: Task<Void, Never>?
    private var pendingFill: Task<Void, Never>?
    private var replacementID: UUID?
    private var replacementSnapshot: InputSnapshot?
    private var replacementText: String?
    private var fillCancellationMessage: String?
    private var replacementEntry: DraftEntry?
    private var observedPreferences: TranslationPreferences

    public init(host: any HostInput, translator: any DraftTranslator) {
        self.host = host
        self.translator = translator
        observedPreferences = translator.preferences
        targetLanguage = translator.preferences.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var canSwitchDraft: Bool {
        phase != .filling && !sourceIsComposing && !outputIsComposing
    }
    public var canGenerate: Bool {
        captured != nil && phase != .translating && phase != .filling && phase != .blocked && phase != .filled
            && canSwitchDraft && !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var canFill: Bool {
        phase == .ready && resultValidity == .current && supportsDirectFill(captured)
            && generationRecord.map(generationStillMatches) == true
            && canSwitchDraft && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var canCopy: Bool {
        phase != .translating && phase != .filling && canSwitchDraft
            && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public var canSaveCLI: Bool {
        entry == .cli && phase == .ready && resultValidity == .current
            && generationRecord.map(generationStillMatches) == true && canCopy
    }
    public var canEditOutput: Bool {
        hasOutputEditor && phase != .translating && phase != .filling && phase != .filled
    }
    public var staleReason: String? {
        if case .stale(let reason) = resultValidity { return reason }
        return nil
    }
    public var isManualInput: Bool { entry == .manual }
    public var isFullInputCapture: Bool { captured?.captureScope == .entireInput }
    public var isExternalSelection: Bool {
        if case .external = entry { return true }
        return entry == .claude || entry == .codex
    }
    public var isCopyOnlyTarget: Bool { !supportsDirectFill(captured) }
    public var externalHostName: String {
        if let entry, let name = externalNames[entry] { return name }
        return entry == .claude ? "Claude" : (entry == .codex ? "ChatGPT / Codex" : "原应用")
    }
    public var canReturnWithCopy: Bool { isExternalSelection && resultValidity == .current && phase == .ready }
    public func hasSavedDraft(_ value: DraftEntry) -> Bool {
        let saved = value == entry ? record : drafts[value]?.current
        return saved.map { !$0.source.isEmpty || $0.hasOutputEditor } ?? false
    }

    private func supportsDirectFill(_ snapshot: InputSnapshot?) -> Bool {
        snapshot?.supportsDirectFill == true && snapshot?.containsProtectedContent == false
    }

    @discardableResult public func allowDraftSwitch() -> Bool {
        guard canSwitchDraft else {
            message = "请先确认或取消浮窗中的输入法候选。"
            return false
        }
        if entry == .demo && host.snapshot()?.isComposing == true {
            message = "请先确认或取消测试宿主中的输入法候选。"
            return false
        }
        return true
    }

    @discardableResult public func prepareForEntrySwitch() async -> Bool {
        guard allowDraftSwitch() else { return false }
        if phase == .translating {
            markStale("入口已切换，旧稿已保留。")
            phase = .idle
        }
        routeID = UUID()
        invalidateRequest()
        saveActive()
        captured = nil
        return true
    }

    public func captureDidFail(_ reason: String) {
        block(reason)
    }

    private var record: DraftRecord {
        DraftRecord(source: source, output: output, intent: intent, targetLanguage: targetLanguage,
            sourceRevision: sourceRevision, generation: generationRecord,
            validity: resultValidity, hasOutputEditor: hasOutputEditor)
    }
    private var emptySlot: DraftSlot {
        DraftSlot(current: .empty(targetLanguage: translator.preferences.targetLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)))
    }
    private func saveActive() {
        guard let entry else { return }
        var slot = drafts[entry] ?? emptySlot
        slot.current = record
        drafts[entry] = slot
    }
    private func rememberReplacement() {
        guard let entry, !source.isEmpty || hasOutputEditor else { return }
        var slot = drafts[entry] ?? emptySlot
        slot.previous = record
        drafts[entry] = slot
        canRestore = true
    }
    private func load(_ value: DraftRecord) {
        source = value.source
        output = value.output
        intent = value.intent
        targetLanguage = value.targetLanguage
        sourceRevision = value.sourceRevision
        generationRecord = value.generation
        resultValidity = value.validity
        hasOutputEditor = value.hasOutputEditor
        sourceIsComposing = false
        outputIsComposing = false
        sourceDocumentID = UUID()
        outputDocumentID = UUID()
    }
    private func switchEntry(_ value: DraftEntry) {
        guard entry != value else { return }
        routeID = UUID()
        invalidateRequest()
        saveActive()
        entry = value
        captured = nil
        let slot = drafts[value] ?? emptySlot
        load(slot.current)
        canRestore = slot.previous != nil
        replacementRecord = replacements[value]
    }
    private func markStale(_ reason: String) {
        if hasOutputEditor { resultValidity = .stale(reason) }
    }
    private func entryFor(_ snapshot: InputSnapshot) -> DraftEntry {
        if let bundle = snapshot.identity.bundleIdentifier {
            if bundle == "com.anthropic.claudefordesktop" { return .claude }
            if bundle == "com.openai.codex" { return .codex }
            let entry = DraftEntry.external(bundleIdentifier: bundle.isEmpty ? snapshot.identity.window : bundle)
            externalNames[entry] = snapshot.identity.host
            return entry
        }
        switch snapshot.identity.host {
        case "手动输入": return .manual
        case "CLI": return .cli
        case "Claude": return .claude
        case "ChatGPT / Codex": return .codex
        default: return .demo
        }
    }

    public func restorePreviousDraft() async {
        guard allowDraftSwitch(), let entry, let previous = drafts[entry]?.previous else { return }
        let operationID = UUID()
        entryRequestID = operationID
        let expectedRoute = routeID
        let expectedSourceRevision = sourceRevision
        let restoredManualSnapshot: InputSnapshot?
        if entry == .manual || entry == .cli {
            restoredManualSnapshot = await host.liveSnapshot()
            guard entryRequestID == operationID, self.entry == entry,
                  routeID == expectedRoute, sourceRevision == expectedSourceRevision,
                  !Task.isCancelled else { return }
        } else {
            restoredManualSnapshot = nil
        }
        guard entryRequestID == operationID, self.entry == entry,
              routeID == expectedRoute, sourceRevision == expectedSourceRevision,
              !Task.isCancelled else { return }
        invalidateRequest()
        guard var slot = drafts[entry] else { return }
        slot.previous = record
        load(previous)
        markStale("已恢复上一稿，请重新生成。")
        slot.current = record
        drafts[entry] = slot
        canRestore = true
        if isManualInput || entry == .cli {
            captured = restoredManualSnapshot.flatMap { entryFor($0) == entry ? $0 : nil }
            phase = captured == nil ? .blocked : .idle
        } else {
            captured = nil
            phase = .blocked
            targetLabel = "\(isExternalSelection ? externalHostName : "测试宿主") · 旧稿未关联"
        }
        message = isManualInput || entry == .cli ? "上一稿已恢复。" : "上一稿已恢复；请重新读取输入框，或继续直接输入。"
    }

    public func continueAsManualInput() async {
        guard allowDraftSwitch(), let currentEntry = entry else { return }
        let operationID = UUID()
        entryRequestID = operationID
        let expectedRoute = routeID
        let expectedSourceRevision = sourceRevision
        guard let snapshot = await host.liveSnapshot(), snapshot.identity.host == "手动输入",
              entryRequestID == operationID, entry == currentEntry,
              routeID == expectedRoute, sourceRevision == expectedSourceRevision,
              !Task.isCancelled else { return }
        let incoming = record
        invalidateRequest()
        switchEntry(.manual)
        rememberReplacement()
        load(incoming)
        markStale("已转入直接输入，请重新生成。")
        captured = snapshot
        targetLabel = "直接输入"
        phase = .idle
        message = "当前稿已转入直接输入，原直接输入稿可恢复。"
    }

    public func prepareExternalRecapture() async {
        guard allowDraftSwitch(), isExternalSelection else { return }
        let fullInput = isFullInputCapture
        routeID = UUID()
        invalidateRequest()
        captured = nil
        phase = .blocked
        markStale("原输入框已断开关联，请重新读取输入框。")
        message = fullInput
            ? "请点击 \(externalHostName) 输入框，再点击浮窗读取全文。原稿已保留。"
            : "请在 \(externalHostName) 输入框重新选择文字，再从菜单读取选中文字。原稿已保留。"
    }
    public func prepareForOpening() async {
        // Reopening must not silently recapture and overwrite a preserved, unassociated draft.
        if entry == nil { await captureSelection() }
    }
    public func useManualInput() async {
        guard allowDraftSwitch() else { return }
        let operationID = UUID()
        entryRequestID = operationID
        let expectedRoute = routeID
        let expectedSourceRevision = sourceRevision
        guard let snapshot = await host.liveSnapshot(), snapshot.identity.host == "手动输入",
              entryRequestID == operationID, routeID == expectedRoute,
              sourceRevision == expectedSourceRevision, !Task.isCancelled else { return }
        // Reopening a valid manual draft must preserve its generation and result state.
        if entry == .manual && captured == snapshot { return }
        switchEntry(.manual)
        invalidateRequest()
        captured = snapshot
        targetLabel = "直接输入"
        phase = resultValidity == .current ? .ready : .idle
        message = "输入原文并生成译文，再复制到需要使用的应用。"
    }
    public func openSavedEntry(_ value: DraftEntry) async {
        guard allowDraftSwitch(), value != .manual else { return }
        routeID = UUID()
        switchEntry(value)
        invalidateRequest()
        captured = nil
        markStale("旧稿未关联当前选区，请重新读取。")
        phase = .blocked
        targetLabel = "\(isExternalSelection ? externalHostName : "测试宿主") · 旧稿未关联"
        message = "已恢复此入口草稿；请重新读取输入框，或继续直接输入。"
    }
    public func useCLIInput() async {
        guard allowDraftSwitch(), let snapshot = await host.liveSnapshot(), snapshot.identity.host == "CLI" else { return }
        switchEntry(.cli)
        invalidateRequest()
        captured = snapshot
        targetLabel = "CLI · 独立草稿，不关联终端"
        phase = resultValidity == .current ? .ready : .idle
        message = "复制译文后，请粘贴回原 CLI 会话。发送前可再次检查。"
    }
    public func setIntent(_ value: DraftIntent) {
        guard value != intent, allowDraftSwitch() else { return }
        invalidateRequest()
        intent = value
        markStale("处理方式已变化，请重新生成。")
        if captured != nil && phase != .blocked && phase != .filled { phase = .idle }
        message = "处理方式已变化。原稿已保留。"
    }
    public func setTargetLanguage(_ value: String) {
        let language = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phase != .filling, !language.isEmpty, language != targetLanguage,
              allowDraftSwitch() else { return }
        invalidateRequest()
        targetLanguage = language
        markStale("目标语言已变化，请重新生成。")
        if captured != nil && phase != .blocked && phase != .filled { phase = .idle }
        message = "目标语言已变化。原稿已保留。"
    }
    public func captureSelection() async {
        guard allowDraftSwitch() else { return }
        invalidateRequest()
        let operationID = UUID()
        captureRequestID = operationID
        let expectedRoute = routeID
        let expectedSourceRevision = sourceRevision
        guard let snapshot = await host.liveSnapshot() else {
            guard captureRequestID == operationID, routeID == expectedRoute,
                  sourceRevision == expectedSourceRevision, !Task.isCancelled else { return }
            block("未找到可编辑的输入框。")
            return
        }
        guard captureRequestID == operationID, routeID == expectedRoute,
              sourceRevision == expectedSourceRevision, !Task.isCancelled else { return }
        guard !snapshot.isComposing else { block("请先在原输入框中确认或取消输入法候选。"); return }
        guard !snapshot.containsProtectedContent || snapshot.captureScope == .entireInput else {
            block("选区包含附件或引用，请只选择需要翻译的文字。")
            return
        }
        let capturedSource: String
        switch snapshot.captureScope {
        case .selection:
            capturedSource = snapshot.selectedText
        case .entireInput:
            guard let fullText = snapshot.fullText else {
                block("无法读取完整输入框内容，请重新读取。")
                return
            }
            capturedSource = fullText
        }
        switchEntry(entryFor(snapshot))
        invalidateRequest()
        rememberReplacement()
        captured = snapshot
        source = capturedSource
        sourceRevision &+= 1
        targetLanguage = translator.preferences.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        generationRecord = nil
        output = ""
        hasOutputEditor = false
        resultValidity = .none
        sourceDocumentID = UUID()
        outputDocumentID = UUID()
        sourceIsComposing = false
        outputIsComposing = false
        targetLabel = snapshot.captureScope == .entireInput
            ? (snapshot.identity.host == "local-fixture"
                ? "测试会话 \(snapshot.identity.session) · 当前输入框"
                : "\(snapshot.identity.host) · 当前输入框")
            : (snapshot.identity.host == "local-fixture"
                ? "测试会话 \(snapshot.identity.session) · \(snapshot.selection.length == 0 ? "光标位置" : "已选文字")"
                : "\(snapshot.identity.host) · 当前选区")
        phase = .idle
        message = supportsDirectFill(snapshot)
            ? (snapshot.captureScope == .entireInput
                ? "已读取输入框全文。生成译文后可替换原文，不发送消息。"
                : "已读取选中的文字。生成译文后可写入输入框，不发送消息。")
            : (snapshot.captureScope == .entireInput
                ? "已读取输入框全文。生成译文后可复制粘贴，不自动替换或发送。"
                : "已读取选中的文字。生成译文后可复制粘贴，不自动替换或发送。")
    }
    public func editSource(_ value: String, isComposing: Bool = false) {
        guard phase != .filling else { return }
        guard source != value || sourceIsComposing != isComposing else { return }
        invalidateRequest()
        if source != value { sourceRevision &+= 1 }
        source = value
        sourceIsComposing = isComposing
        markStale("原文已修改，请重新生成。")
        if captured != nil && phase != .blocked && phase != .filled { phase = .idle }
        message = isComposing ? "请先确认输入法候选。" : "草稿已更新。旧译文已保留。"
    }
    public func editOutput(_ value: String, isComposing: Bool = false) {
        guard phase != .filling else { return }
        outputIsComposing = isComposing
        guard canEditOutput else { return }
        output = value
    }
    public func generate() {
        guard canGenerate, let expectedSnapshot = captured else { return }
        invalidateRequest()
        let id = UUID()
        let expectedRoute = routeID
        let expectedSourceRevision = sourceRevision
        let request: GenerationRequest
        do {
            request = try GenerationRequest(source: source, intent: intent, targetLanguage: targetLanguage,
                template: translator.preferences.template(for: intent))
        } catch {
            generationFailed((error as? LocalizedError)?.errorDescription ?? "生成设置无效，请检查后重试。")
            return
        }
        let generation = GenerationRecord(source: request.source, sourceRevision: sourceRevision,
            intent: request.intent, targetLanguage: request.targetLanguage,
            templateRevision: request.templateRevision, configurationIdentity: translator.configurationIdentity)
        requestID = id
        markStale("正在重新生成，旧稿已保留。")
        phase = .translating
        message = translator.progressMessage
        pending = Task { [weak self, translator] in
            guard !Task.isCancelled, self?.requestID == id else { return }
            guard self?.generationStillMatches(generation) == true else {
                self?.rejectChangedGeneration()
                return
            }
            guard let self else { return }
            let validBeforeGeneration = await self.liveTargetMatches(expectedSnapshot)
            guard !Task.isCancelled, self.requestID == id, self.routeID == expectedRoute,
                  self.sourceRevision == expectedSourceRevision,
                  self.captured == expectedSnapshot, self.phase == .translating else { return }
            guard validBeforeGeneration else {
                self.block("原应用或输入内容已变化，请重新读取输入框。")
                return
            }
            do {
                let result = try await translator.generate(request)
                guard self.requestID == id, self.routeID == expectedRoute,
                      self.sourceRevision == expectedSourceRevision,
                      self.captured == expectedSnapshot,
                      self.phase == .translating, !Task.isCancelled else { return }
                guard self.generationStillMatches(generation) else {
                    self.rejectChangedGeneration()
                    return
                }
                let validAfterGeneration = await self.liveTargetMatches(expectedSnapshot)
                guard self.requestID == id, self.routeID == expectedRoute,
                      self.sourceRevision == expectedSourceRevision,
                      self.captured == expectedSnapshot,
                      self.phase == .translating, !Task.isCancelled else { return }
                guard validAfterGeneration else {
                    self.block("原应用或输入内容已变化，请重新读取输入框。")
                    return
                }
                self.pending = nil
                self.requestID = nil
                guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.generationFailed("没有生成有效文字，请重试。")
                    return
                }
                if self.hasOutputEditor { self.rememberReplacement() }
                self.output = result
                self.generationRecord = generation
                self.hasOutputEditor = true
                self.outputDocumentID = UUID()
                self.resultValidity = .current
                self.phase = .ready
                self.message = self.supportsDirectFill(self.captured)
                    ? "译文已生成，请检查后写入输入框。"
                    : "译文已生成，可复制到目标输入框。"
            } catch {
                guard self.requestID == id, self.routeID == expectedRoute,
                      self.sourceRevision == expectedSourceRevision,
                      self.captured == expectedSnapshot, !Task.isCancelled else { return }
                guard self.generationStillMatches(generation) else {
                    self.rejectChangedGeneration()
                    return
                }
                self.pending = nil
                self.requestID = nil
                self.generationFailed((error as? TranslationFailure)?.userMessage ?? "生成失败，请重试。")
            }
        }
    }
    private func generationStillMatches(_ value: GenerationRecord) -> Bool {
        value.sourceRevision == sourceRevision && value.source == source && value.intent == intent
            && value.targetLanguage == targetLanguage
            && value.templateRevision == translator.preferences.templateRevision(for: intent)
            && value.configurationIdentity == translator.configurationIdentity
    }
    private func rejectChangedGeneration() {
        invalidateRequest()
        markStale("生成条件已变化，请重新生成。")
        phase = captured == nil ? .blocked : .idle
        message = "生成条件已变化，旧请求的结果不会被采用。"
    }
    private func generationFailed(_ reason: String) {
        phase = .failed
        markStale("重新生成未完成，保留的是旧译文。")
        message = reason
    }
    public func cancel() {
        if phase == .filling {
            guard fillStage == .returning else {
                message = "写入已开始，无法取消；正在核验目标输入框。"
                return
            }
            pendingFill?.cancel()
            message = "正在取消写入…"
            return
        }
        invalidateRequest()
        markStale("生成已取消，保留的是旧译文。")
        if phase != .blocked && phase != .filled {
            phase = .idle
            message = "已取消。旧请求返回的结果不会被采用。"
        }
    }
    public func hostDidChange() {
        guard captured != nil, phase != .filled, phase != .filling else { return }
        guard let expectedSnapshot = captured else { return }
        invalidateRequest()
        let validationID = UUID()
        liveValidationID = validationID
        let expectedRoute = routeID
        let expectedSourceRevision = sourceRevision
        Task { @MainActor [weak self] in
            guard let self else { return }
            let valid = await self.liveTargetMatches(expectedSnapshot)
            guard self.liveValidationID == validationID, self.routeID == expectedRoute,
                  self.sourceRevision == expectedSourceRevision,
                  self.captured == expectedSnapshot, self.phase != .filled,
                  self.phase != .filling, !Task.isCancelled else { return }
            if !valid { self.block("原应用或输入内容已变化，请重新读取输入框。") }
        }
    }
    public func translationSettingsDidChange() {
        invalidateRequest()
        saveActive()
        for key in drafts.keys {
            var slot = drafts[key]!
            if slot.current.hasOutputEditor { slot.current.validity = .stale("模型设置已变化，请重新生成。") }
            if var previous = slot.previous {
                if previous.hasOutputEditor { previous.validity = .stale("模型设置已变化，请重新生成。") }
                slot.previous = previous
            }
            drafts[key] = slot
        }
        markStale("模型设置已变化，请重新生成。")
        if phase == .filling {
            if fillStage == .returning {
                fillCancellationMessage = "模型设置已变化，写入尚未开始。请重新生成后重试。"
                pendingFill?.cancel()
                message = "模型设置已变化，正在确认写入尚未开始…"
            } else {
                message = "模型设置已变化，写入已开始；正在核对目标输入框。"
            }
            return
        }
        if captured != nil && phase != .blocked && phase != .filled { phase = .idle }
        message = "模型设置已变化。原稿已保留。"
    }
    /// Called after preferences have been installed. Defaults apply to the next capture;
    /// a template change invalidates only drafts and requests using that intent.
    public func preferencesDidChange() {
        let preferences = translator.preferences
        let changedIntents = DraftIntent.allCases.filter {
            observedPreferences.templateRevision(for: $0) != preferences.templateRevision(for: $0)
        }
        observedPreferences = preferences
        guard !changedIntents.isEmpty else { return }
        let reason = "提示词模板已变化，请重新生成。"
        saveActive()
        for key in drafts.keys {
            var slot = drafts[key]!
            if changedIntents.contains(slot.current.intent), slot.current.hasOutputEditor {
                slot.current.validity = .stale(reason)
            }
            if var previous = slot.previous, changedIntents.contains(previous.intent) {
                if previous.hasOutputEditor { previous.validity = .stale(reason) }
                slot.previous = previous
            }
            drafts[key] = slot
        }
        guard changedIntents.contains(intent) else { return }
        invalidateRequest()
        markStale(reason)
        if phase == .filling {
            if fillStage == .returning {
                fillCancellationMessage = "提示词模板已变化，写入尚未开始。请重新生成后重试。"
                pendingFill?.cancel()
                message = "提示词模板已变化，正在确认写入尚未开始…"
            } else { message = "提示词模板已变化，写入已开始；正在核对目标输入框。" }
            return
        }
        if captured != nil && phase != .blocked && phase != .filled { phase = .idle }
        message = "提示词模板已变化。原稿已保留。"
    }
    public func copyDidComplete(_ succeeded: Bool) {
        guard canCopy else { return }
        message = succeeded ? "已复制译文，请到目标输入框粘贴。" : "复制未成功，请重试。"
    }
    public func externalReturnDidFail() {
        message = "已复制译文，但未能返回 \(externalHostName)。请手动切回并粘贴检查。"
    }
    public func replacementStageDidChange(_ stage: ReplacementStage) {
        guard phase == .filling else { return }
        fillStage = stage
        switch stage {
        case .returning:
            message = "正在返回目标输入框…"
        case .writing:
            message = "正在写入目标草稿…"
        case .verifying:
            message = "正在核对写入结果…"
        }
    }
    public func fill() {
        guard canFill, let snapshot = captured, let entry else { return }
        let text = output
        let id = UUID()
        let expectedRoute = routeID
        let expectedSourceRevision = sourceRevision
        invalidateRequest()
        let record = ReplacementRecord(originalText: snapshot.fullText ?? snapshot.selectedText,
            writtenText: text, captureID: snapshot.captureID, status: .pending, documentID: sourceDocumentID)
        replacements[entry] = record
        replacementRecord = record
        replacementEntry = entry
        replacementID = id
        replacementSnapshot = snapshot
        replacementText = text
        fillCancellationMessage = nil
        fillStage = .returning
        phase = .filling
        message = "正在返回目标输入框…"
        pendingFill = Task { @MainActor [weak self, host] in
            guard let self else { return }
            guard !Task.isCancelled else {
                self.finishCancelledFill(id: id)
                return
            }
            let live = await host.liveSnapshot()
            guard self.replacementID == id, self.phase == .filling,
                  self.routeID == expectedRoute,
                  self.sourceRevision == expectedSourceRevision,
                  self.entry == entry, self.captured == snapshot else { return }
            guard !Task.isCancelled else {
                self.finishCancelledFill(id: id)
                return
            }
            guard let live, live == snapshot, !live.isComposing,
                  !live.containsProtectedContent,
                  self.generationRecord.map(self.generationStillMatches) == true else {
                self.finishBlockedFill(id: id, reason: "目标已变化或不可编辑，请重新读取输入框。")
                return
            }
            do {
                let receipt = try await host.replaceSelection(with: text, expected: snapshot)
                guard self.replacementID == id, self.phase == .filling,
                      self.routeID == expectedRoute,
                      self.sourceRevision == expectedSourceRevision,
                      self.entry == entry, self.captured == snapshot else { return }
                guard receipt.expected == snapshot, receipt.writtenText == text else {
                    self.finishUnknownFill(id: id)
                    return
                }
                self.finishFilled(id: id)
            } catch let error as FillError {
                guard self.replacementID == id, self.phase == .filling,
                      self.routeID == expectedRoute,
                      self.sourceRevision == expectedSourceRevision,
                      self.entry == entry, self.captured == snapshot else { return }
                switch error {
                case .cancelled where self.fillStage == .returning:
                    self.finishCancelledFill(id: id)
                case .outcomeUnknown, .cancelled:
                    self.finishUnknownFill(id: id)
                case .compositionActive:
                    self.finishBlockedFill(id: id, reason: "输入法候选尚未确认，已停止写入。", failure: .compositionActive)
                case .protectedContent:
                    self.finishBlockedFill(id: id, reason: "目标选区包含附件或引用，已停止写入。", failure: .protectedContent)
                case .clipboardUnavailable:
                    self.finishBlockedFill(id: id, reason: "无法完整备份或访问剪贴板，未替换原文。可手动复制译文。", failure: .clipboardUnavailable)
                case .clipboardChanged:
                    self.finishBlockedFill(id: id, reason: "剪贴板已被其他操作修改，未继续替换。译文已保留。", failure: .clipboardChanged)
                case .selectionUnavailable:
                    self.finishBlockedFill(id: id, reason: "无法确认输入框已全选，未替换原文。可复制译文后粘贴。", failure: .selectionUnavailable)
                case .targetChanged, .notEditable:
                    self.finishBlockedFill(id: id, reason: "目标已变化或不可编辑，请重新读取输入框。")
                }
            } catch is CancellationError where self.fillStage == .returning {
                guard self.replacementID == id, self.phase == .filling,
                      self.routeID == expectedRoute,
                      self.sourceRevision == expectedSourceRevision,
                      self.entry == entry, self.captured == snapshot else { return }
                self.finishCancelledFill(id: id)
            } catch {
                guard self.replacementID == id, self.phase == .filling,
                      self.routeID == expectedRoute,
                      self.sourceRevision == expectedSourceRevision,
                      self.entry == entry, self.captured == snapshot else { return }
                self.finishUnknownFill(id: id)
            }
        }
    }

    private func finishFilled(id: UUID) {
        guard replacementID == id else { return }
        updateReplacementStatus(.confirmed)
        pendingFill = nil
        replacementID = nil
        replacementSnapshot = nil
        replacementText = nil
        fillCancellationMessage = nil
        fillStage = nil
        captured = nil
        phase = .filled
        message = "已写入，尚未发送。可到原应用检查或撤销。"
    }

    private func finishCancelledFill(id: UUID) {
        guard replacementID == id else { return }
        updateReplacementStatus(.cancelled)
        pendingFill = nil
        replacementID = nil
        replacementSnapshot = nil
        replacementText = nil
        let cancellationMessage = fillCancellationMessage
        fillCancellationMessage = nil
        fillStage = nil
        phase = .ready
        message = cancellationMessage ?? "已取消写入，原文未修改。可继续编辑当前草稿。"
    }

    private func finishUnknownFill(id: UUID) {
        guard replacementID == id else { return }
        updateReplacementStatus(.unknown, failure: .outcomeUnknown)
        pendingFill = nil
        replacementID = nil
        replacementSnapshot = nil
        replacementText = nil
        fillCancellationMessage = nil
        fillStage = nil
        captured = nil
        phase = .failed
        markStale("写入结果未知，保留原文和译文。")
        message = "写入结果未知，目标可能已替换。请在原输入框中检查，当前译文已保留。"
    }

    private func finishBlockedFill(id: UUID, reason: String, failure: FillError? = .targetChanged) {
        guard replacementID == id else { return }
        updateReplacementStatus(.blocked, failure: failure)
        pendingFill = nil
        replacementID = nil
        replacementSnapshot = nil
        replacementText = nil
        fillCancellationMessage = nil
        fillStage = nil
        block(reason)
    }
    private func updateReplacementStatus(_ status: ReplacementStatus, failure: FillError? = nil) {
        guard let replacementEntry, let saved = replacements[replacementEntry] else { return }
        let updated = ReplacementRecord(originalText: saved.originalText, writtenText: saved.writtenText,
            captureID: saved.captureID, status: status, failure: failure, documentID: saved.documentID)
        replacements[replacementEntry] = updated
        if entry == replacementEntry { replacementRecord = updated }
        self.replacementEntry = nil
    }
    private func liveTargetMatches(_ expected: InputSnapshot) async -> Bool {
        guard let current = await host.liveSnapshot() else { return false }
        return current == expected && !current.isComposing
            && (!current.containsProtectedContent || current.captureScope == .entireInput)
    }
    private func block(_ reason: String) {
        invalidateRequest()
        captured = nil
        markStale(reason)
        phase = .blocked
        message = reason
    }
    private func invalidateRequest() {
        requestID = nil
        pending?.cancel()
        pending = nil
        captureRequestID = nil
        liveValidationID = UUID()
        entryRequestID = UUID()
    }
}
