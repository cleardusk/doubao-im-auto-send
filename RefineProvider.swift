import Foundation

enum RefineProviderKind: String {
    case minimax
    case codex

    var displayName: String {
        switch self {
        case .minimax:
            return "MiniMax"
        case .codex:
            return "Codex"
        }
    }

    var defaultModel: String {
        switch self {
        case .minimax:
            return Config.defaultMiniMaxModel
        case .codex:
            return Config.defaultCodexModel
        }
    }

    var defaultTimeout: TimeInterval {
        switch self {
        case .minimax:
            return 6.0
        case .codex:
            return 10.0
        }
    }
}

enum RefineProviderSyncError: LocalizedError {
    case timedOut(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let provider):
            return "\(provider) 请求超时。"
        case .invalidResponse(let provider):
            return "\(provider) 返回了无法识别的响应。"
        }
    }
}

protocol RefineTask: AnyObject {
    func cancel()
}

extension URLSessionTask: RefineTask {}

final class NoopRefineTask: RefineTask {
    func cancel() {}
}

final class ManagedAsyncRefineTask: RefineTask {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func bind(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

protocol RefineProvider: AnyObject {
    var kind: RefineProviderKind { get }

    func refine(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval,
        completion: @escaping (Result<String, Error>) -> Void
    ) -> RefineTask
}

extension RefineProvider {
    func refineSync(
        text: String,
        mode: RefineMode,
        model: String,
        timeout: TimeInterval
    ) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedResultBox<String>()
        let task = refine(text: text, mode: mode, model: model, timeout: timeout) { result in
            box.result = result
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            throw RefineProviderSyncError.timedOut(kind.displayName)
        }

        guard let result = box.result else {
            throw RefineProviderSyncError.invalidResponse(kind.displayName)
        }
        return try result.get()
    }
}

func makeRefineProvider(config: Config, logger: Logger) throws -> RefineProvider {
    switch config.refineProvider {
    case .minimax:
        return try MiniMaxClient(logger: logger)
    case .codex:
        return try CodexHTTPProvider(logger: logger, transportMode: config.refineCodexTransport)
    }
}

enum RefineSanitizer {
    static func sanitizeMiniMax(_ content: String) -> String {
        stripWrappingQuotes(stripCodeFence(stripThinkBlock(content)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizeCodex(_ content: String) -> String {
        let normalized = stripWrappingQuotes(stripCodeFence(stripThinkBlock(content)))
            .replacingOccurrences(of: "`", with: "")
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripThinkBlock(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let thinkRange = trimmed.range(of: "</think>") else {
            return trimmed
        }
        return trimmed[thinkRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripCodeFence(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```"), trimmed.hasSuffix("```") else {
            return trimmed
        }

        var lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return trimmed }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(_ content: String) -> String {
        var result = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'")]
        for (prefix, suffix) in pairs {
            if result.first == prefix, result.last == suffix, result.count >= 2 {
                result.removeFirst()
                result.removeLast()
                result = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }
}

final class LockedResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<T, Error>?

    var result: Result<T, Error>? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
