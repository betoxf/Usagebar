//
//  DeepSeekAPIService.swift
//  JustaUsageBar
//
//  Reads a DeepSeek API key or DeepSeek Harness's account sign-in and fetches
//  the balance left. DeepSeek is prepaid, so it reports an amount rather than a
//  percentage of a limit.
//

import Foundation

// MARK: - DeepSeek Usage Data Model

nonisolated struct DeepSeekBalance: Equatable {
    var currency: String
    var total: Double
    /// The part of `total` DeepSeek gave as credits rather than a top-up.
    var granted: Double

    var totalText: String { amountText(total) }
    var grantedText: String { amountText(granted) }

    private func amountText(_ amount: Double) -> String {
        let symbol = switch currency {
        case "USD": "$"
        case "CNY": "¥"
        default: "\(currency) "
        }
        return symbol + String(format: "%.2f", amount)
    }
}

nonisolated struct DeepSeekUsageData {
    var balances: [DeepSeekBalance] = []
    /// False when the balance can't pay for API calls.
    var isAvailable = true

    /// An account lists every currency it can hold, most of them empty.
    var shownBalances: [DeepSeekBalance] {
        let funded = balances.filter { $0.total > 0 }
        return funded.isEmpty ? Array(balances.prefix(1)) : funded
    }

    /// No reading stays "--", so a failure never reads as an empty balance.
    var balanceText: String {
        shownBalances.first?.totalText ?? "--"
    }

    static let placeholder = DeepSeekUsageData()
}

// MARK: - DeepSeek API Service

@ProviderActor
final class DeepSeekAPIService {
    static let shared = DeepSeekAPIService()

    nonisolated enum Credential: Equatable {
        case apiKey(String)
        /// The token DeepSeek Harness keeps after an account sign-in.
        case account(String)
    }

    nonisolated private static let platformOrigin = "https://platform.deepseek.com"
    private let balanceEndpoint = "https://api.deepseek.com/user/balance"
    private let accountSummaryEndpoint = "\(DeepSeekAPIService.platformOrigin)/api/v0/users/get_user_summary"

    private init() {}

    // MARK: - Credential Discovery

    var hasCredentials: Bool {
        credential() != nil
    }

    var hasSavedKey: Bool {
        CredentialStorage.shared.deepseekAPIKey != nil
    }

    /// Read on every use, so a rotated key or a Harness sign-out applies at once.
    private func credential() -> Credential? {
        if let saved = CredentialStorage.shared.deepseekAPIKey {
            return .apiKey(saved)
        }
        let env = ProcessInfo.processInfo.environment
        if let key = env["DEEPSEEK_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return .apiKey(key)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let harnessHome = env["DSH_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".dsh")
        let harness = harnessHome.appendingPathComponent(".credentials.yaml")
        let config = home.appendingPathComponent(".deepseek/config.toml")
        return Self.credential(
            harness: (try? String(contentsOf: harness, encoding: .utf8)) ?? "",
            config: (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        )
    }

    /// An API key comes first because its endpoint is the documented one.
    nonisolated static func credential(harness: String, config: String) -> Credential? {
        if let key = harnessKey(in: harness) ?? configKey(in: config) {
            return .apiKey(key)
        }
        return accountToken(in: harness).map { .account($0) }
    }

    /// Harness keeps its stored keys outside `records:`, whose entries belong to other plugins.
    nonisolated private static func harnessKey(in harness: String) -> String? {
        var section = ""
        let stored = harness.split(whereSeparator: \.isNewline).filter { line in
            if !line.hasPrefix(" ") { section = String(line) }
            return section != "records:"
        }
        return value(of: "DEEPSEEK_API_KEY", in: stored.joined(separator: "\n"))
    }

    /// `deepseek-tui` also holds other providers' keys, and a key must never
    /// reach the wrong provider, so only a top-level key set up for DeepSeek counts.
    nonisolated private static func configKey(in config: String) -> String? {
        let topLevel = config.split(whereSeparator: \.isNewline)
            .prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }
            .joined(separator: "\n")
        if let provider = value(of: "provider", in: topLevel), provider != "deepseek" {
            return nil
        }
        if let baseURL = value(of: "base_url", in: topLevel) {
            guard let host = URL(string: baseURL)?.host?.lowercased(),
                  host == "deepseek.com" || host.hasSuffix(".deepseek.com") else { return nil }
        }
        return value(of: "api_key", in: topLevel)
    }

