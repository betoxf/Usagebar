//
//  AppDelegate.swift
//  JustaUsageBar
//

import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    nonisolated private static let hasShownSetupDefaultsKey = "hasShownSetup"
    nonisolated private static let lastLaunchedAppDescriptorDefaultsKey = "lastLaunchedAppDescriptor"
    nonisolated private static let lastUpdateCheckAtDefaultsKey = "lastUpdateCheckAt"
    nonisolated private static let lastInstalledUpdateAtDefaultsKey = "lastInstalledUpdateAt"
    nonisolated private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/betoxf/Usagebar/releases/latest")!
    nonisolated private static let repositoryURL = URL(string: "https://github.com/betoxf/Usagebar")!
    nonisolated private static let updateFailureFileName = "update-failure.txt"

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var isMenuOpen = false {
        didSet { viewModel.menuVisibilityChanged(isOpen: isMenuOpen || isPanelOpen) }
    }
    private let panelModel = UsagePanelModel()
    private lazy var panel: UsagePanel = {
        let panel = UsagePanel(rootView: UsagePanelView(model: panelModel))
        panel.onClose = { [weak self] in self?.isPanelOpen = false }
        return panel
    }()
    /// While the panel is open every provider refreshes at the on-screen rate.
    private var isPanelOpen = false {
        didSet { viewModel.menuVisibilityChanged(isOpen: isMenuOpen || isPanelOpen) }
    }
    private var lastRenderKey: StatusRenderKey?
    private var cachedStatusImages: [DisplayProvider: (StatusRenderKey, NSImage, CGFloat)] = [:]

    private struct StatusRenderKey: Equatable {
        let provider: DisplayProvider
        let primary: Int
        let secondary: Int?
        let windowLabel: String
        let showIcon: Bool
        let only5h: Bool
        let onlyWeekly: Bool
        let dark: Bool
        let scale: CGFloat
        let updateBadge: Bool
    }
    private let viewModel: UsageViewModel

    override convenience init() {
        self.init(viewModel: .shared)
    }

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init()
    }
    private var lastStatusLength: CGFloat = 0
    private var setupWindow: NSWindow?
    private let setupModel = SetupModel()
    private let setupCheckTimer = RepeatingTimer()
    private let preferredProviderDefaultsKey = "preferredDisplayProvider"

    // Provider switching state
    private var currentProvider: DisplayProvider = .claude
    private let providerSwitchTimer = RepeatingTimer()
    private var rotationSignature = ""
    /// Provider forced by the frontmost app (Claude/ChatGPT/Codex/ZCode) or by the
    /// AI CLI in its terminal, nil when neither is active.
    private var focusProvider: DisplayProvider?
    private var terminalWatch: Task<Void, Never>?
    /// What the terminal watch last found in the frontmost app.
    private var terminalProvider: DisplayProvider?

    // Update availability state
    private var availableUpdateVersion: String?
    private var lastReleaseCheckAt: Date?
    private var isUpdateRunning = false
    nonisolated private static let releaseCheckInterval: TimeInterval = 6 * 3600
    nonisolated private static let lastAutoUpdateVersionDefaultsKey = "lastAutoUpdateAttemptedVersion"

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.hasAnotherRunningInstance else {
            NSApp.terminate(nil)
            return
        }

        setupStatusItem()
        setupMenu()
        observeChanges()
        recordInstalledAppVersionIfNeeded()

        NSApp.setActivationPolicy(.accessory)
        presentPendingUpdateFailureIfNeeded()

        followFrontmostApp()
        if viewModel.hasCredentials {
            syncCurrentProvider(preferSavedSelection: true, persistPreference: true)
            restartProviderAnimation()
        } else {
            showSetupStatus()
        }
    }

    private func observeChanges() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(appearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: NSNotification.Name("SettingsChanged"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(usageDataChanged),
            name: NSNotification.Name("UsageDataChanged"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(backgroundActivityChanged),
            name: NSNotification.Name("BackgroundActivityChanged"),
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    // MARK: - Focus-Aware Provider

    @objc private func activeAppChanged(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        follow(app)
    }

    private func followFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication {
            follow(app)
        }
    }

    /// Shows the provider of the AI app in front. Any other app leaves the last
    /// provider on screen, unless an AI CLI runs in one of its terminal sessions.
    private func follow(_ app: NSRunningApplication) {
        if viewModel.followActiveApp {
            setFocus(provider(matching: app))
        }
        terminalProvider = nil
        watchTerminalSessions(of: app)
    }

    /// Restarts the watch without re-applying the app's focus, so a manual pick
    /// survives sleep and refreshes.
    private func resumeTerminalWatch() {
        if let app = NSWorkspace.shared.frontmostApplication {
            watchTerminalSessions(of: app)
        }
    }

    private func setFocus(_ provider: DisplayProvider?) {
        guard provider != focusProvider else { return }
        focusProvider = provider
        restartProviderAnimation()
    }

    /// Polls the app's terminal sessions off the main thread while it stays in front.
    private func watchTerminalSessions(of app: NSRunningApplication) {
        terminalWatch?.cancel()
        terminalWatch = nil
        guard viewModel.followActiveApp, !viewModel.isBackgroundSuspended, displayableProviders().count > 1,
              provider(matching: app) == nil else { return }
        let pid = app.processIdentifier
        let isTerminal = TerminalAgentDetector.terminalBundleIDs.contains(app.bundleIdentifier?.lowercased() ?? "")
        let isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let known = terminalProvider

        terminalWatch = Task.detached(priority: .utility) { [weak self] in
            var reported = known
            var scans = 0
            while !Task.isCancelled {
                let scan = TerminalAgentDetector.scan(app: pid, isTerminal: isTerminal)
                guard scan.hostsTerminals else { return }
                // Once its CLI is gone, a terminal is like any other app.
                if scan.provider != reported {
                    reported = scan.provider
                    await self?.terminalSessionChanged(to: scan.provider)
                }
                // A CLI is most often started right after its terminal comes forward.
                scans += 1
                let interval: Duration = isLowPower ? .seconds(10) : (scans < 5 ? .seconds(3) : .seconds(6))
                try? await Task.sleep(for: interval, tolerance: .seconds(1))
            }
        }
    }

    private func terminalSessionChanged(to provider: DisplayProvider?) {
        // The app may have left the front while this result crossed threads.
        guard !Task.isCancelled else { return }
        terminalProvider = provider
        setFocus(provider)
    }

    private func provider(matching app: NSRunningApplication) -> DisplayProvider? {
        let bundleId = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""

        if bundleId.hasPrefix("com.anthropic.") || name == "claude" {
            return .claude
        }
        if bundleId.hasPrefix("com.openai.") || name == "chatgpt" || name == "codex" {
            return .codex
        }
        // Cursor ships under a ToDesktop bundle id; match it and the app name.
        // Grok Bot is Cursor's agent app and runs on the Cursor subscription.
        if bundleId == "com.todesktop.230313mzl4w4u92" || bundleId == "com.anysphere.sand" || name == "cursor" {
            return .cursor
        }
        if bundleId.contains("kimi") || bundleId.hasPrefix("com.moonshot.") || name == "kimi" {
            return .kimi
        }
        if bundleId == "dev.zcode.app" || name == "zcode" {
            return .zai
        }
        // Grok runs on the Cursor plan, whose marks include it.
        if bundleId.contains("xai") || bundleId.contains("x.ai") || name == "grok" || name.contains("grok") {
            return .cursor
        }
        return nil
    }

    @objc private func appearanceChanged() {
        if viewModel.hasCredentials {
            updateStatusImage()
        }
    }

    @objc private func backgroundActivityChanged() {
        restartProviderAnimation()
        resumeTerminalWatch()
    }

    @objc private func settingsChanged() {
        viewModel.providerSettingsChanged()
        if viewModel.hasCredentials {
            syncCurrentProvider()
            restartProviderAnimation()
        } else {
            showSetupStatus()
        }
        rebuildMenu()
    }

    @objc private func usageDataChanged() {
        if viewModel.hasCredentials {
            syncCurrentProvider()
            if currentRotationSignature != rotationSignature {
                restartProviderAnimation()
                resumeTerminalWatch()
            }
            updateStatusImage()
        } else {
            showSetupStatus()
            showSetupOnFirstLaunch()
        }
        rebuildMenu()
        maybeCheckForUpdateInBackground()
    }

    // MARK: - Background Update Check

    /// Piggybacks on the regular refresh cycle: at most one release lookup
    /// every `releaseCheckInterval`, a single HTTPS request, no timers.
    private func maybeCheckForUpdateInBackground() {
        let last = lastReleaseCheckAt
            ?? UserDefaults.standard.object(forKey: Self.lastUpdateCheckAtDefaultsKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.releaseCheckInterval {
            return
        }
        lastReleaseCheckAt = Date()

        Task { [weak self] in
            guard let release = try? await Self.fetchLatestRelease() else { return }
            self?.handleDiscoveredRelease(release)
        }
    }

    private func handleDiscoveredRelease(_ release: ReleaseInfo) {
        UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckAtDefaultsKey)

        let installedVersion = Self.installedAppInfo().version
        guard release.version.compare(installedVersion, options: .numeric) == .orderedDescending else {
            if availableUpdateVersion != nil {
                availableUpdateVersion = nil
                rebuildMenu()
                updateStatusImage()
            }
            return
        }

        let isNewDiscovery = availableUpdateVersion != release.version
        availableUpdateVersion = release.version
        if isNewDiscovery {
            rebuildMenu()
            updateStatusImage()

            let defaults = UserDefaults.standard
            let lastAttempted = defaults.string(forKey: Self.lastAutoUpdateVersionDefaultsKey)
            if viewModel.autoUpdate && lastAttempted != release.version {
                defaults.set(release.version, forKey: Self.lastAutoUpdateVersionDefaultsKey)
                runUpdate(interactive: false)
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true

        // Add click handler to toggle providers
        if let button = statusItem.button {
            button.action = #selector(statusBarButtonClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func showSetupStatus() {
        stopProviderAnimation()
        lastRenderKey = nil
        guard let button = statusItem.button else { return }

        let width: CGFloat = 56
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let nameAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let nameString = NSAttributedString(string: "Usagebar", attributes: nameAttributes)
        let logoSize = NSSize(width: 17, height: 6)
        let logoGap: CGFloat = 2
        let startX = (width - logoSize.width - logoGap - nameString.size().width) / 2
        NSImage(named: "UsagebarLogo")?.draw(in: NSRect(origin: NSPoint(x: startX, y: 13.5), size: logoSize))
        nameString.draw(at: NSPoint(x: startX + logoSize.width + logoGap, y: 12))

        let setupAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.black
        ]
        let setupString = NSAttributedString(string: "Setup", attributes: setupAttributes)
        setupString.draw(at: NSPoint(x: (width - setupString.size().width) / 2, y: 0))

        image.unlockFocus()
        // A template follows the menu bar's appearance, which nothing redraws this for.
        image.isTemplate = true

        lastStatusLength = width
        statusItem.length = width
        button.image = image
        button.toolTip = "Set up Usagebar"
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self
        // Don't set statusItem.menu - we handle clicks manually
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard !isMenuOpen else { return }
        isMenuOpen = true
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    private func rebuildMenu() {
        updatePanel()
        // Countdown labels are recomputed on open. Closed menus need no work,
        // and replacing the items would close a submenu the pointer is in.
        guard isMenuOpen, menu.highlightedItem?.submenu == nil else { return }
        menu.removeAllItems()

        let hasClaude = viewModel.hasClaudeCredentials
        let hasCodex = viewModel.hasCodexCredentials
        let hasCursor = viewModel.hasCursorCredentials
        let hasZai = viewModel.hasZaiCredentials
        let hasKimi = viewModel.hasKimiCredentials

        if !hasClaude && !hasCodex && !hasCursor && !hasZai && !hasKimi {
            let setupItem = NSMenuItem(title: "Set Up Usagebar…", action: #selector(showSetupWindow), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
        } else {
            // Refresh
            let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)

            let updatesMenu = NSMenu()
            for provider in DisplayProvider.displayOrder where viewModel.refreshTargets.contains(provider) {
                let title: String = switch provider {
                case .claude: "Claude"
                case .codex: "Codex"
                case .cursor: "Cursor"
                case .kimi: "Kimi Code"
                case .zai: "z.ai"
                }
                let item = NSMenuItem(title: "\(title): \(viewModel.freshnessText(for: provider))", action: nil, keyEquivalent: "")
                item.isEnabled = false
                updatesMenu.addItem(item)
            }
            let updatesItem = NSMenuItem(title: "Last Updates", action: nil, keyEquivalent: "")
            updatesItem.submenu = updatesMenu
            menu.addItem(updatesItem)

            // Display submenu
            let displayMenu = NSMenu()

            let bothItem = NSMenuItem(title: "Show Both", action: #selector(showBoth), keyEquivalent: "")
            bothItem.target = self
            bothItem.state = (!viewModel.showOnly5hr && !viewModel.showOnlyWeekly) ? .on : .off
            displayMenu.addItem(bothItem)

            let only5hItem = NSMenuItem(title: "Show 5h Only", action: #selector(showOnly5h), keyEquivalent: "")
            only5hItem.target = self
            only5hItem.state = viewModel.showOnly5hr ? .on : .off
            displayMenu.addItem(only5hItem)

            let onlyWeeklyItem = NSMenuItem(title: "Show Weekly Only", action: #selector(showOnlyWeekly), keyEquivalent: "")
            onlyWeeklyItem.target = self
            onlyWeeklyItem.state = viewModel.showOnlyWeekly ? .on : .off
            displayMenu.addItem(onlyWeeklyItem)

            // Provider toggles
            let authedProviderCount = [hasClaude, hasCodex, hasCursor, hasKimi, hasZai].filter { $0 }.count
            if authedProviderCount > 0 {
                displayMenu.addItem(NSMenuItem.separator())

                if hasClaude {
                    let claudeToggle = NSMenuItem(title: "Show Claude", action: #selector(toggleShowClaude), keyEquivalent: "")
                    claudeToggle.target = self
                    claudeToggle.state = viewModel.showClaude ? .on : .off
                    displayMenu.addItem(claudeToggle)
                }

                if hasCodex {
                    let codexToggle = NSMenuItem(title: "Show Codex", action: #selector(toggleShowCodex), keyEquivalent: "")
                    codexToggle.target = self
                    codexToggle.state = viewModel.showCodex ? .on : .off
                    displayMenu.addItem(codexToggle)
                }

                if hasCursor {
                    let cursorToggle = NSMenuItem(title: "Show Cursor", action: #selector(toggleShowCursor), keyEquivalent: "")
                    cursorToggle.target = self
                    cursorToggle.state = viewModel.showCursor ? .on : .off
                    displayMenu.addItem(cursorToggle)
                }

                if hasKimi {
                    let kimiToggle = NSMenuItem(title: "Show Kimi Code", action: #selector(toggleShowKimi), keyEquivalent: "")
                    kimiToggle.target = self
                    kimiToggle.state = viewModel.showKimi ? .on : .off
                    displayMenu.addItem(kimiToggle)
                }

                if hasZai {
                    let zaiToggle = NSMenuItem(title: "Show z.ai", action: #selector(toggleShowZai), keyEquivalent: "")
                    zaiToggle.target = self
                    zaiToggle.state = viewModel.showZai ? .on : .off
                    displayMenu.addItem(zaiToggle)
                }

                // Follow-active-app + switch-interval apply once 2+ providers show.
                if authedProviderCount >= 2 {
                    displayMenu.addItem(NSMenuItem.separator())

                    let followItem = NSMenuItem(title: "Follow Active App", action: #selector(toggleFollowActiveApp), keyEquivalent: "")
                    followItem.target = self
                    followItem.state = viewModel.followActiveApp ? .on : .off
                    followItem.toolTip = "Show the provider of the AI app or terminal CLI you used last (Claude, ChatGPT/Codex, Cursor or Grok Bot, Kimi Code, or ZCode)"
                    displayMenu.addItem(followItem)

                    let intervalMenu = NSMenu()

                    // Add Manual option (tag = 0 means no auto-switching)
                    let manualItem = NSMenuItem(title: "Manual", action: #selector(setAnimationInterval(_:)), keyEquivalent: "")
                    manualItem.target = self
                    manualItem.tag = 0
                    manualItem.state = (viewModel.animationInterval == 0) ? .on : .off
                    intervalMenu.addItem(manualItem)

                    intervalMenu.addItem(NSMenuItem.separator())

                    for seconds: Double in [5, 8, 10, 15, 30] {
                        let label = seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
                        let item = NSMenuItem(title: label, action: #selector(setAnimationInterval(_:)), keyEquivalent: "")
                        item.target = self
                        item.tag = Int(seconds)
                        item.state = (viewModel.animationInterval == seconds) ? .on : .off
                        intervalMenu.addItem(item)
                    }

                    let intervalItem = NSMenuItem(title: "Switch Every", action: nil, keyEquivalent: "")
                    intervalItem.submenu = intervalMenu
                    displayMenu.addItem(intervalItem)
                }
            }

            let displayItem = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
            displayItem.submenu = displayMenu
            menu.addItem(displayItem)

            // Icon toggle
            let iconItem = NSMenuItem(title: "Show Icon", action: #selector(toggleIcon), keyEquivalent: "")
            iconItem.target = self
            iconItem.state = viewModel.showIcon ? .on : .off
            menu.addItem(iconItem)

            // Launch at login
            let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchItem.target = self
            launchItem.state = viewModel.launchAtStartup ? .on : .off
            menu.addItem(launchItem)

            menu.addItem(NSMenuItem.separator())

            // Sign out options
            if hasClaude {
                let signOutClaude = NSMenuItem(title: "Sign Out Claude", action: #selector(signOutClaude), keyEquivalent: "")
                signOutClaude.target = self
                menu.addItem(signOutClaude)
            }

            if hasCodex {
                let signOutCodex = NSMenuItem(title: "Sign Out Codex", action: #selector(signOutCodex), keyEquivalent: "")
                signOutCodex.target = self
                menu.addItem(signOutCodex)
            }

            if viewModel.hasSavedKimiCredential {
                let forgetKimi = NSMenuItem(title: "Forget Saved Kimi Code Credential", action: #selector(clearKimiCredential), keyEquivalent: "")
                forgetKimi.target = self
                menu.addItem(forgetKimi)
            }

            if viewModel.availableProviders.count < DisplayProvider.allCases.count {
                let connectItem = NSMenuItem(title: "Connect More Tools…", action: #selector(showSetupWindow), keyEquivalent: "")
                connectItem.target = self
                menu.addItem(connectItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let reviewRepoItem = NSMenuItem(title: "Review GitHub Repo", action: #selector(openGitHubRepository), keyEquivalent: "")
        reviewRepoItem.target = self
        if let githubMark = NSImage(named: "GitHubMark") {
            githubMark.size = NSSize(width: 14, height: 14)
            reviewRepoItem.image = githubMark
        }
        menu.addItem(reviewRepoItem)

        // Check for Updates / update available badge
        if let updateVersion = availableUpdateVersion {
            let updateItem = NSMenuItem(title: "Update to v\(updateVersion) (1)", action: #selector(checkForUpdates), keyEquivalent: "u")
            updateItem.target = self
            updateItem.attributedTitle = NSAttributedString(
                string: "Update to v\(updateVersion)  (1)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                    .foregroundColor: brandClaudeColor
                ]
            )
            menu.addItem(updateItem)
        } else {
            let updateItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "u")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        // Auto update toggle
        let autoUpdateItem = NSMenuItem(title: "Update Automatically", action: #selector(toggleAutoUpdate), keyEquivalent: "")
        autoUpdateItem.target = self
        autoUpdateItem.state = viewModel.autoUpdate ? .on : .off
        menu.addItem(autoUpdateItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: - Menu Actions

    // MARK: - Usage Panel

    private func togglePanel() {
        if panel.isVisible {
            panel.close()
            return
        }
        guard let button = statusItem.button else { return }
        configurePanelActions()
        isPanelOpen = true
        updatePanel()
        panel.show(below: button)
    }

    /// Fills the panel from the normalized usage models. Runs whenever the
    /// open menu would be rebuilt.
    private func updatePanel() {
        guard isPanelOpen else { return }
        panelModel.needsSetup = !viewModel.hasCredentials
        panelModel.cards = panelCards()
        panelModel.currentProvider = viewModel.hasCredentials ? currentProvider : nil
        panelModel.updateVersion = availableUpdateVersion
        panelModel.isRefreshing = viewModel.isLoading
        panelModel.updatedText = updatedText(viewModel.lastUpdated)
        loadProviderMarks()
        DispatchQueue.main.async { [weak self] in self?.panel.fitContent() }
    }

    private func loadProviderMarks() {
        guard panelModel.cursorMarks == nil else { return }
        panelModel.cursorMarks = cursorPlanMarksImage(height: 12)
        var transform = AffineTransform.identity
        transform.scale(10.6)
        let zMark = zcodeMarkPath()
        zMark.transform(using: transform)
        panelModel.zcodeMark = templateImage(size: NSSize(width: 1.13 * 10.6, height: 10.6), paths: [zMark])
    }

    private func updatedText(_ date: Date?) -> String {
        guard let date else { return "" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "Updated just now" : "Updated \(minutes)m ago"
    }

    private func panelCards() -> [UsagePanelCard] {
        var cards: [UsagePanelCard] = []

        if viewModel.showClaude {
            let source: String = switch viewModel.claudeAuthSource {
            case .oauth: "via OAuth"
            case .webSession: "via Browser"
            case .none: ""
            }
            let detail = viewModel.usageData.planName ?? source
            if viewModel.hasClaudeCredentials {
                let usage = viewModel.usageData
                var rows: [UsagePanelRow] = []
                if let fiveHour = usage.fiveHourUsed {
                    rows.append(UsagePanelRow(label: "5h", percent: fiveHour, resetText: usage.timeUntilFiveHourReset))
                }
                rows.append(UsagePanelRow(label: "7d", percent: usage.weeklyUsed, resetText: usage.timeUntilWeeklyReset))
                if usage.hasFableData {
                    rows.append(UsagePanelRow(label: "Fable", percent: usage.fableUsed ?? 0, resetText: usage.timeUntilFableReset))
                }
                let error = viewModel.claudeError
                cards.append(UsagePanelCard(
                    provider: .claude, detail: detail, rows: rows, message: error,
                    actionTitle: error != nil && shouldPromptClaudeAuthentication ? "How to authenticate Claude" : nil
                ))
            } else {
                cards.append(UsagePanelCard(
                    provider: .claude, detail: detail, rows: [],
                    message: "Not connected", actionTitle: "Connect Claude"
                ))
            }
        }

        if viewModel.showCodex {
            let codex = viewModel.codexUsageData
            let detail = codex.planName
            if viewModel.hasCodexCredentials {
                var rows = [UsagePanelRow(
                    label: codex.primaryIsWeekly ? "7d" : codex.primaryWindowLabel,
                    percent: codex.primaryUsedPercent,
                    resetText: codex.timeUntilPrimaryReset
                )]
                if !codex.primaryIsWeekly, codex.secondaryUsedPercent > 0 || codex.secondaryResetAt != nil {
                    rows.append(UsagePanelRow(label: "7d", percent: codex.secondaryUsedPercent, resetText: codex.timeUntilSecondaryReset))
                }
                let error = viewModel.codexError
                cards.append(UsagePanelCard(
                    provider: .codex, detail: detail, rows: rows, message: error,
                    actionTitle: error != nil && shouldPromptCodexAuthentication ? "How to authenticate Codex" : nil
                ))
            } else {
                cards.append(UsagePanelCard(
                    provider: .codex, detail: detail, rows: [],
                    message: "Not connected", actionTitle: "Connect Codex"
                ))
            }
        }

        if viewModel.hasCursorCredentials && viewModel.showCursor {
            let cursor = viewModel.cursorUsageData
            cards.append(UsagePanelCard(
                provider: .cursor,
                detail: cursor.planName != "unknown" ? displayPlanName(cursor.planName) : "",
                rows: [UsagePanelRow(label: cursor.windowLabel, percent: cursor.usedPercent, resetText: cursor.timeUntilReset)],
                message: viewModel.cursorError ?? (cursor.weeklyIsStale ? "Couldn't refresh weekly usage" : nil)
            ))
        }

        if viewModel.hasKimiCredentials && viewModel.showKimi {
            let kimi = viewModel.kimiUsageData
            var rows: [UsagePanelRow] = []
            if let fiveHour = kimi.fiveHourUsedPercent {
                rows.append(UsagePanelRow(label: "5h", percent: fiveHour, resetText: kimi.timeUntilFiveHourReset))
            }
            rows.append(UsagePanelRow(label: "7d", percent: kimi.weeklyUsedPercent, resetText: kimi.timeUntilWeeklyReset))
            let error = viewModel.kimiError
            cards.append(UsagePanelCard(
                provider: .kimi, detail: viewModel.kimiAuthSource.displayName, rows: rows,
                message: error, actionTitle: error != nil ? "Kimi Code Setup…" : nil
            ))
        }

        if viewModel.hasZaiCredentials && viewModel.showZai {
            let zai = viewModel.zaiUsageData
            cards.append(UsagePanelCard(
                provider: .zai,
                detail: zai.planName != "unknown" ? displayPlanName(zai.planName) : "",
                rows: [UsagePanelRow(label: zai.windowLabel, percent: zai.usedPercent, resetText: zai.timeUntilReset)],
                message: viewModel.zaiError
            ))
        }

        return cards
    }

    private func configurePanelActions() {
        panelModel.onSelect = { [weak self] provider in
            guard let self, self.canDisplay(provider) else { return }
            // A pick in the panel wins like a click on the status item.
            self.focusProvider = nil
            self.setCurrentProvider(provider)
            self.restartProviderAnimation()
            self.updateStatusImage()
            self.updatePanel()
        }
        panelModel.onAction = { [weak self] provider in
            guard let self else { return }
            self.panel.close()
            guard self.hasCredentials(for: provider) else {
                self.showSetupWindow()
                return
            }
            switch provider {
            case .claude: self.authenticateClaude()
            case .codex: self.authenticateCodex()
            case .kimi: self.authenticateKimi()
            case .cursor, .zai: break
            }
        }
        panelModel.onRefresh = { [weak self] in
            self?.panelModel.isRefreshing = true
            self?.refreshData()
        }
        panelModel.onMore = { [weak self] anchor in
            guard let self else { return }
            self.menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.maxY + 4), in: anchor)
        }
        panelModel.onUpdate = { [weak self] in self?.checkForUpdates() }
        panelModel.onSetup = { [weak self] in
            self?.panel.close()
            self?.showSetupWindow()
        }
        panelModel.onQuit = { NSApp.terminate(nil) }
    }

    @objc private func statusBarButtonClicked() {
        let event = NSApp.currentEvent

        // Right click shows the usage panel
        if event?.type == .rightMouseUp {
            togglePanel()
            return
        }

        // With nothing to show yet, the bar's only job is setup.
        if !viewModel.hasCredentials {
            showSetupWindow()
            return
        }

        // Left click cycles to the next provider when more than one is shown
        if event?.type == .leftMouseUp {
            if displayableProviders().count > 1, let next = providerAfter(currentProvider) {
                // A manual click always wins, even while focus-follow has the
                // bar locked to the frontmost app's provider. Suspend the lock
                // for now; the next app switch (including switching back to
                // Claude/Cursor/etc.) re-applies focus-follow.
                focusProvider = nil
                setCurrentProvider(next)
                restartProviderAnimation()
            } else {
                // If only one provider, show the usage panel
                togglePanel()
            }
        }
    }

    private func showSetupOnFirstLaunch() {
        guard viewModel.hasCheckedCredentials,
              !UserDefaults.standard.bool(forKey: Self.hasShownSetupDefaultsKey) else { return }
        showSetupWindow()
    }

    @objc private func showSetupWindow() {
        UserDefaults.standard.set(true, forKey: Self.hasShownSetupDefaultsKey)
        if setupWindow == nil {
            loadProviderMarks()
            setupModel.cursorMarks = panelModel.cursorMarks
            setupModel.zcodeMark = panelModel.zcodeMark
            setupModel.onConnect = { [weak self] in self?.connect($0) }
            setupModel.onClose = { [weak self] in self?.setupWindow?.close() }
            _ = setupModel.update(available: viewModel.availableProviders)

            let window = NSWindow(
                contentRect: .zero,
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Set Up Usagebar"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: SetupView(viewModel: viewModel, model: setupModel))
            window.setContentSize(window.contentView?.fittingSize ?? .zero)
            window.center()
            setupWindow = window
            setupCheckTimer.start(every: 3) { [weak self] in self?.checkForSetupSignIns() }
        }

        // No Dock icon leads back here, so it can't stay behind Terminal.
        setupWindow?.makeKeyAndOrderFront(nil)
        setupWindow?.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Watches while someone is connecting a provider or looking at the window, so
    /// a sign-in appears on its own and a forgotten window costs nothing.
    private func checkForSetupSignIns() {
        guard let setupWindow, setupWindow.isKeyWindow || !setupModel.connecting.isEmpty else { return }
        let connecting = Set(setupModel.connecting.keys)
        Task { [weak self] in
            guard let self else { return }
            await self.viewModel.checkForNewSignIns(connecting: connecting)
            let finished = self.setupModel.update(available: self.viewModel.availableProviders)
            if !finished.isEmpty {
                self.showSetupWindow()
            }
        }
    }

    private func connect(_ provider: DisplayProvider) {
        guard let signIn = setupModel.signIns[provider] else { return }
        switch signIn {
        case .terminal:
            let name = provider.rawValue.capitalized
            if signIn.runInTerminal(signingInTo: name) {
                setupModel.startConnecting(provider)
            } else {
                presentAlert(
                    title: "Couldn't Open Terminal",
                    message: "Run this in Terminal to sign in to \(name):\n\n\(signIn.command ?? "")",
                    style: .warning
                )
            }
        case .claudeWebsite:
            setupModel.isSigningInToClaude = true
        case .kimiKey:
            authenticateKimi()
        case .zaiKey:
            if authenticateZai() {
                setupModel.startConnecting(provider)
            }
        case .download(_, let url):
            NSWorkspace.shared.open(url)
            setupModel.startConnecting(provider)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === setupWindow else { return }
        setupCheckTimer.stop()
        setupModel.reset()
        setupWindow = nil
    }

    @objc private func refreshData() {
        Task {
            await viewModel.rediscoverCredentialsAndRefresh()
        }
    }

    @objc private func authenticateClaude() {
        let alert = NSAlert()
        alert.messageText = "Authenticate Claude"
        alert.informativeText = """
        Open Terminal, run `claude`, and log in when prompted.
        Then click Refresh in Usagebar and your usage will appear.

        This also fixes "Session expired": re-logging in from the \
        terminal renews the credentials Usagebar reads.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Sign In with Browser…")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            showSetupWindow()
            setupModel.isSigningInToClaude = true
        }
    }

    @objc private func authenticateCodex() {
        presentAlert(
            title: "Authenticate Codex",
            message: "Run `codex login` in Terminal, then click Refresh in Usagebar.",
            style: .informational
        )
    }

    @objc private func authenticateKimi() {
        let alert = NSAlert()
        alert.messageText = "Set Up Kimi Code"
        alert.informativeText = """
        Run `kimi login` in Terminal, then click Refresh in Usagebar.

        Usagebar reads Kimi Code CLI's local OAuth credential without changing it. You can also paste a Kimi Code API key or a `kimi-auth` web token.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Paste Credential…")
        alert.addButton(withTitle: "Open Kimi Code Console")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            showKimiCredentialPrompt()
        case .alertThirdButtonReturn:
            if let url = URL(string: "https://www.kimi.com/code/console") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    /// z.ai has no sign-in, so the key goes where Usagebar already looks for it.
    /// Returns whether the key page was opened.
    private func authenticateZai() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Connect z.ai"
        alert.informativeText = """
        Create an API key on z.ai, then save it in `~/.zai/config.json` like this:

        {"apiKey": "your-key"}
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open z.ai API Keys")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn,
              let url = URL(string: "https://z.ai/manage-apikey/apikey-list") else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    private func showKimiCredentialPrompt() {
        let alert = NSAlert()
        alert.messageText = "Kimi Code Credential"
        alert.informativeText = "Paste a Kimi Code API key or the `kimi-auth` token from the Kimi Code console. It is encrypted locally."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let credentialField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        credentialField.placeholderString = "API key or kimi-auth token"
        alert.accessoryView = credentialField

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let credential = credentialField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty else { return }
        viewModel.saveKimiCredential(credential)
        rebuildMenu()
    }

    @objc private func showBoth() {
        viewModel.showOnly5hr = false
        viewModel.showOnlyWeekly = false
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func showOnly5h() {
        viewModel.showOnly5hr = true
        viewModel.showOnlyWeekly = false
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func showOnlyWeekly() {
        viewModel.showOnly5hr = false
        viewModel.showOnlyWeekly = true
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleAutoUpdate() {
        viewModel.autoUpdate.toggle()
        rebuildMenu()
    }

    @objc private func toggleFollowActiveApp() {
        viewModel.followActiveApp.toggle()
        focusProvider = nil
        syncCurrentProvider(preferSavedSelection: true)
        followFrontmostApp()
        restartProviderAnimation()
        rebuildMenu()
    }

    /// Re-enables the just-toggled provider if hiding it would leave no
    /// authenticated provider visible (the bar must never go blank).
    private func ensureAProviderRemainsShown(fallback keyPath: ReferenceWritableKeyPath<UsageViewModel, Bool>) {
        let anyShown =
            (viewModel.showClaude && viewModel.hasClaudeCredentials) ||
            (viewModel.showCodex && viewModel.hasCodexCredentials) ||
            (viewModel.showCursor && viewModel.hasCursorCredentials) ||
            (viewModel.showKimi && viewModel.hasKimiCredentials) ||
            (viewModel.showZai && viewModel.hasZaiCredentials)
        if !anyShown {
            viewModel[keyPath: keyPath] = true
        }
    }

    @objc private func toggleShowClaude() {
        viewModel.showClaude.toggle()
        ensureAProviderRemainsShown(fallback: \.showClaude)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowCodex() {
        viewModel.showCodex.toggle()
        ensureAProviderRemainsShown(fallback: \.showCodex)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowCursor() {
        viewModel.showCursor.toggle()
        ensureAProviderRemainsShown(fallback: \.showCursor)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowKimi() {
        viewModel.showKimi.toggle()
        ensureAProviderRemainsShown(fallback: \.showKimi)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowZai() {
        viewModel.showZai.toggle()
        ensureAProviderRemainsShown(fallback: \.showZai)
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func setAnimationInterval(_ sender: NSMenuItem) {
        viewModel.animationInterval = Double(sender.tag)
        if viewModel.animationInterval == 0 {
            preferredProvider = currentProvider
        }
        restartProviderAnimation()
        rebuildMenu()
    }

    @objc private func toggleIcon() {
        viewModel.showIcon.toggle()
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleLaunchAtLogin() {
        viewModel.launchAtStartup.toggle()
        rebuildMenu()
    }

    @objc private func signOutClaude() {
        viewModel.clearClaudeCredentials()
        if !viewModel.hasCredentials {
            stopProviderAnimation()
            showSetupStatus()
        } else {
            syncCurrentProvider(persistPreference: true)
            updateStatusImage()
        }
        rebuildMenu()
    }

    @objc private func signOutCodex() {
        viewModel.clearCodexCredentials()
        if !viewModel.hasCredentials {
            stopProviderAnimation()
            showSetupStatus()
        } else {
            syncCurrentProvider(persistPreference: true)
            updateStatusImage()
        }
        rebuildMenu()
    }

    @objc private func clearKimiCredential() {
        viewModel.clearKimiCredential()
        if !viewModel.hasCredentials {
            stopProviderAnimation()
            showSetupStatus()
        } else {
            syncCurrentProvider(persistPreference: true)
            updateStatusImage()
        }
        rebuildMenu()
    }

    @objc private func checkForUpdates() {
        runUpdate(interactive: true)
    }

    private func runUpdate(interactive: Bool) {
        guard !isUpdateRunning else { return }
        isUpdateRunning = true

        let appURL = Bundle.main.bundleURL

        Task {
            let updateResult = await Task.detached(priority: .userInitiated) {
                await Self.performUpdateCheck()
            }.value

            isUpdateRunning = false
            persistUpdateCheckMetadata(from: updateResult)

            switch updateResult {
            case .readyToInstall(_, let brewURL, let caskToken):
                installPreparedUpdate(
                    brewURL: brewURL,
                    caskToken: caskToken,
                    appURL: appURL,
                    interactive: interactive
                )
            case .alreadyUpToDate(let status):
                availableUpdateVersion = nil
                rebuildMenu()
                updateStatusImage()
                if interactive {
                    presentAlert(
                        title: "Already up to date",
                        message: alreadyUpToDateMessage(for: status),
                        style: .informational
                    )
                }
            case .stillRollingOut(let status):
                // The release exists but the Homebrew tap hasn't synced yet.
                // Not a failure: keep the update badge and retry on a later
                // background check.
                UserDefaults.standard.removeObject(forKey: Self.lastAutoUpdateVersionDefaultsKey)
                // Allow the next background check (and auto-retry) in ~10 minutes.
                lastReleaseCheckAt = Date().addingTimeInterval(-Self.releaseCheckInterval + 600)
                rebuildMenu()
                if interactive {
                    let version = status.latestRelease?.version ?? "the new version"
                    presentAlert(
                        title: "Update on its way",
                        message: "Usagebar \(version) was just published and is still rolling out. It will install automatically in a bit - nothing to do.",
                        style: .informational
                    )
                }
            case .failed(let status, let message):
                rebuildMenu()
                if interactive {
                    presentAlert(
                        title: "Update failed",
                        message: failureMessage(message, status: status),
                        style: .warning
                    )
                }
            }
        }
    }

    @objc private func openGitHubRepository() {
        NSWorkspace.shared.open(Self.repositoryURL)
    }

    private func installPreparedUpdate(
        brewURL: URL,
        caskToken: String,
        appURL: URL,
        interactive: Bool
    ) {
        guard let helperURL = Bundle.main.url(
            forResource: "install_update_and_relaunch",
            withExtension: "sh"
        ) else {
            handleUpdateHandoffFailure("The bundled update helper is missing.", interactive: interactive)
            return
        }

        let failureURL = Self.updateFailureURL
        do {
            try FileManager.default.createDirectory(
                at: failureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: failureURL)
            try? FileManager.default.removeItem(at: Self.updateLogURL)
        } catch {
            handleUpdateHandoffFailure(error.localizedDescription, interactive: interactive)
            return
        }

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            helperURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            brewURL.path,
            caskToken,
            appURL.path,
            failureURL.path,
            interactive ? "failure-interactive" : "failure-background"
        ]

        do {
            try helper.run()
            NSApp.terminate(nil)
        } catch {
            handleUpdateHandoffFailure(error.localizedDescription, interactive: interactive)
        }
    }

    private func handleUpdateHandoffFailure(_ detail: String, interactive: Bool) {
        UserDefaults.standard.removeObject(forKey: Self.lastAutoUpdateVersionDefaultsKey)
        guard interactive else { return }

        presentAlert(
            title: "Update failed",
            message: "Usagebar could not start the update helper.\n\(detail)",
            style: .warning
        )
    }

    private func presentPendingUpdateFailureIfNeeded() {
        let failureURL = Self.updateFailureURL
        try? FileManager.default.removeItem(at: Self.updateLogURL)
        guard let result = try? String(contentsOf: failureURL, encoding: .utf8) else {
            return
        }
        try? FileManager.default.removeItem(at: failureURL)

        var lines = result.components(separatedBy: .newlines)
        let failureKind = lines.isEmpty ? "" : lines.removeFirst()
        let detail = lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if failureKind == "failure-background" {
            UserDefaults.standard.removeObject(forKey: Self.lastAutoUpdateVersionDefaultsKey)
            return
        }
        guard failureKind == "failure-interactive" else { return }

        NSApp.activate(ignoringOtherApps: true)
        presentAlert(
            title: "Update failed",
            message: detail.isEmpty ? "Homebrew could not install the update." : detail,
            style: .warning
        )
    }

    private func presentAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private var installedAppDescriptor: String {
        let appInfo = Self.installedAppInfo()
        return "\(appInfo.version) (\(appInfo.build))"
    }

    private var installedAppUpdatedAt: Date? {
        Self.installedAppInfo().updatedAt
    }

    private var lastUpdateCheckAt: Date? {
        UserDefaults.standard.object(forKey: Self.lastUpdateCheckAtDefaultsKey) as? Date
    }

    private func recordInstalledAppVersionIfNeeded() {
        let defaults = UserDefaults.standard
        let currentDescriptor = installedAppDescriptor
        let previousDescriptor = defaults.string(forKey: Self.lastLaunchedAppDescriptorDefaultsKey)

        guard previousDescriptor != currentDescriptor else {
            return
        }

        defaults.set(currentDescriptor, forKey: Self.lastLaunchedAppDescriptorDefaultsKey)
        defaults.set(Date(), forKey: Self.lastInstalledUpdateAtDefaultsKey)
    }

    private func persistUpdateCheckMetadata(from result: UpdateResult) {
        UserDefaults.standard.set(result.status.checkedAt, forKey: Self.lastUpdateCheckAtDefaultsKey)
    }

    private func alreadyUpToDateMessage(for status: UpdateStatus) -> String {
        var lines = [
            "Installed: Usagebar \(status.installedApp.version) (\(status.installedApp.build))"
        ]

        if let latestRelease = status.latestRelease {
            var latestLine = "Latest release: \(latestRelease.version)"
            if let publishedAt = latestRelease.publishedAt {
                latestLine += " • \(formatAlertTimestamp(publishedAt))"
            }
            lines.append(latestLine)
        } else {
            lines.append("Latest release: unavailable right now")
        }

        if let updatedAt = status.installedApp.updatedAt {
            lines.append("Updated: \(formatAlertTimestamp(updatedAt))")
        }

        lines.append("Checked: \(formatAlertTimestamp(status.checkedAt))")
        return lines.joined(separator: "\n")
    }

    private func failureMessage(_ message: String, status: UpdateStatus) -> String {
        "\(message)\n\n\(alreadyUpToDateMessage(for: status))"
    }

    private func formatMenuTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatAlertTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private enum UpdateResult {
        case readyToInstall(UpdateStatus, URL, String)
        case alreadyUpToDate(UpdateStatus)
        case stillRollingOut(UpdateStatus)
        case failed(UpdateStatus, String)

        var status: UpdateStatus {
            switch self {
            case .readyToInstall(let status, _, _),
                 .alreadyUpToDate(let status),
                 .stillRollingOut(let status),
                 .failed(let status, _):
                return status
            }
        }
    }

    private struct InstalledAppInfo {
        let version: String
        let build: String
        let updatedAt: Date?
    }

    private struct ReleaseInfo {
        let version: String
        let publishedAt: Date?
    }

    private struct UpdateStatus {
        let installedApp: InstalledAppInfo
        let latestRelease: ReleaseInfo?
        let checkedAt: Date
    }

    private struct CommandResult {
        let status: Int32
        let output: String
    }

    nonisolated private static let preferredCaskTokens = ["usagebar", "justausagebar"]

    nonisolated private static func performUpdateCheck() async -> UpdateResult {
        let status = UpdateStatus(
            installedApp: installedAppInfo(),
            latestRelease: try? await fetchLatestRelease(),
            checkedAt: Date()
        )

        if let latestRelease = status.latestRelease,
           latestRelease.version.compare(status.installedApp.version, options: .numeric) != .orderedDescending {
            return .alreadyUpToDate(status)
        }

        return prepareHomebrewUpdate(status: status)
    }

    nonisolated private static func prepareHomebrewUpdate(status: UpdateStatus) -> UpdateResult {
        guard let brewURL = brewExecutableURL() else {
            return .failed(status, """
            Homebrew was not found. Run in Terminal:
            brew update && brew upgrade --cask usagebar
            """)
        }

        do {
            let update = try runCommand(executableURL: brewURL, arguments: ["update", "--quiet"])
            guard update.status == 0 else {
                return .failed(status, """
                Homebrew update failed.
                \(summarizeCommandOutput(update.output))
                """)
            }

            guard let installedCaskToken = try installedCaskToken(brewURL: brewURL) else {
                return .failed(status, """
                This copy of Usagebar is not managed by Homebrew cask.
                Reinstall it with:
                brew install --cask betoxf/tap/usagebar
                """)
            }

            let outdated = try runCommand(
                executableURL: brewURL,
                arguments: ["outdated", "--cask", installedCaskToken],
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"]
            )

            // Homebrew returns exit code 1 when `outdated` finds matching entries.
            guard outdated.status == 0 || outdated.status == 1 else {
                return .failed(status, """
                Could not check for updates.
                \(summarizeCommandOutput(outdated.output))
                """)
            }

            let isOutdated = outdated.output
                .split(whereSeparator: \.isNewline)
                .contains { line in
                    line.trimmingCharacters(in: .whitespacesAndNewlines) == installedCaskToken
                }

            guard isOutdated else {
                if let latestRelease = status.latestRelease,
                   latestRelease.version.compare(status.installedApp.version, options: .numeric) == .orderedDescending {
                    return .stillRollingOut(status)
                }
                return .alreadyUpToDate(status)
            }

            return .readyToInstall(status, brewURL, installedCaskToken)
        } catch {
            return .failed(status, """
            Homebrew update failed.
            \(error.localizedDescription)
            """)
        }
    }

    nonisolated private static func installedCaskToken(brewURL: URL) throws -> String? {
        for token in preferredCaskTokens {
            let result = try runCommand(
                executableURL: brewURL,
                arguments: ["list", "--cask", token]
            )
            if result.status == 0 {
                return token
            }
        }
        return nil
    }

    nonisolated private static func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: latestReleaseAPIURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Usagebar", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await ProviderHTTP.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tagName = json["tag_name"] as? String
        else {
            throw URLError(.cannotParseResponse)
        }

        let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        let publishedAt: Date?

        if let publishedAtString = json["published_at"] as? String {
            publishedAt = ISO8601DateFormatter().date(from: publishedAtString)
        } else {
            publishedAt = nil
        }

        return ReleaseInfo(version: version, publishedAt: publishedAt)
    }

    nonisolated private static func installedAppInfo() -> InstalledAppInfo {
        let infoDictionary = Bundle.main.infoDictionary ?? [:]
        let version = infoDictionary["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = infoDictionary["CFBundleVersion"] as? String ?? "?"
        let storedUpdatedAt = UserDefaults.standard.object(forKey: lastInstalledUpdateAtDefaultsKey) as? Date
        let bundleResourceValues = try? Bundle.main.bundleURL.resourceValues(forKeys: [.contentModificationDateKey])
        let bundleUpdatedAt = bundleResourceValues?.contentModificationDate

        return InstalledAppInfo(
            version: version,
            build: build,
            updatedAt: storedUpdatedAt ?? bundleUpdatedAt
        )
    }

    nonisolated private static var hasAnotherRunningInstance: Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .contains { application in
                application.processIdentifier != currentPID && !application.isTerminated
            }
    }

    nonisolated private static var updateFailureURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JustaUsageBar", isDirectory: true)
            .appendingPathComponent(updateFailureFileName)
    }

    nonisolated private static var updateLogURL: URL {
        URL(fileURLWithPath: updateFailureURL.path + ".log")
    }

    nonisolated private static func brewExecutableURL() -> URL? {
        let candidatePaths = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]

        let fileManager = FileManager.default

        for path in candidatePaths where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    nonisolated private static func runCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String] = [:]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        return CommandResult(status: process.terminationStatus, output: output)
    }

    nonisolated private static func summarizeCommandOutput(_ output: String) -> String {
        let trimmedLines = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !trimmedLines.isEmpty else {
            return "No additional details were returned by Homebrew."
        }

        return trimmedLines.prefix(6).joined(separator: "\n")
    }

    // MARK: - Provider Animation

    private var preferredProvider: DisplayProvider {
        get {
            guard
                let rawValue = UserDefaults.standard.string(forKey: preferredProviderDefaultsKey),
                let provider = DisplayProvider(rawValue: rawValue)
            else {
                return .claude
            }
            return provider
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: preferredProviderDefaultsKey)
        }
    }

    private func hasCredentials(for provider: DisplayProvider) -> Bool {
        switch provider {
        case .claude:
            return viewModel.hasClaudeCredentials
        case .codex:
            return viewModel.hasCodexCredentials
        case .cursor:
            return viewModel.hasCursorCredentials
        case .kimi:
            return viewModel.hasKimiCredentials
        case .zai:
            return viewModel.hasZaiCredentials
        }
    }

    private func isProviderEnabled(_ provider: DisplayProvider) -> Bool {
        switch provider {
        case .claude:
            return viewModel.showClaude
        case .codex:
            return viewModel.showCodex
        case .cursor:
            return viewModel.showCursor
        case .kimi:
            return viewModel.showKimi
        case .zai:
            return viewModel.showZai
        }
    }

    /// Every provider that is authenticated and toggled on, in display order.
    private func enabledProvidersWithCredentials() -> [DisplayProvider] {
        DisplayProvider.displayOrder.filter { hasCredentials(for: $0) && isProviderEnabled($0) }
    }

    private func hasShownProviderWithCredentials(excluding excludedProvider: DisplayProvider) -> Bool {
        enabledProvidersWithCredentials().contains { $0 != excludedProvider }
    }

    private func canDisplay(_ provider: DisplayProvider) -> Bool {
        guard hasCredentials(for: provider) else { return false }

        if isProviderEnabled(provider) {
            return true
        }

        // If the saved provider is the only authenticated one left, keep showing it
        // instead of falling back to a blank/incorrect status item.
        return !hasShownProviderWithCredentials(excluding: provider)
    }

    /// Providers eligible to display right now, in fixed order.
    private func displayableProviders() -> [DisplayProvider] {
        let enabled = enabledProvidersWithCredentials()
        if !enabled.isEmpty {
            return enabled
        }
        // Nothing is both on and authenticated (e.g. all toggled off) — fall back
        // to anything authenticated so the bar never goes blank.
        return DisplayProvider.displayOrder.filter { hasCredentials(for: $0) }
    }

    /// The provider shown after the current one when cycling (click or timer).
    private func providerAfter(_ provider: DisplayProvider) -> DisplayProvider? {
        let providers = displayableProviders()
        guard !providers.isEmpty else { return nil }
        guard let index = providers.firstIndex(of: provider) else { return providers.first }
        return providers[(index + 1) % providers.count]
    }

    private func resolveProvider(preferred provider: DisplayProvider) -> DisplayProvider? {
        if canDisplay(provider) {
            return provider
        }
        return displayableProviders().first
    }

    private func setCurrentProvider(_ provider: DisplayProvider, persistPreference: Bool = true) {
        currentProvider = provider
        viewModel.displayedProviderChanged(provider)

        if persistPreference {
            preferredProvider = provider
        }
    }

    private func syncCurrentProvider(preferSavedSelection: Bool = false, persistPreference: Bool = false) {
        // A Claude/ChatGPT/Codex app in front wins over saved selection and timer.
        if viewModel.followActiveApp, let focusProvider, canDisplay(focusProvider) {
            setCurrentProvider(focusProvider, persistPreference: false)
            return
        }

        let preferredSelection = preferSavedSelection ? preferredProvider : currentProvider

        guard let resolvedProvider = resolveProvider(preferred: preferredSelection) else {
            return
        }

        setCurrentProvider(resolvedProvider, persistPreference: persistPreference)
    }

    private var currentRotationSignature: String {
        [String(viewModel.shouldAnimateProviders), String(viewModel.animationInterval),
         viewModel.followActiveApp ? (focusProvider?.rawValue ?? "none") : "manual",
         displayableProviders().map(\.rawValue).joined(separator: ",")].joined(separator: "|")
    }

    private func startProviderAnimation() {
        stopProviderAnimation()
        syncCurrentProvider()
        rotationSignature = currentRotationSignature

        // Hold on the focused app's provider instead of flipping under it.
        let holdsFocus = viewModel.followActiveApp && focusProvider.map(canDisplay) == true
        let rotates = viewModel.shouldAnimateProviders && !holdsFocus
        viewModel.rotationChanged(isRotating: rotates)
        guard rotates else { return }

        providerSwitchTimer.start(every: viewModel.animationInterval) { [weak self] in
            guard let self, let nextProvider = self.providerAfter(self.currentProvider) else { return }
            self.setCurrentProvider(nextProvider, persistPreference: false)
            self.updateStatusImage()
        }
    }

    private func stopProviderAnimation() {
        providerSwitchTimer.stop()
        rotationSignature = ""
    }

    private func restartProviderAnimation() {
        stopProviderAnimation()
        if viewModel.hasCredentials {
            startProviderAnimation()
            updateStatusImage()
        }
    }

    // MARK: - Status Bar Image

    private func updateStatusImage() {
        guard let button = statusItem.button else { return }
        syncCurrentProvider()

        guard !viewModel.isBackgroundSuspended else { return }
        let key = statusRenderKey()
        guard key != lastRenderKey else { return }
        let image: NSImage
        let width: CGFloat
        if let (cachedKey, cachedImage, cachedWidth) = cachedStatusImages[currentProvider], cachedKey == key {
            image = cachedImage
            width = cachedWidth
        } else {
            (image, width) = createProviderImage(for: currentProvider)
            cachedStatusImages[currentProvider] = (key, image, width)
        }
        lastRenderKey = key

        if lastStatusLength != width {
            lastStatusLength = width
            statusItem.length = width
        }

        button.image = image
        button.toolTip = nil
    }

    private func statusRenderKey() -> StatusRenderKey {
        let primary: Int
        let secondary: Int?
        let label: String
        switch currentProvider {
        case .claude:
            primary = viewModel.usageData.weeklyUsed
            secondary = viewModel.usageData.fiveHourUsed
            label = "7d"
        case .codex:
            primary = viewModel.codexUsageData.primaryUsedPercent
            secondary = viewModel.codexUsageData.primaryIsWeekly ? nil : viewModel.codexUsageData.secondaryUsedPercent
            label = viewModel.codexUsageData.primaryWindowLabel
        case .cursor:
            primary = viewModel.cursorUsageData.usedPercent
            secondary = nil
            label = viewModel.cursorUsageData.windowLabel
        case .kimi:
            primary = viewModel.kimiUsageData.weeklyUsedPercent
            secondary = viewModel.kimiUsageData.fiveHourUsedPercent
            label = "7d"
        case .zai:
            primary = viewModel.zaiUsageData.usedPercent
            secondary = nil
            label = viewModel.zaiUsageData.windowLabel
        }
        return StatusRenderKey(
            provider: currentProvider, primary: primary, secondary: secondary, windowLabel: label,
            showIcon: viewModel.showIcon, only5h: viewModel.showOnly5hr, onlyWeekly: viewModel.showOnlyWeekly,
            dark: getDarkMode(), scale: statusItem.button?.window?.backingScaleFactor ?? 2,
            updateBadge: availableUpdateVersion != nil
        )
    }

    private func createProviderImage(for provider: DisplayProvider) -> (NSImage, CGFloat) {
        switch provider {
        case .claude:
            return createClaudeImage()
        case .codex:
            return createCodexImage()
        case .cursor:
            return createSimpleProviderImage(
                label: "Cursor",
                brandColor: brandCursorColor,
                usedPercent: viewModel.cursorUsageData.usedPercent,
                glyph: .cursor,
                windowLabel: viewModel.cursorUsageData.windowLabel
            )
        case .kimi:
            return createKimiImage()
        case .zai:
            return createSimpleProviderImage(
                label: "Code",
                brandColor: brandZaiColor,
                usedPercent: viewModel.zaiUsageData.usedPercent,
                glyph: .zai,
                windowLabel: viewModel.zaiUsageData.windowLabel
            )
        }
    }

    // MARK: - Cursor / Zai Image (shared single-value renderer)

    private enum ProviderGlyph {
        case cursor
        case kimi
        case zai
    }

    /// Compact status image for the single-percentage providers: brand glyph +
    /// name on top (when the icon is shown), one big percentage underneath.
    /// `windowLabel` is the tiny window hint before the number (e.g. "M").
    private func createSimpleProviderImage(
        label: String,
        brandColor: NSColor,
        usedPercent: Int,
        glyph: ProviderGlyph,
        windowLabel: String = ""
    ) -> (NSImage, CGFloat) {
        let showIcon = viewModel.showIcon
        let width: CGFloat = 50
        let height: CGFloat = showIcon ? 22 : 16

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let isDarkMode = getDarkMode()
        let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.25, alpha: 1.0)

        var yOffset: CGFloat = 0
        if showIcon {
            // Cursor's and ZCode's marks are monochrome — adapt to the menu
            // bar theme instead of using the accent color.
            let glyphColor: NSColor = switch glyph {
            case .cursor, .zai: isDarkMode ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)
            case .kimi: brandColor
            }
            if glyph == .cursor {
                drawCursorPlanMarks(centerX: width / 2, y: 12.5, height: 8, color: glyphColor)
            } else {
                let glyphSize: CGFloat = 7
                let labelAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                    .foregroundColor: textColor
                ]
                // The ZCode mark reads as the "Z" of "ZCode", so its label sits closer.
                let labelString = NSAttributedString(string: glyph == .zai ? label : " \(label)", attributes: labelAttributes)
                let glyphAdvance: CGFloat = glyph == .zai ? glyphSize + 1 : glyphSize
                let totalWidth = glyphAdvance + labelString.size().width
                let startX = (width - totalWidth) / 2
                drawGlyph(glyph, in: NSRect(x: startX, y: 13, width: glyphSize, height: glyphSize), color: glyphColor)
                labelString.draw(at: NSPoint(x: startX + glyphAdvance, y: 12))
            }
            yOffset = 0
        } else {
            yOffset = 3
        }

        let valueColor = usageHighlightColor(
            percentage: usedPercent,
            highThreshold: 90,
            accentColor: brandColor,
            fallback: textColor
        )
        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: valueColor
        ]
        let percentAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: valueColor
        ]
        let valuesString = NSMutableAttributedString()
        if !windowLabel.isEmpty {
            let tinyLabelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 6, weight: .regular),
                .foregroundColor: textColor.withAlphaComponent(0.7)
            ]
            valuesString.append(NSAttributedString(string: "\(windowLabel) ", attributes: tinyLabelAttributes))
        }
        valuesString.append(NSAttributedString(string: "\(usedPercent)", attributes: numberAttributes))
        valuesString.append(NSAttributedString(string: "%", attributes: percentAttributes))
        valuesString.draw(at: NSPoint(x: (width - valuesString.size().width) / 2, y: yOffset))

        if availableUpdateVersion != nil {
            brandClaudeColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: width - 5, y: height - 5, width: 4, height: 4)).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return (image, width)
    }

    /// Cursor's plan is shared by xAI, Grok, Cursor and Grok Bot, so its status
    /// item shows those four marks in a centered row instead of a glyph + name.
    /// The marks are vector paths so they stay sharp at any backing scale.
    private func drawCursorPlanMarks(centerX: CGFloat, y: CGFloat, height: CGFloat, color: NSColor) {
        let marks = cursorPlanMarkPaths(height: height)
        let shift = AffineTransform(translationByX: centerX - marks.width / 2, byY: y)
        color.setFill()
        for path in marks.paths {
            path.transform(using: shift)
            path.fill()
        }
    }

    /// The four marks laid out left to right from the origin, `height` tall.
    private func cursorPlanMarkPaths(height: CGFloat) -> (paths: [NSBezierPath], width: CGFloat) {
        let gap = height * 0.3125
        // (unit-space path, its unit width, size relative to `height`)
        let marks: [(path: NSBezierPath, unitWidth: CGFloat, scale: CGFloat)] = [
            (xMarkPath(), 1200 / 1227, 0.8),
            (grokMarkPath(), 1, 1),
            (cursorCubePath(), 0.88, 1),
            (grokBotMarkPath(), 1, 1)
        ]
        var x: CGFloat = 0
        var paths: [NSBezierPath] = []
        for mark in marks {
            let size = height * mark.scale
            var transform = AffineTransform(translationByX: x, byY: (height - size) / 2)
            transform.scale(size)
            mark.path.transform(using: transform)
            paths.append(mark.path)
            x += mark.unitWidth * size + gap
        }
        return (paths, x - gap)
    }

    private func cursorPlanMarksImage(height: CGFloat) -> NSImage {
        let marks = cursorPlanMarkPaths(height: height)
        return templateImage(size: NSSize(width: marks.width, height: height), paths: marks.paths)
    }

    /// A template asset filled with `color`, `height` points tall, for drawing
    /// into the status images, which are drawn in color rather than as templates.
    private func tintedAsset(_ name: String, height: CGFloat, color: NSColor) -> NSImage? {
        guard let asset = NSImage(named: name), asset.size.height > 0 else { return nil }
        let size = NSSize(width: height * asset.size.width / asset.size.height, height: height)
        return NSImage(size: size, flipped: false) { rect in
            asset.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// Fills `paths` into a vector template image, so it renders sharp and
    /// takes the tint of the view that shows it.
    private func templateImage(size: NSSize, paths: [NSBezierPath]) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            paths.forEach { $0.fill() }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Builds a closed polygon in unit space.
    private func polygon(_ points: [NSPoint], into path: NSBezierPath) {
        path.move(to: points[0])
        for point in points.dropFirst() { path.line(to: point) }
        path.close()
    }

    /// X (xAI) mark: a hollow thick stroke and a thin stroke, from the
    /// official 1200×1227 outline, flipped to y-up and scaled to unit height.
    private func xMarkPath() -> NSBezierPath {
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x / 1227, y: (1227 - y) / 1227) }
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        polygon([
            p(714.163, 519.284), p(1160.89, 0), p(1055.03, 0), p(667.137, 450.887),
            p(357.328, 0), p(0, 0), p(468.492, 681.821), p(0, 1226.37), p(105.866, 1226.37),
            p(515.491, 750.218), p(842.672, 1226.37), p(1200, 1226.37)
        ], into: path)
        polygon([
            p(569.165, 687.828), p(521.697, 619.934), p(144.011, 79.6944), p(306.615, 79.6944),
            p(611.412, 515.685), p(658.88, 583.579), p(1055.08, 1150.3), p(892.476, 1150.3)
        ], into: path)
        return path
    }

    /// Grok mark: a ring broken by a diagonal needle that tapers past it.
    private func grokMarkPath() -> NSBezierPath {
        let center = NSPoint(x: 0.5, y: 0.5)
        let k: CGFloat = 0.5 / 1.36            // ring radius 1 in a unit box
        let path = NSBezierPath()
        for (start, end) in [(CGFloat(62), CGFloat(224)), (245, 405)] {
            let radians = start * .pi / 180
            path.move(to: NSPoint(x: center.x + k * cos(radians), y: center.y + k * sin(radians)))
            path.appendArc(withCenter: center, radius: k, startAngle: start, endAngle: end)
            path.appendArc(withCenter: center, radius: 0.7 * k, startAngle: end, endAngle: start, clockwise: true)
            path.close()
        }
        let u = NSPoint(x: cos(CGFloat.pi / 4) * k, y: sin(CGFloat.pi / 4) * k)
        func p(along a: CGFloat, across c: CGFloat) -> NSPoint {
            NSPoint(x: center.x + u.x * a - u.y * c, y: center.y + u.y * a + u.x * c)
        }
        polygon([
            p(along: 1.9, across: 0), p(along: 0.92, across: 0.09), p(along: 0, across: 0.035),
            p(along: -0.92, across: 0.09), p(along: -1.9, across: 0), p(along: -0.92, across: -0.09),
            p(along: 0, across: -0.035), p(along: 0.92, across: -0.09)
        ], into: path)
        return path
    }

    /// Cursor mark: a pointy-top hexagon with an arrow-shaped facet cut out.
    private func cursorCubePath() -> NSBezierPath {
        let r: CGFloat = 0.5
        let center = NSPoint(x: 0.44, y: 0.5)
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: center.x + x * r, y: center.y + y * r) }
        let path = NSBezierPath()
        path.windingRule = .evenOdd
        polygon([p(0, 1), p(0.866, 0.5), p(0.866, -0.5), p(0, -1), p(-0.866, -0.5), p(-0.866, 0.5)], into: path)
        polygon([p(-0.74, 0.43), p(0.74, 0.43), p(0.01, -0.86), p(0.01, 0)], into: path)
        return path
    }

    /// Grok Bot mark: a ball with two tilted capsule eyes cut out.
    private func grokBotMarkPath() -> NSBezierPath {
        let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 1, height: 1))
        path.windingRule = .evenOdd
        for (eyeCenter, length, width) in [(NSPoint(x: 0.51, y: 0.61), CGFloat(0.21), CGFloat(0.12)),
                                           (NSPoint(x: 0.78, y: 0.72), 0.23, 0.11)] {
            let eye = NSBezierPath(
                roundedRect: NSRect(x: -width / 2, y: -length / 2, width: width, height: length),
                xRadius: width / 2, yRadius: width / 2
            )
            var transform = AffineTransform(translationByX: eyeCenter.x, byY: eyeCenter.y)
            transform.rotate(byDegrees: 30)
            eye.transform(using: transform)
            path.append(eye)
        }
        return path
    }

    /// ZCode mark: a top bar, a long diagonal and a bottom bar split by thin
    /// slanted gaps, in a unit-height box 1.13 wide.
    private func zcodeMarkPath() -> NSBezierPath {
        let path = NSBezierPath()
        polygon([NSPoint(x: 0, y: 1), NSPoint(x: 0.56, y: 1), NSPoint(x: 0.465, y: 0.86), NSPoint(x: 0, y: 0.86)], into: path)
        polygon([NSPoint(x: 0.64, y: 1), NSPoint(x: 1.13, y: 1), NSPoint(x: 0.46, y: 0), NSPoint(x: 0, y: 0)], into: path)
        polygon([NSPoint(x: 0.645, y: 0.16), NSPoint(x: 1.13, y: 0.16), NSPoint(x: 1.13, y: 0), NSPoint(x: 0.537, y: 0)], into: path)
        return path
    }

    /// Draws a small brand glyph. Cursor = hexagon mark; Zai = ZCode's Z mark.
    private func drawGlyph(_ glyph: ProviderGlyph, in rect: NSRect, color: NSColor) {
        color.set()
        switch glyph {
        case .cursor:
            let path = cursorCubePath()
            var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
            transform.scale(rect.height)
            path.transform(using: transform)
            path.fill()
        case .kimi:
            let kAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            let k = NSAttributedString(string: "K", attributes: kAttrs)
            k.draw(at: NSPoint(x: rect.minX, y: rect.minY - 1))

            let accent = NSBezierPath()
            accent.move(to: NSPoint(x: rect.minX + 5.4, y: rect.maxY - 0.4))
            accent.line(to: NSPoint(x: rect.minX + 6.5, y: rect.maxY + 1.0))
            accent.lineWidth = 1.1
            accent.lineCapStyle = .round
            brandKimiColor.setStroke()
            accent.stroke()
        case .zai:
            let path = zcodeMarkPath()
            let height = rect.width / 1.13
            var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY + (rect.height - height) / 2)
            transform.scale(height)
            path.transform(using: transform)
            path.fill()
        }
    }

    // MARK: - Kimi Code Image

    private func createKimiImage() -> (NSImage, CGFloat) {
        let showIcon = viewModel.showIcon
        let kimi = viewModel.kimiUsageData
        let fiveHour = kimi.fiveHourUsedPercent
        let showOnly5hr = viewModel.showOnly5hr && fiveHour != nil
        let showOnlyWeekly = viewModel.showOnlyWeekly || fiveHour == nil
        let width: CGFloat = showOnly5hr || showOnlyWeekly ? 50 : 80
        let height: CGFloat = showIcon ? 22 : 16

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let isDarkMode = getDarkMode()
        let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.25, alpha: 1.0)
        let yOffset: CGFloat = showIcon ? 0 : 3

        if showIcon {
            let glyphSize: CGFloat = 7
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                .foregroundColor: textColor
            ]
            let labelString = NSAttributedString(string: " Kimi Code", attributes: labelAttributes)
            let totalWidth = glyphSize + labelString.size().width
            let startX = (width - totalWidth) / 2

            drawGlyph(
                .kimi,
                in: NSRect(x: startX, y: 13, width: glyphSize, height: glyphSize),
                color: textColor
            )
            labelString.draw(at: NSPoint(x: startX + glyphSize, y: 12))
        }

        let weekly = kimi.weeklyUsedPercent
        let fiveHourColor = usageHighlightColor(
            percentage: fiveHour ?? 0,
            highThreshold: 90,
            accentColor: brandKimiColor,
            fallback: textColor
        )
        let weeklyColor = usageHighlightColor(
            percentage: weekly,
            highThreshold: 80,
            accentColor: brandKimiColor,
            fallback: textColor
        )
        let tinyLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6, weight: .regular),
            .foregroundColor: textColor.withAlphaComponent(0.7)
        ]
        let valuesString = NSMutableAttributedString()

        if !showOnlyWeekly, let fiveHour {
            valuesString.append(NSAttributedString(string: "5h ", attributes: tinyLabelAttributes))
            valuesString.append(usageValueString(fiveHour, color: fiveHourColor))
        }

        if !showOnly5hr {
            if !showOnlyWeekly {
                valuesString.append(NSAttributedString(string: "  ", attributes: tinyLabelAttributes))
            }
            valuesString.append(NSAttributedString(string: "W ", attributes: tinyLabelAttributes))
            valuesString.append(usageValueString(weekly, color: weeklyColor))
        }

        valuesString.draw(at: NSPoint(x: (width - valuesString.size().width) / 2, y: yOffset))

        if availableUpdateVersion != nil {
            brandClaudeColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: width - 5, y: height - 5, width: 4, height: 4)).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return (image, width)
    }

    private func usageValueString(_ percentage: Int, color: NSColor) -> NSAttributedString {
        let value = NSMutableAttributedString(string: "\(percentage)", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color
        ])
        value.append(NSAttributedString(string: "%", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: color
        ]))
        return value
    }

    // MARK: - Claude Image

    private func createClaudeImage() -> (NSImage, CGFloat) {
        let showIcon = viewModel.showIcon
        // Plans without a 5-hour window show a single "W X%" like the other
        // one-value providers.
        let fiveHour = viewModel.usageData.fiveHourUsed
        let showOnly5hr = viewModel.showOnly5hr && fiveHour != nil
        let showOnlyWeekly = viewModel.showOnlyWeekly || fiveHour == nil

        var width: CGFloat = 80
        if showOnly5hr || showOnlyWeekly { width = 50 }

        let height: CGFloat = showIcon ? 22 : 16

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let isDarkMode = getDarkMode()
        let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.25, alpha: 1.0)

        var yOffset: CGFloat = 0

        if showIcon {
            // The spark from the panel, in Claude's orange.
            let spark = tintedAsset("ClaudeSpark", height: 7, color: .usagebarClaudeOrange)
            let sparkWidth = spark?.size.width ?? 0

            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .medium),
                .foregroundColor: textColor
            ]
            let labelString = NSAttributedString(string: "Claude", attributes: labelAttributes)

            let totalLabelWidth = sparkWidth + 1.5 + labelString.size().width
            let labelStartX = (width - totalLabelWidth) / 2

            spark?.draw(in: NSRect(x: labelStartX, y: 13, width: sparkWidth, height: 7))
            labelString.draw(at: NSPoint(x: labelStartX + sparkWidth + 1.5, y: 12))
            yOffset = 0
        } else {
            yOffset = 3
        }

        let weekly = viewModel.usageData.weeklyUsed

        let fiveHourColor = usageHighlightColor(
            percentage: fiveHour ?? 0,
            highThreshold: 90,
            accentColor: brandClaudeColor,
            fallback: textColor
        )
        let weeklyColor = usageHighlightColor(
            percentage: weekly,
            highThreshold: 80,
            accentColor: brandClaudeColor,
            fallback: textColor
        )

        let tinyLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6, weight: .regular),
            .foregroundColor: textColor.withAlphaComponent(0.7)
        ]

        let number5hAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: fiveHourColor
        ]
        let percent5hAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: fiveHourColor
        ]
        let numberWAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: weeklyColor
        ]
        let percentWAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: weeklyColor
        ]

        let valuesString = NSMutableAttributedString()

        if !showOnlyWeekly, let fiveHour {
            valuesString.append(NSAttributedString(string: "5h ", attributes: tinyLabelAttributes))
            valuesString.append(NSAttributedString(string: "\(fiveHour)", attributes: number5hAttributes))
            valuesString.append(NSAttributedString(string: "%", attributes: percent5hAttributes))
        }

        if !showOnly5hr {
            if !showOnlyWeekly {
                valuesString.append(NSAttributedString(string: "  ", attributes: tinyLabelAttributes))
            }
            valuesString.append(NSAttributedString(string: "W ", attributes: tinyLabelAttributes))
            valuesString.append(NSAttributedString(string: "\(weekly)", attributes: numberWAttributes))
            valuesString.append(NSAttributedString(string: "%", attributes: percentWAttributes))
        }

        valuesString.draw(at: NSPoint(x: (width - valuesString.size().width) / 2, y: yOffset))

        if availableUpdateVersion != nil {
            brandClaudeColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: width - 5, y: height - 5, width: 4, height: 4)).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return (image, width)
    }

    // MARK: - Codex Image

    private func createCodexImage() -> (NSImage, CGFloat) {
        let showIcon = viewModel.showIcon
        // Once Codex's primary window IS the weekly one, the secondary weekly
        // is redundant — show a single "W X%" like the other one-value providers.
        let primaryIsWeekly = viewModel.codexUsageData.primaryIsWeekly
        let showOnly5hr = viewModel.showOnly5hr || primaryIsWeekly
        let showOnlyWeekly = viewModel.showOnlyWeekly && !primaryIsWeekly

        var width: CGFloat = 80
        if showOnly5hr || showOnlyWeekly { width = 50 }

        let height: CGFloat = showIcon ? 22 : 16

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let isDarkMode = getDarkMode()
        let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.25, alpha: 1.0)
        let codexBrandColor = isDarkMode ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)

        var yOffset: CGFloat = 0

        if showIcon {
            // The Codex logo and wordmark from the panel, in black or white.
            let lockupHeight: CGFloat = 9.5
            if let lockup = tintedAsset("CodexLockup", height: lockupHeight, color: codexBrandColor) {
                let lockupX = (width - lockup.size.width) / 2
                lockup.draw(in: NSRect(x: lockupX, y: 11.75, width: lockup.size.width, height: lockupHeight))
            }

            yOffset = 0
        } else {
            yOffset = 3
        }

        let codex = viewModel.codexUsageData
        let primary = codex.primaryUsedPercent
        let secondary = codex.secondaryUsedPercent

        // Use blue color for percentages based on usage
        let primaryColor = usageHighlightColor(
            percentage: primary,
            highThreshold: 90,
            accentColor: brandCodexColor,
            fallback: textColor
        )
        let secondaryColor = usageHighlightColor(
            percentage: secondary,
            highThreshold: 80,
            accentColor: brandCodexColor,
            fallback: textColor
        )

        let tinyLabelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 6, weight: .regular),
            .foregroundColor: textColor.withAlphaComponent(0.7)
        ]

        let numberPrimaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: primaryColor
        ]
        let percentPrimaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: primaryColor
        ]
        let numberSecondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: secondaryColor
        ]
        let percentSecondaryAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .medium),
            .foregroundColor: secondaryColor
        ]

        let valuesString = NSMutableAttributedString()

        if !showOnlyWeekly {
            let windowLabel = codex.primaryWindowLabel
            valuesString.append(NSAttributedString(string: "\(windowLabel) ", attributes: tinyLabelAttributes))
            valuesString.append(NSAttributedString(string: "\(primary)", attributes: numberPrimaryAttributes))
            valuesString.append(NSAttributedString(string: "%", attributes: percentPrimaryAttributes))
        }

        if !showOnly5hr {
            if !showOnlyWeekly {
                valuesString.append(NSAttributedString(string: "  ", attributes: tinyLabelAttributes))
            }
            valuesString.append(NSAttributedString(string: "W ", attributes: tinyLabelAttributes))
            valuesString.append(NSAttributedString(string: "\(secondary)", attributes: numberSecondaryAttributes))
            valuesString.append(NSAttributedString(string: "%", attributes: percentSecondaryAttributes))
        }

        valuesString.draw(at: NSPoint(x: (width - valuesString.size().width) / 2, y: yOffset))

        if availableUpdateVersion != nil {
            brandClaudeColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: width - 5, y: height - 5, width: 4, height: 4)).fill()
        }

        image.unlockFocus()
        image.isTemplate = false
        return (image, width)
    }

    // MARK: - Helpers

    private var brandClaudeColor: NSColor {
        NSColor(red: 0.83, green: 0.53, blue: 0.30, alpha: 1.0)
    }

    private var brandCodexColor: NSColor {
        NSColor(red: 0.14, green: 0.73, blue: 0.94, alpha: 1.0)
    }

    // Cursor's brand is monochrome: black on light menu bars, white on dark.
    private var brandCursorColor: NSColor {
        getDarkMode() ? .white : .black
    }

    private var brandKimiColor: NSColor {
        NSColor(red: 0.04, green: 0.48, blue: 1.0, alpha: 1.0)
    }

    private var brandZaiColor: NSColor {
        NSColor(red: 0.91, green: 0.35, blue: 0.42, alpha: 1.0)
    }

    private func usageHighlightColor(
        percentage: Int,
        highThreshold: Int,
        accentColor: NSColor,
        fallback: NSColor
    ) -> NSColor
    {
        percentage >= highThreshold ? accentColor : fallback
    }

    private var shouldPromptClaudeAuthentication: Bool {
        !viewModel.hasClaudeCredentials || viewModel.claudeError != nil
    }

    private var shouldPromptCodexAuthentication: Bool {
        !viewModel.hasCodexCredentials || viewModel.codexError == APIError.unauthorized.errorDescription
    }

    private func getDarkMode() -> Bool {
        if let button = statusItem.button {
            return button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
