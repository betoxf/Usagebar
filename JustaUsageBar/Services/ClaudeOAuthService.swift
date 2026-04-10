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

    func loadCredentials() -> OAuthCredentials? {
        if let lastCheck = lastCredentialCheck,
           Date().timeIntervalSince(lastCheck) < cacheTTL {
            return cachedCredentials
        }

        // 1. Prefer the app's own encrypted mirror so updates don't trigger repeated
        // macOS password prompts for the same Claude OAuth credentials.
        if let creds = readPersistedCredentials() {
            cache(credentials: creds)
            return creds
        }

        // 2. Try credentials file (~/.claude/.credentials.json) when available.
        if let creds = readCredentialsFile() {
            cache(credentials: creds, persist: true)
            return creds
        }

        // 3. Prefer the stable Apple-signed `security` tool before a direct GUI
        // Keychain read so app updates don't look like a new requester to Keychain.
        if let creds = readFromKeychainUsingSecurityCLI() {
            cache(credentials: creds, persist: true)
            return creds
        }

        // 4. Fall back to a direct Keychain read only when the safer paths miss.
        if let creds = readFromKeychain() {
            cache(credentials: creds, persist: true)
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

    func clearPersistedCredentials() {
        clearCache()
        CredentialStorage.shared.clearClaudeOAuthCredentials()
    }

    // MARK: - Read from ~/.claude/.credentials.json

    private func readCredentialsFile() -> OAuthCredentials? {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let credPath = homeDir.appendingPathComponent(".claude/.credentials.json")

        guard FileManager.default.fileExists(atPath: credPath.path),
              let data = try? Data(contentsOf: credPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    // MARK: - Read from Keychain (Claude CLI)

    private func readFromKeychain() -> OAuthCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeKeychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    private func readFromKeychainUsingSecurityCLI() -> OAuthCredentials? {
        guard FileManager.default.isExecutableFile(atPath: securityBinaryPath) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityBinaryPath)
        process.arguments = [
            "find-generic-password",
            "-s",
            claudeKeychainService,
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

    // MARK: - Fetch Usage via OAuth

    func fetchUsage() async throws -> UsageData {
        guard var creds = loadCredentials() else {
            throw APIError.noCredentials
        }

        // Refresh slightly before expiry to avoid a stale-token race in the menu refresh loop.
        if let expiresAt = creds.expiresAt, expiresAt <= Date().addingTimeInterval(60) {
            if let refreshToken = creds.refreshToken {
                creds = try await refreshAccessToken(refreshToken: refreshToken)
                cache(credentials: creds, persist: true)
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

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
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

        return usageData
    }

    private func parseDate(_ string: String) -> Date? {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: string) { return date }
        iso8601.formatOptions = [.withInternetDateTime]
        return iso8601.date(from: string)
    }
}
