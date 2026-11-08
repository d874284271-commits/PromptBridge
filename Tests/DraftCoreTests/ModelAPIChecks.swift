import DraftCore
import Foundation

private let apiFixtureSource = "把 `saveDraft()` 保留在 Sources/App.swift；按钮“发送”保持中文，不要新增需求。\n只翻译这段。"
private let apiFixtureOutput = "Keep `saveDraft()` in Sources/App.swift; keep the “发送” button label in Chinese. Do not add requirements.\nTranslate only this text."
private let customFixtureSource = "Only this mixed-language draft: 请保留 {{target_language}} 和 `saveDraft()`。"
private let customTranslationTemplate = "Custom translation to {{target_language}}. Preserve literal code. Return only the requested draft."
private let customOptimizationTemplate = "Custom rewrite in {{target_language}}. Keep confirmed intent and uncertainty. Return only the requested draft."

@MainActor func runModelAPIChecks(baseURL: String) async -> [String] {
    var failures: [String] = []
    func report(_ name: String, _ problem: String? = nil) {
        print("\(problem == nil ? "PASS" : "FAIL") API \(name)")
        if let problem { failures.append("API \(name): \(problem)") }
    }
    func config(_ format: APIFormat, _ model: String) -> ProviderConfiguration {
        ProviderConfiguration(format: format, baseURL: baseURL + "/proxy/v1/", model: "  " + model + "  ", apiKey: "  fixture-key  ")
    }
    func generation(_ source: String = apiFixtureSource, intent: DraftIntent = .translate,
                    language: String = "English", template: String? = nil) throws -> GenerationRequest {
        try GenerationRequest(source: source, intent: intent, targetLanguage: language,
            template: template ?? TranslationPreferences().template(for: intent))
    }
    func expectFailure(_ name: String, configuration: ProviderConfiguration,
                       expected: TranslationFailure, client: ModelAPIClient = ModelAPIClient(),
                       source: String = apiFixtureSource) async {
        do {
            _ = try await client.generate(generation(source), using: configuration)
            report(name, "expected rejection, received a draft")
        } catch let error as TranslationFailure {
            let safe = !error.userMessage.contains("SECRET_SERVER_BODY")
                && !error.userMessage.contains("fixture-key") && !error.userMessage.contains(baseURL)
            report(name, error == expected && safe ? nil : "unexpected or unsafe error: \(error)")
        } catch {
            report(name, "error escaped the safe TranslationFailure mapping")
        }
    }

    let validBases = ["https://example.invalid", "https://example.invalid/proxy/v1/", "http://localhost:8080/v1", "http://127.0.0.1:8080", "http://[::1]:8080/v1"]
    for base in validBases {
        do {
            let value = ProviderConfiguration(format: .chatCompletions, baseURL: base, model: "fixture", apiKey: "fixture-key")
            let endpoint = try value.endpointURL()
            report("accept base \(base)", endpoint.path.hasSuffix("/chat/completions") ? nil : "endpoint was not appended")
        } catch { report("accept base \(base)", "valid fixture configuration rejected") }
    }
    let invalidBases = [
        "http://example.invalid/v1", "ftp://127.0.0.1/v1", "https://user:secret@example.invalid/v1",
        "https://example.invalid/v1?key=secret", "https://example.invalid/v1#fragment", "https://example.invalid/v1?",
        "https://example.invalid/v1/chat/completions", "https://example.invalid/v1/responses/",
        "https://example.invalid/v1/messages", "https://example.invalid/v1/%72esponses",
        "https://example.invalid:99999/v1", "https://", "/v1",
        "http://127.0.0.2/v1", "http://localhost.example.invalid/v1"
    ]
    var invalidConfigurations = invalidBases.map {
        ProviderConfiguration(format: .responses, baseURL: $0, model: "fixture", apiKey: "fixture-key")
    }
    invalidConfigurations += [
        ProviderConfiguration(format: .responses, baseURL: "https://example.invalid/v1", model: "fixture", apiKey: " "),
        ProviderConfiguration(format: .responses, baseURL: baseURL, model: " \n", apiKey: "fixture-key"),
        ProviderConfiguration(format: .responses, baseURL: baseURL, model: "model\tname", apiKey: "fixture-key"),
        ProviderConfiguration(format: .responses, baseURL: baseURL, model: "fixture", apiKey: "fixture-key\r\nInjected: header"),
        ProviderConfiguration(format: .responses, baseURL: baseURL, model: "fixture", apiKey: "fixture\u{2028}key")
    ]
    for (index, invalid) in invalidConfigurations.enumerated() {
        do {
            _ = try invalid.endpointURL()
            report("reject configuration \(index + 1)", "invalid fixture configuration accepted")
        } catch let error as TranslationFailure { report("reject configuration \(index + 1)", error == .configuration ? nil : "wrong failure") }
        catch { report("reject configuration \(index + 1)", "unsafe configuration error") }
    }

    for (format, prefix) in [(APIFormat.chatCompletions, "chat"), (.responses, "responses"), (.anthropicMessages, "anthropic")] {
        for suffix in ["success", "blocks"] {
            do {
                let result = try await ModelAPIClient().generate(generation(), using: config(format, prefix + "-" + suffix))
                report("\(prefix) \(suffix)", result == apiFixtureOutput ? nil : "text or preserved labels differ")
            } catch { report("\(prefix) \(suffix)", "valid fixture response rejected: \(error)") }
        }
        do {
            let result = try await ModelAPIClient().generate(generation(intent: .optimize), using: config(format, prefix + "-optimize"))
            report("\(prefix) optimize", result == apiFixtureOutput ? nil : "optimized fixture output differs")
        } catch { report("\(prefix) optimize", "valid optimization response rejected: \(error)") }
        let customizedCases: [(String, DraftIntent, String, String?, String, String)] = [
            ("language-translate", .translate, "  日本語  ", nil, apiFixtureSource, "日本語の下書き。"),
            ("language-optimize", .optimize, "Español (Latinoamérica)", nil, apiFixtureSource, "Borrador en español."),
            ("custom-translate", .translate, "简体中文（技术交流）", customTranslationTemplate,
             customFixtureSource, "定制翻译稿，保留 {{target_language}}。"),
            ("custom-optimize", .optimize, "Esperanto", customOptimizationTemplate,
             customFixtureSource, "La personecigita malneto.")
        ]
        for (suffix, intent, language, template, source, expectedOutput) in customizedCases {
            do {
                let request = try generation(source, intent: intent, language: language, template: template)
                let result = try await ModelAPIClient().generate(request, using: config(format, prefix + "-" + suffix))
                report("\(prefix) \(suffix)", result == expectedOutput ? nil : "custom language or template fixture differs")
            } catch { report("\(prefix) \(suffix)", "customized request was rejected: \(error)") }
        }
        for (suffix, expected) in [
            ("refusal", TranslationFailure.refused), ("truncated", .truncated), ("tools", .unsupportedContent),
            ("mixed-tools", .unsupportedContent), ("empty", .emptyResponse), ("malformed", .invalidResponse),
            ("nonterminal", .invalidResponse), ("wrong-role", .invalidResponse), ("error-object", .invalidResponse),
            ("nontext", .unsupportedContent), ("body-empty", .emptyResponse), ("http429", .http(429)),
            ("http401", .http(401)), ("http500", .http(500)), ("redirect", .redirect)
        ] {
            await expectFailure("\(prefix) \(suffix)", configuration: config(format, prefix + "-" + suffix), expected: expected)
        }
        for suffix in ["large-known", "large-unknown"] {
            await expectFailure("\(prefix) \(suffix)", configuration: config(format, prefix + "-" + suffix),
                                expected: .responseTooLarge, client: ModelAPIClient(maximumResponseBytes: 4096))
        }
    }
    await expectFailure("chat content filter", configuration: config(.chatCompletions, "chat-filter"), expected: .refused)
    await expectFailure("responses content filter", configuration: config(.responses, "responses-filter"), expected: .refused)
    await expectFailure("anthropic stop details refusal", configuration: config(.anthropicMessages, "anthropic-stop-refusal"), expected: .refused)
    await expectFailure("empty source is local", configuration: config(.responses, "must-not-arrive"), expected: .emptySource, source: " \n")
    await expectFailure("invalid timeout is local", configuration: config(.responses, "must-not-arrive"), expected: .configuration,
                        client: ModelAPIClient(timeout: 0))
    await expectFailure("timeout before headers", configuration: config(.chatCompletions, "chat-timeout"), expected: .timeout,
                        client: ModelAPIClient(timeout: 0.15))
    await expectFailure("timeout during body", configuration: config(.chatCompletions, "chat-slowbody"), expected: .timeout,
                        client: ModelAPIClient(timeout: 0.15))
    await expectFailure("interrupted body", configuration: config(.chatCompletions, "chat-interrupted"), expected: .network)

    for suffix in ["cancel", "cancelbody"] {
        let configuration = config(.chatCompletions, "chat-" + suffix)
        let start = Date()
        let task = Task { try await ModelAPIClient().generate(generation(), using: configuration) }
        try? await Task.sleep(for: .milliseconds(70))
        task.cancel()
        do {
            _ = try await task.value
            report(suffix, "cancelled request returned a draft")
        } catch let error as TranslationFailure {
            report(suffix, error == .cancelled && Date().timeIntervalSince(start) < 1 ? nil : "cancellation was incorrect or slow")
        } catch { report(suffix, "cancellation escaped safe error mapping") }
    }
    do {
        let noKey = ProviderConfiguration(format: .responses, baseURL: baseURL + "/proxy/v1", model: "responses-no-key", apiKey: " ")
        let result = try await ModelAPIClient().generate(generation(), using: noKey)
        report("loopback without key", result == apiFixtureOutput ? nil : "wrong fixture output")
    } catch { report("loopback without key", "loopback request was rejected") }
    return failures
}
