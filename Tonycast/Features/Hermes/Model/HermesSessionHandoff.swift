import Foundation

/// Turns a session this client cannot reopen into the opening context of one it can.
///
/// Hermes refuses to reopen a session another surface created, and every ACP path funnels through
/// that
/// check, so carrying work across has to happen on the supported surface: start a session here and
/// hand
/// the agent what was said before. This builds that handover.
///
/// Tool traffic is dropped. It is the bulk of a session — 186 kB of 220 kB in one measured 248-item
/// session — and none of its meaning: a `terminal` result is not part of the conversation. What is
/// kept
/// is the exchange itself, which measured 33 kB for the same session.
enum HermesSessionHandoff {
    /// Bounds the handover, newest first. A long session keeps its recent shape rather than its
    /// beginning, because that is what a continuation needs, and the prompt stays affordable.
    static let maximumCharacters = 12_000

    /// The conversation so far, oldest to newest, as `User:`/`Assistant:` turns.
    ///
    /// Empty when the session holds no prose at all, which the caller reports rather than sending a
    /// handover with nothing in it.
    static func make(from items: [HermesTranscriptReader.Item]) -> String {
        var chosen: [String] = []
        var used = 0
        // Newest first, so the bound keeps the most recent turns, then reversed to read
        // chronologically.
        for item in items.reversed() {
            guard let speaker = speaker(for: item.role) else { continue }
            let body = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let turn = "\(speaker): \(body)"
            guard used + turn.count <= maximumCharacters else { continue }
            chosen.append(turn)
            used += turn.count
        }
        return chosen.reversed().joined(separator: "\n\n")
    }

    /// What the new session's agent is told, with the conversation appended.
    ///
    /// The closing instruction matters: without it the agent answers the last turn in the handover
    /// again, which reads as though it ignored the request the user has not made yet.
    static func prompt(for summary: HermesSessionSummary, digest: String) -> String {
        let origin = summary.originLabel ?? "another Hermes surface"
        let title = summary.displayTitle
        let when = summary.updatedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "earlier"
        return """
            I am continuing a conversation that began in \(origin) on \(when): "\(title)".

            \(explanation)

            --- conversation so far ---
            \(digest)

            Reply with one short sentence saying where things stand, then wait for my next message.
            """
    }

    /// The same explanation the window shows, so the agent and the notice agree on what happened.
    static let explanation = """
        Hermes does not let this client reopen a session another surface created, so instead of \
        resuming it you are being handed its recent history as context. Treat it as your own prior \
        conversation with me, and do not repeat or summarise it.
        """

    /// The new session appears in Hermes' own sidebar, so it says what it came from rather than
    /// looking like a session that started itself.
    static func title(for summary: HermesSessionSummary) -> String {
        "Continue \(summary.displayTitle)"
    }

    /// Tool and thinking items are not part of the conversation; only the speakers are.
    private static func speaker(for role: HermesTranscriptReader.Item.Role) -> String? {
        switch role {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .tool, .thinking: return nil
        }
    }
}
