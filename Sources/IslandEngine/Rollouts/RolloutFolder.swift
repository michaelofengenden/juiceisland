import Foundation
import OpenIslandCore

/// Folds rollout lines with upstream's `CodexRolloutReducer` and gets the snapshot upstream's fold gets, for a
/// fraction of its time (P83). The reducer builds a new `ISO8601DateFormatter` for every line's timestamp, about
/// 160 µs each on this Mac and most of a fold's time. Here each line reaches the reducer without its timestamp, which
/// it reads for `updatedAt` alone, and `updatedAt` is settled once, in `finish()`: the time of the newest `event_msg`
/// line (the reducer sets `updatedAt` from every one), or of a newer line that sets it, found by folding that line
/// alone, whole. Only a `response_item`, or a line whose type is not where Codex puts it, can leave `updatedAt` as it
/// was (a developer message, one with no text the reducer keeps).
struct RolloutFolder {
    private(set) var snapshot: CodexRolloutSnapshot
    /// The time of the newest line known to set `updatedAt`.
    private var newestTime: Date?
    /// Lines newer than `newestTime` that may set `updatedAt`, oldest first, kept whole to be folded alone.
    private var laterLines: [String] = []
    private var laterLineBytes = 0
    private var formatter: ISO8601DateFormatter?

    /// More lines that may set `updatedAt` after the newest `event_msg` than this, or more bytes of them, and the
    /// oldest are let go. A turn's lines end in an `event_msg`, so the list is short or empty.
    static let laterLineLimit = 32
    static let laterLineByteLimit = 4 << 20

    private enum Kind { case event, mayDate, undated }

    init(_ snapshot: CodexRolloutSnapshot = CodexRolloutSnapshot()) {
        self.snapshot = snapshot
    }

    mutating func apply(_ rawLine: String) {
        // Codex's own text written as a user message (`<turn_aborted>`, `<user_shell_command>`, an async question's
        // reply envelope, …) is never a prompt, and never reopens a finished turn (P155).
        guard let line = Self.cleaned(rawLine) else { return }
        guard let (time, rest) = Self.split(line) else {
            // Not in Codex's shape: the reducer gets the line whole and sets `updatedAt` itself when the line does.
            let kept = snapshot.updatedAt
            snapshot.updatedAt = nil
            CodexRolloutReducer.apply(line: line, to: &snapshot)
            Self.applyReviewStart(line, to: &snapshot)
            if let time = snapshot.updatedAt { settle(at: time) }
            snapshot.updatedAt = kept
            return
        }
        var untimed = "{"
        untimed.append(contentsOf: rest)
        CodexRolloutReducer.apply(line: untimed, to: &snapshot)
        Self.applyReviewStart(line, to: &snapshot)
        switch Self.kind(of: rest) {
        case .event:
            if let date = parse(time) { settle(at: date) }
        case .mayDate:
            laterLines.append(line)
            laterLineBytes += line.utf8.count
            while laterLines.count > Self.laterLineLimit || (laterLineBytes > Self.laterLineByteLimit && laterLines.count > 1) {
                laterLineBytes -= laterLines.removeFirst().utf8.count
            }
        case .undated:
            break
        }
    }

    /// A review is a turn of its chat, but Codex writes no turn start for it in the chat's rollout (`core/src/session/
    /// review.rs`: "Review turns … do not emit a parent TurnStarted"), only that the chat entered review mode: an
    /// `entered_review_mode` event in a legacy rollout, an `item_completed` of an `EnteredReviewMode` item in a paginated
    /// one. Read as the turn's start, so the chat's row runs while its review runs; the review's end is the chat's own
    /// `task_complete` (P217). Only a line that names one is parsed.
    static func applyReviewStart(_ line: String, to snapshot: inout CodexRolloutSnapshot) {
        guard line.contains("entered_review_mode") || line.contains("EnteredReviewMode"), isReviewStart(line) else { return }
        snapshot.phase = .running
        snapshot.isCompleted = false
        snapshot.isInterrupted = false
        snapshot.currentTool = nil
        snapshot.currentCommandPreview = nil
        snapshot.summary = StatusWord.reviewingSummary
    }

