import Foundation

enum CodexHTTPProviderError: LocalizedError {
    case missingAuth
    case invalidResponse
    case invalidHTTPStatus(Int, String)
    case invalidContent
    case timedOut
    case websocketFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAuth:
            return CodexOAuthError.missingAuth.localizedDescription
        case .invalidResponse:
            return "Codex 返回了无法识别的响应。"
        case .invalidHTTPStatus(let statusCode, let message):
            return "Codex API 返回 HTTP \(statusCode)：\(message)"
        case .invalidContent:
            return "Codex 未返回可用的 refine 文本。"
        case .timedOut:
            return "Codex 请求超时。"
        case .websocketFailed(let message):
            return "Codex WebSocket 失败：\(message)"
        }
    }
}

struct CodexRequestBody: Encodable {
    struct InputMessage: Encodable {
        struct InputText: Encodable {
            let type = "input_text"
            let text: String
        }

        let role = "user"
        let content: [InputText]
    }

    struct TextOptions: Encodable {
        let verbosity = "low"
    }

    struct ReasoningOptions: Encodable {
        let effort = "low"
        let summary = "auto"
    }

    let model: String
    let store = false
    let stream = true
    let instructions: String
    let input: [InputMessage]
    let text = TextOptions()
    let include = ["reasoning.encrypted_content"]
    let promptCacheKey: String
    let reasoning = ReasoningOptions()

    enum CodingKeys: String, CodingKey {
        case model
        case store
        case stream
        case instructions
        case input
        case text
        case include
        case promptCacheKey = "prompt_cache_key"
        case reasoning
    }
}

struct CodexSessionKey: Hashable {
    let model: String
    let mode: RefineMode
}

final class CodexHTTPProvider: RefineProvider {
    let kind: RefineProviderKind = .codex

    private let logger: Logger
    private let environment: [String: String]
    private let authStore: CodexOAuthStore
    private let httpSession: URLSession
    private let transportMode: CodexTransportMode
    private let websocketTransport: CodexWebSocketTransport
    private let endpointURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    init(
        logger: Logger,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        transportMode: CodexTransportMode = .sse
    ) throws {
        self.logger = logger
        self.environment = environment
        self.transportMode = transportMode
        let status = CodexOAuthStore.environmentStatus(from: environment)
        guard status.authConfigured else {
            throw CodexHTTPProviderError.missingAuth
        }
        self.authStore = CodexOAuthStore(logger: logger, environment: environment)
        self.httpSession = HTTPTransportSupport.makeEphemeralSession(environment: environment)
        self.websocketTransport = CodexWebSocketTransport(logger: logger, environment: environment)
    }

    static func environmentStatus(from environment: [String: String] = ProcessInfo.processInfo.environment) -> CodexEnvironmentStatus {
        CodexOAuthStore.environmentStatus(from: environment)
    }

    func refine(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> RefineTask {
        let managedTask = ManagedAsyncRefineTask()
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.withTimeout(timeout) {
                    try await self.refineAsync(text: text, mode: mode, model: model, timeout: timeout)
                }
                if !Task.isCancelled {
                    completion(.success(result))
                }
            } catch is CancellationError {
                return
            } catch {
                if !Task.isCancelled {
                    completion(.failure(error))
                }
            }
        }
        managedTask.bind(task)
        return managedTask
    }
}

extension CodexHTTPProvider {
    func refineAsync(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval
    ) async throws -> String {
        let credential = try await authStore.resolvedCredential()
        let startedAt = Date()
        switch transportMode {
        case .sse:
            let sessionID = Self.makeSessionID(model: model, mode: mode)
            let body = try Self.makeBody(text: text, mode: mode, model: model, sessionID: sessionID)
            let result = try await performSSE(
                body: body,
                credential: credential,
                sessionID: sessionID,
                timeout: timeout
            )
            logSuccess(result: result, mode: mode, transport: "sse", source: credential.source, startedAt: startedAt)
            return result
        case .ws:
            let result = try await websocketTransport.refine(
                text: text,
                mode: mode,
                model: model,
                timeout: timeout,
                credential: credential
            )
            logSuccess(result: result, mode: mode, transport: "ws", source: credential.source, startedAt: startedAt)
            return result
        }
    }

    func performSSE(
        body: Data,
        credential: CodexCredential,
        sessionID: String,
        timeout: TimeInterval
    ) async throws -> String {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.httpBody = body

        for (name, value) in buildBaseHeaders(credential: credential) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionID, forHTTPHeaderField: "session_id")

        let (data, response) = try await fetchData(with: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexHTTPProviderError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw CodexHTTPProviderError.invalidHTTPStatus(httpResponse.statusCode, decodeAPIError(data))
        }

