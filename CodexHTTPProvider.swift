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

private struct CodexRequestBody: Encodable {
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

private struct CodexSessionKey: Hashable {
    let model: String
    let mode: RefineMode
}

private enum CodexTransportPlan {
    case websocket(sessionID: String, socket: URLSessionWebSocketTask?)
    case sse(sessionID: String)
}

private struct CodexWebSocketPhaseError: Error {
    let underlying: Error
    let started: Bool
}

extension CodexWebSocketPhaseError: LocalizedError {
    var errorDescription: String? {
        underlying.localizedDescription
    }
}

private actor CodexWebSocketPool {
    private struct Entry {
        let sessionID: String
        var socket: URLSessionWebSocketTask?
        var isBusy = false
        var idleExpiry: Date?
        var degradedUntil: Date?
    }

    private static let idleTTL: TimeInterval = 300
    private static let degradeTTL: TimeInterval = 60
    private var entries: [CodexSessionKey: Entry] = [:]

    func plan(for key: CodexSessionKey) -> CodexTransportPlan {
        let now = Date()
        var entry = entries[key] ?? Entry(sessionID: makeSessionID(for: key))

        if let idleExpiry = entry.idleExpiry, idleExpiry <= now {
            entry.socket?.cancel(with: .normalClosure, reason: nil)
            entry.socket = nil
            entry.idleExpiry = nil
            entry.isBusy = false
        }

        if let degradedUntil = entry.degradedUntil, degradedUntil > now {
            entries[key] = entry
            return .sse(sessionID: entry.sessionID)
        }

        if let socket = entry.socket, !entry.isBusy, socket.closeCode == .invalid {
            entry.isBusy = true
            entry.idleExpiry = nil
            entries[key] = entry
            return .websocket(sessionID: entry.sessionID, socket: socket)
        }

        if entry.isBusy {
            entries[key] = entry
            return .sse(sessionID: entry.sessionID)
        }

        entry.isBusy = true
        entry.idleExpiry = nil
        entries[key] = entry
        return .websocket(sessionID: entry.sessionID, socket: nil)
    }

    func attach(_ socket: URLSessionWebSocketTask, for key: CodexSessionKey) {
        var entry = entries[key] ?? Entry(sessionID: makeSessionID(for: key))
        entry.socket = socket
        entry.isBusy = true
        entry.idleExpiry = nil
        entries[key] = entry
    }

    func release(for key: CodexSessionKey, keep: Bool) {
        guard var entry = entries[key] else { return }
        if keep, let socket = entry.socket, socket.closeCode == .invalid {
            entry.isBusy = false
            entry.idleExpiry = Date().addingTimeInterval(Self.idleTTL)
            entries[key] = entry
            return
        }

        entry.socket?.cancel(with: .normalClosure, reason: nil)
        entry.socket = nil
        entry.isBusy = false
        entry.idleExpiry = nil
        entries[key] = entry
    }

    func markFailure(for key: CodexSessionKey) {
        var entry = entries[key] ?? Entry(sessionID: makeSessionID(for: key))
        entry.socket?.cancel(with: .goingAway, reason: nil)
        entry.socket = nil
        entry.isBusy = false
        entry.idleExpiry = nil
        entry.degradedUntil = Date().addingTimeInterval(Self.degradeTTL)
        entries[key] = entry
    }

    private func makeSessionID(for key: CodexSessionKey) -> String {
        let mode = sanitize(key.mode.rawValue).prefix(10)
        let model = sanitize(key.model).prefix(24)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12)
        return "dbref-\(mode)-\(model)-\(nonce)"
    }

    private func sanitize(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48).description
    }
}

final class CodexHTTPProvider: RefineProvider {
    let kind: RefineProviderKind = .codex

    private let logger: Logger
    private let environment: [String: String]
    private let authStore: CodexOAuthStore
    private let httpSession: URLSession
    private let websocketSession: URLSession
    private let websocketPool = CodexWebSocketPool()
    private let endpointURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!
    private let websocketBetaHeader = "responses_websockets=2026-02-06"

