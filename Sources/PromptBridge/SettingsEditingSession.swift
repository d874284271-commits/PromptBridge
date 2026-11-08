import AppKit
import Combine
import DraftCore

/// One settings window owns both page drafts, including while a page is hidden.
@MainActor final class SettingsEditingSession: ObservableObject {
    enum Section: Int, CaseIterable { case model, preferences, cli }
    let settings: TranslationSettings
    let provider: ProviderEditor
    @Published var section: Section
    @Published var preferencesDraft: TranslationPreferences
    @Published private(set) var preferencesBaseline: TranslationPreferences
    @Published var preferencesIntent: DraftIntent = .translate
    @Published var templateDocumentID = UUID()
    @Published var showsTemplates = false
    @Published var showsTemplatePreview = false
    @Published var showsPreferenceFile = false
    @Published var showsAdvancedConnection = false
    @Published var showsModelFile = false
    enum PreferenceErrorLocation: Hashable { case language, template, file }
    @Published var preferencesErrorLocation: PreferenceErrorLocation?
    @Published var preferencesError: String?
    @Published var preferencesNotice: String?
    @Published var preferencesIsComposing = false
    @Published var nativeIsComposing = false
    var nativeCompositionCheck: (() -> Bool)?
    private var observations: Set<AnyCancellable> = []

    init(settings: TranslationSettings, provider: ProviderEditor, initialSection: Int = 0) {
        self.settings = settings
        self.provider = provider
        section = Section(rawValue: initialSection) ?? .model
        preferencesDraft = settings.preferences
        preferencesBaseline = settings.preferences
        provider.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &observations)
        settings.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.synchronizeSavedSettings() }
        }.store(in: &observations)
    }

    var isComposing: Bool { preferencesIsComposing || (nativeCompositionCheck?() ?? nativeIsComposing) }
    var preferencesHaveChanges: Bool { preferencesDraft != preferencesBaseline }
    var hasChanges: Bool { provider.hasChanges || preferencesHaveChanges }
    var dirtyPageNames: [String] {
        var pages: [String] = []
        if provider.hasChanges { pages.append("模型连接") }
        if preferencesHaveChanges { pages.append("翻译与浮窗") }
        return pages
    }

    func selectSection(_ section: Section) {
        guard !isComposing else { return }
        self.section = section
    }

    private func synchronizeSavedSettings() {
        provider.synchronize(settings.library)
        if !preferencesHaveChanges {
            preferencesDraft = settings.preferences
            preferencesBaseline = settings.preferences
        }
    }

    @discardableResult func saveModels(activateSelected: Bool) -> Bool {
        guard !isComposing, !settings.isLoading, !settings.isImporting else { return false }
        let active = activateSelected ? (provider.useAPI ? provider.form.id : nil) : settings.activePresetID
        let value = provider.libraryForSave(activeID: active)
        guard provider.validateForSave(value) else {
            if provider.fieldIssue?.field == .modelsPath { showsAdvancedConnection = true }
            return false
        }
        do {
            if activateSelected && provider.useAPI && value.activePresetID == nil {
                throw SettingsFailure("请先填写供应商配置。")
            }
            try settings.saveLibrary(value)
            provider.didSave(value)
            provider.notice = activateSelected ? "已保存，当前设置已生效。" : "预设已保存，当前启用项保持不变。"
            return true
        } catch {
            provider.error = (error as? LocalizedError)?.errorDescription ?? "配置保存失败，原配置已保留。"
            return false
        }
    }

    @discardableResult func savePreferences() -> Bool {
        guard !isComposing else { return false }
        preferencesError = nil
        preferencesErrorLocation = nil
        for intent in DraftIntent.allCases {
            do { _ = try preferencesDraft.render(intent: intent, targetLanguage: preferencesDraft.targetLanguage) }
            catch {
                if error as? TranslationPreferencesError != .emptyTargetLanguage {
                    showsTemplates = true
                    preferencesIntent = intent
                    templateDocumentID = UUID()
                    preferencesErrorLocation = .template
                } else { preferencesErrorLocation = .language }
                preferencesError = error.localizedDescription
                return false
            }
        }
        do {
            try settings.savePreferences(preferencesDraft)
            preferencesDraft = settings.preferences
            preferencesBaseline = settings.preferences
            preferencesNotice = "已保存。"
            return true
        } catch {
            preferencesError = error.localizedDescription
            preferencesErrorLocation = .file
            showsPreferenceFile = true
            return false
        }
    }

    func reloadPreferences() {
        guard !isComposing else { return }
        if settings.reloadPreferences() {
            preferencesDraft = settings.preferences
            preferencesBaseline = settings.preferences
            preferencesError = nil
            preferencesErrorLocation = nil
            preferencesNotice = "已重新读取设置。"
            templateDocumentID = UUID()
        } else { preferencesError = settings.preferencesNotice; preferencesErrorLocation = .file; showsPreferenceFile = true }
    }

    func reloadModels() {
        guard !isComposing else { return }
        settings.reloadSavedConfiguration { [weak self] succeeded in
            guard let self else { return }
            if succeeded {
                self.provider.replaceWithSavedLibrary(self.settings.library)
                self.provider.notice = "已重新读取配置。"
            } else { self.provider.error = self.settings.environmentNotice }
        }
    }

    func importEnvironment(_ url: URL) {
        guard !isComposing, !settings.isLoading, !settings.isImporting else { return }
        settings.loadEnvironmentFile(url) { [weak self] succeeded in
            guard let self else { return }
            if succeeded, let value = self.settings.importedConfiguration {
                self.provider.importConfiguration(value)
            } else { self.provider.error = self.settings.importNotice }
        }
    }
}
