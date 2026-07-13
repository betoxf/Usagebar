//
//  AppDelegate.swift
//  JustaUsageBar
//

import SwiftUI
import AppKit

enum DisplayProvider: String, CaseIterable {
    case claude
    case codex
    case cursor
    case zai

    /// Fixed left-to-right order used for cycling and menu layout.
    static let displayOrder: [DisplayProvider] = [.claude, .codex, .cursor, .zai]
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated private static let lastLaunchedAppDescriptorDefaultsKey = "lastLaunchedAppDescriptor"
    nonisolated private static let lastUpdateCheckAtDefaultsKey = "lastUpdateCheckAt"
    nonisolated private static let lastInstalledUpdateAtDefaultsKey = "lastInstalledUpdateAt"
    nonisolated private static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/betoxf/Usagebar/releases/latest")!
    nonisolated private static let repositoryURL = URL(string: "https://github.com/betoxf/Usagebar")!

    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var viewModel = UsageViewModel.shared
    private var lastStatusLength: CGFloat = 0
    private var credentialsWindow: NSWindow?
    private let preferredProviderDefaultsKey = "preferredDisplayProvider"

    // Provider switching state
    private var currentProvider: DisplayProvider = .claude
    private var providerSwitchTimer: Timer?
    /// Provider forced by the frontmost app (Claude/ChatGPT/Codex), nil when
    /// no matching app is active.
    private var focusProvider: DisplayProvider?

    // Update availability state
    private var availableUpdateVersion: String?
    private var lastReleaseCheckAt: Date?
    private var isUpdateRunning = false
    nonisolated private static let releaseCheckInterval: TimeInterval = 6 * 3600
    nonisolated private static let lastAutoUpdateVersionDefaultsKey = "lastAutoUpdateAttemptedVersion"

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        observeChanges()
        recordInstalledAppVersionIfNeeded()

        NSApp.setActivationPolicy(.accessory)

