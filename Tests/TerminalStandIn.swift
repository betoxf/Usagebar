import Foundation

/// A stand-in CLI for terminal session tests: this test binary, started again
/// under another name on a real pseudo-terminal, reading what the test types.
/// System binaries hide their environment from other processes, so one of
/// those could not show an `ANTHROPIC_BASE_URL`.
nonisolated struct TerminalStandIn {
    private let process: pid_t
    private let primary: Int32
    private let replica: Int32

    /// Becomes the stand-in when this process was started as one.
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--stand-in-cli") else { return }
        while readLine() != nil {}
        exit(0)
    }

    init?(named name: String, environment: [String] = []) {
        var primary: Int32 = -1
        var replica: Int32 = -1
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard openpty(&primary, &replica, &path, nil, nil) == 0 else { return nil }

        // A session leader takes the first terminal it opens as its controlling terminal.
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        defer { posix_spawnattr_destroy(&attributes) }
        let command = "exec -a \(name) '\(Bundle.main.executablePath!)' --stand-in-cli < '\(String(cString: path))'"
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup(command), nil]
        let variables: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer { (arguments + variables).forEach { free($0) } }

        var process: pid_t = 0
        guard posix_spawn(&process, "/bin/sh", nil, &attributes, arguments, variables) == 0 else {
            close(primary)
            close(replica)
            return nil
        }
        self.process = process
        self.primary = primary
        self.replica = replica
    }

    /// Typing keeps this session the most recently used one, whatever else a
    /// developer has open while the tests run.
    func type() {
        _ = write(primary, "\n", 1)
    }

    func stop() {
        kill(process, SIGKILL)
        // The stand-in cannot finish exiting while its terminal holds unread output.
        close(primary)
        close(replica)
        waitpid(process, nil, 0)
    }
}
