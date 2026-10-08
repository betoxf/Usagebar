//
//  KeychainTool.swift
//  JustaUsageBar
//
//  Reads one secret from the keychain through `/usr/bin/security` rather than in
//  process. The items Usagebar looks for are created with that tool, so it reads
//  them without a dialog. A permission granted to it also survives app updates;
//  one granted to Usagebar's own ad hoc signed binary is lost with every build.
//

import Foundation

nonisolated final class KeychainTool {
    private let executable: String
    private let patience: TimeInterval
    /// A read still waiting on the user's answer to the tool's keychain dialog.
    private var pending: (process: Process, output: Pipe)?
    private var wasRefused = false

    init(executable: String = "/usr/bin/security", patience: TimeInterval = 1.5) {
        self.executable = executable
        self.patience = patience
    }

    /// Lets an explicit refresh ask again after the user refused.
    func reset() {
        wasRefused = false
    }

    /// The password of a generic password item, or nil when it cannot be had now.
    /// The items passed in are alternatives for the same secret: an answer to a
    /// dialog that was still open is returned by the next call, whichever it is.
    func password(service: String, account: String) -> String? {
        if let waiting = pending {
            // Never stack a second dialog behind one that is still on screen.
            guard !waiting.process.isRunning else { return nil }
            pending = nil
            if let password = result(of: waiting.process, output: waiting.output) {
                return password
            }
            wasRefused = true
        }
        guard !wasRefused else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["find-generic-password", "-s", service]
            + (account.isEmpty ? [] : ["-a", account]) + ["-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        guard (try? process.run()) != nil else { return nil }

        // A read that needs no permission returns at once. One that does shows the
        // tool's dialog, and ending the tool would leave that dialog on screen with
        // nothing behind it. So the wait is bounded, never the dialog.
        guard finished.wait(timeout: .now() + patience) == .success else {
            pending = (process, output)
            return nil
        }
        return result(of: process, output: output)
    }

    private func result(of process: Process, output: Pipe) -> String? {
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let password = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return password.isEmpty ? nil : password
    }
}
