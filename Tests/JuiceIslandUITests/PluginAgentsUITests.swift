import Foundation
import IslandHookNotes
import OpenIslandCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Wave 4's plugin agents on the island and in the app (P1150 to P1174). Their sessions are built as upstream's bridge
/// builds them from what Juice's plugins send (`PluginAgentsTests` holds the plugins to these payloads):
/// `BridgeServer.handleOpenCodeHook` for Amp's threads (`amp-<thread id>`), `handlePiHook` for Pi and Oh My Pi
/// (`FixtureSessionFeed.piEvents`). Fictional folders only.
@MainActor
struct PluginAgentsUITests {
    static let ampID = "amp-T-5f1d"
    static let kiloID = "kilo-ses_k1"
    static let piID = "pi-019a2b"
    static let ompID = "omp-77c0"

    /// What Amp's plugin sends while its thread waits on the owner's policy plugin (`AmpPlugin`, `waiting`).
    static func ampWaiting() -> OpenCodeHookPayload {
        var payload = FixtureSessionFeed.openCodePayload(ampID, project: "notes-site", event: .permissionRequest)
        payload.toolName = "Bash"
        payload.toolInput = #"{"command":"git push origin main"}"#
        payload.permissionTitle = "Allow Bash"
        payload.permissionDescription = "Amp is waiting for an answer in Amp."
        return payload
    }

