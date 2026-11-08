import DraftCore
import Foundation

func runProviderModelsChecks(baseURL: String) async -> [String] {
    var failures: [String] = []
    func report(_ name: String, _ problem: String? = nil) {
        print("\(problem == nil ? "PASS" : "FAIL") MODELS \(name)")
        if let problem { failures.append("MODELS \(name): \(problem)") }
    }
    func configuration(format: APIFormat = .chatCompletions, path: String,
                       key: String = "models-key", model: String = "") -> ProviderConfiguration {
        ProviderConfiguration(format: format, baseURL: baseURL + "/provider/base/", model: model,
                               apiKey: key, modelsPath: path)
    }
    func expectFailure(_ name: String, _ value: @autoclosure () throws -> URL,
                       expected: TranslationFailure = .configuration) {
        do {
            _ = try value()
            report(name, "invalid value was accepted")
        } catch let error as TranslationFailure {
            report(name, error == expected ? nil : "unexpected failure")
        } catch {
            report(name, "unsafe error escaped")
        }
    }
    func expectListFailure(_ name: String, configuration: ProviderConfiguration,
                           expected: TranslationFailure, client: ProviderModelsClient = ProviderModelsClient()) async {
        do {
            _ = try await client.list(using: configuration)
            report(name, "expected rejection, received model data")
        } catch let error as TranslationFailure {
            let safe = !error.userMessage.contains("SECRET_SERVER_BODY")
                && !error.userMessage.contains("models-key")
                && !error.userMessage.contains(baseURL)
            report(name, error == expected && safe ? nil : "unexpected or unsafe failure")
        } catch {
            report(name, "unsafe error escaped")
        }
    }

    let serializable = ProviderConfiguration(format: .anthropicMessages, baseURL: baseURL + "/provider/base",
                                             model: "", apiKey: "models-key", modelsPath: "/catalog/models")
    do {
        let encoded = try JSONEncoder().encode(serializable)
        let decoded = try JSONDecoder().decode(ProviderConfiguration.self, from: encoded)
        report("configuration Codable", decoded == serializable ? nil : "round trip changed configuration")
        let old = "{\"format\":\"responses\",\"baseURL\":\"https://example.invalid/v1\",\"model\":\"m\",\"apiKey\":\"k\"}"
        let legacy = try JSONDecoder().decode(ProviderConfiguration.self, from: Data(old.utf8))
        report("legacy configuration Codable", legacy.modelsPath == "models" ? nil : "missing modelsPath default")
    } catch {
        report("configuration Codable", "configuration could not be serialized")
        report("legacy configuration Codable", "legacy configuration could not be decoded")
    }

    do {
        let emptyModelURL = try configuration(path: "models").connectionURL(appending: "/catalog/models")
        report("empty model and relative path", emptyModelURL.path == "/provider/base/catalog/models" ? nil : "path escaped base path")
        let endpoint = try configuration(path: "models", model: "m").endpointURL()
        report("translation endpoint", endpoint.path == "/provider/base/chat/completions" ? nil : "wrong protocol endpoint")
        expectFailure("endpoint requires model", try configuration(path: "models").endpointURL())
    } catch {
        report("empty model and relative path", "valid connection URL rejected")
        report("translation endpoint", "valid endpoint rejected")
        report("endpoint requires model", "unexpected error")
    }
    for path in ["https://other.invalid/models", "//other.invalid/models", "../models", "models/../x",
                 "models?after_id=secret", "models#fragment", "%2e%2e/models"] {
        do {
            _ = try configuration(path: "models").connectionURL(appending: path)
            report("reject path \(path)", "unsafe path was accepted")
        } catch let error as TranslationFailure {
            report("reject path \(path)", error == .configuration ? nil : "wrong failure")
        } catch {
            report("reject path \(path)", "unsafe error escaped")
        }
    }

    for (name, format, key, path) in [
        ("Chat Bearer", APIFormat.chatCompletions, "chat-key", "models-auth-chat"),
        ("Responses Bearer", APIFormat.responses, "responses-key", "models-auth-responses"),
        ("Anthropic x-api-key", APIFormat.anthropicMessages, "anthropic-key", "models-auth-anthropic")
    ] {
        do {
            let result = try await ProviderModelsClient().list(using: configuration(format: format, path: path, key: key))
            let expectedID = name.hasPrefix("Anthropic") ? "anthropic-model" : "\(name.split(separator: " ").first!.lowercased())-model"
            let expected = [ModelOption(id: expectedID)]
            report(name, result == expected ? nil : "unexpected model response")
        } catch {
            report(name, "valid model response rejected")
        }
    }
    do {
        let result = try await ProviderModelsClient().list(using: configuration(path: "/model"))
        report("custom models path", result.map(\.id) == ["custom-model"] ? nil : "custom path response mismatch")
    } catch {
        report("custom models path", "custom models path rejected")
    }

    do {
        let result = try await ProviderModelsClient().list(using: configuration(path: "models-pages"))
        let expected = [ModelOption(id: "first", displayName: "First"), ModelOption(id: "duplicate"), ModelOption(id: "second", displayName: "Second")]
        report("pagination and dedupe", result == expected ? nil : "pages were not merged in order")
    } catch {
        report("pagination and dedupe", "paginated response rejected")
    }
    for (name, suffix, expected) in [
        ("redirect", "models-redirect", TranslationFailure.redirect),
        ("HTTP 401", "models-http401", TranslationFailure.http(401)),
        ("HTTP 404", "models-http404", TranslationFailure.http(404)),
        ("invalid JSON", "models-invalid", TranslationFailure.invalidResponse),
        ("empty body", "models-empty", TranslationFailure.emptyResponse),
        ("too large", "models-large", TranslationFailure.responseTooLarge)
    ] {
        await expectListFailure(name, configuration: configuration(path: suffix), expected: expected,
                                client: name == "too large" ? ProviderModelsClient(maximumResponseBytes: 128) : ProviderModelsClient())
    }
    await expectListFailure("timeout", configuration: configuration(path: "models-timeout"), expected: .timeout,
                            client: ProviderModelsClient(timeout: 0.12))

    await expectListFailure("overall pagination timeout", configuration: configuration(path: "models-slow-pages"), expected: .timeout,
                            client: ProviderModelsClient(timeout: 1))

    do {
        let task = Task { try await ProviderModelsClient(timeout: 5).list(using: configuration(path: "models-cancel")) }
        try? await Task.sleep(for: .milliseconds(60))
        task.cancel()
        _ = try await task.value
        report("cancellation and late result", "cancelled request returned data")
    } catch let error as TranslationFailure {
        report("cancellation and late result", error == .cancelled ? nil : "wrong cancellation failure")
    } catch {
        report("cancellation and late result", "unsafe cancellation error escaped")
    }
    await expectListFailure("invalid client timeout", configuration: configuration(path: "models-auth-chat"), expected: .configuration,
                            client: ProviderModelsClient(timeout: 0))
    return failures
}