        if viewModel.hasCredentials {
            if viewModel.followActiveApp, let frontmost = NSWorkspace.shared.frontmostApplication {
                focusProvider = provider(matching: frontmost)
            }
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

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    // MARK: - Focus-Aware Provider

    @objc private func activeAppChanged(_ notification: Notification) {
        guard viewModel.followActiveApp, viewModel.hasCredentials else { return }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        let newFocus = provider(matching: app)
        guard newFocus != focusProvider else { return }
        focusProvider = newFocus

        if let provider = newFocus, canDisplay(provider) {
            stopProviderAnimation()
            setCurrentProvider(provider, persistPreference: false)
            updateStatusImage()
        } else {
            syncCurrentProvider(preferSavedSelection: true)
            restartProviderAnimation()
        }
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
        if bundleId == "com.todesktop.230313mzl4w4u92" || name == "cursor" {
            return .cursor
        }
        return nil
    }

    @objc private func appearanceChanged() {
        if viewModel.hasCredentials {
            updateStatusImage()
        }
    }

    @objc private func settingsChanged() {
        if viewModel.hasCredentials {
            syncCurrentProvider()
            restartProviderAnimation()
            updateStatusImage()
        } else {
            showSetupStatus()
        }
        rebuildMenu()
    }

    @objc private func usageDataChanged() {
        if viewModel.hasCredentials {
            syncCurrentProvider()
            updateStatusImage()
        } else {
            showSetupStatus()
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
        guard let button = statusItem.button else { return }

        let width: CGFloat = 50
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let isDarkMode: Bool = {
            return button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }()

        let anthropicOrange = NSColor(red: 0.83, green: 0.53, blue: 0.30, alpha: 1.0)
        let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.25, alpha: 1.0)

        let starAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .bold),
            .foregroundColor: anthropicOrange
        ]
        let starString = NSAttributedString(string: "\u{2733}\u{FE0E}", attributes: starAttributes)

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7, weight: .medium),
            .foregroundColor: textColor
        ]
        let labelString = NSAttributedString(string: "Claude", attributes: labelAttributes)

        let totalLabelWidth = starString.size().width + 1 + labelString.size().width
        let labelStartX = (width - totalLabelWidth) / 2

        starString.draw(at: NSPoint(x: labelStartX, y: 12))
        labelString.draw(at: NSPoint(x: labelStartX + starString.size().width + 1, y: 12))

        let setupAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9, weight: .medium),
            .foregroundColor: anthropicOrange
        ]
        let setupString = NSAttributedString(string: "Setup", attributes: setupAttributes)
        let setupX = (width - setupString.size().width) / 2
        setupString.draw(at: NSPoint(x: setupX, y: 0))

        image.unlockFocus()
        image.isTemplate = false

        statusItem.length = width
        button.image = image
        button.toolTip = nil
    }

    private func setupMenu() {
        menu = NSMenu()
        rebuildMenu()
        // Don't set statusItem.menu - we handle clicks manually
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let hasClaude = viewModel.hasClaudeCredentials
        let hasCodex = viewModel.hasCodexCredentials
        let hasCursor = viewModel.hasCursorCredentials
        let hasZai = viewModel.hasZaiCredentials

        if !hasClaude && !hasCodex && !hasCursor && !hasZai {
            let setupItem = NSMenuItem(title: "Setup Usage Tracking", action: #selector(showCredentialsWindow), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
        } else {
            // Claude usage section
            if viewModel.showClaude {
                let claudeHeader = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
                claudeHeader.isEnabled = false
                let anthropicOrange = NSColor(red: 0.83, green: 0.53, blue: 0.30, alpha: 1.0)

                // Build header with auth method
                let authMethod: String = switch viewModel.claudeAuthSource {
                case .oauth:
                    "via OAuth"
                case .webSession:
                    "via Browser"
                case .none:
                    ""
                }

                let headerString = NSMutableAttributedString()
                headerString.append(NSAttributedString(string: "\u{2733}\u{FE0E} Claude  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: anthropicOrange
                ]))
                headerString.append(NSAttributedString(string: "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
                ]))
                headerString.append(NSAttributedString(string: authMethod, attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]))

                claudeHeader.attributedTitle = headerString
                menu.addItem(claudeHeader)

                if hasClaude {
                    let fiveHour = viewModel.usageData.fiveHourUsed
                    let weekly = viewModel.usageData.weeklyUsed
                    let fiveHourReset = viewModel.usageData.timeUntilFiveHourReset
                    let weeklyReset = viewModel.usageData.timeUntilWeeklyReset

                    let fiveHourColor = usageHighlightColor(
                        percentage: fiveHour,
                        highThreshold: 90,
                        accentColor: brandClaudeColor,
                        fallback: NSColor.labelColor
                    )
                    let weeklyColor = usageHighlightColor(
                        percentage: weekly,
                        highThreshold: 80,
                        accentColor: brandClaudeColor,
                        fallback: NSColor.labelColor
                    )

                    let fiveHourItem = NSMenuItem(title: "  5h: \(fiveHour)%  \u{2022}  \(fiveHourReset)", action: nil, keyEquivalent: "")
                    fiveHourItem.isEnabled = false
                    let fiveHourAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular)
                    ]
                    let fiveHourString = NSMutableAttributedString(string: "  5h: ", attributes: fiveHourAttrs)
                    fiveHourString.append(NSAttributedString(string: "\(fiveHour)", attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: fiveHourColor
                    ]))
                    fiveHourString.append(NSAttributedString(string: "%  \u{2022}  \(fiveHourReset)", attributes: fiveHourAttrs))
                    fiveHourItem.attributedTitle = fiveHourString
                    menu.addItem(fiveHourItem)

                    let weeklyItem = NSMenuItem(title: "  7d: \(weekly)%  \u{2022}  \(weeklyReset)", action: nil, keyEquivalent: "")
                    weeklyItem.isEnabled = false
                    let weeklyAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular)
                    ]
                    let weeklyString = NSMutableAttributedString(string: "  7d: ", attributes: weeklyAttrs)
                    weeklyString.append(NSAttributedString(string: "\(weekly)", attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: weeklyColor
                    ]))
                    weeklyString.append(NSAttributedString(string: "%  \u{2022}  \(weeklyReset)", attributes: weeklyAttrs))
                    weeklyItem.attributedTitle = weeklyString
                    menu.addItem(weeklyItem)

                    if viewModel.usageData.hasFableData {
                        let fable = viewModel.usageData.fableUsed ?? 0
                        let fableReset = viewModel.usageData.timeUntilFableReset
                        let fableColor = usageHighlightColor(
                            percentage: fable,
                            highThreshold: 80,
                            accentColor: brandClaudeColor,
                            fallback: NSColor.labelColor
                        )

                        let fableItem = NSMenuItem(title: "  Fable: \(fable)%  \u{2022}  \(fableReset)", action: nil, keyEquivalent: "")
                        fableItem.isEnabled = false
                        let fableAttrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.systemFont(ofSize: 11, weight: .regular)
                        ]
                        let fableString = NSMutableAttributedString(string: "  Fable: ", attributes: fableAttrs)
                        fableString.append(NSAttributedString(string: "\(fable)", attributes: [
                            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                            .foregroundColor: fableColor
                        ]))
                        fableString.append(NSAttributedString(string: "%  \u{2022}  \(fableReset)", attributes: fableAttrs))
                        fableItem.attributedTitle = fableString
                        menu.addItem(fableItem)
                    }

                    if let claudeError = viewModel.claudeError {
                        menu.addItem(makeStatusMessageItem(claudeError, color: .systemOrange))
                        if shouldPromptClaudeAuthentication {
                            let authItem = NSMenuItem(title: "How to authenticate Claude", action: #selector(authenticateClaude), keyEquivalent: "")
                            authItem.target = self
                            menu.addItem(authItem)
                        }
                    }
                } else {
                    menu.addItem(makeStatusMessageItem("Not authenticated", color: .secondaryLabelColor))
                    let authItem = NSMenuItem(title: "How to authenticate Claude", action: #selector(authenticateClaude), keyEquivalent: "")
                    authItem.target = self
                    menu.addItem(authItem)
                }
            }

            // Codex usage section
            if viewModel.showCodex {
                if viewModel.showClaude {
                    menu.addItem(NSMenuItem.separator())
                }

                let codexHeader = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
                codexHeader.isEnabled = false
                let codexBlue = NSColor(red: 0.1, green: 0.2, blue: 0.5, alpha: 1.0)

                // Build header with plan type
                let codex = viewModel.codexUsageData
                let planInfo = codex.planType != "unknown" ? codex.planType.capitalized : ""

                let headerString = NSMutableAttributedString()
                headerString.append(NSAttributedString(string: "Codex  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: codexBlue
                ]))
                if !planInfo.isEmpty {
                    headerString.append(NSAttributedString(string: planInfo, attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }

                codexHeader.attributedTitle = headerString
                menu.addItem(codexHeader)

                if hasCodex {
                    let primaryLabel = codex.primaryWindowLabel
                    let primary = codex.primaryUsedPercent
                    let primaryReset = codex.timeUntilPrimaryReset

                    let primaryColor = usageHighlightColor(
                        percentage: primary,
                        highThreshold: 90,
                        accentColor: brandCodexColor,
                        fallback: NSColor.labelColor
                    )

                    let primaryItem = NSMenuItem(title: "  \(primaryLabel): \(primary)%  \u{2022}  \(primaryReset)", action: nil, keyEquivalent: "")
                    primaryItem.isEnabled = false
                    let primaryAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 11, weight: .regular)
                    ]
                    let primaryString = NSMutableAttributedString(string: "  \(primaryLabel): ", attributes: primaryAttrs)
                    primaryString.append(NSAttributedString(string: "\(primary)", attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: primaryColor
                    ]))
                    primaryString.append(NSAttributedString(string: "%  \u{2022}  \(primaryReset)", attributes: primaryAttrs))
                    primaryItem.attributedTitle = primaryString
                    menu.addItem(primaryItem)

                    if !codex.primaryIsWeekly, codex.secondaryUsedPercent > 0 || codex.secondaryResetAt != nil {
                        let secondary = codex.secondaryUsedPercent
                        let secondaryReset = codex.timeUntilSecondaryReset
                        let secondaryColor = usageHighlightColor(
                            percentage: secondary,
                            highThreshold: 80,
                            accentColor: brandCodexColor,
                            fallback: NSColor.labelColor
                        )

                        let secondaryItem = NSMenuItem(title: "  7d: \(secondary)%  \u{2022}  \(secondaryReset)", action: nil, keyEquivalent: "")
                        secondaryItem.isEnabled = false
                        let secondaryString = NSMutableAttributedString(string: "  7d: ", attributes: primaryAttrs)
                        secondaryString.append(NSAttributedString(string: "\(secondary)", attributes: [
                            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                            .foregroundColor: secondaryColor
                        ]))
                        secondaryString.append(NSAttributedString(string: "%  \u{2022}  \(secondaryReset)", attributes: primaryAttrs))
                        secondaryItem.attributedTitle = secondaryString
                        menu.addItem(secondaryItem)
                    }

                    if let codexError = viewModel.codexError {
                        menu.addItem(makeStatusMessageItem(codexError, color: .systemOrange))
                        if shouldPromptCodexAuthentication {
                            let authItem = NSMenuItem(title: "How to authenticate Codex", action: #selector(authenticateCodex), keyEquivalent: "")
                            authItem.target = self
                            menu.addItem(authItem)
                        }
                    }
                } else {
                    menu.addItem(makeStatusMessageItem("Not authenticated", color: .secondaryLabelColor))
                    let authItem = NSMenuItem(title: "How to authenticate Codex", action: #selector(authenticateCodex), keyEquivalent: "")
                    authItem.target = self
                    menu.addItem(authItem)
                }
            }

            // Cursor usage section
            if hasCursor && viewModel.showCursor {
                if viewModel.showClaude || viewModel.showCodex {
                    menu.addItem(NSMenuItem.separator())
                }
                let cursor = viewModel.cursorUsageData
                let planInfo = cursor.planName != "unknown" ? cursor.planName.capitalized : ""
                appendSimpleProviderSection(
                    title: "Cursor",
                    titleColor: NSColor.labelColor,
                    subtitle: planInfo,
                    usedPercent: cursor.usedPercent,
                    resetText: cursor.timeUntilReset,
                    error: viewModel.cursorError,
                    accentColor: brandCursorColor,
                    windowLabel: "M"
                )
            }

            // Zai usage section
            if hasZai && viewModel.showZai {
                if viewModel.showClaude || viewModel.showCodex || (hasCursor && viewModel.showCursor) {
                    menu.addItem(NSMenuItem.separator())
                }
                let zai = viewModel.zaiUsageData
                let planInfo = zai.planName != "unknown" ? zai.planName.capitalized : ""
                appendSimpleProviderSection(
                    title: "z.ai",
                    titleColor: NSColor(red: 0.91, green: 0.35, blue: 0.42, alpha: 1.0),
                    subtitle: planInfo,
                    usedPercent: zai.usedPercent,
                    resetText: zai.timeUntilReset,
                    error: viewModel.zaiError,
                    windowLabel: zai.windowLabel
                )
            }

            menu.addItem(NSMenuItem.separator())

            // Refresh
            let refreshItem = NSMenuItem(title: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)

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
            let authedProviderCount = [hasClaude, hasCodex, hasCursor, hasZai].filter { $0 }.count
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
                    followItem.toolTip = "Show a provider's usage when its app (Claude, ChatGPT/Codex, or Cursor) is in front"
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

    @objc private func statusBarButtonClicked() {
        let event = NSApp.currentEvent

        // Right click shows menu
        if event?.type == .rightMouseUp {
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
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
                // If only one provider, show menu
                statusItem.menu = menu
                statusItem.button?.performClick(nil)
                statusItem.menu = nil
            }
        }
    }

    @objc private func showCredentialsWindow() {
        if credentialsWindow == nil {
            let contentView = CredentialsView(onSave: { [weak self] sessionKey, orgId in
                self?.viewModel.saveCredentials(sessionKey: sessionKey, organizationId: orgId)
                self?.credentialsWindow?.close()
                self?.credentialsWindow = nil
                self?.updateStatusImage()
                self?.startProviderAnimation()
                self?.rebuildMenu()
            })

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = ""
            window.titlebarAppearsTransparent = true
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.contentView = NSHostingView(rootView: contentView)
            window.center()
            window.isReleasedWhenClosed = false
            credentialsWindow = window
        }

        credentialsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        alert.addButton(withTitle: "Manual Setup…")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            showCredentialsWindow()
        }
    }

    @objc private func authenticateCodex() {
        presentAlert(
            title: "Authenticate Codex",
            message: "Run `codex login` in Terminal, then click Refresh in Usagebar.",
            style: .informational
        )
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
        if !viewModel.followActiveApp {
            focusProvider = nil
            syncCurrentProvider(preferSavedSelection: true)
            restartProviderAnimation()
        }
        rebuildMenu()
    }

    /// Re-enables the just-toggled provider if hiding it would leave no
    /// authenticated provider visible (the bar must never go blank).
    private func ensureAProviderRemainsShown(fallback keyPath: ReferenceWritableKeyPath<UsageViewModel, Bool>) {
        let anyShown =
            (viewModel.showClaude && viewModel.hasClaudeCredentials) ||
            (viewModel.showCodex && viewModel.hasCodexCredentials) ||
            (viewModel.showCursor && viewModel.hasCursorCredentials) ||
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
            case .updated(_):
                relaunchApplication(at: appURL)
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

    private func relaunchApplication(at appURL: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
            NSApp.terminate(nil)
        }
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
        case updated(UpdateStatus)
        case alreadyUpToDate(UpdateStatus)
        case stillRollingOut(UpdateStatus)
        case failed(UpdateStatus, String)

        var status: UpdateStatus {
            switch self {
            case .updated(let status), .alreadyUpToDate(let status), .stillRollingOut(let status), .failed(let status, _):
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

        return performHomebrewUpdate(status: status)
    }

    nonisolated private static func performHomebrewUpdate(status: UpdateStatus) -> UpdateResult {
        guard let brewURL = brewExecutableURL() else {
            return .failed(status, """
            Homebrew was not found. Run in Terminal:
            brew update && brew upgrade --cask usagebar
            """)
        }

        do {
            guard let installedCaskToken = try installedCaskToken(brewURL: brewURL) else {
                return .failed(status, """
                This copy of Usagebar is not managed by Homebrew cask.
                Reinstall it with:
                brew install --cask betoxf/tap/usagebar
                """)
            }

            let update = try runCommand(executableURL: brewURL, arguments: ["update", "--quiet"])
            guard update.status == 0 else {
                return .failed(status, """
                Homebrew update failed.
                \(summarizeCommandOutput(update.output))
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

            let upgrade = try runCommand(
                executableURL: brewURL,
                arguments: ["upgrade", "--cask", installedCaskToken],
                environment: ["HOMEBREW_NO_AUTO_UPDATE": "1"]
            )

            guard upgrade.status == 0 else {
                return .failed(status, """
                Homebrew could not install the update.
                \(summarizeCommandOutput(upgrade.output))
                """)
            }

            return .updated(status)
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

        let (data, response) = try await URLSession.shared.data(for: request)

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

    private func startProviderAnimation() {
        stopProviderAnimation()
        syncCurrentProvider()

        guard viewModel.shouldAnimateProviders else {
            return
        }

        // Hold on the focused app's provider instead of flipping under it.
        if viewModel.followActiveApp, let focusProvider, canDisplay(focusProvider) {
            return
        }

        providerSwitchTimer = Timer.scheduledTimer(withTimeInterval: viewModel.animationInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let nextProvider = self.providerAfter(self.currentProvider) else { return }
                self.setCurrentProvider(nextProvider, persistPreference: false)
                self.updateStatusImage()
            }
        }
        // Let the system coalesce timer wakeups to save energy.
        providerSwitchTimer?.tolerance = viewModel.animationInterval * 0.1
    }

    private func stopProviderAnimation() {
        providerSwitchTimer?.invalidate()
        providerSwitchTimer = nil
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

        let (image, width) = createProviderImage(for: currentProvider)

        if lastStatusLength != width {
            lastStatusLength = width
            statusItem.length = width
        }

        button.image = image
        button.toolTip = nil
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
                windowLabel: "M"
            )
        case .zai:
            return createSimpleProviderImage(
                label: "z.ai",
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
            let glyphSize: CGFloat = 7
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                .foregroundColor: textColor
            ]
            let labelString = NSAttributedString(string: " \(label)", attributes: labelAttributes)
            let totalWidth = glyphSize + labelString.size().width
            let startX = (width - totalWidth) / 2

            // Cursor's mark is monochrome (black cube, gray faces) — adapt to
            // the menu bar theme instead of using the accent color.
            let glyphColor: NSColor = switch glyph {
            case .cursor: isDarkMode ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)
            case .zai: brandColor
            }
            drawGlyph(glyph, in: NSRect(x: startX, y: 13, width: glyphSize, height: glyphSize), color: glyphColor)
            labelString.draw(at: NSPoint(x: startX + glyphSize, y: 12))
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

    /// Draws a small brand glyph. Cursor = isometric cube; Zai = bold Z.
    private func drawGlyph(_ glyph: ProviderGlyph, in rect: NSRect, color: NSColor) {
        color.set()
        switch glyph {
        case .cursor:
            // Isometric cube like Cursor's logo: a pointy-top hexagon split
            // into three rhombus faces with distinct shading.
            let cx = rect.midX, cy = rect.midY
            let r = rect.width / 2
            func vertex(_ degrees: CGFloat) -> NSPoint {
                let rad = degrees * .pi / 180
                return NSPoint(x: cx + r * cos(rad), y: cy + r * sin(rad))
            }
            let center = NSPoint(x: cx, y: cy)
            let top = vertex(90), upLeft = vertex(150), downLeft = vertex(210)
            let bottom = vertex(270), downRight = vertex(330), upRight = vertex(30)

            func fillFace(_ points: [NSPoint], alpha: CGFloat) {
                let path = NSBezierPath()
                path.move(to: points[0])
                for point in points.dropFirst() { path.line(to: point) }
                path.close()
                color.withAlphaComponent(alpha).setFill()
                path.fill()
            }
            fillFace([upLeft, top, upRight, center], alpha: 1.0)          // top
            fillFace([upLeft, center, bottom, downLeft], alpha: 0.62)     // left
            fillFace([center, upRight, downRight, bottom], alpha: 0.30)   // right
        case .zai:
            let zAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 8, weight: .bold),
                .foregroundColor: color
            ]
            let z = NSAttributedString(string: "Z", attributes: zAttrs)
            z.draw(at: NSPoint(x: rect.minX, y: rect.minY - 1))
        }
    }

    // MARK: - Claude Image

    private func createClaudeImage() -> (NSImage, CGFloat) {
        let showIcon = viewModel.showIcon
        let showOnly5hr = viewModel.showOnly5hr
        let showOnlyWeekly = viewModel.showOnlyWeekly

        var width: CGFloat = 80
        if showOnly5hr || showOnlyWeekly { width = 50 }

        let height: CGFloat = showIcon ? 22 : 16

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let isDarkMode = getDarkMode()
        let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.25, alpha: 1.0)

        var yOffset: CGFloat = 0

        if showIcon {
            let starColor = brandClaudeColor
            let starAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .bold),
                .foregroundColor: starColor
            ]
            let starString = NSAttributedString(string: "\u{2733}\u{FE0E}", attributes: starAttributes)

            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .medium),
                .foregroundColor: textColor
            ]
            let labelString = NSAttributedString(string: "Claude", attributes: labelAttributes)

            let totalLabelWidth = starString.size().width + 1 + labelString.size().width
            let labelStartX = (width - totalLabelWidth) / 2

            starString.draw(at: NSPoint(x: labelStartX, y: 12))
            labelString.draw(at: NSPoint(x: labelStartX + starString.size().width + 1, y: 12))
            yOffset = 0
        } else {
            yOffset = 3
        }

        let fiveHour = viewModel.usageData.fiveHourUsed
        let weekly = viewModel.usageData.weeklyUsed

        let fiveHourColor = usageHighlightColor(
            percentage: fiveHour,
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

        if !showOnlyWeekly {
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
            // Draw icon and "Codex" label (no gradient, just black/white)
            let iconFont = NSFont.systemFont(ofSize: 6, weight: .regular)
            let iconString = ">_"
            let codexIconColor = codexBrandColor

            let iconAttrs: [NSAttributedString.Key: Any] = [
                .font: iconFont,
                .foregroundColor: codexIconColor
            ]
            let codexIcon = NSAttributedString(string: iconString, attributes: iconAttrs)

            let codexLabelAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7, weight: .semibold),
                .foregroundColor: codexBrandColor
            ]
            let codexLabel = NSAttributedString(string: " Codex", attributes: codexLabelAttrs)

            let totalLabelWidth = codexIcon.size().width + codexLabel.size().width
            let labelStartX = (width - totalLabelWidth) / 2

            codexIcon.draw(at: NSPoint(x: labelStartX, y: 12))
            codexLabel.draw(at: NSPoint(x: labelStartX + codexIcon.size().width, y: 12))

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

    private var brandCursorColor: NSColor {
        NSColor(red: 0.0, green: 0.75, blue: 0.65, alpha: 1.0)
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

    /// Header + single "used% • reset" row shared by Cursor and Zai.
    /// `accentColor` (defaults to the title color) highlights high usage;
    /// `windowLabel` prefixes the row (e.g. "M" for a monthly window).
    private func appendSimpleProviderSection(
        title: String,
        titleColor: NSColor,
        subtitle: String,
        usedPercent: Int,
        resetText: String,
        error: String?,
        accentColor: NSColor? = nil,
        windowLabel: String = ""
    ) {
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        let headerString = NSMutableAttributedString(string: "\(title)  ", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: titleColor
        ])
        if !subtitle.isEmpty {
            headerString.append(NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
        }
        header.attributedTitle = headerString
        menu.addItem(header)

        let valueColor = usageHighlightColor(
            percentage: usedPercent,
            highThreshold: 90,
            accentColor: accentColor ?? titleColor,
            fallback: NSColor.labelColor
        )
        let rowPrefix = windowLabel.isEmpty ? "  " : "  \(windowLabel): "
        let row = NSMenuItem(title: "\(rowPrefix)\(usedPercent)%  \u{2022}  \(resetText)", action: nil, keyEquivalent: "")
        row.isEnabled = false
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .regular)]
        let rowString = NSMutableAttributedString(string: rowPrefix, attributes: attrs)
        rowString.append(NSAttributedString(string: "\(usedPercent)", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: valueColor
        ]))
        rowString.append(NSAttributedString(string: "%  \u{2022}  \(resetText)", attributes: attrs))
        row.attributedTitle = rowString
        menu.addItem(row)

        if let error {
            menu.addItem(makeStatusMessageItem(error, color: .systemOrange))
        }
    }

    private func makeStatusMessageItem(_ title: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(string: "  \(title)", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: color
        ])
        return item
    }

    private func getDarkMode() -> Bool {
        if let button = statusItem.button {
            return button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
        return NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Credentials View (for setup window)

struct CredentialsView: View {
    let onSave: (String, String) -> Void

    @State private var showManualEntry = false
    @State private var sessionKey = ""
    @State private var organizationId = ""

    private let anthropicOrange = Color(red: 0.83, green: 0.53, blue: 0.30)

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 4) {
                Text("\u{2733}\u{FE0E}")
                    .foregroundColor(anthropicOrange)
                    .font(.title2)
                Text("Claude Usage")
                    .font(.headline)
            }
            .padding(.top, 8)

            // Auto-detected status
            VStack(spacing: 8) {
                if ClaudeOAuthService.shared.hasCredentials {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Claude detected")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                if CodexAPIService.shared.hasCredentials {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Codex detected")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal)
                }
            }

            if ClaudeOAuthService.shared.hasCredentials || CodexAPIService.shared.hasCredentials {
                VStack(spacing: 10) {
                    if ClaudeOAuthService.shared.hasCredentials {
                        Button(action: {
                            onSave("__oauth__", "__oauth__")
                        }) {
                            HStack {
                                Image(systemName: "sparkles")
                                Text("Use Claude Detected Credentials")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(anthropicOrange)
                    }

                    if CodexAPIService.shared.hasCredentials {
                        Button(action: {
                            onSave("__detected_codex__", "__detected_codex__")
                        }) {
                            HStack {
                                Image(systemName: "terminal")
                                Text("Use Codex Detected Credentials")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(anthropicOrange)
                    }
                }

                Divider()
                    .padding(.vertical, 4)
            }

            if !showManualEntry {
                Spacer()
                VStack(spacing: 16) {
                    Text("Manual Claude setup")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Divider()
                        .padding(.vertical, 4)

                    Button(action: { showManualEntry = true }) {
                        HStack {
                            Image(systemName: "keyboard")
                            Text("Manual Entry")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)

                    Text("For advanced users")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                // Manual entry form
                VStack(alignment: .leading, spacing: 10) {
                    Text("Manual Credential Entry")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Organization ID")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("From URL: claude.ai/chat \u{2192} copy UUID after /organizations/")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        TextField("263e9fcb-52b9-4372-8842-...", text: $organizationId)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session Key")
                            .font(.caption)
                            .fontWeight(.medium)
                        Text("From DevTools \u{2192} Application \u{2192} Cookies \u{2192} sessionKey")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                        SecureField("sk-ant-sid01-...", text: $sessionKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Button("\u{2190} Back") {
                            showManualEntry = false
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundColor(.secondary)

                        Spacer()

                        Button("Save") {
                            onSave(sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                   organizationId.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(anthropicOrange)
                        .disabled(sessionKey.isEmpty || organizationId.isEmpty)
                    }
                }
            }

            Spacer()

            Text("Not affiliated with Anthropic or OpenAI.\nCredentials stored locally (encrypted).")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 300, height: 400)
    }
}
