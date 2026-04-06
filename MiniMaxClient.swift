import Foundation

struct MiniMaxEnvironmentStatus {
    let apiKeyPresent: Bool
    let apiHost: String
    let hostValidationError: String?
}

enum MiniMaxClientError: LocalizedError {
    case missingAPIKey
    case invalidHost(String)
    case invalidHTTPStatus(Int, String)
    case invalidResponse
    case invalidContent
    case timedOut

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "缺少环境变量 MINIMAX_API_KEY。"
        case .invalidHost(let host):
            return "MINIMAX_API_HOST 无效：\(host)。请仅提供 host，例如 https://api.minimaxi.com"
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

private struct MiniMaxChatCompletionRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream = false
    let temperature = 0.1
    let reasoningSplit = true

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case reasoningSplit = "reasoning_split"
    }
}

private struct MiniMaxChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let content: String
        }

        let message: Message
    }

    let choices: [Choice]
}

private struct MiniMaxAPIErrorResponse: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError?
}

final class MiniMaxClient: RefineProvider {
    let kind: RefineProviderKind = .minimax

    private let logger: Logger
    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession

    init(logger: Logger, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.logger = logger
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
            hostValidationError: validateHost(apiHost)
        )
    }

    func refine(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> RefineTask {
        let payload = MiniMaxChatCompletionRequest(
            model: model,
            messages: [
                .init(role: "system", content: mode.systemPrompt),
                .init(role: "user", content: mode.userPrompt(for: text))
            ]
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(payload)
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
                let decoded = try JSONDecoder().decode(MiniMaxChatCompletionResponse.self, from: bodyData)
                guard let content = decoded.choices.first?.message.content else {
                    throw MiniMaxClientError.invalidContent
                }
                let result = RefineSanitizer.sanitizeMiniMax(content)
                guard !result.isEmpty else {
                    throw MiniMaxClientError.invalidContent
                }
                let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                logger.log("refine 成功：provider=minimax，mode=\(mode.rawValue)，耗时=\(elapsedMs)ms，结果长度=\(result.count)")
                completion(.success(result))
            } catch {
                completion(.failure(error))
            }
        }
        task.resume()
        return task
    }

    private static func validateHost(_ host: String) -> String? {
        guard let components = URLComponents(string: host),
              let scheme = components.scheme,
              (scheme == "https" || scheme == "http"),
              components.host != nil else {
            return host
        }

        let path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !path.isEmpty && path != "/" {
            return host
        }
        return nil
    }

    private static func makeBaseURL(from host: String) throws -> URL {
        guard validateHost(host) == nil, var components = URLComponents(string: host) else {
            throw MiniMaxClientError.invalidHost(host)
        }
        components.path = "/v1"
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw MiniMaxClientError.invalidHost(host)
        }
        return url
    }

    private static func decodeAPIError(from data: Data) -> String? {
        if let decoded = try? JSONDecoder().decode(MiniMaxAPIErrorResponse.self, from: data),
           let message = decoded.error?.message,
           !message.isEmpty {
            return message
        }
        return String(data: data.prefix(200), encoding: .utf8)
    }

}
