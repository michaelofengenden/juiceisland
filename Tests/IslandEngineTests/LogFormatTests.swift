import Foundation
import Testing

/// P115: the app's log (`JuiceLog`) never holds a key, a token, an email, a prompt, transcript text or a path inside a
/// profile folder. This reads every log call in our sources and holds each interpolation to that: it says its privacy,
/// and what it logs, once `JuiceLog.folder(_:)`, `JuiceLog.file(_:)`, `JuiceLog.code(_:)`, `logName` and
/// `logReason(_:)` have reduced it and its string literals are left out, names none of the words below. No other
/// logger, `print` or `NSLog` is allowed in the app's sources.
struct LogFormatTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let trees = ["App", "Sources/IslandEngine", "Sources/IslandHookNotes", "JuiceCore/Sources/JuiceCore", "PublicApp"]
    /// What a logged value may not name, whatever its privacy.
    static let forbidden = ["email", "token", "key", "prompt", "transcript", "summary", "message", "stderr", "stdout", "secret",
                            "password", "credential", "auth", "description", "path", "folder", "url", "text", "title", "cwd",
                            "directory", "home", "name", "alias", "reading", "response", "output"]
    /// Calls that reduce a value to what may be logged.
    static let reducers = ["JuiceLog.folder(", "JuiceLog.file(", "JuiceLog.code(", "Self.logReason(", "SessionEngine.logReason("]

    struct Call {
        var file: String
        var line: Int
        var interpolations: [String]
    }

    static func sources() throws -> [(path: String, text: String)] {
        var found: [(String, String)] = []
        for tree in trees {
            let base = root.appendingPathComponent(tree)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                // Upstream's files, compiled from Vendor/ through links and derived copies, are not ours to log in.
                let relative = String(url.path.dropFirst(root.path.count + 1))
                if relative.contains("/Vendored/") || relative.contains("/Derived/") { continue }
                found.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return found
    }

    /// Every `JuiceLog.<category>.<level>(…)` call with the interpolations of its message.
    static func calls(in text: String, file: String) -> [Call] {
        let pattern = try! NSRegularExpression(pattern: #"JuiceLog\.[a-zA-Z]+\.(debug|info|notice|error|fault|warning|critical|trace|log)\("#)
        let characters = Array(text)
        let utf16 = text.utf16
        return pattern.matches(in: text, range: NSRange(location: 0, length: utf16.count)).map { match in
            let end = match.range.location + match.range.length
            let offset = text.utf16.index(utf16.startIndex, offsetBy: end)
            let start = text.distance(from: text.startIndex, to: offset)
            var scanner = Scanner(characters: characters, index: start)
            _ = scanner.code(until: ")")
            let line = text[..<offset].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
            return Call(file: file, line: line, interpolations: scanner.interpolations)
        }
    }

    /// Walks Swift source far enough to find a call's end and the interpolations in its string literals.
    struct Scanner {
        let characters: [Character]
        var index: Int
        var interpolations: [String] = []

        /// Code up to the closing `close` that matches (its own parentheses and string literals skipped); returns it.
        mutating func code(until close: Character) -> String {
            var depth = 0
            var taken = ""
            while index < characters.count {
                let character = characters[index]
                if character == "\"" {
                    let literal = string()
                    taken += "\"\(literal)\""
                    continue
                }
                index += 1
                if character == "(" { depth += 1 }
                if character == ")" {
                    if depth == 0 && close == ")" { return taken }
                    depth -= 1
                }
                taken.append(character)
            }
            return taken
        }

        /// A string literal from its opening quote(s); records each `\( … )` in it. Returns its plain text.
        mutating func string() -> String {
            let multiline = index + 2 < characters.count && characters[index + 1] == "\"" && characters[index + 2] == "\""
            index += multiline ? 3 : 1
            var plain = ""
            while index < characters.count {
                let character = characters[index]
                if character == "\\", index + 1 < characters.count {
                    if characters[index + 1] == "(" {
                        index += 2
                        interpolations.append(code(until: ")").trimmingCharacters(in: .whitespacesAndNewlines))
                        continue
                    }
                    index += 2
                    continue
                }
                if character == "\"" {
                    if !multiline {
                        index += 1
                        return plain
                    }
                    if index + 2 < characters.count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                        index += 3
                        return plain
                    }
                }
                plain.append(character)
                index += 1
            }
            return plain
        }
    }

    /// An interpolation with its reducers' calls, `logName` and string literals taken out: what it actually logs.
    static func logged(_ interpolation: String) -> String {
        var text = interpolation
        if let comma = text.range(of: ", privacy:", options: .backwards) { text = String(text[..<comma.lowerBound]) }
        text = text.replacingOccurrences(of: #""[^"]*""#, with: "_", options: .regularExpression)
        text = text.replacingOccurrences(of: ".logName", with: "")
        for reducer in reducers {
            while let range = text.range(of: reducer) {
                var depth = 1
                var end = range.upperBound
                while end < text.endIndex, depth > 0 {
                    if text[end] == "(" { depth += 1 }
                    if text[end] == ")" { depth -= 1 }
                    end = text.index(after: end)
                }
                text.replaceSubrange(range.lowerBound..<end, with: "_")
            }
        }
        return text
    }

    @Test
    func everyLoggedValueSaysItsPrivacyAndNamesNothingPrivate() throws {
        let calls = try Self.sources().flatMap { Self.calls(in: $0.text, file: $0.path) }
        #expect(calls.count >= 20, "the log calls were not found: \(calls.count)")
        var problems: [String] = []
        for call in calls {
            for interpolation in call.interpolations {
                if !interpolation.contains("privacy:") { problems.append("\(call.file):\(call.line): no privacy in \\(\(interpolation))") }
                let logged = Self.logged(interpolation).lowercased()
                for word in Self.forbidden where logged.contains(word) {
                    problems.append("\(call.file):\(call.line): \\(\(interpolation)) names \(word)")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test
    func theScannerFindsInterpolationsInEveryKindOfLiteral() {
        let source = #"""
            JuiceLog.reads.error("\(a, privacy: .public) and \(f(x, "y"), privacy: .private)")
            JuiceLog.bridge.notice("""
                one \(JuiceLog.folder(account.folder), privacy: .public) \
                two \(error.logName, privacy: .public)
                """)
            """#
        let calls = Self.calls(in: source, file: "x.swift")
        #expect(calls.map(\.interpolations) == [["a, privacy: .public", #"f(x, "y"), privacy: .private"#],
                                                ["JuiceLog.folder(account.folder), privacy: .public", "error.logName, privacy: .public"]])
        #expect(calls.map(\.line) == [1, 2])
        #expect(Self.logged("JuiceLog.folder(account.folder), privacy: .public") == "_")
        #expect(Self.logged("account.email, privacy: .private").contains("email"))
    }

    /// Only `JuiceLog` makes loggers, and nothing prints.
    @Test
    func noOtherLoggerOrPrint() throws {
        let other = try NSRegularExpression(pattern: #"(\bLogger\(|\bos_log\(|\bNSLog\(|(^|[^.\w])print\()"#, options: [.anchorsMatchLines])
        var problems: [String] = []
        for (path, text) in try Self.sources() where !path.hasSuffix("Logging/JuiceLog.swift") {
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = line.trimmingCharacters(in: .whitespaces)
                if code.hasPrefix("//") || code.hasPrefix("///") { continue }
                let string = String(line)
                if other.firstMatch(in: string, range: NSRange(location: 0, length: string.utf16.count)) != nil {
                    problems.append("\(path):\(number + 1)")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
