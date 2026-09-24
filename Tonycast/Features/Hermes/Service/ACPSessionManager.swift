import Foundation
import Observation

/// Owns the one long-lived `hermes acp` process and the session attached to it.
///
/// One process for the app's lifetime: cold start costs seconds and every turn carries the agent's
/// full system prompt, so a process per prompt is the expensive failure mode. The session id is
/// persisted so a relaunch can reattach with `session/load` instead of starting over.
@MainActor
@Observable
final class ACPSessionManager {
    /// Where the conversation is, from the UI's point of view.
    enum Status: Equatable {
        case idle
        case launching
        case ready
        case failed(String)

        var isReady: Bool { self == .ready }
        var label: String {
            switch self {
            case .idle: return "Not connected"
            case .launching: return "Starting Hermes…"
            case .ready: return "Connected"
            case .failed(let message): return message
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var agentVersion: String?
    /// The live transcript, appended to as notifications arrive.
    private(set) var transcript: [ACPTranscriptItem] = []
    /// Set while a turn is in flight, so the composer can disable Send and offer Stop.
    private(set) var isTurnActive = false
    private(set) var sessionID: String?

    /// A permission prompt waiting on the user. The broker decides which options are offered.
    private(set) var pendingPermission: ACPClient.PermissionRequest?
    /// Options actually shown, which may be narrower than what the agent proposed.
    private(set) var pendingPermissionOptions: [ACPClient.PermissionOption] = []

    private let client: ACPClient
    private let settings: HermesSettings
    private let broker: ACPPermissionBroker
    /// The last turn's failure, surfaced next to the composer rather than as a sheet.
    private(set) var lastError: String?

    init(settings: HermesSettings, broker: ACPPermissionBroker = ACPPermissionBroker()) {
        self.settings = settings
        self.broker = broker
        self.client = ACPClient(workingDirectory: settings.launchDirectory)
    }

    // MARK: - Lifecycle

    /// Starts the process and attaches a session. Safe to call repeatedly.
    func connect() async {
        guard status != .launching, status != .ready else { return }
        status = .launching
        lastError = nil
        await client.onEvent { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try await client.start()
            try await attachSession()
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    func disconnect() async {
        await client.stop()
        status = .idle
        agentVersion = nil
        sessionID = nil
        isTurnActive = false
    }

    /// New session in the configured working directory, discarding the current conversation.
    func startNewSession() async {
        transcript.removeAll()
        do {
            try await attachSession(forceNew: true)
        } catch {
            // A failed new session must not leave the window claiming to be ready.
            status = .failed(Self.describe(error))
            lastError = Self.describe(error)
        }
    }

    private func attachSession(forceNew: Bool = false) async throws {
        let cwd = settings.sessionDirectory
        // Reattach only when the previous session ran in the same directory; a session's cwd is
        // fixed at creation, so resuming elsewhere would hand the agent a stale working root.
        if !forceNew, settings.canReattach(to: cwd), let saved = settings.savedSessionID {
            do {
                sessionID = try await client.loadSession(sessionID: saved, cwd: cwd)
                status = .ready
                // History is replayed by the agent as notifications, so nothing is restored here.
                appendSystemNote("Reattached to your previous Hermes session.")
                return
            } catch {
                appendSystemNote("Could not reattach the previous session; starting a new one.")
            }
        }
        sessionID = try await client.newSession(cwd: cwd)
        settings.savedSessionID = sessionID
        settings.savedSessionCwd = cwd
        status = .ready
    }

    /// Where this session is filed in Hermes' own sidebar: `Home` when it has no working
    /// directory, otherwise the directory's name. Shown so placement is visible, not inferred.
    var sessionLocationLabel: String {
        let cwd = settings.sessionDirectory
        guard !cwd.isEmpty else { return "Home" }
        return (cwd as NSString).lastPathComponent
    }

    // MARK: - Turns

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !status.isReady { await connect() }
        guard status.isReady, let sessionID else { return }

        transcript.append(.user(trimmed))
        isTurnActive = true
        lastError = nil
        // The permission sheet must not outlive the turn that raised it.
        pendingPermission = nil
        pendingPermissionOptions = []
        do {
            _ = try await client.prompt(sessionID: sessionID, text: trimmed)
        } catch {
            lastError = Self.describe(error)
            transcript.append(.system("Turn failed: \(Self.describe(error))"))
        }
        isTurnActive = false
    }

    func cancelTurn() async {
        guard let sessionID, isTurnActive else { return }
        try? await client.cancel(sessionID: sessionID)
    }

    /// The session mode controls whether edits need approval; `accept_edits` is the practical default.
    func setMode(_ modeID: String) async {
        guard let sessionID else { return }
        try? await client.setMode(sessionID: sessionID, modeID: modeID)
    }

    // MARK: - Permissions

    func answerPermission(optionID: String?) async {
        guard let request = pendingPermission else { return }
        pendingPermission = nil
        pendingPermissionOptions = []
        await client.answerPermission(request, optionID: optionID)
        if let optionID {
            transcript.append(.system("Approved: \(optionID)"))
        } else {
            transcript.append(.system("Denied."))
        }
    }

    // MARK: - Event handling

    private func handle(_ event: ACPClient.Event) {
        switch event {
        case .connected(let version):
            agentVersion = version
        case .sessionReady:
            break
        case .disconnected(let reason):
            status = .failed(reason)
            isTurnActive = false
            pendingPermission = nil
            pendingPermissionOptions = []
        case .notification(let method, let params):
            consume(method: method, params: params)
        case .permission(let request):
            // The broker narrows the menu: a destructive command never offers a session-scoped grant.
            let verdict = broker.evaluate(request)
            pendingPermission = request
            pendingPermissionOptions = verdict.options
        }
    }

    private func consume(method: String, params: JSONValue) {
        guard method == "session/update" else { return }
        guard let update = params.objectValue?["update"]?.objectValue else { return }
        guard let kind = update["sessionUpdate"]?.stringValue else { return }

        switch kind {
        case "agent_message_chunk":
            appendChunk(update, as: .assistant)
        case "agent_thought_chunk":
            appendChunk(update, as: .thinking)
        case "user_message_chunk":
            appendChunk(update, as: .user)
        case "tool_call":
            transcript.append(
                .tool(
                    ACPTranscriptItem.Tool(
                        id: update["toolCallId"]?.stringValue ?? UUID().uuidString,
                        title: update["title"]?.stringValue ?? "Running a tool",
                        status: update["status"]?.stringValue ?? "in_progress",
                        detail: nil)))
        case "tool_call_update":
            updateTool(update)
        case "plan":
            let entries = (update["entries"]?.arrayValue ?? []).compactMap {
                $0.objectValue?["content"]?.stringValue
            }
            if !entries.isEmpty {
                transcript.append(.plan(entries))
            }
        case "usage_update":
            if let used = update["used"]?.intValue {
                transcript.append(.usage(used))
            }
        default:
            break
        }
    }

    /// A chunk continues the previous item when it is the same role, which is what streaming looks
    /// like on the wire: many one-token chunks, one visible bubble.
    private func appendChunk(_ update: [String: JSONValue], as role: ACPTranscriptItem.Role) {
        guard let text = update["content"]?.objectValue?["text"]?.stringValue, !text.isEmpty else {
            return
        }
        if transcript.last?.role == role, transcript.last?.isChunkContinuation == true {
            transcript[transcript.count - 1].text += text
        } else {
            transcript.append(ACPTranscriptItem(role: role, text: text))
        }
    }

    private func updateTool(_ update: [String: JSONValue]) {
        guard let id = update["toolCallId"]?.stringValue else { return }
        guard let index = transcript.lastIndex(where: { $0.tool?.id == id }) else { return }
        guard var tool = transcript[index].tool else { return }
        tool.status = update["status"]?.stringValue ?? tool.status
        // A completed tool carries its diff/result; keep the most recent non-empty detail.
        if let detail = update["content"]?.arrayValue, !detail.isEmpty {
            let texts = detail.compactMap { block -> String? in
                let object = block.objectValue
                if object?["type"]?.stringValue == "content" {
                    return object?["content"]?.objectValue?["text"]?.stringValue
                }
                return object?["text"]?.stringValue
            }
            let joined = texts.joined(separator: "\n")
            if !joined.isEmpty { tool.detail = joined }
        }
        transcript[index] = .tool(tool)
    }

    private func appendSystemNote(_ text: String) {
        transcript.append(.system(text))
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
