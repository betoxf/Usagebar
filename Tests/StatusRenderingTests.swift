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
        viewModel.showXai = false
        viewModel.showIcon = true
        viewModel.showOnly5hr = false
        viewModel.showOnlyWeekly = false
        viewModel.usageData = UsageData(fiveHourUsed: 23, weeklyUsed: 67)
        viewModel.codexUsageData = CodexUsageData(primaryUsedPercent: 34, secondaryUsedPercent: 72)

        for providers: Set<DisplayProvider> in [[], [.claude], [.codex], [.claude, .codex]] {
            viewModel.useRenderingFixtures(providers)
            menuWillOpen(menu)
            if providers.isEmpty {
                precondition(menu.items.contains { $0.title == "Setup Usage Tracking" })
            } else {
                precondition(menu.items.contains { $0.title == "Refresh" })
                let updates = menu.items.first { $0.title == "Last Updates" }?.submenu
                precondition(updates?.numberOfItems == providers.count)
            }
            menuDidClose(menu)
            let firstItem = menu.items.first
            rebuildMenu()
            precondition(menu.items.first === firstItem, "Closed menu rebuilt")
        }

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
            viewModel.usageData.fiveHourUsed += 1
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
        print("PASS: setup/Claude/Codex menus, closed-menu reuse, status image caching, light/dark rendering, focus following")
    }
}
