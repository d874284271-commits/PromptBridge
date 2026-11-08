#if PROMPTBRIDGE_TESTING
import DraftCore
import Foundation

/// State-only settings checks used by the internal UI acceptance runner.
/// All loaders below are injected and use synthetic values; no real environment
/// file, model service, or user configuration is read.
@MainActor final class SettingsAcceptanceChecks {
    private static func delayed(_ value: ProviderConfiguration?, milliseconds: UInt64) async -> ProviderConfiguration? {
        await withCheckedContinuation { continuation in
            Task.detached {
                try? await Task.sleep(nanoseconds: milliseconds * 1_000_000)
                continuation.resume(returning: value)
            }
        }
    }

    static func run() async -> [(String, Bool)] {
        let old = ProviderConfiguration(format: .chatCompletions,
                                        baseURL: "https://api.deepseek.com",
                                        model: "deepseek-flash", apiKey: "old-key")
        let replacement = ProviderConfiguration(format: .chatCompletions,
                                                 baseURL: "https://api.deepseek.com",
                                                 model: "deepseek-reasoner", apiKey: "new-key")
        let late = ProviderConfiguration(format: .responses,
                                         baseURL: "https://api.openai.com/v1",
                                         model: "gpt-test", apiKey: "late-key")
        var checks: [(String, Bool)] = []

        func settle(_ settings: TranslationSettings, timeoutMilliseconds: UInt64 = 500) async {
            let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
            while (settings.isLoading || settings.isImporting) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            for _ in 0..<4 { await Task.yield() }
        }

        // A signed bundle has real configuration paths in Info.plist. Override
        // both paths even when the environment loader itself is synthetic.
        let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PromptBridgeMissing-" + UUID().uuidString)
        let automaticDemo = TranslationSettings(loadEnvironment: true,
            environmentLoader: { _, _ in nil }, environmentTimeout: .seconds(1),
            configFileURL: missingRoot.appendingPathComponent("providers.json"),
            preferencesFileURL: missingRoot.appendingPathComponent("preferences.json"))
        await settle(automaticDemo, timeoutMilliseconds: 2_000)
        checks.append(("自动配置缺失时回到本地演示",
                       automaticDemo.isDemo && automaticDemo.canGenerate
                       && automaticDemo.environmentNotice == nil && !automaticDemo.isLoading))

        do {
            let settings = TranslationSettings(loadEnvironment: false,
                environmentLoader: { _, _ in throw EnvironmentFailure.unreadable },
                environmentTimeout: .milliseconds(25))
            try settings.apply(old)
            var changes = 0
            settings.willChange = { changes += 1 }
            settings.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/failure.env"))
            await settle(settings)
            checks.append(("有效配置导入失败后保留配置和生成能力",
                           settings.configuration == old && settings.canGenerate
                           && settings.importNotice != nil && changes == 0))
        } catch {
            checks.append(("有效配置导入失败后保留配置和生成能力", false))
        }

        do {
            let settings = TranslationSettings(loadEnvironment: false,
                environmentLoader: { _, _ in nil }, environmentTimeout: .milliseconds(25))
            try settings.apply(old)
            settings.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/no-key.env"))
            await settle(settings)
            checks.append(("无有效 API Key 时保留旧配置",
                           settings.configuration == old && settings.canGenerate
                           && settings.importNotice?.contains("API_KEY") == true))
        } catch {
            checks.append(("无有效 API Key 时保留旧配置", false))
        }

        do {
            let settings = TranslationSettings(loadEnvironment: false,
                environmentLoader: { _, _ in
                    try await Task.sleep(nanoseconds: 250_000_000)
                    return replacement
                }, environmentTimeout: .milliseconds(20))
            try settings.apply(old)
            settings.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/timeout.env"))
            let importingIsObservable = settings.isImporting && settings.activeLoadKind == .userImport
            await settle(settings)
            checks.append(("导入超时保留旧配置且区分导入状态",
                           importingIsObservable && settings.configuration == old
                           && settings.canGenerate && settings.importNotice != nil
                           && !settings.isImporting))
        } catch {
            checks.append(("导入超时保留旧配置且区分导入状态", false))
        }

        do {
            var calls = 0
            let settings = TranslationSettings(loadEnvironment: false,
                environmentLoader: { _, _ in replacement }, environmentTimeout: .milliseconds(25))
            try settings.apply(old)
            settings.willChange = { calls += 1 }
            settings.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/success.env"))
            await settle(settings)
            checks.append(("成功导入仅提供草稿而不切换配置",
                           settings.configuration == old && settings.importedConfiguration == replacement && settings.canGenerate
                           && settings.environmentNotice == nil && calls == 0))

            settings.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/same.env"))
            await settle(settings)
            checks.append(("导入相同配置不重复通知",
                           settings.configuration == old && settings.importedConfiguration == replacement && calls == 0))
        } catch {
            checks.append(("成功导入仅提供草稿而不切换配置", false))
            checks.append(("导入相同配置不重复通知", false))
        }

        do {
            let settings = TranslationSettings(loadEnvironment: false,
                environmentLoader: { _, _ in
                    await delayed(late, milliseconds: 120)
                }, environmentTimeout: .milliseconds(500))
            try settings.apply(old)
            var calls = 0
            settings.willChange = { calls += 1 }
            settings.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/late.env"))
            try settings.apply(replacement)
            try? await Task.sleep(nanoseconds: 150_000_000)
            await settle(settings)
            checks.append(("手动应用优先于迟到导入结果",
                           settings.configuration == replacement && settings.canGenerate && calls == 1))
        } catch {
            checks.append(("手动应用优先于迟到导入结果", false))
        }

        do {
            let settings = TranslationSettings(loadEnvironment: false,
                environmentLoader: { _, _ in await delayed(replacement, milliseconds: 120) },
                environmentTimeout: .milliseconds(20))
            try settings.apply(old)
            var changes = 0
            settings.willChange = { changes += 1 }
            settings.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/uncooperative.env"))
            await settle(settings, timeoutMilliseconds: 70)
            checks.append(("不响应取消的读取仍按期限结束等待", !settings.isLoading && !settings.isImporting && settings.configuration == old && changes == 0))
            try? await Task.sleep(nanoseconds: 140_000_000)
            checks.append(("超时后的迟到读取不能替换旧配置", settings.configuration == old && changes == 0 && settings.canGenerate))
            settings.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/cancelled.env"))
            settings.cancelEnvironmentImport()
            try? await Task.sleep(nanoseconds: 140_000_000)
            checks.append(("取消导入后保留配置且拒绝迟到结果", settings.configuration == old && changes == 0 && !settings.isLoading && !settings.isImporting))
        } catch { checks.append(("不合作读取期限与取消保护", false)) }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PromptBridgeSettings-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config/providers.json")
        do {
            let preset = ProviderPreset(name: "123", configuration: replacement)
            let library = ProviderLibrary(presets: [preset], activePresetID: preset.id)
            let settings = TranslationSettings(loadEnvironment: false, configFileURL: file)
            await settle(settings)
            try settings.saveLibrary(library)
            let restarted = TranslationSettings(loadEnvironment: true, environmentLoader: { _, _ in late }, configFileURL: file)
            await settle(restarted)
            checks.append(("页面保存配置后重启恢复名称及全部字段且优先于环境", restarted.library == library && restarted.configuration == replacement))
            var demo = library
            demo.activePresetID = nil
            try settings.saveLibrary(demo)
            let restartedDemo = TranslationSettings(loadEnvironment: true, environmentLoader: { _, _ in late }, configFileURL: file)
            await settle(restartedDemo)
            checks.append(("显式演示模式跨重启保留预设且不被环境覆盖", restartedDemo.library == demo && restartedDemo.isDemo))
            try settings.saveLibrary(library)
            var invalid = library
            invalid.presets[0].name = " "
            do { try settings.saveLibrary(invalid); checks.append(("保存失败不替换有效配置", false)) }
            catch { checks.append(("保存失败不替换有效配置", settings.library == library && (try? ProviderLibraryStore(fileURL: file).load()) == library)) }
            try Data("{broken".utf8).write(to: file)
            settings.reloadSavedConfiguration()
            await settle(settings)
            do { try settings.saveLibrary(library); checks.append(("损坏文件禁止覆盖直到手动修复并重新读取", false)) }
            catch { checks.append(("损坏文件禁止覆盖直到手动修复并重新读取", settings.library == library && (try? String(contentsOf: file, encoding: .utf8)) == "{broken")) }
            try ProviderLibraryStore(fileURL: file).save(library)
            settings.reloadSavedConfiguration()
            await settle(settings)
            try settings.saveLibrary(demo)
            checks.append(("修复文件重新读取后恢复保存", settings.library == demo))
        } catch { checks.append(("持久化状态检查", false)) }

        do {
            let one = ProviderPreset(name: "123", configuration: replacement)
            let two = ProviderPreset(name: "我的代理", configuration: late)
            let editor = ProviderEditor(library: ProviderLibrary(presets: [one, two], activePresetID: one.id), modelsLoader: { _ in [ModelOption(id: "selected")] })
            editor.setFormat(.responses)
            checks.append(("消息格式独立于供应商名称地址和Key", editor.form.name == "123" && editor.form.configuration.baseURL == replacement.baseURL && editor.form.configuration.apiKey == replacement.apiKey))
            editor.select(two.id)
            editor.select(one.id)
            checks.append(("切换预设恢复各自Key和未保存编辑", editor.form.configuration.apiKey == replacement.apiKey && editor.form.configuration.format == .responses))
            editor.setBaseURL(replacement.baseURL + "/proxy")
            checks.append(("同服务路径调整保留Key", editor.form.configuration.apiKey == replacement.apiKey))
            editor.setBaseURL("https://different.example/v1")
            checks.append(("手动修改服务地址清除旧Key", editor.form.configuration.apiKey.isEmpty))
            editor.setKey("fake-key")
            editor.fetchModels()
            for _ in 0..<10 { await Task.yield() }
            checks.append(("获取列表保留手动模型且允许选择", editor.models == [ModelOption(id: "selected")] && editor.form.configuration.model == replacement.model && !editor.isFetchingModels))
            let lateEditor = ProviderEditor(library: ProviderLibrary(presets: [one, two], activePresetID: one.id), modelsLoader: { _ in
                await withCheckedContinuation { continuation in
                    Task.detached { try? await Task.sleep(for: .milliseconds(60)); continuation.resume(returning: [ModelOption(id: "late")]) }
                }
            })
            lateEditor.fetchModels()
            lateEditor.select(two.id)
            try? await Task.sleep(for: .milliseconds(90))
            checks.append(("切换预设拒绝迟到模型列表", lateEditor.models.isEmpty && !lateEditor.isFetchingModels && lateEditor.form.id == two.id))
            editor.delete()
            let saved = editor.libraryForSave(activeID: one.id)
            checks.append(("删除预设同步清除有效选择", saved.activePresetID == nil && saved.presets.count == 1 && saved.presets[0].id == two.id))
        }
        return checks
    }
}

#endif
