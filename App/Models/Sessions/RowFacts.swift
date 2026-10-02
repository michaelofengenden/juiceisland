import Foundation
import IslandEngine

/// What a row says of a session beyond its state (P310): the model ("Opus 5.5", "GPT-6 Astra"), the permission mode when
/// it is not the default ("plan", "bypass") and the task list's progress while something is left to do ("3/7"). Shown on
/// Detailed rows, and in a Clean row's peek, which is the only place Clean says them: every fact once.
struct RowFacts: Equatable, Sendable {
    var model: String?
    var mode: String?
    var progress: String?
    /// The reasoning effort, said only beside a model (P443): "high" alone would say nothing of what runs at it.
    var effort: String?

    init(model: String? = nil, mode: String? = nil, progress: String? = nil, effort: String? = nil) {
        self.model = model
        self.mode = mode
        self.progress = progress
        self.effort = model == nil ? nil : effort
    }

    init(_ facts: SessionFacts) {
        self.init(model: facts.model.flatMap(ModelName.short), mode: facts.mode.flatMap(ModeName.short),
                  progress: facts.tasks.flatMap { $0.isOpen ? "\($0.done)/\($0.total)" : nil },
                  effort: facts.effort.flatMap(EffortName.short))
    }

    /// In the order a row says them: the model and its effort, the mode, the progress.
    var items: [String] { [model, effort, mode, progress].compactMap { $0 } }
    var isEmpty: Bool { items.isEmpty }
}

/// A model id as a row names it: `claude-opus-5-5[1m]` → "Opus 5.5", `claude-3-5-sonnet-20241022` → "Sonnet 3.5",
/// `gpt-6-astra` → "GPT-6 Astra", `gpt-5.1-codex-max` → "GPT-5.1 Codex Max", `gemini-2.5-pro` → "Gemini 2.5 Pro". A
/// date or a context suffix (`-20250805`, `[1m]`) says nothing on a row and goes; so does the "claude" prefix, which the
/// row's agent mark already says. nil for nothing, or for an id too long to be a name.
enum ModelName {
    static let limit = 24

    static func short(_ raw: String) -> String? {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let bracket = id.firstIndex(of: "[") { id = String(id[..<bracket]) }
        if let at = id.firstIndex(of: "@") { id = String(id[..<at]) }
        var parts = id.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        // A release date (8 digits) at the end.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard !parts.isEmpty, id != "<synthetic>" else { return nil }
        let name: String
        if parts.first == "claude" {
            parts.removeFirst()
            // `opus-5-5` and the older `3-5-sonnet`: the family, then its version.
            let numbers = parts.filter { $0.allSatisfy(\.isNumber) }
            let words = parts.filter { !$0.allSatisfy(\.isNumber) }
            guard !words.isEmpty || !numbers.isEmpty else { return nil }
            name = (words.map(capitalized) + (numbers.isEmpty ? [] : [numbers.joined(separator: ".")])).joined(separator: " ")
        } else if parts.first == "gpt", parts.count >= 2 {
            name = (["GPT-" + parts[1]] + parts.dropFirst(2).map(capitalized)).joined(separator: " ")
        } else if parts.first?.hasPrefix("gpt") == true {
            // `gpt4o`, as some tools spell it.
            name = ([parts[0].uppercased()] + parts.dropFirst().map(capitalized)).joined(separator: " ")
        } else {
            // A code such as `o3` or `k2` keeps its case; a word is capitalised.
            name = parts.map { $0.allSatisfy(\.isLetter) ? capitalized($0) : $0 }.joined(separator: " ")
        }
        return name.isEmpty || name.count > limit ? nil : name
    }

    private static func capitalized(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}

/// A permission mode as a row names it; nil for the default, which says nothing, and for a mode no agent documents.
enum ModeName {
    static func short(_ raw: String) -> String? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "plan": "plan"
        case "acceptEdits": "accept edits"
        case "bypassPermissions": "bypass"
        case "dontAsk": "don't ask"
        case "auto": "auto"
        default: nil
        }
    }
}

/// A reasoning effort as a row names it (P443): the agent's own word, lower case (`low`, `medium`, `high`, `xhigh`, `max`,
/// Codex's `minimal`, a model's own), nil for none, for Codex's `none` (no reasoning, which says nothing beside a model)
/// and for anything that is no word.
enum EffortName {
    static let limit = 10

    static func short(_ raw: String) -> String? {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !word.isEmpty, word.count <= limit, word != "none", word != "default",
              word.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) || CharacterSet.decimalDigits.contains($0) || $0 == "-" })
        else { return nil }
        return word
    }
}
