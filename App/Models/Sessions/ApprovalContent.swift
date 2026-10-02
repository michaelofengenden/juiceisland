import Foundation
import IslandEngine
import OpenIslandCore

/// What an approval card is about, from what upstream's bridge puts in the request and, for Claude, the tool call's
/// input read from the session's transcript (`SessionEngine.toolCallInput(for:)`). Upstream fills the request
/// differently per agent (`ClaudeHooks.swift` `permissionRequestSummary`/`permissionAffectedPath`, `CodexHooks.swift`
/// `permissionRequestSummary`/`permissionRequestAffectedPath`):
/// - Claude: `summary` is a fixed sentence ("Claude wants to run Bash."), `affectedPath` the file path, or at most
///   110 characters of the input with its newlines collapsed; the transcript has the whole input.
/// - Codex: `summary` is the model's justification (`tool_input.description`, clipped to 110), `affectedPath` the
///   whole command.
/// - OpenCode (its plugin, `open-island-opencode.js` `permission.asked`, then `BridgeServer` `handleOpenCodeHook`):
///   `title` "Allow <Tool>", `summary` the plugin's sentence "OpenCode wants to run <Tool>: <first pattern>" with the
///   pattern whole, `affectedPath` the input as JSON cut at 200 characters and clipped again to 110.
/// - Claude Code's forks (Kimi, Qwen, Factory, Qoder, CodeBuddy) send Claude's payload: Claude's rules.
/// So the box shows the command, the edit or the URL, and the dim line under it why (Bash's `description`, Codex's
/// justification, WebFetch's prompt); upstream's fixed sentences are never shown. Owner: stream C.
enum ApprovalContent {
    struct Mapped: Equatable, Sendable {
        /// "Bash", "Edit", …: the header's "Needs approval · Bash".
        var tool: String
        var body: ApprovalBody
        /// Why, when the agent said: the dim line under the box.
        var reason: String?
        /// The row's one line after the tool: the command, the file's name, the URL.
        var rowText: String
    }

    static let fileTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    /// The lines a card keeps of a change or a written file; past them the box says how many more.
    static let diffLineLimit = 400
    /// Past this a line of a change is cut, with "…".
    static let diffLineLength = 1_000

    static func make(request: PermissionRequest, input: ClaudeHookJSONValue?, tool: AgentTool, folder: String?) -> Mapped {
        switch tool {
        case .codex: codexContent(request)
        case .openCode: openCodeContent(request, folder: folder)
        default: claudeContent(request, input: input, folder: folder)
        }
    }

    // MARK: Codex

    private static func codexContent(_ request: PermissionRequest) -> Mapped {
        let tool = request.toolName.flatMap { $0.isEmpty ? nil : $0 } ?? codexTool(title: request.title)
        let text = request.affectedPath
        let body: ApprovalBody = text.hasPrefix(CodexPatch.begin)
            ? .diff(CodexPatch.files(text))
            : isShell(tool) ? .command(text) : .text(text)
        let reason = codexReason(request.summary, shown: text)
        return Mapped(tool: tool, body: body, reason: reason, rowText: rowText(body))
    }

    /// Codex's PreToolUse path names no tool, only upstream's title.
    private static func codexTool(title: String) -> String {
        switch title {
        case "Run Bash command": "Bash"
        case "Apply code patch": "apply_patch"
        default: title
        }
    }

    /// The justification, unless it is one of upstream's own sentences or the command again.
    static func codexReason(_ summary: String, shown: String) -> String? {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixed = ["Codex wants to run: ", "Codex wants to use ", "Codex wants to run a shell command", "Codex is requesting permission"]
        guard !text.isEmpty, text != shown, !fixed.contains(where: text.hasPrefix) else { return nil }
        return text
    }

    private static func isShell(_ tool: String) -> Bool {
        ["bash", "shell", "exec_command", "local_shell"].contains(tool.lowercased())
    }

    // MARK: OpenCode

