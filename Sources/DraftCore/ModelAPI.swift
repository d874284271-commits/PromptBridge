import Foundation

public enum APIFormat: String, CaseIterable, Codable, Sendable {
    case chatCompletions, responses, anthropicMessages

    fileprivate var path: String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .responses: "responses"
        case .anthropicMessages: "messages"
        }
    }
}

public enum DraftIntent: String, CaseIterable, Sendable {
    case translate, optimize
}

public enum TranslationFailure: Error, Equatable, Sendable, LocalizedError {
    case configuration, emptySource, network, timeout, cancelled
    case http(Int), redirect, refused, truncated, unsupportedContent
    case invalidResponse, emptyResponse, responseTooLarge

    public var userMessage: String {
        switch self {
        case .configuration: "模型设置无效，请检查协议、基础地址、模型名称和 API Key。"
        case .emptySource: "请输入需要翻译的文字。"
        case .network: "无法连接模型服务，请检查网络和服务设置后重试。"
        case .timeout: "模型请求超时，请稍后重试。"
        case .cancelled: "已取消生成。"
        case .http(401), .http(403): "模型服务拒绝访问，请检查 API Key 及模型权限。"
        case .http(429): "模型服务限流或额度不足，请检查账户额度后再试。"
        case .http(let status): "模型服务返回 HTTP \(status)，请检查设置或稍后重试。"
        case .redirect: "模型服务要求跳转地址，已停止请求。请填写最终的 API 基础地址。"
        case .refused: "模型拒绝处理这段内容，未生成可用译文。"
        case .truncated: "模型结果未完整生成，请缩短原文后重试。"
        case .unsupportedContent: "模型返回了工具调用或非文本内容，未生成可用译文。"
        case .invalidResponse: "模型响应格式无效或尚未完成，请检查 API 协议后重试。"
        case .emptyResponse: "模型没有返回有效文字，请重试。"
        case .responseTooLarge: "模型响应超过大小限制，已停止接收。请缩短原文后重试。"
        }
    }

    public var errorDescription: String? { userMessage }
}

public enum ProviderConfigurationField: String, Equatable, Sendable {
    case baseURL, apiKey, model, modelsPath
}

public struct ProviderConfigurationIssue: Equatable, Sendable {
    public let field: ProviderConfigurationField
    public let message: String
}

public struct ProviderConfiguration: Equatable, Codable, Sendable {
    public var format: APIFormat
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var modelsPath: String

    public init(format: APIFormat, baseURL: String, model: String, apiKey: String,
                modelsPath: String = "models") {
        self.format = format
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.modelsPath = modelsPath
    }

    public func endpointURL() throws -> URL {
        let components = try validatedBaseURL(requiringModel: true)
        return try appending(format.path, to: components)
    }

    /// Returns a model-list (or other provider-specific) URL below the configured base path.
    /// The appended path is always relative to this configuration's origin and base path.
    public func connectionURL(appending path: String) throws -> URL {
        let components = try validatedBaseURL(requiringModel: false)
        return try appending(path, to: components)
    }

    var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    private enum CodingKeys: String, CodingKey {
        case format, baseURL, model, apiKey, modelsPath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(APIFormat.self, forKey: .format)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        model = try values.decode(String.self, forKey: .model)
        apiKey = try values.decode(String.self, forKey: .apiKey)
        modelsPath = try values.decodeIfPresent(String.self, forKey: .modelsPath) ?? "models"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(format, forKey: .format)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(model, forKey: .model)
        try values.encode(apiKey, forKey: .apiKey)
        try values.encode(modelsPath, forKey: .modelsPath)
    }

    /// The form and request builders use the same validation rules.
    public func validationIssue(requiringModel: Bool, validatingModelsPath: Bool = true) -> ProviderConfigurationIssue? {
        if let issue = baseValidationIssue(requiringModel: requiringModel) { return issue }
        if validatingModelsPath && Self.validatedRelativePath(modelsPath) == nil {
            return ProviderConfigurationIssue(field: .modelsPath, message: "请填写有效的相对路径，例如 models。")
        }
        return nil
    }

