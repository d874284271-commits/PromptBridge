import Combine
import DraftCore
import Foundation

@MainActor final class TranslationSettings: ObservableObject, DraftTranslator {
    typealias EnvironmentLoader = @Sendable (URL?, [String: String]) async throws -> ProviderConfiguration?
    enum EnvironmentLoadKind: Equatable { case automatic, userImport, savedConfiguration }

    @Published private(set) var configuration: ProviderConfiguration?
    @Published private(set) var presets: [ProviderPreset] = []
    @Published private(set) var activePresetID: UUID?
    @Published private(set) var environmentNotice: String?
    @Published private(set) var importedConfiguration: ProviderConfiguration?
    @Published private(set) var importNotice: String?
    @Published private(set) var isLoading = true
    @Published private(set) var isImporting = false
    @Published private(set) var activeLoadKind: EnvironmentLoadKind?
    @Published private(set) var preferences = TranslationPreferences()
    @Published private(set) var preferencesNotice: String?
    private(set) var configurationIdentity = UUID().uuidString
    let preferencesFileURL: URL?
    private var preferencesReadFailed = false
    var preferencesDidChange: (() -> Void)?
    var canEditPreferences: (() -> Bool)?
    let configFileURL: URL?
    private var loadID = UUID()
    private var loadTask: Task<Void, Never>?
    private var loadDeadline: Task<Void, Never>?
    private var storageReadFailed = false
    private let environmentLoader: EnvironmentLoader
    private let environmentTimeout: Duration
    private let fallbackFileURL: URL?
    private let fallbackEnvironment: [String: String]
    private let fallbackEnabled: Bool
    private let allowsDemo: Bool
    var canGenerate: Bool { configuration != nil || (allowsDemo && !isLoading && environmentNotice == nil) }
    var willChange: (() -> Void)?

    init(loadEnvironment: Bool = true,
         environmentLoader: @escaping EnvironmentLoader = TranslationSettings.defaultEnvironmentLoader,
         environmentTimeout: Duration = .seconds(5), configFileURL: URL? = nil,
         preferencesFileURL: URL? = nil, allowDemo: Bool = BuildFeatures.testing) {
        self.allowsDemo = BuildFeatures.testing && allowDemo
        self.environmentLoader = environmentLoader
        self.environmentTimeout = environmentTimeout
        self.fallbackEnabled = loadEnvironment
        let path = Bundle.main.object(forInfoDictionaryKey: "PromptBridgeEnvironmentFile") as? String
        fallbackFileURL = loadEnvironment ? path.map { URL(fileURLWithPath: $0) } : nil
        let names: Set<String> = ["DEEPSEEK_API_KEY", "DEEPSEEK_BASE_URL", "DEEPSEEK_MODEL"]
        fallbackEnvironment = loadEnvironment ? ProcessInfo.processInfo.environment.filter { names.contains($0.key) } : [:]
        let storedPath = loadEnvironment ? Bundle.main.object(forInfoDictionaryKey: "PromptBridgeConfigFile") as? String : nil
        #if PROMPTBRIDGE_TESTING
        self.configFileURL = configFileURL ?? storedPath.map { URL(fileURLWithPath: $0) }
        #else
        self.configFileURL = configFileURL ?? (loadEnvironment ? ApplicationStorage.providers : nil)
        #endif
        self.preferencesFileURL = preferencesFileURL ?? (loadEnvironment
            ? self.configFileURL?.deletingLastPathComponent().appendingPathComponent("preferences.json") : nil)
        reloadPreferences()
        if self.configFileURL != nil { reloadSavedConfiguration() }
        else if loadEnvironment { beginEnvironmentLoad(fallbackFileURL, environment: fallbackEnvironment, userSelected: false, completion: nil) }
        else { isLoading = false }
    }

    var library: ProviderLibrary { ProviderLibrary(presets: presets, activePresetID: activePresetID) }

    func saveLibrary(_ value: ProviderLibrary) throws {
        guard activeLoadKind != .savedConfiguration else { throw SettingsFailure("正在读取已保存配置，请稍后再保存。") }
        guard !storageReadFailed else {
            throw SettingsFailure("已保存配置未能读取，请修正配置文件后点击“重新读取配置”。")
        }
        try value.validate()
        if let configFileURL { try ProviderLibraryStore(fileURL: configFileURL).save(value) }
        cancelLoads()
        install(value)
        environmentNotice = nil
    }