    /// Everything the request allows: the command OpenCode runs on Allow (`metadata.command`, whole, or as far as a cut
    /// input shows it, with `…`: its patterns leave out `cd` and join a pipe with `&&`, P179), else the plugin's
    /// `command` (every pattern joined by `&&`) or the files when upstream kept the input whole; when it cut it, every
    /// pattern its start still shows, the first whole from the plugin's sentence, and `…` where more may follow, so a
    /// second command is never hidden behind the first (P154); else what the request carries. Never the sentence itself
    /// or a cut JSON when either of those is there (P153). No reason of the plugin's own; a folder ask
    /// (`external_directory`) for a command shows the command, with its folders as the reason.
    private static func openCodeContent(_ request: PermissionRequest, folder: String?) -> Mapped {
        let tool = request.toolName.flatMap { $0.isEmpty ? nil : $0 }
            ?? (request.title.hasPrefix("Allow ") ? String(request.title.dropFirst(6)) : request.title)
        let shell = isShell(tool)
        let separator = shell ? " && " : "\n"
        func shown(_ pattern: String) -> String {
            ["edit", "write", "read"].contains(tool.lowercased()) ? relative(pattern, to: folder) : pattern
        }
        let fields = openCodeInput(request.affectedPath)
        let pattern = openCodePattern(request.summary, tool: tool)
        let runs: String? = if let fields {
            if case let .object(metadata)? = fields["metadata"] { metadata.text("command") } else { nil }
        } else {
            OpenCodeCutPatterns.metadataCommand(request.affectedPath)
        }
        if let runs, !shell {
            let folders = fields?.strings("patterns") ?? OpenCodeCutPatterns(request.affectedPath)?.whole ?? pattern.map { [$0] } ?? []
            let body = ApprovalBody.command(runs)
            return Mapped(tool: tool, body: body, reason: folders.isEmpty ? nil : "in " + folders.joined(separator: ", "),
                          rowText: rowText(body))
        }
        let text: String
        if let runs {
            text = runs
        } else if let fields {
            let patterns = fields.strings("patterns")
            if let command = fields.text("command") {
                text = command
            } else if patterns.count > 1 {
                text = patterns.map(shown).joined(separator: separator)
            } else if let path = fields.text("file_path") {
                text = relative(path, to: folder)
            } else if let pattern {
                text = shown(pattern)
            } else {
                // No pattern: what else the input holds, else the plugin's sentence, the only words there are.
                text = keyValueLines(fields.filter { !isEmpty($0.value) }) ?? request.summary
            }
        } else if let cut = OpenCodeCutPatterns(request.affectedPath) {
            text = cut.text(first: pattern, separator: separator, shown: shown) ?? request.summary
        } else if let pattern {
            text = shown(pattern)
        } else {
            text = request.affectedPath
        }
        let body: ApprovalBody = shell ? .command(text) : .text(text)
        return Mapped(tool: tool, body: body, reason: nil, rowText: rowText(body))
    }

    /// The plugin's input, when upstream kept it whole: JSON that parses (a clipped one ends in "…" and does not).
    static func openCodeInput(_ text: String) -> [String: ClaudeHookJSONValue]? {
        guard text.hasPrefix("{"), case let .object(fields)? = try? JSONDecoder().decode(ClaudeHookJSONValue.self, from: Data(text.utf8))
        else { return nil }
        return fields
    }

