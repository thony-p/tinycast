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
        /// A peer reporting it could not read a request, answered with a null id. JSON-RPC requires
        /// this reply, and it is the only diagnostic for the frame that failed.
        case nullIDError(code: Int, message: String)
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
        let params = JSONValue(object["params"] ?? [:])

        if let method = object["method"] as? String {
            // A bool bridges to NSNumber; echoing one back as an id makes an invalid JSON-RPC reply.
            guard let id = object["id"], Self.isValidRequestID(id) else {
                return .notification(method: method, params: params)
            }
            return .request(id: JSONValue(id), method: method, params: params)
        }
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? NSNumber)?.intValue ?? -1
            let message = error["message"] as? String ?? "The agent reported an error with no message."
            // JSON-RPC answers an unreadable request with `id: null`; dropping it loses the reason.
            guard let id = object["id"], !(id is NSNull) else {
                return .nullIDError(code: code, message: message)
            }
            guard let numericID = Self.numericID(id) else { return .invalid }
            return .failure(id: numericID, code: code, message: message)
        }
        guard let result = object["result"], let id = object["id"],
            let numericID = Self.numericID(id)
        else { return .invalid }
        return .response(id: numericID, result: JSONValue(result))
    }

    /// A request id the reply can be addressed to: JSON-RPC allows a number or a string, never a bool.
    private static func isValidRequestID(_ value: Any) -> Bool {
        value is String || Self.isNumber(value)
    }

    /// The id as a number, or nil for a bool, a string, or a non-number.
    private static func numericID(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.intValue
    }

    private static func isNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    private static func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        // One frame per line; a message containing a newline would split into two invalid frames.
        data.append(0x0A)
        return data
    }
}
