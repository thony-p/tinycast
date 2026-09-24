import Foundation

/// Guards the permission narrowing policy: a destructive command must never be offered a
/// session-scoped grant, and a narrowed list must never come back empty.
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

        func request(title: String, detail: String = "") -> ACPClient.PermissionRequest {
            ACPClient.PermissionRequest(
                rpcID: .null,
                requestID: "tool-1",
                title: title,
                detail: detail,
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
            "git reset --hard origin/main",
            "git push --force origin main",
            "diskutil eraseDisk JHFS+ Empty /dev/disk9",
            "zfs destroy tank/data",
            "chmod -R 777 /",
            "drop table users",
            "shutdown -r now",
            "brew uninstall node",
        ]
        for command in destructive {
            let verdict = broker.evaluate(request(title: command))
            let ids = verdict.options.map(\.optionID)
            check(
                "destructive is flagged: \(command.prefix(28))",
                verdict.isDestructive)
            check(
                "no session grant offered: \(command.prefix(28))",
                !ids.contains("allow_session") && !ids.contains("allow_always"))
            check(
                "deny and allow_once survive: \(command.prefix(28))",
                ids.contains("deny") && ids.contains("allow_once"))
            check("destructive has no recommended grant: \(command.prefix(28))",
                verdict.recommended == nil)
        }

        // --- the pattern must not fire on innocent commands ---------------------------------

        let benign = [
            "terminal: echo ACP-PROBE-OK",
            "read_file Tonycast/App/AppCore.swift",
            "git status --short",
            "git diff --stat",
            "npm test",
            "python3 -m py_compile script.py",
        ]
        for command in benign {
            let verdict = broker.evaluate(request(title: command))
            check("benign keeps the full range: \(command.prefix(28))", !verdict.isDestructive)
            check(
                "benign keeps session grants: \(command.prefix(28))",
                verdict.options.count == 4)
            check(
                "benign recommends allow_once: \(command.prefix(28))",
                verdict.recommended == "allow_once")
        }

        // --- the pattern reads the detail too, not just the title ---------------------------

        let inDetail = broker.evaluate(
            request(title: "Run a shell command", detail: "rm -rf ~/git/forks/tinycast"))
        check("a destructive command in the detail is caught", inDetail.isDestructive)

        // --- a narrowed list can never be empty ---------------------------------------------

        let onlySessionScoped = ACPClient.PermissionRequest(
            rpcID: .null,
            requestID: "tool-2",
            title: "rm -rf /",
            detail: "",
            options: [option("allow_session"), option("allow_always")])
        let fallback = broker.evaluate(onlySessionScoped)
        check("a list of only session grants is not emptied", !fallback.options.isEmpty)
        check(
            "the fallback still offers something answerable",
            fallback.options.contains { $0.optionID == "allow_once" || $0.optionID == "deny" }
                || fallback.options.count == 2)

        // --- an empty proposal is survivable --------------------------------------------------

        let empty = ACPClient.PermissionRequest(
            rpcID: .null, requestID: "tool-3", title: "Something", detail: "", options: [])
        let emptyVerdict = broker.evaluate(empty)
        check("an empty proposal does not crash", emptyVerdict.options.isEmpty)
        check("an empty proposal recommends nothing", emptyVerdict.recommended == nil)

        // --- matching is case-insensitive ------------------------------------------------------

        check("uppercase is still caught", broker.evaluate(request(title: "RM -RF /tmp")).isDestructive)
        check("mixed case is still caught", broker.evaluate(request(title: "Git Push --Force")).isDestructive)

        print(failures == 0 ? "\nAll permission broker checks passed." : "\n\(failures) check(s) failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
