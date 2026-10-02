import Foundation

/// What a login CLI's output asks of the person signing in, one line at a time:
/// - the sign-in page's URL;
/// - a prompt that waits for the code the page shows at the end: `claude auth login` prints
///   `Paste code here if prompted > ` without a newline (`CLIProcess`'s interactive mode delivers it as a line);
/// - a one-time code to type on the page: `codex login --device-auth` prints it alone on the line after the one that
///   announces it.
/// Colour and hyperlink escapes are removed first. A value type with no side effects, so the flow reads with it off the
/// main actor and tests feed it transcripts.
struct SignInOutput: Sendable {
    enum Event: Sendable, Equatable {
        case url(URL)
        case wantsCode
        case deviceCode(String)
    }

    /// The last line mentioned a code without asking for one, so this line may be the code itself.
    private var codeAnnounced = false

    mutating func read(_ raw: String) -> [Event] {
        let line = Self.plain(raw).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return [] }
        let announced = codeAnnounced
        codeAnnounced = false
        if announced, line.range(of: Self.deviceCodeShape, options: .regularExpression) != nil { return [.deviceCode(line)] }
        var events: [Event] = []
        if let url = Self.firstURL(in: line) { events.append(.url(url)) }
        let words = line.replacingOccurrences(of: Self.urlShape, with: "", options: .regularExpression)
        if Self.asksForCode(words) {
            events.append(.wantsCode)
        } else {
            codeAnnounced = words.range(of: #"(?i)\bcode\b"#, options: .regularExpression) != nil
        }
        return events
    }

    /// A prompt (it ends in `>`, `:` or `?`) that asks to paste or enter a code, and not the announcement of a
    /// one-time or device code, which is typed on the page, not here (Codex's
    /// `…sign in with ChatGPT using device code authorization:`).
    static func asksForCode(_ words: String) -> Bool {
        guard let last = words.trimmingCharacters(in: .whitespaces).last, ">:?".contains(last) else { return false }
        return words.range(of: #"(?i)\b(paste|enter|type)\b.*\bcode\b"#, options: .regularExpression) != nil
            && words.range(of: #"(?i)\b(one-time|device)\s+code\b"#, options: .regularExpression) == nil
    }

    /// A line on stderr that says a code was refused (Claude: `Invalid code. Please make sure the full code was copied.`).
    static func refusesCode(_ line: String) -> Bool {
        line.range(of: #"(?i)\b(invalid|incorrect|wrong|expired)\b.*\bcode\b|\bcode\b.*\b(invalid|incorrect|wrong|expired)\b"#,
                   options: .regularExpression) != nil
    }

    /// The first http(s) URL in `line`, without a sentence's closing punctuation (Codex ends
    /// `Starting local login server on http://localhost:1455.` with a full stop).
    static func firstURL(in line: String) -> URL? {
        guard let range = line.range(of: urlShape, options: .regularExpression) else { return nil }
        var text = String(line[range])
        while let last = text.last, ".,;:".contains(last) { text.removeLast() }
        return URL(string: text)
    }

    /// `line` without terminal escapes: OSC sequences (a hyperlink's wrapper; its text stays), CSI sequences (colour),
    /// other two-byte escapes, and carriage returns.
    static func plain(_ line: String) -> String {
        guard line.contains("\u{1B}") || line.contains("\r") else { return line }
        return line
            .replacingOccurrences(of: #"\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B[@-Z\\-_]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r", with: "")
    }

    private static let urlShape = #"https?://[^\s"'<>]+"#
    /// Groups of capitals and digits joined by dashes (`ABCD-EFGH`), the shape RFC 8628 suggests for a user code; a
    /// word in capitals alone (`SUCCESS`) is not one.
    private static let deviceCodeShape = #"^[A-Z0-9]{3,}(?:-[A-Z0-9]{3,})+$"#
}
