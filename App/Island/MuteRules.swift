import Foundation
import OpenIslandCore

/// One of Settings › Island › Mute rules (P420, P421): a session whose folder, title or first prompt contains `text`
/// (any case, any accents), of `agent` or any agent, is muted. A muted session still lists, counts and shows on the
/// pill, but never sounds, never opens the island by itself (its card, a finish's Done card or dot, a stall's notice, a
/// catch-up after a lock) and never nudges. A rule with no text mutes nothing, so a row just added mutes nothing until
/// the owner types.
struct MuteRule: Codable, Equatable, Identifiable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case folder, title, prompt

        var label: String {
            switch self {
            case .folder: "Folder"
            case .title: "Title"
            case .prompt: "First prompt"
            }
        }
    }

    var id = UUID()
    var field: Field = .folder
    var text = ""
    /// The agent's `AgentTool` raw value (`claudeCode`, `codex`, …); nil for any agent. A raw value keeps a rule for an
    /// agent a later engine drops readable, matching nothing.
    var agent: String?

    /// Whether this rule mutes `row`. `home` expands a folder rule written from `~`.
    func matches(_ row: SessionRow, home: String = NSHomeDirectory()) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        if let agent, agent != MuteRules.tool(of: row.agent).rawValue { return false }
        switch field {
        case .folder:
            let path = MuteRules.expandingHome(needle, home: home)
            return MuteRules.contains(row.folder, path) || MuteRules.contains(row.project, path)
        case .title:
            return MuteRules.contains(row.task, needle)
        case .prompt:
            // The first prompt; a row titled by it before the engine said which it was reads its title.
            return MuteRules.contains(row.firstPrompt ?? (row.titleSource == .prompt ? row.task : nil), needle)
        }
    }
}

extension Array where Element == MuteRule {
    /// Any rule mutes `row`.
    func mutes(_ row: SessionRow) -> Bool { contains { $0.matches(row) } }
}

/// Mute rules as the settings keep them and the island and the sounds apply them.
enum MuteRules {
    /// The agent a row's glyph palette names, as the engine's tool.
    static func tool(of agent: GlyphPalette.Agent) -> AgentTool {
        switch agent {
        case .claude: .claudeCode
        case .codex: .codex
        case let .other(tool): tool
        }
    }

    /// `value` contains `needle`, in any case and with any accents.
    static func contains(_ value: String?, _ needle: String) -> Bool {
        guard let value, !needle.isEmpty else { return false }
        return value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// `~` and `~/…` as the home folder, so a rule written as the owner types a path matches the whole folder.
    static func expandingHome(_ path: String, home: String) -> String {
        if path == "~" { return home }
        return path.hasPrefix("~/") ? home + path.dropFirst() : path
    }

    /// The batch without the signals of muted sessions: no card, no Done card or Glance dot, no stall notice opens the
    /// island for them. Rows are what the batch was heard from.
    static func unmuted(_ signals: [IslandSignal], rows: [SessionRow], rules: [MuteRule]) -> [IslandSignal] {
        guard !rules.isEmpty, !signals.isEmpty else { return signals }
        let muted = Set(rows.filter { rules.mutes($0) }.map(\.id))
        guard !muted.isEmpty else { return signals }
        return signals.filter { signal in
            switch signal {
            case let .needsYou(id), let .finished(id), let .stalled(id): !muted.contains(id)
            }
        }
    }

    /// How many of `rows` any rule mutes, for the editor's live count.
    static func matchCount(_ rows: [SessionRow], rules: [MuteRule]) -> Int {
        rows.filter { rules.mutes($0) }.count
    }

    /// The editor's footnote: "Matches 2 sessions."
    static func countText(_ count: Int) -> String {
        switch count {
        case 0: "Matches no session."
        case 1: "Matches 1 session."
        default: "Matches \(count) sessions."
        }
    }

    // MARK: Storage

    /// The rules as the defaults keep them (JSON), nil for none.
    static func encode(_ rules: [MuteRule]) -> String? {
        guard !rules.isEmpty, let data = try? JSONEncoder().encode(rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stored rules; one that no longer reads (a field a later build dropped, a hand edit) is left out, never read as
    /// another field.
    static func decode(_ text: String?) -> [MuteRule] {
        guard let data = text?.data(using: .utf8), let rules = try? JSONDecoder().decode([Lossy].self, from: data) else { return [] }
        return rules.compactMap(\.rule)
    }

    private struct Lossy: Decodable {
        var rule: MuteRule?
        init(from decoder: any Decoder) throws { rule = try? MuteRule(from: decoder) }
    }

    // MARK: The editor's choices

    static let fields: [(MuteRule.Field, String)] = MuteRule.Field.allCases.map { ($0, $0.label) }

    /// Any agent, then Claude and Codex, then every other agent the engine knows, by name.
    static var agents: [(String?, String)] {
        let others = AgentTool.allCases.filter { $0 != .claudeCode && $0 != .codex }
            .map { ($0.rawValue, AgentLook.of($0).name) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
        return [(nil, "Any agent"), (AgentTool.claudeCode.rawValue, "Claude"), (AgentTool.codex.rawValue, "Codex")]
            + others.map { (Optional($0.0), $0.1) }
    }
}
