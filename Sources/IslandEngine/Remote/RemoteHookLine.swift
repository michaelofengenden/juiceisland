import Foundation
import IslandHookNotes
import OpenIslandCore

/// What a remote hook knows that a jump back can use (P748): the remote tmux pane it runs in, and the client port of
/// the ssh connection its shell came in on (`SSH_CONNECTION`), which tells two local ssh tabs to one host apart.
public struct RemoteContext: Equatable, Sendable {
    public var tmuxSocket: String?
    public var tmuxPane: String?
    public var sshClientPort: Int?

    public init(tmuxSocket: String? = nil, tmuxPane: String? = nil, sshClientPort: Int? = nil) {
        self.tmuxSocket = tmuxSocket
        self.tmuxPane = tmuxPane
        self.sshClientPort = sshClientPort
    }

    /// `TMUX` is `<socket>,<server pid>,<session>`; `TMUX_PANE` is `%<n>`; `SSH_CONNECTION` is `<client ip> <client port>
    /// <server ip> <server port>`. Anything else is dropped.
    init(object: [String: Any]?) {
        let tmux = (object?["tmux"] as? String)?.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init)
        tmuxSocket = tmux.flatMap { $0.hasPrefix("/") && $0.count <= 256 ? $0 : nil }
        tmuxPane = (object?["pane"] as? String).flatMap { pane in
            pane.count > 1 && pane.count <= 12 && pane.first == "%" && pane.dropFirst().allSatisfy(\.isASCIIDigit) ? pane : nil
        }
        let parts = (object?["ssh"] as? String)?.split(separator: " ") ?? []
        sshClientPort = parts.count == 4 ? Int(parts[1]).flatMap { (1...65_535).contains($0) ? $0 : nil } : nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

/// One hook's line from the remote helper (`jr.py hook`): `{"jr":1,"source":…,"input":{…},"entrypoint":…,"tty":…,
/// "ctx":{…}}`. The remote sends only facts; what reaches the bridge or the broker is built here (P742).
struct RemoteHookLine {
    static let lineLimit = HookRequestLine.inputLimit + 8_192

    var source: String
    /// The hook's input. `[String: Any]` is not Sendable; it is only read on the relay's queue.
    var input: [String: Any]
    var entrypoint: String?
    var hasTerminal: Bool
    var context: RemoteContext

    static func decode(_ line: Data) -> RemoteHookLine? {
        guard line.count <= lineLimit, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["jr"] as? Int == 1, let source = object["source"] as? String,
              let input = object["input"] as? [String: Any] else { return nil }
        let entrypoint = (object["entrypoint"] as? String).flatMap { $0.isEmpty || $0.utf8.count > 32 ? nil : $0 }
        return RemoteHookLine(source: source, input: input, entrypoint: entrypoint, hasTerminal: object["tty"] as? Bool ?? false,
                              context: RemoteContext(object: object["ctx"] as? [String: Any]))
    }

    var sessionID: String? { (input["session_id"] as? String).flatMap { $0.isEmpty || $0.count > 256 ? nil : $0 } }
    var event: String? { input["hook_event_name"] as? String }
}

/// Where a remote hook goes, decided from its line alone, as the superset helper's prelude decides for a local one
/// (`HookPrelude`): a Claude or Codex PermissionRequest to the request broker (with the bridge as the fallback when the
/// broker is not there, C16), a Codex subagent's other hooks and a Codex PreToolUse nowhere (P167, P161), every other
/// Claude and Codex hook to the bridge. Any other source ends at once: the agent goes on as without the island.
enum RemoteRoute {
    case end
    case bridge(BridgeCommand, timeout: TimeInterval)
    case broker(HookRequestLine, fallback: BridgeCommand)
}

enum RemoteRouting {
    /// The bridge's wait for an ordinary hook: under the remote helper's own 40 s, which is under Codex's 45 s hook
    /// timeout, so the remote side always ends first.
    static let bridgeTimeout: TimeInterval = 35

    /// What names the remote's own files and terminals, which nothing on this Mac may read or jump to (P743): a
    /// transcript path could even name a different file at the same path here.
    static let remoteOnlyKeys = ["transcript_path", "agent_transcript_path", "terminal_app", "terminal_session_id",
                                 "terminal_tty", "terminal_title", "warp_pane_uuid", "hook_source", "remote"]

    static func sanitized(_ input: [String: Any]) -> [String: Any] {
        var clean = input
        for key in remoteOnlyKeys { clean[key] = nil }
        clean["remote"] = true
        return clean
    }

    static func route(_ line: RemoteHookLine) -> RemoteRoute {
        guard line.source == "claude" || line.source == "codex", line.sessionID != nil else { return .end }
        let input = sanitized(line.input)
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return .end
        }
        let command: BridgeCommand
        if line.source == "claude" {
            guard var payload = SessionEngine.decodeClaude(data) else { return .end }
            payload.hookSource = "claude"
            command = .processClaudeHook(payload)
        } else {
            guard let payload = SessionEngine.decodeCodex(data) else { return .end }
            command = .processCodexHook(payload)
        }
        if line.event == "PermissionRequest" {
            // No pid and no host app: both are this Mac's, and a remote one would name some local process (P744).
            let request = HookRequestLine(source: line.source, input: data, digest: input["tool_input"].flatMap(HookInputDigest.of),
                                          entrypoint: line.entrypoint, agentPID: nil, hostBundleID: nil,
                                          hasTerminal: line.hasTerminal)
            return .broker(request, fallback: command)
        }
        if line.source == "codex" {
            if let agent = input["agent_id"] as? String, !agent.isEmpty { return .end }
            if line.event == "PreToolUse" { return .end }
        }
        return .bridge(command, timeout: bridgeTimeout)
    }

    /// Upstream's helper waits this long on the bridge for a PermissionRequest (the broker's fallback).
    static func permissionTimeout(source: String) -> TimeInterval {
        source == "codex" ? HookBrokerClient.codexHoldCap : HookBrokerClient.claudeHoldCap
    }

    /// What the remote helper prints for the bridge's answer: upstream's own encoders, so the remote holds none.
    static func standardOutput(for response: BridgeResponse, source: String) -> String? {
        let data = source == "codex" ? try? CodexHookOutputEncoder.standardOutput(for: response)
            : try? ClaudeHookOutputEncoder.standardOutput(for: response)
        return data.flatMap { $0 }.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// One reply line to the remote helper: `{"stdout":"…"}`.
    static func stdoutLine(_ text: String) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: ["stdout": text], options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        return data + Data("\n".utf8)
    }
}
