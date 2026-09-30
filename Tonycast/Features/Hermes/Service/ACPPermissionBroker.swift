import Foundation

/// Decides which permission options the user is actually offered.
///
/// The agent builds the option list and sends it in the request, so this cannot add options — it can
/// only narrow them. The policy: a command classified destructive never gets a session-scoped grant
/// (`allow_session` / `allow_always`), even when the agent offers one, and Deny is the default.
/// Everything else keeps the full range so routine work does not prompt forever.
///
/// Two honest limits, both load-bearing:
///
/// 1. This is a blocklist, and blocklists of shell syntax are unbounded. `rm --recursive --force`,
///    a command assembled in a variable, and `find . -exec rm -rf {} +` all defeat substring
///    matching. Treat a non-match as "not obviously destructive", never as "verified safe".
/// 2. The command is read from the `$ <command>` line the agent prints. When no such line can be
///    recovered, the request is treated as destructive, because a missing command must not be the
///    path to a lasting grant.
struct ACPPermissionBroker: Sendable {
    struct Verdict: Sendable {
        let options: [ACPClient.PermissionOption]
        let isDestructive: Bool
        /// The option to preselect. Never a session-scoped grant on a destructive command.
        let recommended: String?
        /// True when no command could be recovered, so the verdict rests on absence, not matching.
        let isUnverified: Bool
    }

    /// Option ids worth asking about again even if the agent marks them session-scoped.
    private static let sessionScopedIDs: Set<String> = ["allow_session", "allow_always"]

    /// Patterns that mean "this can destroy something you cannot get back".
    private static let destructivePatterns: [String] = [
        // --- deletion ---
        "rm -rf", "rm -fr", "rm -r", "rm --recursive", "rm -f -r", "rm -f --recursive",
        "sudo rm", "unlink ", "shred ", "srm ", "find ", "-delete", "-exec rm",
        // --- disks and filesystems ---
        "mkfs", "wipefs", "blkdiscard", "dd if=", "dd of=", "fdisk", "parted ",
        "diskutil erase", "diskutil apfs delete", "diskutil unmount force",
        "zpool destroy", "zfs destroy", "zfs rollback",
        // --- overwrite in place ---
        "> /dev/disk", "> ~/.zshrc", "> ~/.ssh/", "cp /dev/null", ": > ",
        "tee /dev/disk", "truncate ",
        // --- history and git destruction ---
        "git reset --hard", "git clean -fd", "git clean -fdx", "git clean -f",
        "git push --force", "git push -f", "git filter-branch", "git rebase -i",
        "git branch -D", "git branch -d", "git stash clear", "git stash drop",
        "git reflog expire", "git gc --prune", "git checkout .", "git restore .",
        // --- databases ---
        "drop database", "drop table", "drop schema", "truncate table", "delete from",
        "flushall", "flushdb", "dropdatabase",
        // --- services and packages ---
        "launchctl unload", "launchctl bootout", "launchctl remove",
        "systemctl disable", "systemctl stop", "killall ", "pkill", "kill -9",
        "shutdown", "reboot", "halt", "poweroff",
        "npm publish", "yarn publish", "pnpm publish", "cargo publish", "gem push",
        "twine upload", "pip uninstall", "pip3 uninstall",
        "brew uninstall", "apt purge", "apt remove", "dnf remove", "pacman -Rs",
        "docker rm -f", "docker volume rm", "docker system prune", "kubectl delete",
        // --- permissions, ownership, fork bombs ---
        "chmod -R 777", "chmod 777", "chown -R", "chown ",
        ":(){", "(){ :|:&", "bomb()",
    ]

    func evaluate(_ request: ACPClient.PermissionRequest) -> Verdict {
        let command = Self.commandLine(of: request)
        // No recoverable command means the verdict cannot rest on matching, so it fails safe.
        let isUnverified = command == nil
        // Only the recovered command is matched. Falling back to the title and detail would classify
        // prose about a command, and every pattern below is a substring of ordinary English.
        let haystack = (command ?? "").lowercased()
        // Both sides are normalized: the patterns carry uppercase flags (`-R`, `-fdx`), so matching
        // them against a lowercased haystack would silently never fire.
        let destructive =
            isUnverified
            || Self.destructivePatterns.contains { haystack.contains($0.lowercased()) }

        let options: [ACPClient.PermissionOption]
        if destructive {
            // Strip every persistent grant. `allow_once` and `deny` survive; a deny-once is also
            // kept when offered, because "never again this session" is still not a lasting grant.
            options = request.options.filter { !Self.sessionScopedIDs.contains($0.optionID) }
        } else {
            options = request.options
        }

        // A narrowed list must never come back empty, or the sheet would have no way to answer.
        // The fallback is built from the agent's non-persistent ids only — falling back to the full
        // list would re-offer exactly the session grants that were just stripped.
        let usable = options.isEmpty ? Self.safeFallback(from: request.options) : options
        // Never a session-scoped grant by default: when the agent offers only a persistent allow and
        // a deny, the first element is the grant, and preselection is what the sheet acts on.
        let recommended = destructive ? nil : Self.recommendedOption(in: usable)

        return Verdict(
            options: usable, isDestructive: destructive, recommended: recommended,
            isUnverified: isUnverified)
    }

    /// The option to preselect, from the non-persistent range only.
    ///
    /// `allow_once` first, then a deny, then anything not session-scoped. A deny is preferred over
    /// the agent's own first option because that first option is the grant when no allow-once came.
    private static func recommendedOption(in options: [ACPClient.PermissionOption]) -> String? {
        options.first { $0.optionID == "allow_once" }?.optionID
            ?? options.first { $0.kind.hasPrefix("reject") }?.optionID
            ?? options.first { !sessionScopedIDs.contains($0.optionID) }?.optionID
    }

    /// The `$ <command>` line the agent prints with a permission request, if it sent one.
    ///
    /// Matching this instead of the whole payload is the difference between classifying a command and
    /// classifying prose about it: a title reading "this does not run rm -rf" must not decide it.
    private static func commandLine(of request: ACPClient.PermissionRequest) -> String? {
        let lines = request.detail
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var commands: [String] = []
        var index = 0
        while index < lines.count {
            guard lines[index].hasPrefix("$ ") else {
                index += 1
                continue
            }
            // A `\`-continued command keeps its arguments on lines that carry no `$ ` prefix.
            // Reading only the first line classifies `rm \` as harmless, which fails open.
            var command = String(lines[index].dropFirst(2))
            while command.hasSuffix("\\"), index + 1 < lines.count {
                index += 1
                // The backslash leaves a trailing space, so collapse it before joining — two spaces
                // is what stops `rm -rf` from matching.
                command = String(command.dropLast()).trimmingCharacters(in: .whitespaces)
                    + " " + lines[index]
            }
            if !command.isEmpty { commands.append(command) }
            index += 1
        }
        guard !commands.isEmpty else { return nil }
        return commands.joined(separator: "\n")
    }

    /// Only the non-persistent ids, so a fallback can never hand back a session-scoped grant.
    private static func safeFallback(
        from options: [ACPClient.PermissionOption]
    ) -> [ACPClient.PermissionOption] {
        let safe = options.filter { !sessionScopedIDs.contains($0.optionID) }
        if !safe.isEmpty { return safe }
        // The agent offered nothing but persistent grants; a local deny is always answerable.
        return [
            ACPClient.PermissionOption(optionID: "deny", name: "Deny", kind: "reject_once")
        ]
    }
}
