import Foundation

/// The transcript the Hermes window renders. One item per visible bubble.
struct ACPTranscriptItem: Identifiable, Equatable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
        case thinking
        case system
        /// A tool call shown as its own row.
        case tool
        /// The agent's plan, as a checklist.
        case plan
        /// Token usage after a turn.
        case usage
    }

    struct Tool: Equatable, Sendable {
        let id: String
        var title: String
        var status: String
        var detail: String?

        var isFinished: Bool { status == "completed" || status == "failed" }
    }

    let id = UUID()
    var role: Role
    var text: String
    var tool: Tool?
    /// Plan entries, when `role == .plan`.
    var entries: [String] = []
    /// Tokens, when `role == .usage`.
    var tokenCount: Int?

    /// Only assistant/thinking/user text streams; a tool or plan row is created whole.
    var isChunkContinuation: Bool {
        role == .assistant || role == .thinking || role == .user
    }

    static func user(_ text: String) -> ACPTranscriptItem {
        ACPTranscriptItem(role: .user, text: text)
    }

    static func assistant(_ text: String) -> ACPTranscriptItem {
        ACPTranscriptItem(role: .assistant, text: text)
    }

    static func system(_ text: String) -> ACPTranscriptItem {
        ACPTranscriptItem(role: .system, text: text)
    }

    static func tool(_ tool: Tool) -> ACPTranscriptItem {
        ACPTranscriptItem(role: .tool, text: tool.title, tool: tool)
    }

    static func plan(_ entries: [String]) -> ACPTranscriptItem {
        ACPTranscriptItem(role: .plan, text: "", entries: entries)
    }

    static func usage(_ tokens: Int) -> ACPTranscriptItem {
        ACPTranscriptItem(role: .usage, text: "", tokenCount: tokens)
    }

    init(role: Role, text: String, tool: Tool? = nil, entries: [String] = [], tokenCount: Int? = nil)
    {
        self.role = role
        self.text = text
        self.tool = tool
        self.entries = entries
        self.tokenCount = tokenCount
    }

    static func == (lhs: ACPTranscriptItem, rhs: ACPTranscriptItem) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.tool == rhs.tool
            && lhs.entries == rhs.entries
    }
}
