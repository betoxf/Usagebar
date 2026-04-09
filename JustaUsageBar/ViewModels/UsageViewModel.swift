//
//  UsageViewModel.swift
//  JustaUsageBar
//

import Foundation
import Combine
import SwiftUI
import ServiceManagement

@MainActor
final class UsageViewModel: ObservableObject {
    static let shared = UsageViewModel()

    // MARK: - Claude Published Properties

    @Published var usageData: UsageData = .placeholder
    @Published var claudeAuthSource: ClaudeAuthSource = .none
    @Published var claudeError: String?

    // MARK: - Codex Published Properties

    @Published var codexUsageData: CodexUsageData = .placeholder
    @Published var codexError: String?

    // MARK: - General

    @Published var isLoading: Bool = false
    @Published var error: String?
    @Published var lastUpdated: Date?
    @Published var refreshInterval: TimeInterval = 120

    // MARK: - Display Settings (persisted)

    @AppStorage("showIcon") var showIcon: Bool = true
    @AppStorage("showOnly5hr") var showOnly5hr: Bool = false
    @AppStorage("showOnlyWeekly") var showOnlyWeekly: Bool = false
    @AppStorage("showClaude") var showClaude: Bool = true
    @AppStorage("showCodex") var showCodex: Bool = true
    @AppStorage("showPromoVisibility") var showPromoVisibility: Bool = true
    @AppStorage("animationInterval") var animationInterval: Double = 8.0

