import Foundation

/// Runs a read-only script on the connected Hermes host and returns its stdout.
///
/// Both readers in this feature need the same thing — read a Hermes store on the machine that owns
/// it
/// — so the launch, the stdin write and the timeout live here once. That matters because the launch
/// is
/// not the ACP wire's: `hermes acp` is a long-lived process whose command describes it, while these
/// are short reads that must run where the *sessions* live, which is another machine when the
/// window
/// is attached to the VM.
///
/// The script arrives on standard input, so no path is ever quoted into a shell command line, and
/// nothing is written on the far side. Only stdout is parsed, and a non-zero exit yields no bytes
/// rather than a partial parse of whatever was printed on the way down.
enum HermesHostScript {
    nonisolated static func run(
        _ connection: HermesConnection, script: String, timeout: TimeInterval
    ) async -> Data {
        let launch = connection.workspaceLaunch
        guard let executable = await executable(for: launch) else { return Data() }
        return await spawn(
            executable: executable, arguments: launch.arguments, input: script, timeout: timeout)
    }

    /// Resolves the launch command without searching PATH for a name that is already a path.
    ///
    /// `ExecutableLocator` answers a bare command name like `ssh`, and answers nil for an absolute
    /// path because it only ever searches PATH. The local launch is the interpreter's absolute
    /// path,
    /// so it is checked directly; `ssh` goes through the locator.
    private nonisolated static func executable(for launch: (command: String, arguments: [String]))
        async -> URL?
    {
        if launch.command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: launch.command)
                ? URL(fileURLWithPath: launch.command) : nil
        }
        return await ExecutableLocator.locate(launch.command)
    }

    private nonisolated static func spawn(
        executable: URL, arguments: [String], input: String, timeout: TimeInterval
    ) async -> Data {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let stdin = Pipe()
            let stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            // Unread stderr fills its pipe and blocks the child, so it is discarded deliberately.
            process.standardError = FileHandle.nullDevice

            let collector = OutputCollector()
            stdout.fileHandleForReading.readabilityHandler = { collector.absorb($0.availableData) }

            return await withCheckedContinuation { continuation in
                process.terminationHandler = { finished in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    collector.absorb((try? stdout.fileHandleForReading.readToEnd()) ?? Data())
                    continuation.resume(
                        returning: finished.terminationStatus == 0 ? collector.data : Data())
                }
                do {
                    try process.run()
                } catch {
                    // The handler never fires for a process that never started.
                    stdout.fileHandleForReading.readabilityHandler = nil
                    process.terminationHandler = nil
                    continuation.resume(returning: Data())
                    return
                }
                // Closing stdin says the script is complete; an open pipe waits forever instead.
                try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                try? stdin.fileHandleForWriting.close()

                Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    if process.isRunning { process.terminate() }
                }
            }
        }.value
    }
}

/// Read from the pipe's queue and the termination handler, so the lock is load-bearing.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Buffers bytes, not text: a read landing mid-character would decode to a replacement.
    func absorb(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }
}
