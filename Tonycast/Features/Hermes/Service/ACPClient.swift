import Foundation

/// ACP's wire over a child process: newline-delimited JSON-RPC on stdin/stdout.
///
/// Deliberately an `actor` rather than the MCP transport's `@MainActor`: one agent turn can push
/// hundreds of notifications (token chunks, thinking, tool progress), and none of that traffic
/// should hop through the main thread on its way in. The UI observes a main-actor projection.
///
/// The process is long-lived. Cold start costs seconds and every turn carries the agent's full
/// system prompt, so respawning per prompt is the expensive failure mode.
actor ACPClient {
    /// In-flight request bookkeeping. Each entry carries its own timeout task.
    private struct Pending {
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeout: Task<Void, Never>
    }

    /// An agent→client request that needs a decision from the user.
    struct PermissionRequest: Sendable, Identifiable {
        /// The JSON-RPC id the answer must be addressed to.
        let rpcID: JSONValue
        let requestID: String
        let title: String
        let detail: String
        let options: [PermissionOption]

        /// `Identifiable` needs this one to be stable across updates, and `requestID` is the agent's.
        var id: String { requestID }
    }

    struct PermissionOption: Sendable, Equatable {
        let optionID: String
        let name: String
        let kind: String
    }

    /// What the client is told about the agent's own liveness.
    enum Event: Sendable {
        case connected(agentVersion: String)
        case disconnected(reason: String)
        case sessionReady(sessionID: String)
        case notification(method: String, params: JSONValue)
        case permission(PermissionRequest)
    }

    // MARK: - State

    private let command: String
    private let arguments: [String]
    private let workingDirectory: String
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var stderrBuffer = Data()
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    /// Set when the user asked to stop, so a late exit is not reported as a crash.
    private var intentionalStop = false
    /// Serial, off-actor writer. Writes never touch the actor's thread.
    private let writer = ACPFrameWriter()

    /// Fan-out for notifications the session layer consumes.
    private var eventHandler: (@Sendable (Event) -> Void)?

    /// An unterminated frame this long means the peer is not speaking ACP.
    private static let outputLimit = 8 * 1_048_576
    private static let stderrLimit = 8_192
    /// A turn can legitimately run for minutes; the per-method timeouts below cover control calls.
    private static let defaultTimeout: Duration = .seconds(60)

    init(command: String = "hermes", arguments: [String] = ["acp"], workingDirectory: String) {
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
    }

    // MARK: - Lifecycle

    var isRunning: Bool { process?.isRunning == true }

    func onEvent(_ handler: @escaping @Sendable (Event) -> Void) {
        eventHandler = handler
    }

    func start() async throws {
        if isRunning { return }
        guard let executable = await ExecutableLocator.locate(command) else {
            throw ACPError.launchFailed(
                "`\(command)` was not found on this Mac. Install Hermes, or set its path in settings.")
        }
        // A concurrent start may have won the race during the async lookup.
        if isRunning { return }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        process.environment = Self.launchEnvironment(executable: executable)

        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeOutput(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeStderr(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.didExit(status: status) }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw ACPError.launchFailed(error.localizedDescription)
        }
        self.process = process
        input = stdin.fileHandleForWriting
        // A frame is written off the actor: a pipe write blocks once the buffer fills (~64 KB), and
        // writing on the actor would freeze the reader and every timeout watchdog with it.
        writer.start(handle: stdin.fileHandleForWriting)

        // Handshake: nothing is usable until the agent answers `initialize`.
        do {
            let response = try await request(ACPMessage.initialize)
            let agentVersion =
                response.objectValue?["agentInfo"]?.objectValue?["version"]?.stringValue ?? "unknown"
            emit(.connected(agentVersion: agentVersion))
        } catch {
            // Without this the child stays alive with `isRunning == true` but never initialized, so a
            // retry would skip the handshake and leave the client permanently broken.
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            stop()
            throw ACPError.launchFailed(reason)
        }
    }

    func stop() {
        guard let process else { return }
        writer.stop()
        // The user asked for this stop, so a late exit must not report a crash reason.
        intentionalStop = true
        process.terminationHandler = nil
        (process.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        input = nil
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { process.terminate() }
        }
        finishAll(with: ACPError.notRunning)
        self.process = nil
        // Buffers must not survive into the next session: stale bytes would corrupt its first frame.
        outputBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
    }

    // MARK: - Requests

    func request(
        _ build: (Int) throws -> Data, timeout: Duration = ACPClient.defaultTimeout
    ) async throws -> JSONValue {
        guard isRunning, input != nil else { throw ACPError.notRunning }
        let id = nextID
        nextID += 1
        let frame = try build(id)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let watchdog = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(continuation: continuation, timeout: watchdog)
                // Queued, never written inline: a blocking pipe write on the actor would stall the
                // reader and stop this request's own watchdog from ever firing.
                writer.enqueue(frame)
            }
        } onCancel: {
            Task { await self.expire(id) }
        }
    }

    /// A prompt runs an entire turn, so it gets its own generous timeout rather than the default.
    func prompt(sessionID: String, text: String) async throws -> JSONValue {
        try await request(
            { try ACPMessage.prompt(id: $0, sessionID: sessionID, text: text) },
            timeout: .seconds(1_800))
    }

    func newSession(cwd: String) async throws -> String {
        let response = try await request({ try ACPMessage.newSession(id: $0, cwd: cwd) })
        guard let sessionID = response.objectValue?["sessionId"]?.stringValue else {
            throw ACPError.malformedResponse
        }
        emit(.sessionReady(sessionID: sessionID))
        return sessionID
    }

    func loadSession(sessionID: String, cwd: String) async throws -> String {
        _ = try await request({ try ACPMessage.loadSession(id: $0, sessionID: sessionID, cwd: cwd) })
        emit(.sessionReady(sessionID: sessionID))
        return sessionID
    }

    func cancel(sessionID: String) async throws {
        _ = try await request({ try ACPMessage.cancel(id: $0, sessionID: sessionID) })
    }

    func setMode(sessionID: String, modeID: String) async throws {
        _ = try await request(
            { try ACPMessage.setMode(id: $0, sessionID: sessionID, modeID: modeID) })
    }

    func setModel(sessionID: String, modelID: String) async throws {
        _ = try await request(
            { try ACPMessage.setModel(id: $0, sessionID: sessionID, modelID: modelID) })
    }

    // MARK: - Answers to agent requests

    func answerPermission(_ request: PermissionRequest, optionID: String?) async {
        let frame: Data?
        if let optionID {
            frame = try? ACPMessage.permissionAnswer(id: request.rpcID, optionID: optionID)
        } else {
            frame = try? ACPMessage.permissionCancelled(id: request.rpcID)
        }
        send(frame)
    }

    // MARK: - Private

    private func send(_ data: Data?) {
        guard let data else { return }
        writer.enqueue(data)
    }

    private func emit(_ event: Event) {
        eventHandler?(event)
    }

    /// A response resolves the request; a notification or request is pushed to the owner.
    private func handle(_ message: ACPProtocol.Message) {
        switch message {
        case .response(let id, let result):
            finish(id, with: .success(result))
        case .failure(let id, let code, let message):
            finish(id, with: .failure(ACPError.agentError(code: code, message: message)))
        case .notification(let method, let params):
            emit(.notification(method: method, params: params))
        case .request(let id, let method, let params):
            handleAgentRequest(id: id, method: method, params: params)
        case .invalid:
            // A line neither side can parse is not fatal; the next frame may be fine.
            break
        }
    }

    private func handleAgentRequest(id: JSONValue, method: String, params: JSONValue) {
        guard method == "session/request_permission" else {
            // Anything else (fs/terminal) is refused explicitly rather than silently ignored,
            // so the agent does not wait on a reply that never comes.
            send(try? ACPProtocol.error(
                id: id,
                code: ACPProtocol.methodNotFound,
                message: "Tonycast does not implement \(method)."))
            return
        }
        let object = params.objectValue
        let toolCall = object?["toolCall"]?.objectValue
        let options =
            (object?["options"]?.arrayValue ?? []).compactMap { value -> PermissionOption? in
                guard let option = value.objectValue,
                    let optionID = option["optionId"]?.stringValue,
                    let name = option["name"]?.stringValue
                else { return nil }
                return PermissionOption(
                    optionID: optionID,
                    name: name,
                    kind: option["kind"]?.stringValue ?? "")
            }
        // `title` is what the agent calls the action; the raw command lives in content blocks.
        let title = toolCall?["title"]?.stringValue ?? "Hermes needs permission"
        let detail = Self.permissionDetail(from: toolCall)
        let request = PermissionRequest(
            rpcID: id,
            requestID: toolCall?["toolCallId"]?.stringValue ?? UUID().uuidString,
            title: title,
            detail: detail,
            options: options)
        emit(.permission(request))
    }

    /// Flattens the tool call's content blocks into a readable detail line.
    private static func permissionDetail(from toolCall: [String: JSONValue]?) -> String {
        let blocks = toolCall?["content"]?.arrayValue ?? []
        let texts = blocks.compactMap { block -> String? in
            let object = block.objectValue
            guard let type = object?["type"]?.stringValue else { return nil }
            switch type {
            case "content":
                return object?["content"]?.objectValue?["text"]?.stringValue
            case "text":
                return object?["text"]?.stringValue
            default:
                return nil
            }
        }
        return texts.joined(separator: "\n")
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            handle(ACPProtocol.parse(Data(line)))
        }
        guard outputBuffer.count > Self.outputLimit else { return }
        let message = "Hermes sent an unterminated oversized message and was disconnected."
        stop()
        emit(.disconnected(reason: message))
    }

    private func consumeStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        stderrBuffer.append(data)
        // Keep the tail only: a startup banner is noise, the last lines are the reason it died.
        guard stderrBuffer.count > Self.stderrLimit else { return }
        stderrBuffer.removeFirst(stderrBuffer.count - Self.stderrLimit)
    }

    private func expire(_ id: Int) {
        finish(id, with: .failure(ACPError.timedOut))
    }

    private func finish(_ id: Int, with result: Result<JSONValue, Error>) {
        guard let entry = pending.removeValue(forKey: id) else { return }
        entry.timeout.cancel()
        entry.continuation.resume(with: result)
    }

    private func finishAll(with error: Error) {
        let entries = pending
        pending.removeAll()
        for entry in entries.values {
            entry.timeout.cancel()
            entry.continuation.resume(throwing: error)
        }
    }

    private func didExit(status: Int32) {
        drainStderr()
        let detail = String(decoding: stderrBuffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let reason =
            detail.isEmpty ? "Hermes exited with status \(status)." : Self.lastLines(of: detail)
        // Pending calls fail before the owner is told, or a late `stop()` would overwrite the reason.
        finishAll(with: ACPError.requestFailed(reason))
        let wasIntentional = intentionalStop
        intentionalStop = false
        cleanup()
        // A user-initiated stop already told the UI; reporting it again reads as a crash.
        guard !wasIntentional else { return }
        emit(.disconnected(reason: reason))
    }

    /// Termination can beat the last read, and what the agent printed on its way out is the reason.
    private func drainStderr() {
        guard let handle = (process?.standardError as? Pipe)?.fileHandleForReading else { return }
        handle.readabilityHandler = nil
        consumeStderr(handle.readDataToEndOfFile())
    }

    private func cleanup() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? input?.close()
        process = nil
        input = nil
        outputBuffer.removeAll(keepingCapacity: false)
        stderrBuffer.removeAll(keepingCapacity: false)
    }

    /// The app inherits Finder's PATH, so the agent's own toolchain has to be put back on it.
    private static func launchEnvironment(executable: URL) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let paths =
            [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin"]
            + [inherited["PATH"] ?? "/usr/bin:/bin"]
        return inherited.merging([
            // ACP reserves stdout for the wire; colour codes would corrupt a frame.
            "NO_COLOR": "1", "PATH": paths.joined(separator: ":"),
            // Force line-buffered stdio so a frame is not held back in a pipe buffer.
            "PYTHONUNBUFFERED": "1",
        ]) { _, new in new }
    }

    private static func lastLines(of text: String, limit: Int = 4) -> String {
        let lines = text.split(separator: "\n").suffix(limit)
        return lines.joined(separator: "\n")
    }
}

/// Errors surfaced to the UI. Wording is user-facing, so no raw error dumps.
enum ACPError: LocalizedError, Equatable {
    case notRunning
    case launchFailed(String)
    case requestFailed(String)
    case agentError(code: Int, message: String)
    case malformedResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Hermes is not running."
        case .launchFailed(let detail):
            return detail
        case .requestFailed(let detail):
            return detail
        case .agentError(_, let message):
            return message
        case .malformedResponse:
            return "Hermes sent a response Tonycast could not read."
        case .timedOut:
            return "Hermes did not respond in time."
        }
    }
}
