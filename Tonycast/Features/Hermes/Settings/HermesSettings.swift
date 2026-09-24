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

    /// The cwd a new session is created with. Must be absolute, so it falls back to home.
    var defaultWorkingDirectory: String {
        get {
            let stored = defaults.string(forKey: Key.defaultWorkingDirectory.rawValue) ?? ""
            return stored.isEmpty ? Self.homeDirectory : stored
        }
        set { defaults.set(newValue, forKey: Key.defaultWorkingDirectory.rawValue) }
    }

    /// Overrides `hermes` on PATH when the user installs it somewhere unusual.
    var executablePath: String? {
        get { defaults.string(forKey: Key.executablePath.rawValue) }
        set { defaults.set(newValue, forKey: Key.executablePath.rawValue) }
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
        let roots = defaults.stringArray(forKey: Key.projectRoots.rawValue)
        self.projectRoots = roots?.isEmpty == false ? roots! : [Self.homeGitDirectory]
    }

    /// The roots a session picker offers, filtered to directories that still exist.
    var existingProjectRoots: [String] {
        projectRoots.filter { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
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
        case defaultWorkingDirectory = "hermesDefaultWorkingDirectory"
        case executablePath = "hermesExecutablePath"
        case sessionMode = "hermesSessionMode"
        case savedSessionID = "hermesSavedSessionID"
        case savedSessionCwd = "hermesSavedSessionCwd"
    }
}