        let parser = CodexEventAccumulator()
        try parser.consumeSSE(data)
        return try Self.finalize(parser: parser)
    }

    static func makeBody(text: String, mode: RefineMode, model: String, sessionID: String) throws -> Data {
        let payload = CodexRequestBody(
            model: model,
            instructions: mode.systemPrompt,
            input: [
                .init(content: [.init(text: mode.userPrompt(for: text))])
            ],
            promptCacheKey: sessionID
        )
        return try JSONEncoder().encode(payload)
    }

    static func makeSessionID(model: String, mode: RefineMode) -> String {
        let modePart = sanitizeSessionComponent(mode.rawValue, maxLength: 10)
        let modelPart = sanitizeSessionComponent(model, maxLength: 24)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        return "dbref-\(modePart)-\(modelPart)-\(nonce)"
    }

    static func finalize(parser: CodexEventAccumulator) throws -> String {
        let result = RefineSanitizer.sanitizeCodex(parser.finalText)
        guard !result.isEmpty else {
            throw CodexHTTPProviderError.invalidContent
        }
        return result
    }

    static func sanitizeSessionComponent(_ value: String, maxLength: Int) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(maxLength)
            .description
    }

    func buildBaseHeaders(credential: CodexCredential) -> [String: String] {
        [
            "Authorization": "Bearer \(credential.accessToken)",
            "chatgpt-account-id": credential.accountID,
            "originator": "pi",
            "User-Agent": "pi (\(ProcessInfo.processInfo.operatingSystemVersionString.trimmingCharacters(in: .whitespacesAndNewlines)); swift)"
        ]
    }

    func fetchData(with request: URLRequest) async throws -> (Data, URLResponse) {
        final class DataTaskBox: @unchecked Sendable {
            var task: URLSessionDataTask?
        }
        let box = DataTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = httpSession.dataTask(with: request) { data, response, error in
                    if let error = error as? URLError, error.code == .timedOut {
                        continuation.resume(throwing: CodexHTTPProviderError.timedOut)
                        return
                    }
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let data, let response else {
                        continuation.resume(throwing: CodexHTTPProviderError.invalidResponse)
                        return
                    }
                    continuation.resume(returning: (data, response))
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    func decodeAPIError(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        return String(data: data.prefix(240), encoding: .utf8) ?? "未知错误"
    }

    func withTimeout<T>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw CodexHTTPProviderError.timedOut
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    func logSuccess(
        result: String,
        mode: RefineMode,
        transport: String,
        source: CodexAuthSource,
        startedAt: Date
    ) {
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        logger.log("refine 成功：provider=codex，transport=\(transport)，source=\(source.rawValue)，mode=\(mode.rawValue)，耗时=\(elapsedMs)ms，结果长度=\(result.count)")
    }
}

final class CodexEventAccumulator {
    private var deltaText = ""
    private var completedMessages: [String] = []
    private(set) var isCompleted = false

    var finalText: String {
        let joinedMessages = completedMessages
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        if !joinedMessages.isEmpty {
            return joinedMessages
        }
        return deltaText
    }

    func consumeSSE(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CodexHTTPProviderError.invalidResponse
        }

        var currentDataLines: [String] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if line.isEmpty {
                try flush(lines: &currentDataLines)
                continue
            }
            if line.hasPrefix("data:") {
                currentDataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            }
        }
        try flush(lines: &currentDataLines)
    }

    func consumeRawEvent(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexHTTPProviderError.invalidResponse
        }
        try consume(event: object)
    }

    private func flush(lines: inout [String]) throws {
        guard !lines.isEmpty else { return }
        let eventText = lines.joined(separator: "\n")
        lines.removeAll(keepingCapacity: true)
        guard eventText != "[DONE]" else {
            return
        }
        try consumeRawEvent(Data(eventText.utf8))
    }

    private func consume(event: [String: Any]) throws {
        let type = event["type"] as? String ?? ""
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            if let delta = event["delta"] as? String {
                deltaText += delta
            }
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any],
               let itemType = item["type"] as? String,
               itemType == "message",
               let content = item["content"] as? [[String: Any]] {
                let text = content.compactMap { part -> String? in
                    if part["type"] as? String == "output_text" {
                        return part["text"] as? String
                    }
                    if part["type"] as? String == "refusal" {
                        return part["refusal"] as? String
                    }
                    return nil
                }.joined()
                if !text.isEmpty {
                    completedMessages.append(text)
                }
            }
        case "response.completed", "response.done", "response.incomplete":
            isCompleted = true
        case "response.failed":
            if let response = event["response"] as? [String: Any],
               let error = response["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw CodexHTTPProviderError.invalidHTTPStatus(500, message)
            }
            throw CodexHTTPProviderError.invalidResponse
        case "error":
            let message = event["message"] as? String ?? "未知错误"
            throw CodexHTTPProviderError.websocketFailed(message)
        default:
            break
        }
    }
}
