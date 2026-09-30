import Foundation

/// Guards the sidebar's data model: how a session is filed under a project, where a new session in
/// a project opens, and how the agent's `session/list` payload is decoded.
///
/// The grouping rule is the one that must match Hermes' own sidebar — a session is filed under the
/// project owning the longest folder that is an ancestor of its cwd — and the failure mode of
/// getting it wrong is quiet: sessions simply appear under the wrong project, or under none.
@main
struct HermesWorkspaceTest {
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

        func workspace(
            _ id: String, _ name: String, start: String = "", folders: [String] = []
        ) -> HermesWorkspace {
            HermesWorkspace(
                id: id, slug: id, name: name, startDirectory: start,
                folders: start.isEmpty ? folders : [start] + folders)
        }

        func session(
            _ id: String, cwd: String, updated: Date? = nil, root: String = "", source: String = "acp"
        ) -> HermesSessionSummary {
            HermesSessionSummary(
                id: id, title: id, cwd: cwd, repoRoot: root, source: source, updatedAt: updated)
        }

        // MARK: - Path normalization

        check("an absolute path survives normalization",
              HermesWorkspace.normalizedPath("/Users/tony/git/wiki") == "/Users/tony/git/wiki")
        check("a trailing slash is not a different directory",
              HermesWorkspace.normalizedPath("/Users/tony/git/wiki/") == "/Users/tony/git/wiki")
        check("a tilde is expanded rather than kept",
              !HermesWorkspace.normalizedPath("~/git/wiki").hasPrefix("~"))
        check("interior dot segments collapse",
              HermesWorkspace.normalizedPath("/Users/tony/git/./wiki")
                  == "/Users/tony/git/wiki")
        check("parent segments collapse",
              HermesWorkspace.normalizedPath("/Users/tony/git/forks/../wiki")
                  == "/Users/tony/git/wiki")
        // The empty cwd is Home and a relative one names no directory: both match nothing.
        check("an empty path normalizes to nothing", HermesWorkspace.normalizedPath("").isEmpty)
        check("a relative path normalizes to nothing",
              HermesWorkspace.normalizedPath("git/wiki").isEmpty)
        check("a lone dot normalizes to nothing", HermesWorkspace.normalizedPath(".").isEmpty)

        // MARK: - Grouping

        let projects = [
            workspace("p_root", "My Projects", start: "/Users/tony/git"),
            workspace("p_forks", "Forks", start: "/Users/tony/git/forks"),
        ]

        let sections = HermesSidebarSection.sections(
            workspaces: projects,
            sessions: [
                session("a", cwd: "/Users/tony/git/forks/tonycast"),
                session("b", cwd: "/Users/tony/git/wiki"),
                session("c", cwd: ""),
                session("d", cwd: "/Users/tony/git/forks"),
            ])

        check("every project gets a section", sections.count == 3)
        check("projects keep the order they were listed in",
              sections.map(\.title) == ["My Projects", "Forks", "Home"])
        // Load-bearing: /Users/tony/git/forks/x is under both, and the deeper project wins.
        check("the longest matching folder wins",
              sections[1].sessions.map(\.id) == ["a", "d"])
        check("a sibling directory stays with the shallower project",
              sections[0].sessions.map(\.id) == ["b"])
        check("a session with no cwd falls to Home", sections[2].sessions.map(\.id) == ["c"])

        // Prefix matching is the classic bug: "git" prefixes "github" without being its parent.
        let prefix = HermesSidebarSection.sections(
            workspaces: [workspace("p_git", "Git", start: "/Users/tony/git")],
            sessions: [session("x", cwd: "/Users/tony/github/thing")])
        check("a shared string prefix is not a parent directory",
              prefix.count == 2 && prefix[1].sessions.map(\.id) == ["x"])

