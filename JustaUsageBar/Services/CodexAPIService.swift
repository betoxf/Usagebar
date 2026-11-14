//
//  CodexAPIService.swift
//  JustaUsageBar
//
//  Reads Codex/OpenAI credentials and fetches usage
//

import Foundation

// MARK: - Codex Usage Data Model

nonisolated struct CodexUsageData {
    var planType: String = "unknown"
    /// The plan as people read it, empty until the API reports one.
    var planName: String {
        switch planType {
        case "unknown": ""
        case "prolite": "Pro Lite"
        case "promax": "Pro Max"
        default: displayPlanName(planType)
        }
    }
    var primaryUsedPercent: Int = 0
    var primaryResetAt: Date?
    var primaryWindowSeconds: Int = 18000
    var secondaryUsedPercent: Int = 0
    var secondaryResetAt: Date?
    var hasCredits: Bool = false
    var creditBalance: Double?
    var isUnlimited: Bool = false

    /// True once Codex's primary window is the weekly one (the old 5h window
    /// was retired upstream); the separate secondary weekly is redundant then.
    var primaryIsWeekly: Bool {
        primaryWindowSeconds >= 7 * 24 * 3600
    }

    var primaryWindowLabel: String {
        if primaryIsWeekly { return "W" }
        let hours = primaryWindowSeconds / 3600
        return "\(hours)h"
    }

    var timeUntilPrimaryReset: String {
        guard let resetAt = primaryResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    var timeUntilSecondaryReset: String {
        guard let resetAt = secondaryResetAt else { return "--" }
        return formatTimeUntil(resetAt)
    }

    private func formatTimeUntil(_ date: Date) -> String {
        let now = Date()
        guard date > now else { return "Now" }
        let interval = date.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static let placeholder = CodexUsageData()
}

// MARK: - Codex API Service

@ProviderActor
final class CodexAPIService {
    static let shared = CodexAPIService()

    nonisolated struct CodexCredentials {
        var accessToken: String
        var accountId: String?
        var isApiKey: Bool = false
    }

    private var cachedCredentials: CodexCredentials?
    private var lastCredentialCheck: Date?
    private let credentialCacheTTL: TimeInterval = 300

    private init() {}

    // MARK: - Credential Discovery

    func loadCredentials() -> CodexCredentials? {
        if let lastCredentialCheck,
           Date().timeIntervalSince(lastCredentialCheck) < credentialCacheTTL {
            return cachedCredentials
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? homeDir.appendingPathComponent(".codex")

        let authPath = codexHome.appendingPathComponent("auth.json")

        guard FileManager.default.fileExists(atPath: authPath.path),
              let data = try? Data(contentsOf: authPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            cachedCredentials = nil
            lastCredentialCheck = Date()
            return nil
        }

        // API key format
        if let apiKey = json["OPENAI_API_KEY"] as? String {
            let creds = CodexCredentials(accessToken: apiKey, isApiKey: true)
            cachedCredentials = creds
            lastCredentialCheck = Date()
            return creds
        }

        // OAuth format
        if let tokens = json["tokens"] as? [String: Any],
           let accessToken = tokens["access_token"] as? String {
            let creds = CodexCredentials(accessToken: accessToken, accountId: tokens["account_id"] as? String)
            cachedCredentials = creds
            lastCredentialCheck = Date()
            return creds
        }

        cachedCredentials = nil
        lastCredentialCheck = Date()
        return nil
    }

    var hasCredentials: Bool {
        loadCredentials() != nil
    }

    func clearCache() {
        cachedCredentials = nil
        lastCredentialCheck = nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> CodexUsageData {
        try await fetchUsage(allowRediscovery: true)
    }

    private func fetchUsage(allowRediscovery: Bool) async throws -> CodexUsageData {
        guard let creds = loadCredentials() else {
            throw APIError.noCredentials
        }

        let baseURL = getBaseURL()
        let usageURL: String
        if baseURL.contains("chatgpt.com") {
            usageURL = "\(baseURL)/backend-api/wham/usage"
        } else {
            usageURL = "\(baseURL)/api/codex/usage"
        }

        guard let url = URL(string: usageURL) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("Usagebar/1.0", forHTTPHeaderField: "User-Agent")
        if let accountId = creds.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await ProviderHTTP.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseCodexUsageResponse(data)
        case 429:
            throw APIError.rateLimited(retryAfter: HTTPRetryAfter.date(from: httpResponse))
        case 401, 403:
            // Codex owns this sign-in, and OpenAI refresh tokens work once, so
            // refreshing here would sign Codex out. Read Codex's file again in
            // case it renewed the token, and otherwise wait for Codex to.
            clearCache()
            if allowRediscovery, let reloaded = loadCredentials(), reloaded.accessToken != creds.accessToken {
                return try await fetchUsage(allowRediscovery: false)
            }
            throw creds.isApiKey ? APIError.unauthorized : APIError.cliSignInExpired(tool: "Codex")
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    // MARK: - Parse Response

    private func parseCodexUsageResponse(_ data: Data) throws -> CodexUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]))
        }

        var usage = CodexUsageData()
        usage.planType = json["plan_type"] as? String ?? "unknown"

        if let rateLimit = json["rate_limit"] as? [String: Any] {
            if let primary = rateLimit["primary_window"] as? [String: Any] {
                if let pct = primary["used_percent"] as? Double {
                    usage.primaryUsedPercent = Int(pct)
                } else if let pct = primary["used_percent"] as? Int {
                    usage.primaryUsedPercent = pct
                }
                if let resetAt = primary["reset_at"] as? Double {
                    usage.primaryResetAt = Date(timeIntervalSince1970: resetAt)
                }
                if let windowSec = primary["limit_window_seconds"] as? Int {
                    usage.primaryWindowSeconds = windowSec
                }
            }
            if let secondary = rateLimit["secondary_window"] as? [String: Any] {
                if let pct = secondary["used_percent"] as? Double {
                    usage.secondaryUsedPercent = Int(pct)
                } else if let pct = secondary["used_percent"] as? Int {
                    usage.secondaryUsedPercent = pct
                }
                if let resetAt = secondary["reset_at"] as? Double {
                    usage.secondaryResetAt = Date(timeIntervalSince1970: resetAt)
                }
            }
        }

        if let credits = json["credits"] as? [String: Any] {
            usage.hasCredits = credits["has_credits"] as? Bool ?? false
            usage.isUnlimited = credits["unlimited"] as? Bool ?? false
            usage.creditBalance = credits["balance"] as? Double
        }

        return usage
    }

    private func getBaseURL() -> String {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? homeDir.appendingPathComponent(".codex")
        let configPath = codexHome.appendingPathComponent("config.toml")

        if let content = try? String(contentsOf: configPath, encoding: .utf8) {
            for line in content.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("chatgpt_base_url") {
                    let parts = trimmed.components(separatedBy: "=")
                    if parts.count >= 2 {
                        let value = parts[1].trimmingCharacters(in: .whitespaces)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        if !value.isEmpty { return value }
                    }
                }
            }
        }

        return "https://chatgpt.com"
    }
}
