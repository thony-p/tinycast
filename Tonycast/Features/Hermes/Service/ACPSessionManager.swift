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

    /// Files to carry with the next prompt. Cleared once the prompt is sent.
    private(set) var attachments: [ACPAttachment] = []
    /// An attachment the user removed before sending, kept so `undo` can put it back.
    private var removedAttachments: [ACPAttachment] = []

    /// The newest usage reading, shown beside the composer rather than as a transcript row.
    private(set) var usage: ACPTranscriptItem.Usage?

    private let client: ACPClient
    private let settings: HermesSettings
    private let broker: ACPPermissionBroker
    /// The last turn's failure, surfaced next to the composer rather than as a sheet.
    private(set) var lastError: String?

    init(settings: HermesSettings, broker: ACPPermissionBroker = ACPPermissionBroker()) {
        self.settings = settings
        self.broker = broker
        self.client = ACPClient(
            connection: settings.connection, workingDirectory: settings.launchDirectory)
    }

    // MARK: - Lifecycle

    /// Which Hermes this window talks to, for the header and the New Session dialog.
    var connection: HermesConnection { settings.connection }

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
        usage = nil
    }

    /// Switches to another Hermes instance and starts a fresh session there.
    ///
    /// The process is torn down rather than re-pointed: a session and its id belong to the instance
    /// that minted them, so the transcript is cleared too. Doing it in this order means the window
    /// never shows the old host's conversation under the new host's name.
    ///
    /// The switch is claimed synchronously, before the first suspension. Two menu clicks in one
    /// turn would otherwise both tear the process down and both start one, racing the same client.
    func switchConnection(to connection: HermesConnection) async {
        guard connection != settings.connection else { return }
        // A switch kills the running agent, so it is refused mid-turn rather than cancelling one.
        guard status != .launching, !isTurnActive else { return }
        status = .launching
        agentVersion = nil
        sessionID = nil
        pendingPermission = nil
        pendingPermissionOptions = []
        usage = nil
        transcript.removeAll()
        clearAttachments()
        await client.stop()
        settings.connection = connection
        await client.use(connection)
        status = .idle
        await connect()
    }

    /// New session in the configured working directory, discarding the current conversation.
    func startNewSession() async {
        guard !isTurnActive else { return }
        transcript.removeAll()
        usage = nil
        clearAttachments()
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

    // MARK: - Attachments

    /// Adds picked files to the next prompt. A path already attached is not added twice, and a path
    /// Tonycast cannot turn into a valid link is dropped rather than sent as a dead one.
    func attach(_ paths: [String]) {
        let existing = Set(attachments.map(\.path))
        let additions = paths.filter { !existing.contains($0) }.compactMap(ACPAttachment.at(path:))
        guard !additions.isEmpty else { return }
        attachments.append(contentsOf: additions)
        removedAttachments.removeAll()
    }

    func removeAttachment(_ attachment: ACPAttachment) {
        guard let index = attachments.firstIndex(where: { $0.id == attachment.id }) else { return }
        removedAttachments = [attachments.remove(at: index)]
    }

    /// Puts back the last removed attachment, so a mis-click is not a re-pick.
    func undoRemoveAttachment() {
        guard let restored = removedAttachments.popLast() else { return }
        guard !attachments.contains(where: { $0.path == restored.path }) else { return }
        attachments.append(restored)
    }

    func clearAttachments() {
        attachments.removeAll()
        removedAttachments.removeAll()
    }

    // MARK: - Turns

    /// Sends a prompt and reports whether a turn actually began, so the composer only discards the
    /// draft once it has been handed over. Clearing first would lose the text when the send fails.
    @discardableResult
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Attachments alone are a valid prompt: a screenshot with no words is a real request.
        guard !trimmed.isEmpty || !attachments.isEmpty else { return false }
        if !status.isReady { await connect() }
        guard status.isReady, let sessionID else { return false }

        let sent = attachments
        transcript.append(.user(trimmed.isEmpty ? "Attached \(sent.count) file(s)." : trimmed, attachments: sent))
        attachments.removeAll()
        removedAttachments.removeAll()
        isTurnActive = true
        lastError = nil
        // The permission sheet must not outlive the turn that raised it.
        pendingPermission = nil
        pendingPermissionOptions = []
        do {
            let measured = try await client.prompt(
                sessionID: sessionID, text: trimmed, attachments: sent)
            // The measured count replaces the estimate the streamed notifications left behind.
            if let measured {
                recordUsage(used: measured.inputTokens, size: usage?.size, isEstimated: false)
            }
        } catch {
            lastError = Self.describe(error)
            transcript.append(.system("Turn failed: \(Self.describe(error))"))
        }
        isTurnActive = false
        return true
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
            // A mid-turn reading, and always a rough estimate: the agent has not measured the
            // request yet. The prompt response replaces it with the real count when the turn ends.
            if let used = update["used"]?.intValue {
                recordUsage(used: used, size: update["size"]?.intValue ?? usage?.size, isEstimated: true)
            }
        default:
            break
        }
    }

    /// Keeps one usage reading for the whole window. A later notification with no `size` must not
    /// throw away the context window an earlier one reported, or the gauge loses its denominator.
    private func recordUsage(used: Int, size: Int?, isEstimated: Bool) {
        let resolved = size ?? usage?.size ?? 0
        usage = ACPTranscriptItem.Usage(used: used, size: resolved, isEstimated: isEstimated)
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
