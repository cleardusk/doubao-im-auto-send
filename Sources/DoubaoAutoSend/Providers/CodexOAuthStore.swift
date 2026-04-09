import CryptoKit
import Foundation

enum CodexAuthSource: String {
    case openClawProfile = "openclaw auth-profiles"
    case codexKeychain = "codex keychain"
    case codexAuthFile = "codex auth.json"
}

enum CodexCredentialExpiryStatus {
    case valid
    case expired
    case unknown
}

struct CodexEnvironmentStatus {
    let authConfigured: Bool
    let authUsable: Bool
    let authSource: CodexAuthSource?
    let expiresAt: Date?
    let authMode: String?
    let expiryStatus: CodexCredentialExpiryStatus
}

struct CodexCredential {
    let accessToken: String
    let refreshToken: String?
    let accountID: String
    let expiresAt: Date?
    let authMode: String?
    let source: CodexAuthSource
}

enum CodexOAuthError: LocalizedError {
    case missingAuth
    case expiredAuth(Date?)
    case invalidAuthStore(String)
    case missingAccountID

    var errorDescription: String? {
        switch self {
        case .missingAuth:
            return "未检测到可用的 Codex OAuth 登录态。请先执行 `openclaw models auth login --provider openai-codex` 或 `codex login`。"
        case .expiredAuth(let expiresAt):
            if let expiresAt {
                return "Codex 本地登录态已过期：\(ISO8601DateFormatter().string(from: expiresAt))。请重新执行 `openclaw models auth login --provider openai-codex` 或 `codex login`。"
            }
            return "Codex 本地登录态已过期。请重新执行 `openclaw models auth login --provider openai-codex` 或 `codex login`。"
        case .invalidAuthStore(let message):
            return "Codex 本地认证配置无效：\(message)"
        case .missingAccountID:
            return "Codex OAuth token 缺少 account id。"
        }
    }
}

actor CodexOAuthStore {
    private static let openClawProfileID = "openai-codex:default"

    private let logger: Logger
    private let environment: [String: String]

    init(logger: Logger, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.logger = logger
        self.environment = environment
    }

    static func environmentStatus(from environment: [String: String] = ProcessInfo.processInfo.environment) -> CodexEnvironmentStatus {
        let candidates = loadCandidates(from: environment)
        let chosen = chooseBestCandidate(from: candidates)
        let expiryStatus = chosen.map(expiryStatus(for:)) ?? .unknown
        return CodexEnvironmentStatus(
            authConfigured: !candidates.isEmpty,
            authUsable: chosen.map(isUsable(_:)) ?? false,
            authSource: chosen?.source,
            expiresAt: chosen?.expiresAt,
            authMode: chosen?.authMode,
            expiryStatus: expiryStatus
        )
    }

    func resolvedCredential() async throws -> CodexCredential {
        let candidates = Self.loadCandidates(from: environment)
        guard let chosen = Self.chooseBestCandidate(from: candidates) else {
            throw CodexOAuthError.missingAuth
        }
        guard Self.isUsable(chosen) else {
            logger.log("Codex access token 已过期，拒绝继续使用本地登录态：source=\(chosen.source.rawValue)")
            throw CodexOAuthError.expiredAuth(chosen.expiresAt)
        }
        return chosen
    }
}

private extension CodexOAuthStore {
    struct CandidateRecord {
        let credential: CodexCredential
        let freshnessRank: Int
    }

    static func loadCandidates(from environment: [String: String]) -> [CodexCredential] {
        var candidates: [CodexCredential] = []
        if let openClaw = readOpenClawProfile(environment: environment) {
            candidates.append(openClaw)
        }
        if let keychain = readCodexKeychain(environment: environment) {
            candidates.append(keychain)
        }
        if let authFile = readCodexAuthFile(environment: environment) {
            candidates.append(authFile)
        }
        return candidates
    }

    static func chooseBestCandidate(from candidates: [CodexCredential]) -> CodexCredential? {
        let ranked = candidates.map { credential in
            let freshnessRank: Int
            switch expiryStatus(for: credential) {
            case .valid, .unknown:
                freshnessRank = 2
            case .expired:
                freshnessRank = 1
            }
            return CandidateRecord(credential: credential, freshnessRank: freshnessRank)
        }
        return ranked.sorted { lhs, rhs in
            if lhs.freshnessRank != rhs.freshnessRank {
                return lhs.freshnessRank > rhs.freshnessRank
            }
            if precedence(of: lhs.credential.source) != precedence(of: rhs.credential.source) {
                return precedence(of: lhs.credential.source) < precedence(of: rhs.credential.source)
            }
            return (lhs.credential.expiresAt ?? .distantPast) > (rhs.credential.expiresAt ?? .distantPast)
        }.first?.credential
    }

    static func expiryStatus(for credential: CodexCredential) -> CodexCredentialExpiryStatus {
        guard let expiresAt = credential.expiresAt else {
            return .unknown
        }
        return expiresAt > Date() ? .valid : .expired
    }

    static func isUsable(_ credential: CodexCredential) -> Bool {
        expiryStatus(for: credential) != .expired
    }

