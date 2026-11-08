import DraftCore
import Foundation

func runEnvironmentChecks() -> [String] {
    var failures: [String] = []
    func check(_ name: String, _ body: () throws -> Bool) {
        do {
            if try body() { print("PASS environment \(name)") }
            else { failures.append(name); print("FAIL environment \(name)") }
        } catch { failures.append(name); print("FAIL environment \(name)") }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("promptbridge-env-check-" + UUID().uuidString)
    let file = root.appendingPathComponent(".env.local")
    defer { try? FileManager.default.removeItem(at: root) }
    do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    catch { return ["environment fixture could not be created"] }
    func write(_ text: String, mode: Int = 0o600) throws {
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
    }
    check("plain data, quotes and no shell expansion") {
        let parsed = try LocalEnvironment.parse("# fixture\nexport DEEPSEEK_API_KEY='$(not-executed)'\nDEEPSEEK_MODEL=\"deepseek-flash\"\nIGNORED=value\n")
        return parsed["DEEPSEEK_API_KEY"] == "$(not-executed)" && parsed["DEEPSEEK_MODEL"] == "deepseek-flash" && parsed["IGNORED"] == nil
    }
    check("malformed or duplicate entries rejected") {
        for value in ["DEEPSEEK_API_KEY", "DEEPSEEK_API_KEY='unterminated", "DEEPSEEK_MODEL=a\nDEEPSEEK_MODEL=b"] {
            do { _ = try LocalEnvironment.parse(value); return false }
            catch EnvironmentFailure.malformed { }
        }
        return true
    }
    check("owner-only file and official defaults") {
        try write("DEEPSEEK_API_KEY=fixture-only-key\n")
        let configuration = try LocalEnvironment.configuration(fileURL: file, environment: [:])
        return configuration?.apiKey == "fixture-only-key" && configuration?.model == "deepseek-flash"
            && configuration?.baseURL == "https://api.deepseek.com"
    }
    check("insecure file rejected") {
        try write("DEEPSEEK_API_KEY=fixture-only-key\n", mode: 0o644)
        do { _ = try LocalEnvironment.configuration(fileURL: file, environment: [:]); return false }
        catch EnvironmentFailure.insecurePermissions { return true }
    }
    check("process key does not inherit file destination") {
        try write("DEEPSEEK_API_KEY=file-fixture\nDEEPSEEK_BASE_URL=https://other.example.invalid\n")
        let configuration = try LocalEnvironment.configuration(fileURL: file, environment: ["DEEPSEEK_API_KEY": "process-fixture"])
        return configuration?.apiKey == "process-fixture" && configuration?.baseURL == "https://api.deepseek.com"
    }
    check("nonofficial destination rejected") {
        do { _ = try LocalEnvironment.configuration(fileURL: file, environment: [:]); return false }
        catch EnvironmentFailure.wrongDestination { return true }
    }
    check("empty process key explicitly disables file configuration") {
        try LocalEnvironment.configuration(fileURL: file, environment: ["DEEPSEEK_API_KEY": ""]) == nil
    }
    check("missing file leaves demo available") {
        try LocalEnvironment.configuration(fileURL: root.appendingPathComponent("missing"), environment: [:]) == nil
    }
    check("oversized file rejected") {
        try write(String(repeating: "#", count: 16_385))
        do { _ = try LocalEnvironment.configuration(fileURL: file, environment: [:]); return false }
        catch EnvironmentFailure.malformed { return true }
    }
    return failures.map { "environment \($0)" }
}
