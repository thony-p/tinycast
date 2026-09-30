import Foundation

/// Guards four defects found reviewing the Hermes client.
///
/// Each case fails against the code as it stood. Three are pinned deterministically; the fourth is a
/// wire behaviour, so it runs against the real agent when one is installed and says so when it is not
/// — a skipped case is reported rather than counted as a pass.
@main
@MainActor
struct HermesReviewTest {
    static func main() async {
        var failures = 0
        var skipped: [String] = []

        func check(_ description: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("PASS  \(description)")
            } else {
                print("FAIL  \(description)")
                failures += 1
            }
        }

        func skip(_ description: String, _ why: String) {
            print("SKIP  \(description) — \(why)")
            skipped.append(description)
        }

        func makeSettings() -> HermesSettings {
            let suite = "com.tonycast.app.hermes-review-test.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defaults.removePersistentDomain(forName: suite)
            return HermesSettings(defaults: defaults)
        }

        // MARK: - Issue 1: the session mode the settings promise is never applied

        // `session/new` answers with `modes.currentModeId`, and Hermes defaults that to `default`
        // ("Ask before edits"). The setting was documented as sent after a session was created, and
        // nothing ever sent it: measured on the wire, the session reported `default` while the setting
        // read `accept_edits`, so every file edit raised a prompt the setting claimed to have removed.
        //
        // The decision is pinned here rather than the call site: a session whose reported mode already
        // matches must not be sent a redundant request, and an agent that reports no mode at all is
        // left alone rather than guessed at.
        check(
            "the default session mode is one Hermes advertises",
            ["default", "accept_edits", "dont_ask"].contains(makeSettings().sessionMode))
        check(
            "a session reporting a different mode is corrected",
            ACPSessionManager.shouldApplyMode(reported: "default", wanted: "accept_edits"))
        check(
            "a session already in the wanted mode is left alone",
            !ACPSessionManager.shouldApplyMode(reported: "accept_edits", wanted: "accept_edits"))
        check(
            "an agent that reports no mode is not guessed at",
            !ACPSessionManager.shouldApplyMode(reported: nil, wanted: "accept_edits"))
        check(
            "an agent that reports an empty mode is not guessed at",
            !ACPSessionManager.shouldApplyMode(reported: "", wanted: "accept_edits"))

        // The reported mode has to be readable off the response, because assuming our own preference
        // won is what hid this defect.
        let withModes = JSONValue([
            "sessionId": "s1",
            "modes": [
                "currentModeId": "default",
                "availableModes": [["id": "default"], ["id": "accept_edits"]],
            ],
        ])
        check(
            "the session's reported mode is readable",
            ACPClient.reportedMode(from: withModes) == "default")
        check(
            "a response with no modes block reads as unknown, not as a default",
            ACPClient.reportedMode(from: JSONValue(["sessionId": "s1"])) == nil)
        check(
            "an empty mode id reads as unknown",
            ACPClient.reportedMode(from: JSONValue(["modes": ["currentModeId": ""]])) == nil)

        // MARK: - Issue 2: the loading flag is not cleared on every exit path

        // `refreshSidebar` set `isLoadingSidebar = true` then returned early when the connection
        // changed under it, leaving the flag set: the pane says "Reading sessions…" and never stops.
        // It is cleared with a `defer`, so the invariant is structural rather than a statement on the
        // happy path. This drives the real method against a live agent, because the early return only
        // happens after the two host reads, and a stubbed manager cannot reach it.
        let managerSettings = makeSettings()
        let manager = ACPSessionManager(settings: managerSettings)
        check("a fresh manager is not loading", !manager.isLoadingSidebar)
        // The guard path: a refresh with no ready status must leave nothing set.
        await manager.refreshSidebar()
        check("a refresh that could not run leaves no loading flag", !manager.isLoadingSidebar)

        if await ExecutableLocator.locate("hermes") == nil {
            skip("a host switch mid-read leaves no loading flag", "no hermes on PATH")
        } else {
            await manager.connect()
            if !manager.status.isReady {
                skip("a host switch mid-read leaves no loading flag", "the agent did not start")
            } else {
                // The real path: switch the setting while the reads are in flight, then await the
                // refresh. The guard fires, and the flag must still come back down.
                let switched = Task { await manager.refreshSidebar() }
                managerSettings.connection = .vm
                await switched.value
                check("a host switch mid-read leaves no loading flag", !manager.isLoadingSidebar)
                managerSettings.connection = .local
                await manager.disconnect()
            }
        }