        // A project holds folders, so a session matches on its cwd or the git root recorded.
        let byRoot = HermesSidebarSection.sections(
            workspaces: [
                workspace("p_setup", "Tonycast", start: "/Users/tony/git/forks/tonycast",
                          folders: ["/Users/tony/git/tonycast-setup"])
            ],
            sessions: [
                session("in-repo", cwd: "/Users/tony/git/forks/tonycast"),
                session("in-second-folder", cwd: "/Users/tony/git/tonycast-setup"),
                // A session whose cwd is elsewhere but whose root is the project's second folder.
                session("by-root", cwd: "/tmp/scratch", root: "/Users/tony/git/tonycast-setup"),
            ])
        check("a session is filed by its cwd or its git root",
              byRoot.first?.sessions.count == 3)
        check("a session matching only by root is not left ungrouped", byRoot.count == 1)

        // MARK: - Section contents

        check("an empty project still gets a section",
              HermesSidebarSection.sections(workspaces: projects, sessions: []).count == 2)
        check("the Home section is dropped when nothing is ungrouped",
              HermesSidebarSection.sections(workspaces: projects, sessions: [session("a", cwd: "/Users/tony/git/wiki")]).count == 2)
        check("the Home section has no workspace",
              HermesSidebarSection.sections(workspaces: [], sessions: [session("c", cwd: "")])
                  .first?.workspace == nil)
        check("the ungrouped section is titled Home",
              HermesSidebarSection.sections(workspaces: [], sessions: [session("c", cwd: "")])
                  .first?.title == "Home")
        check("no projects and no sessions yields no sections",
              HermesSidebarSection.sections(workspaces: [], sessions: []).isEmpty)

        // A project id is minted as `p_…`, so the ungrouped id cannot collide with a real one.
        check("the ungrouped id is not a Hermes project id",
              !HermesSidebarSection.ungroupedID.hasPrefix("p_"))

