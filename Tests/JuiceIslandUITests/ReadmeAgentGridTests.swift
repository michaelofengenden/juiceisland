import Foundation
import IslandHookNotes
import JuiceCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The READMEs' agent grid (P975): written from the agents table (`AgentHookTable.wave1`) and the three agents with rows of
/// their own (Claude Code, Codex, OpenCode), so a new agent, a Watch that becomes Approve or a moved file shows up in the
/// README or fails here. The grid sits between `<!-- agent-grid` and `<!-- /agent-grid -->` in `docs/public/README.md` (the
/// public Juice's, `README.md` in the public repository) and in the private `README.md`. To rewrite both after a change to
/// the table: `JI_WRITE_AGENT_GRID=1 swift test --filter ReadmeAgentGridTests`.
struct ReadmeAgentGridTests {
    struct Line: Equatable {
        var name: String
        var reach: String
        var usage: String
        var place: String
    }

    static let begin = "<!-- agent-grid: written by ReadmeAgentGridTests from the agents table; "
        + "JI_WRITE_AGENT_GRID=1 swift test --filter ReadmeAgentGridTests rewrites it -->"
    static let end = "<!-- /agent-grid -->"
    static let battery = "Battery per account"

    /// One line per agent a click connects, in the Agents pane's order: Claude Code, Codex, OpenCode, then the table's.
    /// `stem`: the flavor's own file name in an agent's folder (`HookHome.ownFileStem`: `juice`, or `juice-island`).
    static func lines(stem: String) -> [Line] {
        var lines = [
            Line(name: AgentRowText.name(.claude), reach: AgentReach.approve.title, usage: battery,
                 place: "`settings.json` in `~/.claude` and each `~/.claude-*` profile"),
            // Approve only while Answer Codex on the island holds (P947).
            Line(name: AgentRowText.name(.codex), reach: AgentReach.approve.title + "¹", usage: battery,
                 place: "`hooks.json` and `config.toml` in `~/.codex` and each `~/.codex-*` profile"),
            // OpenCode's plugin is the flavor's own file too (`OpenCodePlugin.fileName`, P934).
            Line(name: "OpenCode", reach: AgentReach.approve.title, usage: "",
                 place: "`~/.config/opencode/plugins/\(stem).js`"),
        ]
        let marks = Dictionary(uniqueKeysWithValues: notes().map { ($0.kind, $0.mark) })
        for spec in AgentHookTable.wave1 {
            let reach: AgentReach = spec.answers == .approve ? .approve : .watch
            // An agent that reads more than one place (Factory Droid, Kimi) names each, in the agent's order (P1126, P1132).
            let places = ([spec] + spec.elsewhere).map { "`~/\($0.folder)/\($0.file(stem: stem))`" }.joined(separator: " or ")
            lines.append(Line(name: spec.name, reach: reach.title + (marks[spec.kind] ?? ""), usage: "", place: places))
        }
        return lines
    }

    /// The table's agents that are Approve in part only, each with its note's mark, after Codex's ¹ (Qoder's IDE, P1190).
    static func notes() -> [(kind: AgentKind, mark: String, text: String)] {
        let marks = ["²", "³", "⁴", "⁵", "⁶"]
        return AgentHookTable.wave1.compactMap { spec in spec.reachNote.map { (spec.kind, $0) } }.enumerated().map { index, note in
            (note.0, marks[index], note.1)
        }
    }

    /// The block as the README holds it, markers included.
    static func grid(stem: String) -> String {
        var text = [begin, "", "| Agent | From the island | Usage | Juice's hooks go in |", "|---|---|---|---|"]
        for line in lines(stem: stem) {
            text.append("| \(line.name) | \(line.reach) | \(line.usage) | \(line.place) |")
        }
        text += [
            "",
            "**\(AgentReach.approve.title)**: answer its prompts from the island. "
                + "**\(AgentReach.watch.title)**: see its sessions and jump to them, and answer its prompts there.",
            "",
            "¹ With Settings › Island › Answer Codex on the island; \(AgentReach.watch.title) otherwise.",
        ]
        for note in notes() { text += ["", "\(note.mark) \(note.text)."] }
        text += ["", end]
        return text.joined(separator: "\n")
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The READMEs this tree holds, with the stem each one's grid names: the private tree's public and private READMEs,
    /// or the public repository's one README (the export puts `docs/public/README.md` there).
    static func readmes() -> [(url: URL, stem: String)] {
        let publicDraft = root.appendingPathComponent("docs/public/README.md")
        let top = root.appendingPathComponent("README.md")
        if FileManager.default.fileExists(atPath: publicDraft.path) {
            return [(publicDraft, "juice"), (top, "juice-island")]
        }
        return [(top, "juice")]
    }

    /// The text with its grid replaced; nil when the README has no grid markers.
    static func replacingGrid(in text: String, with grid: String) -> String? {
        guard let start = text.range(of: "<!-- agent-grid"), let stop = text.range(of: end, range: start.upperBound..<text.endIndex)
        else { return nil }
        return text.replacingCharacters(in: start.lowerBound..<stop.upperBound, with: grid)
    }

    @Test func eachReadmesGridIsTheTables() throws {
        let write = ProcessInfo.processInfo.environment["JI_WRITE_AGENT_GRID"] == "1"
        for (url, stem) in Self.readmes() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let replaced = try #require(Self.replacingGrid(in: text, with: Self.grid(stem: stem)),
                                        "\(url.lastPathComponent) has no agent grid")
            if replaced != text, write {
                try replaced.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            #expect(replaced == text, "\(url.path) has an old agent grid: JI_WRITE_AGENT_GRID=1 swift test --filter ReadmeAgentGridTests")
        }
    }

