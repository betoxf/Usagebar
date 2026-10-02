import Foundation

/// Serializes provider and credential storage work away from the UI actor.
/// Awaiting a network response lets other providers use the executor.
@globalActor
actor ProviderActor {
    static let shared = ProviderActor()
}