        // MARK: - Issue 3: a deliberate stop can be reported as a crash

        // `intentionalStop` was set by `stop()` and cleared only in `didExit`. `stop()` also sets
        // `process = nil`, so `didExit` never ran again for that client and the flag stayed set. A
        // later launch then swallowed its own exit report, so a genuine crash after a relaunch showed
        // no reason at all. The state a stop leaves behind is put in place here, because that is the
        // bug: asserting a fresh client's flag proves nothing.
        let client = ACPClient(connection: .local, workingDirectory: NSHomeDirectory())
        await client.markStoppedIntentionally()
        let marked = await client.isStoppingIntentionally
        check("the client can be left in the state a stop produces", marked)
        // A launch must repair it, whatever else happens.
        do {
            try await client.start()
            let afterLaunch = await client.isStoppingIntentionally
            check("a relaunch clears the previous stop's mark", !afterLaunch)
            if await client.isRunning {
                let modes = await client.reportedMode
                check("a fresh process reports no session mode yet", modes == nil)
            }
            await client.stop()
        } catch {
            // No agent installed is not a failure of this invariant, only of the launch itself.
            print("SKIP  a relaunch clears the previous stop's mark — the agent did not start")
            skipped.append("relaunch clears the stop mark")
        }

        // MARK: - A directory is not an executable

        // `FileManager.isExecutableFile` answers true for a directory — X_OK on a directory is search
        // permission — so a path like `~/bin` passed the override check and `Process` was handed a
        // directory, failing with an opaque launch error instead of falling back to PATH. Measured:
        // isExecutableFile("/tmp/some/dir") == true.
        check(
            "a directory is not treated as the executable",
            !ACPClient.isUsableExecutable("/tmp", isDirectory: true, isExecutable: true))
        check(
            "an executable file is usable",
            ACPClient.isUsableExecutable("/opt/bin/hermes", isDirectory: false, isExecutable: true))
        check(
            "a non-executable file is not usable",
            !ACPClient.isUsableExecutable("/tmp/notes.txt", isDirectory: false, isExecutable: false))
        // A bare name is a PATH lookup, not a file in the process's working directory: resolving it as
        // `./hermes` would depend on wherever the app was launched from.
        check(
            "a bare command name is left to the PATH lookup",
            ACPClient.executableOverride(connection: .local, configured: "hermes") == nil)
        check(
            "an absolute path is honoured",
            ACPClient.executableOverride(connection: .local, configured: "/opt/bin/hermes")
                == "/opt/bin/hermes")
        check(
            "a relative path is not honoured as an override",
            ACPClient.executableOverride(connection: .local, configured: "./bin/hermes") == nil)

        // MARK: - Opening a session from the sidebar applies the configured mode too

        // `applyConfiguredMode` was added to `attachSession`'s two branches but not to
        // `loadContinuable`, which makes the identical `session/load` call for a session opened from
        // the sidebar. Same wire call, divergent treatment: reattach corrected the mode, sidebar-open
        // did not, so a session created elsewhere in `default` still prompted before every edit.
        check(
            "opening a continuable session corrects a mismatched mode",
            ACPSessionManager.shouldApplyMode(reported: "default", wanted: "accept_edits"))
        // Pinned at the source level, because the defect was a missing call site rather than a wrong
        // decision: every method that establishes a session must apply the mode. Read from the file so
        // a future path that loads a session without it fails here.
        // `attachSession` no longer names the mode itself: it routes both its branches through
        // `adoptSession`, which applies it. So the check is that every found method either applies the
        // mode or hands off to one that does — the handoff is the fix, and asserting only the direct
        // call would fail on the correct code.
        if let body = ACPSessionManager.sessionEstablishingMethodBodies() {
            check(
                "every method that establishes a session applies the mode, directly or by handoff",
                body.allSatisfy {
                    $0.contains("applyConfiguredMode") || $0.contains("adoptSession")
                })
            check("the three session-establishing methods were found", body.count >= 3)
            check(
                "exactly one method is the one that actually applies it",
                body.filter { $0.contains("applyConfiguredMode") }.count == 1)
        } else {
            print("SKIP  every session-establishing method applies the mode — source unreadable")
            skipped.append("session-establishing methods apply the mode")
        }

