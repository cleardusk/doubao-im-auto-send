import Foundation

struct MiniMaxEnvironmentStatus {
    let apiKeyPresent: Bool
    let apiHost: String
    let hostValidationError: String?
    let effectiveBaseURL: String?
}

enum MiniMaxClientError: LocalizedError {
    case missingAPIKey
    case invalidHost(String)
    case unsupportedTransport(String)
    case invalidHTTPStatus(Int, String)
    case invalidResponse
    case invalidContent
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "缺少环境变量 MINIMAX_API_KEY。"
        case .invalidHost(let host):
            return "MINIMAX_API_HOST 无效：\(host)。请提供类似 https://api.minimaxi.com、https://api.minimaxi.com/v1 或 https://api.minimaxi.com/anthropic"
        case .unsupportedTransport(let transport):
            return "MiniMax 不支持 `\(transport)` transport。当前按 OpenClaw 和官方文档，仅支持 `sync` 和 `sse`。"
        case .invalidHTTPStatus(let statusCode, let message):
            return "MiniMax API 返回 HTTP \(statusCode)：\(message)"
        case .invalidResponse:
            return "MiniMax API 返回了无法识别的响应。"
        case .invalidContent:
            return "MiniMax API 未返回可用的文本内容。"
        case .timedOut:
            return "MiniMax 请求超时。"
        }
    }
}

private struct MiniMaxAnthropicRequest: Encodable {
    struct ContentBlock: Encodable {
        let type = "text"
        let text: String
    }

    struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    let model: String
    let maxTokens: Int
    let system: String
    let messages: [Message]
    let stream: Bool?
    let temperature = 0.1

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
        case stream
        case temperature
    }
}

private struct MiniMaxAnthropicResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    let content: [ContentBlock]
}

private struct MiniMaxAPIErrorResponse: Decodable {
    struct APIError: Decodable {
        let type: String?
        let message: String?
    }

    let type: String?
    let error: APIError?
}

private struct MiniMaxSSEContentBlockStart: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    let content_block: ContentBlock?
}

private struct MiniMaxSSEContentBlockDelta: Decodable {
    struct Delta: Decodable {
        let type: String
        let text: String?
    }

    let delta: Delta?
}

final class MiniMaxClient: RefineProvider {
    let kind: RefineProviderKind = .minimax

    private let logger: Logger
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let transportMode: MiniMaxTransportMode

    init(
        logger: Logger,
        transportMode: MiniMaxTransportMode = .sync,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        self.logger = logger
        self.transportMode = transportMode
        let status = Self.environmentStatus(from: environment)
        guard status.apiKeyPresent, let apiKey = environment["MINIMAX_API_KEY"], !apiKey.isEmpty else {
            throw MiniMaxClientError.missingAPIKey
        }
        if let hostValidationError = status.hostValidationError {
            throw MiniMaxClientError.invalidHost(hostValidationError)
        }
        self.apiKey = apiKey
        self.baseURL = try Self.makeBaseURL(from: status.apiHost)
        self.session = HTTPTransportSupport.makeEphemeralSession(environment: environment)
    }

