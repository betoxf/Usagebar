import AppKit

// The runner joins this file with the two controllers so these test extensions can
// inspect private state without adding test-only accessors to the shipped app.
extension UsageViewModel {
    fileprivate func useRenderingFixtures(_ providers: Set<DisplayProvider>) {
        availableProviders = providers
        claudeAuthSource = .oauth
        for provider in providers {
            refreshStates[provider, default: .init()].succeeded(at: Date())
        }
    }
}

extension AppDelegate {
    fileprivate func verifyRendering(output: URL?) throws {
        setupStatusItem()
        setupMenu()
        defer { NSStatusBar.system.removeStatusItem(statusItem) }
        viewModel.stopAutoRefresh()
        viewModel.followActiveApp = false
        viewModel.showClaude = true
        viewModel.showCodex = true
        viewModel.showCursor = false
        viewModel.showKimi = false
        viewModel.showZai = false
        viewModel.showIcon = true
        viewModel.showOnly5hr = false
        viewModel.showOnlyWeekly = false
        viewModel.usageData = UsageData(fiveHourUsed: 23, weeklyUsed: 67)
        viewModel.codexUsageData = CodexUsageData(primaryUsedPercent: 34, secondaryUsedPercent: 72)

        for providers: Set<DisplayProvider> in [[], [.claude], [.codex], [.claude, .codex]] {
            viewModel.useRenderingFixtures(providers)
            menuWillOpen(menu)
            if providers.isEmpty {
                precondition(menu.items.contains { $0.title == "Set Up Usagebar…" })
            } else {
                precondition(menu.items.contains { $0.title == "Refresh" })
                let updates = menu.items.first { $0.title == "Last Updates" }?.submenu
                precondition(updates?.numberOfItems == providers.count)
                precondition(menu.items.contains { $0.title == "Connect More Tools…" })
            }
            menuDidClose(menu)
            let firstItem = menu.items.first
            rebuildMenu()
            precondition(menu.items.first === firstItem, "Closed menu rebuilt")
        }

        viewModel.useRenderingFixtures([])
        showSetupStatus()
        precondition(statusItem.button?.image?.isTemplate == true, "Setup status ignored the menu bar's appearance")
        precondition(ProviderSignIn.terminal(executable: "/a b/it's", arguments: ["login"]).command == "'/a b/it'\\''s' 'login'",
                     "Login command was not quoted for the shell")
        verifySetupModel()
        statusBarButtonClicked()
        precondition(setupWindow?.isVisible == true, "A click with nothing connected did not open setup")
        setupWindow?.close()
        precondition(setupWindow == nil, "Closing setup left it watching for sign-ins")
        if let output {
            try renderSetup(to: output)
        }

        verifyPlanNames()
        verifyCursorOutage()

        viewModel.useRenderingFixtures([.claude, .codex])
        let sheet = NSImage(size: NSSize(width: 560, height: 240))
        for (row, appearance) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            statusItem.button?.appearance = NSAppearance(named: appearance)
            currentProvider = .claude
            updateStatusImage()
            let first = statusItem.button!.image!
            updateStatusImage()
            precondition(statusItem.button?.image === first, "Unchanged status image rebuilt")
            currentProvider = .codex
            updateStatusImage()
            currentProvider = .claude
            updateStatusImage()
            precondition(statusItem.button?.image === first, "Provider cache missed on return")
            viewModel.usageData.fiveHourUsed? += 1
            updateStatusImage()
            precondition(statusItem.button?.image !== first, "Changed usage kept the old image")

            let light = row == 0
            var previews: [NSImage] = []
            for provider in DisplayProvider.displayOrder {
                let (image, width) = createProviderImage(for: provider)
                precondition(width > 0 && image.size.width == width && image.size.height > 0)
                previews.append(image)
            }
            sheet.lockFocus()
            (light ? NSColor.white : NSColor(white: 0.12, alpha: 1)).setFill()
            NSRect(x: 0, y: row * 120, width: 560, height: 120).fill()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: light ? NSColor.black : NSColor.white
            ]
            NSAttributedString(string: light ? "Light appearance" : "Dark appearance", attributes: attrs)
                .draw(at: NSPoint(x: 12, y: row * 120 + 90))
            for (column, image) in previews.enumerated() {
                image.draw(at: NSPoint(x: 12 + column * 90, y: row * 120 + 40), from: .zero, operation: .sourceOver, fraction: 1)
            }
            sheet.unlockFocus()
        }
        currentProvider = .codex
        viewModel.codexUsageData.primaryWindowSeconds = 7 * 24 * 3600
        updateStatusImage()
        precondition(statusItem.button?.image?.size.width == 50, "Weekly Codex window duplicated")

        // A Claude plan without a 5-hour window shows the weekly value alone.
        currentProvider = .claude
        viewModel.showOnly5hr = true
        viewModel.usageData = UsageData(weeklyUsed: 29)
        updateStatusImage()
        precondition(statusItem.button?.image?.size.width == 50, "Claude kept a slot for a 5-hour window it lacks")
        precondition(panelCards().first { $0.provider == .claude }?.rows.map(\.label) == ["7d"],
                     "Claude showed a 5-hour window it lacks")
        viewModel.showOnly5hr = false
        viewModel.usageData.fiveHourUsed = 0
        updateStatusImage()
        precondition(statusItem.button?.image?.size.width == 80, "An unused 5-hour window was hidden")
        precondition(panelCards().first { $0.provider == .claude }?.rows.map(\.label) == ["5h", "7d"],
                     "An unused 5-hour window was hidden")

        // Follow Active App keeps the last AI tool on screen instead of the saved pick.
        viewModel.followActiveApp = true
        viewModel.animationInterval = 0
        preferredProvider = .codex
        setFocus(.claude)
        precondition(currentProvider == .claude, "AI app in front was not shown")
        follow(.current)
        precondition(focusProvider == nil && currentProvider == .claude, "Leaving an AI app changed the provider")

        // A CLI in the frontmost app's terminal is followed, here in this test's own.
        guard let cli = TerminalStandIn(named: "codex") else { preconditionFailure("No pseudo-terminal available") }
        defer { cli.stop() }
        for _ in 0..<200 where TerminalAgentDetector.scan(app: getpid(), isTerminal: false).provider != .codex {
            cli.type()
            usleep(10_000)
        }
        follow(.current)
        for _ in 0..<100 where focusProvider != .codex {
            cli.type()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(focusProvider == .codex && currentProvider == .codex, "Terminal CLI was not followed")
        currentProvider = .claude
        resumeTerminalWatch()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        precondition(currentProvider == .claude, "Resuming the watch overrode a manual pick")
        terminalSessionChanged(to: nil)
        precondition(focusProvider == nil && currentProvider == .claude, "A CLI that ended moved the provider")

        viewModel.followActiveApp = false
        follow(.current)
        precondition(terminalWatch == nil, "Watching continued with Follow Active App off")
        if let output, let tiff = sheet.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: output)
        }
    }

    private func verifyCursorOutage() {
        let now = Date()
        let saved = CursorWeeklyReading(percent: 100, resetAt: now.addingTimeInterval(3600))
        func usage(_ weekly: CursorWeeklyUsage, saved: CursorWeeklyReading?, at time: Date) -> CursorUsageData {
            var usage = CursorUsageData()
            usage.apply(weekly, saved: saved, now: time)
            return usage
        }

        let outage = usage(.unavailable, saved: saved, at: now)
        precondition(outage.usedPercent == 100 && outage.windowLabel == "W" && outage.weeklyIsStale,
                     "An outage replaced the weekly reading with the month's")
        let afterReset = usage(.unavailable, saved: saved, at: now.addingTimeInterval(7200))
        precondition(afterReset.usedPercent == 0 && afterReset.windowLabel == "M" && afterReset.weeklyIsStale,
                     "A weekly reading outlived its reset")
        let monthlyPlan = usage(.unavailable, saved: nil, at: now)
        precondition(monthlyPlan.windowLabel == "M" && !monthlyPlan.weeklyIsStale, "A plan without a weekly allowance was flagged")
        let live = usage(.reading(saved), saved: nil, at: now)
        precondition(live.usedPercent == 100 && live.windowLabel == "W" && !live.weeklyIsStale, "A live weekly reading was missed")
        let noneNow = usage(.noAllowance, saved: saved, at: now)
        precondition(noneNow.windowLabel == "M" && !noneNow.weeklyIsStale, "A plan that lost its allowance kept the old reading")

        viewModel.useRenderingFixtures([.cursor])
        viewModel.showCursor = true
        viewModel.cursorUsageData = outage
        precondition(panelCards().first { $0.provider == .cursor }?.message == "Couldn't refresh weekly usage",
                     "A stale weekly reading looked current")
        viewModel.cursorUsageData = live
        precondition(panelCards().first { $0.provider == .cursor }?.message == nil, "A current reading was flagged")
        viewModel.cursorUsageData = .placeholder
        viewModel.showCursor = false
    }

    private func verifyPlanNames() {
        func plan(_ type: String?, _ tier: String?) -> String? {
            ClaudeOAuthService.OAuthCredentials(accessToken: "", scopes: [], subscriptionType: type, rateLimitTier: tier).planName
        }
        precondition(plan("max", "default_claude_max_20x") == "Ultra", "Claude's 20x tier was not shown as Ultra")
        precondition(plan("max", "default_claude_max_5x") == "Max" && plan("max", nil) == "Max", "Claude's Max plan was misread")
        precondition(plan("ultra", nil) == "Ultra", "A stored Ultra plan was misread")
        precondition(plan("pro", nil) == "Pro" && plan("team", "default_claude_max_5x") == "Team", "Claude's plan was misread")
        precondition(plan(nil, "default_claude_max_5x") == nil, "A tier without a plan was shown")

        precondition(displayPlanName("pro_plus") == "Pro Plus", "A plan id was left unreadable")
        precondition(displayPlanName("GLM Coding Pro") == "GLM Coding Pro", "A readable plan name was changed")
        var codex = CodexUsageData()
        precondition(codex.planName.isEmpty, "An unknown Codex plan was shown")
        codex.planType = "prolite"
        precondition(codex.planName == "Pro Lite", "Codex's plan read as one word")

        viewModel.useRenderingFixtures([.claude])
        viewModel.usageData.planName = "Ultra"
        precondition(panelCards().first { $0.provider == .claude }?.detail == "Ultra", "Claude's card hid its plan")
        viewModel.usageData.planName = nil
        precondition(panelCards().first { $0.provider == .claude }?.detail == "via OAuth", "Claude's card lost its fallback")
    }

    private func verifySetupModel() {
        let model = SetupModel()
        let start = Date()
        _ = model.update(available: [], now: start)
        precondition(model.signIns.count == DisplayProvider.allCases.count, "A provider had no way to connect")
        model.startConnecting(.claude)
        model.startConnecting(.codex)
        precondition(model.update(available: [.claude], now: start) == [.claude], "A finished sign-in was missed")
        precondition(model.connecting.keys.contains(.codex) && model.signIns[.claude] == nil, "Row states drifted")
        precondition(model.update(available: [.claude], now: start.addingTimeInterval(601)).isEmpty, "A timeout counted as a sign-in")
        precondition(model.connecting.isEmpty, "An abandoned sign-in was watched forever")
    }

    /// Saves the setup window beside the status preview, signed out and connected.
    private func renderSetup(to output: URL) throws {
        if let tiff = statusItem.button?.image?.tiffRepresentation {
            try NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])?
                .write(to: output.deletingPathExtension().appendingPathExtension("setup-status.png"))
        }
        loadProviderMarks()
        setupModel.cursorMarks = panelModel.cursorMarks
        setupModel.zcodeMark = panelModel.zcodeMark
        _ = setupModel.update(available: [])
        for (name, providers, appearance) in [
            ("setup-light", Set<DisplayProvider>(), NSAppearance.Name.aqua),
            ("setup-dark", [.claude], .darkAqua)
        ] {
            viewModel.useRenderingFixtures(providers)
            let view = NSHostingView(rootView: SetupView(viewModel: viewModel, model: setupModel)
                .background(Color(nsColor: .windowBackgroundColor)))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let url = output.deletingPathExtension().appendingPathExtension("\(name).png")
            try bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}

@main
struct StatusRenderingTests {
    @MainActor static func main() throws {
        TerminalStandIn.runIfRequested()
        guard Bundle.main.bundleIdentifier == "dev.usagebar.performance-tests" else {
            fatalError("Tests require their isolated preferences domain")
        }
        // A run that trapped leaves its preferences behind.
        UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests")
        defer { UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests") }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let model = UsageViewModel(startAutomatically: false)
        let output = ProcessInfo.processInfo.environment["USAGEBAR_RENDER_OUTPUT"].map { URL(fileURLWithPath: $0) }
        try AppDelegate(viewModel: model).verifyRendering(output: output)
        print("PASS: Cursor outages, plan names, setup status and model, setup/Claude/Codex menus, closed-menu reuse, status image caching, light/dark rendering, Claude without a 5-hour window, focus following")
    }
}
