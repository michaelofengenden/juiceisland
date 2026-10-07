import Foundation
import IslandHookNotes
import JuiceCore
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// The READMEs' agent grid (P975): written from the agents table (`AgentHookTable.wave1`) and the three agents with rows of
/// their own (Claude Code, Codex, OpenCode), so a new agent, a Watch that becomes Approve or a moved file shows up in the
/// README or fails here. The grid sits between `<!-- agent-grid` and `<!-- /agent-grid -->` in each page `readmes()` names,
/// in that page's layout: the public README's Works with (`docs/public/README.md` here, `README.md` in the public
/// repository) as two columns, Approve and Watch (`columns()`, P1587); the full table with each agent's files
/// (`grid(stem:)`) in the public page on what Juice reads and changes (`docs/public/PRIVACY.md`, `docs/PRIVACY.md` there)
/// and in the private `README.md`. To rewrite them all after a change to the table:
/// `JI_WRITE_AGENT_GRID=1 swift test --filter ReadmeAgentGridTests`.
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
            // Approve only while Answer Codex in Juice holds (P947).
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
            "¹ With Settings › Island › Answer Codex in Juice; \(AgentReach.watch.title) otherwise.",
        ]
        for note in notes() { text += ["", "\(note.mark) \(note.text)."] }
        text += ["", end]
        return text.joined(separator: "\n")
    }

    /// The public README's Works with: the agents you answer from the island beside the ones you watch, each column in the
    /// Agents pane's order, with the same marks and notes as the table (P1587). Files and usage are the table's, on the
    /// page that says what Juice changes.
    static func columns() -> String {
        let lines = lines(stem: "juice")
        let approve = lines.filter { $0.reach.hasPrefix(AgentReach.approve.title) }
        let watch = lines.filter { $0.reach.hasPrefix(AgentReach.watch.title) }
        func name(_ line: Line) -> String { line.name + line.reach.drop { $0.isLetter } }
        var text = [begin, "",
                    "| \(AgentReach.approve.title): answer from the island | \(AgentReach.watch.title): see it and jump back |",
                    "|---|---|"]
        for index in 0..<max(approve.count, watch.count) {
            let left = index < approve.count ? name(approve[index]) : ""
            let right = index < watch.count ? name(watch[index]) : ""
            text.append("| \(left) | \(right) |")
        }
        text += ["", "¹ With Settings › Island › Answer Codex in Juice; \(AgentReach.watch.title) otherwise."]
        for note in notes() { text += ["", "\(note.mark) \(note.text)."] }
        text += ["", end]
        return text.joined(separator: "\n")
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// How a page draws the grid: the two columns of the public README, or the full table with each agent's files.
    enum Layout { case columns, table }

    struct Page {
        var url: URL
        var stem: String
        var layout: Layout

        /// The grid this page must hold, markers included.
        var grid: String { layout == .columns ? ReadmeAgentGridTests.columns() : ReadmeAgentGridTests.grid(stem: stem) }
    }

    /// The pages with a grid this tree holds: here the public README, the public page on what Juice reads and changes, and
    /// the private README; in the public repository (the export puts `docs/public/README.md` at `README.md` and
    /// `docs/public/PRIVACY.md` at `docs/PRIVACY.md`) the first two.
    static func readmes() -> [Page] {
        let publicDraft = root.appendingPathComponent("docs/public/README.md")
        let top = root.appendingPathComponent("README.md")
        if FileManager.default.fileExists(atPath: publicDraft.path) {
            return [Page(url: publicDraft, stem: "juice", layout: .columns),
                    Page(url: root.appendingPathComponent("docs/public/PRIVACY.md"), stem: "juice", layout: .table),
                    Page(url: top, stem: "juice-island", layout: .table)]
        }
        return [Page(url: top, stem: "juice", layout: .columns),
                Page(url: root.appendingPathComponent("docs/PRIVACY.md"), stem: "juice", layout: .table)]
    }

    /// The text with its grid replaced; nil when the README has no grid markers.
    static func replacingGrid(in text: String, with grid: String) -> String? {
        guard let start = text.range(of: "<!-- agent-grid"), let stop = text.range(of: end, range: start.upperBound..<text.endIndex)
        else { return nil }
        return text.replacingCharacters(in: start.lowerBound..<stop.upperBound, with: grid)
    }

    @Test func eachReadmesGridIsTheTables() throws {
        let write = ProcessInfo.processInfo.environment["JI_WRITE_AGENT_GRID"] == "1"
        for page in Self.readmes() {
            let url = page.url
            let text = try String(contentsOf: url, encoding: .utf8)
            let replaced = try #require(Self.replacingGrid(in: text, with: page.grid), "\(url.lastPathComponent) has no agent grid")
            if replaced != text, write {
                try replaced.write(to: url, atomically: true, encoding: .utf8)
                continue
            }
            #expect(replaced == text, "\(url.path) has an old agent grid: JI_WRITE_AGENT_GRID=1 swift test --filter ReadmeAgentGridTests")
        }
    }

    /// The public README's two columns hold every agent once, Approve on the left and Watch on the right, with the table's
    /// marks, and name no file: those are on the page about what Juice changes (P1587).
    @Test func theColumnsSplitEveryAgentByWhatYouCanDoFromTheIsland() throws {
        let rows = Self.columns().components(separatedBy: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| Approve") }
        let cells = rows.map { $0.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) } }
        let left = cells.map { $0[1] }.filter { !$0.isEmpty }, right = cells.map { $0[2] }.filter { !$0.isEmpty }
        let lines = Self.lines(stem: "juice")
        #expect(left.count + right.count == lines.count)
        for line in lines {
            let shown = line.name + line.reach.drop { $0.isLetter }
            let column = line.reach.hasPrefix("Approve") ? left : right
            #expect(column.contains(shown), "\(line.name) is not in its column")
        }
        #expect(left.first == "Claude Code" && left.contains("Codex¹") && left.contains("Qoder²") && right.first == "Cursor")
        #expect(!Self.columns().contains("~/") && !Self.columns().contains("juice-island"))
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

    /// Every count of agents the public README gives is the grid's, so a new agent in the table that the page's words
    /// leave behind fails here too (P1588; before wave 10 its first sentence named every agent, P975).
    @Test func thePublicReadmesCountsOfAgentsAreTheGrids() throws {
        let page = try #require(Self.readmes().first)
        #expect(page.layout == .columns && page.stem == "juice")
        let text = try String(contentsOf: page.url, encoding: .utf8)
        let total = Self.lines(stem: "juice").count
        let counts = try Regex("([0-9]+) (?:coding )?agents").numbers(in: text)
        #expect(!counts.isEmpty, "the README never says how many agents it works with")
        for count in counts { #expect(count == total, "the README says \(count) agents; the grid has \(total)") }
        let more = try Regex("Claude Code, Codex and ([0-9]+) more").numbers(in: text)
        for count in more { #expect(count == total - 2, "the README says Claude Code, Codex and \(count) more; the grid has \(total)") }
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

    /// The issue forms' folder: `docs/public/github/ISSUE_TEMPLATE/` here, `.github/ISSUE_TEMPLATE/` in the public
    /// repository, so the tests that read them pass in both trees (P1597).
    static var issueForms: URL {
        let forms = root.appendingPathComponent("docs/public/github/ISSUE_TEMPLATE")
        return FileManager.default.fileExists(atPath: forms.path) ? forms : root.appendingPathComponent(".github/ISSUE_TEMPLATE")
    }

    /// The issue forms' Agent menus list every agent the grid does, so a bug in a new agent has its own choice (P979).
    @Test func theIssueFormsOfferEveryAgent() throws {
        let folder = Self.issueForms
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

private extension Regex where Output == AnyRegexOutput {
    /// The first capture of every match, as a number.
    func numbers(in text: String) -> [Int] {
        text.matches(of: self).compactMap { match in match.output[1].substring.flatMap { Int($0) } }
    }
}
