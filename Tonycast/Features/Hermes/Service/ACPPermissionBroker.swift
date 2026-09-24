import Foundation

/// Decides which permission options the user is actually offered.
///
/// The agent builds the option list and sends it in the request, so this cannot add options — it can
/// only narrow them. The policy: a command classified destructive never gets a session-scoped grant
/// (`allow_session` / `allow_always`), even when the agent offers one, and Deny is the default.
/// Everything else keeps the full range so routine work does not prompt forever.
struct ACPPermissionBroker: Sendable {
    struct Verdict: Sendable {
        let options: [ACPClient.PermissionOption]
        let isDestructive: Bool
        /// The option to preselect. Never a session-scoped grant on a destructive command.
        let recommended: String?
    }

    /// Option ids worth asking about again even if the agent marks them session-scoped.
    private static let sessionScopedIDs: Set<String> = ["allow_session", "allow_always"]

    /// Patterns that mean "this can destroy something you cannot get back".
    private static let destructivePatterns: [String] = [
        "rm -rf", "rm -fr", "rm -r ", "sudo rm", "mkfs", "dd if=", "dd of=",
        "diskutil erase", "diskutil apfs delete", "zpool destroy", "zfs destroy",
        ":(){", "chmod -R 777", "chown -R", "> /dev/disk", "shred ",
        "git reset --hard", "git clean -fd", "git clean -fdx", "git push --force",
        "git push -f", "git filter-branch", "git rebase -i",
        "drop database", "drop table", "truncate table", "delete from",
        "launchctl unload", "killall ", "pkill -9", "shutdown ", "reboot",
        "npm publish", "brew uninstall", "pip uninstall",
    ]

    func evaluate(_ request: ACPClient.PermissionRequest) -> Verdict {
        let haystack = "\(request.title)\n\(request.detail)".lowercased()
        // Both sides are normalized: the patterns carry uppercase flags (`-R`, `-fdx`), so matching
        // them against a lowercased haystack would silently never fire.
        let destructive = Self.destructivePatterns.contains {
            haystack.contains($0.lowercased())
        }

        let options: [ACPClient.PermissionOption]
        if destructive {
            // Strip every persistent grant. `allow_once` and `deny` survive; a deny-once is also
            // kept when offered, because "never again this session" is still not a lasting grant.
            options = request.options.filter { !Self.sessionScopedIDs.contains($0.optionID) }
        } else {
            options = request.options
        }

        // A narrowed list must never come back empty, or the sheet would have no way to answer.
        let usable = options.isEmpty ? request.options : options
        let recommended =
            destructive
            ? nil
            : usable.first { $0.optionID == "allow_once" }?.optionID ?? usable.first?.optionID

        return Verdict(options: usable, isDestructive: destructive, recommended: recommended)
    }
}
