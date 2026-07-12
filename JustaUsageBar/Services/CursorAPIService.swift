//
//  CursorAPIService.swift
//  JustaUsageBar
//
//  Reads Cursor.app's local auth token and fetches usage from cursor.com.
//  Approach mirrors CodexBar: read the accessToken JWT from Cursor's VS Code
//  state.vscdb, synthesize a WorkosCursorSessionToken cookie, call the web API.
//

import Foundation
import SQLite3

// MARK: - Cursor Usage Data Model

struct CursorUsageData {
    var planName: String = "unknown"
    var usedPercent: Int = 0
    var resetAt: Date?
    /// On-demand / usage-based spend in USD for the current cycle, when present.
    var onDemandUsedUSD: Double?
    var onDemandLimitUSD: Double?

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

    static let placeholder = CursorUsageData()
}

// MARK: - Cursor API Service

final class CursorAPIService {
    static let shared = CursorAPIService()

    private let usageSummaryEndpoint = "https://cursor.com/api/usage-summary"

    private var cachedToken: CursorToken?
    private var lastTokenCheck: Date?
    private let tokenCacheTTL: TimeInterval = 300

    private struct CursorToken {
        let userID: String
        let accessToken: String
        let expiresAt: Date?

        /// Cookie Cursor's web API expects: WorkosCursorSessionToken=<userID>::<jwt>
        var cookieHeader: String {
            let value = "\(userID)::\(accessToken)"
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .cursorCookieAllowed) ?? value
            return "WorkosCursorSessionToken=\(encoded)"
        }
    }

    private init() {}

    // MARK: - Credential Discovery

    private var stateDBURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    var hasCredentials: Bool {
        loadToken() != nil
    }

    func clearCache() {
        cachedToken = nil
        lastTokenCheck = nil
    }

    private func loadToken() -> CursorToken? {
        if let lastCheck = lastTokenCheck,
           Date().timeIntervalSince(lastCheck) < tokenCacheTTL,
           let cachedToken {
            return cachedToken
        }

        guard let accessToken = readStateValue(key: "cursorAuth/accessToken"),
              !accessToken.isEmpty,
              let claims = decodeJWTClaims(accessToken),
              let sub = claims["sub"] as? String else {
            return nil
        }

        // sub is typically "auth0|user_..." — Cursor's cookie wants the trailing id.
        let userID = sub.split(separator: "|").last.map(String.init) ?? sub

        var expiresAt: Date?
        if let exp = claims["exp"] as? Double {
            expiresAt = Date(timeIntervalSince1970: exp)
        }

        let token = CursorToken(userID: userID, accessToken: accessToken, expiresAt: expiresAt)
        cachedToken = token
        lastTokenCheck = Date()
        return token
    }

    /// Reads a single value from the VS Code-style SQLite key/value store,
    /// opened read-only so we never contend with a running Cursor.
    private func readStateValue(key: String) -> String? {
        guard FileManager.default.fileExists(atPath: stateDBURL.path) else { return nil }

        var db: OpaquePointer?
        let uri = "file:\(stateDBURL.path)?mode=ro&immutable=1"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        // SQLITE_TRANSIENT so SQLite copies the key bytes.
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, key, -1, transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        switch sqlite3_column_type(stmt, 0) {
        case SQLITE_TEXT:
            guard let cString = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: cString)
        case SQLITE_BLOB:
            guard let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
            let count = Int(sqlite3_column_bytes(stmt, 0))
            let data = Data(bytes: bytes, count: count)
            return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16LittleEndian)
        default:
            return nil
        }
    }

    private func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> CursorUsageData {
        var token = loadToken()
        // Cursor.app refreshes its own token in the DB; if our cached copy is
        // expired, drop it and re-read the fresh one before making the request.
        if let current = token, let expiresAt = current.expiresAt, expiresAt <= Date() {
            clearCache()
            token = loadToken()
        }
        guard let token else {
            throw APIError.noCredentials
        }

        guard let url = URL(string: usageSummaryEndpoint) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(token.cookieHeader, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }

        switch httpResponse.statusCode {
        case 200:
            return try parseUsageSummary(data)
        case 401, 403:
            clearCache()
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    // MARK: - Parse

    private func parseUsageSummary(_ data: Data) throws -> CursorUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.decodingError(NSError(domain: "Cursor", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]))
        }

        var usage = CursorUsageData()

        if let membership = json["membershipType"] as? String, !membership.isEmpty {
            usage.planName = membership
        }

        // Billing cycle end → reset date.
        if let end = json["billingCycleEnd"] as? String {
            usage.resetAt = parseDate(end)
        }

        let individual = json["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]

        // Percentage precedence mirrors CodexBar: totalPercentUsed, then the
        // average of the auto/api lanes, then either lane, then used/limit.
        if let total = doubleValue(plan?["totalPercentUsed"]) {
            usage.usedPercent = clampPercent(total)
        } else {
            let auto = doubleValue(plan?["autoPercentUsed"])
            let api = doubleValue(plan?["apiPercentUsed"])
            if let auto, let api {
                usage.usedPercent = clampPercent((auto + api) / 2)
            } else if let single = auto ?? api {
                usage.usedPercent = clampPercent(single)
            } else if let used = doubleValue(plan?["used"]), let limit = doubleValue(plan?["limit"]), limit > 0 {
                usage.usedPercent = clampPercent(used / limit * 100)
            }
        }

        // On-demand / usage-based spend (values are in cents).
        if let onDemand = individual?["onDemand"] as? [String: Any] {
            if let used = doubleValue(onDemand["used"]) {
                usage.onDemandUsedUSD = used / 100.0
            }
            if let limit = doubleValue(onDemand["limit"]) {
                usage.onDemandLimitUSD = limit / 100.0
            }
        }

        return usage
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

    private func parseDate(_ string: String) -> Date? {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: string) { return date }
        iso8601.formatOptions = [.withInternetDateTime]
        return iso8601.date(from: string)
    }
}

private extension CharacterSet {
    /// Percent-encode the cookie value but keep JWT-safe characters intact.
    static let cursorCookieAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()
}
