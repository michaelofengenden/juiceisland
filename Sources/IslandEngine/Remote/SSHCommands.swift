import Foundation

/// Every ssh the app runs, as argument lists (P741). Always the system's `/usr/bin/ssh` with the owner's own config,
/// keys, agent and `ProxyJump`, and these options over it:
/// - `BatchMode=yes`: never a password or passphrase prompt (a host that needs one reads Needs key login);
/// - `ClearAllForwardings=yes`, `Tunnel=no`: none of the host's own `LocalForward`, `RemoteForward` or
///   `DynamicForward` ports (a Jupyter port, a SOCKS port) is bound by the app, so it never fights the owner's own ssh
///   for them; the tunnel needs no forward, it speaks over stdio (P740);
/// - `ControlMaster=no`, `ControlPath=none`: no master is left running and none of the owner's is borrowed;
/// - `UpdateHostKeys=no`: ssh never adds keys to `known_hosts` on the app's behalf (the owner's own
///   `StrictHostKeyChecking` still decides about a new host);
/// - `ForwardAgent=no`, `ForwardX11=no`: a long-lived connection never lends the agent to the remote;
/// - `PermitLocalCommand=no`, `RemoteCommand=none`, `RequestTTY=no`, `-T`, `-e none`: the host's own commands and a
///   terminal stay out, so stdio stays clean;
/// - `ServerAliveInterval=60`, `ServerAliveCountMax=3`, `ConnectTimeout=15`: a connection that died unseen ends within
///   three minutes, with one small packet a minute while connected, the one thing that runs at rest (P747); a wake or a
///   network change starts a connected tunnel over at once, as that is where unseen drops come from;
/// - `LogLevel=ERROR`: no banner, only the lines `failure` reads.
public enum SSHCommands {
    public static let ssh = URL(fileURLWithPath: "/usr/bin/ssh")

    public static let options: [String] = [
        "BatchMode=yes", "ClearAllForwardings=yes", "Tunnel=no", "ControlMaster=no", "ControlPath=none", "UpdateHostKeys=no",
        "ForwardAgent=no", "ForwardX11=no", "PermitLocalCommand=no", "RemoteCommand=none", "RequestTTY=no",
        "ServerAliveInterval=60", "ServerAliveCountMax=3", "ConnectTimeout=15", "LogLevel=ERROR",
    ]

    /// `ssh <options> -T -e none -- <destination> <command>`. A destination that could be read as an option is refused.
    public static func arguments(destination: String, command: String) -> [String]? {
        guard RemoteDestination.isValid(destination) else { return nil }
        return options.flatMap { ["-o", $0] } + ["-T", "-e", "none", "--", destination, command]
    }

    /// The tunnel: the remote helper's `serve` under the Python Set up found, by absolute paths.
    public static func tunnel(destination: String, python: String, script: String) -> [String]? {
        guard let python = shellQuoted(python), let script = shellQuoted(script) else { return nil }
        return arguments(destination: destination, command: "exec \(python) \(script) serve")
    }

    /// Set up and Remove: the helper arrives on stdin, is written beside the old one and run with `python3`, which
    /// renames it into place once the merge is done. `sh -c` with no single quote, `!` or backslash inside, so it reads
    /// the same under any login shell (bash, zsh, fish, tcsh). 96: the folder cannot be written; 97: no Python 3.
    public static func setup(destination: String, mode: SetupMode) -> [String]? {
        let script = #"umask 077; d="$HOME/.juice-island"; mkdir -p "$d" || exit 96; chmod 700 "$d"; "#
            + #"cat > "$d/jr.py.new" || exit 96; command -v python3 >/dev/null 2>&1 || exit 97; "#
            + #"exec python3 "$d/jr.py.new" \#(mode.rawValue)"#
        return arguments(destination: destination, command: "sh -c '\(script)'")
    }

    public enum SetupMode: String, Sendable {
        case install, remove
    }

    /// A path for the remote shell, single-quoted; nil when it holds a quote or a newline.
    static func shellQuoted(_ path: String) -> String? {
        guard !path.isEmpty, path.hasPrefix("/"), !path.contains("'"), !path.contains("\n") else { return nil }
        return "'\(path)'"
    }

    // MARK: Failures

    /// What ssh's exit status and last error lines say about a connection that ended before the helper spoke. The error
    /// lines also hold whatever the host's rc files print at login, so a word counts only with the status that goes with
    /// it: the login's and the host key's with ssh's own 255, a missing helper with the shell's 126 or 127, or Python's
    /// "can't open file" with its 2. Anything else may pass by itself.
    public static func failure(status: Int32, stderr: String) -> TunnelFailure {
        let text = stderr.lowercased()
        switch status {
        case 255:
            if text.contains("host key verification failed") || text.contains("remote host identification has changed")
                || text.contains("host key for") || text.contains("no matching host key") {
                return .hostKey
            }
            if text.contains("permission denied") || text.contains("too many authentication failures")
                || text.contains("no more authentication methods") {
                return .needsKeyLogin
            }
            return .unreachable
        case 126, 127:
            return .notSetUp
        case 2 where text.contains("can't open file"):
            return .notSetUp
        default:
            return .unreachable
        }
    }
}