    private func install(_ value: ProviderLibrary) {
        if configuration != value.activeConfiguration {
            willChange?()
            configurationIdentity = UUID().uuidString
        }
        presets = value.presets
        activePresetID = value.activePresetID
        configuration = value.activeConfiguration
    }

    func reloadSavedConfiguration(completion: ((Bool) -> Void)? = nil) {
        guard let configFileURL else { return }
        let store = ProviderLibraryStore(fileURL: configFileURL)
        startLoad(kind: .savedConfiguration, completion: completion) {
            await Task.detached {
                do { return LoadOutcome.library(try store.load()) }
                catch { return LoadOutcome.failure((error as? LocalizedError)?.errorDescription ?? "已保存配置读取失败。") }
            }.value
        }
    }

    func loadEnvironmentFile(_ url: URL, completion: ((Bool) -> Void)? = nil) {
        importedConfiguration = nil
        importNotice = nil
        beginEnvironmentLoad(url, environment: [:], userSelected: true, completion: completion)
    }

    func cancelEnvironmentImport() {
        guard isImporting else { return }
        cancelLoads()
        importNotice = nil
    }

    private enum LoadOutcome: Sendable {
        case configuration(ProviderConfiguration?), library(ProviderLibrary?)
        case failure(String), timeout, cancelled
    }

    private func beginEnvironmentLoad(_ url: URL?, environment: [String: String], userSelected: Bool,
                                      completion: ((Bool) -> Void)?) {
        let loader = environmentLoader
        startLoad(kind: userSelected ? .userImport : .automatic, completion: completion) {
            do { return .configuration(try await loader(url, environment)) }
            catch is CancellationError { return .cancelled }
            catch { return .failure((error as? LocalizedError)?.errorDescription ?? "本地模型配置无效。") }
        }
    }

    private func startLoad(kind: EnvironmentLoadKind, completion: ((Bool) -> Void)?,
                           operation: @escaping @Sendable () async -> LoadOutcome) {
        loadTask?.cancel()
        loadDeadline?.cancel()
        let id = UUID()
        loadID = id
        isLoading = kind != .userImport
        isImporting = kind == .userImport
        activeLoadKind = kind
        if kind == .userImport { importNotice = "正在导入到配置草稿…" }
        else { environmentNotice = kind == .savedConfiguration ? "正在读取已保存配置…" : "正在读取本地环境配置…" }
        loadTask = Task { [weak self] in
            let outcome = await operation()
            guard let self, self.loadID == id else { return }
            self.loadDeadline?.cancel()
            self.finishLoad(outcome, kind: kind, completion: completion)
        }
        loadDeadline = Task { [weak self] in
            do { try await Task.sleep(for: self?.environmentTimeout ?? .seconds(5)) }
            catch { return }
            guard let self, self.loadID == id, self.isLoading || self.isImporting else { return }
            self.loadID = UUID()
            self.loadTask?.cancel()
            self.finishLoad(.timeout, kind: kind, completion: completion)
        }
    }

    private func finishLoad(_ outcome: LoadOutcome, kind: EnvironmentLoadKind, completion: ((Bool) -> Void)?) {
        isLoading = false
        isImporting = false
        activeLoadKind = nil
        loadTask = nil
        loadDeadline = nil
        if kind == .userImport {
            switch outcome {
            case .configuration(let value):
                importedConfiguration = value
                importNotice = value == nil ? "所选文件没有有效的 DEEPSEEK_API_KEY。" : nil
                completion?(value != nil)
            case .failure(let message): importNotice = message; completion?(false)
            case .timeout: importNotice = "读取所选环境文件超时，请重试。"; completion?(false)
            case .cancelled: completion?(false)
            case .library: completion?(false)
            }
            return
        }
        switch outcome {
        case .library(let value):
            storageReadFailed = false
            if let value {
                install(value)
                environmentNotice = nil
                completion?(true)
            } else if fallbackEnabled {
                beginEnvironmentLoad(fallbackFileURL, environment: fallbackEnvironment, userSelected: false, completion: completion)
            } else {
                install(ProviderLibrary())
                environmentNotice = nil
                completion?(true)
            }
        case .configuration(let value):
            guard let value else {
                environmentNotice = kind == .userImport ? "所选文件没有有效的 DEEPSEEK_API_KEY。" : nil
                completion?(false)
                return
            }
            var updated = library
            if let id = updated.activePresetID, let index = updated.presets.firstIndex(where: { $0.id == id }) {
                updated.presets[index].configuration = value
            } else {
                let imported = ProviderPreset(name: "导入配置", configuration: value)
                updated.presets.append(imported)
                updated.activePresetID = imported.id
            }
            install(updated)
            environmentNotice = nil
            completion?(true)
        case .failure(let message):
            if kind == .savedConfiguration { storageReadFailed = true }
            environmentNotice = message
            completion?(false)
        case .timeout:
            if kind == .savedConfiguration { storageReadFailed = true }
            environmentNotice = kind == .userImport ? "读取所选环境文件超时，请重试。"
                : "配置读取超时，请在设置中重新读取配置或选择环境文件。"
            completion?(false)
        case .cancelled: completion?(false)
        }
    }

