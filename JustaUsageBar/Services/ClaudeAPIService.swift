//
//  ClaudeAPIService.swift
//  JustaUsageBar
//

#if canImport(Darwin)
import Darwin
#endif
import Foundation

enum APIError: Error, LocalizedError {
    case noCredentials
    case invalidURL
    case unauthorized
    case rateLimited
    case networkError(Error)
    case decodingError(Error)
    case unknown(Int)

    var errorDescription: String? {
        switch self {
        case .noCredentials:
            return "No credentials configured"
        case .invalidURL:
            return "Invalid API URL"
        case .unauthorized:
            return "Session expired - please sign in again"
        case .rateLimited:
            return "Claude usage is temporarily rate limited - please try again later"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .decodingError(let error):
            return "Failed to parse response: \(error.localizedDescription)"
        case .unknown(let code):
            return "Unknown error (status: \(code))"
        }
    }
}

enum ClaudeAuthSource: String {
    case none
    case oauth
    case cli
    case webSession
}

final class ClaudeAPIService {
    static let shared = ClaudeAPIService()

    private let baseURL = "https://claude.ai/api/organizations"
    private let session: URLSession

    /// Tracks which auth method was used for the last successful fetch
    private(set) var lastAuthSource: ClaudeAuthSource = .none

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - Fetch Usage (match CodexBar app order: OAuth -> CLI -> Web)

    func fetchUsage() async throws -> UsageData {
        var lastError: APIError?

        if ClaudeOAuthService.shared.hasCredentials {
            do {
                let data = try await ClaudeOAuthService.shared.fetchUsage()
                lastAuthSource = .oauth
                return data
            } catch let error as APIError {
                lastError = error
                print("OAuth fetch failed, trying CLI/web fallback: \(error)")
            }
        }

        if ClaudeCLIService.shared.isAvailable {
            do {
                let data = try await ClaudeCLIService.shared.fetchUsage()
                lastAuthSource = .cli
                return data
            } catch let error as APIError {
                if lastError == nil {
                    lastError = error
                }
                print("Claude CLI fetch failed, trying web fallback: \(error)")
            }
        }

        if CredentialStorage.shared.hasCredentials {
            do {
                let data = try await fetchUsageViaWebSession()
                lastAuthSource = .webSession
                return data
            } catch let error as APIError {
                if lastError == nil {
                    lastError = error
                }
                throw error
            }
        }

        if let lastError {
            throw lastError
        }

        throw APIError.noCredentials
    }

    var hasAnyCredentials: Bool {
        ClaudeOAuthService.shared.hasCredentials || ClaudeCLIService.shared.isAvailable || CredentialStorage.shared.hasCredentials
    }

    // MARK: - Web Session Fetch (original method)

    private func fetchUsageViaWebSession() async throws -> UsageData {
        guard let sessionKey = CredentialStorage.shared.sessionKey,
              let orgId = CredentialStorage.shared.organizationId else {
            throw APIError.noCredentials
        }

        let urlString = "\(baseURL)/\(orgId)/usage"
        guard let url = URL(string: urlString) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        request.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36", forHTTPHeaderField: "user-agent")
        request.setValue("https://claude.ai", forHTTPHeaderField: "origin")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "referer")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw APIError.unknown(0)
            }

            if let jsonString = String(data: data, encoding: .utf8) {
                print("Web API Response (\(httpResponse.statusCode)): \(jsonString.prefix(500))")
            }

            switch httpResponse.statusCode {
            case 200:
                return try parseUsageResponse(data)
            case 401, 403:
                throw APIError.unauthorized
            default:
                throw APIError.unknown(httpResponse.statusCode)
            }
        } catch let error as APIError {
            throw error
        } catch {
            throw APIError.networkError(error)
        }
    }

    // MARK: - Parse Response

    private func parseUsageResponse(_ data: Data) throws -> UsageData {
        var usageData = UsageData()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if let text = String(data: data, encoding: .utf8) {
                return try parseTextResponse(text)
            }
            throw APIError.decodingError(NSError(domain: "JSON", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"]))
        }

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

    private func parseTextResponse(_ text: String) throws -> UsageData {
        var usageData = UsageData()
        let percentPattern = #"(\d+)%\s*used"#
        if let regex = try? NSRegularExpression(pattern: percentPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            if let percentage = Int(text[range]) {
                usageData.fiveHourUsed = percentage
                usageData.fiveHourLimit = 100
            }
        }
        return usageData
    }

    private func parseDate(_ string: String) -> Date? {
        let iso8601 = ISO8601DateFormatter()
        iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso8601.date(from: string) { return date }
        iso8601.formatOptions = [.withInternetDateTime]
        if let date = iso8601.date(from: string) { return date }

        let dateFormatter = DateFormatter()
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "EEE MMM d HH:mm:ss yyyy"] {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: string) { return date }
        }
        return nil
    }
}

final class ClaudeCLIService {
    static let shared = ClaudeCLIService()

    private let shellPath: String

    private init() {
        let shell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.shellPath = (shell?.isEmpty == false) ? shell! : "/bin/zsh"
    }

    var isAvailable: Bool {
        resolvedBinaryPath() != nil
    }

    var oauthUserAgent: String {
        "claude-code/\(userAgentVersion())"
    }

