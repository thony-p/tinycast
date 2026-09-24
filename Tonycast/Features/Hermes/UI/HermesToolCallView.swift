import SwiftUI

/// A tool call as its own row: title, status, and the result or diff when the agent sends one.
struct HermesToolCallView: View {
    let tool: ACPTranscriptItem.Tool

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                statusGlyph
                Text(tool.title)
                    .font(Font.caption)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if hasDetail {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Font.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard hasDetail else { return }
                withAnimation(.easeOut(duration: Theme.Duration.hover)) { isExpanded.toggle() }
            }

            if isExpanded, let detail = tool.detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.Typography.code)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Theme.Spacing.lg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                            .fill(Theme.Colors.controlSurface))
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.Colors.rowHover))
    }

    private var hasDetail: Bool {
        !(tool.detail ?? "").isEmpty
    }

    private var statusGlyph: some View {
        Group {
            switch tool.status {
            case "completed":
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case "failed":
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            default:
                Image(systemName: "circle.dotted")
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .font(Font.caption)
        .frame(width: 14)
    }
}