/// A host as the owner names it: an alias from `~/.ssh/config`, `host`, `user@host` or `ssh://user@host:port`.
public enum RemoteDestination {
    /// Letters, digits and `._-@:/[]%` only, and never a leading `-` (ssh would read an option).
    public static func isValid(_ destination: String) -> Bool {
        guard !destination.isEmpty, destination.count <= 255, destination.first != "-" else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-@:/[]%")
        return destination.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// The host part, which rows show: `gpu1` for `ubuntu@gpu1`, `box` for `ssh://me@box:2222`.
    public static func hostName(_ destination: String) -> String {
        var rest = Substring(destination)
        if rest.hasPrefix("ssh://") { rest = rest.dropFirst(6) }
        if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
        if rest.hasPrefix("[") , let close = rest.firstIndex(of: "]") { return String(rest[rest.index(after: rest.startIndex)..<close]) }
        if destination.hasPrefix("ssh://"), let colon = rest.lastIndex(of: ":") { rest = rest[..<colon] }
        return String(rest.split(separator: "/").first ?? rest)
    }
}

/// What Set up found on the remote, from the helper's `JR-RESULT {…}` line.
public struct RemoteSetupResult: Equatable, Sendable, Codable {
    public var helper: Int
    public var python: String
    public var script: String
    public var claude: Bool
    public var codex: Bool
    /// Codex's `[features] hooks`: "added", "on", "off" (the owner turned it off: left so) or "unknown" (set some other
    /// way: left alone); nil without Codex.
    public var codexFeature: String?

    public init(helper: Int, python: String, script: String, claude: Bool, codex: Bool, codexFeature: String? = nil) {
        self.helper = helper
        self.python = python
        self.script = script
        self.claude = claude
        self.codex = codex
        self.codexFeature = codexFeature
    }

    static let prefix = "JR-RESULT "

    /// The last result line in stdout (an rc file may print before it).
    static func parse(_ stdout: String) -> [String: Any]? {
        guard let line = stdout.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }),
              let data = String(line.dropFirst(prefix.count)).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func install(stdout: String) -> RemoteSetupResult? {
        guard let object = parse(stdout), let helper = object["v"] as? Int, let python = object["python"] as? String,
              let script = object["script"] as? String, SSHCommands.shellQuoted(python) != nil,
              SSHCommands.shellQuoted(script) != nil else { return nil }
        return RemoteSetupResult(helper: helper, python: python, script: script, claude: object["claude"] as? Bool ?? false,
                                 codex: object["codex"] as? Bool ?? false, codexFeature: object["codexFeature"] as? String)
    }
}

/// Why Set up or Remove did not finish, in the few words the host's row shows.
public enum RemoteSetupFailure: Error, Equatable, Sendable {
    case connection(TunnelFailure)
    case noPython
    case cannotWrite
    /// The helper refused, before writing anything: a settings file that is not JSON, a link; or a write failed.
    case refused(String)
    case timedOut
    case invalidDestination
    case unreadable

    public var words: String {
        switch self {
        case .connection(.needsKeyLogin): "Needs key login"
        case .connection(.hostKey): "Unknown host key"
        case .connection(.notSetUp), .connection(.protocolError): "Not reachable"
        case .connection(.unreachable): "Not reachable"
        case .noPython: "Needs Python 3"
        case .cannotWrite: "Home folder is read-only"
        case let .refused(reason): reason
        case .timedOut: "Timed out"
        case .invalidDestination: "Not a host name"
        case .unreadable: "Unexpected answer"
        }
    }

    /// The helper ran there, or may have: it refused (and wrote nothing), or the run timed out or answered something
    /// not understood, perhaps after its merge. Remove then runs there too (P756).
    public var mayHaveReachedTheHost: Bool {
        switch self {
        case .refused, .timedOut, .unreadable: true
        default: false
        }
    }

    /// From the run's exit and output; nil when it succeeded.
    static func of(status: Int32, stderr: String, timedOut: Bool) -> RemoteSetupFailure? {
        if timedOut { return .timedOut }
        switch status {
        case 0: return nil
        case 96: return .cannotWrite
        case 97: return .noPython
        case 98:
            let line = stderr.split(whereSeparator: \.isNewline).last { $0.hasPrefix("JR-ERROR ") }
            return .refused(line.map { String($0.dropFirst("JR-ERROR ".count).prefix(80)) } ?? "Refused")
        default:
            return .connection(SSHCommands.failure(status: status, stderr: stderr))
        }
    }
}
