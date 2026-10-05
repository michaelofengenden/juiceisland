import Foundation
import OpenIslandCore

/// One of Settings › Island › Mute rules (P420, P421): a session whose folder, title or first prompt contains `text`
/// (any case, any accents), of `agent` or any agent, is muted; or, with Tool (P1010), one whose approval waits on a tool
/// whose whole name `text` matches (`ToolPattern`: any case, `*` for any run of characters, so `Bash`,
/// `mcp__github__*` or `*Edit`). A muted session still lists, counts and shows on the pill, but never sounds, never
/// opens the island by itself (its card, a finish's Done card or dot, a stall's notice, a catch-up after a lock) and
/// never nudges. A rule with no text mutes nothing, so a row just added mutes nothing until the owner types.
struct MuteRule: Codable, Equatable, Identifiable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable {
        case folder, title, prompt, tool

        var label: String {
            switch self {
            case .folder: "Folder"
            case .title: "Title"
            case .prompt: "First prompt"
            case .tool: "Tool"
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
        case .tool:
            // Only while an approval waits on that tool: a question, a finish or a stall is never a tool's (P1010).
            guard case let .needsApproval(tool?) = row.status else { return false }
            return ToolPattern(needle).matches(tool)
        }
    }
}

/// A Tool rule's text as a pattern over a tool's whole name (P1010): any case, `*` for any run of characters (none
/// included), every other character itself. `Bash` is Bash alone, never `BashOutput`; `mcp__github__*` every tool of
/// that MCP server; `*` every tool. Spaces around it are dropped.
struct ToolPattern: Equatable, Sendable {
    /// The pattern's literal pieces between its stars, lowercased.
    let pieces: [String]
    let leadingStar: Bool
    let trailingStar: Bool

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        pieces = trimmed.split(separator: "*", omittingEmptySubsequences: true).map(String.init)
        leadingStar = trimmed.hasPrefix("*")
        trailingStar = trimmed.hasSuffix("*")
    }

    func matches(_ name: String) -> Bool {
        let name = name.lowercased()
        guard !pieces.isEmpty else { return leadingStar }
        var rest = name[...]
        for (index, piece) in pieces.enumerated() {
            let first = index == 0, last = index == pieces.count - 1
            if first, !leadingStar {
                guard rest.hasPrefix(piece) else { return false }
                rest = rest.dropFirst(piece.count)
                if last { return trailingStar || rest.isEmpty }
                continue
            }
            if last, !trailingStar { return rest.hasSuffix(piece) }
            guard let range = rest.range(of: piece) else { return false }
            rest = rest[range.upperBound...]
        }
        return true
    }
}

extension Array where Element == MuteRule {
    /// Any rule mutes `row`. Never a row whose agent waits on the island alone (Copilot CLI's, Devin's or Qwen Code's
    /// approval, Codex's behind the old helper): it shows no prompt of its own, so a muted card would leave it waiting
    /// unseen (P931).
    func mutes(_ row: SessionRow) -> Bool { !row.waitsOnIsland && contains { $0.matches(row) } }
}

/// Mute rules as the settings keep them and the island and the sounds apply them.
enum MuteRules {
    /// The agent a row's glyph palette names, as the engine's tool.
    static func tool(of agent: GlyphPalette.Agent) -> AgentTool {
        switch agent {
        case .claude: .claudeCode
        case .codex: .codex
        case let .other(tool): tool
        case let .kind(kind): kind.carrierTool
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
        rows.filter { row in rules.contains { $0.matches(row) } }.count
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