    private static func isEmpty(_ value: ClaudeHookJSONValue) -> Bool {
        switch value {
        case .null: true
        case let .string(text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let .array(items): items.isEmpty
        case let .object(fields): fields.isEmpty
        default: false
        }
    }

    /// The first pattern in the plugin's "OpenCode wants to run Bash: git push origin main".
    static func openCodePattern(_ summary: String, tool: String) -> String? {
        let prefix = "OpenCode wants to run \(tool): "
        guard summary.hasPrefix(prefix) else { return nil }
        let pattern = summary.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return pattern.isEmpty ? nil : pattern
    }

    // MARK: Claude

    private static func claudeContent(_ request: PermissionRequest, input: ClaudeHookJSONValue?, folder: String?) -> Mapped {
        let tool = request.toolName.flatMap { $0.isEmpty ? nil : $0 } ?? request.title
        let fallbackReason = claudeReason(request.summary)
        guard case let .object(fields)? = input else {
            // Not read (yet): what the request carries. Its command ends in "…" when upstream clipped it.
            let shown = request.affectedPath
            let body: ApprovalBody = tool == "Bash" ? .command(shown)
                : fileTools.contains(tool) || tool == "Read" ? .text(relative(shown, to: folder)) : .text(shown)
            return Mapped(tool: tool, body: body, reason: fallbackReason, rowText: rowText(body))
        }
        var reason: String?
        let body: ApprovalBody
        switch tool {
        case "Bash":
            body = .command(fields.text("command") ?? request.affectedPath)
            reason = fields.text("description")
        case "Edit":
            let path = relative(fields.text("file_path") ?? request.affectedPath, to: folder)
            body = .diff([FileDiff.change(path: path, edits: [(fields.raw("old_string") ?? "", fields.raw("new_string") ?? "")])])
            if fields["replace_all"] == .boolean(true) { reason = "Every occurrence" }
        case "MultiEdit":
            let path = relative(fields.text("file_path") ?? request.affectedPath, to: folder)
            var edits: [(String, String)] = []
            if case let .array(items)? = fields["edits"] {
                for case let .object(edit) in items { edits.append((edit.raw("old_string") ?? "", edit.raw("new_string") ?? "")) }
            }
            body = .diff([FileDiff.change(path: path, edits: edits)])
        case "Write":
            let path = relative(fields.text("file_path") ?? request.affectedPath, to: folder)
            body = .diff([FileDiff.written(path: path, content: fields.raw("content") ?? "")])
        case "NotebookEdit":
            let path = relative(fields.text("notebook_path") ?? request.affectedPath, to: folder)
            if fields.text("edit_mode") == "delete" {
                body = .text(path)
                reason = "Deletes a cell"
            } else {
                body = .diff([FileDiff.written(path: path, content: fields.raw("new_source") ?? "")])
            }
        case "WebFetch":
            body = .text(fields.text("url") ?? request.affectedPath)
            reason = fields.text("prompt")
        case "WebSearch":
            body = .text(fields.text("query") ?? request.affectedPath)
        case "Read":
            body = .text(relative(fields.text("file_path") ?? request.affectedPath, to: folder))
        case "Glob", "Grep":
            body = .text(fields.text("pattern") ?? request.affectedPath)
            reason = fields.text("path").map { "in " + relative($0, to: folder) }
        case "Task", "Agent":
            body = .text(fields.text("prompt") ?? fields.text("description") ?? request.affectedPath)
            reason = fields.text("prompt") == nil ? nil : fields.text("description")
        default:
            body = .text(keyValueLines(fields) ?? request.affectedPath)
        }
        return Mapped(tool: tool, body: body, reason: reason ?? fallbackReason, rowText: rowText(body))
    }

    /// The request's summary, unless it is upstream's own sentence ("Claude wants to run Bash.", "… needs permission
    /// to continue."): a hook that carried a title or a message shows it.
    static func claudeReason(_ summary: String) -> String? {
        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasSuffix(" needs permission to continue.") { return nil }
        if text.range(of: #"^\S+( \S+)? wants to (run|exit plan mode)"#, options: .regularExpression) != nil { return nil }
        return text
    }

    /// An unknown tool's input (an MCP tool): one `key: value` line per field, strings as written, the rest as JSON.
    static func keyValueLines(_ fields: [String: ClaudeHookJSONValue]) -> String? {
        let lines = fields.keys.sorted().compactMap { key -> String? in
            guard let value = fields[key] else { return nil }
            if case let .string(text) = value { return "\(key): \(text)" }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(value), let json = String(data: data, encoding: .utf8) else { return nil }
            return "\(key): \(json)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// A path inside the session's folder relative to it, else with `~` for the home folder.
    static func relative(_ path: String, to folder: String?) -> String {
        if let folder, !folder.isEmpty {
            let root = folder.hasSuffix("/") ? folder : folder + "/"
            if path.hasPrefix(root), path.count > root.count { return String(path.dropFirst(root.count)) }
        }
        return EngineSessionsModel.abbreviated(path)
    }

    /// The row's one line: its start is all a row shows, so at most `rowTextLength` characters are kept.
    static func rowText(_ body: ApprovalBody) -> String {
        switch body {
        case let .command(text), let .text(text):
            text.prefix(rowTextLength * 2).split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " ").prefix(rowTextLength).description
        case let .diff(files):
            files.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ")
        }
    }

    static let rowTextLength = 300
}

/// What an approval card's box shows.
enum ApprovalBody: Equatable, Sendable {
    /// A shell command, whole and as written (Bash, Codex's shell): wrapped, scrolling past the box's height.
    case command(String)
    /// A change to files: each file and its lines as a compact diff.
    case diff([FileDiff])
    /// What another tool is about: a URL, a query, a pattern, a path, or its input as `key: value` lines.
    case text(String)
}

/// One file's change as the card draws it: the changed lines with one line of context either side, a longer
/// unchanged run as a gap.
struct FileDiff: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case added, removed, context, gap }
        var kind: Kind
        var text: String
    }

