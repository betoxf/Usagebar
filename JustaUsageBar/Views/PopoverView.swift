//
//  PopoverView.swift
//  JustaUsageBar
//

import SwiftUI

struct PopoverView: View {
    @ObservedObject var viewModel: UsageViewModel

    // Auth form state
    @State private var authStep: Int = 1
    @State private var sessionKey: String = ""
    @State private var organizationId: String = ""

    // Anthropic orange
    private let anthropicOrange = Color(red: 0.83, green: 0.53, blue: 0.30)

    // Display mode label
    private var displayModeLabel: String {
        if viewModel.showOnly5hr { return "5h" }
        if viewModel.showOnlyWeekly { return "W" }
        return "Both"
    }

    private func cycleDisplayMode() {
        if !viewModel.showOnly5hr && !viewModel.showOnlyWeekly {
            viewModel.showOnly5hr = true
            viewModel.showOnlyWeekly = false
        } else if viewModel.showOnly5hr {
            viewModel.showOnly5hr = false
            viewModel.showOnlyWeekly = true
        } else {
            viewModel.showOnly5hr = false
            viewModel.showOnlyWeekly = false
        }
        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
    }

    private func openBrowser() {
        if let url = URL(string: "https://claude.ai/settings/usage") {
            NSWorkspace.shared.open(url)
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !viewModel.hasClaudeCredentials {
                authView
            } else {
                usageView
            }
        }
        .padding(10)
        .frame(minWidth: 170)
    }

    // MARK: - Auth View

    private var authView: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 2) {
                Text("✳︎")
                    .foregroundColor(anthropicOrange)
                Text("Claude")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }

            if authStep == 1 {
                step1View
            } else {
                step2View
            }

            Divider()

            // Disclosure
            Text("Not affiliated with Anthropic. Credentials stored locally (encrypted).")
                .font(.system(size: 6))
                .foregroundColor(.secondary.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(width: 220)
    }

    private var step1View: some View {
        VStack(spacing: 10) {
            Text("1. Sign in to Claude")
                .font(.system(size: 10, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: openBrowser) {
                Text("Open claude.ai")
                    .font(.system(size: 10))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .tint(anthropicOrange)

            Button(action: { authStep = 2 }) {
                Text("Next →")
                    .font(.system(size: 10))
                    .foregroundColor(anthropicOrange)
            }
            .buttonStyle(.plain)
        }
    }

    private var step2View: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2. Copy your credentials")
                .font(.system(size: 10, weight: .medium))

            VStack(alignment: .leading, spacing: 4) {
                Text("Session Key")
                    .font(.system(size: 8, weight: .medium))
                Text("DevTools → Network → Cookie: sessionKey=...")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
                SecureField("sk-ant-sid01-...", text: $sessionKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9))
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3)))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Organization ID")
                    .font(.system(size: 8, weight: .medium))
                Text("URL: claude.ai/api/organizations/{this-id}/usage")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)
                TextField("uuid from URL", text: $organizationId)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9))
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.3)))
            }

            HStack {
                Button(action: { authStep = 1 }) {
                    Text("← Back")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    viewModel.saveCredentials(sessionKey: sessionKey, organizationId: organizationId)
                }) {
                    Text("Done")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(sessionKey.isEmpty || organizationId.isEmpty ? .secondary : anthropicOrange)
                }
                .buttonStyle(.plain)
                .disabled(sessionKey.isEmpty || organizationId.isEmpty)
            }
        }
    }

    // MARK: - Usage View

    private var usageView: some View {
        VStack(spacing: 8) {
            // 5-Hour
            UsageRowMinimal(
                title: "5h",
                percentage: viewModel.usageData.fiveHourPercentage,
                resetTime: viewModel.usageData.timeUntilFiveHourReset,
                color: anthropicOrange
            )

            // Weekly
            UsageRowMinimal(
                title: "7d",
                percentage: viewModel.usageData.weeklyPercentage,
                resetTime: viewModel.usageData.timeUntilWeeklyReset,
                color: anthropicOrange
            )

            Divider()
                .padding(.vertical, 2)

            // Controls row
            HStack(spacing: 6) {
                // Settings button
                Button(action: {
                    viewModel.clearClaudeCredentials()
                }) {
                    Text("✳︎")
                        .font(.system(size: 8))
                        .foregroundColor(anthropicOrange)
                        .frame(width: 14, height: 14)
                        .background(Circle().stroke(anthropicOrange, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Startup toggle
                Toggle("", isOn: $viewModel.launchAtStartup)
                    .labelsHidden()
                    .scaleEffect(0.6)
                    .tint(anthropicOrange)
                Text("Start")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)

                // Icon toggle
                Toggle("", isOn: Binding(
                    get: { viewModel.showIcon },
                    set: {
                        viewModel.showIcon = $0
                        NotificationCenter.default.post(name: NSNotification.Name("SettingsChanged"), object: nil)
                    }
                ))
                    .labelsHidden()
                    .scaleEffect(0.6)
                    .tint(anthropicOrange)
                Text("Icon")
                    .font(.system(size: 7))
                    .foregroundColor(.secondary)

                // Display mode
                Button(action: cycleDisplayMode) {
                    Text(displayModeLabel)
                        .font(.system(size: 7, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(anthropicOrange))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Usage Row

struct UsageRowMinimal: View {
    let title: String
    let percentage: Double
    let resetTime: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(percentage))%")
                    .font(.system(size: 10, weight: .semibold))
            }

            // Progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: geometry.size.width * min(percentage / 100, 1.0), height: 4)
                }
            }
            .frame(height: 4)

            Text(resetTime)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    PopoverView(viewModel: UsageViewModel.shared)
}
