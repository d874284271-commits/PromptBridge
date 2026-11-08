import DraftCore
import Foundation
import Darwin

@MainActor private final class FakeHost: HostInput {
    var current: InputSnapshot? = snapshotValue()
    var writes: [String] = []
    var failAtWrite = false
    var outcomeUnknown = false
    var mismatchedReceipt = false
    var holdReplacement = false
    var replacementStarted = false
    var holdLiveSnapshot = false
    var liveSnapshotCalls = 0
    private var pendingLiveSnapshot: CheckedContinuation<InputSnapshot?, Never>?
    private var pendingReplacement: (text: String, expected: InputSnapshot,
                                     continuation: CheckedContinuation<ReplacementReceipt, Error>)?

    func snapshot() -> InputSnapshot? { current }

    func liveSnapshot() async -> InputSnapshot? {
        liveSnapshotCalls += 1
        guard holdLiveSnapshot else { return current }
        return await withCheckedContinuation { continuation in
            pendingLiveSnapshot = continuation
        }
    }

    func releaseLiveSnapshot(_ value: InputSnapshot? = nil) {
        let continuation = pendingLiveSnapshot
        pendingLiveSnapshot = nil
        continuation?.resume(returning: value ?? current)
    }

    func replaceSelection(with text: String, expected: InputSnapshot) async throws -> ReplacementReceipt {
        guard !failAtWrite, current == expected else { throw FillError.targetChanged }
        guard !outcomeUnknown else { throw FillError.outcomeUnknown }
        replacementStarted = true
        if holdReplacement {
            return try await withCheckedThrowingContinuation { continuation in
                pendingReplacement = (text, expected, continuation)
            }
        }
        writes.append(text)
        return ReplacementReceipt(expected: expected, writtenText: mismatchedReceipt ? "different receipt" : text)
    }

    func releaseReplacement(writes: Bool = true, error: FillError? = nil) {
        guard let pendingReplacement else { return }
        self.pendingReplacement = nil
        if let error {
            pendingReplacement.continuation.resume(throwing: error)
            return
        }
        if writes { self.writes.append(pendingReplacement.text) }
        pendingReplacement.continuation.resume(returning: ReplacementReceipt(
            expected: pendingReplacement.expected, writtenText: pendingReplacement.text))
    }
}

/// Intentionally ignores Task cancellation to exercise late results from an uncooperative provider.
@MainActor private final class ControlledTranslator: DraftTranslator {
    var inputs: [String] = []
    var intents: [DraftIntent] = []
    var requests: [GenerationRequest] = []
    var preferences = TranslationPreferences()
    var configurationIdentity = "fixture-model-1"
    var replies: [Int: CheckedContinuation<String, Error>] = [:]

    func generate(_ request: GenerationRequest) async throws -> String {
        let index = inputs.count
        inputs.append(request.source)
        intents.append(request.intent)
        requests.append(request)
        return try await withCheckedThrowingContinuation { replies[index] = $0 }
    }

    func finish(_ index: Int, _ result: String) { replies.removeValue(forKey: index)?.resume(returning: result) }
    func fail(_ index: Int, error: Error = FillError.notEditable) { replies.removeValue(forKey: index)?.resume(throwing: error) }
}

private func snapshotValue(session: String = "A", revision: UInt64 = 1,
                           selection: NSRange = NSRange(location: 0, length: 5),
                           composing: Bool = false, protected: Bool = false) -> InputSnapshot {
    InputSnapshot(identity: InputIdentity(host: "fixture", window: "window", input: "input", session: session),
                  revision: revision, selection: selection, selectedText: "hello",
                  isComposing: composing, containsProtectedContent: protected)
}

