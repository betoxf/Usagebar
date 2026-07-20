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

    // MARK: - Cursor Published Properties

    @Published var cursorUsageData: CursorUsageData = .placeholder
    @Published var cursorError: String?

    // MARK: - Zai Published Properties

    @Published var zaiUsageData: ZaiUsageData = .placeholder
    @Published var zaiError: String?

    // MARK: - XAI / Grok Build Published Properties

    @Published var xaiUsageData: XaiUsageData = .placeholder
    @Published var xaiError: String?

    // MARK: - Kimi Published Properties

    @Published var kimiUsageData: KimiUsageData = .placeholder
    @Published var kimiAuthSource: KimiAuthSource = .none
    @Published var kimiError: String?

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
    @AppStorage("showCursor") var showCursor: Bool = true
    @AppStorage("showZai") var showZai: Bool = true
    @AppStorage("showXai") var showXai: Bool = true
    @AppStorage("showKimi") var showKimi: Bool = true
    @AppStorage("animationInterval") var animationInterval: Double = 8.0
    @AppStorage("followActiveApp") var followActiveApp: Bool = true
    @AppStorage("autoUpdate") var autoUpdate: Bool = true

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

        kimiAuthSource = KimiAPIService.shared.detectedAuthSource
    }

    // MARK: - Public Methods

    func refresh() async {
        guard !isLoading else { return }
        guard hasCredentials else { return }

        isLoading = true
        error = nil

        // Refresh all providers in parallel
        async let claudeResult: Void = refreshClaude()
        async let codexResult: Void = refreshCodex()
        async let cursorResult: Void = refreshCursor()
        async let zaiResult: Void = refreshZai()
        async let xaiResult: Void = refreshXai()
        async let kimiResult: Void = refreshKimi()
        _ = await (claudeResult, codexResult, cursorResult, zaiResult, xaiResult, kimiResult)

        lastUpdated = Date()
        isLoading = false
        NotificationCenter.default.post(name: NSNotification.Name("UsageDataChanged"), object: nil)
    }

    func rediscoverCredentialsAndRefresh() async {
        ClaudeOAuthService.shared.clearCache()
        CodexAPIService.shared.clearCache()
        CursorAPIService.shared.clearCache()
        ZaiAPIService.shared.clearCache()
        XaiAPIService.shared.clearCache()
        KimiAPIService.shared.clearCache()
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
            usageData = data
            claudeAuthSource = ClaudeAPIService.shared.lastAuthSource
            claudeError = nil
        } catch APIError.unauthorized {
            claudeError = "Signed out — run `claude` in Terminal to log in"
            print("Claude Error: unauthorized")
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

    private func refreshCursor() async {
        guard hasCursorCredentials else {
            cursorError = nil
            return
        }

        do {
            cursorUsageData = try await CursorAPIService.shared.fetchUsage()
            cursorError = nil
        } catch let apiError as APIError {
            cursorError = apiError.errorDescription
            print("Cursor Error: \(apiError.errorDescription ?? "Unknown")")
        } catch {
            cursorError = error.localizedDescription
            print("Cursor Error: \(error)")
        }
    }

    private func refreshZai() async {
        guard hasZaiCredentials else {
            zaiError = nil
            return
        }

        do {
            zaiUsageData = try await ZaiAPIService.shared.fetchUsage()
            zaiError = nil
        } catch let apiError as APIError {
            zaiError = apiError.errorDescription
            print("Zai Error: \(apiError.errorDescription ?? "Unknown")")
        } catch {
            zaiError = error.localizedDescription
            print("Zai Error: \(error)")
        }
    }

    private func refreshXai() async {
        guard hasXaiCredentials else {
            xaiError = nil
            return
        }

        do {
            xaiUsageData = try await XaiAPIService.shared.fetchUsage()
            xaiError = nil
        } catch let apiError as APIError {
            xaiError = apiError.errorDescription
            print("XAI Error: \(apiError.errorDescription ?? "Unknown")")
        } catch {
            xaiError = error.localizedDescription
            print("XAI Error: \(error)")
        }
    }

    private func refreshKimi() async {
        guard hasKimiCredentials else {
            kimiError = nil
            kimiAuthSource = .none
            return
        }

        do {
            kimiUsageData = try await KimiAPIService.shared.fetchUsage()
            kimiAuthSource = KimiAPIService.shared.lastAuthSource
            kimiError = nil
        } catch let error as KimiServiceError {
            kimiAuthSource = KimiAPIService.shared.detectedAuthSource
            kimiError = error.errorDescription
            print("Kimi Error: \(error.errorDescription ?? "Unknown")")
        } catch let error as APIError {
            kimiAuthSource = KimiAPIService.shared.detectedAuthSource
            kimiError = error.errorDescription
            print("Kimi Error: \(error.errorDescription ?? "Unknown")")
        } catch {
            kimiAuthSource = KimiAPIService.shared.detectedAuthSource
            kimiError = error.localizedDescription
            print("Kimi Error: \(error)")
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
        // Generous tolerance lets the system coalesce wakeups and save energy.
        timer?.tolerance = refreshInterval * 0.1
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
        hasClaudeCredentials || hasCodexCredentials || hasCursorCredentials || hasZaiCredentials || hasXaiCredentials || hasKimiCredentials
    }

    var hasClaudeCredentials: Bool {
        ClaudeOAuthService.shared.hasCredentials || CredentialStorage.shared.hasCredentials
    }

    var hasCodexCredentials: Bool {
        CodexAPIService.shared.hasCredentials
    }

    var hasCursorCredentials: Bool {
        CursorAPIService.shared.hasCredentials
    }

    var hasZaiCredentials: Bool {
        ZaiAPIService.shared.hasCredentials
    }

    var hasXaiCredentials: Bool {
        XaiAPIService.shared.hasCredentials
    }

    var hasKimiCredentials: Bool {
        KimiAPIService.shared.hasCredentials
    }

    var hasSavedKimiCredential: Bool {
        KimiAPIService.shared.hasSavedCredential
    }

    /// Number of authenticated providers the user has toggled on.
    private var activeShownProviderCount: Int {
        var count = 0
        if showClaude && hasClaudeCredentials { count += 1 }
        if showCodex && hasCodexCredentials { count += 1 }
        if showCursor && hasCursorCredentials { count += 1 }
        if showZai && hasZaiCredentials { count += 1 }
        if showXai && hasXaiCredentials { count += 1 }
        if showKimi && hasKimiCredentials { count += 1 }
        return count
    }

    /// Whether two or more providers are active and should rotate.
    var shouldAnimateProviders: Bool {
        activeShownProviderCount >= 2 && animationInterval > 0
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
        CredentialStorage.shared.clearClaudeCredentials()
        ClaudeOAuthService.shared.clearPersistedCredentials()
        claudeAuthSource = .none
        usageData = .placeholder
        claudeError = nil
        if !hasCredentials {
            stopAutoRefresh()
        }
    }

    func clearCodexCredentials() {
        CodexAPIService.shared.clearCache()
        codexUsageData = .placeholder
        codexError = nil
        if !hasCredentials {
            stopAutoRefresh()
        }
    }

    func saveKimiCredential(_ credential: String) {
        CredentialStorage.shared.kimiCredential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        KimiAPIService.shared.clearCache()
        detectCredentials()
        startAutoRefresh()
        Task { await refresh() }
    }

    func clearKimiCredential() {
        CredentialStorage.shared.clearKimiCredential()
        KimiAPIService.shared.clearCache()
        kimiUsageData = .placeholder
        kimiError = nil
        detectCredentials()
        if !hasCredentials {
            stopAutoRefresh()
        }
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

}