        // MARK: - Issue 4: a documented setting that nothing read

        // `executablePath` was persisted, validated and documented as overriding `hermes` on PATH, and
        // no code path consumed it. A setting the user can write and nothing reads looks like it works,
        // which is worse than not offering it.
        let override = "/opt/custom/bin/hermes"
        check(
            "an explicit executable path is preferred over the PATH lookup",
            ACPClient.executableOverride(connection: .local, configured: override) == override)
        check(
            "a whitespace-only path is not a path",
            ACPClient.executableOverride(connection: .local, configured: "   ") == nil)
        check(
            "no configured path means resolve on PATH",
            ACPClient.executableOverride(connection: .local, configured: nil) == nil)
        // The override names a local agent. The remote launch runs `ssh`, and a path to a local
        // `hermes` means nothing on the far host — honouring it there would break the VM connection.
        check(
            "a remote connection ignores a local executable path",
            ACPClient.executableOverride(connection: .vm, configured: override) == nil)

        // MARK: - Issue 1, end to end

        // The deterministic cases above pin the decision; this pins the behaviour it decides about,
        // which is what the user actually hit. It needs a real agent, so it is reported as skipped
        // rather than silently passing when one is absent.
        let settings = makeSettings()
        settings.connection = .local
        if await ExecutableLocator.locate("hermes") == nil {
            skip("a new session runs the mode the settings asked for", "no hermes on PATH")
        } else {
            let agent = ACPSessionManager(settings: settings)
            await agent.connect()
            if !agent.status.isReady {
                skip(
                    "a new session runs the mode the settings asked for",
                    "the agent did not start (\(agent.status.label))")
            } else {
                let reported = agent.reportedSessionMode
                check(
                    "the agent reports a mode at all",
                    reported != nil)
                check(
                    "the session runs the mode the setting named",
                    reported == settings.sessionMode)
                await agent.disconnect()
            }
        }

        // MARK: - Frame parsing: an id the reply can be addressed to

        // A bool bridges to NSNumber in Swift, and the request branch read it as an id — so an
        // answer would echo `"id": true`, which is not a legal JSON-RPC id. A null id on an error is
        // the spec's reply to an unreadable request; discarding it as `.invalid` lost the reason.
        func parse(_ json: String) -> ACPProtocol.Message {
            ACPProtocol.parse(Data(json.utf8))
        }
        func notificationMethod(_ message: ACPProtocol.Message) -> String? {
            if case .notification(let method, _) = message { return method }
            return nil
        }
        if case .nullIDError(let code, let text) = parse(
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}"#)
        {
            check("a null-id error keeps its code and message", code == -32700 && text == "Parse error")
        } else {
            check("a null-id error keeps its code and message", false)
        }
        if case .failure(let id, let code, let text) = parse(
            #"{"jsonrpc":"2.0","id":7,"error":{"code":-1,"message":"boom"}}"#)
        {
            check("a numeric-id error reads its id, code and message", id == 7 && code == -1
                && text == "boom")
        } else {
            check("a numeric-id error reads its id, code and message", false)
        }
        check("a bool id is not addressable, so it is not a request",
            notificationMethod(parse(#"{"jsonrpc":"2.0","id":true,"method":"foo"}"#)) == "foo")
        if case .request(let id, let method, _) = parse(
            #"{"jsonrpc":"2.0","id":"abc","method":"foo"}"#)
        {
            check("a string id is a legal request id, kept not dropped",
                id.stringValue == "abc" && method == "foo")
        } else {
            check("a string id is a legal request id, kept not dropped", false)
        }
        if case .request(let id, _, _) = parse(#"{"jsonrpc":"2.0","id":3,"method":"bar"}"#) {
            check("a numeric id is a request id", id.intValue == 3)
        } else {
            check("a numeric id is a request id", false)
        }
        if case .notification = parse(#"{"jsonrpc":"2.0","method":"bar"}"#) {
            check("a request with no id is a notification", true)
        } else {
            check("a request with no id is a notification", false)
        }

        if failures > 0 {
            print("\n\(failures) check(s) failed.")
            exit(1)
        }
        let note = skipped.isEmpty ? "" : " (\(skipped.count) skipped: no agent)"
        print("\nAll checks passed\(note).")
    }
}
