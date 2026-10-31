//
//  ProviderSignIn.swift
//  JustaUsageBar
//
//  The easiest way to connect each provider from the setup window. Signing in
//  stays with the provider's own tools and the provider services discover the
//  result as usual, so nothing here reads or holds a credential.
//

import AppKit

nonisolated enum ProviderSignIn: Equatable {
    /// The provider's CLI is on this Mac, so its own login runs in Terminal.
    case terminal(executable: String, arguments: [String])
    /// Claude works without its CLI through a claude.ai sign-in inside Usagebar.
    case claudeWebsite
    /// Kimi Code accepts a pasted API key or web token.
    case kimiKey
    /// z.ai has no sign-in, only an API key saved in its config file.
    case zaiKey
    /// There is nothing to sign in with yet, so the download page comes first.
    case download(title: String, url: URL)

    static func available(for provider: DisplayProvider) -> ProviderSignIn? {
        switch provider {
        case .claude:
            return login("claude", arguments: ["auth", "login"], alsoIn: [".claude/local"])
                ?? .claudeWebsite
        case .codex:
            return login("codex")
                ?? .download(title: "Get Codex", url: URL(string: "https://developers.openai.com/codex/cli")!)
        case .cursor:
            return login("cursor-agent")
                ?? .download(title: "Get Cursor CLI", url: URL(string: "https://cursor.com/cli")!)
        case .kimi:
            return login("kimi", alsoIn: [".kimi-code/bin"]) ?? .kimiKey
        case .zai:
            return .zaiKey
        case .xai:
            return nil
        }
    }

    var buttonTitle: String {
        switch self {
        case .terminal, .claudeWebsite: "Sign In"
        case .kimiKey, .zaiKey: "Add Key"
        case .download(let title, _): title
        }
    }

    /// The login command as a shell would read it.
    var command: String? {
        guard case .terminal(let executable, let arguments) = self else { return nil }
        return ([executable] + arguments).map(Self.shellQuoted).joined(separator: " ")
    }

    /// Opens Terminal on the provider's login. Terminal runs a `.command` file
    /// without Automation access, and the file holds only that command.
    func runInTerminal(signingInTo name: String) -> Bool {
        guard let command else { return false }
        let script = """
        #!/bin/sh
        clear
        echo "Signing in to \(name) for Usagebar."
        echo
        \(command)
        echo
        echo "You can close this window and go back to Usagebar."
        rm -f "$0"

        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Usagebar Sign In.command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(url)
    }

    private static func login(
        _ name: String,
        arguments: [String] = ["login"],
        alsoIn directories: [String] = []
    ) -> ProviderSignIn? {
        locate(name, alsoIn: directories).map { .terminal(executable: $0, arguments: arguments) }
    }

    /// Apps opened from Finder get a bare PATH, so also look where installers put CLIs.
    private static func locate(_ name: String, alsoIn directories: [String]) -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let inHome = (directories + [".local/bin", ".npm-global/bin", ".bun/bin", ".volta/bin", "Library/pnpm"])
            .map { "\(home)/\($0)" }
        let nvm = "\(home)/.nvm/versions/node"
        let nodeVersions = ((try? fileManager.contentsOfDirectory(atPath: nvm)) ?? []).map { "\(nvm)/\($0)/bin" }
        return (path + inHome + ["/opt/homebrew/bin", "/usr/local/bin"] + nodeVersions)
            .map { "\($0)/\(name)" }
            .first { fileManager.isExecutableFile(atPath: $0) }
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