    init(logger: Logger, environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        self.logger = logger
        self.environment = environment
        let status = CodexOAuthStore.environmentStatus(from: environment)
        guard status.authConfigured else {
            throw CodexHTTPProviderError.missingAuth
        }
        self.authStore = CodexOAuthStore(logger: logger, environment: environment)
        self.httpSession = HTTPTransportSupport.makeEphemeralSession(environment: environment)
        self.websocketSession = HTTPTransportSupport.makeEphemeralSession(environment: environment)
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

private extension CodexHTTPProvider {
    func refineAsync(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval
    ) async throws -> String {
        let credential = try await authStore.resolvedCredential()
        let key = CodexSessionKey(model: model, mode: mode)
        let startedAt = Date()
        let sessionID: String
        switch await websocketPool.plan(for: key) {
        case .sse(let existingSessionID):
            sessionID = existingSessionID
        case .websocket(let existingSessionID, _):
            sessionID = existingSessionID
            await websocketPool.release(for: key, keep: false)
        }

        let body = try makeBody(text: text, mode: mode, model: model, sessionID: sessionID)
        let result = try await performSSE(
            body: body,
            credential: credential,
            sessionID: sessionID,
            timeout: timeout
        )
        logSuccess(result: result, mode: mode, transport: "sse", source: credential.source, startedAt: startedAt)
        return result
    }

    func makeBody(text: String, mode: RefineMode, model: String, sessionID: String) throws -> Data {
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
        return try finalize(parser: parser)
    }

    func performWebSocket(
        socket: URLSessionWebSocketTask,
        body: Data,
        key: CodexSessionKey
    ) async throws -> String {
        let parser = CodexEventAccumulator()
        let bodyString = String(decoding: body, as: UTF8.self)
        let payload = "{\"type\":\"response.create\",\(bodyString.dropFirst())"
        var hasStarted = false

        return try await withTaskCancellationHandler {
            do {
                try await socket.send(.string(payload))
                hasStarted = true
            } catch {
                throw CodexWebSocketPhaseError(underlying: error, started: false)
            }
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await socket.receive()
                } catch {
                    throw CodexWebSocketPhaseError(underlying: error, started: hasStarted)
                }
                switch message {
                case .data(let data):
                    try parser.consumeRawEvent(data)
                case .string(let text):
                    try parser.consumeRawEvent(Data(text.utf8))
                @unknown default:
                    throw CodexHTTPProviderError.invalidResponse
                }

                if parser.isCompleted {
                    return try finalize(parser: parser)
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
            Task {
                await self.websocketPool.markFailure(for: key)
            }
        }
    }

    func finalize(parser: CodexEventAccumulator) throws -> String {
        let result = RefineSanitizer.sanitizeCodex(parser.finalText)
        guard !result.isEmpty else {
            throw CodexHTTPProviderError.invalidContent
        }
        return result
    }

    func buildBaseHeaders(credential: CodexCredential) -> [String: String] {
        [
            "Authorization": "Bearer \(credential.accessToken)",
            "chatgpt-account-id": credential.accountID,
            "originator": "pi",
            "User-Agent": "pi (\(ProcessInfo.processInfo.operatingSystemVersionString.trimmingCharacters(in: .whitespacesAndNewlines)); swift)"
        ]
    }

    func makeWebSocketTask(credential: CodexCredential, sessionID: String, timeout: TimeInterval) -> URLSessionWebSocketTask {
        var request = URLRequest(url: websocketURL())
        request.timeoutInterval = timeout
        for (name, value) in buildBaseHeaders(credential: credential) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.setValue(websocketBetaHeader, forHTTPHeaderField: "OpenAI-Beta")
        request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        request.setValue(sessionID, forHTTPHeaderField: "session_id")
        return websocketSession.webSocketTask(with: request)
    }

    func websocketURL() -> URL {
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        components.scheme = endpointURL.scheme == "https" ? "wss" : "ws"
        return components.url!
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

    func shouldFallbackToSSE(_ error: Error) -> Bool {
        if let phaseError = error as? CodexWebSocketPhaseError {
            guard !phaseError.started else { return false }
            return shouldFallbackToSSE(phaseError.underlying)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .networkConnectionLost, .cannotFindHost, .notConnectedToInternet, .timedOut:
                return true
            default:
                break
            }
        }
        let message = error.localizedDescription.lowercased()
        return message.contains("handshake") || message.contains("cancelled") || message.contains("socket is not connected")
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

private final class CodexEventAccumulator {
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
