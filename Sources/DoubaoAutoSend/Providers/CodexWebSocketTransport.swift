import Foundation

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
    }

    private static let idleTTL: TimeInterval = 300
    private var entries: [CodexSessionKey: Entry] = [:]

    func checkout(for key: CodexSessionKey) -> (sessionID: String, socket: URLSessionWebSocketTask?) {
        let now = Date()
        var entry = entries[key] ?? Entry(sessionID: CodexHTTPProvider.makeSessionID(model: key.model, mode: key.mode))

        if let idleExpiry = entry.idleExpiry, idleExpiry <= now {
            entry.socket?.cancel(with: .normalClosure, reason: nil)
            entry.socket = nil
            entry.idleExpiry = nil
            entry.isBusy = false
        }

        if let socket = entry.socket, !entry.isBusy, socket.closeCode == .invalid {
            entry.isBusy = true
            entry.idleExpiry = nil
            entries[key] = entry
            return (entry.sessionID, socket)
        }

        entry.isBusy = true
        entry.idleExpiry = nil
        entries[key] = entry
        return (entry.sessionID, nil)
    }

    func attach(_ socket: URLSessionWebSocketTask, for key: CodexSessionKey) {
        guard var entry = entries[key] else { return }
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

    func invalidate(for key: CodexSessionKey) {
        guard var entry = entries[key] else { return }
        entry.socket?.cancel(with: .goingAway, reason: nil)
        entry.socket = nil
        entry.isBusy = false
        entry.idleExpiry = nil
        entries[key] = entry
    }
}

final class CodexWebSocketTransport {
    private let logger: Logger
    private let websocketSession: URLSession
    private let websocketPool = CodexWebSocketPool()
    private let endpointURL = URL(string: "https://chatgpt.com/backend-api/codex/responses")!

    init(logger: Logger, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.logger = logger
        self.websocketSession = HTTPTransportSupport.makeEphemeralSession(environment: environment)
    }

    func refine(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval,
        credential: CodexCredential
    ) async throws -> String {
        let key = CodexSessionKey(model: model, mode: mode)
        let plan = await websocketPool.checkout(for: key)
        let socket = plan.socket ?? makeWebSocketTask(
            credential: credential,
            sessionID: plan.sessionID,
            timeout: timeout
        )

        if plan.socket == nil {
            await websocketPool.attach(socket, for: key)
            socket.resume()
        }

        let body = try CodexHTTPProvider.makeBody(text: text, mode: mode, model: model, sessionID: plan.sessionID)
        do {
            let result = try await performWebSocket(
                socket: socket,
                body: body,
                key: key
            )
            await websocketPool.release(for: key, keep: true)
            return result
        } catch {
            await websocketPool.invalidate(for: key)
            logger.log("Codex WebSocket 失败：\(error.localizedDescription)")
            throw error
        }
    }
}

private extension CodexWebSocketTransport {
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
                    return try CodexHTTPProvider.finalize(parser: parser)
                }
            }
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
            Task {
                await self.websocketPool.invalidate(for: key)
            }
        }
    }

    func makeWebSocketTask(credential: CodexCredential, sessionID: String, timeout: TimeInterval) -> URLSessionWebSocketTask {
        var request = URLRequest(url: websocketURL())
        request.timeoutInterval = timeout
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.accountID, forHTTPHeaderField: "chatgpt-account-id")
        request.setValue("pi", forHTTPHeaderField: "originator")
        request.setValue("pi (\(ProcessInfo.processInfo.operatingSystemVersionString.trimmingCharacters(in: .whitespacesAndNewlines)); swift)", forHTTPHeaderField: "User-Agent")
        request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        request.setValue(sessionID, forHTTPHeaderField: "session_id")
        return websocketSession.webSocketTask(with: request)
    }

    func websocketURL() -> URL {
        var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false)!
        components.scheme = endpointURL.scheme == "https" ? "wss" : "ws"
        return components.url!
    }
}