    /// Relative to the session's folder when inside it, else with `~`.
    var path: String
    var lines: [Line]
    var added: Int
    var removed: Int
    /// Lines left out past the card's bound (`ApprovalContent.diffLineLimit`); the box says so.
    var omitted = 0
    var deleted = false

    /// An Edit (one pair) or a MultiEdit (a pair each, a gap between them).
    static func change(path: String, edits: [(old: String, new: String)]) -> FileDiff {
        var lines: [Line] = []
        for (index, edit) in edits.enumerated() {
            if index > 0 { lines.append(Line(kind: .gap, text: "")) }
            lines += LineDiff.lines(old: edit.old, new: edit.new)
        }
        return bounded(path: path, lines)
    }

    /// A written file: every line added.
    static func written(path: String, content: String) -> FileDiff {
        bounded(path: path, LineDiff.split(content).map { Line(kind: .added, text: $0) })
    }

    static func bounded(path: String, _ lines: [Line], deleted: Bool = false) -> FileDiff {
        let kept = lines.prefix(ApprovalContent.diffLineLimit).map { line in
            line.text.count > ApprovalContent.diffLineLength
                ? Line(kind: line.kind, text: String(line.text.prefix(ApprovalContent.diffLineLength - 1)) + "…") : line
        }
        return FileDiff(path: path, lines: Array(kept), added: lines.count { $0.kind == .added },
                        removed: lines.count { $0.kind == .removed }, omitted: max(0, lines.count - kept.count), deleted: deleted)
    }
}

/// A line diff small enough for a card: the lines both texts share at their ends are trimmed, and what is left is
/// compared line by line (longest common subsequence) when both sides hold at most `exactLimit` lines, else shown as
/// all removed, then all added.
enum LineDiff {
    static let exactLimit = 400
    static let context = 1

    static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    static func lines(old: String, new: String) -> [FileDiff.Line] {
        let a = split(old), b = split(new)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let midA = Array(a[prefix..<(a.count - suffix)]), midB = Array(b[prefix..<(b.count - suffix)])
        var body: [FileDiff.Line] = a[..<prefix].map { .init(kind: .context, text: $0) }
        body += middle(midA, midB)
        body += a[(a.count - suffix)...].map { .init(kind: .context, text: $0) }
        return folded(body)
    }

