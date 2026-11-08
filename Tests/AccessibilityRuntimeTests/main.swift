import AccessibilityRuntime
import Foundation

@main @MainActor enum AccessibilityRuntimeCheckRunner {
    static func main() async {
        let results = await AccessibilityRuntimeFixtureChecks.run()
        for (name, passed) in results { print("\(passed ? "PASS" : "FAIL") \(name)") }
        let failures = results.filter { !$0.1 }
        print("AccessibilityRuntime: \(results.count - failures.count)/\(results.count) passed; fixture-only, no external app or model access.")
        if let index = CommandLine.arguments.firstIndex(of: "--output"), CommandLine.arguments.indices.contains(index + 1) {
            do {
                let data = try JSONSerialization.data(withJSONObject: ["checks": results.map { ["assertion": $0.0, "passed": $0.1] as [String: Any] }, "failures": failures.map(\.0)], options: [.sortedKeys, .prettyPrinted])
                try data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
            } catch { exit(2) }
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}
