import DraftCore
import Foundation
import CryptoKit

/// An explicit batch entry point. Offline preparation never loads provider credentials.
enum ProviderEvaluation {
    struct Case: Codable, Equatable {
        let id: String
        let category: String
        let direction: String
        let intent: String
        let targetLanguage: String
        let source: String
        let requiredLiterals: [String]
        let semanticChecks: [String]
        let forbiddenAdditions: [String]
    }
    struct Suite: Codable, Equatable { let version: Int; let cases: [Case] }
    struct Model: Codable, Equatable {
        let name: String
        let format: APIFormat
        let serviceOrigin: String
        let routeRevision: String
    }
    struct Result: Codable {
        let caseID: String
        let templateRevision: String
        var output: String?
        var missingLiterals: [String]?
        var error: String?
    }
    struct Report: Codable {
        let version: Int
        let runID: UUID
        let mode: String
        let label: String
        let startedAt: Date
        let suite: Suite
        let model: Model?
        var requestCount: Int
        var status: String
        let semanticStatus: String
        var results: [Result]
        var resumedFromRunID: UUID?
        var resumedRequestCount: Int?
    }
    private enum Failure: Error {
        case arguments, invalidSuite, invalidTemplates, configuration, existingOutput, incompatibleBaseline
        case incompatibleResume, requestBudget
    }
    private struct Options {
        var values: [String: String] = [:]
        var flags: Set<String> = []
        init(_ arguments: [String]) throws {
            let valueNames: Set<String> = ["--cases", "--output", "--provider-library", "--env-file",
                "--templates", "--mock-url", "--format", "--label", "--baseline-report",
                "--expected-model", "--expected-service-host", "--resume-report", "--request-budget"]
            let flagNames: Set<String> = ["--dry-run", "--live"]
            var index = 0
            while index < arguments.count {
                let name = arguments[index]
                if flagNames.contains(name) {
                    guard flags.insert(name).inserted else { throw Failure.arguments }
                    index += 1
                } else {
                    guard valueNames.contains(name), values[name] == nil,
                          arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
                        throw Failure.arguments
                    }
                    values[name] = arguments[index + 1]
                    index += 2
                }
            }
            guard values["--cases"] != nil, values["--output"] != nil,
                  [flags.contains("--dry-run"), flags.contains("--live"), values["--mock-url"] != nil]
                    .filter({ $0 }).count == 1 else { throw Failure.arguments }
            let sources = [values["--provider-library"], values["--env-file"]].compactMap { $0 }
            guard flags.contains("--live") ? sources.count == 1 : sources.isEmpty,
                  values["--format"] == nil || values["--mock-url"] != nil,
                  (values["--expected-model"] == nil && values["--expected-service-host"] == nil) || flags.contains("--live"),
                  values["--label"] == nil || ["baseline", "candidate"].contains(values["--label"]!),
                  values["--baseline-report"] == nil || values["--label"] == "candidate",
                  values["--label"] != "candidate" || values["--baseline-report"] != nil,
                  values["--resume-report"] == nil || (values["--request-budget"] != nil && !flags.contains("--dry-run")),
                  values["--request-budget"] == nil || (!flags.contains("--dry-run") &&
                    (Int(values["--request-budget"]!) ?? 0) > 0) else {
                throw Failure.arguments
            }
        }
    }
    static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try Options(arguments)
            let suite: Suite = try decode(options.values["--cases"]!)
            try validate(suite)
            let preferences: TranslationPreferences
            if let path = options.values["--templates"] {
                guard let loaded = try TranslationPreferencesStore(fileURL: URL(fileURLWithPath: path)).load() else {
                    throw Failure.invalidTemplates
                }
                preferences = loaded
            } else { preferences = TranslationPreferences() }
            let output = URL(fileURLWithPath: options.values["--output"]!, isDirectory: true)
            guard !FileManager.default.fileExists(atPath: output.path) else {
                throw Failure.existingOutput
            }
            let configuration = try configuration(options)
            if let configuration {
                guard options.values["--expected-model"].map({ $0 == configuration.model.trimmingCharacters(in: .whitespacesAndNewlines) }) ?? true,
                      options.values["--expected-service-host"].map({ $0 == (try? configuration.endpointURL().host) }) ?? true else {
                    throw Failure.configuration
                }
            }
            let model = try configuration.map {
                let endpoint = try $0.endpointURL()
                var origin = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
                origin.path = ""; origin.query = nil; origin.fragment = nil
                return Model(name: $0.model.trimmingCharacters(in: .whitespacesAndNewlines), format: $0.format,
                      serviceOrigin: origin.string!,
                      routeRevision: SHA256.hash(data: Data(endpoint.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined())
            }
            let baseline: Report?
            if let path = options.values["--baseline-report"] {
                let loaded: Report = try decode(path)
                guard loaded.version == 1, loaded.label == "baseline", loaded.suite == suite, loaded.model == model,
                      loaded.mode == (options.flags.contains("--live") ? "live" : "mock"),
                      ["completed", "completedWithLiteralFailures"].contains(loaded.status),
                      loaded.results.count == suite.cases.count,
                      loaded.requestCount >= suite.cases.count,
                      zip(loaded.results, suite.cases).allSatisfy({ $0.caseID == $1.id && $0.output != nil && $0.error == nil }) else {
                    throw Failure.incompatibleBaseline
                }
                for intent in DraftIntent.allCases {
                    let revisions = zip(loaded.results, suite.cases)
                        .filter { pair in pair.1.intent == intent.rawValue }.map { pair in pair.0.templateRevision }
                    guard Set(revisions).count == 1,
                          revisions.allSatisfy({ $0.count == 64 && $0.allSatisfy({ "0123456789abcdef".contains($0) }) }) else {
                        throw Failure.incompatibleBaseline
                    }
                }
                baseline = loaded
            } else { baseline = nil }
            // Snapshot every request before the first model call; no config/template rereads.
            let requests = try suite.cases.map { value in
                try GenerationRequest(source: value.source, intent: DraftIntent(rawValue: value.intent)!,
                    targetLanguage: value.targetLanguage,
                    template: preferences.template(for: DraftIntent(rawValue: value.intent)!))
            }
            var report = Report(version: 1, runID: UUID(), mode: options.flags.contains("--dry-run") ? "offline"
                : (options.flags.contains("--live") ? "live" : "mock"), label: options.values["--label"] ?? "baseline",
                startedAt: Date(), suite: suite, model: model, requestCount: 0,
                status: configuration == nil ? "prepared" : "running",
                semanticStatus: "requiresHumanReview", results: zip(suite.cases, requests).map { value, request in
                    Result(caseID: value.id, templateRevision: request.templateRevision)
                })
            var startIndex = 0
            if let path = options.values["--resume-report"] {
                let previous: Report = try decode(path)
                guard previous.version == report.version, previous.mode == report.mode,
                      previous.label == report.label, previous.suite == suite, previous.model == model,
                      previous.semanticStatus == report.semanticStatus,
                      previous.status == "stoppedOnRequestFailure",
                      previous.results.count == report.results.count,
                      let failed = previous.results.firstIndex(where: { $0.error != nil }),
                      previous.requestCount >= failed + 1 else { throw Failure.incompatibleResume }
                for index in previous.results.indices {
                    let old = previous.results[index], fresh = report.results[index]
                    guard old.caseID == fresh.caseID, old.templateRevision == fresh.templateRevision else {
                        throw Failure.incompatibleResume
                    }
                    if index < failed {
                        guard let text = old.output, old.error == nil,
                              old.missingLiterals == suite.cases[index].requiredLiterals.filter({ !text.contains($0) }) else {
                            throw Failure.incompatibleResume
                        }
                        report.results[index] = old
                    } else {
                        guard old.output == nil, old.missingLiterals == nil,
                              index == failed || old.error == nil else { throw Failure.incompatibleResume }
                    }
                }
                startIndex = failed
                report.requestCount = previous.requestCount
                report.resumedFromRunID = previous.runID
                report.resumedRequestCount = previous.requestCount
            }
            // Count failed attempts too; candidate calls share the baseline's budget.
            let limit = options.values["--request-budget"].flatMap(Int.init) ?? 64
            let baselineUsed = baseline?.requestCount ?? 0
            guard baselineUsed <= limit, report.requestCount >= 0,
                  report.requestCount <= limit - baselineUsed,
                  requests.count - startIndex <= limit - baselineUsed - report.requestCount else {
                throw Failure.requestBudget
            }
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try save(report, to: output.appendingPathComponent("report.json"))
            guard let configuration else {
                print("Prepared \(requests.count) requests offline; provider configuration was not read; semantic quality not evaluated.")
                return 0
            }
            for index in startIndex..<requests.count {
                report.requestCount += 1
                try save(report, to: output.appendingPathComponent("report.json"))
                do {
                    let text = try await ModelAPIClient().generate(requests[index], using: configuration)
                    report.results[index].output = text
                    report.results[index].missingLiterals = suite.cases[index].requiredLiterals.filter { !text.contains($0) }
                } catch {
                    report.results[index].error = (error as? TranslationFailure)?.userMessage ?? "Model request failed."
                    report.status = "stoppedOnRequestFailure"
                    try save(report, to: output.appendingPathComponent("report.json"))
                    print("Stopped after \(report.requestCount) request(s); no retry; semantic quality not evaluated.")
                    return 1
                }
                try save(report, to: output.appendingPathComponent("report.json"))
            }
            let failures = report.results.filter { $0.missingLiterals?.isEmpty == false }.count
            report.status = failures == 0 ? "completed" : "completedWithLiteralFailures"
            try save(report, to: output.appendingPathComponent("report.json"))
            if let baseline { try writeBlindReview(baseline: baseline, candidate: report, to: output) }
            print("Completed \(report.requestCount) \(report.mode) requests; \(failures) literal failures; semantic quality requires human review.")
            return failures == 0 ? 0 : 1
        } catch {
            let reason: String
            switch error {
            case Failure.arguments: reason = "Expected --cases PATH --output DIRECTORY and exactly one of --dry-run, --mock-url LOOPBACK_URL, or --live with --provider-library PATH / --env-file PATH."
            case Failure.invalidSuite: reason = "Invalid 32-case bilingual matrix or case checks."
            case Failure.existingOutput: reason = "Output directory already exists; choose a fresh directory."
            case Failure.incompatibleBaseline: reason = "Baseline must be a completed run with identical model, service, protocol, case matrix and mode."
            case Failure.incompatibleResume: reason = "Resume requires a stopped failure report with identical model, service, protocol, matrix, mode, label and templates; completed outputs must form a valid prefix."
            case Failure.requestBudget: reason = "Remaining cases exceed the request budget, including previous failed attempts and baseline calls. No requests were sent."
            default: reason = "Could not prepare evaluation. No credentials or configuration contents were logged."
            }
            print("FAIL: \(reason)")
            return 1
        }
    }
    private static func validate(_ suite: Suite) throws {
        let categories: Set<String> = ["ordinary", "negations", "uncertainty", "technical", "mixed", "questions", "repetition", "long-draft"]
        var ids: Set<String> = [], cells: Set<String> = []
        guard suite.version == 1, suite.cases.count == 32 else { throw Failure.invalidSuite }
        for value in suite.cases {
            guard !value.id.isEmpty, ids.insert(value.id).inserted, categories.contains(value.category),
                  ["zh-en", "en-zh"].contains(value.direction), DraftIntent(rawValue: value.intent) != nil,
                  value.targetLanguage == (value.direction == "zh-en" ? "English" : "简体中文"),
                  !value.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.semanticChecks.isEmpty, !value.forbiddenAdditions.isEmpty,
                  (value.semanticChecks + value.forbiddenAdditions).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  value.requiredLiterals.allSatisfy({ !$0.isEmpty && value.source.contains($0) }),
                  cells.insert("\(value.category)/\(value.direction)/\(value.intent)").inserted else {
                throw Failure.invalidSuite
            }
        }
    }
    private static func configuration(_ options: Options) throws -> ProviderConfiguration? {
        if options.flags.contains("--dry-run") { return nil }
        if let base = options.values["--mock-url"] {
            guard let components = URLComponents(string: base), components.scheme == "http",
                  components.host == "127.0.0.1", components.user == nil, components.password == nil,
                  let format = APIFormat(rawValue: options.values["--format"] ?? "chatCompletions") else {
                throw Failure.configuration
            }
            let value = ProviderConfiguration(format: format, baseURL: base, model: "local-evaluation-fixture", apiKey: "fixture-key")
            _ = try value.endpointURL()
            return value
        }
        if let path = options.values["--provider-library"] {
            guard let value = try ProviderLibraryStore(fileURL: URL(fileURLWithPath: path)).load()?.activeConfiguration else {
                throw Failure.configuration
            }
            _ = try value.endpointURL()
            return value
        }
        guard let value = try LocalEnvironment.configuration(
            fileURL: URL(fileURLWithPath: options.values["--env-file"]!), environment: [:]) else {
            throw Failure.configuration
        }
        _ = try value.endpointURL()
        return value
    }
    private static func decode<T: Decodable>(_ path: String) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
    private static func save<T: Encodable>(_ value: T, to file: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: file, options: .atomic)
    }
    private struct BlindPair: Encodable {
        let caseInfo: Case
        let A: String
        let B: String
        let semanticVerdict = "unreviewed"
        let preference = "unreviewed"
    }
    private struct ReviewKey: Encodable { let caseID: String; let baseline: String; let candidate: String }
    private static func writeBlindReview(baseline: Report, candidate: Report, to directory: URL) throws {
        var pairs: [BlindPair] = [], keys: [ReviewKey] = []
        for index in candidate.suite.cases.indices {
            let reversed = Bool.random()
            let old = baseline.results[index].output!, new = candidate.results[index].output!
            pairs.append(BlindPair(caseInfo: candidate.suite.cases[index], A: reversed ? new : old, B: reversed ? old : new))
            keys.append(ReviewKey(caseID: candidate.suite.cases[index].id,
                                  baseline: reversed ? "B" : "A", candidate: reversed ? "A" : "B"))
        }
        try save(pairs, to: directory.appendingPathComponent("blind-review.json"))
        try save(keys, to: directory.appendingPathComponent("review-key.json"))
    }
}
