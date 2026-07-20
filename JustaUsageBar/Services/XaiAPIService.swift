//
//  XaiAPIService.swift
//  JustaUsageBar
//
//  Discovers Grok Build / xAI OIDC credentials from ~/.grok/auth.json,
//  refreshes them through auth.x.ai, and fetches weekly Grok Build usage
//  from the CLI billing endpoint.
//

import Foundation

// MARK: - XAI Usage Data Model

struct XaiUsageData {
    /// Subscription tier label when present (for example "X Premium").
    var planName: String = "unknown"
    /// Grok Build product usage for the current weekly credits window.
    var buildUsedPercent: Int = 0
    /// Overall weekly credit usage across Grok products.
    var weeklyUsedPercent: Int = 0
    var weeklyResetAt: Date?
    /// True when the payload included an explicit GrokBuild product row.
    var hasBuildProduct: Bool = false

    var timeUntilWeeklyReset: String {
        formatTimeUntil(weeklyResetAt)
    }

    /// Prefer the Grok Build product percentage for the status item; fall back
    /// to the overall weekly credits figure when product usage is absent.
    var primaryUsedPercent: Int {
        hasBuildProduct ? buildUsedPercent : weeklyUsedPercent
    }

    var primaryWindowLabel: String {
        "W"
    }

    static let placeholder = XaiUsageData()

    private func formatTimeUntil(_ date: Date?) -> String {
        guard let date else { return "--" }
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
}

// MARK: - XAI API Service

final class XaiAPIService {
    static let shared = XaiAPIService()

    private let billingEndpoint = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    private let openIDConfigurationURL = URL(string: "https://auth.x.ai/.well-known/openid-configuration")!
    private let authFileName = "auth.json"
    private let defaultAuthDirectoryName = ".grok"

    private var cachedCredential: XaiAuthCredential??
    private var lastCredentialCheck: Date?
    private let credentialCacheTTL: TimeInterval = 30
    private var tokenEndpointCache: URL?
    private let fileManager = FileManager.default
    private let isoParsers: [ISO8601DateFormatter] = {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        basic.formatOptions = [.withInternetDateTime]
        return [withFractional, basic]
    }()

    private init() {}

    // MARK: - Credential Discovery

    func clearCache() {
        cachedCredential = nil
        lastCredentialCheck = nil
        tokenEndpointCache = nil
    }

    var hasCredentials: Bool {
        loadCredential() != nil
    }

    private func loadCredential(forceReload: Bool = false) -> XaiAuthCredential? {
        if !forceReload,
           let lastCredentialCheck,
           Date().timeIntervalSince(lastCredentialCheck) < credentialCacheTTL,
           let cachedCredential {
            return cachedCredential
        }

        let resolved = resolveCredential()
        cachedCredential = .some(resolved)
        lastCredentialCheck = Date()
        return resolved
    }

    private func resolveCredential() -> XaiAuthCredential? {
        guard let authURL = authFileURL(),
              let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var best: XaiAuthCredential?
        for (key, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            guard let accessToken = stringValue(entry["key"]) ?? stringValue(entry["access_token"]),
                  !accessToken.isEmpty else {
                continue
            }

            let refreshToken = stringValue(entry["refresh_token"])
            let expiresAt = parseDate(entry["expires_at"])
            let clientID = stringValue(entry["oidc_client_id"])
                ?? clientID(fromStorageKey: key)
            let issuer = stringValue(entry["oidc_issuer"]) ?? "https://auth.x.ai"
            let planHint = stringValue(entry["subscription_tier"])
                ?? stringValue(entry["subscriptionTier"])
            let email = stringValue(entry["email"])

            let candidate = XaiAuthCredential(
                storageKey: key,
                accessToken: accessToken,
                refreshToken: refreshToken,
                expiresAt: expiresAt,
                clientID: clientID,
                issuer: issuer,
                planHint: planHint,
                email: email,
                authFileURL: authURL
            )

            if best == nil || candidate.isFresher(than: best!) {
                best = candidate
            }
        }
        return best
    }

