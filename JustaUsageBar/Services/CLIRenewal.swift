//
//  CLIRenewal.swift
//  JustaUsageBar
//
//  Asks Claude Code or Codex to renew its own expired sign-in. Both CLIs own
//  their tokens and rotate the refresh token each time it is used, so Usagebar
//  never redeems it. Instead it runs the CLI for something that needs a valid
//  token and makes no model call; the CLI renews the token itself before it
//  answers and saves it where it always does, and Usagebar then reads it as
//  usual. Nothing opens a terminal or a window. Refreshes ask on their own
//  once a token has expired (Claude Code's also just before), so nobody has
//  to open the panel for it.
//
//  - Claude Code: `claude -p /usage`, which reads the plan's usage with
//    `refreshOAuth` on, in print mode, so no folder-trust prompt is shown.
//  - Codex: `codex app-server`, Codex's JSON-RPC interface over pipes, asked
//    for the rate limits.
//

import Foundation

@ProviderActor final class CLIRenewal {
    static let claude = CLIRenewal { await CLIRenewal.askClaudeCode() }
    static let codex = CLIRenewal { await CLIRenewal.askCodexAppServer() }

    /// After a renewal, the token lasts hours. After a failure, try again in
    /// 20 seconds when someone is looking; on their own, refreshes back off,
    /// doubling up to half an hour, so a CLI that can't renew isn't run on
    /// every tick.
    static let renewedCooldown: TimeInterval = 300
    static let failedCooldown: TimeInterval = 20
    static let longestFailedCooldown: TimeInterval = 1800

    private var ask: @Sendable () async -> Bool

    /// Replaces the CLI in tests.
    func setAsk(_ ask: @escaping @Sendable () async -> Bool) {
        self.ask = ask
    }

    private var finishedAt = Date.distantPast
    private var failures = 0
    private var running: Task<Bool, Never>?

    private init(ask: @escaping @Sendable () async -> Bool) {
        self.ask = ask
    }

    /// Asks the CLI, then `renewed` rereads its credentials and says whether the
    /// token is fresh now. A CLI's answer alone proves nothing: one that can't
    /// run the command still answers. While another refresh is asking, this
    /// waits for that answer and rereads. Returns false at once while a
    /// cooldown holds; `asked` (someone opened the panel or clicked Refresh)
    /// keeps a failure's cooldown short.
    func renew(now: Date = Date(), asked: Bool = false, renewed: () -> Bool) async -> Bool {
        if let running {
            _ = await running.value
            return renewed()
        }
        guard now >= nextAttempt(asked: asked) else { return false }
        let attempt = Task { [ask] in await ask() }
        running = attempt
        let fresh = await attempt.value && renewed()
        running = nil
        finishedAt = Date()
        failures = fresh ? 0 : failures + 1
        return fresh
    }

    private func nextAttempt(asked: Bool) -> Date {
        guard failures > 0 else {
            return finishedAt == .distantPast ? .distantPast : finishedAt.addingTimeInterval(Self.renewedCooldown)
        }
        let backoff = asked ? Self.failedCooldown
            : min(Self.failedCooldown * pow(2, Double(failures - 1)), Self.longestFailedCooldown)
        return finishedAt.addingTimeInterval(backoff)
    }

    // MARK: - Claude Code

