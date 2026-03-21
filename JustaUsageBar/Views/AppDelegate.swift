//
//  AppDelegate.swift
//  JustaUsageBar
//

import SwiftUI
import AppKit

enum DisplayProvider {
    case claude
    case codex
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var viewModel = UsageViewModel.shared
    private var lastStatusLength: CGFloat = 0
    private var credentialsWindow: NSWindow?

    // Animation state
    private var currentProvider: DisplayProvider = .claude
    private var providerSwitchTimer: Timer?
    private var transitionTimer: Timer?
    private var transitionProgress: CGFloat = 0
    private var isTransitioning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        observeChanges()

        NSApp.setActivationPolicy(.accessory)

        if viewModel.hasCredentials {
            updateStatusImage()
            startProviderAnimation()
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
            updateStatusImage()
        }
        restartProviderAnimation()
        rebuildMenu()
    }

    @objc private func usageDataChanged() {
        if viewModel.hasCredentials {
            updateStatusImage()
            startProviderAnimation()
        } else {
            showSetupStatus()
        }
        rebuildMenu()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
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
    }

    private func setupMenu() {
        menu = NSMenu()
        rebuildMenu()
        statusItem.menu = menu
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
            if hasClaude && viewModel.showClaude {
                let claudeHeader = NSMenuItem(title: "Claude", action: nil, keyEquivalent: "")
                claudeHeader.isEnabled = false
                let headerAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor(red: 0.83, green: 0.53, blue: 0.30, alpha: 1.0)
                ]
                claudeHeader.attributedTitle = NSAttributedString(string: "\u{2733}\u{FE0E} Claude", attributes: headerAttrs)
                menu.addItem(claudeHeader)

                let fiveHour = viewModel.usageData.fiveHourUsed
                let weekly = viewModel.usageData.weeklyUsed
                let fiveHourReset = viewModel.usageData.timeUntilFiveHourReset
                let weeklyReset = viewModel.usageData.timeUntilWeeklyReset

                let fiveHourItem = NSMenuItem(title: "  5h: \(fiveHour)%  \u{2022}  \(fiveHourReset)", action: nil, keyEquivalent: "")
                fiveHourItem.isEnabled = false
                menu.addItem(fiveHourItem)

                let weeklyItem = NSMenuItem(title: "  7d: \(weekly)%  \u{2022}  \(weeklyReset)", action: nil, keyEquivalent: "")
                weeklyItem.isEnabled = false
                menu.addItem(weeklyItem)

                // Auth source indicator
                let sourceLabel: String
                switch viewModel.claudeAuthSource {
                case .oauth: sourceLabel = "  via CLI (OAuth)"
                case .webSession: sourceLabel = "  via Browser Session"
                case .none: sourceLabel = "  not connected"
                }
                let sourceItem = NSMenuItem(title: sourceLabel, action: nil, keyEquivalent: "")
                sourceItem.isEnabled = false
                let sourceAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
                sourceItem.attributedTitle = NSAttributedString(string: sourceLabel, attributes: sourceAttrs)
                menu.addItem(sourceItem)
            }

            // Codex usage section
            if hasCodex && viewModel.showCodex {
                if hasClaude && viewModel.showClaude {
                    menu.addItem(NSMenuItem.separator())
                }

                let codexHeader = NSMenuItem(title: "Codex", action: nil, keyEquivalent: "")
                codexHeader.isEnabled = false
                let headerAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .heavy),
                    .foregroundColor: NSColor.labelColor
                ]
                codexHeader.attributedTitle = NSAttributedString(string: "Codex", attributes: headerAttrs)
                menu.addItem(codexHeader)

                let codex = viewModel.codexUsageData
                let primaryLabel = codex.primaryWindowLabel
                let primaryItem = NSMenuItem(title: "  \(primaryLabel): \(codex.primaryUsedPercent)%  \u{2022}  \(codex.timeUntilPrimaryReset)", action: nil, keyEquivalent: "")
                primaryItem.isEnabled = false
                menu.addItem(primaryItem)

                if codex.secondaryUsedPercent > 0 || codex.secondaryResetAt != nil {
                    let secondaryItem = NSMenuItem(title: "  7d: \(codex.secondaryUsedPercent)%  \u{2022}  \(codex.timeUntilSecondaryReset)", action: nil, keyEquivalent: "")
                    secondaryItem.isEnabled = false
                    menu.addItem(secondaryItem)
                }

                if codex.planType != "unknown" {
                    let planItem = NSMenuItem(title: "  Plan: \(codex.planType.capitalized)", action: nil, keyEquivalent: "")
                    planItem.isEnabled = false
                    let planAttrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 10),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                    planItem.attributedTitle = NSAttributedString(string: "  Plan: \(codex.planType.capitalized)", attributes: planAttrs)
                    menu.addItem(planItem)
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
                    for seconds: Double in [5, 8, 10, 15, 30] {
                        let label = seconds < 60 ? "\(Int(seconds))s" : "\(Int(seconds / 60))m"
                        let item = NSMenuItem(title: label, action: #selector(setAnimationInterval(_:)), keyEquivalent: "")
                        item.target = self
                        item.tag = Int(seconds)
                        item.state = (Int(viewModel.animationInterval) == Int(seconds)) ? .on : .off
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

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: - Menu Actions

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
            await viewModel.refresh()
        }
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
            currentProvider = .codex
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
            currentProvider = .claude
            updateStatusImage()
        }
        rebuildMenu()
    }

    // MARK: - Provider Animation

    private func startProviderAnimation() {
        stopProviderAnimation()

        guard viewModel.shouldAnimateProviders else {
            // Show whichever is available
            if viewModel.hasClaudeCredentials && viewModel.showClaude {
                currentProvider = .claude
            } else if viewModel.hasCodexCredentials && viewModel.showCodex {
                currentProvider = .codex
            }
            return
        }

        providerSwitchTimer = Timer.scheduledTimer(withTimeInterval: viewModel.animationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.beginTransition()
            }
        }
    }

    private func stopProviderAnimation() {
        providerSwitchTimer?.invalidate()
        providerSwitchTimer = nil
        transitionTimer?.invalidate()
        transitionTimer = nil
        isTransitioning = false
        transitionProgress = 0
    }

    private func restartProviderAnimation() {
        stopProviderAnimation()
        if viewModel.hasCredentials {
            startProviderAnimation()
            updateStatusImage()
        }
    }

    private func beginTransition() {
        guard !isTransitioning else { return }
        guard viewModel.shouldAnimateProviders else { return }

        isTransitioning = true
        transitionProgress = 0

        let totalFrames: CGFloat = 20
        let frameDuration: TimeInterval = 1.0 / 60.0

        transitionTimer = Timer.scheduledTimer(withTimeInterval: frameDuration, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else { timer.invalidate(); return }

                self.transitionProgress += 1.0 / totalFrames

                if self.transitionProgress >= 1.0 {
                    self.transitionProgress = 1.0
                    timer.invalidate()
                    self.transitionTimer = nil
                    self.isTransitioning = false
                    self.currentProvider = (self.currentProvider == .claude) ? .codex : .claude
                    self.updateStatusImage()
                } else {
                    self.renderTransitionFrame()
                }
            }
        }
    }

    private func renderTransitionFrame() {
        guard let button = statusItem.button else { return }

        let fromProvider = currentProvider
        let toProvider: DisplayProvider = (currentProvider == .claude) ? .codex : .claude

        let (fromImage, fromWidth) = createProviderImage(for: fromProvider)
        let (toImage, toWidth) = createProviderImage(for: toProvider)

        let maxWidth = max(fromWidth, toWidth)
        let height: CGFloat = viewModel.showIcon ? 22 : 16

        let progress = transitionProgress

        let image = NSImage(size: NSSize(width: maxWidth, height: height))
        image.lockFocus()

        // Smooth easing function (ease in-out)
        let eased = progress < 0.5
            ? 2 * progress * progress
            : 1 - pow(-2 * progress + 2, 2) / 2

        if eased < 0.5 {
            // Phase 1: Current slides out to the left and fades
            let phaseProgress = eased / 0.5
            let xOffset = -(phaseProgress * maxWidth * 0.6)
            let alpha = 1.0 - phaseProgress

            fromImage.draw(
                in: NSRect(x: xOffset, y: 0, width: fromWidth, height: height),
                from: NSRect(origin: .zero, size: fromImage.size),
                operation: .sourceOver,
                fraction: alpha
            )
        } else {
            // Phase 2: New slides in from the left and fades in
            let phaseProgress = (eased - 0.5) / 0.5
            let xOffset = -(1.0 - phaseProgress) * maxWidth * 0.6
            let alpha = phaseProgress

            toImage.draw(
                in: NSRect(x: xOffset, y: 0, width: toWidth, height: height),
                from: NSRect(origin: .zero, size: toImage.size),
                operation: .sourceOver,
                fraction: alpha
            )
        }

        image.unlockFocus()
        image.isTemplate = false

        if lastStatusLength != maxWidth {
            lastStatusLength = maxWidth
            statusItem.length = maxWidth
        }
        button.image = image
    }

    // MARK: - Status Bar Image

    private func updateStatusImage() {
        guard !isTransitioning else { return }
        guard let button = statusItem.button else { return }

        let (image, width) = createProviderImage(for: currentProvider)

        if lastStatusLength != width {
            lastStatusLength = width
            statusItem.length = width
        }

        button.image = image
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

        var width: CGFloat = 80
        if showOnly5hr || showOnlyWeekly { width = 50 }

        let height: CGFloat = showIcon ? 22 : 16

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()

        let isDarkMode = getDarkMode()
        let anthropicOrange = NSColor(red: 0.83, green: 0.53, blue: 0.30, alpha: 1.0)
        let textColor = isDarkMode ? NSColor.white : NSColor(white: 0.25, alpha: 1.0)

        var yOffset: CGFloat = 0

        if showIcon {
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
            yOffset = 0
        } else {
            yOffset = 3
        }

        let fiveHour = viewModel.usageData.fiveHourUsed
        let weekly = viewModel.usageData.weeklyUsed

        let fiveHourColor: NSColor = (fiveHour == 0 || fiveHour >= 90) ? anthropicOrange : textColor
        let weeklyColor: NSColor = (weekly == 0 || weekly >= 80) ? anthropicOrange : textColor

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

        image.unlockFocus()
        image.isTemplate = false
        return (image, width)
    }

    // MARK: - Codex Image

    private func createCodexImage() -> (NSImage, CGFloat) {
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
        let codexBrandColor = isDarkMode ? NSColor.white : NSColor(white: 0.1, alpha: 1.0)

        var yOffset: CGFloat = 0

        if showIcon {
            // "CODEX" in heavy font — no icon
            let codexLabelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 7.5, weight: .heavy),
                .foregroundColor: codexBrandColor
            ]
            let codexLabel = NSAttributedString(string: "Codex", attributes: codexLabelAttributes)
            let labelX = (width - codexLabel.size().width) / 2
            codexLabel.draw(at: NSPoint(x: labelX, y: 12))
            yOffset = 0
        } else {
            yOffset = 3
        }

        let codex = viewModel.codexUsageData
        let primary = codex.primaryUsedPercent
        let secondary = codex.secondaryUsedPercent

        let openaiGreen = NSColor(red: 0.063, green: 0.639, blue: 0.498, alpha: 1.0) // #10a37f
        let primaryColor: NSColor = (primary == 0 || primary >= 90) ? openaiGreen : textColor
        let secondaryColor: NSColor = (secondary == 0 || secondary >= 80) ? openaiGreen : textColor

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

        image.unlockFocus()
        image.isTemplate = false
        return (image, width)
    }

    // MARK: - Helpers

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
    @State private var showBrowserAuth = false
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
                        Text("Claude CLI detected")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                if CodexAPIService.shared.hasCredentials {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("Codex CLI detected")
                            .font(.caption)
                        Spacer()
                    }
                    .padding(.horizontal)
                }
            }

            if ClaudeOAuthService.shared.hasCredentials || CodexAPIService.shared.hasCredentials {
                Button(action: {
                    // Use auto-detected credentials — trigger refresh
                    // Pass empty strings to signal OAuth mode
                    if ClaudeOAuthService.shared.hasCredentials {
                        // OAuth doesn't need session key / org ID
                        // Just dismiss and let the app refresh
                        onSave("__oauth__", "__oauth__")
                    }
                }) {
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text("Use Detected Credentials")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)

                Divider()
                    .padding(.vertical, 4)
            }

            if !showManualEntry {
                Spacer()
                VStack(spacing: 16) {
                    Text("Sign in to Claude")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Button(action: { showBrowserAuth = true }) {
                        HStack {
                            Image(systemName: "globe")
                            Text("Sign in with Browser")
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(anthropicOrange)

                    Text("Recommended - auto-extracts credentials")
                        .font(.caption2)
                        .foregroundColor(.secondary)

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
        .sheet(isPresented: $showBrowserAuth) {
            AuthWindowView { sk, org in
                onSave(sk, org)
            }
        }
    }
}