@MainActor final class DraftWorkflowChecks {
    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        recordFailure("Expected asynchronous transition did not occur")
    }

    private func setup() async -> (FakeHost, ControlledTranslator, DraftWorkflow) {
        let host = FakeHost()
        let translator = ControlledTranslator()
        let workflow = DraftWorkflow(host: host, translator: translator)
        await workflow.captureSelection()
        return (host, translator, workflow)
    }

    func testResultRequiresExplicitFillAndCannotBeAppliedTwice() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "English draft")
        await settle { workflow.phase == .ready }
        expectEqual(host.writes, [])
        workflow.fill()
        workflow.fill()
        await settle { workflow.phase == .filled }
        expectEqual(host.writes, ["English draft"])
        expectEqual(workflow.phase, .filled)
    }

    func testFillFreezesOutputUntilLateReceipt() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "frozen draft")
        await settle { workflow.phase == .ready }
        host.holdReplacement = true
        workflow.fill()
        await settle { host.replacementStarted }
        workflow.editOutput("changed while filling")
        expectEqual(workflow.output, "frozen draft")
        expectFalse(workflow.canCopy)
        expectEqual(workflow.fillStage, .returning)
        host.releaseReplacement()
        await settle { workflow.phase == .filled }
        expectEqual(host.writes, ["frozen draft"])
    }

    func testCancelDuringReturnPreservesRetryability() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "draft")
        await settle { workflow.phase == .ready }
        host.holdReplacement = true
        workflow.fill()
        await settle { host.replacementStarted }
        workflow.cancel()
        expectEqual(workflow.phase, .filling)
        host.releaseReplacement(writes: false, error: .cancelled)
        await settle { workflow.phase == .ready }
        expectEqual(host.writes, [])
        expectTrue(workflow.canFill)
        expectEqual(workflow.message, "已取消写入，原文未修改。可继续编辑当前草稿。")
    }

    func testUncooperativeHostReceiptAfterCancelCountsAsFilled() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "draft")
        await settle { workflow.phase == .ready }
        host.holdReplacement = true
        workflow.fill()
        await settle { host.replacementStarted }
        workflow.cancel()
        host.releaseReplacement()
        await settle { workflow.phase == .filled }
        expectEqual(host.writes, ["draft"])
        expectEqual(workflow.message, "已写入，尚未发送。可到原应用检查或撤销。")
    }

    func testCancellationAfterWritingContinuesToVerifiedReceipt() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "draft")
        await settle { workflow.phase == .ready }
        host.holdReplacement = true
        workflow.fill()
        await settle { host.replacementStarted }
        workflow.replacementStageDidChange(.writing)
        workflow.cancel()
        expectEqual(workflow.phase, .filling)
        host.releaseReplacement()
        await settle { workflow.phase == .filled }
        expectEqual(host.writes, ["draft"])
    }

    func testSettingsChangeDuringReturnWaitsForExplicitCancellation() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "draft")
        await settle { workflow.phase == .ready }
        host.holdReplacement = true
        workflow.fill()
        await settle { host.replacementStarted }
        workflow.translationSettingsDidChange()
        expectEqual(workflow.phase, .filling)
        expectTrue(workflow.staleReason != nil)
        expectTrue(workflow.message.contains("确认写入尚未开始"))
        host.releaseReplacement(writes: false, error: .cancelled)
        await settle { workflow.phase == .ready }
        expectFalse(workflow.canFill)
        expectEqual(workflow.output, "draft")
        expectEqual(workflow.message, "模型设置已变化，写入尚未开始。请重新生成后重试。")
    }

    func testSettingsChangeAfterWritingKeepsVerifiedReceipt() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "draft")
        await settle { workflow.phase == .ready }
        host.holdReplacement = true
        workflow.fill()
        await settle { host.replacementStarted }
        workflow.replacementStageDidChange(.writing)
        workflow.translationSettingsDidChange()
        expectEqual(workflow.phase, .filling)
        host.releaseReplacement()
        await settle { workflow.phase == .filled }
        expectEqual(host.writes, ["draft"])
        expectEqual(workflow.message, "已写入，尚未发送。可到原应用检查或撤销。")
        expectTrue(workflow.staleReason != nil)
    }

    func testUnknownFillOutcomePreservesDraftAndWarns() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "draft")
        await settle { workflow.phase == .ready }
        host.outcomeUnknown = true
        workflow.fill()
        await settle { workflow.phase == .failed }
        expectTrue(workflow.message.contains("可能已替换"))
        expectEqual(workflow.output, "draft")
        expectFalse(workflow.canFill)
        expectEqual(host.writes, [])
    }

    func testMismatchedReceiptNeverReportsFilled() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "draft")
        await settle { workflow.phase == .ready }
        host.mismatchedReceipt = true
        workflow.fill()
        await settle { workflow.phase == .failed }
        expectTrue(workflow.message.contains("可能已替换"))
        expectEqual(host.writes, ["draft"])
        expectFalse(workflow.canFill)
    }

    func testEntireInputUsesFullTextAndAllowsManualFillWithoutContext() async {
        let (host, translator, workflow) = await setup()
        host.current = InputSnapshot(identity: InputIdentity(host: "Claude", window: "fixture", input: "field", session: "full-input"),
            revision: 1, selection: NSRange(location: 2, length: 3), selectedText: "old selection",
            captureScope: .entireInput, fullText: "完整输入框内容", contextID: nil)
        await workflow.captureSelection()
        expectEqual(workflow.source, "完整输入框内容")
        expectTrue(workflow.targetLabel.contains("当前输入框"))
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        expectEqual(translator.inputs, ["完整输入框内容"])
        translator.finish(0, "full result")
        await settle { workflow.phase == .ready }
        expectFalse(workflow.isCopyOnlyTarget)
        expectTrue(workflow.canFill)
        workflow.fill()
        await settle { workflow.phase == .filled }
        expectEqual(host.writes, ["full result"])
    }

    func testCancelRejectsUncooperativeLateResult() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        workflow.cancel()
        translator.finish(0, "obsolete")
        for _ in 0..<10 { await Task.yield() }
        workflow.fill()
        expectEqual(workflow.phase, .idle)
        expectEqual(workflow.output, "")
        expectEqual(host.writes, [])
    }

    func testNewRequestWinsWhenResponsesArriveOutOfOrder() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        workflow.editSource("new source")
        workflow.generate()
        await settle { translator.inputs.count == 2 }
        translator.finish(1, "new result")
        await settle { workflow.phase == .ready }
        translator.finish(0, "old result")
        for _ in 0..<10 { await Task.yield() }
        expectEqual(workflow.output, "new result")
        expectEqual(workflow.phase, .ready)
    }

    func testEditingSourceInvalidatesReadyResult() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "old result")
        await settle { workflow.phase == .ready }
        workflow.editSource("updated source")
        workflow.fill()
        expectEqual(workflow.output, "old result")
        expectTrue(workflow.staleReason != nil)
        expectEqual(host.writes, [])
    }

    func testTargetChangeDuringRequestIsCaughtEvenWithoutNotification() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        host.current = snapshotValue(session: "B")
        translator.finish(0, "wrong session")
        await settle { workflow.phase == .blocked }
        expectEqual(workflow.output, "")
        expectFalse(workflow.canFill)
    }

    func testChangingAwayAndBackStillInvalidatesSnapshot() async {
        let (host, _, workflow) = await setup()
        host.current = snapshotValue(revision: 3)
        workflow.hostDidChange()
        await settle { workflow.phase == .blocked }
        expectEqual(workflow.phase, .blocked)
        expectFalse(workflow.canGenerate)
    }

    func testChangedSelectionIsRejectedImmediatelyBeforeFill() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "result")
        await settle { workflow.phase == .ready }
        host.current = snapshotValue(selection: NSRange(location: 8, length: 5))
        workflow.fill()
        await settle { workflow.phase == .blocked }
        expectEqual(workflow.phase, .blocked)
        expectEqual(host.writes, [])
    }

    func testAdapterCanRejectChangeBetweenValidationAndWrite() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "result")
        await settle { workflow.phase == .ready }
        host.failAtWrite = true
        workflow.fill()
        await settle { workflow.phase == .blocked }
        expectEqual(workflow.phase, .blocked)
        expectEqual(host.writes, [])
    }

    func testMissingTargetAndProtectedSelectionCannotStart() async {
        let (host, _, workflow) = await setup()
        host.current = nil
        await workflow.captureSelection()
        expectFalse(workflow.canGenerate)
        host.current = snapshotValue(protected: true)
        await workflow.captureSelection()
        expectFalse(workflow.canGenerate)
        host.current = snapshotValue(composing: true)
        await workflow.captureSelection()
        expectFalse(workflow.canGenerate)
    }

    func testCompositionBlocksGenerationAndFillUntilCommitted() async {
        let (host, translator, workflow) = await setup()
        workflow.editSource("候选", isComposing: true)
        expectFalse(workflow.canGenerate)
        await workflow.captureSelection()
        expectTrue(workflow.sourceIsComposing)
        workflow.editSource("已确认")
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "result")
        await settle { workflow.phase == .ready }
        workflow.editOutput("结果候选", isComposing: true)
        workflow.fill()
        expectEqual(host.writes, [])
        workflow.editOutput("confirmed result")
        workflow.fill()
        await settle { workflow.phase == .filled }
        expectEqual(host.writes, ["confirmed result"])
    }

    func testReopeningPreservesEditedDrafts() async {
        let (_, translator, workflow) = await setup()
        workflow.editSource("edited source")
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "result")
        await settle { workflow.phase == .ready }
        workflow.editOutput("manually edited result")
        await workflow.prepareForOpening()
        expectEqual(workflow.source, "edited source")
        expectEqual(workflow.output, "manually edited result")
        expectTrue(workflow.canFill)
    }

    func testInvalidTargetPreservesEditedOutput() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "result")
        await settle { workflow.phase == .ready }
        workflow.editOutput("manually edited result", isComposing: true)
        expectFalse(workflow.canGenerate)
        host.current = nil
        workflow.hostDidChange()
        await settle { workflow.phase == .blocked }
        workflow.editOutput("committed result", isComposing: false)
        expectFalse(workflow.outputIsComposing)
        expectEqual(workflow.output, "committed result")
        expectFalse(workflow.canFill)
        await workflow.prepareForOpening()
        expectEqual(workflow.output, "committed result")
    }

    func testEmptyAndFailedResponsesCannotBeFilled() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "  \n")
        await settle { workflow.phase == .failed }
        expectFalse(workflow.canFill)
        workflow.generate()
        await settle { translator.inputs.count == 2 }
        translator.fail(1)
        await settle { workflow.phase == .failed }
        workflow.fill()
        expectEqual(host.writes, [])
    }

    func testSettingsChangeBeforeTaskStartsMakesNoRequest() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        workflow.translationSettingsDidChange()
        for _ in 0..<10 { await Task.yield() }
        expectEqual(translator.inputs, [])
        expectEqual(workflow.phase, .idle)
    }

    func testSettingsChangeRejectsLateResponseAndPreservesEditedResult() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        workflow.translationSettingsDidChange()
        translator.finish(0, "old provider")
        for _ in 0..<10 { await Task.yield() }
        expectEqual(workflow.output, "")
        expectFalse(workflow.canFill)
        workflow.generate()
        await settle { translator.inputs.count == 2 }
        translator.finish(1, "new provider")
        await settle { workflow.phase == .ready }
        workflow.editOutput("user's edited draft")
        workflow.translationSettingsDidChange()
        expectEqual(workflow.output, "user's edited draft")
        workflow.fill()
        expectEqual(host.writes, [])
        expectTrue(workflow.canGenerate)
    }

    func testSafeProviderErrorReachesUser() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.fail(0, error: TranslationFailure.http(401))
        await settle { workflow.phase == .failed }
        expectEqual(workflow.message, TranslationFailure.http(401).userMessage)
        expectFalse(workflow.canFill)
    }

    func testReadOnlyExternalTargetCanCopyButNeverFill() async {
        let (host, translator, workflow) = await setup()
        host.current = InputSnapshot(identity: InputIdentity(host: "Claude", window: "fixture", input: "field", session: "selected-input"),
            revision: 1, selection: NSRange(location: 0, length: 5), selectedText: "hello", supportsDirectFill: false)
        await workflow.captureSelection()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "Complete English draft")
        await settle { workflow.phase == .ready }
        expectTrue(workflow.canCopy)
        expectFalse(workflow.canFill)
        workflow.fill()
        expectEqual(host.writes, [])
        host.current = nil
        workflow.hostDidChange()
        expectTrue(workflow.canCopy)
        expectFalse(workflow.canFill)
    }

    func testIntentChangeRejectsLateResultAndKeepsManualEdits() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        workflow.setIntent(.optimize)
        translator.finish(0, "old translation")
        for _ in 0..<10 { await Task.yield() }
        expectEqual(workflow.output, "")
        workflow.generate()
        await settle { translator.inputs.count == 2 }
        expectEqual(translator.intents, [.translate, .optimize])
        translator.finish(1, "optimized draft")
        await settle { workflow.phase == .ready }
        workflow.editOutput("user edited")
        workflow.setIntent(.translate)
        expectEqual(workflow.output, "user edited")
        expectFalse(workflow.canFill)
    }

    func testManualInputDoesNotRequireExternalTargetOrDiscardDraft() async {
        let (host, translator, workflow) = await setup()
        workflow.editSource("manual source")
        host.current = InputSnapshot(identity: InputIdentity(host: "手动输入", window: "manual", input: "manual", session: "manual"),
            revision: 1, selection: NSRange(location: 0, length: 0), selectedText: "", supportsDirectFill: false)
        await workflow.useManualInput()
        expectEqual(workflow.source, "")
        workflow.editSource("manual source")
        expectTrue(workflow.isManualInput)
        expectFalse(workflow.isExternalSelection)
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "manual English")
        await settle { workflow.phase == .ready }
        expectTrue(workflow.canCopy)
        expectFalse(workflow.canFill)
        expectEqual(host.writes, [])
    }

    func testManualReentryPreservesInFlightGenerationAndReadyResult() async {
        let host = FakeHost()
        host.current = InputSnapshot(identity: InputIdentity(host: "手动输入", window: "manual", input: "manual", session: "manual"),
            revision: 1, selection: NSRange(location: 0, length: 0), selectedText: "", supportsDirectFill: false)
        let translator = ControlledTranslator()
        let workflow = DraftWorkflow(host: host, translator: translator)
        await workflow.useManualInput()
        workflow.editSource("manual source")
        let sourceDocument = workflow.sourceDocumentID
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        let progress = workflow.message

        await workflow.useManualInput()
        expectEqual(workflow.phase, .translating)
        expectEqual(workflow.message, progress)
        expectEqual(translator.inputs, ["manual source"])
        expectEqual(workflow.sourceDocumentID, sourceDocument)
        translator.finish(0, "manual translation")
        await settle { workflow.phase == .ready }
        expectEqual(workflow.output, "manual translation")
        guard workflow.phase == .ready else { return }

        workflow.editOutput("edited translation")
        workflow.copyDidComplete(true)
        let copyMessage = workflow.message
        let outputDocument = workflow.outputDocumentID
        let generation = workflow.generationRecord
        await workflow.useManualInput()
        expectEqual(workflow.phase, .ready)
        expectEqual(workflow.output, "edited translation")
        expectEqual(workflow.message, copyMessage)
        expectEqual(workflow.generationRecord, generation)
        expectEqual(workflow.outputDocumentID, outputDocument)
        expectTrue(workflow.canCopy)
        expectFalse(workflow.canFill)
        expectEqual(translator.inputs.count, 1)
        expectEqual(host.writes, [])
    }

    func testRegenerationKeepsManualResultOnFailureAndCancel() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "first result")
        await settle { workflow.phase == .ready }
        workflow.editOutput("valuable manual draft")
        workflow.generate()
        expectEqual(workflow.output, "valuable manual draft")
        expectFalse(workflow.canEditOutput)
        await settle { translator.inputs.count == 2 }
        translator.fail(1, error: TranslationFailure.network)
        await settle { workflow.phase == .failed }
        expectEqual(workflow.output, "valuable manual draft")
        expectTrue(workflow.canEditOutput && workflow.canCopy)
        expectFalse(workflow.canFill)
        workflow.generate()
        await settle { translator.inputs.count == 3 }
        workflow.cancel()
        translator.finish(2, "late result")
        for _ in 0..<20 { await Task.yield() }
        expectEqual(workflow.output, "valuable manual draft")
        workflow.generate()
        await settle { translator.inputs.count == 4 }
        translator.finish(3, "  ")
        await settle { workflow.phase == .failed }
        expectEqual(workflow.output, "valuable manual draft")
    }

    func testNewResultHasOneStepRecoveryWithoutFillPermission() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "original")
        await settle { workflow.phase == .ready }
        workflow.editOutput("manual English")
        let previousDocument = workflow.outputDocumentID
        workflow.generate()
        await settle { translator.inputs.count == 2 }
        translator.finish(1, "replacement")
        await settle { workflow.phase == .ready }
        expectTrue(workflow.canRestore)
        expectFalse(previousDocument == workflow.outputDocumentID)
        await workflow.restorePreviousDraft()
        expectEqual(workflow.output, "manual English")
        expectTrue(workflow.canCopy)
        expectFalse(workflow.canFill || workflow.canGenerate)
        await workflow.restorePreviousDraft()
        expectEqual(workflow.output, "replacement")
        expectFalse(workflow.canFill)
    }

    func testEntriesKeepSeparateDraftsAndInvalidateSavedResultsOnConfigChange() async {
        let (host, translator, workflow) = await setup()
        workflow.editSource("demo work")
        host.current = InputSnapshot(identity: InputIdentity(host: "手动输入", window: "manual", input: "manual", session: "manual"),
            revision: 1, selection: NSRange(location: 0, length: 0), selectedText: "", supportsDirectFill: false)
        _ = await workflow.prepareForEntrySwitch()
        await workflow.useManualInput()
        workflow.editSource("manual work")
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "manual English")
        await settle { workflow.phase == .ready }
        for name in ["Claude", "ChatGPT / Codex"] {
            _ = await workflow.prepareForEntrySwitch()
            host.current = InputSnapshot(identity: InputIdentity(host: name, window: "fixture", input: "field", session: "selected-input"),
                revision: 1, selection: NSRange(location: 0, length: 3), selectedText: name, supportsDirectFill: false)
            await workflow.captureSelection()
            workflow.editSource("\(name) work")
        }
        workflow.translationSettingsDidChange()
        await workflow.openSavedEntry(.claude)
        expectEqual(workflow.source, "Claude work")
        expectFalse(workflow.canGenerate)
        await workflow.openSavedEntry(.codex)
        expectEqual(workflow.source, "ChatGPT / Codex work")
        await workflow.openSavedEntry(.demo)
        expectEqual(workflow.source, "demo work")
        host.current = InputSnapshot(identity: InputIdentity(host: "手动输入", window: "manual", input: "manual", session: "manual"),
            revision: 2, selection: NSRange(location: 0, length: 0), selectedText: "", supportsDirectFill: false)
        await workflow.useManualInput()
        expectEqual(workflow.source, "manual work")
        expectEqual(workflow.output, "manual English")
        expectTrue(workflow.staleReason != nil && workflow.canGenerate)
    }

    func testProtectedFullInputCanTranslateAndCopyWithoutReplacingObjects() async {
        let (host, translator, workflow) = await setup()
        host.current = InputSnapshot(identity: InputIdentity(host: "微信", window: "w", input: "i", session: "s",
            bundleIdentifier: "com.tencent.xinWeChat"), revision: 1, selection: NSRange(location: 0, length: 5),
            selectedText: "hello", containsProtectedContent: true, supportsDirectFill: false,
            captureScope: .entireInput, fullText: "hello", captureID: UUID())
        await workflow.captureSelection()
        expectTrue(workflow.canGenerate)
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "translation")
        await settle { workflow.phase == .ready }
        expectTrue(workflow.canCopy)
        expectFalse(workflow.canFill)
        workflow.fill()
        expectEqual(host.writes.count, 0)
    }

    func testGenericApplicationsKeepDraftsAndReplacementRecordsSeparate() async {
        let host = FakeHost()
        let translator = ControlledTranslator()
        let workflow = DraftWorkflow(host: host, translator: translator)
        for (index, app) in [("com.tencent.xinWeChat", "微信"), ("com.tencent.qq", "QQ")].enumerated() {
            host.current = InputSnapshot(identity: InputIdentity(host: app.1, window: "same", input: "same",
                session: "unavailable", bundleIdentifier: app.0), revision: 1,
                selection: NSRange(location: 0, length: 5), selectedText: "hello", supportsDirectFill: true,
                captureScope: .entireInput, fullText: "hello", captureID: UUID())
            await workflow.captureSelection()
            expectEqual(workflow.entry, .external(bundleIdentifier: app.0))
            expectTrue(workflow.targetLabel.contains(app.1))
            workflow.generate()
            await settle { translator.inputs.count == index + 1 }
            translator.finish(index, "translation for \(app.1)")
            await settle { workflow.phase == .ready }
            workflow.fill()
            await settle { workflow.phase == .filled }
        }
        expectEqual(workflow.externalDraftEntries.count, 2)
        for app in [("com.tencent.xinWeChat", "微信"), ("com.tencent.qq", "QQ")] {
            await workflow.openSavedEntry(.external(bundleIdentifier: app.0))
            expectEqual(workflow.output, "translation for \(app.1)")
            expectEqual(workflow.replacementRecord?.writtenText, "translation for \(app.1)")
            expectFalse(workflow.canFill)
        }
        expectFalse(workflow.hasSavedDraft(.demo))
    }

    func testCaptureFailureAndNewSelectionPreserveDrafts() async {
        let (host, translator, workflow) = await setup()
        workflow.editSource("unfinished source")
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "edited English")
        await settle { workflow.phase == .ready }
        host.current = nil
        await workflow.captureSelection()
        expectEqual(workflow.source, "unfinished source")
        expectEqual(workflow.output, "edited English")
        host.current = snapshotValue(revision: 3)
        await workflow.captureSelection()
        expectEqual(workflow.output, "")
        await workflow.restorePreviousDraft()
        expectEqual(workflow.source, "unfinished source")
        expectEqual(workflow.output, "edited English")
        expectFalse(workflow.canGenerate || workflow.canFill)
    }

    func testStaleReasonSurvivesCopyAndCompositionProtectsEntrySwitch() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "English")
        await settle { workflow.phase == .ready }
        workflow.setIntent(.optimize)
        let reason = workflow.staleReason
        workflow.copyDidComplete(true)
        expectEqual(workflow.staleReason, reason)
        workflow.editOutput("candidate", isComposing: true)
        let entry = workflow.entry
        expectFalse(await workflow.prepareForEntrySwitch())
        await workflow.openSavedEntry(.claude)
        await workflow.restorePreviousDraft()
        expectEqual(workflow.entry, entry)
        expectTrue(workflow.outputIsComposing)
        workflow.editOutput("committed", isComposing: false)
        expectTrue(workflow.canCopy)
    }

    func testFailedCaptureStopsPendingTranslationWithoutDiscardingDraft() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.inputs.count == 1 }
        translator.finish(0, "manual English")
        await settle { workflow.phase == .ready }
        workflow.generate()
        await settle { translator.inputs.count == 2 }
        expectTrue(await workflow.prepareForEntrySwitch())
        workflow.captureDidFail("捕获失败")
        expectEqual(workflow.phase, .blocked)
        expectEqual(workflow.output, "manual English")
        expectTrue(workflow.canCopy)
        translator.finish(1, "obsolete")
        for _ in 0..<20 { await Task.yield() }
        expectEqual(workflow.output, "manual English")
        expectFalse(workflow.canGenerate)
    }

    func testNativeHostCompositionProtectsEntrySwitch() async {
        let (host, _, workflow) = await setup()
        host.current = snapshotValue(composing: true)
        expectFalse(await workflow.prepareForEntrySwitch())
        await workflow.openSavedEntry(.claude)
        expectEqual(workflow.entry, .demo)
        expectEqual(workflow.source, "hello")
        expectTrue(workflow.message.contains("测试宿主"))
    }

    func testTargetLanguageFreezesRequestAndRejectsLateResult() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.requests.count == 1 }
        workflow.setTargetLanguage(" 日本語 ")
        workflow.setTargetLanguage(" \n ")
        expectEqual(workflow.targetLanguage, "日本語")
        translator.finish(0, "obsolete English")
        for _ in 0..<20 { await Task.yield() }
        expectEqual(workflow.output, "")
        workflow.generate()
        await settle { translator.requests.count == 2 }
        expectEqual(translator.requests[0].targetLanguage, "English")
        expectEqual(translator.requests[1].targetLanguage, "日本語")
        expectTrue(translator.requests[1].instructions.contains("日本語"))
        translator.finish(1, "日本語の結果")
        await settle { workflow.phase == .ready }
        expectEqual(workflow.generationRecord?.targetLanguage, "日本語")
        expectEqual(workflow.generationRecord?.sourceRevision, workflow.sourceRevision)
        expectEqual(workflow.generationRecord?.configurationIdentity, translator.configurationIdentity)
    }

    func testOnlyApplicableTemplateInvalidatesGeneration() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.requests.count == 1 }
        translator.preferences.optimizationTemplate += " Preserve punctuation."
        translator.preferences.launcherMode = .focusedInput
        workflow.preferencesDidChange()
        expectEqual(workflow.phase, .translating)
        translator.finish(0, "translation remains applicable")
        await settle { workflow.phase == .ready }
        workflow.editOutput("edited result")
        workflow.generate()
        await settle { translator.requests.count == 2 }
        translator.preferences.translationTemplate += " Keep paragraph boundaries."
        workflow.preferencesDidChange()
        expectEqual(workflow.phase, .idle)
        expectTrue(workflow.staleReason?.contains("模板") == true)
        translator.finish(1, "obsolete template result")
        for _ in 0..<20 { await Task.yield() }
        expectEqual(workflow.output, "edited result")
        expectFalse(workflow.canFill)
        workflow.generate()
        await settle { translator.requests.count == 3 }
        expectFalse(translator.requests[1].templateRevision == translator.requests[2].templateRevision)
        translator.finish(2, "new template result")
        await settle { workflow.phase == .ready }
    }

    func testUnannouncedConfigurationChangesRejectLateResults() async {
        let (_, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.requests.count == 1 }
        translator.configurationIdentity = "fixture-model-2"
        translator.finish(0, "old model")
        await settle { workflow.phase != .translating }
        expectEqual(workflow.output, "")
        workflow.generate()
        await settle { translator.requests.count == 2 }
        translator.preferences.translationTemplate += " Keep all names."
        translator.finish(1, "old prompt")
        await settle { workflow.phase != .translating }
        expectEqual(workflow.output, "")
        expectFalse(workflow.canFill)
    }

    func testSavedDraftLanguagesSurviveDefaultChangesAndRestoration() async {
        let (host, translator, workflow) = await setup()
        workflow.setTargetLanguage("Français")
        workflow.editSource("French draft")
        translator.preferences.targetLanguage = "한국어"
        workflow.preferencesDidChange()
        expectEqual(workflow.targetLanguage, "Français")
        host.current = InputSnapshot(identity: InputIdentity(host: "手动输入", window: "manual", input: "manual", session: "manual"),
            revision: 1, selection: NSRange(location: 0, length: 0), selectedText: "", supportsDirectFill: false)
        await workflow.useManualInput()
        expectEqual(workflow.targetLanguage, "한국어")
        workflow.editSource("manual source")
        workflow.setTargetLanguage("Español")
        await workflow.openSavedEntry(.demo)
        expectEqual(workflow.targetLanguage, "Français")
        await workflow.useManualInput()
        expectEqual(workflow.targetLanguage, "Español")
        host.current = snapshotValue(revision: 9)
        await workflow.captureSelection()
        expectEqual(workflow.targetLanguage, "한국어")
        await workflow.restorePreviousDraft()
        expectEqual(workflow.targetLanguage, "Français")
        expectEqual(workflow.source, "French draft")
    }

    func testTemplateChangesInvalidateOnlyApplicableSavedDrafts() async {
        let (host, translator, workflow) = await setup()
        host.current = InputSnapshot(identity: InputIdentity(host: "手动输入", window: "manual", input: "manual", session: "manual"),
            revision: 1, selection: NSRange(location: 0, length: 0), selectedText: "", supportsDirectFill: false)
        await workflow.useManualInput()
        workflow.editSource("manual translation")
        workflow.generate()
        await settle { translator.requests.count == 1 }
        translator.finish(0, "saved translation")
        await settle { workflow.phase == .ready }
        host.current = snapshotValue(revision: 10)
        await workflow.captureSelection()
        workflow.setIntent(.optimize)
        workflow.generate()
        await settle { translator.requests.count == 2 }
        translator.finish(1, "optimization")
        await settle { workflow.phase == .ready }
        translator.preferences.translationTemplate += " Preserve literal labels."
        workflow.preferencesDidChange()
        expectEqual(workflow.resultValidity, .current)
        expectTrue(workflow.canFill)
        host.current = InputSnapshot(identity: InputIdentity(host: "手动输入", window: "manual", input: "manual", session: "manual"),
            revision: 2, selection: NSRange(location: 0, length: 0), selectedText: "", supportsDirectFill: false)
        await workflow.useManualInput()
        expectEqual(workflow.output, "saved translation")
        expectTrue(workflow.staleReason?.contains("模板") == true)
    }

    func testUnknownReplacementKeepsCapturedAAndExactEAcrossEditsAndEntries() async {
        let (host, translator, workflow) = await setup()
        let captureID = UUID()
        host.current = InputSnapshot(identity: InputIdentity(host: "Claude", window: "fixture", input: "field", session: "manual"),
            revision: 1, selection: NSRange(location: 0, length: 1), selectedText: "selection",
            captureScope: .entireInput, fullText: "CAPTURED A", captureID: captureID)
        await workflow.captureSelection()
        workflow.editSource("EDITED B")
        workflow.generate()
        await settle { translator.requests.count == 1 }
        expectEqual(translator.requests[0].source, "EDITED B")
        translator.finish(0, "generated result")
        await settle { workflow.phase == .ready }
        workflow.editOutput("EXACT E")
        host.outcomeUnknown = true
        workflow.fill()
        expectEqual(workflow.replacementRecord?.status, .pending)
        await settle { workflow.phase == .failed }
        let frozen = workflow.replacementRecord
        expectEqual(frozen?.originalText, "CAPTURED A")
        expectEqual(frozen?.writtenText, "EXACT E")
        expectEqual(frozen?.captureID, captureID)
        expectEqual(frozen?.status, .unknown)
        expectEqual(frozen?.failure, .outcomeUnknown)
        workflow.editSource("LATER EDIT")
        workflow.editOutput("LATER RESULT")
        await workflow.captureSelection()
        expectEqual(workflow.replacementRecord, frozen)
        await workflow.openSavedEntry(.codex)
        expectEqual(workflow.replacementRecord, nil)
        await workflow.openSavedEntry(.claude)
        expectEqual(workflow.replacementRecord, frozen)
        expectEqual(host.writes, [])
        host.outcomeUnknown = false
        await workflow.captureSelection()
        workflow.generate()
        await settle { translator.requests.count == 2 }
        translator.finish(1, "NEXT E")
        await settle { workflow.phase == .ready }
        workflow.fill()
        await settle { workflow.phase == .filled }
        expectEqual(workflow.replacementRecord?.writtenText, "NEXT E")
        expectEqual(workflow.replacementRecord?.status, .confirmed)
        expectEqual(host.writes, ["NEXT E"])
    }

    func testFillFreezesLanguageAndReplacementRecordUntilReceipt() async {
        let (host, translator, workflow) = await setup()
        workflow.setTargetLanguage("Deutsch")
        workflow.generate()
        await settle { translator.requests.count == 1 }
        translator.finish(0, "Ergebnis")
        await settle { workflow.phase == .ready }
        host.holdReplacement = true
        workflow.fill()
        await settle { host.replacementStarted }
        workflow.setTargetLanguage("Italiano")
        workflow.editSource("changed")
        expectEqual(workflow.targetLanguage, "Deutsch")
        expectEqual(workflow.replacementRecord?.originalText, "hello")
        expectEqual(workflow.replacementRecord?.writtenText, "Ergebnis")
        host.releaseReplacement(writes: false, error: .cancelled)
        await settle { workflow.phase == .ready }
        expectEqual(workflow.replacementRecord?.status, .cancelled)
    }

    func testDelayedLiveValidationGuardsGenerationStartAndResult() async {
        let (host, translator, workflow) = await setup()
        host.holdLiveSnapshot = true
        workflow.generate()
        for _ in 0..<20 { await Task.yield() }
        expectEqual(translator.requests.count, 0)
        host.releaseLiveSnapshot()
        await settle { translator.requests.count == 1 }

        host.holdLiveSnapshot = true
        translator.finish(0, "delayed result")
        for _ in 0..<20 { await Task.yield() }
        expectEqual(workflow.phase, .translating)
        host.releaseLiveSnapshot()
        await settle { workflow.phase == .ready }
        expectEqual(workflow.output, "delayed result")
    }

    func testDelayedLiveValidationCannotStartOldGenerationAfterSourceEditOrEntrySwitch() async {
        let (host, translator, workflow) = await setup()
        host.holdLiveSnapshot = true
        workflow.generate()
        for _ in 0..<20 { await Task.yield() }
        workflow.editSource("new source")
        host.releaseLiveSnapshot()
        for _ in 0..<40 { await Task.yield() }
        expectEqual(translator.requests.count, 0)
        expectEqual(workflow.source, "new source")

        host.holdLiveSnapshot = true
        workflow.generate()
        for _ in 0..<20 { await Task.yield() }
        await workflow.openSavedEntry(.claude)
        host.releaseLiveSnapshot()
        for _ in 0..<40 { await Task.yield() }
        expectEqual(translator.requests.count, 0)
        expectEqual(workflow.entry, .claude)
    }

    func testCancelledDelayedFillNeverCallsSetter() async {
        let (host, translator, workflow) = await setup()
        workflow.generate()
        await settle { translator.requests.count == 1 }
        translator.finish(0, "fill result")
        await settle { workflow.phase == .ready }

        host.holdLiveSnapshot = true
        workflow.fill()
        await settle { workflow.phase == .filling }
        workflow.cancel()
        host.releaseLiveSnapshot()
        await settle { workflow.phase == .ready }
        expectFalse(host.replacementStarted)
        expectEqual(host.writes, [])
    }
}