    nonisolated static func askClaudeCode(timeout: TimeInterval = 20) async -> Bool {
        guard let claude = ProviderSignIn.locate("claude", alsoIn: [".claude/local"]) else { return false }
        // An empty folder of Usagebar's own, so no project's settings or
        // instructions load. Claude Code keeps an empty folder for it under
        // ~/.claude/projects, the same as for any folder it runs in.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Usagebar Claude Renewal")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = [
            "-p", "/usage", "--output-format", "json",
            "--no-session-persistence", "--strict-mcp-config", "--allowed-tools", "",
            "--settings", #"{"disableAllHooks":true}"#,
        ]
        guard let output = await run(claude, arguments: arguments, in: folder,
                                     environment: ["DISABLE_AUTOUPDATER": "1"], timeout: timeout),
              let json = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else { return false }
        return json["subtype"] as? String == "success" && json["is_error"] as? Bool == false
    }

    // MARK: - Codex

    nonisolated static func askCodexAppServer(timeout: TimeInterval = 10) async -> Bool {
        guard let codex = ProviderSignIn.locate("codex") else { return false }
        let requests: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["clientInfo": ["name": "usagebar", "version": appVersion]]],
            ["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read"],
        ]
        let input = requests.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        // Responses are read for their id only; the one that matters is id 2.
        let answered = await run(
            codex, arguments: ["-s", "read-only", "-a", "never", "app-server"],
            in: FileManager.default.homeDirectoryForCurrentUser, input: input, timeout: timeout
        ) { output in
            for line in output.split(separator: 0x0A) {
                guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      (message["id"] as? Int) == 2 else { continue }
                return message["result"] != nil
            }
            return nil
        }
        return answered?.isEmpty == false
    }

    nonisolated private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Running a CLI

    /// Runs a CLI and returns its output once it exits, or as soon as `verdict`
    /// decides, or nil after `timeout`, on cancellation, or on failure. The
    /// process is ended either way; it never outlives the call by more than two
    /// seconds. With a `verdict`, a positive one returns non-empty output.
    nonisolated private static func run(
        _ executable: String,
        arguments: [String],
        in folder: URL,
        environment extra: [String: String] = [:],
        input: Data? = nil,
        timeout: TimeInterval,
        verdict: (@Sendable (Data) -> Bool?)? = nil
    ) async -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = folder
        // An npm install is a Node script, and apps opened from Finder get a bare
        // PATH, so put Node's usual homes next to the one the CLI came from.
        var environment = ProcessInfo.processInfo.environment.merging(extra) { $1 }
        let homes = [URL(fileURLWithPath: executable).deletingLastPathComponent().path,
                     "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        environment["PATH"] = (homes + [environment["PATH"]].compactMap { $0 }).joined(separator: ":")
        process.environment = environment
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // Writing to a CLI that already quit must fail, not raise SIGPIPE in Usagebar.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        let collector = OutputCollector(verdict: verdict)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                collector.finishAtEnd()
            } else {
                collector.append(data)
            }
        }

        let output = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                collector.onFinish = { continuation.resume(returning: $0) }
                do {
                    try process.run()
                } catch {
                    collector.finish(nil)
                    return
                }
                if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { collector.finish(nil) }
            }
        } onCancel: {
            collector.finish(nil)
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        try? stdin.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        return output
    }
}

/// Collects a CLI's output and resumes its waiter exactly once, whichever of
/// verdict, end of output, timeout or cancellation comes first.
nonisolated private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let verdict: (@Sendable (Data) -> Bool?)?
    private var buffer = Data()
    private var result: Data??
    private var waiter: ((Data?) -> Void)?

    init(verdict: (@Sendable (Data) -> Bool?)?) {
        self.verdict = verdict
    }

    var onFinish: ((Data?) -> Void)? {
        get { nil }
        set {
            lock.lock()
            if let result {
                lock.unlock()
                newValue?(result)
                return
            }
            waiter = newValue
            lock.unlock()
        }
    }

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let overflow = buffer.count > 1_000_000
        let snapshot = buffer
        lock.unlock()
        // A runaway process never gets to hold much memory.
        if overflow { finish(nil); return }
        if let verdict, let decided = verdict(snapshot) {
            finish(decided ? snapshot : Data())
        }
    }

    /// The CLI closed its output. Without a verdict, that is the answer.
    func finishAtEnd() {
        lock.lock()
        let snapshot = buffer
        lock.unlock()
        finish(verdict == nil ? snapshot : nil)
    }

    func finish(_ value: Data?) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = .some(value)
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?(value)
    }
}
