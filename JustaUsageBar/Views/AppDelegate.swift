//
//  AppDelegate.swift
//  JustaUsageBar
//

import SwiftUI
import AppKit

enum DisplayProvider: String {
    case claude
    case codex
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

    // Animation state
    private var currentProvider: DisplayProvider = .claude
    private var providerSwitchTimer: Timer?
    private var promoAnimationTimer: Timer?
    private var promoAnimationPhase: CGFloat = 0
    private var promoHeaderShowsCountdown = true
    private var lastPromoHeaderSlot: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        observeChanges()
        recordInstalledAppVersionIfNeeded()

        NSApp.setActivationPolicy(.accessory)

        if viewModel.hasCredentials {
            syncCurrentProvider(preferSavedSelection: true, persistPreference: true)
            restartProviderAnimation()
            restartPromoAnimation()
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
            restartPromoAnimation()
            updateStatusImage()
        } else {
            showSetupStatus()
        }
        rebuildMenu()
    }

    @objc private func usageDataChanged() {
        if viewModel.hasCredentials {
            syncCurrentProvider()
            restartPromoAnimation()
            updateStatusImage()
        } else {
            showSetupStatus()
        }
        rebuildMenu()
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
        stopPromoAnimation()
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

        if !hasClaude && !hasCodex {
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
                let peakLabel = viewModel.shouldShowClaudePeakIndicator ? "  ↓ Peak hour" : ""

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
                if !peakLabel.isEmpty {
                    headerString.append(NSAttributedString(string: peakLabel, attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .regular),
                        .foregroundColor: anthropicOrange.withAlphaComponent(0.9)
                    ]))
                }

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
                        accentColor: animatedClaudeAccentColor(),
                        fallback: NSColor.labelColor
                    )
                    let weeklyColor = usageHighlightColor(
                        percentage: weekly,
                        highThreshold: 80,
                        accentColor: animatedClaudeAccentColor(phaseShift: 0.14),
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

                    if let claudeError = viewModel.claudeError {
                        menu.addItem(makeStatusMessageItem(claudeError, color: .systemOrange))
                        if shouldPromptClaudeAuthentication {
                            let authItem = NSMenuItem(title: "Authenticate Claude…", action: #selector(authenticateClaude), keyEquivalent: "")
                            authItem.target = self
                            menu.addItem(authItem)
                        }
                    }
                } else {
                    menu.addItem(makeStatusMessageItem("Not authenticated", color: .secondaryLabelColor))
                    let authItem = NSMenuItem(title: "Authenticate Claude…", action: #selector(authenticateClaude), keyEquivalent: "")
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
                let promoLabel: String = {
                    guard viewModel.isPromoVisibilityInWindow else { return "" }
                    if promoHeaderShowsCountdown, let remaining = viewModel.codexPromoTimeRemainingText {
                        return "• 2x • \(remaining)"
                    }
                    return "• 2x • \(viewModel.codexPromoEndDisplayText)"
                }()

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
                if !promoLabel.isEmpty {
                    headerString.append(NSAttributedString(string: promoLabel, attributes: [
                        .font: NSFont.systemFont(ofSize: 10, weight: .regular),
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
                        accentColor: animatedCodexAccentColor(),
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

                    if codex.secondaryUsedPercent > 0 || codex.secondaryResetAt != nil {
                        let secondary = codex.secondaryUsedPercent
                        let secondaryReset = codex.timeUntilSecondaryReset
                        let secondaryColor = usageHighlightColor(
                            percentage: secondary,
                            highThreshold: 80,
                            accentColor: animatedCodexAccentColor(phaseShift: 0.14),
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

            if hasCodex {
                let promoVisibilityItem = NSMenuItem(title: "Show Promo Visibility", action: #selector(togglePromoVisibility), keyEquivalent: "")
                promoVisibilityItem.target = self
                promoVisibilityItem.state = viewModel.showPromoVisibility ? .on : .off
                promoVisibilityItem.isEnabled = viewModel.isPromoVisibilityInWindow
                displayMenu.addItem(promoVisibilityItem)
            }

            // Provider toggles
            if hasClaude || hasCodex {
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

                // Animation interval submenu
                if hasClaude && hasCodex && viewModel.showClaude && viewModel.showCodex {
                    displayMenu.addItem(NSMenuItem.separator())

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

        menu.addItem(makeStatusMessageItem("Version \(installedAppDescriptor)", color: .secondaryLabelColor))

        if let updatedAt = installedAppUpdatedAt {
            menu.addItem(makeStatusMessageItem("Updated \(formatMenuTimestamp(updatedAt))", color: .secondaryLabelColor))
        }

        if let lastCheckedAt = lastUpdateCheckAt {
            menu.addItem(makeStatusMessageItem("Checked \(formatMenuTimestamp(lastCheckedAt))", color: .secondaryLabelColor))
        }

        menu.addItem(NSMenuItem.separator())

        let reviewRepoItem = NSMenuItem(title: "Review GitHub Repo", action: #selector(openGitHubRepository), keyEquivalent: "")
        reviewRepoItem.target = self
        if let githubMark = NSImage(named: "GitHubMark") {
            githubMark.size = NSSize(width: 14, height: 14)
            reviewRepoItem.image = githubMark
        }
        menu.addItem(reviewRepoItem)

        // Check for Updates
        let updateItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdates), keyEquivalent: "u")
        updateItem.target = self
        menu.addItem(updateItem)

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

        // Left click toggles provider if both are shown
        if event?.type == .leftMouseUp {
            let hasBoth = viewModel.hasClaudeCredentials && viewModel.hasCodexCredentials &&
                          viewModel.showClaude && viewModel.showCodex

            if hasBoth {
                // Switch provider immediately (manual mode or auto mode)
                setCurrentProvider((currentProvider == .claude) ? .codex : .claude)
                updateStatusImage()
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
        showCredentialsWindow()
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

    @objc private func togglePromoVisibility() {
        viewModel.showPromoVisibility.toggle()
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowClaude() {
        viewModel.showClaude.toggle()
        // Ensure at least one provider is shown
        if !viewModel.showClaude && !viewModel.showCodex {
            viewModel.showCodex = true
        }
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    @objc private func toggleShowCodex() {
        viewModel.showCodex.toggle()
        if !viewModel.showClaude && !viewModel.showCodex {
            viewModel.showClaude = true
        }
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
        let appURL = Bundle.main.bundleURL

        Task {
            let updateResult = await Task.detached(priority: .userInitiated) {
                await Self.performUpdateCheck()
            }.value

            persistUpdateCheckMetadata(from: updateResult)
            rebuildMenu()

            switch updateResult {
            case .updated(_):
                relaunchApplication(at: appURL)
            case .alreadyUpToDate(let status):
                presentAlert(
                    title: "Already up to date",
                    message: alreadyUpToDateMessage(for: status),
                    style: .informational
                )
            case .failed(let status, let message):
                presentAlert(
                    title: "Update failed",
                    message: failureMessage(message, status: status),
                    style: .warning
                )
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
        case failed(UpdateStatus, String)

        var status: UpdateStatus {
            switch self {
            case .updated(let status), .alreadyUpToDate(let status), .failed(let status, _):
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
                    return .failed(status, """
                    Latest release \(latestRelease.version) is published, but Homebrew has not picked it up yet.
                    Try again in a minute.
                    """)
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
        }
    }

    private func isProviderEnabled(_ provider: DisplayProvider) -> Bool {
        switch provider {
        case .claude:
            return viewModel.showClaude
        case .codex:
            return viewModel.showCodex
        }
    }

    private func hasShownProviderWithCredentials(excluding excludedProvider: DisplayProvider) -> Bool {
        for provider in [DisplayProvider.claude, .codex] where provider != excludedProvider {
            if hasCredentials(for: provider) && isProviderEnabled(provider) {
                return true
            }
        }
        return false
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

    private func resolveProvider(preferred provider: DisplayProvider) -> DisplayProvider? {
        if canDisplay(provider) {
            return provider
        }

        let fallback: DisplayProvider = (provider == .claude) ? .codex : .claude
        if canDisplay(fallback) {
            return fallback
        }

        return nil
    }

    private func setCurrentProvider(_ provider: DisplayProvider, persistPreference: Bool = true) {
        currentProvider = provider

        if persistPreference {
            preferredProvider = provider
        }
    }

    private func syncCurrentProvider(preferSavedSelection: Bool = false, persistPreference: Bool = false) {
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

        providerSwitchTimer = Timer.scheduledTimer(withTimeInterval: viewModel.animationInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let nextProvider: DisplayProvider = (self.currentProvider == .claude) ? .codex : .claude
                self.setCurrentProvider(nextProvider, persistPreference: false)
                self.updateStatusImage()
            }
        }
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

    private func startPromoAnimation() {
        stopPromoAnimation()

        guard shouldAnimateAnyAccentState else {
            promoAnimationPhase = 0
            promoHeaderShowsCountdown = true
            lastPromoHeaderSlot = nil
            return
        }

        promoAnimationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                guard self.shouldAnimateAnyAccentState else {
                    self.stopPromoAnimation()
                    self.updateStatusImage()
                    return
                }

                self.promoAnimationPhase = (self.promoAnimationPhase + 0.0225).truncatingRemainder(dividingBy: 1.0)
                if self.shouldAnimateMenuMetadata {
                    let currentSlot = Int(Date().timeIntervalSinceReferenceDate / 2.0)
                    if self.lastPromoHeaderSlot != currentSlot {
                        self.lastPromoHeaderSlot = currentSlot
                        self.promoHeaderShowsCountdown = currentSlot.isMultiple(of: 2)
                        self.rebuildMenu()
                    }
                }

                self.updateStatusImage()
            }
        }
    }

    private func stopPromoAnimation() {
        promoAnimationTimer?.invalidate()
        promoAnimationTimer = nil
        lastPromoHeaderSlot = nil
    }

    private func restartPromoAnimation() {
        if viewModel.hasCredentials && shouldAnimateAnyAccentState {
            startPromoAnimation()
        } else {
            stopPromoAnimation()
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
        button.toolTip = statusTooltip(for: currentProvider)
    }

    private func createProviderImage(for provider: DisplayProvider) -> (NSImage, CGFloat) {
        switch provider {
        case .claude:
            return createClaudeImage()
        case .codex:
            return createCodexImage()
        }
    }

    // MARK: - Claude Image

    private func createClaudeImage() -> (NSImage, CGFloat) {
        let showIcon = viewModel.showIcon
        let showOnly5hr = viewModel.showOnly5hr
        let showOnlyWeekly = viewModel.showOnlyWeekly
        let showPeakIndicator = viewModel.shouldShowClaudePeakIndicator && !showOnlyWeekly

        var width: CGFloat = 80
        if showOnly5hr || showOnlyWeekly { width = 50 }
        if showPeakIndicator { width += 14 }

        let height: CGFloat = showIcon ? 22 : 16

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let isDarkMode = getDarkMode()
        let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.25, alpha: 1.0)

        var yOffset: CGFloat = 0

        if showIcon {
            let starColor = shouldAnimateClaudeBrandAccent
                ? animatedClaudeAccentColor(phaseShift: 0.12)
                : brandClaudeColor
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
            accentColor: animatedClaudeAccentColor(),
            fallback: textColor
        )
        let weeklyColor = usageHighlightColor(
            percentage: weekly,
            highThreshold: 80,
            accentColor: animatedClaudeAccentColor(phaseShift: 0.14),
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

        if showPeakIndicator {
            let symbolConfig = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            let arrowSize = NSSize(width: 10, height: 10)
            let badgeGap: CGFloat = 4
            let valuesX = (width - valuesString.size().width) / 2
            let arrowX = max(0, valuesX - badgeGap - arrowSize.width)
            let badgeY = (height - arrowSize.height) / 2 - 0.2

            if let arrowSymbol = NSImage(
                systemSymbolName: "arrow.down.circle.fill",
                accessibilityDescription: "Claude peak hour"
            )?.withSymbolConfiguration(symbolConfig) {
                let tintedSymbol = arrowSymbol.copy() as? NSImage ?? arrowSymbol
                tintedSymbol.lockFocus()
                animatedClaudeAccentColor(phaseShift: 0.34).set()
                NSRect(origin: .zero, size: tintedSymbol.size).fill(using: .sourceAtop)
                tintedSymbol.unlockFocus()
                tintedSymbol.draw(in: NSRect(x: arrowX, y: badgeY, width: arrowSize.width, height: arrowSize.height))
            }

            valuesString.draw(at: NSPoint(x: valuesX, y: yOffset))
        } else {
            valuesString.draw(at: NSPoint(x: (width - valuesString.size().width) / 2, y: yOffset))
        }

        image.unlockFocus()
        image.isTemplate = false
        return (image, width)
    }

    // MARK: - Codex Image

    private func createCodexImage() -> (NSImage, CGFloat) {
        let showIcon = viewModel.showIcon
        let showOnly5hr = viewModel.showOnly5hr
        let showOnlyWeekly = viewModel.showOnlyWeekly
        let showPromo = viewModel.shouldShowCodexPromo && !showOnlyWeekly

        var width: CGFloat = 80
        if showOnly5hr || showOnlyWeekly { width = 50 }
        if showPromo { width += 14 }

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
            let codexIconColor = shouldAnimateCodexBrandAccent
                ? animatedCodexAccentColor(phaseShift: 0.12)
                : codexBrandColor

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
            accentColor: animatedCodexAccentColor(),
            fallback: textColor
        )
        let secondaryColor = usageHighlightColor(
            percentage: secondary,
            highThreshold: 80,
            accentColor: animatedCodexAccentColor(phaseShift: 0.14),
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

        if showPromo {
            let promo2Attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: animatedCodexAccentColor(phaseShift: 0.08)
            ]
            let promoXAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: animatedCodexAccentColor(phaseShift: 0.2)
            ]

            let promoString = NSMutableAttributedString()
            promoString.append(NSAttributedString(string: "2", attributes: promo2Attributes))
            promoString.append(NSAttributedString(string: "x", attributes: promoXAttributes))

            let promoGap: CGFloat = 4
            let valuesX = (width - valuesString.size().width) / 2
            let promoX = max(0, valuesX - promoGap - promoString.size().width)
            let promoY = (height - promoString.size().height) / 2 - (promoString.size().height * 0.2)

            promoString.draw(at: NSPoint(x: promoX, y: promoY))
            valuesString.draw(at: NSPoint(x: valuesX, y: yOffset))
        } else {
            valuesString.draw(at: NSPoint(x: (width - valuesString.size().width) / 2, y: yOffset))
        }

        image.unlockFocus()
        image.isTemplate = false
        return (image, width)
    }

    // MARK: - Helpers

    private var brandClaudeColor: NSColor {
        NSColor(red: 0.83, green: 0.53, blue: 0.30, alpha: 1.0)
    }

    private func shouldAnimateUsageHighlight(percentage: Int, highThreshold: Int) -> Bool {
        percentage == 0 || percentage >= highThreshold
    }

    private var shouldAnimateClaudeBrandAccent: Bool {
        canDisplay(.claude) && viewModel.shouldAnimateClaudeUsageActivity
    }

    private var shouldAnimateClaudeHighlightedValues: Bool {
        let showFiveHour = !viewModel.showOnlyWeekly
        let showWeekly = !viewModel.showOnly5hr

        return (
            (showFiveHour && shouldAnimateUsageHighlight(percentage: viewModel.usageData.fiveHourUsed, highThreshold: 90)) ||
            (showWeekly && shouldAnimateUsageHighlight(percentage: viewModel.usageData.weeklyUsed, highThreshold: 80))
        )
    }

    private var shouldAnimateCodexBrandAccent: Bool {
        canDisplay(.codex) && viewModel.shouldAnimateCodexUsageActivity
    }

    private var shouldAnimateCodexHighlightedValues: Bool {
        let showPrimary = !viewModel.showOnlyWeekly
        let showSecondary = !viewModel.showOnly5hr
        let codex = viewModel.codexUsageData

        return (
            (showPrimary && shouldAnimateUsageHighlight(percentage: codex.primaryUsedPercent, highThreshold: 90)) ||
            (showSecondary && shouldAnimateUsageHighlight(percentage: codex.secondaryUsedPercent, highThreshold: 80))
        )
    }

    private var shouldAnimateMenuMetadata: Bool {
        viewModel.shouldShowCodexPromo || viewModel.shouldShowClaudePeakIndicator
    }

    private var shouldAnimateAnyAccentState: Bool {
        shouldAnimateClaudeBrandAccent ||
            shouldAnimateCodexBrandAccent ||
            shouldAnimateClaudeHighlightedValues ||
            shouldAnimateCodexHighlightedValues ||
            shouldAnimateMenuMetadata
    }

    private func usageHighlightColor(
        percentage: Int,
        highThreshold: Int,
        accentColor: NSColor,
        fallback: NSColor
    ) -> NSColor
    {
        guard shouldAnimateUsageHighlight(percentage: percentage, highThreshold: highThreshold) else {
            return fallback
        }
        return accentColor
    }

    private func animatedCodexAccentColor(phaseShift: CGFloat = 0) -> NSColor {
        let colors = [
            NSColor(red: 0.15, green: 0.81, blue: 0.63, alpha: 1.0),
            NSColor(red: 0.14, green: 0.73, blue: 0.94, alpha: 1.0),
            NSColor(red: 0.33, green: 0.57, blue: 0.99, alpha: 1.0)
        ]

        let normalizedPhase = (promoAnimationPhase + phaseShift).truncatingRemainder(dividingBy: 1.0)
        let scaled = normalizedPhase * CGFloat(colors.count)
        let startIndex = Int(floor(scaled)) % colors.count
        let endIndex = (startIndex + 1) % colors.count
        let blend = scaled - CGFloat(startIndex)

        return colors[startIndex].blended(withFraction: blend, of: colors[endIndex]) ?? colors[startIndex]
    }

    private func animatedClaudeAccentColor(phaseShift: CGFloat = 0) -> NSColor {
        let colors = [
            NSColor(red: 0.83, green: 0.53, blue: 0.30, alpha: 1.0),
            NSColor(red: 0.91, green: 0.67, blue: 0.45, alpha: 1.0),
            NSColor(red: 0.75, green: 0.42, blue: 0.20, alpha: 1.0)
        ]

        let normalizedPhase = (promoAnimationPhase + phaseShift).truncatingRemainder(dividingBy: 1.0)
        let scaled = normalizedPhase * CGFloat(colors.count)
        let startIndex = Int(floor(scaled)) % colors.count
        let endIndex = (startIndex + 1) % colors.count
        let blend = scaled - CGFloat(startIndex)

        return colors[startIndex].blended(withFraction: blend, of: colors[endIndex]) ?? colors[startIndex]
    }

    private func statusTooltip(for provider: DisplayProvider) -> String? {
        switch provider {
        case .claude:
            return viewModel.shouldShowClaudePeakIndicator ? "Claude peak hour: faster consumption" : nil
        case .codex:
            return viewModel.shouldShowCodexPromo ? "Codex 2x usage active" : nil
        }
    }

    private var shouldPromptClaudeAuthentication: Bool {
        !viewModel.hasClaudeCredentials || viewModel.claudeError != nil
    }

    private var shouldPromptCodexAuthentication: Bool {
        !viewModel.hasCodexCredentials || viewModel.codexError == APIError.unauthorized.errorDescription
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
