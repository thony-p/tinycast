import Foundation
import Observation

/// Hermes-specific settings: which executable to launch, where sessions open, and the remembered
/// session id. Persisted under the app's own UserDefaults domain alongside every other setting.
@MainActor
@Observable
final class HermesSettings {
    /// Project roots a new session may open in. Defaults to the same tree the desktop app scans.
    var projectRoots: [String] {
        didSet { defaults.set(projectRoots, forKey: Key.projectRoots.rawValue) }
    }

    /// The directory a new session is created in. Empty by default, and empty is meaningful: a
    /// session with no cwd is one Hermes files under **Home** in its own sidebar, which is what a
    /// launcher chat is. A dead or relative path falls back to empty rather than minting a project
    /// for a directory that is not there.
    var sessionDirectory: String {
        get { Self.usablePath(defaults.string(forKey: Key.sessionDirectory.rawValue) ?? "") ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            defaults.set(trimmed, forKey: Key.sessionDirectory.rawValue)
        }
    }

    /// Where the `hermes acp` process itself starts. A launch into a missing directory fails
    /// outright, so this falls back to home rather than handing `Process` a dead path.
    var launchDirectory: String {
        get {
            let stored = defaults.string(forKey: Key.launchDirectory.rawValue) ?? ""
            return Self.usablePath(stored) ?? Self.homeDirectory
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            defaults.set(trimmed, forKey: Key.launchDirectory.rawValue)
        }
    }

    /// Overrides `hermes` on PATH when the user installs it somewhere unusual. Trimmed and
    /// tilde-expanded like every other path here: a bare name is left alone, so PATH lookup works.
    var executablePath: String? {
        get {
            guard let raw = defaults.string(forKey: Key.executablePath.rawValue) else { return nil }
            return (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespaces)
            let value = trimmed?.isEmpty == true ? nil : trimmed
            defaults.set(value, forKey: Key.executablePath.rawValue)
        }
    }

    /// The ACP mode id sent after a session is created. `accept_edits` avoids a click per write.
    var sessionMode: String {
        get { defaults.string(forKey: Key.sessionMode.rawValue) ?? "accept_edits" }
        set { defaults.set(newValue, forKey: Key.sessionMode.rawValue) }
    }

    /// Remembered so a relaunch can reattach instead of starting over.
    var savedSessionID: String? {
        get { defaults.string(forKey: Key.savedSessionID.rawValue) }
        set { defaults.set(newValue, forKey: Key.savedSessionID.rawValue) }
    }

    /// A session's cwd is fixed at creation, so the id is only reusable for the same directory.
    var savedSessionCwd: String? {
        get { defaults.string(forKey: Key.savedSessionCwd.rawValue) }
        set { defaults.set(newValue, forKey: Key.savedSessionCwd.rawValue) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let roots = defaults.stringArray(forKey: Key.projectRoots.rawValue) ?? []
        self.projectRoots = roots.isEmpty ? [Self.homeGitDirectory] : roots
    }

    /// The roots a session picker offers, filtered to directories that still exist.
    var existingProjectRoots: [String] {
        projectRoots.filter { Self.isUsableDirectory($0) }
    }

    /// Whether a session may reattach to the remembered id. A session's cwd is fixed at creation,
    /// so resuming elsewhere would hand the agent a stale working root.
    func canReattach(to cwd: String) -> Bool {
        guard let id = savedSessionID, !id.isEmpty,
              let savedCwd = savedSessionCwd?.trimmingCharacters(in: .whitespaces) else {
            return false
        }
        return Self.isSameDirectory(savedCwd, cwd)
    }

    /// Compares directories, not strings: a trailing slash, a `~`, a `.` segment, a symlinked
    /// spelling or a different capitalisation all name the same directory, and plain equality calls
    /// every one of them different.
    static func isSameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        let leftRaw = (lhs.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        let rightRaw = (rhs.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        // A relative path is not a directory we can name, and URL would silently root it at the
        // process cwd — a false "same" here would reattach into an unrelated directory. The empty
        // cwd is the Home session and stays comparable.
        let leftIsPath = (leftRaw as NSString).isAbsolutePath
        let rightIsPath = (rightRaw as NSString).isAbsolutePath
        guard leftIsPath || leftRaw.isEmpty, rightIsPath || rightRaw.isEmpty else { return false }
        guard leftIsPath, rightIsPath else { return leftRaw.isEmpty && rightRaw.isEmpty }

        let left = standardizedPath(leftRaw)
        let right = standardizedPath(rightRaw)
        if let identity = fileIdentity(left), let other = fileIdentity(right) {
            return identity.isEqual(other)
        }
        return left == right
    }

    static func standardizedPath(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        let expanded = (path as NSString).expandingTildeInPath
        guard (expanded as NSString).isAbsolutePath else { return "" }
        // Symlinks resolve during traversal, so resolve before collapsing `..` — the reverse order
        // answers with a directory the kernel would never produce.
        return URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
    }

    /// Identity is case- and spelling-independent, which a path string is not: APFS is
    /// case-insensitive, so `/Users/tony/git` and `/USERS/TONY/GIT` are one directory.
    private static func fileIdentity(_ path: String) -> (any NSObjectProtocol)? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]),
              let identity = values.fileResourceIdentifier else { return nil }
        return identity
    }

    /// An absolute path that currently resolves to a directory — the only kind `Process` can
    /// launch into and the only kind worth offering in a picker.
    static func isUsableDirectory(_ path: String) -> Bool {
        usablePath(path) != nil
    }

    /// The expanded form of `path` when it is a directory that exists, else nil. Callers get the
    /// expanded path back because neither `Process` nor the agent expands a `~` themselves.
    static func usablePath(_ path: String) -> String? {
        let expanded = (path.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        guard !expanded.isEmpty, (expanded as NSString).isAbsolutePath else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return expanded
    }

    static var homeDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser.path
    }

    static var homeGitDirectory: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "git", directoryHint: .isDirectory).path
    }

    private enum Key: String {
        case projectRoots = "hermesProjectRoots"
        case sessionDirectory = "hermesSessionDirectory"
        case launchDirectory = "hermesLaunchDirectory"
        case executablePath = "hermesExecutablePath"
        case sessionMode = "hermesSessionMode"
        case savedSessionID = "hermesSavedSessionID"
        case savedSessionCwd = "hermesSavedSessionCwd"
    }
}
