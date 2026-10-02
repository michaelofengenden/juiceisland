import Foundation
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore
import Testing

/// Settings › Island › Mute rules (P420, P421): a session whose folder, title or first prompt contains a rule's text, of
/// its agent or any, lists as ever but never sounds, opens the island by itself or nudges. Rows and engines are the
/// tests' own; nothing plays.
@MainActor
@Suite(.serialized)
struct MuteRulesTests {
    static let home = "/Users/owner"

    static func row(_ id: String, _ agent: GlyphPalette.Agent = .claude, _ bucket: SessionBucket = .running,
                    folder: String? = "/Users/owner/Developer/juice-island", project: String = "juice-island",
                    task: String = "Fix the résumé page", titleSource: TitleSource = .agent,
                    firstPrompt: String? = "Please tidy the NIGHTLY build") -> SessionRow {
        var row = DStub.row(id, agent, bucket, project: project, task: task)
        row.folder = folder
        row.titleSource = titleSource
        row.firstPrompt = firstPrompt
        return row
    }

    static func rule(_ field: MuteRule.Field, _ text: String, agent: AgentTool? = nil) -> MuteRule {
        MuteRule(field: field, text: text, agent: agent?.rawValue)
    }

    // MARK: Matching (P420)

    /// Contains, in any case and with any accents: the folder (its whole path, or the workspace name, `~` as the home
    /// folder), the row's title, the first prompt.
    @Test func aRuleMatchesItsFieldContainingItsTextInAnyCase() {
        let row = Self.row("a")
        for (field, text, matches) in [(MuteRule.Field.folder, "JUICE", true), (.folder, "~/Developer/juice", true),
                                       (.folder, "~/Documents", false), (.folder, "Developer/juice-island", true),
                                       (.title, "resume", true), (.title, "RÉSUMÉ PAGE", true), (.title, "nightly", false),
                                       (.prompt, "nightly build", true), (.prompt, "résumé", false)] {
            #expect(Self.rule(field, text).matches(row, home: Self.home) == matches, "\(field) \(text)")
        }
        // No folder known: the workspace name.
        #expect(Self.rule(.folder, "island").matches(Self.row("b", folder: nil), home: Self.home))
        // A row titled by its first prompt before the engine said which prompt was first reads its title.
        let untold = Self.row("c", task: "Rename the widget", titleSource: .prompt, firstPrompt: nil)
        #expect(Self.rule(.prompt, "widget").matches(untold, home: Self.home))
        #expect(!Self.rule(.prompt, "widget").matches(Self.row("d", task: "Rename the widget", firstPrompt: nil), home: Self.home))
    }

    /// A rule for one agent mutes only that agent's sessions; with none, every agent's.
    @Test func aRuleForOneAgentMutesOnlyItsSessions() {
        let claude = Self.row("a", .claude), codex = Self.row("b", .codex), openCode = Self.row("c", .other(.openCode))
        let any = Self.rule(.folder, "juice")
        #expect([claude, codex, openCode].allSatisfy { any.matches($0, home: Self.home) })
        let codexOnly = Self.rule(.folder, "juice", agent: .codex)
        #expect(!codexOnly.matches(claude, home: Self.home) && codexOnly.matches(codex, home: Self.home))
        #expect(Self.rule(.folder, "juice", agent: .claudeCode).matches(claude, home: Self.home))
        #expect(Self.rule(.folder, "juice", agent: .openCode).matches(openCode, home: Self.home))
        // An agent a later engine no longer knows matches nothing.
        #expect(!MuteRule(field: .folder, text: "juice", agent: "retired").matches(claude, home: Self.home))
        // The editor's agents: Any agent, Claude, Codex, then the rest by name, each once.
        let agents = MuteRules.agents
        #expect(agents.prefix(3).map(\.1) == ["Any agent", "Claude", "Codex"])
        #expect(Set(agents.compactMap(\.0)).count == AgentTool.allCases.count)
    }

