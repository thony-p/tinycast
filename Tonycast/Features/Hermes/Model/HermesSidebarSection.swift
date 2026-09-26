import Foundation

/// One sidebar section: a project and the sessions filed under it, or — with no workspace — the
/// sessions that belong to no project.
struct HermesSidebarSection: Identifiable, Equatable, Sendable {
    let workspace: HermesWorkspace?
    let sessions: [HermesSessionSummary]

    /// Stable, and never equal to a project id: Hermes mints those as `p_…`.
    static let ungroupedID = "tonycast.hermes.ungrouped"
    /// The ungrouped section's name: the sessions whose cwd is empty, which Hermes buckets as Home.
    static let ungroupedTitle = "Home"

    var id: String { workspace?.id ?? Self.ungroupedID }
    var title: String { workspace?.name ?? Self.ungroupedTitle }

    /// Sections in the order Hermes' sidebar shows them: the user's own projects first, in creation
    /// order, then the ungrouped sessions.
    ///
    /// A project with no sessions is still shown — it is how a session gets started in it. The
    /// ungrouped section is dropped when empty, because it names no place to start one.
    ///
    /// A session is filed under the project owning the **longest** folder that is an ancestor of
    /// its cwd, which is Hermes' own rule.
    static func sections(
        workspaces: [HermesWorkspace], sessions: [HermesSessionSummary]
    ) -> [HermesSidebarSection] {
        let index = FolderIndex(workspaces: workspaces)

        var filed = [[HermesSessionSummary]](repeating: [], count: workspaces.count)
        var ungrouped: [HermesSessionSummary] = []
        for session in sessions {
            if let owner = index.owner(of: session) {
                filed[owner].append(session)
            } else {
                ungrouped.append(session)
            }
        }

        var result = workspaces.indices.map {
            HermesSidebarSection(workspace: workspaces[$0], sessions: newestFirst(filed[$0]))
        }
        if !ungrouped.isEmpty {
            result.append(HermesSidebarSection(workspace: nil, sessions: newestFirst(ungrouped)))
        }
        return result
    }

    /// A session with no timestamp sorts last: an unknown time is not a recent one.
    private static func newestFirst(_ sessions: [HermesSessionSummary])
        -> [HermesSessionSummary]
    {
        sessions.sorted { lhs, rhs in
            switch (lhs.updatedAt, rhs.updatedAt) {
            case (let left?, let right?): return left > right
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.id < rhs.id
            }
        }
    }
}

/// Folder path -> the project owning it, matched by the longest ancestor of a session's cwd.
private struct FolderIndex {
    private let owners: [String: Int]

    init(workspaces: [HermesWorkspace]) {
        var owners: [String: Int] = [:]
        for (project, workspace) in workspaces.enumerated() {
            for folder in workspace.folders {
                let key = HermesWorkspace.normalizedPath(folder)
                guard !key.isEmpty else { continue }
                // Two projects may claim one folder; the first listed keeps it, as Hermes does.
                if owners[key] == nil { owners[key] = project }
            }
        }
        self.owners = owners
    }

    /// The project owning a session, matched on its cwd or on the git root Hermes recorded.
    ///
    /// Both are tried because a project holds folders rather than one checkout, and Hermes files a
    /// session under whichever of the two matches. A session run in the project's own root matches
    /// on
    /// the cwd; one run in a second folder of the project matches on the root. The deeper match
    /// wins,
    /// so a session inside a nested project stays with the nested one.
    func owner(of session: HermesSessionSummary) -> Int? {
        let candidates = [session.cwd, session.repoRoot].filter { !$0.isEmpty }
        return candidates.compactMap { match($0) }.max { $0.depth < $1.depth }?.project
    }

    /// The project owning the longest ancestor of `path`, with that ancestor's depth.
    ///
    /// Walks the path's own components rather than using `hasPrefix`, which would file
    /// `/Users/tony/github` under a project rooted at `/Users/tony/git`.
    private func match(_ path: String) -> (project: Int, depth: Int)? {
        let normalized = HermesWorkspace.normalizedPath(path)
        guard !normalized.isEmpty else { return nil }
        let components = normalized.split(separator: "/")
        for end in stride(from: components.count, through: 1, by: -1) {
            let candidate = "/" + components[0..<end].joined(separator: "/")
            if let project = owners[candidate] { return (project, end) }
        }
        return nil
    }
}
