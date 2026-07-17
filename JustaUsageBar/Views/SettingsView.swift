//
//  SettingsView.swift
//  JustaUsageBar
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: UsageViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var sessionKey: String = ""
    @State private var organizationId: String = ""
    @State private var showingAuthWindow = false
    @State private var showManualEntry = false

    private let anthropicOrange = Color(red: 0.83, green: 0.53, blue: 0.30)

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack(spacing: 2) {
                Text("✳︎")
                    .foregroundColor(anthropicOrange)
                Text("Claude")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button(action: { dismiss() }) {
                    Text("×")
                        .font(.system(size: 14, weight: .light))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if viewModel.hasClaudeCredentials {
                // Connected state - minimal
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text("Connected")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Sign out") {
                        viewModel.clearClaudeCredentials()
                    }
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)
                }
            } else {
                // Sign in
                VStack(spacing: 10) {
                    Button(action: { showingAuthWindow = true }) {
                        HStack(spacing: 4) {
                            Text("✳︎")
                            Text("Sign in")
                        }
                        .font(.system(size: 11))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(anthropicOrange)

                    Button(showManualEntry ? "hide" : "manual") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showManualEntry.toggle()
                        }
                    }
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .buttonStyle(.plain)

                    if showManualEntry {
                        VStack(spacing: 8) {
                            SecureField("session key", text: $sessionKey)
                                .textFieldStyle(.plain)
                                .font(.system(size: 9))
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                            TextField("org id", text: $organizationId)
                                .textFieldStyle(.plain)
                                .font(.system(size: 9))
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))

                            Button("save") {
                                viewModel.saveCredentials(sessionKey: sessionKey, organizationId: organizationId)
                                dismiss()
                            }
                            .font(.system(size: 9))
                            .foregroundColor(anthropicOrange)
                            .buttonStyle(.plain)
                            .disabled(sessionKey.isEmpty || organizationId.isEmpty)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 160)
        .onAppear {
            sessionKey = CredentialStorage.shared.sessionKey ?? ""
            organizationId = CredentialStorage.shared.organizationId ?? ""
        }
        .sheet(isPresented: $showingAuthWindow) {
            AuthWindowView { sk, org in
                viewModel.saveCredentials(sessionKey: sk, organizationId: org)
            }
        }
    }
}

#Preview {
    SettingsView(viewModel: UsageViewModel.shared)
}
