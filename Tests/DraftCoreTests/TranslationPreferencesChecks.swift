import DraftCore
import Foundation

func runTranslationPreferencesChecks() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ body: () throws -> Bool) {
        do {
            if try body() { print("PASS preferences \(name)") }
            else { failures.append("preferences \(name)"); print("FAIL preferences \(name)") }
        } catch {
            failures.append("preferences \(name)")
            print("FAIL preferences \(name): \(error.localizedDescription)")
        }
    }
    func rejects(_ expected: TranslationPreferencesError, _ operation: () throws -> Void) -> Bool {
        do { try operation(); return false }
        catch let error as TranslationPreferencesError { return error == expected }
        catch { return false }
    }

    let defaults = TranslationPreferences()
    check("Auto defaults on for legacy preferences and preserves explicit off") {
        let encoded = try JSONEncoder().encode(defaults)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "automaticTranslationAndReplacement")
        let migrated = try JSONDecoder().decode(TranslationPreferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        let disabled = TranslationPreferences(automaticTranslationAndReplacement: false)
        let restored = try JSONDecoder().decode(TranslationPreferences.self, from: JSONEncoder().encode(disabled))
        return defaults.automaticTranslationAndReplacement && migrated == defaults && restored == disabled
    }
    check("defaults retain translation and optimization safeguards") {
        try defaults.validate()
        let translate = try defaults.render(intent: .translate, targetLanguage: defaults.targetLanguage)
        let optimize = try defaults.render(intent: .optimize, targetLanguage: defaults.targetLanguage)
        return defaults.targetLanguage == "English" && defaults.launcherMode == .persistent
            && translate.contains("faithful English draft") && translate.contains("negations, uncertainty")
            && optimize.contains("complete English draft") && optimize.contains("Never invent or add requirements")
            && optimize.contains("Do not resolve ambiguity or uncertainty by guessing") && translate != optimize
    }
    check("language names are trimmed without a language allowlist") {
        let request = try GenerationRequest(source: "  原文\n{{target_language}}  ", intent: .translate,
            targetLanguage: "  日本語（技術文書） \n", template: "Write in {{target_language}}; output {{target_language}}.")
        return request.targetLanguage == "日本語（技術文書）"
            && request.instructions == "Write in 日本語（技術文書）; output 日本語（技術文書）."
            && request.source == "  原文\n{{target_language}}  "
    }
    check("language insertion is one pass and does not evaluate other placeholders") {
        let request = try GenerationRequest(source: "source", intent: .translate,
            targetLanguage: "Language {{target_language}}", template: "{{target_language}} | {{source}}")
        return request.instructions == "Language {{target_language}} | {{source}}"
    }
    check("empty language, empty templates, and missing variable are rejected") {
        let emptyLanguage = TranslationPreferences(targetLanguage: " \n\t ")
        let emptyTemplate = TranslationPreferences(translationTemplate: " \n ")
        let missingVariable = TranslationPreferences(optimizationTemplate: "Rewrite in English.")
        return rejects(.emptyTargetLanguage) { try emptyLanguage.validate() }
            && rejects(.emptyTemplate) { try emptyTemplate.validate() }
            && rejects(.missingTargetLanguageVariable) { try missingVariable.validate() }
    }
    check("request rejects empty source before contacting a provider") {
        do {
            _ = try GenerationRequest(source: " \n ", intent: .translate,
                targetLanguage: "English", template: defaults.translationTemplate)
            return false
        } catch let failure as TranslationFailure { return failure == .emptySource }
    }
    check("request snapshots instructions independently of later preference edits") {
        var edited = defaults
        let original = try GenerationRequest(source: "draft", intent: .optimize,
            targetLanguage: "Esperanto", template: edited.optimizationTemplate)
        edited.optimizationTemplate = "Changed {{target_language}}"
        edited.targetLanguage = "中文"
        return original.targetLanguage == "Esperanto" && original.instructions.contains("complete Esperanto draft")
            && original.templateRevision == defaults.templateRevision(for: .optimize)
            && original.templateRevision != edited.templateRevision(for: .optimize)
    }
    check("template revisions use deterministic SHA256 of exact template bytes") {
        let simple = TranslationPreferences(translationTemplate: "{{target_language}}")
        var changed = simple
        changed.optimizationTemplate += "\n"
        changed.targetLanguage = "Français"
        return simple.templateRevision(for: .translate) == "38d698793e08c97aeecc9b266ca6fb605ff3d7b45270ecb1d9430418ac30e269"
            && changed.templateRevision(for: .translate) == simple.templateRevision(for: .translate)
            && changed.templateRevision(for: .optimize) != simple.templateRevision(for: .optimize)
    }

    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("promptbridge-preferences-" + UUID().uuidString,
        isDirectory: true)
    defer { try? manager.removeItem(at: root) }
    let file = root.appendingPathComponent("config/app-preferences.json")
    let store = TranslationPreferencesStore(fileURL: file)
    let custom = TranslationPreferences(targetLanguage: "Português (Brasil)",
        translationTemplate: "Translate into {{target_language}}. Preserve code.",
        optimizationTemplate: "Rewrite into {{target_language}}. Preserve uncertainty.", launcherMode: .focusedInput,
        automaticTranslationAndReplacement: false)
    check("missing preference file returns nil without creating files") {
        try store.load() == nil && !manager.fileExists(atPath: root.path)
    }
    check("preferences round trip including both templates and launcher mode") {
        try store.save(custom)
        return try TranslationPreferencesStore(fileURL: file).load() == custom
    }
    check("valid updates replace the file and leave no temporary sibling") {
        try store.save(defaults)
        let children = try manager.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        return try store.load() == defaults && children == [file.lastPathComponent]
    }
    check("invalid edits leave the saved preferences unchanged") {
        let before = try Data(contentsOf: file)
        let invalid = TranslationPreferences(translationTemplate: "Missing language variable")
        return try rejects(.missingTargetLanguageVariable) { try store.save(invalid) }
            && (try Data(contentsOf: file)) == before
    }
    check("malformed stored JSON is reported without overwrite or fallback") {
        let malformed = root.appendingPathComponent("malformed.json")
        let original = Data("{\"template\":\"PRIVATE_TEMPLATE".utf8)
        try original.write(to: malformed)
        let other = TranslationPreferencesStore(fileURL: malformed)
        return try rejects(.malformed) { _ = try other.load() }
            && (try Data(contentsOf: malformed)) == original
    }
    check("invalid saved template is rejected instead of loading partial defaults") {
        let invalidFile = root.appendingPathComponent("invalid.json")
        let invalid = TranslationPreferences(optimizationTemplate: "No variable")
        try JSONEncoder().encode(invalid).write(to: invalidFile)
        return rejects(.missingTargetLanguageVariable) { _ = try TranslationPreferencesStore(fileURL: invalidFile).load() }
    }
    check("directory and symlink paths are rejected without changing targets") {
        let linked = root.appendingPathComponent("linked.json")
        try manager.createSymbolicLink(at: linked, withDestinationURL: file)
        let before = try Data(contentsOf: file)
        let linkedStore = TranslationPreferencesStore(fileURL: linked)
        let directoryStore = TranslationPreferencesStore(fileURL: root)
        return try rejects(.notRegularFile) { _ = try linkedStore.load() }
            && rejects(.notRegularFile) { try linkedStore.save(custom) }
            && rejects(.notRegularFile) { _ = try directoryStore.load() }
            && rejects(.notRegularFile) { try directoryStore.save(custom) }
            && (try Data(contentsOf: file)) == before
    }
    return failures
}
