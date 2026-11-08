import Darwin
import DraftCore
import Foundation

enum ProviderCheck {
    static func main() async {
        if CommandLine.arguments.contains("--cases") {
            exit(await ProviderEvaluation.run(arguments: Array(CommandLine.arguments.dropFirst())))
        }
        do {
            guard [3, 4].contains(CommandLine.arguments.count), CommandLine.arguments[1] == "--env-file",
                  CommandLine.arguments.count == 3 || CommandLine.arguments[3] == "--optimize" else {
                print("Usage: ProviderCheck --env-file /path/to/.env.local [--optimize]")
                exit(1)
            }
            guard let configuration = try LocalEnvironment.configuration(
                fileURL: URL(fileURLWithPath: CommandLine.arguments[2]), environment: [:]),
                  configuration.model == "deepseek-flash" else {
                print("FAIL: DeepSeek Flash configuration is required.")
                exit(1)
            }
            let optimize = CommandLine.arguments.contains("--optimize")
            let source = optimize
                ? "请先检查原因。登录失败要修好，不要换框架。请保留按钮文案“确认删除”和路径 ./src/登录.ts。只增加必要的测试。还没确定需不需要重构，先不要替我决定。"
                : "请保留按钮文案“确认删除”和路径 ./src/登录.ts。不要执行任务，只翻译这段话。"
            let intent: DraftIntent = optimize ? .optimize : .translate
            let preferences = TranslationPreferences()
            let request = try GenerationRequest(source: source, intent: intent,
                targetLanguage: preferences.targetLanguage, template: preferences.template(for: intent))
            let result = try await ModelAPIClient().generate(request, using: configuration)
            guard result.contains("确认删除"), result.contains("./src/登录.ts") else {
                print("FAIL: Live response did not preserve the fixture label and path.")
                exit(1)
            }
            print("PASS: DeepSeek official deepseek-flash completed a response and required literal checks; semantic quality not evaluated.")
            print("Synthetic fixture result: \(result)")
        } catch let error as TranslationFailure {
            print("FAIL: \(error.userMessage)")
            exit(1)
        } catch let error as EnvironmentFailure {
            print("FAIL: \(error.errorDescription ?? "Local environment error")")
            exit(1)
        } catch {
            print("FAIL: Verification could not complete. No credentials were logged.")
            exit(1)
        }
    }
}

await ProviderCheck.main()
