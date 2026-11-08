import DraftCore
import Combine
import Foundation

/// The settings window edits its own copy. Only an explicit save changes the library.
@MainActor final class ProviderEditor: ObservableObject {
    typealias ModelsLoader = @Sendable (ProviderConfiguration) async throws -> [ModelOption]
    @Published var form: ProviderPreset
    @Published var presets: [ProviderPreset]
    @Published var useAPI: Bool
    @Published private(set) var models: [ModelOption] = []
    @Published private(set) var isFetchingModels = false
    @Published var error: String?
    @Published var notice: String?
    enum Field: String, Hashable { case name, baseURL, apiKey, model, modelsPath }
    struct FieldIssue: Equatable {
        let presetID: UUID
        let field: Field
        let message: String
    }
    @Published private(set) var fieldIssue: FieldIssue?
    @Published private(set) var modelListError: String?
    @Published private(set) var modelListNotice: String?
    private var baseline: ProviderLibrary
    private var originalForm: ProviderPreset
    private var deletedIDs: Set<UUID> = []
    private let modelsLoader: ModelsLoader
    private var modelsTask: Task<Void, Never>?
    private var modelsRequestID = UUID()

    init(library: ProviderLibrary, modelsLoader: @escaping ModelsLoader) {
        baseline = library
        presets = library.presets
        useAPI = !BuildFeatures.testing || library.activePresetID != nil
        let initial = library.presets.first(where: { $0.id == library.activePresetID }) ?? library.presets.first ?? Self.blankPreset()
        form = initial
        originalForm = initial
        self.modelsLoader = modelsLoader
    }

    private static func blankPreset() -> ProviderPreset {
        ProviderPreset(name: "", configuration: ProviderConfiguration(format: .chatCompletions, baseURL: "", model: "", apiKey: ""))
    }
    var hasChanges: Bool { editedPresets != baseline.presets || useAPI != (!BuildFeatures.testing || baseline.activePresetID != nil) }
    var hasPresetChanges: Bool { editedPresets != baseline.presets }
    var removesActivePreset: Bool { baseline.activePresetID.map { deletedIDs.contains($0) } ?? false }
    private var editedPresets: [ProviderPreset] {
        var values = presets
        if hasFormContent || values.contains(where: { $0.id == form.id }) {
            if let index = values.firstIndex(where: { $0.id == form.id }) { values[index] = form }
            else { values.append(form) }
        }
        return values
    }
    private var hasFormContent: Bool { !form.name.isEmpty || !form.configuration.baseURL.isEmpty || !form.configuration.apiKey.isEmpty || !form.configuration.model.isEmpty }

    func synchronize(_ library: ProviderLibrary) {
        guard library != baseline else { return }
        if !hasChanges {
            cancelModels()
            presets = library.presets
            form = library.presets.first(where: { $0.id == library.activePresetID }) ?? library.presets.first ?? Self.blankPreset()
            originalForm = form
            useAPI = !BuildFeatures.testing || library.activePresetID != nil
        } else {
            // Merge a startup load without dropping edits made while it was pending.
            for incoming in library.presets where !deletedIDs.contains(incoming.id) {
                if !presets.contains(where: { $0.id == incoming.id }) { presets.append(incoming) }
            }
        }
        baseline = library
    }

    private func stashForm() {
        guard hasFormContent || presets.contains(where: { $0.id == form.id }) else { return }
        if let index = presets.firstIndex(where: { $0.id == form.id }) { presets[index] = form }
        else { presets.append(form) }
    }
    func select(_ id: UUID) {
        guard id != form.id, let next = presets.first(where: { $0.id == id }) else { return }
        stashForm()
        cancelModels()
        form = next
        originalForm = next
        error = nil
        notice = nil
        fieldIssue = nil
    }
    func add() {
        stashForm()
        cancelModels()
        form = Self.blankPreset()
        originalForm = form
        useAPI = true
        error = nil
        notice = nil
        fieldIssue = nil
    }
    func delete() {
        let id = form.id
        presets.removeAll { $0.id == id }
        deletedIDs.insert(id)
        cancelModels()
        form = presets.first ?? Self.blankPreset()
        originalForm = form
        error = nil
        fieldIssue = nil
        notice = "删除将在保存后生效。"
    }

