import Foundation

/// Guards where a Tonycast ACP session is filed inside Hermes' own sidebar.
///
/// Hermes' desktop frontend and its backend disagree about a session whose cwd is the user's home
/// directory: the backend files it under Home, but the frontend computes a project id that does not
/// exist, so the row renders in **neither** a project lane nor Home. It stays reachable through
/// search, which is exactly the reported symptom. Only an EMPTY cwd satisfies both sides.
///
/// So this harness pins two things: the default session directory is empty, and the label the
/// window shows matches the placement the user will see in Hermes. The process launch directory is
/// a separate value and must never leak into the session cwd, or the bug returns.
@main
@MainActor
struct HermesPlacementTest {
    static func main() {
        var failures = 0

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        func makeSettings() -> HermesSettings {
            let suite = "com.tonycast.app.hermes-placement-test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return HermesSettings(defaults: defaults)
        }

        let settings = makeSettings()

        check("a fresh install files sessions in Home (empty cwd)",
              settings.sessionDirectory.isEmpty)

        check("the process still launches in a real directory",
              !settings.launchDirectory.isEmpty)

        check("launch directory defaults to home, not the session cwd",
              settings.launchDirectory == HermesSettings.homeDirectory)

        // The exact bug: a home-directory cwd is the value that falls between the backend's Home
        // bucket and the frontend's project bucket. It must never be the session default again.
        check("the session default is never the home directory",
              settings.sessionDirectory != HermesSettings.homeDirectory)

        let manager = ACPSessionManager(settings: settings)
        check("an empty session directory is labelled Home",
              manager.sessionLocationLabel == "Home")
        check("the Home label does not mention a path separator",
              !manager.sessionLocationLabel.contains("/"))

        settings.sessionDirectory = "/Users/tony/git/forks/tinycast"
        check("a real directory is labelled by its last component",
              manager.sessionLocationLabel == "tinycast")

        settings.sessionDirectory = "/Users/tony/git/"
        check("a trailing slash does not produce an empty label",
              manager.sessionLocationLabel == "git")

        // Placement and launch are independent: choosing a session directory must not move the
        // process, and vice versa.
        let launchBefore = settings.launchDirectory
        settings.sessionDirectory = "/tmp"
        check("changing the session directory leaves the launch directory alone",
              settings.launchDirectory == launchBefore)

        let sessionBefore = settings.sessionDirectory
        settings.launchDirectory = "/tmp"
        check("changing the launch directory leaves the session directory alone",
              settings.sessionDirectory == sessionBefore)

        check("a session directory is persisted, not recomputed on read",
              settings.sessionDirectory == "/tmp")

        // Two real defects the glm-5.3 review caught, both with a proven failure.
        check("a trailing slash still reattaches (plain equality would reject it)",
              HermesSettings.isSameDirectory("/Users/tony/git", "/Users/tony/git/"))

        check("a tilde spelling still reattaches",
              HermesSettings.isSameDirectory("~/git", HermesSettings.homeGitDirectory))

        check("a symlinked spelling still reattaches",
              HermesSettings.isSameDirectory("/tmp", "/private/tmp"))

        check("interior dot segments still reattach",
              HermesSettings.isSameDirectory("/Users/tony/git/./forks", "/Users/tony/git/forks"))

        check("genuinely different directories do NOT reattach",
              !HermesSettings.isSameDirectory("/Users/tony/git", "/Users/tony/workspace"))

        check("empty matches empty (the Home session case)",
              HermesSettings.isSameDirectory("", ""))

        check("empty never matches a real directory",
              !HermesSettings.isSameDirectory("", "/Users/tony"))

        // A launch into a missing directory throws and the app never connects, so the getter
        // must not hand Process a dead path.
        let badSettings = makeSettings()
        badSettings.launchDirectory = "/Users/tony/definitely-does-not-exist-xyz"
        check("a nonexistent launch directory falls back to home",
              badSettings.launchDirectory == HermesSettings.homeDirectory)

        badSettings.launchDirectory = "relative/path"
        check("a relative launch directory falls back to home",
              badSettings.launchDirectory == HermesSettings.homeDirectory)

        badSettings.launchDirectory = "/tmp"
        check("a real launch directory is honoured",
              badSettings.launchDirectory == "/tmp")

        badSettings.launchDirectory = ""
        check("an empty launch directory falls back to home",
              badSettings.launchDirectory == HermesSettings.homeDirectory)

        check("a file is not a usable directory",
              !HermesSettings.isUsableDirectory("/etc/hosts"))

        check("an existing directory is usable",
              HermesSettings.isUsableDirectory("/tmp"))

        // Reattach policy: the id is only reusable when the directory is unchanged.
        let reattach = makeSettings()
        check("no saved session means no reattach",
              !reattach.canReattach(to: ""))

        reattach.savedSessionID = "session-1"
        reattach.savedSessionCwd = "/Users/tony/git/"
        check("a saved session reattaches across a trailing-slash difference",
              reattach.canReattach(to: "/Users/tony/git"))

        check("a saved session does not reattach into a different directory",
              !reattach.canReattach(to: "/Users/tony/workspace"))

        reattach.savedSessionCwd = ""
        check("an empty saved cwd reattaches to an empty cwd",
              reattach.canReattach(to: ""))

        // sessionDirectory is validated too: a dead path must fall back to Home, not mint a
        // project for a directory that is not there.
        let dirSettings = makeSettings()
        dirSettings.sessionDirectory = "/Users/tony/definitely-does-not-exist-xyz"
        check("a dead session directory falls back to Home",
              dirSettings.sessionDirectory.isEmpty)

        dirSettings.sessionDirectory = "   "
        check("a whitespace-only session directory falls back to Home",
              dirSettings.sessionDirectory.isEmpty)

        dirSettings.sessionDirectory = "relative/path"
        check("a relative session directory falls back to Home",
              dirSettings.sessionDirectory.isEmpty)

        dirSettings.sessionDirectory = "/tmp"
        check("a real session directory is honoured",
              dirSettings.sessionDirectory == "/tmp")

        // Symlinked spellings of one directory must compare equal, or a reattach silently
        // discards a perfectly good session. Both sides are always existing directories —
        // `sessionDirectory` validates that — so the nested case is created, not imagined.
        let linkRoot = "/Users/tony/git/Temp/reattach-link-probe"
        try? FileManager.default.createDirectory(
            atPath: linkRoot + "/real/nested", withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: linkRoot + "/link")
        try? FileManager.default.createSymbolicLink(
            atPath: linkRoot + "/link", withDestinationPath: linkRoot + "/real")

        check("a symlinked spelling still reattaches",
              HermesSettings.isSameDirectory(linkRoot + "/link", linkRoot + "/real"))

        check("a nested symlinked spelling still reattaches",
              HermesSettings.isSameDirectory(linkRoot + "/link/nested", linkRoot + "/real/nested"))

        check("a symlinked spelling does not collide with a real sibling",
              !HermesSettings.isSameDirectory(linkRoot + "/link/nested", linkRoot + "/real"))

        try? FileManager.default.removeItem(atPath: linkRoot)

        // APFS is case-insensitive: a capitalisation change names the same directory, so a
        // string compare would throw away a reattachable session.
        check("a differently-cased spelling of one directory matches",
              HermesSettings.isSameDirectory("/Users/tony/git", "/USERS/TONY/GIT"))

        check("case folding does not merge different directories",
              !HermesSettings.isSameDirectory("/Users/tony/git", "/Users/tony/workspace"))

        // The two validators must agree about what a directory is, or reattach accepts a cwd
        // that can never be opened.
        check("a tilde path is usable (validators agree)",
              HermesSettings.isUsableDirectory("~/git"))
        check("a tilde path that does not exist is not usable",
              !HermesSettings.isUsableDirectory("~/definitely-not-here-xyz"))
        check("a tilde spelling compares equal to its expansion",
              HermesSettings.isSameDirectory("~/git", HermesSettings.homeGitDirectory))

        // Empty is the Home session and must never collapse into a real directory.
        check("an empty cwd is not the same as a real directory, case-insensitively",
              !HermesSettings.isSameDirectory("", HermesSettings.homeDirectory))
        check("an empty cwd never matches the process working directory",
              !HermesSettings.isSameDirectory("", FileManager.default.currentDirectoryPath))

        // Setters store trimmed values, so raw storage matches what the app reads.
        let trimSettings = makeSettings()
        trimSettings.sessionDirectory = "  /tmp  "
        check("a padded session directory is stored trimmed",
              trimSettings.sessionDirectory == "/tmp")
        trimSettings.launchDirectory = "  /tmp  "
        check("a padded launch directory is stored trimmed",
              trimSettings.launchDirectory == "/tmp")

        // A stored tilde must come back EXPANDED: neither Process nor the agent expands a `~`,
        // so returning it raw would launch or create a session in a literal "~" directory.
        let tildeSettings = makeSettings()
        tildeSettings.sessionDirectory = "~/git"
        check("a tilde session directory is returned expanded",
              tildeSettings.sessionDirectory == HermesSettings.homeGitDirectory)
        check("an expanded tilde session directory is absolute",
              (tildeSettings.sessionDirectory as NSString).isAbsolutePath)

        tildeSettings.launchDirectory = "~/git"
        check("a tilde launch directory is returned expanded",
              tildeSettings.launchDirectory == HermesSettings.homeGitDirectory)

        // A relative path must never be treated as a directory, or URL silently roots it at the
        // process cwd and reattach could match an unrelated directory.
        check("a relative path never matches an absolute one",
              !HermesSettings.isSameDirectory("git", "/git"))
        check("a relative path does not match the process working directory",
              !HermesSettings.isSameDirectory(
                "git", FileManager.default.currentDirectoryPath))
        check("two relative paths do not match each other",
              !HermesSettings.isSameDirectory("git", "git"))
        check("standardizedPath returns empty for a relative path",
              HermesSettings.standardizedPath("relative/path").isEmpty)

        // An empty id is not a session to reattach to.
        let emptyId = makeSettings()
        emptyId.savedSessionID = ""
        emptyId.savedSessionCwd = ""
        check("an empty saved session id does not reattach",
              !emptyId.canReattach(to: ""))

        emptyId.savedSessionID = "session-2"
        emptyId.savedSessionCwd = "  /tmp  "
        check("a padded saved cwd still reattaches",
              emptyId.canReattach(to: "/tmp"))

        // executablePath is the one path setting a user types by hand, so it follows the same
        // contract. Unset by default, and clearing it must not leave an empty string behind.
        let execSettings = makeSettings()
        check("executablePath is unset by default", execSettings.executablePath == nil)
        execSettings.executablePath = "~/bin/hermes"
        check("a tilde executable path is returned expanded",
              execSettings.executablePath == (HermesSettings.homeDirectory as NSString)
                .appendingPathComponent("bin/hermes"))
        execSettings.executablePath = "  hermes  "
        check("a bare command name still resolves after trimming",
              execSettings.executablePath == "hermes")
        execSettings.executablePath = "   "
        check("clearing executablePath stores nil, not an empty string",
              execSettings.executablePath == nil)

        if failures == 0 {
            print("\nAll Hermes placement checks passed.")
        } else {
            print("\n\(failures) Hermes placement check(s) failed.")
            exit(1)
        }
    }
}
