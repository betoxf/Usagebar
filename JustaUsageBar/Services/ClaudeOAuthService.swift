//
//  ClaudeOAuthService.swift
//  JustaUsageBar
//
//  Reads Claude CLI OAuth credentials and fetches usage via OAuth API
//

import Foundation
import Security

final class ClaudeOAuthService {
    static let shared = ClaudeOAuthService()

    private let oauthClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let tokenEndpoint = "https://platform.claude.com/v1/oauth/token"
    private let usageEndpoint = "https://api.anthropic.com/api/oauth/usage"
    private let oauthUserAgent = "claude-code/2.1.0"
    private let claudeKeychainService = "Claude Code-credentials"
    private let securityBinaryPath = "/usr/bin/security"
    private let securityCLIReadTimeout: TimeInterval = 1.5

    private var cachedCredentials: OAuthCredentials?
    private var lastCredentialCheck: Date?
    private let cacheTTL: TimeInterval = 300 // 5 minutes

    struct OAuthCredentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String]
    }

    private init() {}

    // MARK: - Credential Discovery

    func loadCredentials(forceReload: Bool = false) -> OAuthCredentials? {
        // Serve the short-lived cache only while it holds a still-valid token.
        // A cached-but-expired token must trigger a re-read, because Claude Code
        // may have rotated in a fresh one since we last looked.
        if !forceReload,
           let lastCheck = lastCredentialCheck,
           Date().timeIntervalSince(lastCheck) < cacheTTL,
           let cached = cachedCredentials,
           !isExpired(cached) {
            return cached
        }

        // Use the FRESHEST source (latest expiry), rather than first-wins.
        // Claude Code owns and rotates these tokens; clinging to our own stale
        // mirror is exactly what left the app stuck "signed out" while a valid
        // token sat in the keychain.
        //
        // Prompt-free sources first: if the mirror or credentials file already
        // holds an unexpired token, use it WITHOUT touching the keychain — every
        // keychain secret read can raise a password dialog.
        var candidates: [OAuthCredentials] = []
        if let c = readPersistedCredentials() { candidates.append(c) }
        if let c = readCredentialsFile() { candidates.append(c) }

        if let best = freshest(of: candidates), !isExpired(best) {
            cache(credentials: best, persist: true)
            return best
        }

        // Only now consult the keychain, and read exactly ONE item's secret
        // (the newest) so the user sees at most a single permission prompt.
        if let c = readFreshestFromKeychain() { candidates.append(c) }

        guard let best = freshest(of: candidates) else {
            cachedCredentials = nil
            lastCredentialCheck = Date()
            return nil
        }

        // Mirror the freshest so later loads stay cheap and prompt-free.
        cache(credentials: best, persist: true)
        return best
    }

    /// Latest-expiry wins; a dated token beats one with unknown expiry.
    private func freshest(of creds: [OAuthCredentials]) -> OAuthCredentials? {
        creds.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    private func isExpired(_ creds: OAuthCredentials, skew: TimeInterval = 60) -> Bool {
        guard let expiresAt = creds.expiresAt else { return false }
        return expiresAt <= Date().addingTimeInterval(skew)
    }

    /// Parses the `{ "claudeAiOauth": { ... } }` shape shared by the credentials
    /// file, the keychain, and the `security` CLI output.
    private func parseCredentialsJSON(_ data: Data) -> OAuthCredentials? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String else {
            return nil
        }

        let refreshToken = oauth["refreshToken"] as? String
        var expiresAt: Date?
        if let expiresMs = oauth["expiresAt"] as? Double {
            expiresAt = Date(timeIntervalSince1970: expiresMs / 1000.0)
        }
        let scopes = oauth["scopes"] as? [String] ?? []

        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            scopes: scopes
        )
    }

    var hasCredentials: Bool {
        loadCredentials() != nil
    }

    func clearCache() {
        cachedCredentials = nil
        lastCredentialCheck = nil
    }

    func clearPersistedCredentials() {
        clearCache()
        CredentialStorage.shared.clearClaudeOAuthCredentials()
    }

    // MARK: - Read from ~/.claude/.credentials.json

    private func readCredentialsFile() -> OAuthCredentials? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let credPath = homeDir.appendingPathComponent(".claude/.credentials.json")

        guard FileManager.default.fileExists(atPath: credPath.path),
              let data = try? Data(contentsOf: credPath) else {
            return nil
        }
        return parseCredentialsJSON(data)
    }

    // MARK: - Read from Keychain (Claude CLI)

    private func readFreshestFromKeychain() -> OAuthCredentials? {
        // Claude Code may store several "Claude Code-credentials*" items (e.g. a
        // suffixed duplicate after re-login). Reading a secret can raise a
        // password prompt, so probe ATTRIBUTES first (never prompts), pick the
        // single newest item by modification date — Claude Code rewrites its
        // item on every refresh — and fetch only that one secret.
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(probe as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return nil
        }

        let claudeItems = items
            .filter { ($0[kSecAttrService as String] as? String)?.hasPrefix(claudeKeychainService) == true }
            .sorted {
                let a = $0[kSecAttrModificationDate as String] as? Date ?? .distantPast
                let b = $1[kSecAttrModificationDate as String] as? Date ?? .distantPast
                return a > b
            }

        guard let newest = claudeItems.first else { return nil }

        // Prefer the Apple-signed `security` tool: an "Always Allow" granted to
        // it survives app updates, unlike one granted to Usagebar's own binary.
        if let service = newest[kSecAttrService as String] as? String,
           let creds = readFromKeychainUsingSecurityCLI(service: service) {
            return creds
        }

        // Fall back to a direct read of that same single item.
        guard let ref = newest[kSecValuePersistentRef as String] else { return nil }
        let dataQuery: [String: Any] = [
            kSecValuePersistentRef as String: ref,
            kSecReturnData as String: true
        ]
        var dataResult: AnyObject?
        guard SecItemCopyMatching(dataQuery as CFDictionary, &dataResult) == errSecSuccess,
              let data = dataResult as? Data else {
            return nil
        }
        return parseCredentialsJSON(data)
    }

    private func readFromKeychainUsingSecurityCLI(service: String) -> OAuthCredentials? {
        guard FileManager.default.isExecutableFile(atPath: securityBinaryPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityBinaryPath)
        process.arguments = [
            "find-generic-password",
            "-s",
            service,
            "-w",
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = nil

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(securityCLIReadTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        var data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        while let last = data.last, last == 0x0A || last == 0x0D {
            data.removeLast()
        }

        guard !data.isEmpty else {
            return nil
        }

        return parseCredentialsJSON(data)
    }

    // MARK: - Fetch Usage via OAuth

    func fetchUsage() async throws -> UsageData {
        try await fetchUsage(allowRediscovery: true)
    }

    private func fetchUsage(allowRediscovery: Bool) async throws -> UsageData {
        guard var creds = loadCredentials() else {
            throw APIError.noCredentials
        }

        // Refresh slightly before expiry to avoid a stale-token race in the menu refresh loop.
        if isExpired(creds) {
            // Claude Code proactively refreshes its own token. Before we rotate
            // the refresh token ourselves (which would invalidate Claude Code's
            // copy and vice-versa), force-reload every source in case Claude Code
            // already has a newer token waiting.
            if let reloaded = loadCredentials(forceReload: true), !isExpired(reloaded) {
                creds = reloaded
            } else if let refreshToken = creds.refreshToken {
                do {
                    creds = try await refreshAccessToken(refreshToken: refreshToken)
                    cache(credentials: creds, persist: true)
                } catch APIError.rateLimited {
                    // Temporary throttle: keep the mirror, try again next tick.
                    throw APIError.rateLimited
                } catch {
                    // The persisted mirror can hold a dead refresh token while the
                    // Claude CLI keychain/file has a fresh one. Drop the mirror and
                    // rediscover once instead of staying stuck signed out.
                    clearPersistedCredentials()
                    if allowRediscovery {
                        return try await fetchUsage(allowRediscovery: false)
                    }
                    throw APIError.unauthorized
                }
            } else {
                clearPersistedCredentials()
                throw APIError.unauthorized
            }
        }

        guard let url = URL(string: usageEndpoint) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(oauthUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseOAuthUsageResponse(data)
        case 429:
            throw APIError.rateLimited
        case 400, 401, 403:
            // Try refresh once
            if let refreshToken = creds.refreshToken {
                do {
                    let newCreds = try await refreshAccessToken(refreshToken: refreshToken)
                    cache(credentials: newCreds, persist: true)

                    var retryRequest = request
                    retryRequest.setValue("Bearer \(newCreds.accessToken)", forHTTPHeaderField: "Authorization")
                    let (retryData, retryResponse) = try await URLSession.shared.data(for: retryRequest)
                    guard let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 200 else {
                        clearPersistedCredentials()
                        throw APIError.unauthorized
                    }
                    return try parseOAuthUsageResponse(retryData)
                } catch APIError.rateLimited {
                    // Temporary throttle: keep credentials, try again next tick.
                    throw APIError.rateLimited
                } catch {
                    clearPersistedCredentials()
                    throw APIError.unauthorized
                }
            }
            if Self.isExpiredOAuthResponse(data) {
                clearPersistedCredentials()
                throw APIError.unauthorized
            }
            clearPersistedCredentials()
            throw httpResponse.statusCode == 400 ? APIError.unknown(httpResponse.statusCode) : APIError.unauthorized
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(refreshToken: String) async throws -> OAuthCredentials {
        guard let url = URL(string: tokenEndpoint) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: oauthClientId)
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }
        if httpResponse.statusCode == 429 {
            throw APIError.rateLimited
        }
        guard httpResponse.statusCode == 200 else {
            throw APIError.unauthorized
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw APIError.decodingError(NSError(domain: "OAuth", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid refresh response"]))
        }

        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
        var expiresAt: Date?
        if let expiresIn = json["expires_in"] as? Double {
            expiresAt = Date().addingTimeInterval(expiresIn)
        }

        return OAuthCredentials(
            accessToken: accessToken,
            refreshToken: newRefreshToken,
            expiresAt: expiresAt,
            scopes: cachedCredentials?.scopes ?? []
        )
    }

    private func cache(credentials: OAuthCredentials, persist: Bool = false) {
        cachedCredentials = credentials
        lastCredentialCheck = Date()

        guard persist else {
            return
        }

        CredentialStorage.shared.claudeOAuthCredentials = .init(
            accessToken: credentials.accessToken,
            refreshToken: credentials.refreshToken,
            expiresAt: credentials.expiresAt,
            scopes: credentials.scopes
        )
    }

    private func readPersistedCredentials() -> OAuthCredentials? {
        guard let stored = CredentialStorage.shared.claudeOAuthCredentials else {
            return nil
        }

        return OAuthCredentials(
            accessToken: stored.accessToken,
            refreshToken: stored.refreshToken,
            expiresAt: stored.expiresAt,
            scopes: stored.scopes
        )
    }

    private static func isExpiredOAuthResponse(_ data: Data) -> Bool {
        guard let body = String(data: data, encoding: .utf8)?.lowercased() else {
            return false
        }

        return body.contains("oauth token has expired")
            || body.contains("\"authentication_error\"")
            || body.contains("invalid_grant")
    }

    // MARK: - Parse Response

    private func parseOAuthUsageResponse(_ data: Data) throws -> UsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]))
        }

        var usageData = UsageData()

        if let fiveHour = json["five_hour"] as? [String: Any] {
            if let utilization = fiveHour["utilization"] as? Double {
                usageData.fiveHourUsed = Int(utilization)
                usageData.fiveHourLimit = 100
            }
            if let resetsAt = fiveHour["resets_at"] as? String {
                usageData.fiveHourResetAt = parseDate(resetsAt)
            }
        }

        if let sevenDay = json["seven_day"] as? [String: Any] {
            if let utilization = sevenDay["utilization"] as? Double {
                usageData.weeklyUsed = Int(utilization)
                usageData.weeklyLimit = 100
            }
            if let resetsAt = sevenDay["resets_at"] as? String {
                usageData.weeklyResetAt = parseDate(resetsAt)
            }
        }

        parseFableUsage(from: json, into: &usageData)

        return usageData
    }

    /// Fable weekly usage arrives in two shapes across API versions:
    ///  1. Newer: a `limits` array of model-scoped weekly entries, each with
    ///     `scope.model.display_name` ("Fable") plus `percent`/`resets_at`.
    ///  2. Older: a top-level `seven_day_overage_included` window (labeled
    ///     "Fable 5 limit" in Claude Code), or any fable/mythos-named window.
    private func parseFableUsage(from json: [String: Any], into usageData: inout UsageData) {
        // Shape 1: model-scoped weekly limits.
        if let limits = json["limits"] as? [[String: Any]] {
            for entry in limits {
                let scope = entry["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String
                    ?? model?["id"] as? String
                    ?? "").lowercased()
                guard name.contains("fable") || name.contains("mythos") else { continue }

                if let percent = entry["percent"] as? Double {
                    usageData.fableUsed = Int(percent)
                } else if let percent = entry["percent"] as? Int {
                    usageData.fableUsed = percent
                }
                if let resetsAt = entry["resets_at"] as? String {
                    usageData.fableResetAt = parseDate(resetsAt)
                }
                if usageData.fableUsed != nil { return }
            }
        }

        // Shape 2: dedicated top-level window.
        var fableWindow = json["seven_day_overage_included"] as? [String: Any]
        if fableWindow == nil {
            fableWindow = json.first { key, value in
                let lowered = key.lowercased()
                return (lowered.contains("fable") || lowered.contains("mythos")) && value is [String: Any]
            }?.value as? [String: Any]
        }
        if let window = fableWindow, let utilization = window["utilization"] as? Double {
            usageData.fableUsed = Int(utilization)
            if let resetsAt = window["resets_at"] as? String {
                usageData.fableResetAt = parseDate(resetsAt)
            }
        }
    }

    private func parseDate(_ string: String) -> Date? {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: string) { return date }
        iso8601.formatOptions = [.withInternetDateTime]
        return iso8601.date(from: string)
    }
}