    func fetchUsage() async throws -> UsageData {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.fetchUsageSync())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func fetchUsageSync() throws -> UsageData {
        guard let binaryPath = resolvedBinaryPath() else {
            throw APIError.noCredentials
        }

        let escapedBinary = shellEscape(binaryPath)
        let command = """
        (sleep 2; printf "/usage\\r"; sleep 1; printf "\\r"; sleep 1; printf "\\r"; sleep 8) | script -q /dev/null \(escapedBinary) --allowed-tools "" 2>/dev/null
        """

        guard let rawOutput = runShellCapture(command: command, timeout: 20) else {
            throw APIError.networkError(NSError(
                domain: "ClaudeCLI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Claude CLI PTY capture failed"]
            ))
        }
        let cleanOutput = stripANSICodes(rawOutput)

        if let usageError = extractUsageError(from: cleanOutput) {
            throw usageError
        }

        guard let sessionSection = section(for: "Current session", in: cleanOutput),
              let fiveHourUsed = extractUsedPercent(from: sessionSection) else {
            throw APIError.decodingError(NSError(
                domain: "ClaudeCLI",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "Missing Current session in Claude CLI output"]
            ))
        }

        var usageData = UsageData()
        usageData.fiveHourUsed = fiveHourUsed
        usageData.fiveHourLimit = 100
        usageData.fiveHourResetDescription = extractResetDescription(from: sessionSection)

        if let weeklySection = section(forAnyOf: ["Current week (all models)", "Current week"], in: cleanOutput),
           let weeklyUsed = extractUsedPercent(from: weeklySection) {
            usageData.weeklyUsed = weeklyUsed
            usageData.weeklyLimit = 100
            usageData.weeklyResetDescription = extractResetDescription(from: weeklySection)
        }

        return usageData
    }

    private func userAgentVersion() -> String {
        guard let binaryPath = resolvedBinaryPath() else {
            return "2.1.0"
        }
        return claudeVersion(binaryPath: binaryPath) ?? "2.1.0"
    }

    private func resolvedBinaryPath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default

        if let override = env["CLAUDE_CLI_PATH"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }

        if let existingPATH = env["PATH"] {
            for entry in existingPATH.split(separator: ":").map(String.init) where !entry.isEmpty {
                let candidate = "\(entry.hasSuffix("/") ? String(entry.dropLast()) : entry)/claude"
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        if let shellResolved = runShellCapture(command: "command -v claude", timeout: 2.0, interactive: true)?
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           shellResolved.hasPrefix("/"),
           fileManager.isExecutableFile(atPath: shellResolved) {
            return shellResolved
        }

        let fallbackPaths = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude",
            "/bin/claude",
        ]

        return fallbackPaths.first(where: { fileManager.isExecutableFile(atPath: $0) })
    }

    private func claudeVersion(binaryPath: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["--allowed-tools", "", "--version"]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (text?.isEmpty == false) ? text : nil
    }

    private func runShellCapture(command: String, timeout: TimeInterval, interactive: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = interactive ? ["-l", "-i", "-c", command] : ["-lc", command]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func stripANSICodes(_ text: String) -> String {
        let patterns = [
            #"\u{001B}\][^\u{0007}]*\u{0007}"#,
            #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#,
        ]

        return patterns.reduce(text) { partial, pattern in
            partial.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
    }

    private func extractUsageError(from text: String) -> APIError? {
        let lower = text.lowercased()
        let compact = lower.filter { !$0.isWhitespace }

        if lower.contains("token_expired") || lower.contains("token has expired") || lower.contains("authentication_error") {
            return .unauthorized
        }

        if lower.contains("rate_limit_error") || lower.contains("rate limited") || compact.contains("ratelimited") {
            return .rateLimited
        }

        if lower.contains("failed to load usage data") || compact.contains("failedtoloadusagedata") {
            return .unknown(503)
        }

        return nil
    }

    private func section(for label: String, in text: String) -> String? {
        section(forAnyOf: [label], in: text)
    }

    private func section(forAnyOf labels: [String], in text: String) -> String? {
        let normalizedText = text.replacingOccurrences(of: "\r", with: "\n")
        let lines = normalizedText.components(separatedBy: .newlines)

        for (index, line) in lines.enumerated() {
            let normalizedLine = line.lowercased().filter { !$0.isWhitespace }
            if labels.contains(where: { normalizedLine.contains($0.lowercased().filter { !$0.isWhitespace }) }) {
                let remaining = lines[index..<min(index + 4, lines.count)].joined(separator: "\n")
                return remaining
            }
        }

        return nil
    }

    private func extractUsedPercent(from section: String) -> Int? {
        let patterns: [(String, Bool)] = [
            (#"(\d+)%\s*used"#, true),
            (#"(\d+)%\s*(?:remaining|left|available)"#, false),
            (#"(\d+)%"#, true),
        ]

        for (pattern, isUsed) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
                  let range = Range(match.range(at: 1), in: section),
                  let value = Int(section[range]) else {
                continue
            }
            return isUsed ? value : max(0, 100 - value)
        }

        return nil
    }

    private func extractResetDescription(from section: String) -> String? {
        let patterns = [
            #"Resets?[^\r\n]*\([^\r\n]+\)"#,
            #"Resets?[^\r\n]*"#,
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: section, range: NSRange(section.startIndex..., in: section)),
                  let range = Range(match.range(at: 0), in: section) else {
                continue
            }

            let value = section[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }

        return nil
    }

    private func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
