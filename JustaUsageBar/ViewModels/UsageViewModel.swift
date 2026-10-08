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

    // MARK: - Refresh scheduling

    @Published private(set) var availableProviders: Set<DisplayProvider> = []
    @Published private(set) var hasSavedKimiCredential = false
    @Published private(set) var refreshStates: [DisplayProvider: ProviderRefreshState] = [:]
    @Published private(set) var isBackgroundSuspended = false

    private var refreshTask: Task<Void, Never>?
    private var credentialChangeTask: Task<Void, Never>?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh = false
    private var pendingManualRefresh = false
    private var pendingRediscovery = false
    private var autoRefreshEnabled = true
    private var displayAsleep = false
    private var systemAsleep = false
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var knownTargets: Set<DisplayProvider> = []
    private var displayedProvider: DisplayProvider = .claude
    private var isMenuOpen = false
    private var isRotating = false
    private var lastCredentialCheck: Date?

    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false

    init(startAutomatically: Bool = true) {
        if let raw = UserDefaults.standard.string(forKey: "preferredDisplayProvider"),
           let provider = DisplayProvider(rawValue: raw) {
            displayedProvider = provider
        }
        guard startAutomatically else { return }
        observePowerState()
        Task { await requestRefresh() }
        if !hasLaunchedBefore {
            hasLaunchedBefore = true
            launchAtStartup = true
        }
    }

    var effectiveRefreshInterval: TimeInterval {
        UsageRefreshPolicy.interval(base: refreshInterval, lowPower: lowPowerMode)
    }

    /// The menu bar shows one provider unless it rotates; the open menu shows all.
    func refreshInterval(for provider: DisplayProvider) -> TimeInterval {
        UsageRefreshPolicy.interval(
            base: effectiveRefreshInterval,
            visible: isMenuOpen || isRotating || provider == displayedProvider
        )
    }

    private var enabledProviders: Set<DisplayProvider> {
        Set(DisplayProvider.displayOrder.filter {
            switch $0 {
            case .claude: return showClaude
            case .codex: return showCodex
            case .cursor: return showCursor
            case .kimi: return showKimi
            case .zai: return showZai
            case .xai: return showXai
            }
        })
    }

    var refreshTargets: Set<DisplayProvider> {
        UsageRefreshPolicy.targets(available: availableProviders, enabled: enabledProviders, fallback: displayedProvider)
    }

    // UI availability checks are memory-only. Services own discovery and its caches.
    var hasCredentials: Bool { !availableProviders.isEmpty }
    var hasClaudeCredentials: Bool { availableProviders.contains(.claude) }
    var hasCodexCredentials: Bool { availableProviders.contains(.codex) }
    var hasCursorCredentials: Bool { availableProviders.contains(.cursor) }
    var hasZaiCredentials: Bool { availableProviders.contains(.zai) }
    var hasXaiCredentials: Bool { availableProviders.contains(.xai) }
    var hasKimiCredentials: Bool { availableProviders.contains(.kimi) }

    var shouldAnimateProviders: Bool {
        !isBackgroundSuspended && !lowPowerMode &&
            availableProviders.intersection(enabledProviders).count >= 2 && animationInterval > 0
    }

    func displayedProviderChanged(_ provider: DisplayProvider) {
        guard provider != displayedProvider else { return }
        displayedProvider = provider
        providerSettingsChanged()
    }

    func menuVisibilityChanged(isOpen: Bool) {
        guard isOpen != isMenuOpen else { return }
        isMenuOpen = isOpen
        providerSettingsChanged()
    }

    func rotationChanged(isRotating: Bool) {
        guard isRotating != self.isRotating else { return }
        self.isRotating = isRotating
        providerSettingsChanged()
    }

    func providerSettingsChanged() {
        let targets = refreshTargets
        let added = targets.subtracting(knownTargets)
        knownTargets = targets
        for provider in added {
            // Re-enabling a provider bypasses local delay, but respects server cooldowns.
            refreshStates[provider, default: .init()].lastAttempt = nil
            refreshStates[provider, default: .init()].retryAt = refreshStates[provider]?.serverRetryAt
        }
        // A reading that just became visible may be older than its new cadence allows.
        let now = Date()
        let stale = targets.contains {
            refreshStates[$0, default: .init()].isDue(at: now, interval: refreshInterval(for: $0), manual: false)
        }
        if !added.isEmpty || stale {
            Task { await requestRefresh() }
        } else {
            scheduleNextRefresh()
        }
    }

    func refresh() async {
        if let credentialChangeTask { await credentialChangeTask.value }
        await requestRefresh(manual: true)
    }

    func rediscoverCredentialsAndRefresh() async {
        if let credentialChangeTask { await credentialChangeTask.value }
        await requestRefresh(manual: true, rediscover: true)
    }

    /// Own every refresh task, including timer-triggered work, so suspension can cancel it.
    private func requestRefresh(manual: Bool = false, rediscover: Bool = false) async {
        pendingRefresh = true
        pendingManualRefresh = pendingManualRefresh || manual
        pendingRediscovery = pendingRediscovery || rediscover
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard autoRefreshEnabled, !isBackgroundSuspended else { return }
        timer?.invalidate()
        timer = nil
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshTask = nil
                scheduleNextRefresh()
            }
            while pendingRefresh && !Task.isCancelled && !isBackgroundSuspended && autoRefreshEnabled {
                let manual = pendingManualRefresh
                let rediscover = pendingRediscovery
                pendingRefresh = false
                pendingManualRefresh = false
                pendingRediscovery = false
                await performRefresh(manual: manual, rediscover: rediscover)
            }
        }
        refreshTask = task
        await task.value
    }

    private func detectCredentials(forceReload: Bool) async {
        if forceReload {
            await ClaudeOAuthService.shared.clearCache()
            await CodexAPIService.shared.clearCache()
            await CursorAPIService.shared.clearCache()
            await ZaiAPIService.shared.clearCache()
            await XaiAPIService.shared.clearCache()
            await KimiAPIService.shared.clearCache()
        }
        async let claude = ClaudeOAuthService.shared.hasCredentials
        async let web = CredentialStorage.shared.hasCredentials
        async let codex = CodexAPIService.shared.hasCredentials
        async let cursor = CursorAPIService.shared.hasCredentials
        async let zai = ZaiAPIService.shared.hasCredentials
        async let xai = XaiAPIService.shared.hasCredentials
        async let kimi = KimiAPIService.shared.detectedAuthSource
        async let savedKimi = KimiAPIService.shared.hasSavedCredential
        let (hasClaude, hasWeb, hasCodex, hasCursor, hasZai, hasXai, kimiSource, saved) =
            await (claude, web, codex, cursor, zai, xai, kimi, savedKimi)
        guard !Task.isCancelled else { return }
        var available: Set<DisplayProvider> = []
        if hasClaude || hasWeb { available.insert(.claude) }
        if hasCodex { available.insert(.codex) }
        if hasCursor { available.insert(.cursor) }
        if hasZai { available.insert(.zai) }
        if hasXai { available.insert(.xai) }
        if kimiSource != .none { available.insert(.kimi) }
        if available != availableProviders { availableProviders = available }
        if saved != hasSavedKimiCredential { hasSavedKimiCredential = saved }
        claudeAuthSource = hasClaude ? .oauth : (hasWeb ? .webSession : .none)
        kimiAuthSource = kimiSource
        knownTargets = refreshTargets
        lastCredentialCheck = Date()
    }

    private func performRefresh(manual: Bool, rediscover: Bool) async {
        isLoading = true
        defer {
            isLoading = false
            NotificationCenter.default.post(name: NSNotification.Name("UsageDataChanged"), object: nil)
        }
        // Sign-ins are rare, so look for them at the hidden cadence unless asked.
        let checkInterval = UsageRefreshPolicy.interval(base: effectiveRefreshInterval, visible: false)
        if manual || lastCredentialCheck.map({ Date().timeIntervalSince($0) >= checkInterval }) ?? true {
            await detectCredentials(forceReload: rediscover)
        }
        guard !Task.isCancelled, !isBackgroundSuspended else { return }
        let now = Date()
        let due = refreshTargets.filter {
            refreshStates[$0, default: .init()].isDue(at: now, interval: refreshInterval(for: $0), manual: manual)
        }
        for provider in due { refreshStates[provider, default: .init()].lastAttempt = now }
        await withTaskGroup(of: Void.self) { group in
            for provider in due {
                group.addTask { await self.refreshProvider(provider) }
            }
        }
        lastUpdated = refreshStates.values.compactMap(\.lastSuccess).max()
    }

    private func refreshProvider(_ provider: DisplayProvider) async {
        do {
            try Task.checkCancellation()
            switch provider {
            case .claude:
                let data = try await ClaudeAPIService.shared.fetchUsage()
                let source = await ClaudeAPIService.shared.lastAuthSource
                try Task.checkCancellation()
                usageData = data
                claudeAuthSource = source
            case .codex:
                let data = try await CodexAPIService.shared.fetchUsage()
                try Task.checkCancellation()
                codexUsageData = data
            case .cursor:
                let data = try await CursorAPIService.shared.fetchUsage()
                try Task.checkCancellation()
                cursorUsageData = data
            case .zai:
                let data = try await ZaiAPIService.shared.fetchUsage()
                try Task.checkCancellation()
                zaiUsageData = data
            case .xai:
                let data = try await XaiAPIService.shared.fetchUsage()
                try Task.checkCancellation()
                xaiUsageData = data
            case .kimi:
                let data = try await KimiAPIService.shared.fetchUsage()
                let source = await KimiAPIService.shared.lastAuthSource
                try Task.checkCancellation()
                kimiUsageData = data
                kimiAuthSource = source
            }
            setError(nil, for: provider)
            refreshStates[provider, default: .init()].succeeded(at: Date())
        } catch {
            if Task.isCancelled || isRequestCancelled(error) {
                // A cancelled request is neither a failed login nor a completed poll.
                refreshStates[provider, default: .init()].lastAttempt = nil
                return
            }
            let retryAfter = (error as? APIError)?.retryAfter ?? (error as? KimiServiceError)?.retryAfter
            refreshStates[provider, default: .init()].failed(
                at: Date(), interval: effectiveRefreshInterval, serverRetryAt: retryAfter
            )
            if provider == .claude, case APIError.unauthorized = error {
                setError("Signed out — run `claude` in Terminal to log in", for: provider)
            } else {
                setError((error as? APIError)?.errorDescription ??
                         (error as? KimiServiceError)?.errorDescription ?? error.localizedDescription, for: provider)
            }
        }
    }

    private func setError(_ message: String?, for provider: DisplayProvider) {
        switch provider {
        case .claude: claudeError = message
        case .codex: codexError = message
        case .cursor: cursorError = message
        case .zai: zaiError = message
        case .xai: xaiError = message
        case .kimi: kimiError = message
        }
    }

    private func scheduleNextRefresh() {
        timer?.invalidate()
        timer = nil
        guard autoRefreshEnabled, !isBackgroundSuspended, refreshTask == nil else { return }
        guard let next = refreshTargets.map({ refreshStates[$0, default: .init()].nextRefresh(interval: refreshInterval(for: $0)) }).min()
        else { return }
        let delay = max(1, next.timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.requestRefresh() }
        }
        timer?.tolerance = min(delay * 0.1, effectiveRefreshInterval * 0.1)
    }

    func startAutoRefresh() {
        autoRefreshEnabled = true
        Task { await requestRefresh() }
    }

    func stopAutoRefresh() {
        autoRefreshEnabled = false
        timer?.invalidate()
        timer = nil
        refreshTask?.cancel()
    }

    func updateRefreshInterval(_ interval: TimeInterval) {
        refreshInterval = max(30, min(600, interval))
        scheduleNextRefresh()
    }

    private func observePowerState() {
        let workspace = NSWorkspace.shared.notificationCenter
        for (name, sleeping, isDisplay) in [
            (NSWorkspace.screensDidSleepNotification, true, true),
            (NSWorkspace.screensDidWakeNotification, false, true),
            (NSWorkspace.willSleepNotification, true, false),
            (NSWorkspace.didWakeNotification, false, false)
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if isDisplay { self.setDisplayAsleep(sleeping) } else { self.setSystemAsleep(sleeping) }
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.powerModeChanged(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
            }
        })
    }

    func setDisplayAsleep(_ asleep: Bool) {
        displayAsleep = asleep
        updatePowerState()
    }

    func setSystemAsleep(_ asleep: Bool) {
        systemAsleep = asleep
        updatePowerState()
    }

    func powerModeChanged(lowPower: Bool) {
        lowPowerMode = lowPower
        updatePowerState()
    }

    private func updatePowerState() {
        let suspended = displayAsleep || systemAsleep
        let wasSuspended = isBackgroundSuspended
        isBackgroundSuspended = suspended
        if suspended {
            timer?.invalidate()
            timer = nil
            refreshTask?.cancel()
        } else if wasSuspended {
            Task {
                if let refreshTask { await refreshTask.value }
                await requestRefresh() // Only stale providers are due on wake.
            }
        } else {
            scheduleNextRefresh()
        }
        NotificationCenter.default.post(name: NSNotification.Name("BackgroundActivityChanged"), object: nil)
    }

    func freshnessText(for provider: DisplayProvider, now: Date = Date()) -> String {
        let state = refreshStates[provider, default: .init()]
        let age: String
        if let lastSuccess = state.lastSuccess {
            let minutes = max(0, Int(now.timeIntervalSince(lastSuccess) / 60))
            age = minutes == 0 ? "Updated just now" : "Updated \(minutes)m ago"
        } else {
            age = "No successful update yet"
        }
        if let retryAt = state.retryAt, retryAt > now {
            return "\(age) · retry in \(max(1, Int(ceil(retryAt.timeIntervalSince(now) / 60))))m"
        }
        return age
    }

    // MARK: - Credential changes

    private func changeCredentials(_ change: @escaping @ProviderActor () -> Void, reset: @escaping @MainActor () -> Void = {}) {
        let previous = credentialChangeTask
        credentialChangeTask = Task {
            if let previous { await previous.value }
            stopAutoRefresh()
            if let refreshTask { await refreshTask.value }
            await change()
            reset()
            autoRefreshEnabled = true
            await requestRefresh(manual: true, rediscover: true)
        }
    }

    func saveCredentials(sessionKey: String, organizationId: String) {
        if sessionKey == "__oauth__" || sessionKey.hasPrefix("__detected__") {
            Task { await rediscoverCredentialsAndRefresh() }
            return
        }
        changeCredentials {
            CredentialStorage.shared.setWebSession(
                sessionKey: sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                organizationId: organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    func clearClaudeCredentials() {
        changeCredentials({
            CredentialStorage.shared.clearClaudeCredentials()
            ClaudeOAuthService.shared.clearPersistedCredentials()
        }, reset: {
            self.usageData = .placeholder
            self.claudeError = nil
            self.refreshStates[.claude] = nil
        })
    }

    func clearCodexCredentials() {
        changeCredentials({ CodexAPIService.shared.clearCache() }, reset: {
            self.codexUsageData = .placeholder
            self.codexError = nil
            self.refreshStates[.codex] = nil
        })
    }

    func saveKimiCredential(_ credential: String) {
        changeCredentials {
            CredentialStorage.shared.setKimiCredential(credential.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    func clearKimiCredential() {
        changeCredentials({
            CredentialStorage.shared.clearKimiCredential()
            KimiAPIService.shared.clearCache()
        }, reset: {
            self.kimiUsageData = .placeholder
            self.kimiError = nil
            self.refreshStates[.kimi] = nil
        })
    }

    // MARK: - Display Helpers

    var statusText: String {
        if !hasCredentials { return "Setup" }
        if isLoading && lastUpdated == nil { return "..." }
        return usageData.menuBarText
    }

    var statusColor: NSColor {
        guard hasCredentials else { return .secondaryLabelColor }
        let pct = usageData.fiveHourPercentage
        return pct < 50 ? .systemGreen : (pct < 80 ? .systemYellow : .systemRed)
    }
}