    static func isReviewStart(_ line: String) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              object["type"] as? String == "event_msg", let payload = object["payload"] as? [String: Any] else { return false }
        if payload["type"] as? String == "entered_review_mode" { return true }
        return (payload["item"] as? [String: Any])?["type"] as? String == "EnteredReviewMode"
    }

    /// The line as the reducer may fold it: nil for Codex's own text written as a user message, and an assistant item
    /// without the hidden markup Codex strips from its own `agent_message` (`strip_hidden_assistant_markup`): memory
    /// citations go, a Plan-mode reply's `<proposed_plan>` wrapper is taken off its plan (P155). Every line that
    /// reaches upstream's reducer, the scanner's unterminated last line too, goes through here.
    static func cleaned(_ line: String) -> String? {
        if isMachineUserMessage(line) { return nil }
        if let owners = withOwnersWords(line) { return owners }
        guard line.contains(#""role":"assistant""#),
              line.contains("<oai-mem-citation>") || line.contains("<proposed_plan>") else { return line }
        // Inside the JSON string: newlines are `\n`, and a slash may be escaped.
        var result = line.replacingOccurrences(of: #"<oai-mem-citation>.*?<\\?/oai-mem-citation>"#, with: "",
                                               options: .regularExpression)
        result = result.replacingOccurrences(of: #"<proposed_plan>(\\n)?"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(\\n)?<\\?/proposed_plan>"#, with: "", options: .regularExpression)
        return result
    }

    /// A user message the Codex app wrote with its own context first (`<in-app-browser-context …>` … `## My request:`,
    /// P661), or a shared thread's member's message in its wrapper (P664), as the line with each of its texts cut to the
    /// owner's words (`PromptText.human`); nil when the line is no such message. Upstream's reducer cuts only at the
    /// IDE's older `## My request for Codex:` and then keeps 110 characters, which were the context's first ones. The
    /// line keeps Codex's shape, `{"timestamp":…,"type":…`, so the fold still dates it without the reducer's formatter.
    static func withOwnersWords(_ line: String) -> String? {
        guard line.contains(#""role":"user""#) || line.contains(#""user_message""#),
              line.contains("## My request:") || line.contains("<codex_multi_user_message>")
                || PromptText.inlineBlocks.contains(where: { line.contains("<" + $0) }),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              var payload = object["payload"] as? [String: Any], let type = object["type"] as? String else { return nil }
        func words(_ text: String) -> String? {
            guard let human = PromptText.human(text), human != text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
            return human
        }
        switch (type, payload["type"] as? String) {
        case ("response_item", "message"):
            guard payload["role"] as? String == "user", let blocks = payload["content"] as? [[String: Any]] else { return nil }
            var changed = false
            let kept: [[String: Any]] = blocks.compactMap { block in
                guard block["type"] as? String == "input_text", let text = block["text"] as? String else { return block }
                guard PromptText.human(text) != nil else {
                    changed = true
                    return nil
                }
                guard let owners = words(text) else { return block }
                changed = true
                var copy = block
                copy["text"] = owners
                return copy
            }
            guard changed else { return nil }
            payload["content"] = kept
        case ("event_msg", "user_message"):
            guard let text = payload["message"] as? String, let owners = words(text) else { return nil }
            payload["message"] = owners
        default:
            return nil
        }
        var members: [String] = []
        for key in ["timestamp", "type"] {
            if let value = object[key], let encoded = encode(value) { members.append("\"" + key + "\":" + encoded) }
        }
        for (key, value) in object where !["timestamp", "type", "payload"].contains(key) {
            guard let name = encode(key), let encoded = encode(value) else { return nil }
            members.append(name + ":" + encoded)
        }
        guard let body = encode(payload) else { return nil }
        members.append(#""payload":"# + body)
        return "{" + members.joined(separator: ",") + "}"
    }

    private static func encode(_ value: Any) -> String? {
        (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// A user message (`response_item` message of role user, or `event_msg` `user_message`) whose every text is
    /// machine text by `PromptText.human`. Only lines that can hold one are parsed.
    static func isMachineUserMessage(_ line: String) -> Bool {
        guard line.contains(#""role":"user""#) || line.contains(#""user_message""#),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let payload = object["payload"] as? [String: Any] else { return false }
        let texts: [String]
        switch (object["type"] as? String, payload["type"] as? String) {
        case ("response_item", "message"):
            guard payload["role"] as? String == "user", let blocks = payload["content"] as? [[String: Any]] else { return false }
            texts = blocks.compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }
        case ("event_msg", "user_message"):
            texts = [payload["message"] as? String].compactMap { $0 }
        default:
            return false
        }
        let written = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return !written.isEmpty && written.allSatisfy { PromptText.human($0) == nil }
    }

    /// The snapshot with `updatedAt` settled; `updatedAt` stays as it came in when no line folded since sets it.
    mutating func finish() -> CodexRolloutSnapshot {
        for line in laterLines.reversed() {
            var alone = CodexRolloutSnapshot()
            CodexRolloutReducer.apply(line: line, to: &alone)
            if let time = alone.updatedAt {
                snapshot.updatedAt = time
                return snapshot
            }
        }
        if let newestTime { snapshot.updatedAt = newestTime }
        return snapshot
    }

    private mutating func settle(at time: Date) {
        newestTime = time
        laterLines.removeAll()
        laterLineBytes = 0
    }

    /// `{"timestamp":"<time>",<rest>` as `<time>` and `<rest>`: every line Codex writes starts so.
    private static func split(_ line: String) -> (Substring, Substring)? {
        let prefix = #"{"timestamp":""#
        guard line.hasPrefix(prefix) else { return nil }
        let timeStart = line.utf8.index(line.startIndex, offsetBy: prefix.utf8.count)
        guard let quote = line.utf8[timeStart...].firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        let comma = line.utf8.index(after: quote)
        guard comma < line.endIndex, line.utf8[comma] == UInt8(ascii: ",") else { return nil }
        return (line[timeStart..<quote], line[line.utf8.index(after: comma)...])
    }

    /// The line's type, read where Codex writes it: before the payload, after the timestamp and any short member such
    /// as `"ordinal"`. The reducer folds only `event_msg` and `response_item` lines; a line whose type is not found
    /// there may be either.
    private static func kind(of rest: Substring) -> Kind {
        let head = Array(rest.utf8.prefix(256))
        guard let type = find(Array(#""type":""#.utf8), in: head) else { return .mayDate }
        if let payload = find(Array(#""payload":"#.utf8), in: head), payload < type { return .mayDate }
        let value = head[(type + 8)...]
        if value.starts(with: #"event_msg""#.utf8) { return .event }
        if value.starts(with: #"response_item""#.utf8) { return .mayDate }
        return .undated
    }

    private static func find(_ pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for start in 0...(bytes.count - pattern.count) where bytes[start] == pattern[0] {
            if bytes[start..<(start + pattern.count)].elementsEqual(pattern) { return start }
        }
        return nil
    }

    /// Upstream's timestamp rule, with one formatter per fold.
    private mutating func parse(_ time: Substring) -> Date? {
        if formatter == nil {
            let made = ISO8601DateFormatter()
            made.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            formatter = made
        }
        return formatter?.date(from: String(time))
    }
}
