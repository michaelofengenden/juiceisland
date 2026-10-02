import Foundation
import IslandEngine

/// Row wording shared by the window (stream C) and the island (stream D). Owner: stream C.
/// Line 1 is the chat's title, after the repo in grey where the row has room for it (the repo left off when the title
/// is the repo, P204); line 2 is one short status, which never says the title's prompt again (P203).
enum SessionRowText {
    /// File tools show the basename only; other tools their argument.
    static let fileTools: Set<String> = ["Edit", "Write", "Read", "MultiEdit", "NotebookEdit"]

    /// Line 1's parts: the repo, and the title. The repo is left off when the title is the repo, or already names it as
    /// a word ("Continue MarathonTrainingLog"), or there is none.
    static func cleanTitle(_ row: SessionRow) -> (project: String?, task: String) {
        let task = row.task.trimmingCharacters(in: .whitespaces)
        guard !row.project.isEmpty, row.titleSource != .repo, !task.isEmpty, !names(task, row.project) else {
            return (nil, task.isEmpty ? row.project : task)
        }
        return (row.project, task)
    }

    /// Whether `title` has `project` in it as a whole word, in any case.
    static func names(_ title: String, _ project: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: project) + "\\b"
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The title's full text for a tooltip when a row may cut it; nothing for a short one (as `statusHelp`). What
    /// counts is the text the row shows: the grey `repo · ` before the title (`showsProject`, as `RowTitleLine`) takes
    /// its room too.
    static func titleHelp(_ row: SessionRow, showsProject: Bool = true, limit: Int = 48) -> String {
        let shown = showsProject ? detailedTitle(row) : cleanTitle(row).task
        return shown.count > limit ? row.task : ""
    }

    /// The owner's last prompt as a status line may say it: nil when there is none, or when it is the prompt the
    /// row's title already says (a first turn, P203).
    static func shownPrompt(_ row: SessionRow) -> String? {
        guard let prompt = row.lastPrompt, !prompt.isEmpty else { return nil }
        if row.titleSource == .prompt, ChatTitleText.clean(prompt) == row.task { return nil }
        return prompt
    }

    /// The Clean status line, as plain parts: an optional coloured word, an optional mono tool verb, then text.
    struct Status: Equatable {
        enum Tone: Equatable { case approval, question, done, plain, stalled }
        var word: String?
        var tone: Tone
        var toolVerb: String?
        var text: String?
    }

    /// `now`: the clock a compacting row's time reads ("Compacting 0:42", P433); nil says "Compacting" alone.
    static func cleanStatus(_ row: SessionRow, now: Date? = nil) -> Status {
        if row.isStalled { return stalledStatus(row) }
        // "Limit reached · resets 15:00", "API error · overloaded" in place of "Turn failed" or the last message (P700).
        if let limit = row.limit { return Status(word: limit.word, tone: limit.warns ? .approval : .plain, toolVerb: nil, text: limit.text) }
        switch row.status {
        case let .needsApproval(tool):
            if isPlan(tool) { return Status(word: "Plan ready", tone: .approval, toolVerb: nil, text: planSteps(row.detail).map(stepsText)) }
            return Status(word: "Needs approval", tone: .approval, toolVerb: nil, text: approvalText(row, tool: tool))
        case .question:
            // As the Detailed row, without "You:": the owner's last prompt, else the question.
            return Status(word: "Question", tone: .question, toolVerb: nil, text: shownPrompt(row) ?? row.detail)
        case let .tool(name, detail):
            let argument = detail.map { fileTools.contains(name) ? URL(fileURLWithPath: $0).lastPathComponent : $0 }
            return Status(word: nil, tone: .plain, toolVerb: name, text: argument)
        case let .denied(tool):
            return Status(word: nil, tone: .plain, toolVerb: nil, text: StatusWord.deniedSummary(tool: tool))
        case .thinking:
            return Status(word: nil, tone: .plain, toolVerb: nil, text: "Thinking")
        case .compacting:
            return Status(word: nil, tone: .plain, toolVerb: nil, text: CompactionText.word(since: row.compactingSince, now: now))
        case let .subagents(count, workflows):
            // A main agent waiting on its background agents or workflows (P370, P510), a Codex chat's subagents (P212).
            return Status(word: nil, tone: .plain, toolVerb: nil, text: StatusWord.subagentsText(count, workflows: workflows))
        case .reviewing:
            // A Codex chat whose review runs (P217).
            return Status(word: nil, tone: .plain, toolVerb: nil, text: "Reviewing")
        case .working:
            // Clean drops the "You:" prefix (prototype §1.3.1).
            return Status(word: nil, tone: .plain, toolVerb: nil, text: shownPrompt(row) ?? "Working")
        case .done:
            // The green check says Done; the line is the last message.
            return Status(word: nil, tone: .done, toolVerb: nil, text: row.detail ?? "Done")
        case .interrupted:
            return Status(word: "Interrupted", tone: .plain, toolVerb: nil, text: nil)
        case .failed:
            return Status(word: "Turn failed", tone: .approval, toolVerb: nil, text: row.detail)
        }
    }