    /// Every agent a click connects is in the grid, once, with the tag the Agents pane gives it.
    @Test func theGridNamesEveryConnectableAgentWithThePanesTag() {
        let lines = Self.lines(stem: "juice")
        #expect(lines.count == 3 + AgentHookTable.wave1.count)
        #expect(Set(lines.map(\.name)).count == lines.count)
        for spec in AgentHookTable.wave1 {
            let line = lines.first { $0.name == spec.name }
            // The tag, then the mark of a note where Approve holds in part only (Qoder's IDE, P1190).
            #expect(line.map { String($0.reach.prefix { $0.isLetter }) } == (spec.answers == .approve ? "Approve" : "Watch"))
            #expect(line?.reach.hasSuffix("²") == (spec.reachNote != nil), "\(spec.name)")
        }
        #expect(lines.first { $0.name == "Cursor" }?.reach == "Watch")
        // OpenCode's row as the pane draws it (`AgentRowText.openCode`) is Approve too.
        let openCode = OpenCodeSetupRow(title: "OpenCode", folder: "~/.config/opencode", word: OpenCodeWords.installed,
                                        tone: .normal, action: .remove, refusal: nil, busy: false)
        #expect(AgentRowText.openCode(openCode).reach.title == lines[2].reach)
    }

    /// The README's first sentence names the job and every agent the grid lists, so a new agent in the table that the
    /// top of the page leaves out fails here too.
    @Test func thePublicReadmesFirstSentenceNamesEveryAgent() throws {
        let (url, stem) = try #require(Self.readmes().first)
        #expect(stem == "juice")
        let text = try String(contentsOf: url, encoding: .utf8)
        let first = try #require(text.components(separatedBy: "\n\n").dropFirst().first, "no first paragraph")
        for line in Self.lines(stem: stem) {
            #expect(first.contains(line.name), "the README's first sentence does not name \(line.name)")
        }
    }

    /// The public grid names the public flavor's own files, the private one the private app's (P925).
    @Test func eachFlavorsGridNamesItsOwnFiles() {
        let publicGrid = Self.grid(stem: "juice"), privateGrid = Self.grid(stem: "juice-island")
        #expect(publicGrid.contains("`~/.copilot/hooks/juice.json`") && publicGrid.contains("`~/.config/kilo/plugin/juice.js`"))
        #expect(!publicGrid.contains("juice-island"))
        #expect(privateGrid.contains("`~/.copilot/hooks/juice-island.json`"))
        #expect(publicGrid.contains("`~/.config/opencode/plugins/juice.js`"))
        #expect(OpenCodePlugin.fileName == "\(HookHome.ownFileStem).js")
        #expect(!publicGrid.contains(OpenCodePlugin.legacyFileName) && !privateGrid.contains(OpenCodePlugin.legacyFileName))
    }

    /// The issue forms' Agent menus list every agent the grid does, so a bug in a new agent has its own choice (P979).
    /// Only in the private tree, where the forms are `docs/public/github/ISSUE_TEMPLATE/` (`.github/ISSUE_TEMPLATE/` in the
    /// public repository).
    @Test func theIssueFormsOfferEveryAgent() throws {
        let forms = Self.root.appendingPathComponent("docs/public/github/ISSUE_TEMPLATE")
        let published = Self.root.appendingPathComponent(".github/ISSUE_TEMPLATE")
        let folder = FileManager.default.fileExists(atPath: forms.path) ? forms : published
        for form in ["bug.yml", "feature.yml"] {
            let text = try String(contentsOf: folder.appendingPathComponent(form), encoding: .utf8)
            let after = try #require(text.components(separatedBy: "id: agent").dropFirst().first, "\(form) has no Agent menu")
            let menu = after.components(separatedBy: "- type:")[0]
            let options = Set(menu.components(separatedBy: "\n").compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("- ") ? String(trimmed.dropFirst(2)) : nil
            })
            for line in Self.lines(stem: "juice") {
                #expect(options.contains(line.name), "\(form)'s Agent menu has no \(line.name)")
            }
        }
    }

    @Test func aReadmeWithoutMarkersIsNotRewritten() {
        #expect(Self.replacingGrid(in: "# Juice\n\nNo grid here.\n", with: Self.grid(stem: "juice")) == nil)
        let old = "a\n<!-- agent-grid: old -->\n| x |\n<!-- /agent-grid -->\nb"
        #expect(Self.replacingGrid(in: old, with: "GRID") == "a\nGRID\nb")
    }
}