        // MARK: - Ordering

        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)
        let ordered = HermesSidebarSection.sections(
            workspaces: [workspace("p", "P", start: "/w")],
            sessions: [
                session("old", cwd: "/w", updated: older),
                session("unknown", cwd: "/w", updated: nil),
                session("new", cwd: "/w", updated: newer),
            ])
        check("sessions are newest first", ordered[0].sessions.map(\.id) == ["new", "old", "unknown"])

        // MARK: - Where a new session opens

        // The host decides this: the folders belong to the connected machine, not to this Mac.
        check("a project carries the directory the host chose",
              workspace("p", "P", start: "/Users/tony/git/wiki").startDirectory == "/Users/tony/git/wiki")
        check("a project with no usable folder starts a session in Home",
              workspace("p", "P").startDirectory.isEmpty)
        // The host resolves with realpath; the model still normalizes what arrives on the wire.
        let messy = """
            {"projects":[{"id":"p","slug":"p","name":"P",
             "startDirectory":"/Users/tony/git/wiki/.","folders":[]}]}
            """
        check("a start directory on the wire is normalized",
              HermesWorkspace.decodeListing(Data(messy.utf8)).first?.startDirectory
                  == "/Users/tony/git/wiki")

        // MARK: - Session titles

        check("a titled session shows its title",
              HermesSessionSummary(id: "1", title: "Fix the parser", cwd: "/w", updatedAt: nil)
                  .displayTitle == "Fix the parser")
        check("an untitled session falls back to its directory",
              HermesSessionSummary(id: "1", title: "   ", cwd: "/Users/tony/git/wiki", updatedAt: nil)
                  .displayTitle == "wiki")
        check("an untitled Home session still reads as something",
              HermesSessionSummary(id: "1", title: "", cwd: "", updatedAt: nil)
                  .displayTitle == "New thread")

        // MARK: - Decoding the agent's session list

        let payload = """
            {"sessions":[
              {"sessionId":"s1","cwd":"","title":"Home thread",
               "updatedAt":"2026-09-25T16:45:21.272327+00:00"},
              {"sessionId":"s2","cwd":"/Users/tony/git/forks/tonycast","title":"",
               "updatedAt":null},
              {"cwd":"/w","title":"no id"}
            ]}
            """
        let decoded = HermesSessionSummary.decodeListing(JSONValue(data: Data(payload.utf8))!)
        check("every usable row decodes", decoded.count == 2)
        check("a row with no session id is dropped", !decoded.contains { $0.title == "no id" })
        check("the id is read from sessionId", decoded.first?.id == "s1")
        check("the cwd is normalized on decode", decoded[1].cwd == "/Users/tony/git/forks/tonycast")
        check("a fractional-second timestamp parses", decoded[0].updatedAt != nil)
        check("a null timestamp is nil rather than a date",
              decoded[1].updatedAt == nil)

        check("a payload with no sessions key decodes to nothing",
              HermesSessionSummary.decodeListing(JSONValue(data: Data("{}".utf8))!).isEmpty)
        check("a malformed payload decodes to nothing",
              HermesSessionSummary.decodeListing(.null).isEmpty)

        // MARK: - Decoding the project listing

        let projects_payload = """
            {"projects":[
              {"id":"p_1","slug":"wiki","name":"Wiki","startDirectory":"/Users/tony/git/wiki",
               "folders":["/Users/tony/git/wiki","/Users/tony/git/wiki-web"]},
              {"id":"","slug":"blank","name":"Blank","startDirectory":"","folders":[]}
            ]}
            """
        let decodedProjects = HermesWorkspace.decodeListing(Data(projects_payload.utf8))
        check("a project row decodes", decodedProjects.count == 1)
        check("a project with no id is dropped", decodedProjects.first?.name == "Wiki")
        check("every folder is kept", decodedProjects.first?.folders.count == 2)
        check("folders are normalized", decodedProjects.first?.folders.first == "/Users/tony/git/wiki")
        check("the host's start directory is read",
              decodedProjects.first?.startDirectory == "/Users/tony/git/wiki")
        // No start directory means an unusable folder, not a Home session the user did not ask for.
        check("a missing start directory decodes to empty",
              HermesWorkspace(
                  id: "p", slug: "p", name: "P", startDirectory: "", folders: ["/x"]
              ).startDirectory.isEmpty)
        check("a listing with no projects key decodes to nothing",
              HermesWorkspace.decodeListing(Data("{}".utf8)).isEmpty)
        check("a malformed listing decodes to nothing",
              HermesWorkspace.decodeListing(Data("not json".utf8)).isEmpty)

        // MARK: - Decoding the host's session rows

        // Every source is visible here; the ACP endpoint saw only what ACP created.
        let rows_payload = """
            {"sessions":[
              {"id":"a","title":"From the app","cwd":"/w","repoRoot":"/w","source":"desktop",
               "updatedAt":"2026-09-25T16:45:21.272327+00:00"},
              {"id":"b","title":"","cwd":"/w","repoRoot":"","source":"acp","updatedAt":null},
              {"id":"","title":"no id","cwd":"/w","repoRoot":"","source":"webui","updatedAt":null}
            ]}
            """
        let decodedRows = HermesSessionReader.decode(Data(rows_payload.utf8))
        check("every usable session row decodes", decodedRows.count == 2)
        // One malformed row must cost only itself: the store belongs to another application, so a
        // single odd entry cannot be allowed to drop a whole project's sessions.
        let mixedRows = HermesSessionReader.decode(Data("""
            {"sessions":[
              {"id":"a","title":"one","cwd":"/w","repoRoot":"/w","source":"desktop",
               "updatedAt":null},
              null,
              "a bare string",
              {"id":"b","title":"two","cwd":"/w","repoRoot":"/w","source":"acp","updatedAt":null}
            ]}
            """.utf8))
        check("a non-object row costs only that row", mixedRows.count == 2)
        check("a listing with no sessions key decodes to nothing",
              HermesSessionReader.decode(Data("{}".utf8)).isEmpty)
        check("a row with no id is dropped", !decodedRows.contains { $0.title == "no id" })
        check("the source is read", decodedRows[0].source == "desktop")
        check("the git root is read", decodedRows[0].repoRoot == "/w")
        check("a fractional-second timestamp parses", decodedRows[0].updatedAt != nil)

        let summaries = decodedRows.map(HermesSessionSummary.from)
        check("only an acp session is continuable",
              summaries[1].isContinuable && !summaries[0].isContinuable)
        check("a session created elsewhere names its origin",
              summaries[0].originLabel == "Hermes app")
        check("an acp session has no origin to explain", summaries[1].originLabel == nil)
        check("a blank title prefers the session's own first message",
              HermesSessionSummary(
                  id: "x", title: "", cwd: "/Users/tony/git/wiki", updatedAt: nil,
                  preview: "Rename the app to Tonycast"
              ).displayTitle == "Rename the app to Tonycast")
        check("a blank title with no message falls back to the directory",
              HermesSessionSummary(id: "x", title: "", cwd: "/Users/tony/git/wiki", updatedAt: nil)
                  .displayTitle == "wiki")
        check("a title Hermes wrote wins over the preview",
              HermesSessionSummary(
                  id: "x", title: "Real title", cwd: "/w", updatedAt: nil, preview: "first message"
              ).displayTitle == "Real title")

        // MARK: - Carrying a foreign session forward

        // Hermes refuses to reopen a session another surface created, so the work is carried into a
        // new
        // session instead. What follows is the handover that makes that possible.
        func item(_ role: HermesTranscriptReader.Item.Role, _ text: String)
            -> HermesTranscriptReader.Item
        {
            HermesTranscriptReader.Item(role: role, text: text, toolName: nil)
        }

        let conversation = [
            item(.user, "Where did we leave the property chain?"),
            item(.tool, "{\"output\": \"a great deal of terminal noise\"}"),
            item(.assistant, "At the Silver->Gold step."),
            item(.thinking, "internal reasoning that is not part of the conversation"),
        ]
        let digest = HermesSessionHandoff.make(from: conversation)
        check("the handover keeps the reader's and the agent's turns",
              digest.contains("User: Where did we leave") && digest.contains("Assistant: At the"))
        // Tool output is the bulk of a session and none of its meaning, so it must not be carried.
        check("terminal noise is left out", !digest.contains("terminal noise"))
        check("internal reasoning is left out", !digest.contains("internal reasoning"))
        check("the turns read chronologically",
              digest.range(of: "User:")!.lowerBound < digest.range(of: "Assistant:")!.lowerBound)

        check("a session with no prose carries nothing",
              HermesSessionHandoff.make(from: [item(.tool, "output only")]).isEmpty)
        check("blank turns are skipped",
              HermesSessionHandoff.make(from: [item(.user, "   "), item(.assistant, "")]).isEmpty)

        // The bound keeps the newest turns, which is what a continuation needs.
        let long = (0..<40).map { item(.user, "turn \($0) " + String(repeating: "x", count: 900)) }
        let bounded = HermesSessionHandoff.make(from: long)
        check("a long session is bounded", bounded.count <= HermesSessionHandoff.maximumCharacters + 1_000)
        check("the bound keeps the most recent turns", bounded.contains("turn 39"))
        check("the bound drops the oldest turns", !bounded.contains("turn 0 "))

        let origin = HermesSessionSummary(
            id: "s", title: "Aerox 5 wireless", cwd: "/w", source: "desktop", updatedAt: nil)
        let prompt = HermesSessionHandoff.prompt(for: origin, digest: digest)
        check("the handover names where the session came from",
              prompt.contains("Hermes app"))
        check("the handover carries the conversation", prompt.contains(digest))
        check("the handover tells the agent not to re-answer the last turn",
              prompt.contains("wait for my next message"))
        check("a continuation is titled after what it continues",
              HermesSessionHandoff.title(for: origin) == "Continue Aerox 5 wireless")

        if failures > 0 {
            print("\n\(failures) check(s) failed.")
            exit(1)
        }
        print("\nAll checks passed.")
    }
}
