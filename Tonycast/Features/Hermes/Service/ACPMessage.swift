import Foundation

/// The typed ACP payloads this client sends and receives.
///
/// Field names are the wire names from `acp/schema.py` (`sessionId`, `optionId`, `title`,
/// `sessionUpdate`, …). Decoding goes through `JSONValue` because the agent owns the schema and may
/// add fields; only the parts this UI renders are read out.
enum ACPMessage {
    // MARK: - Requests this client sends

    static func initialize(id: Int) throws -> Data {
        try ACPProtocol.request(
            id: id,
            method: "initialize",
            params: [
                "protocolVersion": ACPProtocol.version,
                // `fs` and `terminal` are deliberately false: Hermes runs its own tools, and
                // claiming these would make it ask this client to perform file I/O it cannot do.
                "clientCapabilities": [
                    "fs": ["readTextFile": false, "writeTextFile": false],
                    "terminal": false,
                ],
                "clientInfo": ["name": "Tonycast", "version": ACPMessage.appVersion],
            ])
    }

    static func newSession(id: Int, cwd: String) throws -> Data {
        try ACPProtocol.request(
            id: id,
            method: "session/new",
            params: ["cwd": cwd, "mcpServers": []])
    }

    static func loadSession(id: Int, sessionID: String, cwd: String) throws -> Data {
        try ACPProtocol.request(
            id: id,
            method: "session/load",
            params: ["sessionId": sessionID, "cwd": cwd, "mcpServers": []])
    }

    /// `prompt` is a list of content blocks. Text plus one `resource_link` per attachment: the
    /// agent resolves each URI and reads the file itself, so no bytes ever cross this pipe.
    static func prompt(
        id: Int, sessionID: String, text: String, attachments: [ACPAttachment] = []
    ) throws -> Data {
        var blocks: [[String: Any]] = [["type": "text", "text": text]]
        blocks.append(contentsOf: attachments.map(\.wireBlock))
        return try ACPProtocol.request(
            id: id,
            method: "session/prompt",
            params: [
                "sessionId": sessionID,
                "prompt": blocks,
            ])
    }

    static func cancel(id: Int, sessionID: String) throws -> Data {
        try ACPProtocol.request(
            id: id, method: "session/cancel", params: ["sessionId": sessionID])
    }

    static func setMode(id: Int, sessionID: String, modeID: String) throws -> Data {
        try ACPProtocol.request(
            id: id,
            method: "session/set_mode",
            params: ["sessionId": sessionID, "modeId": modeID])
    }

    static func setModel(id: Int, sessionID: String, modelID: String) throws -> Data {
        try ACPProtocol.request(
            id: id,
            method: "session/set_model",
            params: ["sessionId": sessionID, "modelId": modelID])
    }

    // MARK: - Requests this client answers

    /// The outcome shape ACP expects for `session/request_permission`.
    static let permissionSelectedOutcome = "selected"
    static let permissionCancelledOutcome = "cancelled"

    static func permissionAnswer(id: JSONValue, optionID: String) throws -> Data {
        try ACPProtocol.result(
            id: id,
            value: ["outcome": ["outcome": permissionSelectedOutcome, "optionId": optionID]])
    }

    /// Used when the user dismisses the sheet: cancelling is safer than a default grant.
    static func permissionCancelled(id: JSONValue) throws -> Data {
        try ACPProtocol.result(id: id, value: ["outcome": ["outcome": permissionCancelledOutcome]])
    }

    static func emptyResult(id: JSONValue) throws -> Data {
        try ACPProtocol.result(id: id, value: [:])
    }

    // MARK: - Helpers

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