    private func baseValidationIssue(requiringModel: Bool) -> ProviderConfigurationIssue? {
        if model.hasControlCharacters || (requiringModel && model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return ProviderConfigurationIssue(field: .model, message: "请填写有效的模型 ID。")
        }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.hasControlCharacters,
              let components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            return ProviderConfigurationIssue(field: .baseURL, message: "请填写不含账户、查询参数或片段的 API 基础地址。")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && loopback),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            return ProviderConfigurationIssue(field: .baseURL, message: "请使用 HTTPS 地址；本地回环服务可使用 HTTP。")
        }
        if apiKey.hasControlCharacters || apiKey.rangeOfCharacter(from: .newlines) != nil || (!loopback && trimmedKey.isEmpty) {
            return ProviderConfigurationIssue(field: .apiKey, message: "请填写有效的 API Key，不要包含换行。")
        }
        let decodedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        guard !["chat/completions", "responses", "messages"].contains(where: {
            decodedPath == $0 || decodedPath.hasSuffix("/" + $0)
        }) else {
            return ProviderConfigurationIssue(field: .baseURL, message: "请填写 API 基础地址，不要包含 chat/completions、responses 或 messages 端点。")
        }
        return nil
    }

    private func validatedBaseURL(requiringModel: Bool) throws -> URLComponents {
        guard baseValidationIssue(requiringModel: requiringModel) == nil,
              let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw TranslationFailure.configuration
        }
        return components
    }

    private func appending(_ path: String, to base: URLComponents) throws -> URL {
        guard let relativePath = Self.validatedRelativePath(path) else {
            throw TranslationFailure.configuration
        }
        var components = base
        let basePath = components.percentEncodedPath.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
        components.percentEncodedPath = basePath + "/" + relativePath
        guard let url = components.url else { throw TranslationFailure.configuration }
        return url
    }

    private static func validatedRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasControlCharacters,
              !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              let components = URLComponents(string: path), components.scheme == nil,
              components.host == nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        let encodedPath = components.percentEncodedPath
        guard !encodedPath.isEmpty, !encodedPath.hasPrefix("//") else { return nil }
        let withoutLeadingSlash = encodedPath.hasPrefix("/") ? String(encodedPath.dropFirst()) : encodedPath
        guard !withoutLeadingSlash.isEmpty, let decoded = withoutLeadingSlash.removingPercentEncoding,
              !decoded.contains("?"), !decoded.contains("#"), !decoded.contains("\\") else { return nil }
        for component in decoded.split(separator: "/", omittingEmptySubsequences: false) {
            guard component != ".", component != ".." else { return nil }
        }
        return withoutLeadingSlash
    }
}

private extension String {
    var hasControlCharacters: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}

/// Each call owns an ephemeral session, sends one request, and returns only a completed text result.
public struct ModelAPIClient: Sendable {
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int

    public init(timeout: TimeInterval = 45, maximumResponseBytes: Int = 1_048_576) {
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func generate(_ generation: GenerationRequest, using configuration: ProviderConfiguration) async throws -> String {
        do {
            try Task.checkCancellation()
            let endpoint = try configuration.endpointURL()
            guard timeout.isFinite, timeout > 0, maximumResponseBytes > 0 else {
                throw TranslationFailure.configuration
            }
            let request = try makeRequest(generation, configuration: configuration, endpoint: endpoint)
            let options = URLSessionConfiguration.ephemeral
            options.urlCache = nil
            options.urlCredentialStorage = nil
            options.httpCookieStorage = nil
            options.httpShouldSetCookies = false
            options.requestCachePolicy = .reloadIgnoringLocalCacheData
            options.timeoutIntervalForRequest = timeout
            options.timeoutIntervalForResource = timeout
            options.waitsForConnectivity = false
            let session = URLSession(configuration: options, delegate: PrivateSessionDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            return try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse else {
                    throw TranslationFailure.invalidResponse
                }
                if (300..<400).contains(response.statusCode) { throw TranslationFailure.redirect }
                guard (200..<300).contains(response.statusCode) else {
                    throw TranslationFailure.http(response.statusCode)
                }
                guard response.expectedContentLength <= Int64(maximumResponseBytes) else {
                    throw TranslationFailure.responseTooLarge
                }
                var body = Data()
                // Bound retained bytes while receiving, including bodies without Content-Length.
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard body.count < maximumResponseBytes else { throw TranslationFailure.responseTooLarge }
                    body.append(byte)
                }
                try Task.checkCancellation()
                let result = try parse(body, format: configuration.format)
                try Task.checkCancellation()
                return result
            } onCancel: {
                session.invalidateAndCancel()
            }
        } catch is CancellationError {
            throw TranslationFailure.cancelled
        } catch let failure as TranslationFailure {
            throw failure
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled { throw TranslationFailure.cancelled }
            throw error.code == .timedOut ? TranslationFailure.timeout : TranslationFailure.network
        } catch {
            if Task.isCancelled { throw TranslationFailure.cancelled }
            throw TranslationFailure.invalidResponse
        }
    }

