//
//  KimiAPIService.swift
//  JustaUsageBar
//
//  Reuses Kimi Code CLI credentials or a manually supplied Kimi credential
//  and fetches weekly plus 5-hour coding usage directly from Kimi.
//

import Foundation

enum KimiAuthSource: String {
    case none
    case apiKey
    case cli
    case webToken

    var displayName: String {
        switch self {
        case .none:
            return ""
        case .apiKey:
            return "via API Key"
        case .cli:
            return "via Kimi CLI"
        case .webToken:
            return "via Web Token"
        }
    }
}

struct KimiUsageData {
    var weeklyUsedPercent: Int = 0
    var weeklyResetAt: Date?
    var fiveHourUsedPercent: Int?
    var fiveHourResetAt: Date?

    var timeUntilWeeklyReset: String {
        formatTimeUntil(weeklyResetAt)
    }

    var timeUntilFiveHourReset: String {
        formatTimeUntil(fiveHourResetAt)
    }

    private func formatTimeUntil(_ date: Date?) -> String {
        guard let date else { return "--" }
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return "Now" }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 {
            return "\(hours / 24)d \(hours % 24)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }

    static let placeholder = KimiUsageData()
}

enum KimiServiceError: LocalizedError {
    case noCredentials
    case expiredCLICredential
    case unauthorized
    case rateLimited
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "Run `kimi login` or add a Kimi credential"
        case .expiredCLICredential:
            return "Kimi CLI login expired — run `kimi login` again"
        case .unauthorized:
            return "Kimi credential expired — sign in again"
        case .rateLimited:
            return "Kimi usage could not be verified right now"
        case .invalidResponse:
            return "Kimi returned an unsupported usage response"
        case .httpStatus(let status):
            return "Kimi usage request failed (status: \(status))"
        }
    }
}

final class KimiAPIService {
    static let shared = KimiAPIService()

    private let codeUsageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private let webUsageURL = URL(
        string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages"
    )!
    private let session: URLSession

    private(set) var lastAuthSource: KimiAuthSource = .none

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    var hasCredentials: Bool {
        if normalized(CredentialStorage.shared.kimiCredential) != nil {
            return true
        }

        let environment = ProcessInfo.processInfo.environment
        if normalized(environment["KIMI_CODE_API_KEY"]) != nil ||
            normalized(environment["KIMI_AUTH_TOKEN"]) != nil {
            return true
        }

        guard let credential = loadCLICredential() else { return false }
        return normalized(credential.accessToken) != nil || normalized(credential.refreshToken) != nil
    }

    var hasSavedCredential: Bool {
        normalized(CredentialStorage.shared.kimiCredential) != nil
    }

    var detectedAuthSource: KimiAuthSource {
        let environment = ProcessInfo.processInfo.environment
        if let stored = normalized(CredentialStorage.shared.kimiCredential), !isWebToken(stored) {
            return .apiKey
        }
        if normalized(environment["KIMI_CODE_API_KEY"]) != nil {
            return .apiKey
        }
        if let credential = loadCLICredential(),
           normalized(credential.accessToken) != nil || normalized(credential.refreshToken) != nil {
            return .cli
        }
        if normalized(CredentialStorage.shared.kimiCredential) != nil ||
            normalized(environment["KIMI_AUTH_TOKEN"]) != nil {
            return .webToken
        }
        return .none
    }

    func clearCache() {
        lastAuthSource = .none
    }

