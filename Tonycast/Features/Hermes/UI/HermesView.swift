import SwiftUI

/// The Hermes conversation window: transcript, composer, and permission prompts.
struct HermesView: View {
    @Bindable var session: ACPSessionManager
    let settings: HermesSettings

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            HermesSidebarView(
                session: session,
                onOpen: open(_:),
                onNewSession: startSession(in:))
            Divider().overlay(Theme.Colors.separator)
            conversation
        }
        .background(Theme.Colors.panelScrim)
        .frame(
            minWidth: HermesWindowController.minimumSize.width,
            minHeight: HermesWindowController.minimumSize.height)
        .onAppear { composerFocused = true }
    }

    /// Bound to `Task<Void, Never>` rather than left to inference: Swift 6.2 cannot choose between
    /// `Task`'s throwing and non-throwing forms for a closure that only awaits, which is ambiguous.
    private func open(_ summary: HermesSessionSummary) {
        Task<Void, Never> { await session.openSession(summary) }
    }

    /// A project is where a session opens; Home is the empty directory Hermes files separately, so
    /// a
    /// workspace with no usable folder falls back to it.
    private func startSession(in workspace: HermesWorkspace?) {
        let directory = workspace?.startDirectory ?? ""
        Task<Void, Never> { await session.startNewSession(in: directory) }
    }

    private var conversation: some View {
        VStack(spacing: 0) {
            HermesHeader(session: session)
            Divider().overlay(Theme.Colors.separator)
            HermesTranscriptView(session: session)
            if let permission = session.pendingPermission {
                Divider().overlay(Theme.Colors.separator)
                HermesPermissionSheet(
                    request: permission,
                    options: session.pendingPermissionOptions,
                    onDecide: { optionID in
                        Task { await session.answerPermission(optionID: optionID) }
                    })
            }
            Divider().overlay(Theme.Colors.separator)
            composer
        }
    }

    @ViewBuilder
    private var composer: some View {
        if session.isReadOnly {
            readOnlyNotice
        } else {
            activeComposer
        }
    }

    /// Shown instead of the composer for a session this client may read but not continue.
    ///
    /// Hermes refuses to reopen a session another surface created, and every ACP method funnels
    /// through
    /// that check, so this offers the route that does exist: carry the conversation into a new
    /// session
    /// under the project this one was filed in. It is not a resume, and the wording says so.
    private var readOnlyNotice: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: "eye")
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("View only")
                    .font(Font.body)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(readOnlyExplanation)
                    .font(Font.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.lg)
            Button("Continue…") { continueFromReadOnly() }
                .buttonStyle(.plain)
                .font(Font.caption)
                .foregroundStyle(
                    session.status.isReady ? Theme.Colors.textSecondary : Theme.Colors.textTertiary)
                .disabled(!session.status.isReady)
                .help("Start a new session in this project with this conversation as its context")
        }
        .padding(Theme.Spacing.dialogInset)
    }

    /// Reading the transcript and sending are separate, so the manager reports whether a session
    /// started
    /// and the window only swaps to it once there is somewhere for the conversation to go.
    private func continueFromReadOnly() {
        guard let summary = session.readOnlySession else { return }
        Task { await session.continueFromReadOnly(summary) }
    }

    /// Tells the user the same thing the agent is told, so both sides agree on what Continue did.
    private var readOnlyExplanation: String {
        let origin = session.readOnlyOrigin ?? "another Hermes surface"
        return
            "This session was created in \(origin). Hermes only lets Tonycast continue sessions it "
            + "started over ACP, so this history is here to read. Continue starts a new session in "
            + "this project with the conversation as its context."
    }
    private var activeComposer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let error = session.lastError {
                Text(error)
                    .font(Font.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HermesAttachmentBar(
                attachments: session.attachments,
                onRemove: { session.removeAttachment($0) })
            HStack(alignment: .bottom, spacing: Theme.Spacing.md) {
                HermesAttachButton(isEnabled: session.status.isReady, onSource: pickAttachments)

                TextField("Ask Hermes…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Font.body)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1...10)
                    .focused($composerFocused)
                    .disabled(!session.status.isReady)
                    .onSubmit(submit)

                if let usage = session.usage {
                    HermesUsageGauge(usage: usage)
                }

                if session.isTurnActive {
                    Button("Stop") { Task { await session.cancelTurn() } }
                        .buttonStyle(.plain)
                        .font(Font.body)
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    Button("Send", action: submit)
                        .buttonStyle(.plain)
                        .font(Font.body)
                        .foregroundStyle(
                            canSend ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
                        .disabled(!canSend)
                }
            }
        }
        .padding(Theme.Spacing.dialogInset)
    }

    private var canSend: Bool {
        session.status.isReady && !session.isTurnActive
            && !(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && session.attachments.isEmpty)
    }

    private func submit() {
        let text = draft
        guard canSend else { return }
        // The draft is cleared only once the session took it. A refused or failed send leaves the
        // text in place, so a lost connection never silently discards what the user typed.
        Task {
            if await session.send(text) { draft = "" }
        }
    }

    private func pickAttachments(_ source: ACPAttachmentSource) {
        let paths = ACPAttachmentPicker.present(source)
        guard !paths.isEmpty else { return }
        session.attach(paths)
    }
}

/// The context-window gauge, in Hermes' own format: `~211.8k/1M` then `[██░░░░░░░░] ~20%`.
struct HermesUsageGauge: View {
    let usage: ACPTranscriptItem.Usage

    var body: some View {
        ZStack(alignment: .trailing) {
            reading(
                label: HermesUsageFormat.widestContextLabel(size: usage.size),
                bar: HermesUsageFormat.widestBarLabel())
                .hidden()
            reading(label: usage.label, bar: usage.barLabel)
        }
        .font(Font.caption)
        .foregroundStyle(Theme.Colors.textTertiary)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context window usage \(usage.label)")
        .help("Context window usage for this session")
    }

    private func reading(label: String, bar: String) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(label)
                .monospacedDigit()
            Text(bar)
                .monospaced()
        }
    }
}

/// Identity, which Hermes, and the session controls.
private struct HermesHeader: View {
    let session: ACPSessionManager

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.Colors.menuSymbol)
            VStack(alignment: .leading, spacing: 1) {
                Text("Hermes")
                    .font(Theme.Typography.panelTitle)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(subtitle)
                    .font(Font.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer()
            // The sidebar reads Hermes' store on the host, and nothing on the wire announces a
            // session
            // created in Hermes' own app — so this is how the list is brought up to date on demand.
            HermesRefreshButton(session: session)
            // Gated here as well as inside the menu: a switch tears the process down, so the
            // parent must not rely on the child to enforce it.
            HermesConnectionMenu(
                connection: session.connection,
                isEnabled: canChangeConnection,
                onSelect: { connection in
                    Task { await session.switchConnection(to: connection) }
                })
                .disabled(!canChangeConnection)
        }
        .padding(.horizontal, Theme.Spacing.dialogInset)
        .padding(.vertical, Theme.Spacing.md)
    }

    /// A switch tears the process down, which mid-turn would kill a running agent.
    private var canChangeConnection: Bool {
        !session.isTurnActive && session.status != .launching
    }

    private var subtitle: String {
        switch session.status {
        case .ready:
            let placement = "filed in \(session.sessionLocationLabel)"
            if let version = session.agentVersion {
                return "Connected · \(session.connection.name) · Hermes \(version) · \(placement)"
            }
            return "Connected · \(session.connection.name) · \(placement)"
        case .launching:
            return "Starting Hermes on \(session.connection.name)…"
        default:
            return session.status.label
        }
    }
}
