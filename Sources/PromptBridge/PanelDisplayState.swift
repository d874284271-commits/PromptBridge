import DraftCore
import AccessibilityContracts

enum PanelFailureKind {
    case capture(ExternalInputError?), returnFailure, restore(FillError?), configuration, automatic, copy
}

/// Presentation only. The workflow and broker remain the authorities for every action.
@MainActor struct PanelDisplayState {
    enum Action { case generate, fill, copy, copyAndReturn, cliRead, cliSave, settings, none }
    var action: Action = .none
    var title = "请先输入原文"
    var enabled = false
    var message: String
    var warning = false
    var busy = false
    var canCancelGeneration = false
    var sourceEditable: Bool
    var outputEditable: Bool

    init(workflow: DraftWorkflow, settings: TranslationSettings, presentation: PanelPresentation,
         cliEditor: CLIEditorSession, canReturn: Bool) {
        sourceEditable = workflow.phase != .filling && !presentation.returning
            && !presentation.capturing && !cliEditor.finishing && !cliEditor.awaitingDraft
        outputEditable = workflow.canEditOutput && sourceEditable
        message = workflow.message
        if workflow.phase == .filling || cliEditor.finishing || presentation.returning || presentation.capturing {
            busy = true
            if cliEditor.finishing { title = "正在保存并返回 CLI…"; message = cliEditor.message ?? title }
            else if presentation.capturing { title = "正在读取全文…"; message = title }
            else if presentation.returning { title = "正在返回原输入框…"; message = presentation.restoreMessage ?? title }
            else {
                switch workflow.fillStage {
                case .writing: title = "正在写入…"
                case .verifying: title = "正在核对结果…"
                default: title = "正在返回输入框…"
                }
                message = title
            }
            return
        }
        if workflow.phase == .translating {
            title = settings.isDemo ? "正在生成演示结果…" : "正在生成译文…"
            message = title; busy = true; canCancelGeneration = !presentation.automaticRunning
            return
        }
        if cliEditor.needsConsent {
            action = .cliRead; title = "读取草稿"; enabled = true
            message = cliEditor.message ?? "读取后生成译文，不发送消息。"
            return
        }

        let restoreUnknown: Bool
        if case .restore(.outcomeUnknown) = presentation.failureKind {
            restoreUnknown = presentation.failureDocumentID == workflow.sourceDocumentID && presentation.captureFailure != nil
        } else { restoreUnknown = false }
        let unknown = restoreUnknown || (workflow.replacementRecord?.status == .unknown && workflow.replacementRecord?.documentID == workflow.sourceDocumentID)
            || (cliEditor.outcomeIsUnknown && cliEditor.outcomeDocumentID == workflow.sourceDocumentID)
        let issue = presentation.failureDocumentID == workflow.sourceDocumentID ? presentation.captureFailure : nil
        if unknown {
            message = "替换结果未确认，请到原应用检查。译文已保留，不会自动重试。"
            warning = true
        } else if let issue {
            message = issue; warning = true
        } else if workflow.phase == .blocked || workflow.phase == .failed {
            message = workflow.message; warning = true
        } else if let stale = workflow.staleReason {
            message = stale; warning = true
        } else if let restore = presentation.restoreMessage { message = restore }
        else if workflow.phase == .ready {
            if workflow.isFullInputCapture && workflow.isCopyOnlyTarget {
                message = "此输入框暂不支持直接替换。可复制译文后粘贴。"
            } else if cliEditor.active { message = "可修改译文，确认后替换并返回 CLI。不会发送消息。" }
            else if workflow.canFill { message = "可修改译文，确认后替换原文。不会发送消息。" }
            else { message = "译文已生成，可复制到目标输入框。" }
        }

        if unknown {
            action = .copy; title = "复制译文"; enabled = workflow.canCopy
        } else if workflow.staleReason != nil && workflow.canGenerate {
            action = .generate; title = "重新生成"; enabled = settings.canGenerate
        } else if workflow.hasOutputEditor {
            if cliEditor.active && cliEditor.canSave {
                action = .cliSave; title = "替换并返回"; enabled = true
            } else if workflow.canFill && !cliEditor.active {
                action = .fill; title = workflow.isExternalSelection ? "确认替换" : "写入输入框"; enabled = true
            } else if workflow.isCopyOnlyTarget && workflow.canReturnWithCopy && canReturn && !cliEditor.active {
                action = .copyAndReturn; title = "复制并返回"; enabled = workflow.canCopy
            } else {
                action = .copy; title = workflow.staleReason == nil ? "复制译文" : "复制旧译文"; enabled = workflow.canCopy
            }
        } else if !settings.canGenerate {
            action = .settings; title = settings.isLoading ? "正在加载配置…" : "设置模型"; enabled = !settings.isLoading
        } else {
            action = .generate; title = settings.isDemo ? "生成演示结果" : "生成译文"; enabled = workflow.canGenerate
        }
    }
}
