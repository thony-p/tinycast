import SwiftUI

/// The Hermes conversation window: transcript, composer, and permission prompts.
struct HermesView: View {
    @Bindable var session: ACPSessionManager
    let settings: HermesSettings

    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
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
        .background(Theme.Colors.panelScrim)
        .frame(
            minWidth: HermesWindowController.minimumSize.width,
            minHeight: HermesWindowController.minimumSize.height)
        .onAppear { composerFocused = true }
    }

    private var composer: some View {
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
            if let usage = session.usage {
                HermesUsageGauge(usage: usage)
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
        HStack(spacing: Theme.Spacing.sm) {
            Text(usage.label)
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .monospacedDigit()
            Text(usage.barLabel)
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .monospaced()
            Spacer(minLength: 0)
        }
        .help("Context window usage for this session")
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
            // Gated here as well as inside the menu: a switch tears the process down, so the
            // parent must not rely on the child to enforce it.
            HermesConnectionMenu(
                connection: session.connection,
                isEnabled: canChangeConnection,
                onSelect: { connection in
                    Task { await session.switchConnection(to: connection) }
                })
                .disabled(!canChangeConnection)
            Button("New Session") {
                Task { await session.startNewSession() }
            }
            .buttonStyle(.plain)
            .font(Font.caption)
            .foregroundStyle(Theme.Colors.textSecondary)
            .disabled(!session.status.isReady || session.isTurnActive)
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