    /// Harness also accepts private deployments, whose tokens must not reach DeepSeek.
    nonisolated private static func accountToken(in harness: String) -> String? {
        func indent(_ line: Substring) -> Int { line.prefix { $0 == " " }.count }
        let lines = harness.split(whereSeparator: \.isNewline)
        guard let start = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "deepseek-account-platform/default:"
        }) else { return nil }
        let record = lines[(start + 1)...]
            .prefix { indent($0) > indent(lines[start]) }
            .joined(separator: "\n")
        guard value(of: "issuer", in: record) == platformOrigin else { return nil }
        return value(of: "token", in: record)
    }

    /// The first usable `name: value` (YAML) or `name = "value"` (TOML) line.
    nonisolated private static func value(of name: String, in text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }),
                  line[..<separator].trimmingCharacters(in: .whitespaces) == name else { continue }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                value = String(value.dropFirst().prefix { $0 != quote })
            } else {
                value = (value.components(separatedBy: " #").first ?? "").trimmingCharacters(in: .whitespaces)
            }
            // YAML's empty values and block markers aren't the value itself.
            if !value.isEmpty, value != "null", value != "~", !value.hasPrefix(">"), !value.hasPrefix("|") {
                return value
            }
        }
        return nil
    }

    // MARK: - Fetch Usage

    func fetchUsage() async throws -> DeepSeekUsageData {
        switch credential() {
        case .apiKey(let key):
            let data = try await get(balanceEndpoint, authorization: ("Authorization", "Bearer \(key)"))
            return try Self.parseBalance(data)
        case .account(let token):
            let data = try await get(accountSummaryEndpoint, authorization: ("x-dsh-auth-token", token))
            return try Self.parseAccountSummary(data)
        case nil:
            throw APIError.noCredentials
        }
    }

    private func get(_ endpoint: String, authorization: (name: String, value: String)) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.setValue(authorization.value, forHTTPHeaderField: authorization.name)

        let (data, response) = try await ProviderHTTP.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknown(0)
        }
        switch httpResponse.statusCode {
        case 200:
            return data
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            throw APIError.rateLimited(retryAfter: HTTPRetryAfter.date(from: httpResponse))
        default:
            throw APIError.unknown(httpResponse.statusCode)
        }
    }

    // MARK: - Parse

    nonisolated static func parseBalance(_ data: Data) throws -> DeepSeekUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let infos = json["balance_infos"] as? [[String: Any]] else {
            throw invalidResponse
        }
        var usage = DeepSeekUsageData()
        usage.isAvailable = json["is_available"] as? Bool ?? true
        // A renamed field must read as a failure, never as an empty balance.
        usage.balances = try infos.map { info in
            guard let currency = info["currency"] as? String, let total = amount(info["total_balance"]) else {
                throw invalidResponse
            }
            return DeepSeekBalance(currency: currency, total: total, granted: amount(info["granted_balance"]) ?? 0)
        }
        return usage
    }

    /// The private endpoint behind Harness's account page: recharge and bonus
    /// wallets inside DeepSeek's platform envelope.
    nonisolated static func parseAccountSummary(_ data: Data) throws -> DeepSeekUsageData {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidResponse
        }
        if json["code"] as? Int == 40003 {
            throw APIError.unauthorized
        }
        guard json["code"] as? Int == 0,
              let body = json["data"] as? [String: Any],
              body["biz_code"] as? Int == 0,
              let summary = body["biz_data"] as? [String: Any],
              let normal = summary["normal_wallets"] as? [[String: Any]],
              let bonus = summary["bonus_wallets"] as? [[String: Any]] else {
            throw invalidResponse
        }

        var balances: [DeepSeekBalance] = []
        for (wallets, isBonus) in [(normal, false), (bonus, true)] {
            for wallet in wallets {
                guard let currency = wallet["currency"] as? String, let amount = amount(wallet["balance"]) else {
                    throw invalidResponse
                }
                if !balances.contains(where: { $0.currency == currency }) {
                    balances.append(DeepSeekBalance(currency: currency, total: 0, granted: 0))
                }
                let index = balances.firstIndex { $0.currency == currency }!
                balances[index].total += amount
                if isBonus { balances[index].granted += amount }
            }
        }
        return DeepSeekUsageData(balances: balances, isAvailable: balances.contains { $0.total > 0 })
    }

    nonisolated private static var invalidResponse: APIError {
        .decodingError(NSError(domain: "DeepSeek", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]))
    }

    /// Balances arrive as decimal strings, such as "110.00" or "0E-16".
    nonisolated private static func amount(_ value: Any?) -> Double? {
        let parsed = (value as? Double) ?? (value as? String).flatMap(Double.init)
        return parsed?.isFinite == true ? parsed : nil
    }
}
