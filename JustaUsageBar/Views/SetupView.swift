//
//  SetupView.swift
//  JustaUsageBar
//
//  The window new people land in: every provider on one screen, each with a
//  single button. Rows turn to Connected on their own as sign-ins are discovered.
//

import AppKit
import Combine
import SwiftUI

/// What the setup window shows beyond the view model's provider snapshot.
/// `AppDelegate` keeps it current and handles the actions.
final class SetupModel: ObservableObject {
    /// How long a sign-in is watched closely after its button is clicked.
    nonisolated private static let connectingWindow: TimeInterval = 10 * 60

    @Published var signIns: [DisplayProvider: ProviderSignIn] = [:]
    /// Providers someone just started connecting, and when.
    @Published private(set) var connecting: [DisplayProvider: Date] = [:]
    @Published var isSigningInToClaude = false

    var cursorMarks: NSImage?
    var zcodeMark: NSImage?

    var onConnect: (DisplayProvider) -> Void = { _ in }
    var onClose: () -> Void = {}

    func startConnecting(_ provider: DisplayProvider) {
        connecting[provider] = Date()
    }

    /// Returns the providers that finished connecting since the last update.
    func update(available: Set<DisplayProvider>, now: Date = Date()) -> Set<DisplayProvider> {
        let finished = Set(connecting.keys).intersection(available)
        let waiting = connecting.filter {
            !available.contains($0.key) && now.timeIntervalSince($0.value) < Self.connectingWindow
        }
        if waiting != connecting { connecting = waiting }

        var current: [DisplayProvider: ProviderSignIn] = [:]
        for provider in DisplayProvider.displayOrder where !available.contains(provider) {
            current[provider] = .available(for: provider)
        }
        if current != signIns { signIns = current }
        return finished
    }

    func reset() {
        connecting = [:]
        isSigningInToClaude = false
    }
}

struct SetupView: View {
    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(spacing: 6) {
                ForEach(DisplayProvider.displayOrder, id: \.self) { provider in
                    SetupRow(
                        provider: provider,
                        isConnected: viewModel.availableProviders.contains(provider),
                        isConnecting: model.connecting[provider] != nil,
                        signIn: model.signIns[provider],
                        model: model
                    )
                }
            }
            footer
        }
        .padding(EdgeInsets(top: 4, leading: 20, bottom: 20, trailing: 20))
        .frame(width: 420)
        .font(.system(size: 13))
        .sheet(isPresented: $model.isSigningInToClaude) {
            AuthWindowView { sessionKey, organizationId in
                viewModel.saveCredentials(sessionKey: sessionKey, organizationId: organizationId)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(viewModel.hasCredentials ? "You're all set" : "Welcome to Usagebar")
                .font(.system(size: 18, weight: .semibold))
            Text(viewModel.hasCredentials
                 ? "Your usage is in the menu bar. Right-click it for details, or connect more tools here."
                 : "Connect the AI tools you use to see your limits in the menu bar.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Your sign-ins stay on this Mac. Usagebar is not affiliated with these providers.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if viewModel.hasCredentials {
                Button("Done") { model.onClose() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Later") { model.onClose() }
            }
        }
    }
}

private struct SetupRow: View {
    let provider: DisplayProvider
    let isConnected: Bool
    let isConnecting: Bool
    let signIn: ProviderSignIn?
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                ProviderMark(provider: provider, cursorMarks: model.cursorMarks, zcodeMark: model.zcodeMark)
                    .frame(height: 18)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name). \(detail)")
            Spacer(minLength: 8)
            if isConnected {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text("Connected")
                }
            } else if let signIn {
                if isConnecting {
                    ProgressView().controlSize(.small)
                }
                Button(signIn.buttonTitle) { model.onConnect(provider) }
                    .accessibilityLabel("\(signIn.buttonTitle), \(name)")
            }
        }
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }

    private var name: String {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .kimi: "Kimi Code"
        case .zai: "z.ai"
        }
    }

    private var detail: String {
        if !isConnected, isConnecting, let waiting {
            return waiting
        }
        return switch provider {
        case .claude: "Claude Code and claude.ai"
        case .codex: "Codex app and CLI"
        case .cursor: "Cursor and Grok Bot"
        case .kimi: "Kimi Code CLI or API key"
        case .zai: "z.ai coding plan"
        }
    }

    private var waiting: String? {
        switch signIn {
        case .terminal: "Finish signing in, then come back here."
        case .download: "Install it, then come back here."
        case .zaiKey: "Save your key, then come back here."
        default: nil
        }
    }
}
