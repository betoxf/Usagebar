import Foundation

// Deterministic providers for testing the production refresh controller.
// This executable never reads real credentials or sends network requests.
@ProviderActor enum FakeProviders {
    static var available: Set<DisplayProvider> = [.claude, .codex, .kimi]
    static var counts: [DisplayProvider: Int] = [:]
    static var probes = 0
    static var concurrent = 0
    static var peakConcurrent = 0
    static var overlappingProviderRequests = 0
    static var inFlight: Set<DisplayProvider> = []
    static var failures: [DisplayProvider: APIError] = [:]
    static var delay: UInt64 = 5_000_000

    static func reset() {
        counts = [:]; probes = 0; concurrent = 0; peakConcurrent = 0
        overlappingProviderRequests = 0; inFlight = []; failures = [:]
    }
    static func probe(_ provider: DisplayProvider) -> Bool {
        probes += 1
        return available.contains(provider)
    }
    static func setDelay(_ value: UInt64) { delay = value }
    static func setError(_ value: APIError, for provider: DisplayProvider) { failures[provider] = value }
    static func fetch(_ provider: DisplayProvider) async throws -> Int {
        counts[provider, default: 0] += 1
        let result = counts[provider]!
        if !inFlight.insert(provider).inserted { overlappingProviderRequests += 1 }
        concurrent += 1
        peakConcurrent = max(peakConcurrent, concurrent)
        defer { concurrent -= 1; inFlight.remove(provider) }
        // Deliberately return even after cancellation to test the controller's guard.
        try? await Task.sleep(nanoseconds: delay)
        if let error = failures[provider] { throw error }
        return result
    }
}

nonisolated enum ClaudeAuthSource { case none, oauth, webSession }
nonisolated enum KimiAuthSource { case none, cli }
nonisolated enum APIError: Error {
    case unauthorized
    case rateLimited(retryAfter: Date?)
    var retryAfter: Date? { if case .rateLimited(let date) = self { return date }; return nil }
    var errorDescription: String? { "Test provider error" }
}
nonisolated enum KimiServiceError: Error {
    case unavailable
    var retryAfter: Date? { nil }
    var errorDescription: String? { "Test provider error" }
}
nonisolated func isRequestCancelled(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

@ProviderActor final class ClaudeOAuthService {
    static let shared = ClaudeOAuthService()
    var hasCredentials: Bool { FakeProviders.probe(.claude) }
    func clearCache() {}
    func clearPersistedCredentials() {}
}
@ProviderActor final class CredentialStorage {
    static let shared = CredentialStorage()
    var hasCredentials: Bool { false }
    func setWebSession(sessionKey: String, organizationId: String) {}
    func setKimiCredential(_ value: String) {}
    func clearClaudeCredentials() {}
    func clearKimiCredential() {}
}

@ProviderActor final class ClaudeAPIService {
    static let shared = ClaudeAPIService()
    var hasCredentials: Bool { FakeProviders.probe(.claude) }
    func clearCache() {}
    var lastAuthSource: ClaudeAuthSource { .oauth }
    func fetchUsage() async throws -> UsageData {
        let value = try await FakeProviders.fetch(.claude)
        return UsageData(fiveHourUsed: value)
    }
}

nonisolated struct CodexUsageData { var testValue = 0; static let placeholder = CodexUsageData() }

@ProviderActor final class CodexAPIService {
    static let shared = CodexAPIService()
    var hasCredentials: Bool { FakeProviders.probe(.codex) }
    func clearCache() {}
    func fetchUsage() async throws -> CodexUsageData {
        let value = try await FakeProviders.fetch(.codex)
        return CodexUsageData(testValue: value)
    }
}

nonisolated struct CursorUsageData { var testValue = 0; static let placeholder = CursorUsageData() }

@ProviderActor final class CursorAPIService {
    static let shared = CursorAPIService()
    var hasCredentials: Bool { FakeProviders.probe(.cursor) }
    func clearCache() {}
    func fetchUsage() async throws -> CursorUsageData {
        let value = try await FakeProviders.fetch(.cursor)
        return CursorUsageData(testValue: value)
    }
}

nonisolated struct ZaiUsageData { var testValue = 0; static let placeholder = ZaiUsageData() }

@ProviderActor final class ZaiAPIService {
    static let shared = ZaiAPIService()
    var hasCredentials: Bool { FakeProviders.probe(.zai) }
    func clearCache() {}
    func fetchUsage() async throws -> ZaiUsageData {
        let value = try await FakeProviders.fetch(.zai)
        return ZaiUsageData(testValue: value)
    }
}

nonisolated struct XaiUsageData { var testValue = 0; static let placeholder = XaiUsageData() }

@ProviderActor final class XaiAPIService {
    static let shared = XaiAPIService()
    var hasCredentials: Bool { FakeProviders.probe(.xai) }
    func clearCache() {}
    func fetchUsage() async throws -> XaiUsageData {
        let value = try await FakeProviders.fetch(.xai)
        return XaiUsageData(testValue: value)
    }
}

nonisolated struct KimiUsageData { var testValue = 0; static let placeholder = KimiUsageData() }

@ProviderActor final class KimiAPIService {
    static let shared = KimiAPIService()
    var hasCredentials: Bool { FakeProviders.probe(.kimi) }
    func clearCache() {}
    var lastAuthSource: KimiAuthSource { .cli }
    var detectedAuthSource: KimiAuthSource { FakeProviders.probe(.kimi) ? .cli : .none }
    var hasSavedCredential: Bool { false }
    func fetchUsage() async throws -> KimiUsageData {
        let value = try await FakeProviders.fetch(.kimi)
        return KimiUsageData(testValue: value)
    }
}
