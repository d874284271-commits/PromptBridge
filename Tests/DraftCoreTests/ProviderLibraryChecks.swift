import Darwin
import DraftCore
import Foundation

func runProviderLibraryChecks() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ body: () throws -> Bool) {
        do {
            if try body() { print("PASS providers \(name)") }
            else { failures.append("providers \(name)"); print("FAIL providers \(name)") }
        } catch {
            failures.append("providers \(name)")
            print("FAIL providers \(name): \(error.localizedDescription)")
        }
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("promptbridge-provider-library-" + UUID().uuidString, isDirectory: true)
    let nestedFile = root.appendingPathComponent("config/providers.json")
    let fileManager = FileManager.default
    defer { try? fileManager.removeItem(at: root) }

    do {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    } catch {
        return ["providers fixture directory could not be created"]
    }

    func configuration(_ format: APIFormat = .chatCompletions, baseURL: String = "https://customproxy.invalid/v1",
                       model: String = "custom-model", key: String = "fixture-key",
                       modelsPath: String = "models") -> ProviderConfiguration {
        ProviderConfiguration(format: format, baseURL: baseURL, model: model,
                              apiKey: key, modelsPath: modelsPath)
    }

    let deepSeek = ProviderPreset(name: "DeepSeek", configuration: configuration(model: "deepseek-flash"))
    let custom = ProviderPreset(name: "123", configuration: configuration(.anthropicMessages,
        baseURL: "https://customproxy.invalid/provider", model: "custom-anthropic", key: "custom-key",
        modelsPath: "catalog/models"))
    let inactive = ProviderPreset(name: "待选择模型", configuration: configuration(.responses,
        baseURL: "https://customproxy.invalid/provider", model: "", key: "inactive-key"))

    check("自定义供应商独立保存消息格式地址密钥和模型") {
        let library = ProviderLibrary(presets: [custom], activePresetID: custom.id)
        try library.validate()
        guard let active = library.activeConfiguration else { return false }
        return custom.name == "123" && active.format == .anthropicMessages
            && active.baseURL == "https://customproxy.invalid/provider"
            && active.apiKey == "custom-key" && active.model == "custom-anthropic"
    }

    check("非当前预设允许空模型并保留连接") {
        let library = ProviderLibrary(presets: [deepSeek, inactive], activePresetID: deepSeek.id)
        try library.validate()
        return inactive.configuration.model.isEmpty
            && (try? inactive.configuration.connectionURL(appending: inactive.configuration.modelsPath)) != nil
    }

    var edited = ProviderLibrary(presets: [deepSeek, custom, inactive], activePresetID: custom.id)
    check("列表增删编辑重命名和当前预设") {
        guard edited.activeConfiguration == custom.configuration else { return false }
        edited.presets[0].name = "DeepSeek 改名"
        edited.presets.removeAll(where: { $0.id == inactive.id })
        edited.activePresetID = edited.presets[0].id
        return edited.presets.count == 2 && edited.presets[0].name == "DeepSeek 改名"
            && edited.activeConfiguration == edited.presets[0].configuration
    }

    let store = ProviderLibraryStore(fileURL: nestedFile)
    check("保存并重启读取保留选中模型和密钥") {
        try store.save(edited)
        guard let loaded = try store.load() else { return false }
        return loaded == edited && loaded.activeConfiguration?.model == edited.activeConfiguration?.model
            && loaded.activeConfiguration?.apiKey == edited.activeConfiguration?.apiKey
    }

    check("保存文件使用 owner-only 0600 权限") {
        let attributes = try fileManager.attributesOfItem(atPath: nestedFile.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600
    }

    check("缺少文件返回 nil") {
        let missing = ProviderLibraryStore(fileURL: root.appendingPathComponent("missing/providers.json"))
        return try missing.load() == nil
    }

    func writeFixture(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    let malformedFile = root.appendingPathComponent("malformed.json")
    check("坏 JSON 拒绝且不泄漏 Key") {
        try writeFixture(Data(#"{"apiKey":"SECRET_PROVIDER_KEY"}"#.utf8), to: malformedFile)
        do {
            _ = try ProviderLibraryStore(fileURL: malformedFile).load()
            return false
        } catch {
            return error is ProviderLibraryError && !error.localizedDescription.contains("SECRET_PROVIDER_KEY")
        }
    }

    let insecureFile = root.appendingPathComponent("insecure.json")
    check("不安全权限拒绝") {
        try writeFixture(Data(#"{"version":1,"presets":[],"activePresetID":null}"#.utf8), to: insecureFile, mode: 0o644)
        do {
            _ = try ProviderLibraryStore(fileURL: insecureFile).load()
            return false
        } catch ProviderLibraryError.insecurePermissions { return true }
        catch { return false }
    }

    let versionFile = root.appendingPathComponent("version.json")
    check("未知版本拒绝") {
        try writeFixture(Data(#"{"version":2,"presets":[],"activePresetID":null}"#.utf8), to: versionFile)
        do {
            _ = try ProviderLibraryStore(fileURL: versionFile).load()
            return false
        } catch ProviderLibraryError.unsupportedVersion(2) { return true }
        catch { return false }
    }

    let missingActiveFile = root.appendingPathComponent("missing-active.json")
    check("当前预设 ID 缺失拒绝") {
        let invalid = ProviderLibrary(presets: [deepSeek], activePresetID: UUID())
        let data = try JSONEncoder().encode(invalid)
        try writeFixture(data, to: missingActiveFile)
        do {
            _ = try ProviderLibraryStore(fileURL: missingActiveFile).load()
            return false
        } catch ProviderLibraryError.missingActivePreset { return true }
        catch { return false }
    }

    check("名称为空拒绝") {
        let invalid = ProviderLibrary(presets: [ProviderPreset(name: " \n", configuration: deepSeek.configuration)])
        do { try invalid.validate(); return false }
        catch ProviderLibraryError.emptyName { return true }
        catch { return false }
    }

    check("重复 ID 拒绝") {
        let duplicate = ProviderPreset(id: deepSeek.id, name: "duplicate", configuration: custom.configuration)
        do { try ProviderLibrary(presets: [deepSeek, duplicate]).validate(); return false }
        catch ProviderLibraryError.duplicateID { return true }
        catch { return false }
    }

    check("当前预设空模型拒绝") {
        let invalid = ProviderPreset(name: "empty", configuration: inactive.configuration)
        do { try ProviderLibrary(presets: [invalid], activePresetID: invalid.id).validate(); return false }
        catch ProviderLibraryError.invalidConfiguration { return true }
        catch { return false }
    }

    check("无效保存不破坏旧文件") {
        guard let before = try store.load() else { return false }
        let invalid = ProviderLibrary(presets: [ProviderPreset(name: "empty", configuration: inactive.configuration)],
                                      activePresetID: inactive.id)
        do { try store.save(invalid); return false }
        catch { return try store.load() == before }
    }

    let symlinkTarget = root.appendingPathComponent("symlink-target.json")
    let symlinkPath = root.appendingPathComponent("symlink.json")
    check("symlink 不读取也不替换目标文件") {
        try store.save(edited)
        try fileManager.copyItem(at: nestedFile, to: symlinkTarget)
        guard Darwin.symlink(symlinkTarget.path, symlinkPath.path) == 0 else { return false }
        do {
            _ = try ProviderLibraryStore(fileURL: symlinkPath).load()
            return false
        } catch ProviderLibraryError.notRegularFile { }
        catch { return false }
        do { try ProviderLibraryStore(fileURL: symlinkPath).save(edited); return false }
        catch ProviderLibraryError.notRegularFile { }
        catch { return false }
        return try ProviderLibraryStore(fileURL: symlinkTarget).load() == edited
    }

    return failures
}
