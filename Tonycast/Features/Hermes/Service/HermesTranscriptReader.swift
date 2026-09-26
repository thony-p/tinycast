import Foundation

/// Reads one session's conversation from the connected host, for a session ACP cannot reopen.
///
/// `session/load` only restores a row Hermes created over ACP, and answers any other id with an
/// empty
/// *success* — so a session from the desktop app or the web UI has to be read out of the store
/// directly. That is also why such a session is presented read-only: nothing here can hand it back
/// to
/// the agent to continue.
///
/// Only what the transcript renders is read. Tool arguments and results arrive as JSON strings and
/// are
/// flattened to text, because the transcript shows a call as a line and its output as a block.
enum HermesTranscriptReader {
    /// One rendered transcript item, mirroring `ACPTranscriptItem`'s roles so the view is shared.
    struct Item: Sendable, Equatable {
        let role: Role
        let text: String
        /// The tool's name, when `role == .tool`.
        let toolName: String?

        enum Role: Sendable, Equatable {
            case user
            case assistant
            case thinking
            case tool
        }
    }

    /// A session can carry hundreds of messages with kilobytes of tool output each, so both the
    /// read
    /// and every individual block are bounded: this is a transcript to read, not an export.
    static let maximumMessages = 2_000
    static let maximumCharacters = 4_000

    /// The script is built per call because the session id travels inside it.
    ///
    /// The id is escaped into a Python **string literal**, not into a shell command line: it
    /// arrives
    /// over JSON and is passed to the interpreter as source, so no quoting layer can misread it and
    /// no
    /// argument ever reaches a shell.
    static func script(sessionID: String) -> String {
        """
        import json, os, sqlite3, sys
        home = os.environ.get("HERMES_HOME") or os.path.join(os.path.expanduser("~"), ".hermes")
        path = os.path.join(home, "state.db")
        session_id = \(pythonLiteral(sessionID))
        out = {"items": []}
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
            rows = db.execute(
                "select role, content, tool_name, tool_calls from messages"
                " where session_id = ? and compacted = 0"
                " order by id asc limit \(maximumMessages)",
                (session_id,))
            for role, content, tool_name, tool_calls in rows:
                text = content if isinstance(content, str) else ""
                if not isinstance(content, str) and content is not None:
                    text = json.dumps(content)
                text = text.strip()
                calls = []
                if tool_calls:
                    try:
                        for call in json.loads(tool_calls):
                            fn = call.get("function") or {}
                            calls.append((fn.get("name") or "tool", fn.get("arguments") or ""))
                    except Exception:
                        calls = []
                if role == "user" and text:
                    out["items"].append({"role": "user", "text": text, "toolName": None})
                elif role == "assistant":
                    if text:
                        out["items"].append({"role": "assistant", "text": text, "toolName": None})
                    for name, arguments in calls:
                        out["items"].append({
                            "role": "tool", "text": arguments, "toolName": name})
                elif role == "tool" and text:
                    out["items"].append({
                        "role": "tool", "text": text, "toolName": tool_name or "tool"})
        except Exception:
            out["items"] = []
        finally:
            if db is not None:
                db.close()
        sys.stdout.write(json.dumps(out))
        """
    }

    nonisolated static func read(
        _ connection: HermesConnection, sessionID: String
    ) async -> [Item] {
        let output = await HermesHostScript.run(
            connection, script: script(sessionID: sessionID), timeout: 30)
        return decode(output)
    }

    /// Decoded from the script's JSON, clipped to what the transcript will show.
    static func decode(_ data: Data) -> [Item] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rows = root["items"] as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let raw = row["role"] as? String, let role = Item.Role(rawValue: raw) else {
                return nil
            }
            let text = row["text"] as? String ?? ""
            guard !text.isEmpty else { return nil }
            return Item(role: role, text: clip(text), toolName: row["toolName"] as? String)
        }
    }

    /// A single-quoted Python literal, which needs only the quote and the backslash escaped.
    private static func pythonLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    /// Clipped in the middle, so a tool call's command and the tail of its output both stay
    /// readable.
    private static func clip(_ text: String) -> String {
        guard text.count > maximumCharacters else { return text }
        return "\(text.prefix(maximumCharacters / 2))\n…\n\(text.suffix(maximumCharacters / 2))"
    }
}

extension HermesTranscriptReader.Item.Role {
    init?(rawValue: String) {
        switch rawValue {
        case "user": self = .user
        case "assistant": self = .assistant
        case "thinking": self = .thinking
        case "tool": self = .tool
        default: return nil
        }
    }
}
