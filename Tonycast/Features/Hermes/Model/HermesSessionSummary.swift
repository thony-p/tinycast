import Foundation

/// One session in the sidebar: everything a row needs to render and reopen it.
struct HermesSessionSummary: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// The session's working directory, fixed when it was created. Empty means Hermes files it
    /// under Home.
    let cwd: String
    /// The git root Hermes recorded. A project matches a session on either this or its cwd, so both
    /// are carried: a session run in a project's second folder has a cwd *and* a root.
    let repoRoot: String
    /// Which Hermes surface created it. Only `acp` can be reopened and continued here.
    let source: String
    let updatedAt: Date?
    /// The session's first user message, used as a title when Hermes wrote none.
    let preview: String

    init(
        id: String, title: String, cwd: String, repoRoot: String = "", source: String = "acp",
        updatedAt: Date?, preview: String = ""
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.repoRoot = repoRoot
        self.source = source
        self.updatedAt = updatedAt
        self.preview = preview
    }

    /// Whether `session/load` can reopen this one. Hermes restores only the sessions it created
    /// over
    /// ACP, and answers any other id with an empty result rather than an error, so this is the one
    /// honest test of whether the session can be continued here.
    var isContinuable: Bool { source == "acp" }

    /// What the row says about where the session came from, or nil for one created here.
    ///
    /// Shown so the read-only state is explained before the row is clicked rather than after.
    var originLabel: String? {
        switch source {
        case "acp": return nil
        case "desktop": return "Hermes app"
        case "cli": return "Hermes CLI"
        case "webui": return "Hermes web UI"
        case "api_server": return "API"
        case "tui": return "Hermes TUI"
        default: return source
        }
    }

    /// What the row shows. Hermes titles a session from its first prompt, but a session that
    /// predates
    /// that, or was created by a surface that does not title at all, has none — so its own first
    /// user
    /// message names it, and only then the directory.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let opening = preview.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        if !opening.isEmpty { return String(opening.prefix(120)) }
        let leaf = (cwd as NSString).lastPathComponent
        return leaf.isEmpty ? "New thread" : leaf
    }

    /// Built from a row of the host's own sessions table, which is where every source is visible.
    static func from(_ row: HermesSessionReader.Row) -> HermesSessionSummary {
        HermesSessionSummary(
            id: row.id,
            title: row.title,
            cwd: row.cwd,
            repoRoot: row.repoRoot,
            source: row.source,
            updatedAt: row.updatedAt,
            preview: row.preview)
    }

    /// Decoded from the agent's `session/list` result. That endpoint reports only the sessions this
    /// client created, so it is no longer the sidebar's source; it is kept because it is the wire's
    /// own answer and the harnesses pin its decode. A row with no id is dropped.
    static func decodeListing(_ result: JSONValue) -> [HermesSessionSummary] {
        let rows = result.objectValue?["sessions"]?.arrayValue ?? []
        return rows.compactMap { row in
            guard let object = row.objectValue, let id = object["sessionId"]?.stringValue,
                !id.isEmpty
            else { return nil }
            return HermesSessionSummary(
                id: id,
                title: object["title"]?.stringValue ?? "",
                cwd: HermesWorkspace.normalizedPath(object["cwd"]?.stringValue ?? ""),
                updatedAt: parseTimestamp(object["updatedAt"]?.stringValue))
        }
    }

    /// `updatedAt` is ISO 8601 with microseconds and an offset, which only parses with fractional
    /// seconds enabled. The plain form is tried too, so a coarser timestamp costs the ordering.
    static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}