    /// Amp waiting, Kilo asking (Approve, as a control), Pi running a read, Oh My Pi done.
    static func feed(now: Date = DemoClock.now) -> FixtureSessionFeed {
        let feed = FixtureSessionFeed(scenario: .empty, now: now)
        let m: TimeInterval = 60
        var events = FixtureSessionFeed.openCodeStart(ampID, project: "notes-site", prompt: "push the fix", at: now - 6 * m)
        events.append(.permissionRequested(PermissionRequested(sessionID: ampID, request: FixtureSessionFeed.openCodeRequest(ampWaiting()),
                                                               timestamp: now - 1 * m)))
        events += FixtureSessionFeed.openCodeStart(kiloID, project: "field-notes", prompt: "tidy the index", at: now - 9 * m)
        events += FixtureSessionFeed.openCodePermission(kiloID, project: "field-notes", tool: "Bash", patterns: ["rm -rf build"], at: now - 2 * m)
        events += FixtureSessionFeed.piEvents(piID, variant: .pi, project: "MarathonTrainingLog", prompt: "read the results", tool: "read",
                                              input: #"{"path":"results/summary.md"}"#, message: nil, at: now - 4 * m, endedAt: nil)
        events += FixtureSessionFeed.piEvents(ompID, variant: .ohMyPi, project: "field-notes", prompt: "list the drafts", tool: nil, input: nil,
                                              message: "Three drafts are waiting for review.", at: now - 20 * m, endedAt: now - 12 * m)
        feed.engine.loadPreviewEvents(events)
        return feed
    }

    /// The app over that feed, and the feed (its engine, what its cards sent).
    static func world(_ settings: AppSettings = .ephemeral()) -> (env: AppEnvironment, feed: FixtureSessionFeed) {
        let feed = feed()
        return (AppEnvironment(settings: settings, usage: DemoUsageModel(now: feed.now), sessions: feed.makeModel()), feed)
    }

    static func environment(_ settings: AppSettings = .ephemeral()) -> AppEnvironment { world(settings).env }

    /// Amp's thread is Amp's row (its A tile, its name), and the waiting it reports is a read-only card: its command,
    /// Open and ✕, no answer the island could send; Allow all passes it by. Kilo's request beside it stays answerable.
    @Test
    func ampsWaitingThreadIsAReadOnlyCardOnAmpsRow() throws {
        let (env, feed) = Self.world()
        let row = try #require(env.sessions.row(id: Self.ampID))
        #expect(row.agent == .kind(.amp) && AgentLook.of(row.agent).name == "Amp" && AgentLook.of(row.agent).mark == .tile("A"))
        #expect(row.bucket == .needsYou)
        guard case let .approval(card)? = env.sessions.card(for: Self.ampID) else {
            Issue.record("Amp's waiting thread has no approval card")
            return
        }
        #expect(!card.isAnswerable && card.request?.dismissable == true)
        #expect(card.body == .command("git push origin main") && card.tool == "Bash")
        let request = try #require(feed.engine.attentionHead(for: Self.ampID))
        #expect(request.channel == .open && !request.isAnswerable && !request.waitsOnIslandAlone)
        guard case let .approval(kilo)? = env.sessions.card(for: Self.kiloID) else {
            Issue.record("Kilo's request has no card")
            return
        }
        #expect(kilo.isAnswerable && env.sessions.row(id: Self.kiloID)?.agent == .kind(.kilo))
        #expect(BatchAnswer.targets(env).map(\.sessionID) == [Self.kiloID] || BatchAnswer.targets(env).isEmpty)
        #expect(!BatchAnswer.targets(env).contains { $0.sessionID == Self.ampID })
        // A click on Yes for Amp's card sends nothing anywhere.
        let sent = feed.sentCommands.count
        env.sessions.approve(Self.ampID, .allowOnce, request: card.request?.id)
        #expect(feed.sentCommands.count == sent)
    }

    /// Pi's and Oh My Pi's sessions are their own agents', with upstream's marks; Amp's label comes from its id alone.
    @Test
    func piAndOhMyPiAreTheirOwnRows() throws {
        let (env, feed) = Self.world()
        #expect(env.sessions.row(id: Self.piID)?.agent == .other(.pi))
        #expect(env.sessions.row(id: Self.ompID)?.agent == .other(.ohMyPi))
        #expect(AgentLook.of(.other(.pi)).name == "Pi" && AgentLook.of(.other(.ohMyPi)).name == "Oh My Pi")
        let engine = feed.engine
        let amp = try #require(engine.state.session(id: Self.ampID))
        #expect(amp.tool == .openCode && engine.agent(of: amp) == .amp)
        #expect(EngineSessionsModel.agent(.amp) == .kind(.amp) && EngineSessionsModel.agent(.pi) == .other(.pi))
    }

    /// Every agent a session can be has its own mark (Amp's A tile is no one else's), and Amp's taupe sits at least
    /// CIEDE2000 12 from every other agent's colour, Claude's and Codex's included, and from every state's, in each Needs
    /// you colour (P207, P926, P1163).
    @Test(arguments: NeedsYouColour.allCases)
    func ampsMarkAndColourAreItsOwn(_ needsYou: NeedsYouColour) {
        let tools = AgentLookTests.others.map { GlyphPalette.Agent.other($0) }
        let kinds = AgentLook.kinds.keys.sorted { $0.rawValue < $1.rawValue }.map { GlyphPalette.Agent.kind($0) }
        let looks = ([GlyphPalette.Agent.claude, .codex] + tools + kinds).map { AgentLook.of($0) }
        for look in looks { #expect(looks.filter { $0.mark == look.mark }.count == 1, "\(look.name)") }
        #expect(Set(looks.map(\.name)).count == looks.count)
        let amp = AgentLook.kindColours[.amp] ?? ""
        let others = ["#d97757", "#d96a5a", "#5ac8fa"] + AgentLookTests.others.map(AgentLook.colourHex)
            + AgentLook.kindColours.filter { $0.key != .amp }.map(\.value)
        let wait = GlassGlyphTests.hex(needsYou.wait, .dark).lowercased(), question = GlassGlyphTests.hex(needsYou.question, .dark).lowercased()
        let states = ["#4e80ed", "#6fb982", "#5c5c61", wait, question]
        for colour in others + states { #expect(CIEDE2000.distance(amp, colour) >= 12, "\(amp) \(colour)") }
        #expect(AgentLook.of(GlyphPalette.Agent.kind(.amp)).runningColour(needsYou) == AgentLook.colour(hex: amp))
    }

    /// The table's agents are the bug form's own choices, by the name the form gives them.
    @Test
    func theBugFormNamesThePluginAgents() {
        #expect(BugReport.agentOption(.other(.pi)) == "Pi")
        #expect(BugReport.agentOption(.other(.ohMyPi)) == "Oh My Pi")
        #expect(BugReport.agentOption(.kind(.amp)) == "Amp")
        #expect(BugReport.agentOption(.other(.geminiCLI)) == (AgentHookTable.spec(.gemini)?.name ?? "Another agent"))
    }

    /// The welcome, its "new agents" card and Settings › Agents read the table, so the three are there with nothing added
    /// by hand: Watch rows with their own marks and files.
    @Test
    func theWelcomeAndTheAgentsPaneReadTheTable() {
        #expect(NewAgents.catalog.filter { ["pi", "ohmypi", "amp"].contains($0) } == ["pi", "ohmypi", "amp"])
        let table = TableAgents(installer: AgentHookInstaller(home: URL(fileURLWithPath: "/tmp/ji-render-home"), helperPath: "/tmp/h",
                                                              bundledHelper: nil, ownFileStem: "juice", bridgeSocketPath: "/tmp/b.sock"),
                                specs: AgentHookTable.plugins, directories: { [] })
        let rows = AgentHookTable.plugins.map(table.row)
        #expect(rows.map(\.reach) == [.watch, .watch, .watch])
        #expect(rows.map(\.place) == ["~/.pi/agent/extensions/juice.ts", "~/.omp/agent/extensions/juice.ts", "~/.config/amp/plugins/juice.ts"])
        #expect(rows.map(\.look.name) == ["Pi", "Oh My Pi", "Amp"])
    }
}
