import Foundation

/// Reads every session Hermes groups under the connected host's projects.
///
/// `session/list` cannot answer this. Hermes scopes it to the sessions **it** created over ACP, and
/// `session/load` refuses any other row, so a session from the Hermes app, its web UI or a cron job
/// is
/// invisible there — and `session/load` answers such an id with an empty *success* rather than an
/// error, which is why the sidebar used to look empty for a project full of work. The sessions
/// table
/// is therefore read directly, on the host that owns it.
///
/// The read is `SELECT`-only and bounded, and `source` rides along because it is what decides
/// whether
/// a session can be continued here or only read.
enum HermesSessionReader {
    /// One session, with everything the sidebar row and a read-only transcript need.
    struct Row: Sendable, Equatable {
        let id: String
        let title: String
        let cwd: String
        /// The git root Hermes recorded, which can be the project match when the cwd is not.
        let repoRoot: String
        let source: String
        let updatedAt: Date?
        /// The session's first user message, used as a title when Hermes never wrote one.
        let preview: String

        /// Only an `acp` row can be handed back to `session/load`; everything else is view-only
        /// here.
        var isContinuable: Bool { source == "acp" }
    }

    /// The long-lived conversational surfaces a person would look for, in the order Hermes names
    /// them.
    ///
    /// `subagent` and `oneshot` are excluded deliberately: a subagent is a worker owned by another
    /// session and a one-shot is a scripted single reply, so listing them buries real work under
    /// machine traffic. `acp` is included so this is the whole picture rather than a supplement.
    ///
    /// Sessions with a parent are excluded for the same reason: a delegate's child session is a
    /// worker
    /// owned by another row, Hermes' own sidebar hides it, and it is what arrives untitled.
    static let listedSources = ["acp", "desktop", "cli", "webui", "api_server", "tui"]

    /// Rows are ordered newest-first by Hermes' own activity column, and capped: a project with a
    /// thousand sessions does not need all of them to fill a column.
    static let maximumRows = 400

    static var script: String {
        let sources = listedSources.map { "\"\($0)\"" }.joined(separator: ", ")
        return """
            import json, os, sqlite3, sys
            from datetime import datetime, timezone
            home = os.environ.get("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes")
            path = os.path.join(home, "state.db")
            sources = [\(sources)]
            out = {"sessions": []}
            db = None
            for uri in ("file:%s?mode=ro" % path, path):
                try:
                    candidate = sqlite3.connect(uri, uri=uri.startswith("file:"))
                    candidate.execute("select 1 from sqlite_master limit 1")
                    db = candidate
                    break
                except Exception:
                    db = None
            try:
                placeholders = ",".join("?" * len(sources))
                rows = db.execute(
                    "select s.id, coalesce(s.title, ''), coalesce(s.cwd, ''),"
                    " coalesce(s.git_repo_root, ''), s.source,"
                    " coalesce(s.last_activity_at, s.started_at),"
                    " (select substr(m.content, 1, 120) from messages m"
                    "   where m.session_id = s.id and m.role = 'user'"
                    "   order by m.id asc limit 1)"
                    " from sessions s"
                    " where s.message_count > 0 and s.hidden = 0 and s.archived = 0"
                    " and s.parent_session_id is null"
                    " and s.source in (" + placeholders + ")"
                    " order by coalesce(s.last_activity_at, s.started_at) desc limit \(maximumRows)",
                    sources)
                for row in rows:
                    stamp = None
                    try:
                        stamp = datetime.fromtimestamp(float(row[5]), tz=timezone.utc).isoformat()
                    except Exception:
                        stamp = None
                    preview = row[6] if isinstance(row[6], str) else ""
                    out["sessions"].append({
                        "id": row[0], "title": row[1], "cwd": row[2],
                        "repoRoot": row[3], "source": row[4],
                        "updatedAt": stamp, "preview": preview.strip(),
                    })
            except Exception:
                out["sessions"] = []
            finally:
                if db is not None:
                    db.close()
            sys.stdout.write(json.dumps(out))
            """
    }

    nonisolated static func read(_ connection: HermesConnection) async -> [Row] {
        let output = await HermesHostScript.run(connection, script: script, timeout: 30)
        return decode(output)
    }

    /// Decoded from the script's JSON. A row with no id is dropped; a row missing an optional
    /// column
    /// costs that field rather than the row, because the store belongs to another application.
    static func decode(_ data: Data) -> [Row] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["sessions"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty else { return nil }
            return Row(
                id: id,
                title: row["title"] as? String ?? "",
                cwd: HermesWorkspace.normalizedPath(row["cwd"] as? String ?? ""),
                repoRoot: HermesWorkspace.normalizedPath(row["repoRoot"] as? String ?? ""),
                source: row["source"] as? String ?? "unknown",
                updatedAt: HermesSessionSummary.parseTimestamp(row["updatedAt"] as? String),
                preview: row["preview"] as? String ?? "")
        }
    }
}
