import Foundation
import os

/// P115: the app's unified log, one category per part (`log show --predicate 'subsystem == "com.ofengenden.juice"' --info`):
/// failures and state changes only, never on a timer. A line never holds a key, a token, an email, a prompt,
/// transcript text or a path inside a profile folder: a profile folder is named only by `folder(_:)`, a hash of its
/// name, so two lines about one folder match and neither says which; an error only by its case (`ReadError.logName`,
/// `MoneyReadError.logName`) or its domain and code (`code(_:)`), never its description, which can carry a path or a
/// CLI's words. Every interpolation says its privacy. `LogFormatTests` reads every call in the sources and holds them
/// to these rules, and no other logger, `print` or `NSLog` is allowed beside these.
public enum JuiceLog {
    /// `com.ofengenden.juice` in the private app (and every test); the public flavor's bundle id there (`AppFlavor`, P820).
    public static let subsystem = AppFlavor.current.logSubsystem

    /// Usage reads: phase changes, a login's reads starting to fail or recovering, sleep and wake, CLIs not found.
    public static let reads = Logger(subsystem: subsystem, category: "reads")
    /// The hook bridge: started, refused, lost and taken back.
    public static let bridge = Logger(subsystem: subsystem, category: "bridge")
    /// The in-app update: its phases and the script's end.
    public static let update = Logger(subsystem: subsystem, category: "update")
    /// The app's JSON files: a record or a file that could not be read, a copy kept, a write that failed.
    public static let stores = Logger(subsystem: subsystem, category: "stores")
    /// Money reads: a source starting to fail or recovering, and its 429 pauses.
    public static let money = Logger(subsystem: subsystem, category: "money")
    /// Sign-in flows: started, and how they ended (never who signed in).
    public static let signIn = Logger(subsystem: subsystem, category: "signin")
    /// The profile list: when it changed, by counts.
    public static let profiles = Logger(subsystem: subsystem, category: "profiles")
    /// Sessions sent to the island: each decision of the fold and the resume, by session id and state, never a reply's
    /// or an answer's text (`log show --predicate 'category == "fold"'`).
    public static let fold = Logger(subsystem: subsystem, category: "fold")

    /// A profile folder as the log names it: its provider's word and 8 hex digits of the FNV-1a hash of the folder's
    /// name (`claude·3fa4c2d1`), the same on every run. Nothing of the path or of what is inside the folder.
    public static func folder(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let word = name.hasPrefix(".codex") ? "codex" : name.hasPrefix(".claude") ? "claude" : "folder"
        return word + "·" + hash(name)
    }

    /// An error as its domain and code (`NSCocoaErrorDomain 513`), never its description.
    public static func code(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain) \(error.code)"
    }

    /// One of the app's own files by its name (`readings.json`), never its folder.
    public static func file(_ url: URL) -> String { url.lastPathComponent }

    /// 8 hex digits of the 32-bit FNV-1a hash.
    static func hash(_ text: String) -> String {
        var value: UInt32 = 0x811c_9dc5
        for byte in text.utf8 {
            value ^= UInt32(byte)
            value = value &* 0x0100_0193
        }
        return String(format: "%08x", value)
    }
}

extension ReadError {
    /// The case alone, for the log: a CLI's words (`failed`, `incomplete`, `cliUpdateNeeded`) are left out.
    public var logName: String {
        switch self {
        case .cliNotFound: "cliNotFound"
        case .cliUpdateNeeded: "cliUpdateNeeded"
        case .signInRequired: "signInRequired"
        case .rateLimited(let retryAfter): retryAfter.map { "rateLimited(\(Int($0)) s)" } ?? "rateLimited"
        case .timeout: "timeout"
        case .offline: "offline"
        case .incomplete: "incomplete"
        case .failed: "failed"
        }
    }
}

extension MoneyReadError {
    /// The case alone, for the log: a key file's words and an answer's are left out.
    public var logName: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .keyFileRefused: "keyFileRefused"
        case .keyFileUnreadable: "keyFileUnreadable"
        case .keyNotUsable: "keyNotUsable"
        case .notAvailableWithThisKey: "notAvailableWithThisKey"
        case .refusedByPolicy: "refusedByPolicy"
        case .rateLimited(let retryAfter): retryAfter.map { "rateLimited(\(Int($0)) s)" } ?? "rateLimited"
        case .http(let status): "http(\(status))"
        case .timeout: "timeout"
        case .offline: "offline"
        case .unreadableResponse: "unreadableResponse"
        case .idMissing: "idMissing"
        case .idInvalid: "idInvalid"
        }
    }
}