    // Launch at login using SMAppService (macOS 13+)
    var launchAtStartup: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    print("Failed to \(newValue ? "enable" : "disable") launch at login: \(error)")
                }
            }
        }
    }

    // MARK: - Private

    private var refreshTask: Task<Void, Never>?
    private var timer: Timer?
    private var hasObservedClaudeUsageSample = false
    private var lastClaudeUsageChangeAt: Date?
    private var hasObservedCodexUsageSample = false
    private var lastCodexUsageChangeAt: Date?

    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore: Bool = false

    private init() {
        // Auto-detect credentials on launch
        detectCredentials()
        if hasCredentials {
            startAutoRefresh()
        }

        // Enable Launch at Login on first launch
        if !hasLaunchedBefore {
            hasLaunchedBefore = true
            launchAtStartup = true
        }
    }

    // MARK: - Credential Detection

    func detectCredentials() {
        // Claude: check OAuth first, then web session.
        if ClaudeOAuthService.shared.hasCredentials {
            claudeAuthSource = .oauth
        } else if CredentialStorage.shared.hasCredentials {
            claudeAuthSource = .webSession
        } else {
            claudeAuthSource = .none
        }

        // Codex: auto-detect from file
        // (CodexAPIService.shared.hasCredentials is checked directly)
    }

    // MARK: - Public Methods

    func refresh() async {
        guard !isLoading else { return }
        guard hasCredentials else { return }

        isLoading = true
        error = nil

        // Refresh both providers in parallel
        async let claudeResult: Void = refreshClaude()
        async let codexResult: Void = refreshCodex()
        _ = await (claudeResult, codexResult)

        lastUpdated = Date()
        isLoading = false
        NotificationCenter.default.post(name: NSNotification.Name("UsageDataChanged"), object: nil)
    }

    func rediscoverCredentialsAndRefresh() async {
        ClaudeOAuthService.shared.clearCache()
        CodexAPIService.shared.clearCache()
        detectCredentials()

        if hasCredentials {
            startAutoRefresh()
            await refresh()
        } else {
            lastUpdated = Date()
            NotificationCenter.default.post(name: NSNotification.Name("UsageDataChanged"), object: nil)
        }
    }

    private func refreshClaude() async {
        guard hasClaudeCredentials else {
            claudeError = nil
            return
        }

        do {
            let data = try await ClaudeAPIService.shared.fetchUsage()
            recordClaudeUsageActivityIfNeeded(newData: data)
            usageData = data
            claudeAuthSource = ClaudeAPIService.shared.lastAuthSource
            claudeError = nil
        } catch let apiError as APIError {
            claudeError = apiError.errorDescription
            print("Claude Error: \(apiError.errorDescription ?? "Unknown")")
        } catch {
            claudeError = error.localizedDescription
            print("Claude Error: \(error)")
        }
    }

    private func refreshCodex() async {
        guard hasCodexCredentials else {
            codexError = nil
            return
        }

        do {
            let data = try await CodexAPIService.shared.fetchUsage()
            recordCodexUsageActivityIfNeeded(newData: data)
            codexUsageData = data
            codexError = nil
        } catch let apiError as APIError {
            codexError = apiError.errorDescription
            print("Codex Error: \(apiError.errorDescription ?? "Unknown")")
        } catch {
            codexError = error.localizedDescription
            print("Codex Error: \(error)")
        }
    }

    func startAutoRefresh() {
        stopAutoRefresh()

        guard hasCredentials else {
            return
        }

        refreshTask = Task {
            await refresh()
        }

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        timer?.invalidate()
        timer = nil
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = max(30, min(600, interval))
        startAutoRefresh()
    }

    // MARK: - Credentials

    var hasCredentials: Bool {
        hasClaudeCredentials || hasCodexCredentials
    }

    var hasClaudeCredentials: Bool {
        ClaudeOAuthService.shared.hasCredentials || CredentialStorage.shared.hasCredentials
    }

    var hasCodexCredentials: Bool {
        CodexAPIService.shared.hasCredentials
    }

    /// Whether both providers are active and should animate
    var shouldAnimateProviders: Bool {
        showClaude && showCodex && hasClaudeCredentials && hasCodexCredentials && animationInterval > 0
    }

    private var codexPromoTimeZone: TimeZone {
        TimeZone(identifier: "America/Los_Angeles") ?? .current
    }

    var codexPromoEndDate: Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = codexPromoTimeZone
        return calendar.date(from: DateComponents(
            timeZone: codexPromoTimeZone,
            year: 2026,
            month: 5,
            day: 31,
            hour: 23,
            minute: 59,
            second: 59
        ))
    }

    /// Temporary Codex promo runs through May 31, 2026 at 11:59 PM PT.
    var isPromoVisibilityInWindow: Bool {
        guard let cutoff = codexPromoEndDate else {
            return false
        }
        return Date() <= cutoff
    }

    var shouldShowCodexPromo: Bool {
        showPromoVisibility && isPromoVisibilityInWindow && showCodex && hasCodexCredentials
    }

    var shouldAnimateClaudeUsageActivity: Bool {
        guard let lastClaudeUsageChangeAt else {
            return false
        }

        return Date().timeIntervalSince(lastClaudeUsageChangeAt) < usageActivityWindow
    }

    var shouldAnimateCodexUsageActivity: Bool {
        guard let lastCodexUsageChangeAt else {
            return false
        }

        return Date().timeIntervalSince(lastCodexUsageChangeAt) < usageActivityWindow
    }

    private var claudePeakTimeZone: TimeZone {
        TimeZone(identifier: "America/Los_Angeles") ?? .current
    }

    var isClaudePeakHours: Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = claudePeakTimeZone

        let now = Date()
        let weekday = calendar.component(.weekday, from: now)
        let isWeekday = (2...6).contains(weekday)
        guard isWeekday else {
            return false
        }

        let hour = calendar.component(.hour, from: now)
        return hour >= 5 && hour < 11
    }

    var shouldShowClaudePeakIndicator: Bool {
        showClaude && hasClaudeCredentials && isClaudePeakHours
    }

    var codexPromoEndDisplayText: String {
        guard let endDate = codexPromoEndDate else {
            return "May 31"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = codexPromoTimeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: endDate)
    }

    var codexPromoTimeRemainingText: String? {
        guard let endDate = codexPromoEndDate else {
            return nil
        }

        let remaining = Int(endDate.timeIntervalSinceNow)
        guard remaining > 0 else {
            return nil
        }

        let days = remaining / 86_400
        let hours = (remaining % 86_400) / 3_600
        let minutes = (remaining % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h left"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }
        return "\(max(minutes, 1))m left"
    }

    func saveCredentials(sessionKey: String, organizationId: String) {
        // "__oauth__" / "__detected__*" are sentinels from auto-detect.
        if sessionKey == "__oauth__" || sessionKey.hasPrefix("__detected__") {
            detectCredentials()
            startAutoRefresh()
            Task { await refresh() }
            return
        }

        CredentialStorage.shared.sessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        CredentialStorage.shared.organizationId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        claudeAuthSource = .webSession
        startAutoRefresh()

        Task {
            await refresh()
        }
    }

    func clearClaudeCredentials() {
        CredentialStorage.shared.clearAll()
        ClaudeOAuthService.shared.clearCache()
        claudeAuthSource = .none
        usageData = .placeholder
        claudeError = nil
        hasObservedClaudeUsageSample = false
        lastClaudeUsageChangeAt = nil
        if !hasCredentials {
            stopAutoRefresh()
        }
    }

    func clearCodexCredentials() {
        CodexAPIService.shared.clearCache()
        codexUsageData = .placeholder
        codexError = nil
        hasObservedCodexUsageSample = false
        lastCodexUsageChangeAt = nil
        if !hasCredentials {
            stopAutoRefresh()
        }
    }

    func clearCredentials() {
        clearClaudeCredentials()
        clearCodexCredentials()
        error = "Credentials cleared"
    }

    // MARK: - Display Helpers

    var statusText: String {
        if !hasCredentials {
            return "Setup"
        }
        if isLoading && lastUpdated == nil {
            return "..."
        }
        return usageData.menuBarText
    }

    var statusColor: NSColor {
        guard hasCredentials else { return .secondaryLabelColor }

        let pct = usageData.fiveHourPercentage
        if pct < 50 {
            return .systemGreen
        } else if pct < 80 {
            return .systemYellow
        } else {
            return .systemRed
        }
    }

    private var usageActivityWindow: TimeInterval {
        refreshInterval + 5
    }

    private func recordClaudeUsageActivityIfNeeded(newData: UsageData, now: Date = Date()) {
        guard hasObservedClaudeUsageSample else {
            hasObservedClaudeUsageSample = true
            return
        }

        let didChange =
            usageData.fiveHourUsed != newData.fiveHourUsed ||
            usageData.weeklyUsed != newData.weeklyUsed

        if didChange {
            lastClaudeUsageChangeAt = now
        }
    }

    private func recordCodexUsageActivityIfNeeded(newData: CodexUsageData, now: Date = Date()) {
        guard hasObservedCodexUsageSample else {
            hasObservedCodexUsageSample = true
            return
        }

        let didChange =
            codexUsageData.primaryUsedPercent != newData.primaryUsedPercent ||
            codexUsageData.secondaryUsedPercent != newData.secondaryUsedPercent

        if didChange {
            lastCodexUsageChangeAt = now
        }
    }
}