    private static func middle(_ a: [String], _ b: [String]) -> [FileDiff.Line] {
        guard !a.isEmpty, !b.isEmpty, a.count <= exactLimit, b.count <= exactLimit else {
            return a.map { .init(kind: .removed, text: $0) } + b.map { .init(kind: .added, text: $0) }
        }
        // table[i][j]: the common subsequence's length of a[i...] and b[j...].
        var table = [[Int32]](repeating: [Int32](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var lines: [FileDiff.Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                lines.append(.init(kind: .context, text: a[i])); i += 1; j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] > table[i + 1][j] {
                lines.append(.init(kind: .added, text: b[j])); j += 1
            } else {
                lines.append(.init(kind: .removed, text: a[i])); i += 1
            }
        }
        return lines
    }

    /// Keeps `context` unchanged lines either side of a change; a longer unchanged run becomes one gap.
    private static func folded(_ lines: [FileDiff.Line]) -> [FileDiff.Line] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for index in changed { for near in max(0, index - context)...min(lines.count - 1, index + context) { keep.insert(near) } }
        var result: [FileDiff.Line] = []
        var skipped = false
        for index in lines.indices {
            if keep.contains(index) {
                if skipped, !result.isEmpty { result.append(.init(kind: .gap, text: "")) }
                skipped = false
                result.append(lines[index])
            } else {
                skipped = true
            }
        }
        return result
    }
}

/// Codex's `apply_patch` text (`*** Begin Patch` … `*** End Patch`) as one diff per file.
enum CodexPatch {
    static let begin = "*** Begin Patch"

    static func files(_ patch: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var path: String?
        var lines: [FileDiff.Line] = []
        var deleted = false
        func flush() {
            if let path { files.append(FileDiff.bounded(path: EngineSessionsModel.abbreviated(path), lines, deleted: deleted)) }
            path = nil; lines = []; deleted = false
        }
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("*** ") {
                for (marker, isDelete) in [("*** Update File: ", false), ("*** Add File: ", false), ("*** Delete File: ", true)]
                where line.hasPrefix(marker) {
                    flush()
                    path = String(line.dropFirst(marker.count))
                    deleted = isDelete
                }
                continue
            }
            guard path != nil else { continue }
            if line.hasPrefix("@@") {
                if !lines.isEmpty { lines.append(.init(kind: .gap, text: "")) }
            } else if line.hasPrefix("+") {
                lines.append(.init(kind: .added, text: String(line.dropFirst())))
            } else if line.hasPrefix("-") {
                lines.append(.init(kind: .removed, text: String(line.dropFirst())))
            } else if line.hasPrefix(" ") {
                lines.append(.init(kind: .context, text: String(line.dropFirst())))
            }
        }
        flush()
        return files
    }
}