    /// A stalled turn's line (P312): "Stalled", then what it was on, the tool and its argument, else the owner's last
    /// prompt. The glyph holds still and says nothing of it, so the word stays.
    static func stalledStatus(_ row: SessionRow) -> Status {
        if case let .tool(name, detail) = row.status {
            let argument = detail.map { fileTools.contains(name) ? URL(fileURLWithPath: $0).lastPathComponent : $0 }
            return Status(word: "Stalled", tone: .stalled, toolVerb: name, text: argument)
        }
        return Status(word: "Stalled", tone: .stalled, toolVerb: nil, text: shownPrompt(row))
    }

    /// What an approval is about on a row: "Bash: git push", after the subagent that asks when one does ("worker ·
    /// Bash: git push"); nil when the request says nothing of its own (the word stands alone).
    static func approvalText(_ row: SessionRow, tool: String?) -> String? {
        guard let command = row.detail.map({ detail in tool.map { "\($0): \(detail)" } ?? detail }) else { return nil }
        return [row.asker, command].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Detailed rows (the window and the Detailed island)

    /// Detailed line 1 as text: `repo · title`, by `cleanTitle`'s rule.
    static func detailedTitle(_ row: SessionRow) -> String {
        let parts = cleanTitle(row)
        return parts.project.map { "\($0) · \(parts.task)" } ?? parts.task
    }

    /// Detailed line 2: an optional coloured word, then `You:` and the last prompt, or what the state is about.
    struct DetailedStatus: Equatable {
        enum Tone: Equatable { case approval, done, muted, stalled }
        var word: String?
        var tone: Tone
        /// True when `text` is the owner's last prompt (drawn after a grey "You:").
        var isPrompt: Bool
        var text: String?
    }

    static func detailedStatus(_ row: SessionRow, now: Date? = nil) -> DetailedStatus {
        let prompt = shownPrompt(row)
        // Stalled, then the prompt; the tool line under it says what it was on (P312).
        if row.isStalled { return DetailedStatus(word: "Stalled", tone: .stalled, isPrompt: prompt != nil, text: prompt) }
        if let limit = row.limit { return limitStatus(limit) }
        switch row.status {
        case let .needsApproval(tool):
            if isPlan(tool) {
                return DetailedStatus(word: "Plan ready", tone: .approval, isPrompt: false, text: planSteps(row.detail).map(stepsText))
            }
            return DetailedStatus(word: "Needs approval", tone: .approval, isPrompt: false, text: approvalText(row, tool: tool))
        case .question:
            return DetailedStatus(word: "Question", tone: .approval, isPrompt: prompt != nil, text: prompt ?? row.detail)
        case .done:
            return DetailedStatus(word: "Done", tone: .done, isPrompt: false, text: row.detail)
        case .interrupted:
            return DetailedStatus(word: "Interrupted", tone: .muted, isPrompt: prompt != nil, text: prompt)
        case .failed:
            return DetailedStatus(word: "Turn failed", tone: .approval, isPrompt: false, text: row.detail)
        case .tool, .thinking, .compacting, .working, .denied, .subagents, .reviewing:
            if let prompt { return DetailedStatus(word: nil, tone: .muted, isPrompt: true, text: prompt) }
            return DetailedStatus(word: nil, tone: .muted, isPrompt: false, text: runningWord(row, now: now))
        }
    }

    /// The Done card's header line 2: the word and the age ("Done · 6m"), since the card shows the message itself.
    static func doneCardStatus(_ row: SessionRow, now: Date) -> DetailedStatus {
        if let limit = row.limit {
            var status = limitStatus(limit)
            status.text = status.text ?? age(row.updatedAt, now: now)
            return status
        }
        if row.status == .failed { return DetailedStatus(word: "Turn failed", tone: .approval, isPrompt: false, text: age(row.updatedAt, now: now)) }
        let interrupted = row.status == .interrupted
        return DetailedStatus(word: interrupted ? "Interrupted" : "Done", tone: interrupted ? .muted : .done, isPrompt: false,
                              text: age(row.updatedAt, now: now))
    }

    /// A limit's line (P700): its word in the needs-you colour while it holds, muted once a usage limit reset.
    static func limitStatus(_ limit: RowLimit) -> DetailedStatus {
        DetailedStatus(word: limit.word, tone: limit.warns ? .approval : .muted, isPrompt: false, text: limit.text)
    }

    /// Detailed line 3 while running: the tool verb (mono) and its full argument, or the honest status word.
    static func toolLine(_ row: SessionRow, now: Date? = nil) -> (verb: String?, text: String)? {
        switch row.status {
        case let .tool(name, detail): return (name, detail ?? "")
        case .thinking, .compacting, .denied, .subagents, .reviewing:
            // Without a prompt, line 2 already says it.
            return shownPrompt(row) != nil ? (nil, runningWord(row, now: now) ?? "") : nil
        default: return nil
        }
    }

    private static func runningWord(_ row: SessionRow, now: Date?) -> String? {
        switch row.status {
        case .thinking: "Thinking"
        case .compacting: CompactionText.word(since: row.compactingSince, now: now)
        case let .denied(tool): StatusWord.deniedSummary(tool: tool)
        case .working: "Working"
        case let .subagents(count, workflows): StatusWord.subagentsText(count, workflows: workflows)
        case .reviewing: "Reviewing"
        default: nil
        }
    }

    // MARK: Plans

    /// Claude's plan approval arrives as a permission request for ExitPlanMode.
    static func isPlan(_ tool: String?) -> Bool { tool == "ExitPlanMode" }

    /// "N steps": the plan's numbered lines (`1.`, `2)`), nil when it has none.
    static func planSteps(_ plan: String?) -> Int? {
        guard let plan else { return nil }
        let count = plan.split(whereSeparator: \.isNewline).filter { line in
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let digits = trimmed.prefix { $0.isNumber }
            guard !digits.isEmpty, let next = trimmed.dropFirst(digits.count).first else { return false }
            return next == "." || next == ")"
        }.count
        return count > 0 ? count : nil
    }

    static func stepsText(_ steps: Int) -> String { steps == 1 ? "1 step" : "\(steps) steps" }

    /// Short age: `now`, `3m`, `1h`, `2d`.
    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }

    /// How long something has run: minutes up to 99 (the prototype's long run reads `93m`), then like `age`.
    static func runningTime(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds >= 60, seconds < 100 * 60 { return "\(Int(seconds / 60))m" }
        return age(date, now: now)
    }
}

/// Why a turn failed, in plain words (P132). Claude's StopFailure names one of a few error kinds, which the bridge
/// passes on as the completion's summary; anything else it passes on (a message text) is shown as it is.
enum TurnFailure {
    static let words: [String: String] = [
        "rate_limit": "Rate limited",
        "authentication_failed": "Signed out",
        "billing_error": "Billing problem",
        "invalid_request": "Invalid request",
        "server_error": "Server error",
        "max_output_tokens": "Hit the output limit",
        "unknown": "Unknown error",
    ]

    /// "rate_limit" → "Rate limited"; other text unchanged.
    static func words(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return words[trimmed.lowercased()] ?? trimmed
    }

    /// Short enough for the card's status line ("Turn failed · Signed out"); longer text shows as the card's message.
    static func fitsStatusLine(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40 && !text.contains(where: \.isNewline)
    }
}