    private func authFileURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let custom = env["GROK_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent(authFileName)
        }
        let home = fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent(defaultAuthDirectoryName).appendingPathComponent(authFileName)
    }

    private func clientID(fromStorageKey key: String) -> String? {
        // Storage keys look like "https://auth.x.ai::b1a00492-..."
        let parts = key.components(separatedBy: "::")
        guard parts.count >= 2 else { return nil }
        let clientID = parts.last?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (clientID?.isEmpty == false) ? clientID : nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> XaiUsageData {
        let accessToken = try await usableAccessToken()
        var request = URLRequest(url: billingEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("cli", forHTTPHeaderField: "x-grok-client-mode")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseBilling(data)
        case 401, 403:
            // One forced refresh retry, then surface unauthorized.
            let refreshedToken = try await usableAccessToken(forceRefresh: true)
            var retry = request
            retry.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
            let (retryData, retryResponse) = try await URLSession.shared.data(for: retry)
            guard let retryHTTP = retryResponse as? HTTPURLResponse else {
                throw APIError.unknown(0)
            }
            switch retryHTTP.statusCode {
            case 200:
                return try parseBilling(retryData)
            case 401, 403:
                throw APIError.unauthorized
            case 429:
                throw APIError.rateLimited
            default:
                throw APIError.unknown(retryHTTP.statusCode)
            }
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    private func usableAccessToken(forceRefresh: Bool = false) async throws -> String {
        guard let credential = loadCredential(forceReload: true) else {
            throw APIError.noCredentials
        }

        if !forceRefresh, credential.hasUsableAccessToken {
            return credential.accessToken
        }

        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty,
              let clientID = credential.clientID, !clientID.isEmpty else {
            if credential.hasUsableAccessToken {
                return credential.accessToken
            }
            throw APIError.unauthorized
        }

        let refreshed = try await refreshCredential(credential, refreshToken: refreshToken, clientID: clientID)
        try persistCredential(refreshed)
        cachedCredential = .some(refreshed)
        lastCredentialCheck = Date()
        return refreshed.accessToken
    }

    private func refreshCredential(
        _ credential: XaiAuthCredential,
        refreshToken: String,
        clientID: String
    ) async throws -> XaiAuthCredential {
        let tokenURL = try await resolveTokenEndpoint(issuer: credential.issuer)
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID)
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }
        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw APIError.unauthorized
            }
            throw APIError.unknown(httpResponse.statusCode)
        }

        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = stringValue(payload["access_token"]), !accessToken.isEmpty else {
            throw APIError.decodingError(NSError(domain: "XAI", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Token refresh response missing access_token"
            ]))
        }

        let newRefresh = stringValue(payload["refresh_token"]) ?? refreshToken
        let expiresIn = doubleValue(payload["expires_in"]) ?? 21_600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        return XaiAuthCredential(
            storageKey: credential.storageKey,
            accessToken: accessToken,
            refreshToken: newRefresh,
            expiresAt: expiresAt,
            clientID: clientID,
            issuer: credential.issuer,
            planHint: credential.planHint,
            email: credential.email,
            authFileURL: credential.authFileURL
        )
    }

    private func resolveTokenEndpoint(issuer: String) async throws -> URL {
        if let tokenEndpointCache {
            return tokenEndpointCache
        }

        // Prefer issuer discovery when available; fall back to the known xAI path.
        let discoveryURL: URL
        if let issuerURL = URL(string: issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
           let wellKnown = URL(string: issuerURL.absoluteString + "/.well-known/openid-configuration") {
            discoveryURL = wellKnown
        } else {
            discoveryURL = openIDConfigurationURL
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: discoveryURL)
            if let http = response as? HTTPURLResponse, http.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let endpoint = stringValue(json["token_endpoint"]),
               let url = URL(string: endpoint) {
                tokenEndpointCache = url
                return url
            }
        } catch {
            // Fall through to the hard-coded endpoint.
        }

        let fallback = URL(string: "https://auth.x.ai/oauth2/token")!
        tokenEndpointCache = fallback
        return fallback
    }

    private func persistCredential(_ credential: XaiAuthCredential) throws {
        let url = credential.authFileURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }

        var entry = (root[credential.storageKey] as? [String: Any]) ?? [:]
        entry["key"] = credential.accessToken
        if let refreshToken = credential.refreshToken {
            entry["refresh_token"] = refreshToken
        }
        if let expiresAt = credential.expiresAt {
            entry["expires_at"] = isoParsers[0].string(from: expiresAt)
        }
        if let clientID = credential.clientID {
            entry["oidc_client_id"] = clientID
        }
        entry["oidc_issuer"] = credential.issuer
        root[credential.storageKey] = entry

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Parse

    private func parseBilling(_ data: Data) throws -> XaiUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError(NSError(domain: "XAI", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid JSON"
            ]))
        }

        let config = (json["config"] as? [String: Any]) ?? json
        var usage = XaiUsageData()

        if let percent = doubleValue(config["creditUsagePercent"]) {
            usage.weeklyUsedPercent = clampPercent(percent)
        }

        if let period = config["currentPeriod"] as? [String: Any] {
            usage.weeklyResetAt = parseDate(period["end"])
        } else {
            usage.weeklyResetAt = parseDate(config["billingPeriodEnd"])
        }

        if let products = config["productUsage"] as? [[String: Any]] {
            if let build = products.first(where: {
                let name = (stringValue($0["product"]) ?? "").lowercased()
                return name == "grokbuild" || name == "grok-build" || name.contains("build")
            }) {
                if let percent = doubleValue(build["usagePercent"]) {
                    usage.buildUsedPercent = clampPercent(percent)
                    usage.hasBuildProduct = true
                }
            }
        }

        // Live Grok Build billing is weekly credits. There is no separate 5-hour
        // window in the current billing payload, so the UI shows weekly usage.
        if !usage.hasBuildProduct {
            usage.buildUsedPercent = usage.weeklyUsedPercent
        }

        if let tier = stringValue(json["subscriptionTier"])
            ?? stringValue(config["subscriptionTier"])
            ?? stringValue(config["subscription_tier"])
            ?? loadCredential()?.planHint {
            usage.planName = prettyPlanName(tier)
        } else if let credential = loadCredential(), let email = credential.email, !email.isEmpty {
            usage.planName = email
        }

        return usage
    }

    private func prettyPlanName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }
        // XPremium -> X Premium, x_premium -> X Premium
        if trimmed.replacingOccurrences(of: " ", with: "").lowercased() == "xpremium" {
            return "X Premium"
        }
        if trimmed.contains(" ") { return trimmed }
        return trimmed
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let number = doubleValue(value) {
            // Support seconds and milliseconds epoch values.
            if number > 1_000_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000.0)
            }
            if number > 1_000_000_000 {
                return Date(timeIntervalSince1970: number)
            }
        }
        if let string = stringValue(value) {
            for parser in isoParsers {
                if let date = parser.date(from: string) {
                    return date
                }
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func clampPercent(_ value: Double) -> Int {
        Int(max(0, min(100, value.rounded())))
    }
}

// MARK: - Credential Model

private struct XaiAuthCredential {
    let storageKey: String
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?
    let clientID: String?
    let issuer: String
    let planHint: String?
    let email: String?
    let authFileURL: URL

    var hasUsableAccessToken: Bool {
        guard !accessToken.isEmpty else { return false }
        guard let expiresAt else {
            // Some older auth.json entries only carry expires_at on the JWT.
            return !isJWTExpired(accessToken)
        }
        // Refresh a few minutes early so background polls stay green.
        return expiresAt.timeIntervalSinceNow > 120
    }

    func isFresher(than other: XaiAuthCredential) -> Bool {
        let lhs = expiresAt ?? .distantPast
        let rhs = other.expiresAt ?? .distantPast
        if lhs != rhs { return lhs > rhs }
        return storageKey > other.storageKey
    }

    private func isJWTExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return false }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval ?? (json["exp"] as? Int).map(TimeInterval.init) else {
            return false
        }
        return Date(timeIntervalSince1970: exp).timeIntervalSinceNow <= 120
    }
}