private extension Dictionary where Key == String, Value == ClaudeHookJSONValue {
    /// A string field with text in it.
    func text(_ key: String) -> String? {
        guard case let .string(value)? = self[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// A string field as it is, empty or not.
    func raw(_ key: String) -> String? {
        if case let .string(value)? = self[key] { value } else { nil }
    }

    /// The strings of an array field (OpenCode's `patterns`); none for anything else.
    func strings(_ key: String) -> [String] {
        guard case let .array(items)? = self[key] else { return [] }
        return items.compactMap { item in if case let .string(text) = item { text } else { nil } }
    }
}

/// The patterns an OpenCode request's input still shows once upstream cut it (`{"patterns":["git status","git push
/// --f…`): the plugin puts one pattern per command first in its JSON, and the bridge keeps 110 characters, so the start
/// of the list is there even when the JSON no longer parses.
struct OpenCodeCutPatterns: Equatable {
    /// The patterns the text holds whole.
    var whole: [String]
    /// The start of the pattern the text was cut in ("" when it was cut right after a comma): another one follows.
    var cut: String?
    /// The list ended before the cut: `whole` is every pattern.
    var closed: Bool

    init(whole: [String], cut: String?, closed: Bool) {
        self.whole = whole
        self.cut = cut
        self.closed = closed
    }

    /// nil when the text does not start as the plugin's input does, or is not JSON strings where they should be.
    init?(_ text: String) {
        let start = #"{"patterns":["#
        guard text.hasPrefix(start) else { return nil }
        var rest = Substring(text.dropFirst(start.count))
        if rest.hasSuffix("…") { rest = rest.dropLast() }
        let scalars = Array(rest.unicodeScalars)
        var index = 0
        var whole: [String] = []
        if scalars.first == "]" {
            self.init(whole: [], cut: nil, closed: true)
            return
        }
        while index < scalars.count {
            guard scalars[index] == "\"" else { return nil }
            index += 1
            var value = String.UnicodeScalarView()
            var ended = false
            while index < scalars.count {
                let scalar = scalars[index]
                if scalar == "\"" {
                    ended = true
                    index += 1
                    break
                }
                guard scalar == "\\" else {
                    value.append(scalar)
                    index += 1
                    continue
                }
                guard index + 1 < scalars.count else { index = scalars.count; break }
                switch scalars[index + 1] {
                case "n": value.append("\n")
                case "t": value.append("\t")
                case "r": value.append("\r")
                case "b", "f": break
                case "u":
                    guard index + 5 < scalars.count,
                          let code = UInt32(String(String.UnicodeScalarView(scalars[(index + 2)...(index + 5)])), radix: 16) else {
                        index = scalars.count
                        continue
                    }
                    if let decoded = Unicode.Scalar(code) { value.append(decoded) }
                    index += 4
                default: value.append(scalars[index + 1])
                }
                index += 2
            }
            guard ended else {
                self.init(whole: whole, cut: String(value), closed: false)
                return
            }
            whole.append(String(value))
            guard index < scalars.count else { break }
            if scalars[index] == "]" {
                self.init(whole: whole, cut: nil, closed: true)
                return
            }
            guard scalars[index] == "," else { return nil }
            index += 1
            if index == scalars.count {
                self.init(whole: whole, cut: "", closed: false)
                return
            }
        }
        self.init(whole: whole, cut: nil, closed: false)
    }

    /// The command a cut input still shows in `"metadata":{"command":"…`, with `…` when the cut fell in it; nil when
    /// the cut came before it.
    static func metadataCommand(_ text: String) -> String? {
        guard let start = text.range(of: #""metadata":{"command":""#) else { return nil }
        var rest = Substring(text[start.upperBound...])
        if rest.hasSuffix("…") { rest = rest.dropLast() }
        var value = String.UnicodeScalarView()
        var iterator = rest.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\"" {
                let command = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
                return command.isEmpty ? nil : command
            }
            guard scalar == "\\" else { value.append(scalar); continue }
            guard let escaped = iterator.next() else { break }
            switch escaped {
            case "n": value.append("\n")
            case "t": value.append("\t")
            case "r", "b", "f": break
            case "u":
                var hex = ""
                while hex.unicodeScalars.count < 4, let digit = iterator.next() { hex.unicodeScalars.append(digit) }
                if let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code) { value.append(decoded) }
            default: value.append(escaped)
            }
        }
        let command = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command + "…"
    }

    /// What the box shows: every pattern it knows, joined by `separator` (` && ` between commands), the first whole
    /// from the plugin's sentence (`first`) when the cut fell in it, and `…` where more may follow or one was cut; nil
    /// when there is no pattern at all.
    func text(first: String?, separator: String, shown: (String) -> String) -> String? {
        if closed {
            guard whole.count > 1 else { return (first ?? whole.first).map(shown) }
            return whole.map(shown).joined(separator: separator)
        }
        // Where another pattern may follow, or not: a line of its own after files, a space after a command.
        let maybeMore = separator.contains("\n") ? "\n…" : " …"
        guard !whole.isEmpty else {
            // Cut in the first pattern: the sentence has it whole, but not whether another follows.
            guard let first = first ?? cut.flatMap({ $0.isEmpty ? nil : $0 + "…" }) else { return nil }
            return shown(first) + maybeMore
        }
        let known = whole.map(shown).joined(separator: separator)
        guard let cut else { return known + maybeMore }
        return known + separator + (cut.isEmpty ? "…" : shown(cut) + "…")
    }
}
