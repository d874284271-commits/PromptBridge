#if PROMPTBRIDGE_TESTING
import DraftCore
import Foundation

@MainActor struct DemoTranslator: DraftTranslator {
    func generate(_ request: GenerationRequest) async throws -> String {
        try await Task.sleep(for: .seconds(2))
        let source = request.source
        guard request.targetLanguage == "English",
              request.templateRevision == TranslationPreferences().templateRevision(for: request.intent) else {
            return "【本地演示，非实际译文】\n目标语言：\(request.targetLanguage)\n" + source
        }
        switch source {
        case "请保留按钮文案“确认删除”和路径 ./src/登录.ts。":
            return "Keep the button label “确认删除” and the path ./src/登录.ts unchanged."
        case "修复登录失败的问题，并补充必要的测试。":
            return "Fix the login failure and add the necessary tests."
        default:
            // Deliberately recognizable: this prototype does not pretend to translate arbitrary text.
            return "【本地演示，非实际译文】\n" + source
        }
    }
}

#endif
