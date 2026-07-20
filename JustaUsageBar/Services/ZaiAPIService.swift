//
//  ZaiAPIService.swift
//  JustaUsageBar
//
//  Reads a Z.ai API key (env or config) and fetches quota usage from z.ai.
//  Mirrors CodexBar's Zai provider: GET the quota/limit endpoint with a
//  Bearer key and surface the highest-signal usage window.
//

import Foundation
import Security

// MARK: - Zai Usage Data Model

struct ZaiUsageData {
    var planName: String = "unknown"
    var usedPercent: Int = 0
    var resetAt: Date?
    /// Human label for the window this percentage represents (e.g. "5h", "Weekly").
    var windowLabel: String = ""

    var timeUntilReset: String {
        guard let resetAt else { return "--" }
        let now = Date()
        guard resetAt > now else { return "Now" }
        let interval = resetAt.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        } else if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static let placeholder = ZaiUsageData()
}

// MARK: - Zai API Service

final class ZaiAPIService {
    static let shared = ZaiAPIService()

    private let quotaEndpoint = "https://api.z.ai/api/monitor/usage/quota/limit"

    private var cachedKey: String??
    private var lastKeyCheck: Date?
    private let keyCacheTTL: TimeInterval = 300

    private init() {}

    // MARK: - Credential Discovery

    func clearCache() {
        cachedKey = nil
        lastKeyCheck = nil
    }

    var hasCredentials: Bool {
        apiKey() != nil
    }

    /// Resolves the API key from the environment first, then a small set of
    /// known local config files. Returns nil when Z.ai isn't configured.
    private func apiKey() -> String? {
        if let lastKeyCheck,
           Date().timeIntervalSince(lastKeyCheck) < keyCacheTTL,
           let cachedKey {
            return cachedKey
        }

        let resolved = resolveKey()
        cachedKey = .some(resolved)
        lastKeyCheck = Date()
        return resolved
    }

    private func resolveKey() -> String? {
        let env = ProcessInfo.processInfo.environment
        for name in ["Z_AI_API_KEY", "ZAI_API_KEY", "ZHIPU_API_KEY"] {
            if let value = env[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return value
            }
        }

        // GUI launches do not inherit shell-only env exports. Read the same
        // Keychain items the user's shell loads via `load_keychain_env`.
        if let keychainKey = keychainAPIKey() {
            return keychainKey
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".zai/config.json"),
            home.appendingPathComponent(".config/zai/config.json"),
            home.appendingPathComponent(".config/codexbar/config.json")
        ]
        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            for key in ["apiKey", "api_key", "Z_AI_API_KEY", "token"] {
                if let value = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                    return value
                }
            }

            // Nested provider config variants: { "providers": { "zai": { "apiKey": "..." } } }
            if let providers = json["providers"] as? [String: Any] {
                for providerKey in ["zai", "z.ai", "zhipu"] {
                    if let provider = providers[providerKey] as? [String: Any] {
                        for key in ["apiKey", "api_key", "token"] {
                            if let value = (provider[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !value.isEmpty {
                                return value
                            }
                        }
                    }
                }
            }
            if let providers = json["providers"] as? [[String: Any]] {
                for provider in providers {
                    let id = ((provider["id"] as? String) ?? "").lowercased()
                    guard id == "zai" || id == "z.ai" || id == "zhipu" else { continue }
                    for key in ["apiKey", "api_key", "token"] {
                        if let value = (provider[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !value.isEmpty {
                            return value
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Reads common local Keychain service names for the z.ai API key.
    private func keychainAPIKey() -> String? {
        let services = [
            "user.z-ai-api-key",
            "openclaw.zai-api-key",
            "Z_AI_API_KEY",
            "ZAI_API_KEY"
        ]
        let accounts = [
            NSUserName(),
            NSFullUserName(),
            ProcessInfo.processInfo.environment["USER"] ?? "",
            ""
        ]

        for service in services {
            for account in accounts {
                if let value = readKeychainPassword(service: service, account: account),
                   !value.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    private func readKeychainPassword(service: String, account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !account.isEmpty {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        let value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value : nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> ZaiUsageData {
        guard let key = apiKey() else {
            throw APIError.noCredentials
        }
        guard let url = URL(string: quotaEndpoint) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }
        switch httpResponse.statusCode {
        case 200:
            return try parseQuota(data)
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    // MARK: - Parse

    private func parseQuota(_ data: Data) throws -> ZaiUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["data"] as? [String: Any] else {
            throw APIError.decodingError(NSError(domain: "Zai", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]))
        }

        var usage = ZaiUsageData()

        for key in ["planName", "plan", "plan_type", "packageName"] {
            if let name = (body[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                usage.planName = name
                break
            }
        }

        guard let limits = body["limits"] as? [[String: Any]], !limits.isEmpty else {
            return usage
        }

        // Prefer a token-based window (the meaningful quota); fall back to the
        // longest-window entry. Compute percent defensively like CodexBar:
        // avoid inventing a 0 that reads as full usage.
        let tokenLimits = limits.filter { ($0["type"] as? String) == "TOKENS_LIMIT" }
        let chosen = tokenLimits.max { windowMinutes($0) < windowMinutes($1) }
            ?? limits.max { windowMinutes($0) < windowMinutes($1) }

        if let entry = chosen {
            if let percent = computedPercent(entry) {
                usage.usedPercent = percent
            } else if let percent = doubleValue(entry["percentage"]) {
                usage.usedPercent = clampPercent(percent)
            }
            if let resetMs = doubleValue(entry["nextResetTime"]) {
                usage.resetAt = Date(timeIntervalSince1970: resetMs / 1000.0)
            }
            usage.windowLabel = windowLabel(entry)
        }

        return usage
    }

    private func computedPercent(_ entry: [String: Any]) -> Int? {
        guard let limit = doubleValue(entry["usage"]), limit > 0 else { return nil }
        let remaining = doubleValue(entry["remaining"])
        let current = doubleValue(entry["currentValue"])
        let used: Double
        if let remaining, let current {
            used = max(limit - remaining, current)
        } else if let remaining {
            used = limit - remaining
        } else if let current {
            used = current
        } else {
            return nil
        }
        return clampPercent(used / limit * 100)
    }

    private func windowMinutes(_ entry: [String: Any]) -> Int {
        let number = Int(doubleValue(entry["number"]) ?? 0)
        switch Int(doubleValue(entry["unit"]) ?? 0) {
        case 1: return number * 1440   // days
        case 3: return number * 60     // hours
        case 5: return number          // minutes
        case 6: return number * 10080  // weeks
        default: return number
        }
    }

    private func windowLabel(_ entry: [String: Any]) -> String {
        let minutes = windowMinutes(entry)
        if minutes >= 10080 { return "Weekly" }
        if minutes >= 1440 { return "\(minutes / 1440)d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        if minutes > 0 { return "\(minutes)m" }
        return ""
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func clampPercent(_ value: Double) -> Int {
        Int(max(0, min(100, value.rounded())))
    }
}