    static func environmentStatus(from environment: [String: String] = ProcessInfo.processInfo.environment) -> MiniMaxEnvironmentStatus {
        let apiHost = (environment["MINIMAX_API_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? environment["MINIMAX_API_HOST"]!.trimmingCharacters(in: .whitespacesAndNewlines)
            : Config.defaultMiniMaxHost

        return MiniMaxEnvironmentStatus(
            apiKeyPresent: !(environment["MINIMAX_API_KEY"]?.isEmpty ?? true),
            apiHost: apiHost,
            hostValidationError: validateHost(apiHost),
            effectiveBaseURL: effectiveBaseURL(from: apiHost)?.absoluteString
        )
    }

    func refine(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> RefineTask {
        switch transportMode {
        case .sync:
            return refineSyncTransport(text: text, mode: mode, model: model, timeout: timeout, completion: completion)
        case .sse:
            return refineSSETransport(text: text, mode: mode, model: model, timeout: timeout, completion: completion)
        case .ws:
            completion(.failure(MiniMaxClientError.unsupportedTransport(transportMode.rawValue)))
            return NoopRefineTask()
        }
    }

    private func refineSyncTransport(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> RefineTask {
        let resolvedModel = Self.normalizeModelID(model)
        let payload = MiniMaxAnthropicRequest(
            model: resolvedModel,
            maxTokens: Self.responseMaxTokens,
            system: mode.systemPrompt,
            messages: [
                .init(
                    role: "user",
                    content: [.init(text: mode.userPrompt(for: text))]
                )
            ],
            stream: nil
        )

        let request: URLRequest
        do {
            request = try makeRequest(payload: payload, timeout: timeout)
        } catch {
            completion(.failure(error))
            return NoopRefineTask()
        }

        let startedAt = Date()
        let task = session.dataTask(with: request) { [logger] data, response, error in
            if let error = error as? URLError, error.code == .timedOut {
                completion(.failure(MiniMaxClientError.timedOut))
                return
            }
            if let error {
                completion(.failure(error))
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(MiniMaxClientError.invalidResponse))
                return
            }

            let bodyData = data ?? Data()
            guard (200..<300).contains(httpResponse.statusCode) else {
                let message = Self.decodeAPIError(from: bodyData) ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                completion(.failure(MiniMaxClientError.invalidHTTPStatus(httpResponse.statusCode, message)))
                return
            }

            do {
                let decoded = try JSONDecoder().decode(MiniMaxAnthropicResponse.self, from: bodyData)
                let content = decoded.content
                    .filter { $0.type == "text" }
                    .compactMap(\.text)
                    .joined()
                guard !content.isEmpty else {
                    throw MiniMaxClientError.invalidContent
                }
                let result = RefineSanitizer.sanitizeMiniMax(content)
                guard !result.isEmpty else {
                    throw MiniMaxClientError.invalidContent
                }
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                logger.log("refine 生成成功：provider=minimax，transport=sync，endpoint=anthropic，mode=\(mode.rawValue)，model=\(resolvedModel)，耗时=\(elapsedMs)ms，结果长度=\(result.count)")
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        return task
    }

    private func refineSSETransport(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> RefineTask {
        let resolvedModel = Self.normalizeModelID(model)
        let payload = MiniMaxAnthropicRequest(
            model: resolvedModel,
            maxTokens: Self.responseMaxTokens,
            system: mode.systemPrompt,
            messages: [
                .init(
                    role: "user",
                    content: [.init(text: mode.userPrompt(for: text))]
                )
            ],
            stream: true
        )

        let request: URLRequest
        do {
            request = try makeRequest(payload: payload, timeout: timeout)
        } catch {
            completion(.failure(error))
            return NoopRefineTask()
        }

        let managedTask = ManagedAsyncRefineTask()
        let logger = self.logger
        let session = self.session
        let task = Task {
            let startedAt = Date()
            do {
                let (bytes, response) = try await session.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    completion(.failure(MiniMaxClientError.invalidResponse))
                    return
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    let message = try await Self.readStreamError(from: bytes)
                    completion(.failure(MiniMaxClientError.invalidHTTPStatus(httpResponse.statusCode, message)))
                    return
                }

                let streamedText = try await Self.collectSSEText(from: bytes)
                let result = RefineSanitizer.sanitizeMiniMax(streamedText)
                guard !result.isEmpty else {
                    throw MiniMaxClientError.invalidContent
                }
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                logger.log("refine 生成成功：provider=minimax，transport=sse，endpoint=anthropic，mode=\(mode.rawValue)，model=\(resolvedModel)，耗时=\(elapsedMs)ms，结果长度=\(result.count)")
                completion(.success(result))
            } catch is CancellationError {
                return
            } catch let error as URLError where error.code == .timedOut {
                completion(.failure(MiniMaxClientError.timedOut))
            } catch {
                completion(.failure(error))
            }
        }
        managedTask.bind(task)
        return managedTask
    }

    private static func validateHost(_ host: String) -> String? {
        guard let components = URLComponents(string: host),
              let scheme = components.scheme,
              (scheme == "https" || scheme == "http"),
              components.host != nil else {
            return host
        }

        if components.query != nil || components.fragment != nil {
            return host
        }
        return effectiveBaseURL(from: host) == nil ? host : nil
    }

    private static func makeBaseURL(from host: String) throws -> URL {
        guard validateHost(host) == nil,
              let url = effectiveBaseURL(from: host) else {
            throw MiniMaxClientError.invalidHost(host)
        }
        return url
    }

    private static func effectiveBaseURL(from host: String) -> URL? {
        guard var components = URLComponents(string: host),
              let scheme = components.scheme,
              (scheme == "https" || scheme == "http"),
              components.host != nil else {
            return nil
        }

        let rawPath = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPath = rawPath.isEmpty ? "/" : rawPath
        switch normalizedPath {
        case "/", "/v1", "/anthropic", "/anthropic/v1":
            components.path = "/anthropic"
        default:
            return nil
        }

        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func decodeAPIError(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(MiniMaxAPIErrorResponse.self, from: data),
           let message = decoded.error?.message,
           !message.isEmpty {
            return message
        }
        return String(data: data.prefix(200), encoding: .utf8)
    }

    private static func normalizeModelID(_ rawModel: String) -> String {
        let trimmed = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Config.defaultMiniMaxModel }

        let unqualified: String
        if let slashIndex = trimmed.firstIndex(of: "/") {
            unqualified = String(trimmed[trimmed.index(after: slashIndex)...])
        } else {
            unqualified = trimmed
        }

        let canonicalMap = [
            "minimax-m2.7": "MiniMax-M2.7",
            "minimax-m2.7-highspeed": "MiniMax-M2.7-highspeed",
            "minimax-m2.5": "MiniMax-M2.5",
            "minimax-m2.5-highspeed": "MiniMax-M2.5-highspeed",
            "minimax-m2.1": "MiniMax-M2.1",
            "minimax-m2.1-highspeed": "MiniMax-M2.1-highspeed",
            "minimax-m2": "MiniMax-M2"
        ]

        return canonicalMap[unqualified.lowercased()] ?? unqualified
    }

    private static let responseMaxTokens = 1024

    private func makeRequest(payload: MiniMaxAnthropicRequest, timeout: TimeInterval) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)
        return request
    }

    private static func readStreamError(from bytes: URLSession.AsyncBytes) async throws -> String {
        var collected = ""
        for try await line in bytes.lines {
            if !collected.isEmpty {
                collected.append("\n")
            }
            collected.append(line)
            if collected.count >= 200 {
                break
            }
        }
        let truncated = String(collected.prefix(200))
        if let data = truncated.data(using: .utf8),
           let decoded = decodeAPIError(from: data) {
            return decoded
        }
        return truncated.isEmpty ? "未知错误" : truncated
    }

    private static func collectSSEText(from bytes: URLSession.AsyncBytes) async throws -> String {
        var parser = MiniMaxSSEParser()
        var collected = ""

        for try await line in bytes.lines {
            try Task.checkCancellation()
            for event in parser.consume(line) {
                switch event {
                case .text(let chunk):
                    collected.append(chunk)
                case .done:
                    return collected
                }
            }
        }

        for event in parser.finish() {
            switch event {
            case .text(let chunk):
                collected.append(chunk)
            case .done:
                return collected
            }
        }
        return collected
    }
}

private enum MiniMaxParsedSSEEvent {
    case text(String)
    case done
}

private struct MiniMaxSSEParser {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func consume(_ line: String) -> [MiniMaxParsedSSEEvent] {
        if line.isEmpty {
            return flush()
        }

        if line.hasPrefix("event:") {
            let pending = dataLines.isEmpty ? [] : flush()
            eventName = line.dropFirst("event:".count).trimmingCharacters(in: .whitespaces)
            return pending
        }

        if line.hasPrefix("data:") {
            dataLines.append(line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces))
        }
        return []
    }

    mutating func finish() -> [MiniMaxParsedSSEEvent] {
        flush()
    }

    private mutating func flush() -> [MiniMaxParsedSSEEvent] {
        defer {
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
        }

        let payload = dataLines.joined(separator: "\n")
        guard !payload.isEmpty else { return [] }
        if payload == "[DONE]" || eventName == "message_stop" {
            return [.done]
        }

        guard let data = payload.data(using: .utf8) else { return [] }

        switch eventName {
        case "content_block_start":
            if let decoded = try? JSONDecoder().decode(MiniMaxSSEContentBlockStart.self, from: data),
               decoded.content_block?.type == "text",
               let text = decoded.content_block?.text,
               !text.isEmpty {
                return [.text(text)]
            }
        case "content_block_delta":
            if let decoded = try? JSONDecoder().decode(MiniMaxSSEContentBlockDelta.self, from: data),
               decoded.delta?.type == "text_delta",
               let text = decoded.delta?.text,
               !text.isEmpty {
                return [.text(text)]
            }
        case "message_stop":
            return [.done]
        default:
            break
        }

        return []
    }
}
