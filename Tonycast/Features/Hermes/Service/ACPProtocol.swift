import Foundation

/// JSON-RPC 2.0 for ACP: newline-delimited frames over a child process's stdin/stdout.
///
/// ACP frames one message per line, exactly as MCP's stdio transport does. The envelope is the
/// same; only the method names and payload schemas differ.
enum ACPProtocol {
    /// The ACP wire version this client speaks. `acp.meta.PROTOCOL_VERSION` is 1.
    static let version = 1

    /// JSON-RPC reserves this for "method not found", which is also how a liveness probe is answered.
    static let methodNotFound = -32_601

    enum Message: Equatable {
        case response(id: Int, result: JSONValue)
        case failure(id: Int, code: Int, message: String)
        /// An agent → client notification: no `id`.
        case notification(method: String, params: JSONValue)
        /// An agent → client request, which this client must answer.
        case request(id: JSONValue, method: String, params: JSONValue)
        case invalid
    }

    // MARK: - Encoding

    static func request(id: Int, method: String, params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { object["params"] = params }
        return try encode(object)
    }

    static func notification(method: String, params: [String: Any]? = nil) throws -> Data {
        var object: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { object["params"] = params }
        return try encode(object)
    }

    static func result(id: JSONValue, value: [String: Any]) throws -> Data {
        try encode(["jsonrpc": "2.0", "id": id.jsonObject, "result": value])
    }

    static func error(id: JSONValue, code: Int, message: String) throws -> Data {
        try encode([
            "jsonrpc": "2.0", "id": id.jsonObject, "error": ["code": code, "message": message]
        ])
    }

    // MARK: - Decoding

    static func parse(_ data: Data) -> Message {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .invalid
        }
        // A bool bridges to NSNumber, so it has to be excluded before reading an id as a number.
        let numericID = (object["id"] as? NSNumber).flatMap {
            CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.intValue
        }
        let params = JSONValue(object["params"] ?? [:])

        if let method = object["method"] as? String {
            guard let id = object["id"], !(id is NSNull) else {
                return .notification(method: method, params: params)
            }
            return .request(id: JSONValue(id), method: method, params: params)
        }
        guard let id = numericID else { return .invalid }
        if let error = object["error"] as? [String: Any] {
            return .failure(
                id: id,
                code: (error["code"] as? NSNumber)?.intValue ?? -1,
                message: error["message"] as? String ?? "Hermes reported an error.")
        }
        guard let result = object["result"] else { return .invalid }
        return .response(id: id, result: JSONValue(result))
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        // One frame per line; a message containing a newline would split into two invalid frames.
        data.append(0x0A)
        return data
    }
}