    func libraryForSave(activeID: UUID?) -> ProviderLibrary {
        stashForm()
        let validActive = activeID.flatMap { id in presets.contains(where: { $0.id == id }) ? id : nil }
        return ProviderLibrary(presets: presets, activePresetID: validActive)
    }
    func didSave(_ library: ProviderLibrary) {
        baseline = library
        presets = library.presets
        originalForm = form
        deletedIDs.removeAll()
        error = nil
        fieldIssue = nil
        notice = "预设已保存。"
    }

    func setBaseURL(_ value: String) {
        if origin(form.configuration.baseURL) != origin(value) { form.configuration.apiKey = "" }
        form.configuration.baseURL = value
        cancelModels()
        error = nil
        fieldIssue = nil
    }
    func setFormat(_ value: APIFormat) {
        form.configuration.format = value
        cancelModels()
        error = nil
        fieldIssue = nil
    }
    func setKey(_ value: String) {
        form.configuration.apiKey = value
        cancelModels()
        error = nil
        fieldIssue = nil
    }
    func setModelsPath(_ value: String) {
        form.configuration.modelsPath = value
        cancelModels()
        error = nil
        fieldIssue = nil
    }
    private func origin(_ value: String) -> String? {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(parts.port ?? (scheme == "https" ? 443 : 80))"
    }
    private func connection(_ value: ProviderConfiguration) -> ProviderConfiguration {
        var value = value
        value.model = ""
        return value
    }
    func cancelModels() {
        modelsRequestID = UUID()
        modelsTask?.cancel()
        modelsTask = nil
        isFetchingModels = false
        models = []
        modelListError = nil
        modelListNotice = nil
    }
    func replaceWithSavedLibrary(_ library: ProviderLibrary) {
        cancelModels()
        baseline = library
        presets = library.presets
        form = library.presets.first(where: { $0.id == library.activePresetID }) ?? library.presets.first ?? Self.blankPreset()
        originalForm = form
        useAPI = !BuildFeatures.testing || library.activePresetID != nil
        deletedIDs.removeAll()
        fieldIssue = nil
        error = nil
        notice = nil
    }

    func importConfiguration(_ configuration: ProviderConfiguration) {
        stashForm()
        cancelModels()
        form = ProviderPreset(name: "导入配置", configuration: configuration)
        presets.append(form)
        originalForm = form
        useAPI = true
        fieldIssue = nil
        error = nil
        notice = "配置已导入草稿，保存后生效。"
    }

    func validateForSave(_ library: ProviderLibrary) -> Bool {
        fieldIssue = nil
        error = nil
        for preset in library.presets {
            let issue: FieldIssue?
            if preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issue = FieldIssue(presetID: preset.id, field: .name, message: "请填写供应商名称。")
            } else if let detail = preset.configuration.validationIssue(requiringModel: preset.id == library.activePresetID) {
                issue = FieldIssue(presetID: preset.id, field: Field(rawValue: detail.field.rawValue)!, message: detail.message)
            } else { issue = nil }
            if let issue {
                select(preset.id)
                fieldIssue = issue
                return false
            }
        }
        return true
    }

    func fetchModels() {
        cancelModels()
        let configuration = connection(form.configuration)
        if let detail = configuration.validationIssue(requiringModel: false) {
            fieldIssue = FieldIssue(presetID: form.id, field: Field(rawValue: detail.field.rawValue)!, message: detail.message)
            return
        }
        let request = UUID()
        let presetID = form.id
        modelsRequestID = request
        isFetchingModels = true
        fieldIssue = nil
        modelListError = nil
        modelListNotice = nil
        modelsTask = Task { [weak self, modelsLoader] in
            do {
                let result = try await modelsLoader(configuration)
                guard let self, self.modelsRequestID == request, self.form.id == presetID,
                      self.connection(self.form.configuration) == configuration else { return }
                self.modelsTask = nil
                self.isFetchingModels = false
                self.models = result
                self.modelListNotice = result.isEmpty ? "接口没有返回模型，可手动填写模型 ID。" : "已获取 \(result.count) 个模型。"
            } catch {
                guard let self, self.modelsRequestID == request else { return }
                self.modelsTask = nil
                self.isFetchingModels = false
                self.modelListError = ((error as? LocalizedError)?.errorDescription ?? "模型列表获取失败。") + " 可手动填写模型 ID，或检查模型列表路径。"
            }
        }
    }
}