    /// A rule with no text (one just added) mutes nothing, so adding a row never silences every session.
    @Test func aRuleWithNoTextMutesNothing() {
        let row = Self.row("a")
        for text in ["", "   ", "\n"] {
            for field in MuteRule.Field.allCases { #expect(!Self.rule(field, text).matches(row, home: Self.home)) }
        }
        #expect(![MuteRule()].mutes(row))
        #expect(MuteRules.matchCount([row], rules: [MuteRule()]) == 0)
    }

    /// Kept as JSON under `ji.island.muteRules`, none by default; a rule that no longer reads (a field a later build
    /// dropped, a hand edit) is left out rather than read as another field, and a broken value reads as none.
    @Test func rulesKeepTheirValuesInTheDefaults() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        #expect(fresh.muteRules.isEmpty && AppSettings.ephemeral().muteRules.isEmpty)
        #expect(defaults.object(forKey: AppSettings.Key.muteRules) == nil)
        let rules = [Self.rule(.folder, "scratch"), Self.rule(.prompt, "nightly", agent: .codex)]
        fresh.muteRules = rules
        #expect(AppSettings(defaults: defaults).muteRules == rules)
        // Removing the last rule removes the key.
        fresh.muteRules = []
        #expect(defaults.object(forKey: AppSettings.Key.muteRules) == nil)

        let kept = try #require(MuteRules.encode([Self.rule(.title, "keep")]))
        let unreadable = kept.replacingOccurrences(of: "]", with: #",{"id":"\#(UUID().uuidString)","field":"branch","text":"x"}]"#)
        defaults.set(unreadable, forKey: AppSettings.Key.muteRules)
        #expect(AppSettings(defaults: defaults).muteRules.map(\.text) == ["keep"])
        defaults.set("not json", forKey: AppSettings.Key.muteRules)
        #expect(AppSettings(defaults: defaults).muteRules.isEmpty)
    }

    /// The editor's live count: the sessions any rule matches now, each once.
    @Test func theCountSaysHowManySessionsMatch() {
        let rows = [Self.row("a", folder: "/Users/owner/scratch/one"), Self.row("b", folder: "/Users/owner/scratch/two"),
                    Self.row("c", folder: "/Users/owner/work", project: "work", task: "Ship it", firstPrompt: "ship")]
        #expect(MuteRules.matchCount(rows, rules: [Self.rule(.folder, "scratch"), Self.rule(.folder, "one")]) == 2)
        #expect(MuteRules.countText(0) == "Matches no session.")
        #expect(MuteRules.countText(1) == "Matches 1 session.")
        #expect(MuteRules.countText(2) == "Matches 2 sessions.")
        #expect(MuteRulesText.prompt(.folder) == "Folder contains…" && MuteRulesText.prompt(.prompt) == "Prompt contains…")
    }

    // MARK: What a muted session does (P421)

    /// A muted session's needs-you opens no card, its finish neither a Done card nor Glance's dot, its stall no notice;
    /// another session's still do. The pill still shows the muted one ("it still lists").
    @Test func aMutedSessionOpensNothingButStillLists() {
        let rules = [Self.rule(.folder, "scratch")]
        let muted = Self.row("m", .claude, .needsYou, folder: "/Users/owner/scratch")
        let loud = Self.row("l", .codex, .needsYou, folder: "/Users/owner/work")
        let done = Self.row("d", .claude, .done, folder: "/Users/owner/scratch/b")
        let rows = [muted, loud, done]
        let signals: [IslandSignal] = [.needsYou("m"), .needsYou("l"), .finished("d"), .stalled("m")]
        #expect(MuteRules.unmuted(signals, rows: rows, rules: rules) == [.needsYou("l")])
        #expect(MuteRules.unmuted(signals, rows: rows, rules: []) == signals)

        // The island's side, as the panel runs it.
        var island = Island(rules: rules)
        #expect(island.hear([muted]) == .init())
        #expect(island.hear([muted, done]) == .init())
        #expect(island.hear([muted, done, loud]).card == "l")
        // Glance or Card, a muted finish lights nothing.
        var glance = Island(rules: rules, finish: .glance)
        _ = glance.hear([Self.row("d", .claude, .running, folder: "/Users/owner/scratch/b")])
        #expect(glance.hear([done]) == .init())

        // Still listed: the pill leads with its "!" and counts it.
        let pill = QuietModeTests.pill([muted], settings: AppSettings.ephemeral(), fullScreen: false)
        #expect(pill.lead?.glyph == .bang && pill.count == 1)
    }

    /// The island's side of the rows as the panel runs it (`IslandPanelController.sessionsChanged`): heard, muted, quieted
    /// and the response a batch gives.
    struct Island {
        var rules: [MuteRule]
        var finish: FinishBehaviour = .card
        var putAway = IslandPutAway()
        var last: [SessionRow] = []

        mutating func hear(_ rows: [SessionRow]) -> IslandAttention.Response {
            let heard = MuteRules.unmuted(putAway.hear(IslandAttention.signals(old: last, new: rows), rows: rows,
                                                       pending: IslandAttention.pendingKeys(rows) { _ in nil }),
                                          rows: rows, rules: rules)
            last = rows
            let batch = QuietMode.quieted(heard, finish: finish, quiet: false)
            return IslandAttention.respond(to: batch.signals, rows: rows, finish: batch.finish, cardInUse: false)
        }
    }

    /// With the live engine: a muted session's approval and its Done play nothing, another session's play; the row's
    /// first prompt comes from the engine, and a rule on it mutes too. Removing the rule brings the sound back.
    @Test func aMutedSessionPlaysNoSound() async throws {
        let probe = QuietLaneRig.Probe(), player = RecordingSoundPlayer(), settings = AppSettings.ephemeral()
        settings.doneSound = .system("Hero")
        settings.muteRules = [Self.rule(.folder, "/tmp/scratch")]
        let live = QuietLaneRig.live(probe, settings: settings, player: player)
        let engine = try #require(live.engine)
        QuietLaneRig.start("m", folder: "/tmp/scratch", engine, probe)
        QuietLaneRig.start("l", folder: "/tmp/work", prompt: "rename the nightly job", engine, probe)
        #expect(live.row(id: "l")?.firstPrompt == "rename the nightly job")

        engine.ingest(QuietLaneRig.permission("m", "toolu_m1", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played.isEmpty)
        #expect(live.row(id: "m")?.bucket == .needsYou)
        engine.ingest(QuietLaneRig.permission("l", "toolu_l1", at: probe.now), ingress: .bridge)
        engine.passAttentionWindows()
        #expect(player.played == ["Glass"])

        await engine.approve(sessionID: "m", decision: .allowOnce)
        QuietLaneRig.finish("m", engine, probe)
        #expect(player.played == ["Glass"])

        // A rule on the first prompt, for Claude only: the other session goes quiet as well.
        settings.muteRules.append(Self.rule(.prompt, "NIGHTLY", agent: .claudeCode))
        await engine.approve(sessionID: "l", decision: .allowOnce)
        QuietLaneRig.finish("l", engine, probe)
        #expect(player.played == ["Glass"])

        settings.muteRules = []
        QuietLaneRig.finish("m", engine, probe)
        #expect(player.played == ["Glass", "Hero"])
    }
}
