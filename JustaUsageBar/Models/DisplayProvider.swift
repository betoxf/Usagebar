import Foundation

nonisolated enum DisplayProvider: String, CaseIterable, Sendable {
    case claude
    case codex
    case cursor
    case kimi
    case zai
    case deepseek

    /// Fixed left-to-right order used for cycling and menu layout.
    static let displayOrder: [DisplayProvider] = [.claude, .codex, .cursor, .kimi, .zai, .deepseek]
}