    func fetchUsage() async throws -> KimiUsageData {
        let candidates = credentialCandidates()
        guard !candidates.isEmpty else {
            if hasExpiredCLICredential {
                throw KimiServiceError.expiredCLICredential
            }
            throw KimiServiceError.noCredentials
        }

        var lastError: Error?
        for candidate in candidates {
            do {
                let usage: KimiUsageData
                switch candidate {
                case .codeAPI(let token, let source):
                    usage = try await fetchCodeAPIUsage(token: token, includeCLIIdentity: source == .cli)
                    lastAuthSource = source
                case .web(let token):
                    usage = try await fetchWebUsage(token: token)
                    lastAuthSource = .webToken
                }
                return usage
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw KimiServiceError.noCredentials
    }

    // MARK: - Credential discovery

    private enum CredentialCandidate {
        case codeAPI(String, KimiAuthSource)
        case web(String)
    }

    private func credentialCandidates() -> [CredentialCandidate] {
        let environment = ProcessInfo.processInfo.environment
        var apiCandidates: [CredentialCandidate] = []
        var webCandidates: [CredentialCandidate] = []

        if let stored = normalized(CredentialStorage.shared.kimiCredential) {
            if let webToken = extractWebToken(from: stored) {
                webCandidates.append(.web(webToken))
            } else {
                apiCandidates.append(.codeAPI(stored, .apiKey))
            }
        }

        if let apiKey = normalized(environment["KIMI_CODE_API_KEY"]) {
            apiCandidates.append(.codeAPI(apiKey, .apiKey))
        }

        if let cliToken = freshCLIAccessToken {
            apiCandidates.append(.codeAPI(cliToken, .cli))
        }

        if let webToken = extractWebToken(from: environment["KIMI_AUTH_TOKEN"]) {
            webCandidates.append(.web(webToken))
        }

        return apiCandidates + webCandidates
    }

    private var kimiCodeHomeURL: URL {
        if let override = normalized(ProcessInfo.processInfo.environment["KIMI_CODE_HOME"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code", isDirectory: true)
    }

    private var cliCredentialURL: URL {
        kimiCodeHomeURL
            .appendingPathComponent("credentials", isDirectory: true)
            .appendingPathComponent("kimi-code.json", isDirectory: false)
    }

    private var freshCLIAccessToken: String? {
        guard let credential = loadCLICredential(),
              let token = normalized(credential.accessToken),
              let expiresAt = credential.expiresAt,
              expiresAt > Date().addingTimeInterval(60).timeIntervalSince1970 else {
            return nil
        }
        return token
    }

    private var hasExpiredCLICredential: Bool {
        guard let credential = loadCLICredential() else { return false }
        let hasToken = normalized(credential.accessToken) != nil || normalized(credential.refreshToken) != nil
        guard hasToken else { return false }
        guard let expiresAt = credential.expiresAt else { return true }
        return expiresAt <= Date().addingTimeInterval(60).timeIntervalSince1970
    }

    private func loadCLICredential() -> KimiCodeOAuthCredential? {
        guard let data = try? Data(contentsOf: cliCredentialURL) else { return nil }
        return try? JSONDecoder().decode(KimiCodeOAuthCredential.self, from: data)
    }

    private func normalized(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func isWebToken(_ value: String) -> Bool {
        extractWebToken(from: value) != nil
    }

    private func extractWebToken(from raw: String?) -> String? {
        guard let value = normalized(raw) else { return nil }

        if value.hasPrefix("eyJ"), value.split(separator: ".").count == 3 {
            return value
        }

        guard let range = value.range(of: "kimi-auth=", options: .caseInsensitive) else {
            return nil
        }
        let suffix = value[range.upperBound...]
        let token = suffix.prefix { !"; \t\r\n\"'".contains($0) }
        return normalized(String(token))
    }

    // MARK: - API requests

    private func fetchCodeAPIUsage(token: String, includeCLIIdentity: Bool) async throws -> KimiUsageData {
        var request = URLRequest(url: codeUsageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if includeCLIIdentity {
            for (name, value) in cliIdentityHeaders() {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }

        let data = try await responseData(for: request)
        return try parseCodeAPIUsage(data)
    }

    private func fetchWebUsage(token: String) async throws -> KimiUsageData {
        var request = URLRequest(url: webUsageURL)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")

        for (name, value) in webIdentityHeaders(from: token) {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data = try await responseData(for: request)
        return try parseWebUsage(data)
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw KimiServiceError.invalidResponse
            }
            switch response.statusCode {
            case 200:
                return data
            case 401, 403:
                throw KimiServiceError.unauthorized
            case 429:
                throw KimiServiceError.rateLimited
            default:
                throw KimiServiceError.httpStatus(response.statusCode)
            }
        } catch let error as KimiServiceError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    private func cliIdentityHeaders() -> [String: String] {
        let version = normalized(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "development"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        var headers = [
            "User-Agent": "Usagebar/\(version)",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": version,
            "X-Msh-Os-Version": osVersion,
            "X-Msh-Device-Name": asciiHeaderValue(ProcessInfo.processInfo.hostName),
            "X-Msh-Device-Model": asciiHeaderValue("macOS \(osVersion) \(architectureName)")
        ]

        let deviceIDURL = kimiCodeHomeURL.appendingPathComponent("device_id", isDirectory: false)
        if let deviceID = normalized(try? String(contentsOf: deviceIDURL, encoding: .utf8)) {
            headers["X-Msh-Device-Id"] = deviceID
        }
        return headers
    }

    private var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    private func asciiHeaderValue(_ raw: String) -> String {
        var ascii = ""
        for scalar in raw.unicodeScalars where (0x20...0x7E).contains(scalar.value) {
            ascii.unicodeScalars.append(scalar)
        }
        return normalized(ascii) ?? "unknown"
    }

    private func webIdentityHeaders(from token: String) -> [String: String] {
        let parts = token.split(separator: ".", maxSplits: 2)
        guard parts.count == 3 else { return [:] }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }

        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var headers: [String: String] = [:]
        if let value = claims["device_id"] as? String { headers["x-msh-device-id"] = value }
        if let value = claims["ssid"] as? String { headers["x-msh-session-id"] = value }
        if let value = claims["sub"] as? String { headers["x-traffic-id"] = value }
        return headers
    }

    // MARK: - Parsing

    private struct UsageDetail {
        let limit: Double
        let used: Double
        let resetAt: Date?
    }

    private func parseCodeAPIUsage(_ data: Data) throws -> KimiUsageData {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weeklyObject = root["usage"] as? [String: Any],
              let weekly = parseDetail(weeklyObject) else {
            throw KimiServiceError.invalidResponse
        }
        return makeUsageData(weekly: weekly, limits: root["limits"] as? [[String: Any]])
    }

    private func parseWebUsage(_ data: Data) throws -> KimiUsageData {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usages = root["usages"] as? [[String: Any]],
              let coding = usages.first(where: { ($0["scope"] as? String) == "FEATURE_CODING" }),
              let weeklyObject = coding["detail"] as? [String: Any],
              let weekly = parseDetail(weeklyObject) else {
            throw KimiServiceError.invalidResponse
        }
        return makeUsageData(weekly: weekly, limits: coding["limits"] as? [[String: Any]])
    }

    private func makeUsageData(weekly: UsageDetail, limits: [[String: Any]]?) -> KimiUsageData {
        let rateLimitEntry = limits?.first(where: { entry in
            guard let window = entry["window"] as? [String: Any] else { return false }
            let duration = number(window["duration"]).map(Int.init) ?? 0
            let unit = (window["timeUnit"] as? String)?.uppercased() ?? ""
            return duration == 300 && unit.contains("MINUTE")
        }) ?? limits?.first

        let rateLimit = (rateLimitEntry?["detail"] as? [String: Any]).flatMap(parseDetail)
        return KimiUsageData(
            weeklyUsedPercent: percent(for: weekly),
            weeklyResetAt: weekly.resetAt,
            fiveHourUsedPercent: rateLimit.map(percent),
            fiveHourResetAt: rateLimit?.resetAt
        )
    }

    private func parseDetail(_ object: [String: Any]) -> UsageDetail? {
        guard let limit = number(object["limit"]), limit > 0 else { return nil }
        let remaining = number(object["remaining"])
        let used = number(object["used"]) ?? remaining.map { max(0, limit - $0) } ?? 0
        let resetText = ["resetTime", "resetAt", "reset_time", "reset_at"]
            .compactMap { object[$0] as? String }
            .first
        return UsageDetail(limit: limit, used: used, resetAt: parseDate(resetText))
    }

    private func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private func percent(for detail: UsageDetail) -> Int {
        Int(max(0, min(100, (detail.used / detail.limit * 100).rounded())))
    }

    private func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private struct KimiCodeOAuthCredential: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = (try? container.decode(String.self, forKey: .accessToken)) ?? ""
        refreshToken = (try? container.decode(String.self, forKey: .refreshToken)) ?? ""

        if let value = try? container.decode(Double.self, forKey: .expiresAt) {
            expiresAt = value
        } else if let value = try? container.decode(Int64.self, forKey: .expiresAt) {
            expiresAt = TimeInterval(value)
        } else if let value = try? container.decode(String.self, forKey: .expiresAt) {
            expiresAt = TimeInterval(value)
        } else {
            expiresAt = nil
        }
    }
}
