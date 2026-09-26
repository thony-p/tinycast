import Foundation

/// A named Hermes workspace, as Hermes' own sidebar shows it.
///
/// Read from the instance the window is attached to, because projects are not on the ACP wire:
/// `session/new` takes a working directory and nothing names a project. A project is therefore
/// something to *start a session in* — `startDirectory` is the cwd a new session gets — together
/// with
/// the folders whose sessions are filed under its name.
struct HermesWorkspace: Identifiable, Equatable, Sendable {
    let id: String
    let slug: String
    let name: String
    /// The folder a session started here opens in, empty when no folder on the host can be used.
    ///
    /// Decided **on the connected host**, not here: the folders belong to that machine's disk, so
    /// for
    /// the VM every path is absent from this Mac while being perfectly valid there. A session's cwd
    /// is
    /// fixed when it is created, so a directory known to be missing is never chosen.
    let startDirectory: String
    /// Every folder the project owns, primary first, each normalized for comparison.
    let folders: [String]

    init(id: String, slug: String, name: String, startDirectory: String, folders: [String]) {
        self.id = id
        self.slug = slug
        self.name = name
        self.startDirectory = startDirectory
        self.folders = folders
    }

    /// A path shape a session's cwd can be compared against: absolute, tilde-expanded, with `.`
    /// and `..` collapsed. Case is preserved, since a POSIX filesystem may be case-sensitive.
    ///
    /// A relative or empty path normalizes to `""`, which matches nothing: a session whose cwd
    /// is `.` or unset belongs to no project, not to whichever project happens to be around.
    static func normalizedPath(_ path: String) -> String {
        let expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !expanded.isEmpty, (expanded as NSString).isAbsolutePath else { return "" }
        // Lexical collapse, not symlink resolution: Hermes files the cwd it was given.
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
        return standardized.isEmpty ? "/" : standardized
    }

    /// The listing the host script prints, decoded.
    ///
    /// Tolerant by design: the script reads another application's data store, so a column that has
    /// been renamed or dropped must cost that field, not the whole pane. A row with no usable id or
    /// name is skipped rather than shown blank.
    ///
    /// `startDirectory` comes from the script, which resolves it against the **host's** disk. That
    /// is
    /// the only place the answer can be computed: for the VM every folder is absent from this Mac.
    static func decodeListing(_ data: Data) -> [HermesWorkspace] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["projects"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty,
                let name = row["name"] as? String, !name.isEmpty
            else { return nil }
            let folders = (row["folders"] as? [String] ?? []).map(normalizedPath).filter { !$0.isEmpty }
            return HermesWorkspace(
                id: id,
                slug: row["slug"] as? String ?? id,
                name: name,
                startDirectory: normalizedPath(row["startDirectory"] as? String ?? ""),
                folders: folders)
        }
    }
}
