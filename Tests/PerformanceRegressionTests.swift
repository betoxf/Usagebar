import Foundation

@main
struct PerformanceRegressionTests {
    @MainActor static func main() async throws {
        guard Bundle.main.bundleIdentifier == "dev.usagebar.performance-tests" else {
            fatalError("Tests require their isolated preferences domain")
        }
        defer { UserDefaults.standard.removePersistentDomain(forName: "dev.usagebar.performance-tests") }
        testRefreshPolicy()
        testRetryAfter()
        testTimerLifetime()
        try await testViewModel()
        print("PASS: refresh policy, retry headers, timer lifetime, and refresh orchestration")
    }

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func testRefreshPolicy() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        check(UsageRefreshPolicy.interval(base: 120, lowPower: false) == 120, "Normal cadence changed")
        check(UsageRefreshPolicy.interval(base: 120, lowPower: true) == 300, "Low Power Mode must reduce polls")
        check(UsageRefreshPolicy.interval(base: 600, lowPower: true) == 600, "Respect slower user cadence")
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
        model.showClaude = false
        model.showCodex = false
        model.showKimi = false
        check(model.refreshTargets == [.claude], "All-hidden fallback disappeared")
    }
}
