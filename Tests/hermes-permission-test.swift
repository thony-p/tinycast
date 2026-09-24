import Foundation

/// Guards the permission narrowing policy: a destructive command must never be offered a
/// session-scoped grant, and a narrowed list must never come back empty or re-offer one.
///
/// The broker is the only thing standing between "the agent asked for allow_always" and a lasting
/// grant on `rm -rf`, so every branch here is a decision worth pinning down.
@main
struct HermesPermissionBrokerTest {
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

        func option(_ id: String) -> ACPClient.PermissionOption {
            ACPClient.PermissionOption(optionID: id, name: id, kind: "allow_always")
        }

        /// Mirrors what the agent actually sends: a title, and a detail whose last line is
        /// `$ <command>`.
        func request(title: String, command: String? = nil) -> ACPClient.PermissionRequest {
            let detail = command.map { "\(title)\n$ \($0)" } ?? title
            return ACPClient.PermissionRequest(
                rpcID: .null,
                requestID: "tool-1",
                title: title,
                detail: detail,
                options: [
                    option("allow_once"), option("allow_session"), option("allow_always"),
                    option("deny"),
                ])
        }

        func requestNoCommand(title: String, detail: String) -> ACPClient.PermissionRequest {
            ACPClient.PermissionRequest(
                rpcID: .null, requestID: "tool-nc", title: title, detail: detail,
                options: [
                    option("allow_once"), option("allow_session"), option("allow_always"),
                    option("deny"),
                ])
        }

        let broker = ACPPermissionBroker()

        // --- destructive commands lose every persistent grant -------------------------------

        let destructive = [
            "rm -rf /tmp/scratch",
            "sudo rm -rf ~/Library",
            "rm --recursive --force build",
            "find / -name foo -delete",
            "git reset --hard origin/main",
            "git push --force origin main",
            "git branch -D feature",
            "diskutil eraseDisk JHFS+ Empty /dev/disk9",
            "wipefs -a /dev/sda",
            "zfs destroy tank/data",
            "chmod -R 777 /",
            "chown -R root /",
            "drop table users",
            "shutdown -r now",
            "brew uninstall node",
            "pip3 uninstall requests",
            "docker system prune -af",
            "> ~/.zshrc",
            "rsync -a --delete src/ dst/",
        ]
        for command in destructive {
            let verdict = broker.evaluate(request(title: "Run a shell command", command: command))
            let ids = verdict.options.map(\.optionID)
            check("destructive is flagged: \(command.prefix(30))", verdict.isDestructive)
            check(
                "no session grant offered: \(command.prefix(30))",
                !ids.contains("allow_session") && !ids.contains("allow_always"))
            check(
                "deny and allow_once survive: \(command.prefix(30))",
                ids.contains("deny") && ids.contains("allow_once"))
            check("destructive has no recommended grant: \(command.prefix(30))",
                verdict.recommended == nil)
        }

        // --- the pattern must not fire on innocent commands ---------------------------------

        let benign = [
            "echo ACP-PROBE-OK",
            "git status --short",
            "git diff --stat",
            "npm test",
            "python3 -m py_compile script.py",
            "ls -la ~/git",
            "cat package.json",
        ]
        for command in benign {
            let verdict = broker.evaluate(request(title: "Run a shell command", command: command))
            check("benign keeps the full range: \(command.prefix(30))", !verdict.isDestructive)
            check("benign keeps session grants: \(command.prefix(30))", verdict.options.count == 4)
            check("benign recommends allow_once: \(command.prefix(30))",
                verdict.recommended == "allow_once")
        }

        // --- prose about a command must not decide the verdict ------------------------------

        // The old implementation matched the title as well, so a reassuring description of a
        // destructive command slipped through and kept its session grants.
        let misdescribed = requestNoCommand(
            title: "Clean build artifacts", detail: "Removes generated files.\n$ rm -rf build/")
        check("a destructively-described-but-mis-titled command is caught",
            broker.evaluate(misdescribed).isDestructive)

        // And the inverse must hold: prose naming a destructive command, with no command line,
        // is treated as unverified and therefore destructive rather than safe.
        let proseOnly = requestNoCommand(
            title: "Check the repo", detail: "This does not run rm -rf anywhere.")
        check("prose without a command line is treated as unverified",
            broker.evaluate(proseOnly).isUnverified)

        // --- an unverifiable request fails safe ----------------------------------------------

        let noCommand = requestNoCommand(title: "Do something", detail: "No command shown here.")
        let noCommandVerdict = broker.evaluate(noCommand)
        check("a request with no command is destructive", noCommandVerdict.isDestructive)
        check("a request with no command strips session grants",
            !noCommandVerdict.options.map(\.optionID).contains("allow_session"))

        // --- a narrowed list can never be empty, nor re-offer a session grant ---------------

        let onlySessionScoped = ACPClient.PermissionRequest(
            rpcID: .null,
            requestID: "tool-2",
            title: "rm -rf /",
            detail: "Run a shell command\n$ rm -rf /",
            options: [option("allow_session"), option("allow_always")])
        let fallback = broker.evaluate(onlySessionScoped)
        check("a list of only session grants is not emptied", !fallback.options.isEmpty)
        check(
            "the fallback never re-offers a session grant",
            !fallback.options.map(\.optionID).contains { $0 == "allow_session" || $0 == "allow_always" }
        )
        check("the fallback offers a real deny", fallback.options.map(\.optionID).contains("deny"))

        // --- an empty proposal is survivable --------------------------------------------------

        let empty = ACPClient.PermissionRequest(
            rpcID: .null, requestID: "tool-3", title: "Something", detail: "", options: [])
        let emptyVerdict = broker.evaluate(empty)
        // An unanswerable request still has to be answerable: deny is synthesized locally.
        check("an empty proposal does not crash", !emptyVerdict.options.isEmpty)
        check("an empty proposal offers a deny", emptyVerdict.options.map(\.optionID).contains("deny"))
        check("an empty proposal recommends nothing", emptyVerdict.recommended == nil)

        // --- matching is case-insensitive ------------------------------------------------------

        check("uppercase is caught",
            broker.evaluate(request(title: "Run", command: "RM -RF /tmp")).isDestructive)
        check("mixed case is caught",
            broker.evaluate(request(title: "Run", command: "Git Push --Force")).isDestructive)

        print(failures == 0 ? "\nAll permission broker checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
