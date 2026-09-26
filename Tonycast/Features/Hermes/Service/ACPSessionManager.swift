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
        /// Whether reaching this status means a process has to be started.
        ///
        /// A ready connection already has one and a launching one is mid-start, so both refuse. The
        /// sidebar's listing is read either way, which is what keeps a session created elsewhere
        /// from
        /// staying invisible in a warm window.
        var needsLaunch: Bool {
            switch self {
            case .ready, .launching: return false
            case .idle, .failed: return true
            }
        }
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

    /// The connected host's projects, and the sessions attached to them. Both are refreshed
    /// together, because a session's project is decided by its cwd against these folders.
    private(set) var workspaces: [HermesWorkspace] = []
    private(set) var sessions: [HermesSessionSummary] = []
    /// True while the sidebar's listing is being read, so the pane can say so rather than showing
    /// an
    /// empty list, which would read as "no sessions".
    private(set) var isLoadingSidebar = false
    /// Set when the last read reached nothing, so a caller can report a stale list rather than implying a
    /// working one. Nil when the last read answered.
    private(set) var sidebarError: String?

    /// The sidebar's sections, grouped by the same rule Hermes' own sidebar uses.
    var sidebarSections: [HermesSidebarSection] {
        HermesSidebarSection.sections(workspaces: workspaces, sessions: sessions)
    }

    /// The session the window is showing, so the sidebar can mark its row. Nil before one exists,
    /// and nil for a read-only session, which is not attached to any session the agent knows.
    var currentSessionID: String? { sessionID }

    /// True while the window is showing a session this client may read but not continue.
    ///
    /// Hermes restores only the sessions it created over ACP, so one from the desktop app, the
    /// web UI or a cron job is readable out of the store and nothing more. The composer is disabled
    /// and the window says why, rather than accepting a prompt the agent would answer with an
    /// error.
    private(set) var isReadOnly = false
    /// What created that session, for the explanation: "Hermes app", "Hermes web UI", …
    private(set) var readOnlyOrigin: String?
    /// That session's items, kept so a continuation can be built from them. The rendered transcript
    /// has
    /// already lost the reader/agent distinction a handover needs.
    private(set) var readOnlyItems: [HermesTranscriptReader.Item] = []
    /// The session those items came from, so the window can title its continuation and file it
    /// under the
    /// right project without the view keeping its own copy of the selection.
    private(set) var readOnlySession: HermesSessionSummary?

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

    /// Starts the process and attaches a session, and refreshes the sidebar either way.
    ///
    /// The warm path matters as much as the cold one: Hermes' own app can create a session in a
    /// project while Tonycast runs, and nothing on the wire announces it. Without a read here, the
    /// window keeps the list it had when it was last opened, so that session stays invisible until
    /// the app is restarted.
    func connect() async {
        guard status.needsLaunch else {
            // Already connected, or mid-launch: the wire is fine, but the listing is still re-read.
            if status.isReady { await refreshSidebar() }
            return
        }
        status = .launching
        lastError = nil
        await client.onEvent { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        do {
            try await client.start()
            try await attachSession()
            // After the session is attached: the pane is useless without a wire, and the listing is
            // what makes the window worth opening.
            await refreshSidebar()
        } catch {
            status = .failed(Self.describe(error))
        }
    }

    func disconnect() async {
        await client.stop()
        status = .idle
        agentVersion = nil
        sessionID = nil
        liveSessionCwd = nil
        isTurnActive = false
        usage = nil
        isReadOnly = false
        readOnlyOrigin = nil
        readOnlyItems = []
        readOnlySession = nil
        sidebarError = nil
        workspaces.removeAll()
        sessions.removeAll()
    }

    // MARK: - The sidebar's listing

    /// Reads the connected host's projects and its sessions.
    ///
    /// The two come from different places for the same reason the pane exists: Hermes publishes its
    /// ACP sessions over the wire, but it keeps the *whole* store and its project list in databases
    /// that only exist on the host, so both are read there with a script. They are fetched together
    /// because grouping a session under a project needs both.
    ///
    /// A failure is recorded rather than swallowed. The list itself is left as it was, because emptying
    /// it over a transient host error would read as "no sessions" — but a read that reached nothing is
    /// a fact the caller has to be able to report, or a stale list looks like a working one.
    func refreshSidebar() async {
        guard status.isReady else { return }
        isLoadingSidebar = true
        sidebarError = nil
        let connection = settings.connection
        async let projects = HermesWorkspaceReader.read(connection)
        async let rows = HermesSessionReader.read(connection)
        let (found, listed) = await (projects, rows)
        // A host switch mid-read must not publish the old host's projects over the new one's.
        guard connection == settings.connection else { return }
        workspaces = found
        // A failed read yields nothing, so a list being read is only replaced when it answered.
        if !listed.isEmpty { sessions = listed.map(HermesSessionSummary.from) }
        if found.isEmpty && listed.isEmpty {
            sidebarError = "\(connection.name) did not answer"
        }
        isLoadingSidebar = false
    }

    /// Opens an existing session, replacing the transcript with its history.
    ///
    /// Two paths, because Hermes only lets ACP restore what ACP created. A continuable session goes
    /// through `session/load`, which streams its history back as ordinary `session/update`
    /// notifications. Anything else is read from the host's store and shown **read-only** — loading
    /// it over the wire would return an empty success and leave the window looking blank.
    func openSession(_ summary: HermesSessionSummary) async {
        guard status.isReady, !isTurnActive else { return }
        isReadOnly = !summary.isContinuable
        readOnlyOrigin = summary.originLabel
        transcript.removeAll()
        usage = nil
        clearAttachments()
        pendingPermission = nil
        pendingPermissionOptions = []
        lastError = nil
        if summary.isContinuable {
            await loadContinuable(summary)
        } else {
            await loadReadOnly(summary)
        }
    }

    private func loadContinuable(_ summary: HermesSessionSummary) async {
        // A session's cwd is fixed at creation, so it is loaded with its own, not the setting.
        do {
            sessionID = try await client.loadSession(sessionID: summary.id, cwd: summary.cwd)
            liveSessionCwd = summary.cwd
            settings.rememberSession(sessionID: summary.id, cwd: summary.cwd)
            status = .ready
        } catch {
            // The row stays listed: the session exists, this attempt to open it did not work.
            lastError = Self.describe(error)
            sessionID = nil
            liveSessionCwd = nil
            status = .failed(Self.describe(error))
        }
    }

    private func loadReadOnly(_ summary: HermesSessionSummary) async {
        let items = await HermesTranscriptReader.read(settings.connection, sessionID: summary.id)
        guard !items.isEmpty else {
            lastError = "Hermes kept no readable transcript for this session."
            return
        }
        readOnlyItems = items
        readOnlySession = summary
        transcript = items.map(ACPTranscriptItem.init(readOnly:))
        sessionID = nil
        liveSessionCwd = summary.cwd
    }

    /// Continues a session another surface created, by starting one here and handing over its
    /// history.
    ///
    /// The only route available: Hermes refuses to reopen a foreign session over ACP, and every ACP
    /// method funnels through that check, so the work is carried rather than the session. The new
    /// session opens in the project the old one was filed under — not in whichever project the
    /// picker
    /// happens to list — so the agent gets the right working directory.
    ///
    /// Reports whether a session actually started, so the window only swaps the transcript when
    /// there is
    /// somewhere for the conversation to continue.
    @discardableResult
    func continueFromReadOnly(_ summary: HermesSessionSummary) async -> Bool {
        guard status.isReady, !isTurnActive, isReadOnly else { return false }
        let digest = HermesSessionHandoff.make(from: readOnlyItems)
        // A session whose transcript held no prose has nothing to carry; that is reported, not
        // sent.
        guard !digest.isEmpty else {
            lastError = "This session holds no readable conversation to continue."
            return false
        }
        // The project this session belongs to, so a session filed under Tonycast opens in Tonycast
        // even
        // if the picker is showing Home.
        let directory = sidebarSections
            .first { section in section.sessions.contains { $0.id == summary.id } }?
            .workspace?.startDirectory ?? settings.sessionDirectory
        await startNewSession(in: directory)
        guard status.isReady else { return false }
        return await send(HermesSessionHandoff.prompt(for: summary, digest: digest))
    }

    /// Starts a new session in `directory`, which is empty for a session Hermes files under Home.
    ///
    /// The directory is written to settings first because `attachSession` reads it from there; the
    /// sidebar is refreshed afterwards so the new session appears under the project just used.
    func startNewSession(in directory: String) async {
        guard !isTurnActive else { return }
        settings.sessionDirectory = directory
        await startNewSession()
        await refreshSidebar()
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
        liveSessionCwd = nil
        pendingPermission = nil
        pendingPermissionOptions = []
        usage = nil
        transcript.removeAll()
        isReadOnly = false
        readOnlyOrigin = nil
        readOnlyItems = []
        readOnlySession = nil
        sidebarError = nil
        clearAttachments()
        // The old host's projects are not the new host's, and its session ids do not exist there.
        workspaces.removeAll()
        sessions.removeAll()
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
        // A new session is a continuable one, so the read-only state ends with the old transcript.
        isReadOnly = false
        readOnlyOrigin = nil
        readOnlyItems = []
        readOnlySession = nil
        sidebarError = nil
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
        // Reattach only when the previous session ran in the same directory: a session's cwd is
        // fixed at creation, so resuming elsewhere hands the agent a stale working root.
        if !forceNew, settings.canReattach(to: cwd), let saved = settings.savedSessionID {
            do {
                sessionID = try await client.loadSession(sessionID: saved, cwd: cwd)
                liveSessionCwd = cwd
                status = .ready
                // History is replayed by the agent as notifications, so nothing is restored here.
                appendSystemNote("Reattached to your previous Hermes session.")
                return
            } catch {
                appendSystemNote("Could not reattach the previous session; starting a new one.")
            }
        }
        sessionID = try await client.newSession(cwd: cwd)
        liveSessionCwd = cwd
        settings.rememberSession(sessionID: sessionID ?? "", cwd: cwd)
        status = .ready
    }

    /// Where this session is filed in Hermes' own sidebar: `Home` when it has no working
    /// directory, otherwise the directory's name. Shown so placement is visible, not inferred.
    ///
    /// Reads the live session's own cwd, not the setting: opening a session from the sidebar shows
    /// where *that* session lives, which may be nowhere the setting points.
    var sessionLocationLabel: String {
        let cwd = liveSessionCwd ?? settings.sessionDirectory
        guard !cwd.isEmpty else { return "Home" }
        return (cwd as NSString).lastPathComponent
    }

    /// The cwd of the session actually loaded, set whenever one is created, loaded or reattached.
    private(set) var liveSessionCwd: String?

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

    /// The session mode controls whether edits need approval; `accept_edits` is the practical
    /// default.
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
            // The broker narrows the menu: a destructive command never gets a session-scoped grant.
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
            // A mid-turn reading, and always an estimate: the prompt response replaces it with the
            // real count when the turn ends.
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
