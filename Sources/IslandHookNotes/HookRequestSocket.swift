import Darwin
import Foundation
import OpenIslandCore

/// Where the superset helper hands Claude's and Codex's PermissionRequests to the engine (the request broker): a
/// stream socket in the app's own support folder, one connection per request. It is not one of the hook sockets,
/// which stay byte-identical to Open Island's, and not the note socket.
public enum HookRequestSocket {
    public static let fileName = "hook-requests.sock"
    /// Points one helper process at a scratch socket (tests), as `JUICE_ISLAND_HOOK_NOTES_SOCKET` does for notes.
    public static let overrideKey = "JUICE_ISLAND_HOOK_REQUESTS_SOCKET"

    public static var defaultURL: URL {
        HookNoteSocket.defaultURL.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    /// The override when set, else the helper's home's (P900), else the default.
    public static func helperURL(environment: [String: String], home: HookHome? = nil) -> URL {
        if let path = environment[overrideKey], !path.isEmpty { return URL(fileURLWithPath: path) }
        return home?.requestsURL ?? defaultURL
    }
}

/// One request line, helper to engine: the hook's input (re-encoded as compact JSON, so the request is one line; at
/// most `inputLimit`), and what the helper alone knows about the agent.
public struct HookRequestLine: Equatable, Sendable {
    public static let version = 1
    /// Larger inputs are never sent: the helper exits silent and the agent's own prompt decides.
    public static let inputLimit = 1 << 20

    public var source: String
    /// The hook's input as a JSON object, re-encoded compactly (one line).
    public var input: Data
    public var digest: String?
    public var entrypoint: String?
    public var agentPID: Int32?
    public var hostBundleID: String?
    /// Whether the agent has a controlling terminal: a missing `CLAUDE_CODE_ENTRYPOINT` counts as a terminal only then.
    public var hasTerminal: Bool

    public init(source: String, input: Data, digest: String? = nil, entrypoint: String? = nil, agentPID: Int32? = nil,
                hostBundleID: String? = nil, hasTerminal: Bool = false) {
        self.source = source
        self.input = input
        self.digest = digest
        self.entrypoint = entrypoint
        self.agentPID = agentPID
        self.hostBundleID = hostBundleID
        self.hasTerminal = hasTerminal
    }

    /// The line with its newline; nil when the input is not a JSON object or is too large.
    public func encoded() -> Data? {
        guard input.count <= Self.inputLimit,
              let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] else { return nil }
        var head: [String: Any] = ["v": Self.version, "source": source, "has_terminal": hasTerminal]
        if let digest { head["digest"] = digest }
        if let entrypoint { head["entrypoint"] = entrypoint }
        if let agentPID { head["agent_pid"] = agentPID }
        if let hostBundleID { head["host_bundle_id"] = hostBundleID }
        head["input"] = object
        guard let data = try? JSONSerialization.data(withJSONObject: head, options: [.sortedKeys, .withoutEscapingSlashes]),
              data.count <= Self.inputLimit + 4_096 else { return nil }
        return data + Data("\n".utf8)
    }

    /// The engine's side: one line, without its newline.
    public static func decode(_ line: Data) -> (line: HookRequestLine, object: [String: Any])? {
        guard line.count <= inputLimit + 4_096,
              let head = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              head["v"] as? Int == version, let source = head["source"] as? String,
              let object = head["input"] as? [String: Any],
              let input = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        let request = HookRequestLine(source: source, input: input, digest: head["digest"] as? String,
                                      entrypoint: head["entrypoint"] as? String,
                                      agentPID: (head["agent_pid"] as? NSNumber).map { Int32(truncating: $0) },
                                      hostBundleID: head["host_bundle_id"] as? String,
                                      hasTerminal: head["has_terminal"] as? Bool ?? false)
        return (request, object)
    }
}

/// One reply line, engine to helper: first whether the engine holds the request (`{"hold":true}` or false), then,
/// only for a held one and only on the owner's click, the decision as upstream's bridge response, which the helper
/// prints through upstream's own encoders. Anything else, and the end of the connection, is "no decision".
public enum HookRequestReply: Equatable, Sendable {
    case hold(Bool)
    case decision(BridgeResponse)

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        switch self {
        case let .hold(hold):
            data = Data(#"{"hold":\#(hold)}"#.utf8)
        case let .decision(response):
            let body = (try? encoder.encode(response)) ?? Data("null".utf8)
            data = Data(#"{"decision":"#.utf8) + body + Data("}".utf8)
        }
        return data + Data("\n".utf8)
    }

    public static func decode(_ line: Data) -> HookRequestReply? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return nil }
        if let hold = object["hold"] as? Bool { return .hold(hold) }
        guard let decision = object["decision"],
              let body = try? JSONSerialization.data(withJSONObject: decision, options: [.fragmentsAllowed]),
              let response = try? JSONDecoder().decode(BridgeResponse.self, from: body) else { return nil }
        return .decision(response)
    }
}
