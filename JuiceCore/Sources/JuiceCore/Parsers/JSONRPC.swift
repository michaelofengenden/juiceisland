import Foundation

public enum JSONRPC {
    public struct RPCError: Decodable, Sendable, Equatable {
        public var code: Int?
        public var message: String?
        /// The error's `data`, as compact JSON text: the app-server may put details there (an HTTP status, say).
        public var data: String?

        public init(code: Int? = nil, message: String? = nil, data: String? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }

        private enum CodingKeys: String, CodingKey { case code, message, data }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            code = try? container.decodeIfPresent(Int.self, forKey: .code)
            message = try? container.decodeIfPresent(String.self, forKey: .message)
            data = (try? container.decodeIfPresent(AnyJSON.self, forKey: .data))?.text
        }
    }

    /// A message's id: a number (every request Juice sends) or a string (a server may use either for its own requests).
    public enum ID: Decodable, Sendable, Equatable, Hashable, ExpressibleByIntegerLiteral {
        case number(Int)
        case text(String)

        public init(integerLiteral value: Int) { self = .number(value) }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Int.self) {
                self = .number(number)
            } else {
                self = .text(try container.decode(String.self))
            }
        }

        var json: Any {
            switch self {
            case .number(let number): number
            case .text(let text): text
            }
        }
    }

    /// Just enough of a message to route it: its id, its method and whether it failed. A reply has an id and no method; a
    /// notification has a method and no id; a request from the server has both, and its id is the server's own, which
    /// may equal one of ours.
    public struct Envelope: Decodable, Sendable {
        public var id: ID?
        public var method: String?
        public var error: RPCError?

        private enum CodingKeys: String, CodingKey { case id, method, error }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try? container.decodeIfPresent(ID.self, forKey: .id)
            method = try? container.decodeIfPresent(String.self, forKey: .method)
            error = try? container.decodeIfPresent(RPCError.self, forKey: .error)
        }

        public static func decode(_ data: Data) throws -> Envelope {
            try JSONDecoder().decode(Envelope.self, from: data)
        }
    }
    private struct Typed<T: Decodable>: Decodable {
        var result: T?
    }

    /// Any JSON value, kept only as compact text.
    private struct AnyJSON: Decodable {
        var text: String?

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                text = nil
            } else if let string = try? container.decode(String.self) {
                text = string
            } else if let number = try? container.decode(Int.self) {
                text = String(number)
            } else if let number = try? container.decode(Double.self) {
                text = String(number)
            } else if let flag = try? container.decode(Bool.self) {
                text = String(flag)
            } else if let object = try? container.decode([String: AnyJSON].self) {
                text = "{" + object.keys.sorted().map { "\"\($0)\":\(object[$0]?.text ?? "null")" }.joined(separator: ",") + "}"
            } else if let array = try? container.decode([AnyJSON].self) {
                text = "[" + array.map { $0.text ?? "null" }.joined(separator: ",") + "]"
            } else {
                text = nil
            }
        }
    }

    public static func decodeResult<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        let typed = try JSONDecoder().decode(Typed<T>.self, from: data)
        guard let result = typed.result else { throw ReadError.failed("JSON-RPC message has no result") }
        return result
    }

    public static func request(id: Int, method: String, params: [String: Any] = [:]) -> String {
        line(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    public static func notification(method: String, params: [String: Any] = [:]) -> String {
        line(["jsonrpc": "2.0", "method": method, "params": params])
    }

    /// JSON-RPC's "method not found".
    public static let methodNotFound = -32601

    /// The error reply to a request from the server, under the request's own id.
    public static func errorResponse(id: ID, code: Int, message: String) -> String {
        line(["jsonrpc": "2.0", "id": id.json, "error": ["code": code, "message": message]])
    }

    private static func line(_ object: [String: Any]) -> String {
        // Without `.withoutEscapingSlashes` a method such as account/read goes out as account\/read; both are
        // valid JSON, but the unescaped form is what the wire logs and the vendor's own clients show.
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
