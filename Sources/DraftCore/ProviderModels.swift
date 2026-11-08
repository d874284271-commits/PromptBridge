import Foundation

public struct ModelOption: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

/// Lists models from a configured provider without making assumptions based on its host name.
public struct ProviderModelsClient: Sendable {
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int

    public init(timeout: TimeInterval = 15, maximumResponseBytes: Int = 1_048_576) {
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
    }

    public func list(using configuration: ProviderConfiguration) async throws -> [ModelOption] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeout.isFinite && timeout > 0 ? timeout : 0))
        do {
            try Task.checkCancellation()
            guard timeout.isFinite, timeout > 0, maximumResponseBytes > 0 else {
                throw TranslationFailure.configuration
            }
            let baseURL = try configuration.connectionURL(appending: configuration.modelsPath)
            let options = URLSessionConfiguration.ephemeral
            options.urlCache = nil
            options.urlCredentialStorage = nil
            options.httpCookieStorage = nil
            options.httpShouldSetCookies = false
            options.requestCachePolicy = .reloadIgnoringLocalCacheData
            options.timeoutIntervalForRequest = timeout
            options.timeoutIntervalForResource = timeout
            options.waitsForConnectivity = false
            let session = URLSession(configuration: options, delegate: ProviderModelsSessionDelegate(), delegateQueue: nil)
            let deadlineTask = Task {
                do { try await clock.sleep(until: deadline) }
                catch { return }
                session.invalidateAndCancel()
            }
            defer { deadlineTask.cancel(); session.invalidateAndCancel() }

            var models: [ModelOption] = []
            var knownIDs: Set<String> = []
            var knownCursors: Set<String> = []
            var cursor: String?
            var totalResponseBytes = 0
            // A repeated cursor is rejected below; this bound also handles a server that
            // returns a fresh cursor forever without allowing an unbounded request sequence.
            let maximumPages = 1_000

            for _ in 0..<maximumPages {
                try Task.checkCancellation()
                guard clock.now < deadline else { throw TranslationFailure.timeout }
                guard totalResponseBytes < maximumResponseBytes else {
                    throw TranslationFailure.responseTooLarge
                }
                let pageURL = try pageURL(baseURL: baseURL, afterID: cursor)
                let request = makeRequest(url: pageURL, configuration: configuration)
                let body = try await fetch(request, session: session,
                                           maximumBytes: maximumResponseBytes - totalResponseBytes)
                try Task.checkCancellation()
                guard clock.now < deadline else { throw TranslationFailure.timeout }
                totalResponseBytes += body.count
                let page = try parse(body)
                try Task.checkCancellation()
                for model in page.models where knownIDs.insert(model.id).inserted {
                    models.append(model)
                }
                guard page.hasMore else { return models }
                guard let nextCursor = page.lastID, !nextCursor.isEmpty,
                      !nextCursor.hasControlCharacters,
                      knownCursors.insert(nextCursor).inserted else {
                    throw TranslationFailure.invalidResponse
                }
                cursor = nextCursor
            }
            throw TranslationFailure.invalidResponse
        } catch is CancellationError {
            throw TranslationFailure.cancelled
        } catch let failure as TranslationFailure {
            throw failure
        } catch let error as URLError {
            if Task.isCancelled { throw TranslationFailure.cancelled }
            if clock.now >= deadline { throw TranslationFailure.timeout }
            if error.code == .cancelled { throw TranslationFailure.cancelled }
            throw error.code == .timedOut ? TranslationFailure.timeout : TranslationFailure.network
        } catch {
            if Task.isCancelled { throw TranslationFailure.cancelled }
            throw TranslationFailure.network
        }
    }

    private func makeRequest(url: URL, configuration: ProviderConfiguration) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.trimmedKey.isEmpty {
            switch configuration.format {
            case .anthropicMessages:
                request.setValue(configuration.trimmedKey, forHTTPHeaderField: "x-api-key")
            case .chatCompletions, .responses:
                request.setValue("Bearer " + configuration.trimmedKey, forHTTPHeaderField: "Authorization")
            }
        }
        if configuration.format == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    private func pageURL(baseURL: URL, afterID: String?) throws -> URL {
        guard let afterID else { return baseURL }
        guard !afterID.hasControlCharacters else { throw TranslationFailure.invalidResponse }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        guard components?.query == nil, components?.fragment == nil else {
            throw TranslationFailure.configuration
        }
        components?.queryItems = [URLQueryItem(name: "after_id", value: afterID)]
        guard let url = components?.url else { throw TranslationFailure.invalidResponse }
        return url
    }

    private func fetch(_ request: URLRequest, session: URLSession,
                       maximumBytes: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw TranslationFailure.invalidResponse
            }
            if (300..<400).contains(response.statusCode) { throw TranslationFailure.redirect }
            guard (200..<300).contains(response.statusCode) else {
                throw TranslationFailure.http(response.statusCode)
            }
            guard response.expectedContentLength <= Int64(maximumBytes) else {
                throw TranslationFailure.responseTooLarge
            }
            var body = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard body.count < maximumBytes else {
                    throw TranslationFailure.responseTooLarge
                }
                body.append(byte)
            }
            try Task.checkCancellation()
            return body
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private struct Page {
        let models: [ModelOption]
        let hasMore: Bool
        let lastID: String?
    }

    private func parse(_ data: Data) throws -> Page {
        guard !data.isEmpty else { throw TranslationFailure.emptyResponse }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawModels = root["data"] as? [Any] else {
            throw TranslationFailure.invalidResponse
        }
        var models: [ModelOption] = []
        models.reserveCapacity(rawModels.count)
        for rawModel in rawModels {
            guard let value = rawModel as? [String: Any],
                  let id = value["id"] as? String,
                  !id.isEmpty else {
                throw TranslationFailure.invalidResponse
            }
            let displayName: String?
            if let rawDisplayName = value["display_name"], !(rawDisplayName is NSNull) {
                guard let string = rawDisplayName as? String else {
                    throw TranslationFailure.invalidResponse
                }
                displayName = string
            } else {
                displayName = nil
            }
            models.append(ModelOption(id: id, displayName: displayName))
        }
        let hasMore: Bool
        if let rawHasMore = root["has_more"] {
            guard let value = rawHasMore as? Bool else { throw TranslationFailure.invalidResponse }
            hasMore = value
        } else {
            hasMore = false
        }
        let lastID: String?
        if let rawLastID = root["last_id"], !(rawLastID is NSNull) {
            guard let value = rawLastID as? String else { throw TranslationFailure.invalidResponse }
            lastID = value
        } else {
            lastID = nil
        }
        return Page(models: models, hasMore: hasMore, lastID: lastID)
    }
}

private extension String {
    var hasControlCharacters: Bool { unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }
}

private final class ProviderModelsSessionDelegate: NSObject, URLSessionTaskDelegate {
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