    private func makeRequest(_ generation: GenerationRequest, configuration: ProviderConfiguration,
                             endpoint: URL) throws -> URLRequest {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let instructions = generation.instructions
        let source = generation.source
        var payload: [String: Any] = ["model": configuration.model.trimmingCharacters(in: .whitespacesAndNewlines), "stream": false]
        switch configuration.format {
        case .chatCompletions:
            payload["messages"] = [["role": "system", "content": instructions], ["role": "user", "content": source]]
            // Optional limits differ across compatible APIs and model generations.
            // OpenAI supports store; omit this extension for other Chat-compatible providers.
            if endpoint.host?.lowercased() == "api.openai.com" { payload["store"] = false }
        case .responses:
            payload["instructions"] = instructions
            payload["input"] = source
            payload["store"] = false
            payload["max_output_tokens"] = 4096
        case .anthropicMessages:
            payload["system"] = instructions
            payload["messages"] = [["role": "user", "content": source]]
            payload["max_tokens"] = 4096
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        if !configuration.trimmedKey.isEmpty {
            let header = configuration.format == .anthropicMessages ? "x-api-key" : "Authorization"
            let value = configuration.format == .anthropicMessages ? configuration.trimmedKey : "Bearer " + configuration.trimmedKey
            request.setValue(value, forHTTPHeaderField: header)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return request
    }

    private func parse(_ data: Data, format: APIFormat) throws -> String {
        guard !data.isEmpty else { throw TranslationFailure.emptyResponse }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["error"] == nil || root["error"] is NSNull else {
            throw TranslationFailure.invalidResponse
        }
        let text: String
        switch format {
        case .chatCompletions: text = try parseChat(root)
        case .responses: text = try parseResponses(root)
        case .anthropicMessages: text = try parseAnthropic(root)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationFailure.emptyResponse
        }
        return text
    }

    private func parseChat(_ root: [String: Any]) throws -> String {
        guard let choices = root["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first, let message = choice["message"] as? [String: Any],
              message["role"] as? String == "assistant" else { throw TranslationFailure.invalidResponse }
        if let refusal = message["refusal"], !(refusal is NSNull), (refusal as? String) != "" {
            throw TranslationFailure.refused
        }
        switch choice["finish_reason"] as? String {
        case "length": throw TranslationFailure.truncated
        case "content_filter": throw TranslationFailure.refused
        case "tool_calls", "function_call": throw TranslationFailure.unsupportedContent
        case "stop": break
        default: throw TranslationFailure.invalidResponse
        }
        if let calls = message["tool_calls"], !(calls is NSNull), (calls as? [Any])?.isEmpty != true {
            throw TranslationFailure.unsupportedContent
        }
        if let call = message["function_call"], !(call is NSNull) { throw TranslationFailure.unsupportedContent }
        if let content = message["content"] as? String { return content }
        guard let blocks = message["content"] as? [[String: Any]] else { throw TranslationFailure.invalidResponse }
        return try textBlocks(blocks, textType: "text", allowThinking: false)
    }

    private func parseResponses(_ root: [String: Any]) throws -> String {
        if root["status"] as? String == "incomplete" {
            let details = root["incomplete_details"] as? [String: Any]
            throw details?["reason"] as? String == "content_filter" ? TranslationFailure.refused : TranslationFailure.truncated
        }
        guard root["status"] as? String == "completed", let output = root["output"] as? [[String: Any]] else {
            throw TranslationFailure.invalidResponse
        }
        var messages: [String] = []
        for item in output {
            if item["type"] as? String == "reasoning" { continue }
            guard item["type"] as? String == "message" else { throw TranslationFailure.unsupportedContent }
            guard item["role"] as? String == "assistant", item["status"] as? String == "completed",
                  let blocks = item["content"] as? [[String: Any]] else { throw TranslationFailure.invalidResponse }
            messages.append(try textBlocks(blocks, textType: "output_text", allowThinking: false))
        }
        return messages.joined(separator: "\n\n")
    }

    private func parseAnthropic(_ root: [String: Any]) throws -> String {
        guard root["type"] as? String == "message", root["role"] as? String == "assistant" else {
            throw TranslationFailure.invalidResponse
        }
        if let details = root["stop_details"] as? [String: Any],
           details["type"] as? String == "refusal" {
            throw TranslationFailure.refused
        }
        switch root["stop_reason"] as? String {
        case "max_tokens", "model_context_window_exceeded": throw TranslationFailure.truncated
        case "refusal": throw TranslationFailure.refused
        case "tool_use", "pause_turn": throw TranslationFailure.unsupportedContent
        case "end_turn": break
        default: throw TranslationFailure.invalidResponse
        }
        guard let blocks = root["content"] as? [[String: Any]] else { throw TranslationFailure.invalidResponse }
        return try textBlocks(blocks, textType: "text", allowThinking: true)
    }

    private func textBlocks(_ blocks: [[String: Any]], textType: String, allowThinking: Bool) throws -> String {
        var texts: [String] = []
        for block in blocks {
            guard let type = block["type"] as? String else { throw TranslationFailure.invalidResponse }
            if type == "refusal" { throw TranslationFailure.refused }
            if allowThinking && ["thinking", "redacted_thinking"].contains(type) { continue }
            guard type == textType else { throw TranslationFailure.unsupportedContent }
            guard let text = block["text"] as? String else { throw TranslationFailure.invalidResponse }
            texts.append(text)
        }
        return texts.joined()
    }
}

private final class PrivateSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                          ? .performDefaultHandling : .rejectProtectionSpace, nil)
    }
}
