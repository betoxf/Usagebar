import Foundation

nonisolated struct ProviderRefreshState {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var consecutiveFailures = 0
    var retryAt: Date?
    var serverRetryAt: Date?

    func nextRefresh(interval: TimeInterval) -> Date {
        max(lastAttempt?.addingTimeInterval(interval) ?? .distantPast, retryAt ?? .distantPast)
    }

    func isDue(at now: Date, interval: TimeInterval, manual: Bool) -> Bool {
        if let serverRetryAt, serverRetryAt > now { return false }
        return manual || nextRefresh(interval: interval) <= now
    }

    mutating func succeeded(at now: Date) {
        lastSuccess = now
        consecutiveFailures = 0
        retryAt = nil
        serverRetryAt = nil
    }

    mutating func failed(at now: Date, interval: TimeInterval, serverRetryAt: Date?) {
        consecutiveFailures = min(consecutiveFailures + 1, 10)
        let delay = min(1800, interval * pow(2, Double(consecutiveFailures - 1)))
        self.serverRetryAt = serverRetryAt
        retryAt = max(now.addingTimeInterval(delay), serverRetryAt ?? .distantPast)
    }
}

nonisolated enum UsageRefreshPolicy {
    static func interval(base: TimeInterval, lowPower: Bool) -> TimeInterval {
        let normal = max(30, min(600, base))
        return lowPower ? max(300, normal) : normal
    }

    static func targets(
        available: Set<DisplayProvider>, enabled: Set<DisplayProvider>, fallback: DisplayProvider
    ) -> Set<DisplayProvider> {
        let shown = available.intersection(enabled)
        if !shown.isEmpty { return shown }
        // Keep the displayed fallback fresh even with externally edited preferences.
        if available.contains(fallback) { return [fallback] }
        return DisplayProvider.displayOrder.first(where: available.contains).map { [$0] } ?? []
    }
}

nonisolated enum HTTPRetryAfter {
    static func date(from response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(min(seconds, Date.distantFuture.timeIntervalSince(now)))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(now, $0) }
    }
}