    static func precedence(of source: CodexAuthSource) -> Int {
        switch source {
        case .openClawProfile:
            return 0
        case .codexKeychain:
            return 1
        case .codexAuthFile:
            return 2
        }
    }

    static func readOpenClawProfile(environment: [String: String]) -> CodexCredential? {
        let path = resolveOpenClawAuthPath(environment: environment)
        guard let root = readJSONObject(atPath: path),
              let profiles = root["profiles"] as? [String: Any],
              let profile = profiles[openClawProfileID] as? [String: Any],
              let accessToken = nonEmptyString(profile["access"]) else {
            return nil
        }
        let refreshToken = nonEmptyString(profile["refresh"])
        let accountID = nonEmptyString(profile["accountId"]) ?? resolveAccountID(fromAccessToken: accessToken)
        guard let accountID else { return nil }
        return CodexCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: accountID,
            expiresAt: dateFromEpochMillis(profile["expires"]) ?? expiryFromJWT(accessToken),
            authMode: "oauth",
            source: .openClawProfile
        )
    }

    static func readCodexKeychain(environment: [String: String]) -> CodexCredential? {
        let account = computeCodexKeychainAccount(environment: environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Codex Auth", "-a", account, "-w"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let json = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = nonEmptyString(tokens["access_token"]) else {
            return nil
        }
        let refreshToken = nonEmptyString(tokens["refresh_token"])

        let accountID = nonEmptyString(tokens["account_id"]) ?? resolveAccountID(fromAccessToken: accessToken)
        guard let accountID else { return nil }
        let lastRefresh = dateFromISO8601(object["last_refresh"])
        let expiry = expiryFromJWT(accessToken) ?? lastRefresh?.addingTimeInterval(3600)
        return CodexCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: accountID,
            expiresAt: expiry,
            authMode: nonEmptyString(object["auth_mode"]) ?? "chatgpt",
            source: .codexKeychain
        )
    }

    static func readCodexAuthFile(environment: [String: String]) -> CodexCredential? {
        let path = resolveCodexAuthFilePath(environment: environment)
        guard let root = readJSONObject(atPath: path),
              let tokens = root["tokens"] as? [String: Any],
              let accessToken = nonEmptyString(tokens["access_token"]) else {
            return nil
        }
        let refreshToken = nonEmptyString(tokens["refresh_token"])
        let accountID = nonEmptyString(tokens["account_id"]) ?? resolveAccountID(fromAccessToken: accessToken)
        guard let accountID else { return nil }
        let fileExpiry = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .addingTimeInterval(3600)
        return CodexCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: accountID,
            expiresAt: expiryFromJWT(accessToken) ?? fileExpiry,
            authMode: nonEmptyString(root["auth_mode"]) ?? "chatgpt",
            source: .codexAuthFile
        )
    }

    static func resolveOpenClawAuthPath(environment: [String: String]) -> String {
        if let agentDir = nonEmptyString(environment["OPENCLAW_AGENT_DIR"]) {
            return URL(fileURLWithPath: expandUserPath(agentDir)).appendingPathComponent("auth-profiles.json").path
        }
        return expandUserPath("~/.openclaw/agents/main/agent/auth-profiles.json")
    }

    static func resolveCodexAuthFilePath(environment: [String: String]) -> String {
        return URL(fileURLWithPath: resolveCodexHomePath(environment: environment)).appendingPathComponent("auth.json").path
    }

    static func resolveCodexHomePath(environment: [String: String]) -> String {
        guard let configured = nonEmptyString(environment["CODEX_HOME"]) else {
            return expandUserPath("~/.codex")
        }
        if configured == "~" {
            return expandUserPath("~")
        }
        if configured.hasPrefix("~/") {
            return expandUserPath(configured)
        }
        return configured
    }

    static func computeCodexKeychainAccount(environment: [String: String]) -> String {
        let codexHome = resolveCodexHomePath(environment: environment)
        let resolvedHome = (try? FileManager.default.destinationOfSymbolicLink(atPath: codexHome)).flatMap { link in
            nonEmptyString(link)
        } ?? codexHome
        let digest = SHA256.hash(data: Data(resolvedHome.utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "cli|\(hash.prefix(16))"
    }

    static func resolveAccountID(fromAccessToken accessToken: String) -> String? {
        guard let payload = decodeJWTPayload(accessToken),
              let auth = payload["https://api.openai.com/auth"] as? [String: Any] else {
            return nil
        }
        return nonEmptyString(auth["chatgpt_account_id"]) ??
            nonEmptyString(auth["chatgpt_account_user_id"]) ??
            nonEmptyString(auth["chatgpt_user_id"]) ??
            nonEmptyString(auth["user_id"])
    }

    static func expiryFromJWT(_ accessToken: String) -> Date? {
        guard let payload = decodeJWTPayload(accessToken),
              let exp = number(payload["exp"]) else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    static func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1])
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func readJSONObject(atPath path: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func expandUserPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String, let number = Double(string) {
            return number
        }
        return nil
    }

    static func dateFromEpochMillis(_ value: Any?) -> Date? {
        guard let millis = number(value) else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    static func dateFromISO8601(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }

}