    private func cancelLoads() {
        loadID = UUID()
        loadTask?.cancel()
        loadDeadline?.cancel()
        loadTask = nil
        loadDeadline = nil
        isLoading = false
        isImporting = false
        activeLoadKind = nil
    }

    private static let defaultEnvironmentLoader: EnvironmentLoader = { url, environment in
        try await Task.detached {
            let scoped = url?.startAccessingSecurityScopedResource() == true
            defer { if scoped { url?.stopAccessingSecurityScopedResource() } }
            return try LocalEnvironment.configuration(fileURL: url, environment: environment)
        }.value
    }

    var isDemo: Bool { allowsDemo && configuration == nil }
    var description: String {
        if isLoading && configuration == nil { return "正在加载配置…" }
        if environmentNotice != nil && configuration == nil { return "配置未加载 · 请打开设置" }
        guard let configuration else { return isDemo ? "本地演示 · 固定示例结果" : "尚未配置模型" }
        let name = presets.first(where: { $0.id == activePresetID })?.name ?? "自定义供应商"
        return "\(name) · \(configuration.model)"
    }
    var progressMessage: String { isDemo ? "正在生成本地演示结果…" : "正在生成译文…" }

    // Internal fixture compatibility. The settings page persists through saveLibrary.
    func apply(_ value: ProviderConfiguration?) throws {
        if let value { _ = try value.endpointURL() }
        cancelLoads()
        var updated = library
        if let value {
            if let id = updated.activePresetID, let index = updated.presets.firstIndex(where: { $0.id == id }) {
                updated.presets[index].configuration = value
            } else {
                let preset = ProviderPreset(name: "当前配置", configuration: value)
                updated.presets.append(preset)
                updated.activePresetID = preset.id
            }
        } else { updated.activePresetID = nil }
        install(updated)
        environmentNotice = nil
    }

    func generate(_ request: GenerationRequest) async throws -> String {
        try Task.checkCancellation()
        guard canGenerate else { throw TranslationFailure.configuration }
        guard let configuration else {
            #if PROMPTBRIDGE_TESTING
            if allowsDemo { return try await DemoTranslator().generate(request) }
            #endif
            throw TranslationFailure.configuration
        }
        return try await ModelAPIClient().generate(request, using: configuration)
    }

    @discardableResult func reloadPreferences() -> Bool {
        guard canEditPreferences?() != false else { return false }
        do {
            let value = try preferencesFileURL.flatMap { try TranslationPreferencesStore(fileURL: $0).load() }
                ?? TranslationPreferences()
            let changed = value != preferences
            preferences = value
            preferencesReadFailed = false
            preferencesNotice = nil
            if changed { preferencesDidChange?() }
            return true
        } catch {
            preferencesReadFailed = true
            preferencesNotice = error.localizedDescription
            return false
        }
    }

    func savePreferences(_ proposed: TranslationPreferences) throws {
        guard canEditPreferences?() != false else { throw SettingsFailure("请先完成当前替换或输入法操作。") }
        guard !preferencesReadFailed else { throw SettingsFailure("偏好文件未能读取，请修正后重新读取；原文件不会被覆盖。") }
        var value = proposed
        value.targetLanguage = value.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        try value.validate()
        if let preferencesFileURL { try TranslationPreferencesStore(fileURL: preferencesFileURL).save(value) }
        let changed = preferences != value
        preferences = value
        preferencesNotice = nil
        if changed { preferencesDidChange?() }
    }

    func setDefaultLanguage(_ language: String) throws {
        var updated = preferences
        updated.targetLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        try savePreferences(updated)
    }
}

struct SettingsFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension APIFormat {
    var displayName: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        case .anthropicMessages: "Messages"
        }
    }
}
