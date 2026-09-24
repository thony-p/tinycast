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
    }

    struct Tool: Equatable, Sendable {
        let id: String
        var title: String
        var status: String
        var detail: String?

        var isFinished: Bool { status == "completed" || status == "failed" }
    }

    /// Context-window occupancy after a turn, in the shape Hermes' own statusbar shows it.
    struct Usage: Equatable, Sendable {
        /// Tokens currently in context.
        let used: Int
        /// The model's context window; zero when the agent did not report one.
        let size: Int
        /// True while the number is a rough estimate rather than a measured token count.
        var isEstimated: Bool

        var fraction: Double? {
            guard size > 0 else { return nil }
            return Double(used) / Double(size) * 100
        }

        var label: String { HermesUsageFormat.contextLabel(used: used, size: size, isEstimated: isEstimated) }
        var barLabel: String { HermesUsageFormat.barLabel(percent: fraction, isEstimated: isEstimated) }
    }

    let id = UUID()
    var role: Role
    var text: String
    var tool: Tool?
    /// Plan entries, when `role == .plan`.
    var entries: [String] = []
    /// Context usage, when `role == .usage`.
    var usage: Usage?
    /// Files and images carried with this user message, when `role == .user`.
    var attachments: [ACPAttachment] = []

    /// Only assistant/thinking/user text streams; a tool or plan row is created whole.
    var isChunkContinuation: Bool {
        role == .assistant || role == .thinking || role == .user
    }

    static func user(_ text: String, attachments: [ACPAttachment] = []) -> ACPTranscriptItem {
        ACPTranscriptItem(role: .user, text: text, attachments: attachments)
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

    init(
        role: Role, text: String, tool: Tool? = nil, entries: [String] = [], usage: Usage? = nil,
        attachments: [ACPAttachment] = []
    ) {
        self.role = role
        self.text = text
        self.tool = tool
        self.entries = entries
        self.usage = usage
        self.attachments = attachments
    }

    static func == (lhs: ACPTranscriptItem, rhs: ACPTranscriptItem) -> Bool {
        lhs.id == rhs.id && lhs.text == rhs.text && lhs.tool == rhs.tool
            && lhs.entries == rhs.entries && lhs.usage == rhs.usage
            && lhs.attachments == rhs.attachments
    }
}
