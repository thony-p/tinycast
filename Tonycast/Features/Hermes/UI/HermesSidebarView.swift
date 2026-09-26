import SwiftUI

/// The workspace column: a project picker with its own New Session, and that project's sessions.
///
/// One project at a time rather than every project at once. Hermes can hold dozens of projects, and
/// as
/// one section per project the column becomes mostly empty headers; the picker keeps it to the
/// project
/// being worked in. Its session count is in each entry, so an empty project says so before it is
/// chosen.
///
/// Read from the Hermes instance the window is attached to, so switching host swaps the whole
/// column:
/// the projects and the session ids both belong to the host that minted them.
struct HermesSidebarView: View {
    @Environment(\.metrics) private var metrics
    let session: ACPSessionManager
    let onOpen: (HermesSessionSummary) -> Void
    let onNewSession: (HermesWorkspace?) -> Void

    /// Which project is listed. Home is an id like any other, so the picker needs no second
    /// list, and it is the default: a launcher chat belongs to no project.
    @State private var selection: String = HermesSidebarSection.ungroupedID

    /// The picker's entries: Home first, then the projects in creation order.
    ///
    /// Home is always present even with no sessions, because it is the default and a destination in
    /// its
    /// own right — dropping it when empty would silently move a fresh window to some project.
    private var entries: [HermesSidebarSection] {
        let sections = session.sidebarSections
        let home = sections.first { $0.workspace == nil }
            ?? HermesSidebarSection(workspace: nil, sessions: [])
        return [home] + sections.filter { $0.workspace != nil }
    }

    private var section: HermesSidebarSection { entries.first { $0.id == selection } ?? entries[0] }

    var body: some View {
        VStack(spacing: 0) {
            picker
            Divider().overlay(Theme.Colors.separator)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: metrics.spacing.xxs) {
                    if section.sessions.isEmpty {
                        emptySessions
                    }
                    ForEach(section.sessions) { summary in
                        HermesSidebarSessionRow(
                            session: summary,
                            isCurrent: summary.id == session.currentSessionID,
                            onOpen: { onOpen(summary) })
                    }
                }
                .padding(.horizontal, metrics.spacing.sm)
                .padding(.vertical, metrics.spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Not `edgeDissolve`, which also masks the top: over this plain header that fade only
            // dims the first row while the list rests at the top.
            .overflowFade()
        }
        .frame(width: metrics.size.hermesSidebar)
    }

    /// The project being listed, and the one New Session control — beside the project it starts in.
    ///
    /// The plus and the picker are siblings, not nested: a control inside a `Menu`'s label opens
    /// the
    /// menu instead of running, so the plus could not start anything from there.
    private var picker: some View {
        HStack(spacing: metrics.spacing.xs) {
            Menu {
                ForEach(entries) { entry in
                    Button {
                        selection = entry.id
                    } label: {
                        // The count is in the label: an empty project must not look loaded.
                        Text("\(entry.title) — \(entry.sessions.count)")
                    }
                }
            } label: {
                HStack(spacing: metrics.spacing.xs) {
                    Text(section.title)
                        .font(Theme.Typography.panelTitle)
                        .foregroundStyle(Theme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .help("Choose which project to list")

            Button {
                onNewSession(section.workspace)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .frame(
                        width: metrics.size.hermesSidebarAction,
                        height: metrics.size.hermesSidebarAction)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, metrics.spacing.sm)
            .accessibilityLabel("New session in \(section.title)")
            .help(newSessionHelp)
            .disabled(!session.status.isReady || session.isTurnActive)
        }
        .padding(.leading, metrics.spacing.md)
        .frame(height: metrics.size.hermesPicker)
    }

    /// Names the directory, because that is what a new session in a project actually uses — and the
    /// folder is resolved on the connected host, so it is worth showing rather than implying.
    private var newSessionHelp: String {
        let directory = section.workspace?.startDirectory ?? ""
        return directory.isEmpty ? "New session in \(section.title)" : "New session in \(directory)"
    }

    /// A failed read is stated here too, so a stale list is visible without pressing Refresh.
    private var emptySessions: some View {
        Text(emptySessionsMessage)
            .font(Font.caption)
            .foregroundStyle(
                session.sidebarError == nil ? Theme.Colors.textTertiary : Theme.Colors.textSecondary)
            .padding(.horizontal, metrics.spacing.md)
            .padding(.vertical, metrics.spacing.xs)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var emptySessionsMessage: String {
        if let error = session.sidebarError { return "\(error) — press Refresh" }
        return session.isLoadingSidebar ? "Reading sessions…" : "No sessions here yet"
    }
}

/// One session row. The whole row is the target; the title is the only thing that can be long.
private struct HermesSidebarSessionRow: View {
    @Environment(\.metrics) private var metrics
    let session: HermesSessionSummary
    let isCurrent: Bool
    let onOpen: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.displayTitle)
                    .font(Font.caption)
                    .foregroundStyle(isCurrent ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // Stated before the click, so a read-only session is not a surprise.
                if let origin = session.originLabel {
                    Text("\(origin) · view only")
                        .font(Font.caption2)
                        .foregroundStyle(Theme.Colors.textTertiary)
                } else if let updated = session.updatedAt {
                    Text(updated, format: .relative(presentation: .named))
                        .font(Font.caption2)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .padding(.horizontal, metrics.spacing.md)
            .padding(.vertical, metrics.spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.menuRow, style: .continuous)
                    .fill(fill))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(session.cwd.isEmpty ? "Home" : session.cwd)
    }

    /// Shaded only for the session actually open, or under the pointer — never merely because the
    /// row
    /// happens to be first.
    private var fill: Color {
        if isCurrent { return Theme.Colors.selection }
        return hovered ? Theme.Colors.rowHover : .clear
    }
}
