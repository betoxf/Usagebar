//
//  QwenAPIService.swift
//  JustaUsageBar
//
//  Reads the QwenCloud Token Plan's 5-hour, weekly and monthly windows.
//  Token Plan API keys cannot read their own quota, so this uses the session
//  of the QwenCloud console, saved by Usagebar's sign-in window, and the same
//  console gateway the subscription page calls.
//

import Foundation

// MARK: - Qwen Usage Data Model

nonisolated struct QwenUsageData: Equatable {
    var planName: String?
    var fiveHourUsedPercent: Int?
    var fiveHourResetAt: Date?
    var weeklyUsedPercent: Int?
    var weeklyResetAt: Date?
    var monthlyUsedPercent: Int?
    var monthlyResetAt: Date?

    /// The longer window shown beside the 5-hour one: weekly, else monthly.
    var longUsedPercent: Int { weeklyUsedPercent ?? monthlyUsedPercent ?? 0 }
    var longResetAt: Date? { weeklyUsedPercent != nil ? weeklyResetAt : monthlyResetAt }
    var longIsMonthly: Bool { weeklyUsedPercent == nil && monthlyUsedPercent != nil }
    var longLabel: String { longIsMonthly ? "30d" : "7d" }

    var timeUntilFiveHourReset: String { Self.timeUntil(fiveHourResetAt) }
    var timeUntilWeeklyReset: String { Self.timeUntil(weeklyResetAt) }
    var timeUntilMonthlyReset: String { Self.timeUntil(monthlyResetAt) }

    static func timeUntil(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "--" }
        guard date > now else { return "Now" }
        let interval = date.timeIntervalSince(now)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours >= 24 { return "\(hours / 24)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    static let placeholder = QwenUsageData()
}

// MARK: - Qwen API Service

@ProviderActor
final class QwenAPIService {
    static let shared = QwenAPIService()

    nonisolated static let dashboardURL = URL(string: "https://home.qwencloud.com/analytics/token-plan?region=ap-southeast-1")!
    private let gatewayURL = "https://cs-data.qwencloud.com/data/api.json"
    private let usageAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
    private let subscriptionAPI = "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/subscription"
    private let productCode = "sfm_tokenplansolo_public_intl"

    private init() {}

    var hasCredentials: Bool {
        CredentialStorage.shared.qwenCookie != nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> QwenUsageData {
        guard let cookie = CredentialStorage.shared.qwenCookie else {
            throw APIError.noCredentials
        }
        let secToken = try await secToken(cookie: cookie)
        let usage = try await call(api: usageAPI, data: [:], cookie: cookie, secToken: secToken)
        // The plan name is a nicety; usage stands without it.
        let subscription = try? await call(
            api: subscriptionAPI, data: ["commodityCode": productCode], cookie: cookie, secToken: secToken
        )
        guard var parsed = Self.parseUsage(usage) else {
            if Self.isSignedOut(usage) { throw APIError.unauthorized }
            throw APIError.decodingError(NSError(
                domain: "Qwen", code: 0, userInfo: [NSLocalizedDescriptionKey: "No usage windows in the response"]
            ))
        }
        parsed.planName = subscription.flatMap(Self.parsePlanName)
        return parsed
    }

    /// The console's per-session token, which every gateway call carries. The
    /// subscription page embeds it; the user info endpoint is the fallback.
    private func secToken(cookie: String) async throws -> String {
        var page = URLRequest(url: Self.dashboardURL)
        page.timeoutInterval = 20
        page.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        page.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (html, response) = try await ProviderHTTP.data(for: page)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw APIError.unauthorized }
        if status == 200, let text = String(data: html, encoding: .utf8) {
            if Self.looksLikeLoginPage(text) { throw APIError.unauthorized }
            if let token = Self.extractSecToken(fromHTML: text) { return token }
        }
        if let token = Self.cookieValue(named: "sec_token", in: cookie) {
            return token
        }

        var info = URLRequest(url: URL(string: "https://home.qwencloud.com/tool/user/info.json")!)
        info.timeoutInterval = 20
        info.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        info.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, infoResponse) = try await ProviderHTTP.data(for: info)
        if let http = infoResponse as? HTTPURLResponse, http.statusCode == 200,
           let json = try? JSONSerialization.jsonObject(with: data),
           let token = Self.findString(forKeys: ["secToken", "sec_token"], in: Self.expandEmbeddedJSON(json)) {
            return token
        }
        throw APIError.unauthorized
    }

    private func call(api: String, data: [String: String], cookie: String, secToken: String) async throws -> Data {
        var components = URLComponents(string: gatewayURL)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "IntlBroadScopeAspnGateway"),
            URLQueryItem(name: "product", value: "sfm_bailian"),
            URLQueryItem(name: "api", value: api)
        ]
        guard let url = components.url else { throw APIError.invalidURL }

        var cornerstone: [String: Any] = [
            "feTraceId": UUID().uuidString.lowercased(),
            "feURL": Self.dashboardURL.absoluteString,
            "protocol": "V2",
            "console": "ONE_CONSOLE",
            "productCode": "p_efm",
            "domain": "home.qwencloud.com",
            "consoleSite": "QWENCLOUD",
            "userNickName": "",
            "userPrincipalName": "",
            "xsp_lang": "en-US"
        ]
        if let anonymousID = Self.cookieValue(named: "cna", in: cookie) {
            cornerstone["X-Anonymous-Id"] = anonymousID
        }
        var body = data as [String: Any]
        body["cornerstoneParam"] = cornerstone
        let params = try JSONSerialization.data(withJSONObject: ["Api": api, "V": "1.0", "Data": body])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://home.qwencloud.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        if let csrf = Self.cookieValue(named: "login_aliyunid_csrf", in: cookie) ?? Self.cookieValue(named: "csrf", in: cookie) {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.httpBody = Self.formBody([
            ("product", "sfm_bailian"),
            ("action", "IntlBroadScopeAspnGateway"),
            ("sec_token", secToken),
            ("region", "ap-southeast-1"),
            ("language", "en-US"),
            ("params", String(decoding: params, as: UTF8.self))
        ])

        let (responseData, response) = try await ProviderHTTP.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.unknown(0) }
        switch http.statusCode {
        case 200: return responseData
        case 401, 403: throw APIError.unauthorized
        case 429: throw APIError.rateLimited(retryAfter: HTTPRetryAfter.date(from: http))
        default: throw APIError.unknown(http.statusCode)
        }
    }

    // MARK: - Parse

    /// Reads `per5Hour…`, `per1Week…` and `per1Month…`. Percentages arrive as
    /// ratios (0.03 is 3%) and reset times as epoch milliseconds.
    nonisolated static func parseUsage(_ data: Data) -> QwenUsageData? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let usage = findObject(
                containingAnyOf: ["per5HourPercentage", "per1WeekPercentage", "per1MonthPercentage"],
                in: expandEmbeddedJSON(json)
              ) else { return nil }

        func percent(_ key: String) -> Int? {
            number(usage[key]).map { Int(max(0, min(100, ($0 * 100).rounded()))) }
        }
        func date(_ key: String) -> Date? {
            number(usage[key]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 > 1e11 ? $0 / 1000 : $0) : nil }
        }

        var result = QwenUsageData()
        result.fiveHourUsedPercent = percent("per5HourPercentage")
        result.fiveHourResetAt = date("per5HourResetTime")
        result.weeklyUsedPercent = percent("per1WeekPercentage")
        result.weeklyResetAt = date("per1WeekResetTime")
        result.monthlyUsedPercent = percent("per1MonthPercentage")
        result.monthlyResetAt = date("per1MonthResetTime")
        guard result.fiveHourUsedPercent != nil || result.weeklyUsedPercent != nil
                || result.monthlyUsedPercent != nil else { return nil }
        return result
    }

    nonisolated static func parsePlanName(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let plan = findObject(containingAnyOf: ["specCode"], in: expandEmbeddedJSON(json)),
              let code = (plan["specCode"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return nil }
        return code.prefix(1).uppercased() + code.dropFirst().lowercased()
    }

    /// The gateway answers 200 with an error code when the session has ended.
    nonisolated static func isSignedOut(_ data: Data) -> Bool {
        let text = String(decoding: data.prefix(4096), as: UTF8.self).lowercased()
        return text.contains("notlogin") || text.contains("not_login") || text.contains("needlogin")
    }

    nonisolated static func looksLikeLoginPage(_ html: String) -> Bool {
        let lowered = html.lowercased()
        return lowered.contains("passport.alibabacloud.com") || lowered.contains("signin.aliyun.com")
            || lowered.contains("account.alibabacloud.com/login") || lowered.contains("login.qwencloud.com")
    }

    nonisolated static func extractSecToken(fromHTML html: String) -> String? {
        let patterns = [
            #""secToken"\s*:\s*"([^"]+)""#,
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#
        ]
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: html, range: range),
                  let value = Range(match.range(at: 1), in: html) else { continue }
            let token = html[value].trimmingCharacters(in: .whitespacesAndNewlines)
            if !token.isEmpty { return token }
        }
        return nil
    }

    // MARK: - Helpers

    /// Gateway responses nest JSON documents inside strings; decode them in place.
    nonisolated private static func expandEmbeddedJSON(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 8 else { return value }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { expandEmbeddedJSON($0, depth: depth + 1) }
        }
        if let array = value as? [Any] {
            return array.map { expandEmbeddedJSON($0, depth: depth + 1) }
        }
        if let string = value as? String, let first = string.first, first == "{" || first == "[",
           let data = string.data(using: .utf8), let nested = try? JSONSerialization.jsonObject(with: data) {
            return expandEmbeddedJSON(nested, depth: depth + 1)
        }
        return value
    }

    nonisolated private static func findObject(containingAnyOf keys: [String], in value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] {
            if keys.contains(where: { dictionary[$0] != nil }) { return dictionary }
            for child in dictionary.values {
                if let found = findObject(containingAnyOf: keys, in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = findObject(containingAnyOf: keys, in: child) { return found }
            }
        }
        return nil
    }

    nonisolated private static func findString(forKeys keys: [String], in value: Any) -> String? {
        guard let object = findObject(containingAnyOf: keys, in: value) else { return nil }
        return keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
    }

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    nonisolated static func cookieValue(named name: String, in header: String) -> String? {
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    nonisolated private static func formBody(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = fields.map { name, value in
            let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(name)=\(escaped)"
        }
        return Data(encoded.joined(separator: "&").utf8)
    }
}
