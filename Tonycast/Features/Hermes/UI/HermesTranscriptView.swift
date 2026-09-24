import SwiftUI

/// The scrolling transcript.
///
/// `defaultScrollAnchor(.bottom)` keeps the view pinned to the newest content as chunks stream in,
/// and — unlike a manual `scrollTo` — leaves the reader where they are the moment they scroll up.
/// The deployment target is macOS 26, so the API needs no availability fallback.
struct HermesTranscriptView: View {
    let session: ACPSessionManager

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.sectionSpacing) {
                if session.transcript.isEmpty {
                    emptyState
                }
                ForEach(session.transcript) { item in
                    HermesTranscriptRow(item: item)
                }
            }
            .padding(.horizontal, Theme.Spacing.dialogInset)
            .padding(.vertical, Theme.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Ask Hermes anything")
                .font(Theme.Typography.panelTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
            Text(
                "This is your own Hermes agent, running in the selected project root. It can read and edit files, run commands, and use its skills and memory. It asks here before it does anything destructive."
            )
            .font(Font.caption)
            .foregroundStyle(Theme.Colors.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Theme.Spacing.xxl)
    }
}

/// One transcript item, styled by role.
private struct HermesTranscriptRow: View {
    let item: ACPTranscriptItem

    var body: some View {
        switch item.role {
        case .user:
            bubble(isUser: true)
        case .assistant:
            bubble(isUser: false)
        case .thinking:
            thinkingRow
        case .system:
            systemRow
        case .tool:
            if let tool = item.tool {
                HermesToolCallView(tool: tool)
            }
        case .plan:
            planRow
        }
    }

    @ViewBuilder
    private func bubble(isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: Theme.Spacing.xxl) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: Theme.Spacing.xs) {
                Text(item.text)
                    .font(Font.body)
                    .foregroundStyle(isUser ? Theme.Colors.textPrimary : Theme.Colors.noteText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !item.attachments.isEmpty {
                    attachmentRow
                }
            }
            .padding(isUser ? Theme.Spacing.lg : 0)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(isUser ? Theme.Colors.controlSurface : Color.clear))
            if !isUser { Spacer(minLength: Theme.Spacing.xxl) }
        }
    }

    /// What was carried with the message, so a sent prompt stays legible after Send.
    private var attachmentRow: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(item.attachments) { attachment in
                HStack(spacing: Theme.Spacing.xxs) {
                    Image(systemName: attachment.kind.symbolName)
                    Text(attachment.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .help(attachment.path)
            }
        }
    }

    /// Thinking is present but quiet: it is context, not the answer.
    private var thinkingRow: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "ellipsis.bubble")
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
            Text(item.text)
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var systemRow: some View {
        Text(item.text)
            .font(Font.caption)
            .foregroundStyle(Theme.Colors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var planRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Plan")
                .font(Font.caption)
                .foregroundStyle(Theme.Colors.textTertiary)
            ForEach(Array(item.entries.enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Image(systemName: "circle")
                        .font(Font.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                    Text(entry)
                        .font(Font.caption)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
