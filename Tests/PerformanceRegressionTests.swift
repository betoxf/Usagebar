import Foundation

@main
struct PerformanceRegressionTests {
    @MainActor static func main() async throws {
        TerminalStandIn.runIfRequested()
        guard Bundle.main.bundleIdentifier == "dev.usagebar.performance-tests" else {
            fatalError("Tests require their isolated preferences domain")
        }
        // A run that trapped leaves its preferences behind.
        UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests")
        defer { UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests") }
        testRefreshPolicy()
        testRetryAfter()
        testTimerLifetime()
        try await testViewModel()
        testTerminalCommands()
        try await testTerminalSessionScan()
        await testProviderHTTP()
        print("PASS: refresh policy, retry headers, timer lifetime, refresh orchestration, terminal sessions, and request sessions")
    }

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func testRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        check(UsageRefreshPolicy.interval(base: 120, lowPower: false) == 120, "Normal cadence changed")
        check(UsageRefreshPolicy.interval(base: 120, lowPower: true) == 300, "Low Power Mode must reduce polls")
        check(UsageRefreshPolicy.interval(base: 600, lowPower: true) == 600, "Respect slower user cadence")
        check(UsageRefreshPolicy.interval(base: 120, visible: true) == 120, "Visible reading slowed down")
        check(UsageRefreshPolicy.interval(base: 120, visible: false) == 600, "Hidden reading kept the visible cadence")
        check(UsageRefreshPolicy.targets(available: [.claude, .codex], enabled: [.codex], fallback: .claude) == [.codex], "Hidden provider selected")
        check(UsageRefreshPolicy.targets(available: [.claude, .codex], enabled: [], fallback: .codex) == [.codex], "Lost displayed fallback")
        check(UsageRefreshPolicy.targets(available: [.codex], enabled: [], fallback: .claude) == [.codex], "No available fallback")
        check(UsageRefreshPolicy.targets(available: [], enabled: [.claude], fallback: .claude).isEmpty, "Invented credentials")
        var state = ProviderRefreshState()
        check(state.isDue(at: now, interval: 120, manual: false), "Initial data must fetch")
        state.lastAttempt = now
        state.succeeded(at: now)
        check(!state.isDue(at: now.addingTimeInterval(119), interval: 120, manual: false), "Refetched fresh usage")
        check(state.isDue(at: now.addingTimeInterval(120), interval: 120, manual: false), "Missed stale usage")
        let hidden = UsageRefreshPolicy.interval(base: 120, visible: false)
        check(!state.isDue(at: now.addingTimeInterval(130), interval: hidden, manual: false), "Hidden reading kept the visible cadence")
        check(state.isDue(at: now.addingTimeInterval(130), interval: 120, manual: false), "Reading stayed stale once shown")
        state.failed(at: now, interval: 120, serverRetryAt: nil)
        check(state.retryAt == now.addingTimeInterval(120), "First retry delay")
        state.failed(at: now, interval: 120, serverRetryAt: nil)
        check(state.retryAt == now.addingTimeInterval(240), "Repeated failure did not back off")
        check(state.isDue(at: now, interval: 120, manual: true), "Manual refresh cannot bypass local delay")
        state.failed(at: now, interval: 120, serverRetryAt: now.addingTimeInterval(3600))
        check(!state.isDue(at: now.addingTimeInterval(3599), interval: 120, manual: true), "Manual refresh ignored server cooldown")
        check(state.isDue(at: now.addingTimeInterval(3600), interval: 120, manual: true), "Server cooldown never expires")
        for _ in 0..<20 { state.failed(at: now, interval: 120, serverRetryAt: nil) }
        check(state.retryAt == now.addingTimeInterval(1800), "Unbounded local backoff")
        state.succeeded(at: now)
        check(state.retryAt == nil && state.consecutiveFailures == 0, "Success did not clear failures")
    }

