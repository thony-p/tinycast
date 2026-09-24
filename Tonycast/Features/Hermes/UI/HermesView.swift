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
            HStack(alignment: .bottom, spacing: Theme.Spacing.md) {
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
        }
        .padding(Theme.Spacing.dialogInset)
    }

    private var canSend: Bool {
        session.status.isReady && !session.isTurnActive
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() {
        let text = draft
        guard canSend else { return }
        draft = ""
        Task { await session.send(text) }
    }
}

/// Identity, connection state, and the two session controls.
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

    private var subtitle: String {
        switch session.status {
        case .ready:
            let placement = "filed in \(session.sessionLocationLabel)"
            if let version = session.agentVersion {
                return "Connected · Hermes \(version) · \(placement)"
            }
            return "Connected · \(placement)"
        default:
            return session.status.label
        }
    }
}
