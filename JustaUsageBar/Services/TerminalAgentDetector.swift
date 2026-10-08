//
//  TerminalAgentDetector.swift
//  JustaUsageBar
//
//  Tells which AI coding CLI is in use inside a terminal-like app by reading the
//  process table. Needs no Accessibility, Automation, or Screen Recording access,
//  and stores nothing it reads.
//

import Foundation
import Darwin

nonisolated struct TerminalAgentScan {
    /// Provider of the CLI running in the app's most recently used terminal session.
    var provider: DisplayProvider?
    /// Whether the app hosts terminal sessions, so its sessions are worth watching.
    var hostsTerminals: Bool
}

nonisolated enum TerminalAgentDetector {
    /// Terminals whose sessions may all live under a detached server (iTerm2) or a
    /// multiplexer. Any other app qualifies by owning a terminal session itself.
    static let terminalBundleIDs: Set<String> = [
        "com.apple.terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.warp-stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "org.tabby"
    ]

    /// Runtimes that run a CLI as a script: the script names the tool, not the runtime.
    private static let scriptRuntimes = ["node", "bun", "deno", "python"]

    // MARK: - Classification

    /// Maps a foreground terminal command to the provider whose quota it spends.
    static func provider(executable: String, arguments: [String], baseURL: String?) -> DisplayProvider? {
        var paths = [executable]
        if let command = arguments.first {
            paths.append(command)
            let runtime = commandName(command)
            if scriptRuntimes.contains(where: runtime.hasPrefix),
               let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                paths.append(script)
            }
        }

        for path in paths.map({ $0.lowercased() }) {
            switch commandName(path) {
            case "claude", "claude-code": return claudeCompatibleProvider(baseURL: baseURL)
            case "codex": return .codex
            case "cursor-agent": return .cursor
            case "kimi", "kimi-cli", "kimi-code": return .kimi
            case "grok": return .xai
            default: break
            }
            // Versioned installs and package entry points do not carry the tool's name.
            if path.contains("/claude/versions/") || path.contains("/@anthropic-ai/claude-code/") {
                return claudeCompatibleProvider(baseURL: baseURL)
            }
            if path.contains("/@openai/codex/") { return .codex }
            if path.contains("/cursor-agent/") { return .cursor }
        }
        return nil
    }

    /// Claude Code spends another plan's quota when pointed at that plan's gateway.
    private static func claudeCompatibleProvider(baseURL: String?) -> DisplayProvider? {
        guard let host = baseURL.flatMap({ URL(string: $0)?.host?.lowercased() }) else { return .claude }
        func isWithin(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if isWithin("anthropic.com") { return .claude }
        if isWithin("z.ai") || isWithin("bigmodel.cn") { return .zai }
        if isWithin("kimi.com") { return .kimi }
        return nil
    }

    private static func commandName(_ path: String) -> String {
        var name = path.split(separator: "/").last.map(String.init) ?? path
        for suffix in [".js", ".mjs", ".cjs", ".py"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }

    // MARK: - Terminal Sessions

    /// Scans the terminal sessions of `app`. Sessions that another application
    /// hosts are never attributed to it.
    static func scan(app: pid_t, isTerminal: Bool) -> TerminalAgentScan {
        var parents: [pid_t: pid_t] = [:]

        /// nil when another application hosts the process, false for a detached
        /// session server (tmux, iTermServer), true when it descends from `app`.
        func isHostedByApp(_ pid: pid_t) -> Bool? {
            var ancestors: [pid_t] = []
            var current = pid
            for _ in 0..<64 {
                guard let parent = parents[current] ?? parent(of: current), parent > 1, parent != current else {
                    break
                }
                parents[current] = parent
                if parent == app { return true }
                ancestors.append(parent)
                current = parent
            }
            return ancestors.contains(where: isApplication) ? nil : false
        }

        var hostsTerminals = isTerminal
        var latestInput: TimeInterval?
        var provider: DisplayProvider?
        // Most recently used first, which is how `w` measures idle time.
        for terminal in terminals().sorted(by: { $0.lastInput > $1.lastInput }) {
            if hostsTerminals, provider != nil { break }
            // A multiplexer relays one keystroke through two terminals, so input
            // within a second of the latest counts as the same session.
            let isOlderSession = latestInput.map { $0 - terminal.lastInput > 1 } ?? false
            if hostsTerminals, isOlderSession { break }

            let processes = processes(on: terminal.device)
            for process in processes {
                parents[process.kp_proc.p_pid] = process.kp_eproc.e_ppid
            }
            let foreground = processes.filter { $0.kp_eproc.e_pgid == $0.kp_eproc.e_tpgid }
            guard let member = foreground.first ?? processes.first,
                  let hosted = isHostedByApp(member.kp_proc.p_pid) else { continue }
            if hosted { hostsTerminals = true }
            // An older session only shows whether the app hosts terminals at all.
            if isOlderSession { continue }

            latestInput = latestInput ?? terminal.lastInput
            // The CLI started the job, so it is among the oldest processes; the
            // tools and MCP servers it runs (another CLI included) are younger.
            let oldestFirst = foreground.sorted { startTime($0) < startTime($1) }.prefix(8)
            provider = provider ?? oldestFirst.lazy.compactMap { process in
                command(of: process.kp_proc.p_pid).flatMap {
                    self.provider(executable: $0.executable, arguments: $0.arguments, baseURL: $0.baseURL)
                }
            }.first
        }
        return TerminalAgentScan(provider: hostsTerminals ? provider : nil, hostsTerminals: hostsTerminals)
    }

    private static func startTime(_ process: kinfo_proc) -> TimeInterval {
        let time = process.kp_proc.p_un.__p_starttime
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1e6
    }

    /// Pseudo-terminals in use, with the time each last delivered input.
    private static func terminals() -> [(device: dev_t, lastInput: TimeInterval)] {
        guard let directory = opendir("/dev") else { return [] }
        defer { closedir(directory) }
        var terminals: [(device: dev_t, lastInput: TimeInterval)] = []
        while let entry = readdir(directory) {
            // Sessions are ttys000 and up; the shorter names are legacy devices.
            guard entry.pointee.d_namlen >= 7 else { continue }
            var info = stat()
            let isSession = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { name in
                    strncmp(name, "ttys", 4) == 0 && fstatat(dirfd(directory), name, &info, 0) == 0
                }
            }
            guard isSession else { continue }
            let lastInput = TimeInterval(info.st_atimespec.tv_sec) + TimeInterval(info.st_atimespec.tv_nsec) / 1e9
            terminals.append((info.st_rdev, lastInput))
        }
        return terminals
    }

    private static func processes(on terminal: dev_t) -> [kinfo_proc] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, terminal]
        // A build can put hundreds of processes on one terminal.
        for capacity in [32, 256, 4096] {
            var isTooSmall = false
            let processes = [kinfo_proc](unsafeUninitializedCapacity: capacity) { table, count in
                var length = capacity * MemoryLayout<kinfo_proc>.stride
                if sysctl(&name, 4, table.baseAddress, &length, nil, 0) == 0 {
                    count = length / MemoryLayout<kinfo_proc>.stride
                } else {
                    isTooSmall = errno == ENOMEM
                }
            }
            if !isTooSmall { return processes }
        }
        return []
    }

    /// Whether the process runs from an application bundle.
    static func isApplication(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path).contains(".app/")
    }

    private static func parent(of pid: pid_t) -> pid_t? {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, 4, &process, &length, nil, 0) == 0, length > 0 else { return nil }
        return process.kp_eproc.e_ppid
    }

    /// Reads a process's launch path, arguments, and Anthropic gateway override.
    private static func command(of pid: pid_t) -> (executable: String, arguments: [String], baseURL: String?)? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var length = 0
        guard sysctl(&name, 3, nil, &length, nil, 0) == 0, length > MemoryLayout<Int32>.size else { return nil }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: MemoryLayout<Int32>.alignment)
        defer { buffer.deallocate() }
        guard sysctl(&name, 3, buffer.baseAddress, &length, nil, 0) == 0,
              length > MemoryLayout<Int32>.size else { return nil }

        // Layout: argument count, executable path, arguments, then environment.
        let count = max(0, Int(buffer.loadUnaligned(as: Int32.self)))
        let strings = UnsafeRawBufferPointer(rebasing: buffer[MemoryLayout<Int32>.size..<length])
            .split(separator: 0)
        guard let executable = strings.first else { return nil }
        let arguments = strings.dropFirst().prefix(count)
        let variable = Array("ANTHROPIC_BASE_URL=".utf8)
        let baseURL = strings.dropFirst(1 + count).first { $0.starts(with: variable) }
        return (
            String(decoding: executable, as: UTF8.self),
            arguments.map { String(decoding: $0, as: UTF8.self) },
            baseURL.map { String(decoding: $0.dropFirst(variable.count), as: UTF8.self) }
        )
    }
}
