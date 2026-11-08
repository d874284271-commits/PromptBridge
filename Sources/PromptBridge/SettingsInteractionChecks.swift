#if PROMPTBRIDGE_TESTING
import AppKit
import DraftCore

@MainActor enum SettingsInteractionChecks {
    static func run() async -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PromptBridgeSettingsInteraction-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("providers.json")
        let preferencesURL = directory.appendingPathComponent("preferences.json")
        let local = ProviderConfiguration(format: .responses, baseURL: "http://127.0.0.1:1234/v1", model: "local-model", apiKey: "")
        let imported = ProviderConfiguration(format: .chatCompletions, baseURL: "https://import.example/v1", model: "import-model", apiKey: "SYNTHETIC_IMPORT_KEY")
        let settings = TranslationSettings(loadEnvironment: false, environmentLoader: { _, _ in imported },
                                          configFileURL: configURL, preferencesFileURL: preferencesURL)
        await settle(settings)
        let first = ProviderPreset(name: "本地模型", configuration: local)
        let second = ProviderPreset(name: "另一模型", configuration: local)
        do {
            try settings.saveLibrary(ProviderLibrary(presets: [first, second], activePresetID: first.id))
            let provider = ProviderEditor(library: settings.library, modelsLoader: { _ in [] })
            let session = SettingsEditingSession(settings: settings, provider: provider)
            provider.select(second.id)
            provider.synchronize(settings.library)
            checks.append(("浏览已保存供应商不产生未保存状态", !provider.hasChanges && provider.form.id == second.id))
            checks.append(("无字段修改也可启用选中供应商", session.saveModels(activateSelected: true) && settings.activePresetID == second.id))

            provider.form.name = "修改中的供应商"
            session.preferencesDraft.targetLanguage = "Deutsch"
            session.selectSection(.preferences)
            session.selectSection(.model)
            checks.append(("切换设置分类保留两页草稿", provider.form.name == "修改中的供应商" && session.preferencesDraft.targetLanguage == "Deutsch" && session.dirtyPageNames.count == 2))
            checks.append(("保存偏好只刷新偏好基线", session.savePreferences() && !session.preferencesHaveChanges && provider.hasChanges))
            session.preferencesDraft.targetLanguage = "日本語"
            checks.append(("保存模型保留另一页未保存偏好", session.saveModels(activateSelected: true) && !provider.hasChanges && session.preferencesHaveChanges))
            checks.append(("分别保存后清除各自未保存标记", session.savePreferences() && !session.hasChanges))

            provider.useAPI = false
            provider.form.name = "预设单独保存"
            checks.append(("保存预设不误清待保存运行模式", session.saveModels(activateSelected: false) && provider.hasChanges && settings.activePresetID == second.id && !provider.useAPI))
            provider.useAPI = true
            checks.append(("撤销未保存模式后回到干净状态", !provider.hasChanges))

            let beforeLibrary = settings.library
            let beforeIdentity = settings.configurationIdentity
            let beforeDisk = try Data(contentsOf: configURL)
            provider.form.name = "导入前的未保存修改"
            session.importEnvironment(URL(fileURLWithPath: "/synthetic/import.env"))
            await settle(settings)
            let afterImportDisk = try Data(contentsOf: configURL)
            checks.append(("导入环境配置只生成草稿", settings.library == beforeLibrary && settings.configurationIdentity == beforeIdentity && afterImportDisk == beforeDisk && provider.form.configuration == imported && provider.hasChanges))
            checks.append(("导入保留其他预设的未保存编辑", provider.presets.contains { $0.id == second.id && $0.name == "导入前的未保存修改" }))
            checks.append(("导入草稿明确保存后生效", session.saveModels(activateSelected: true) && settings.configuration == imported))

            session.preferencesDraft.optimizationTemplate = "missing variable"
            session.showsTemplates = false
            checks.append(("保存校验隐藏模板并定位错误", !session.savePreferences() && session.showsTemplates && session.preferencesIntent == .optimize && session.preferencesErrorLocation == .template))
            session.preferencesDraft.optimizationTemplate = TranslationPreferences.defaultOptimizationTemplate
            session.preferencesDraft.targetLanguage = " "
            checks.append(("目标语言错误定位语言字段", !session.savePreferences() && session.preferencesErrorLocation == .language))
            session.preferencesDraft = settings.preferences

            let storedLibrary = settings.library
            provider.form.name = "重新读取失败应保留的编辑"
            try Data("invalid".utf8).write(to: configURL)
            session.reloadModels()
            await settle(settings)
            checks.append(("配置重新读取失败保留草稿和运行配置", provider.form.name == "重新读取失败应保留的编辑" && settings.library == storedLibrary && provider.error != nil))
            try ProviderLibraryStore(fileURL: configURL).save(storedLibrary)
            session.reloadModels()
            await settle(settings)
            checks.append(("成功重新读取更新基线", provider.form == storedLibrary.presets.first(where: { $0.id == storedLibrary.activePresetID }) && !provider.hasChanges))

            session.preferencesDraft.targetLanguage = "pending"
            try Data("invalid".utf8).write(to: preferencesURL)
            session.reloadPreferences()
            checks.append(("偏好重新读取失败保留草稿", session.preferencesDraft.targetLanguage == "pending" && session.preferencesErrorLocation == .file))
            try TranslationPreferencesStore(fileURL: preferencesURL).save(settings.preferences)
            session.reloadPreferences()

            session.nativeCompositionCheck = { true }
            let sectionBefore = session.section
            session.selectSection(.cli)
            checks.append(("输入法候选阻止分类切换和两种保存", session.section == sectionBefore && !session.savePreferences() && !session.saveModels(activateSelected: true)))
            session.nativeCompositionCheck = { false }

            let controller = SettingsController(settings: settings, modelsLoader: { _ in [] })
            controller.show()
            await uiSettle()
            if let window = controller.uiTestWindow, let editor = controller.uiTestEditor, let uiSession = controller.uiTestSession {
                let originalFrame = window.frame
                uiSession.selectSection(.preferences)
                uiSession.showsTemplates = true
                await uiSettle()
                checks.append(("设置切页与展开模板不改变窗口尺寸", window.frame == originalFrame))
                uiSession.preferencesDraft.targetLanguage = "Français"
                checks.append(("保存偏好后保留设置窗口", uiSession.savePreferences() && window.isVisible))
                editor.form.name = "未保存窗口修改"
                var closeAllowed: Bool?
                controller.confirmDiscardForTermination { closeAllowed = $0 }
                await uiSettle()
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    await uiSettle()
                    checks.append(("继续编辑保留窗口及未保存修改", closeAllowed == false && window.isVisible && uiSession.hasChanges))
                } else { checks.append(("未保存窗口显示关闭确认", false)) }
                closeAllowed = nil
                controller.confirmDiscardForTermination { closeAllowed = $0 }
                await uiSettle()
                if let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                    await uiSettle()
                    checks.append(("放弃修改只批准退出且不擅自退出应用", closeAllowed == true && window.isVisible))
                } else { checks.append(("再次关闭仍显示未保存确认", false)) }
                window.close()
            } else { checks.append(("原生设置窗口创建", false)) }
        } catch { checks.append(("设置交互检查发生异常：\(error)", false)) }

        var incompleteLocal = local
        incompleteLocal.model = ""
        checks.append(("本地回环服务可不填 Key，非启用项可缺模型", local.validationIssue(requiringModel: true) == nil && incompleteLocal.validationIssue(requiringModel: false) == nil && incompleteLocal.validationIssue(requiringModel: true)?.field == .model))
        var missingKey = imported
        missingKey.apiKey = ""
        checks.append(("远程服务 Key 错误准确定位", missingKey.validationIssue(requiringModel: false)?.field == .apiKey))
        let demo = TranslationSettings(loadEnvironment: false, environmentLoader: { _, _ in throw SettingsFailure("synthetic import failure") })
        demo.loadEnvironmentFile(URL(fileURLWithPath: "/synthetic/failure.env"))
        await settle(demo)
        checks.append(("草稿导入失败不使运行中的演示失效", demo.isDemo && demo.canGenerate && demo.environmentNotice == nil && demo.importNotice != nil))
        return checks
    }

    private static func settle(_ settings: TranslationSettings) async {
        for _ in 0..<150 where settings.isLoading || settings.isImporting {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
    }
    private static func uiSettle() async { try? await Task.sleep(for: .milliseconds(100)) }
}

#endif