    static func testRetryAfter() {
        let now = Date(timeIntervalSince1970: 0)
        func response(_ value: String) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://example.invalid")!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": value])!
        }
        check(HTTPRetryAfter.date(from: response("300"), now: now) == now.addingTimeInterval(300), "Numeric Retry-After")
        check(HTTPRetryAfter.date(from: response("Thu, 01 Jan 1970 00:05:00 GMT"), now: now) == now.addingTimeInterval(300), "Date Retry-After")
        check(HTTPRetryAfter.date(from: response("Thu, 01 Jan 1970 00:00:00 GMT"), now: now.addingTimeInterval(60)) == now.addingTimeInterval(60), "Past retry date")
        for value in ["garbage", "-1", "nan", "inf"] {
            check(HTTPRetryAfter.date(from: response(value), now: now) == nil, "Invalid retry value accepted: \(value)")
        }
        check(ISO8601Timestamp.date(from: "1970-01-01T00:05:00Z") == now.addingTimeInterval(300), "Plain timestamp")
        check(ISO8601Timestamp.date(from: "1970-01-01T00:05:00.500Z") == now.addingTimeInterval(300.5), "Fractional timestamp")
        check(ISO8601Timestamp.date(from: "soon") == nil, "Invalid timestamp accepted")
    }

    @MainActor static func testTimerLifetime() {
        var firstCount = 0
        var replacementCount = 0
        var owner: RepeatingTimer? = RepeatingTimer()
        owner?.start(every: 0.01) { firstCount += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(firstCount > 0, "Timer did not fire")
        let previous = firstCount
        owner?.start(every: 0.01) { replacementCount += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(firstCount == previous && replacementCount > 0, "Replacing timer left the old one alive")
        weak var weakOwner: RepeatingTimer?
        weakOwner = owner
        owner = nil
        let countAtClose = replacementCount
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        check(weakOwner == nil && replacementCount == countAtClose, "Orphan timer fired after owner deallocation")
    }

    @MainActor static func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for refresh state")
    }

    @MainActor static func testViewModel() async throws {
        await FakeProviders.reset()
        let model = UsageViewModel(startAutomatically: false)
        defer { model.stopAutoRefresh() }
        model.showClaude = true
        model.showCodex = true
        model.showCursor = false
        model.showKimi = false
        model.showZai = false
        model.showXai = false
        await model.refresh()
        var counts = await FakeProviders.counts
        check(counts[.claude] == 1 && counts[.codex] == 1 && counts[.kimi] == nil, "Hidden provider fetched")
        check(model.hasKimiCredentials, "Hidden provider cannot be rediscovered")
        let probes = await FakeProviders.probes
        for _ in 0..<100 {
            _ = model.hasCredentials
            _ = model.hasClaudeCredentials
            _ = model.hasCodexCredentials
            _ = model.hasKimiCredentials
        }
        let probesAfterDrawing = await FakeProviders.probes
        check(probesAfterDrawing == probes, "UI availability checks performed credential I/O")
        let peak = await FakeProviders.peakConcurrent
        check(peak >= 2, "Provider fetches no longer run concurrently")
        model.showKimi = true
        model.providerSettingsChanged()
        try await eventually { await FakeProviders.counts[.kimi] == 1 && !model.isLoading }
        counts = await FakeProviders.counts
        check(counts[.claude] == 1 && counts[.codex] == 1, "Enabling one provider refetched every provider")
        let probesAfterEnabling = await FakeProviders.probes
        check(probesAfterEnabling == probes, "A routine refresh repeated the sign-in check")
        let successBeforeFailure = model.refreshStates[.claude]?.lastSuccess
        await FakeProviders.setError(.rateLimited(retryAfter: Date().addingTimeInterval(300)), for: .claude)
        await model.refresh()
        counts = await FakeProviders.counts
        let countAtLimit = counts[.claude]
        check(model.claudeError != nil, "Rate limit was hidden")
        check(model.refreshStates[.claude]?.lastSuccess == successBeforeFailure, "Failure marked old data fresh")
        await model.refresh()
        counts = await FakeProviders.counts
        check(counts[.claude] == countAtLimit, "Manual refresh ignored Retry-After")
        model.powerModeChanged(lowPower: true)
        check(model.effectiveRefreshInterval == 300, "Low Power Mode not applied")
        model.powerModeChanged(lowPower: false)
        check(model.effectiveRefreshInterval == 120, "Normal cadence not restored")
        await FakeProviders.setDelay(1_000_000_000)
        let outstanding = Task { await model.refresh() }
        try await eventually { await FakeProviders.concurrent > 0 }
        let previousCodexValue = model.codexUsageData.testValue
        model.setDisplayAsleep(true)
        await outstanding.value
        check(model.codexError == nil, "Cancellation appeared as a provider failure")
        check(model.codexUsageData.testValue == previousCodexValue, "Cancelled response replaced usage")
        check(model.refreshStates[.codex]?.lastAttempt == nil, "Cancelled request suppressed wake refresh")
        model.setSystemAsleep(true)
        model.setDisplayAsleep(false)
        check(model.isBackgroundSuspended, "Display notification resumed work before system wake")
        await FakeProviders.setDelay(5_000_000)
        model.setSystemAsleep(false)
        try await eventually { !model.isLoading && model.codexUsageData.testValue > previousCodexValue }
        let overlaps = await FakeProviders.overlappingProviderRequests
        check(overlaps == 0, "A provider had overlapping requests")
        model.rotationChanged(isRotating: true)
        check(model.refreshInterval(for: .codex) == 120, "Rotating providers must all stay fresh")
        model.rotationChanged(isRotating: false)
        model.displayedProviderChanged(.claude)
        check(model.refreshInterval(for: .claude) == 120, "Displayed provider slowed down")
        check(model.refreshInterval(for: .codex) == 600, "Hidden provider kept the visible cadence")
        counts = await FakeProviders.counts
        let countsBeforeSwitch = counts
        model.displayedProviderChanged(.codex)
        check(model.refreshInterval(for: .codex) == 120, "Newly displayed provider kept the hidden cadence")
        model.menuVisibilityChanged(isOpen: true)
        check(model.refreshInterval(for: .claude) == 120, "Open menu showed a hidden cadence")
        model.menuVisibilityChanged(isOpen: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        counts = await FakeProviders.counts
        check(counts == countsBeforeSwitch, "Showing fresh readings refetched them")
        model.displayedProviderChanged(.claude)
        model.showClaude = false
        model.showCodex = false
        model.showKimi = false
        check(model.refreshTargets == [.claude], "All-hidden fallback disappeared")
    }

    static func testTerminalCommands() {
        let zai = "https://api.z.ai/api/anthropic"
        let cases: [(executable: String, arguments: [String], baseURL: String?, expected: DisplayProvider?)] = [
            ("/Users/a/.local/share/claude/versions/2.1.286", ["claude"], nil, .claude),
            ("/Users/a/.local/share/claude/versions/2.1.286", ["claude"], "https://api.anthropic.com", .claude),
            ("/Users/a/.cc-mirror/zai/native/claude", ["/Users/a/.cc-mirror/zai/native/claude"], zai, .zai),
            ("/opt/homebrew/bin/node", ["node", "/opt/homebrew/bin/claude"], "https://api.kimi.com/coding/", .kimi),
            ("/Users/a/.local/bin/claude", ["claude"], "https://openrouter.ai/api", nil),
            ("/Users/a/.local/bin/claude", ["claude"], "https://api.notz.ai/anthropic", nil),
            ("/opt/homebrew/bin/node", ["node", "/Users/a/.local/bin/codex"], zai, .codex),
            ("/Users/a/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/bin/codex", ["codex"], nil, .codex),
            ("/Users/a/.local/share/cursor-agent/versions/2026.09.18/node",
             ["/Users/a/.local/bin/agent", "--use-system-ca", "/Users/a/.local/share/cursor-agent/versions/2026.09.18/index.js"],
             nil, .cursor),
            ("/Users/a/.kimi-code/bin/kimi", ["kimi"], nil, .kimi),
            ("/usr/bin/python3", ["python3.13", "/Users/a/.local/bin/kimi-cli"], nil, .kimi),
            ("/Users/a/.grok/bin/grok", ["grok"], nil, .xai),
            ("/bin/zsh", ["-zsh"], zai, nil),
            ("/usr/bin/vim", ["vim", "codex"], nil, nil),
            ("/opt/homebrew/bin/node", ["node", "/Users/a/code/server.js"], nil, nil)
        ]
        for item in cases {
            let provider = TerminalAgentDetector.provider(
                executable: item.executable, arguments: item.arguments, baseURL: item.baseURL
            )
            check(provider == item.expected, "Misread terminal command: \(item.arguments.joined(separator: " "))")
        }
    }

    /// Runs a stand-in CLI on a real pseudo-terminal, then reads it back from the process table.
    static func testTerminalSessionScan() async throws {
        let app = getpid()
        check(TerminalAgentDetector.isApplication(app) && !TerminalAgentDetector.isApplication(1),
              "Cannot tell an application from a system process")
        check(!TerminalAgentDetector.scan(app: app, isTerminal: false).hostsTerminals,
              "Found a terminal session before one started")

        guard let cli = TerminalStandIn(named: "claude", environment: ["ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic"])
        else { fatalError("No pseudo-terminal available") }
        defer { cli.stop() }

        var scan = TerminalAgentDetector.scan(app: app, isTerminal: false)
        for _ in 0..<200 where scan.provider != .zai {
            cli.type()
            try await Task.sleep(nanoseconds: 10_000_000)
            scan = TerminalAgentDetector.scan(app: app, isTerminal: false)
        }
        check(scan.provider == .zai && scan.hostsTerminals, "Missed the CLI running in this app's terminal session")
        // To any other terminal, the session belongs to this test application.
        cli.type()
        try await Task.sleep(nanoseconds: 10_000_000)
        let foreign = TerminalAgentDetector.scan(app: 1, isTerminal: true)
        check(foreign.provider != .zai && foreign.hostsTerminals, "Claimed another application's terminal session")
    }

    /// Overlapping and repeated requests must never reach a session that was already closed.
    static func testProviderHTTP() async {
        // Nothing listens on this port, so every request fails without leaving the Mac.
        let request = URLRequest(url: URL(string: "https://127.0.0.1:9/")!)
        for _ in 0..<2 {
            await withTaskGroup(of: Bool.self) { group in
                for _ in 0..<4 {
                    group.addTask { (try? await ProviderHTTP.data(for: request, timeout: 2)) == nil }
                }
                for await failed in group {
                    check(failed, "Reached a server that should not exist")
                }
            }
        }
    }
}