@MainActor private var failures: [String] = []

@MainActor private func recordFailure(_ message: String, line: UInt = #line) {
    failures.append("Line \(line): \(message)")
}

@MainActor private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, line: UInt = #line) {
    if actual != expected { recordFailure("Expected \(expected), got \(actual)", line: line) }
}

@MainActor private func expectTrue(_ value: Bool, line: UInt = #line) {
    expectEqual(value, true, line: line)
}

@MainActor private func expectFalse(_ value: Bool, line: UInt = #line) {
    expectEqual(value, false, line: line)
}

@main @MainActor enum CheckRunner {
    static func main() async {
        let checks = DraftWorkflowChecks()
        let cases: [(String, () async -> Void)] = [
            ("explicit fill and single application", checks.testResultRequiresExplicitFillAndCannotBeAppliedTwice),
            ("fill freezes output until receipt", checks.testFillFreezesOutputUntilLateReceipt),
            ("cancel during return preserves retryability", checks.testCancelDuringReturnPreservesRetryability),
            ("late receipt after cancel counts as filled", checks.testUncooperativeHostReceiptAfterCancelCountsAsFilled),
            ("cancellation after writing verifies receipt", checks.testCancellationAfterWritingContinuesToVerifiedReceipt),
            ("settings change during return waits for cancellation", checks.testSettingsChangeDuringReturnWaitsForExplicitCancellation),
            ("settings change after writing keeps receipt", checks.testSettingsChangeAfterWritingKeepsVerifiedReceipt),
            ("unknown fill outcome warns and preserves draft", checks.testUnknownFillOutcomePreservesDraftAndWarns),
            ("mismatched receipt never reports filled", checks.testMismatchedReceiptNeverReportsFilled),
            ("full input uses full text and manual fill without context", checks.testEntireInputUsesFullTextAndAllowsManualFillWithoutContext),
            ("cancel rejects late response", checks.testCancelRejectsUncooperativeLateResult),
            ("new request wins out-of-order responses", checks.testNewRequestWinsWhenResponsesArriveOutOfOrder),
            ("source edit invalidates result", checks.testEditingSourceInvalidatesReadyResult),
            ("target change without notification", checks.testTargetChangeDuringRequestIsCaughtEvenWithoutNotification),
            ("switch away and back", { await checks.testChangingAwayAndBackStillInvalidatesSnapshot() }),
            ("selection change before fill", checks.testChangedSelectionIsRejectedImmediatelyBeforeFill),
            ("adapter write-time rejection", checks.testAdapterCanRejectChangeBetweenValidationAndWrite),
            ("missing/protected/composing target", { await checks.testMissingTargetAndProtectedSelectionCannotStart() }),
            ("composition guard", checks.testCompositionBlocksGenerationAndFillUntilCommitted),
            ("empty and failed response", checks.testEmptyAndFailedResponsesCannotBeFilled),
            ("reopen preserves drafts", checks.testReopeningPreservesEditedDrafts),
            ("invalid target preserves edited output", checks.testInvalidTargetPreservesEditedOutput),
            ("settings change before request starts", checks.testSettingsChangeBeforeTaskStartsMakesNoRequest),
            ("settings change invalidates provider response", checks.testSettingsChangeRejectsLateResponseAndPreservesEditedResult),
            ("safe provider error reaches user", checks.testSafeProviderErrorReachesUser),
            ("external target permits copy only", checks.testReadOnlyExternalTargetCanCopyButNeverFill),
            ("intent switch rejects late results", checks.testIntentChangeRejectsLateResultAndKeepsManualEdits),
            ("manual input works without external target", checks.testManualInputDoesNotRequireExternalTargetOrDiscardDraft),
            ("manual reentry preserves in-flight generation and ready result", checks.testManualReentryPreservesInFlightGenerationAndReadyResult),
            ("regeneration failure/cancel/empty retain manual edits", checks.testRegenerationKeepsManualResultOnFailureAndCancel),
            ("one-step recovery does not restore fill permission", checks.testNewResultHasOneStepRecoveryWithoutFillPermission),
            ("entries isolate drafts and invalidate saved results", checks.testEntriesKeepSeparateDraftsAndInvalidateSavedResultsOnConfigChange),
            ("generic apps isolate drafts and replacement records", checks.testGenericApplicationsKeepDraftsAndReplacementRecordsSeparate),
            ("protected whole input keeps translation/copy only", checks.testProtectedFullInputCanTranslateAndCopyWithoutReplacingObjects),
            ("capture failure and replacement retain old draft", checks.testCaptureFailureAndNewSelectionPreserveDrafts),
            ("stale warning survives copy and IME prevents switches", checks.testStaleReasonSurvivesCopyAndCompositionProtectsEntrySwitch),
            ("failed capture cancels pending translation and keeps draft", checks.testFailedCaptureStopsPendingTranslationWithoutDiscardingDraft),
            ("native host candidate prevents entry switch", { await checks.testNativeHostCompositionProtectsEntrySwitch() }),
            ("target language freezes requests and rejects late results", checks.testTargetLanguageFreezesRequestAndRejectsLateResult),
            ("only applicable template invalidates generation", checks.testOnlyApplicableTemplateInvalidatesGeneration),
            ("unannounced model and template changes reject late results", checks.testUnannouncedConfigurationChangesRejectLateResults),
            ("saved languages survive default changes and restoration", checks.testSavedDraftLanguagesSurviveDefaultChangesAndRestoration),
            ("template invalidation applies to matching saved intents", checks.testTemplateChangesInvalidateOnlyApplicableSavedDrafts),
            ("unknown replacement preserves captured A and exact E per entry", checks.testUnknownReplacementKeepsCapturedAAndExactEAcrossEditsAndEntries),
            ("fill freezes language and replacement record", checks.testFillFreezesLanguageAndReplacementRecordUntilReceipt),
            ("delayed live validation guards generation start and result", checks.testDelayedLiveValidationGuardsGenerationStartAndResult),
            ("delayed validation cannot mutate source or switched entry", checks.testDelayedLiveValidationCannotStartOldGenerationAfterSourceEditOrEntrySwitch),
            ("cancelled delayed fill never calls setter", checks.testCancelledDelayedFillNeverCallsSetter),
        ]
        for (name, run) in cases {
            let count = failures.count
            await run()
            print("\(failures.count == count ? "PASS" : "FAIL") \(name)")
        }
        failures += runEnvironmentChecks()
        failures += runProviderLibraryChecks()
        failures += runTranslationPreferencesChecks()
        if let index = CommandLine.arguments.firstIndex(of: "--models-base-url") {
            guard CommandLine.arguments.indices.contains(index + 1),
                  let url = URL(string: CommandLine.arguments[index + 1]),
                  url.scheme == "http", url.host == "127.0.0.1" else { exit(1) }
            failures += await runProviderModelsChecks(baseURL: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--api-base-url") {
            guard CommandLine.arguments.indices.contains(index + 1),
                  let url = URL(string: CommandLine.arguments[index + 1]),
                  url.scheme == "http", url.host == "127.0.0.1" else {
                print("API checks require a 127.0.0.1 fixture URL")
                exit(1)
            }
            failures += await runModelAPIChecks(baseURL: CommandLine.arguments[index + 1])
        }
        failures.forEach { print($0) }
        print("\(cases.count) workflow checks; all requested checks completed with \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }
}
