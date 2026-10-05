import Foundation
import IslandHookNotes
import OpenIslandCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI

/// Wave 4's lane GEMINI in the app (P1100 to P1124): Gemini CLI, Antigravity CLI and Grok Build each with a look of its
/// own, found only by its own signs, Watch everywhere (no Allow or Deny on their notices, never in Allow all), and named
/// in a bug report.
@MainActor
struct WatchAgentsUITests {
    /// Every agent's colour, the table's own (Copilot, Devin, Kilo, Antigravity) with the engine's, at least CIEDE2000 12
    /// from every other and, as a running glyph, from every state's, in each Needs you colour (P207, P926, P1108).
    @Test(arguments: NeedsYouColour.allCases)
    func everyAgentsColourIsItsOwnWithTheTablesToo(_ needsYou: NeedsYouColour) {
        let wait = GlassGlyphTests.hex(needsYou.wait, .dark).lowercased(), question = GlassGlyphTests.hex(needsYou.question, .dark).lowercased()
        let agents: [GlyphPalette.Agent] = [.claude, .codex] + AgentLookTests.others.map { .other($0) }
            + AgentLook.kindColours.keys.sorted { $0.rawValue < $1.rawValue }.map { .kind($0) }
        let marks = agents.map { GlassGlyphTests.hex(AgentLook.of($0).colour, .dark).lowercased() }
        let glyphs = agents.map { AgentLook.of($0).runningColour(needsYou) }.filter { $0 != IslandTheme.run }
            .map { GlassGlyphTests.hex($0, .dark).lowercased() }
        let states = ["run": "#4e80ed", "wait": wait, "question": question, "done": "#6fb982", "idle": "#5c5c61"]
        var closest = (distance: Double.infinity, pair: "")
        for kind in AgentLook.kindColours.keys {
            let own = GlassGlyphTests.hex(AgentLook.of(.kind(kind)).colour, .dark).lowercased()
            for other in marks where other != own {
                let distance = CIEDE2000.distance(own, other)
                if distance < closest.distance { closest = (distance, "\(kind) \(other)") }
            }
            guard glyphs.contains(own) else { continue }
            for (state, hex) in states {
                let distance = CIEDE2000.distance(own, hex)
                if distance < closest.distance { closest = (distance, "\(kind) \(state)") }
            }
        }
        #expect(closest.distance >= 12, "\(closest.pair): \(closest.distance)")
        #expect(Set(marks).count == marks.count)
        #expect(AgentLook.of(GlyphPalette.Agent.kind(.antigravity)).colour == Color(hex: 0xF0CCB8))
    }

    /// Antigravity's mark is a shape of Juice's own, used by no other agent; Gemini CLI and Grok Build keep the looks
    /// their engine sessions already had.
    @Test
    func antigravityHasAMarkOfItsOwn() {
        #expect(AgentLook.of(GlyphPalette.Agent.kind(.antigravity)) == AgentLook(name: "Antigravity", mark: .rise, colour: Color(hex: 0xF0CCB8)))
        let marks = AgentLook.others.values.map(\.mark) + AgentLook.kinds.values.map(\.mark)
        #expect(marks.filter { $0 == .rise }.count == 1)
        #expect(EngineSessionsModel.agent(.antigravity) == .kind(.antigravity))
        #expect(EngineSessionsModel.agent(.gemini) == .other(.geminiCLI) && EngineSessionsModel.agent(.grok) == .other(.grokBuild))
        #expect(AgentLook.of(EngineSessionsModel.agent(.gemini)) == AgentLook.of(.geminiCLI))
    }

    /// Gemini CLI's ToolPermission and Grok Build's permission_prompt are "needs you" with no answer: a notice, never
    /// Allow or Deny, and never in Allow all (P1103, P1112).
    @Test
    func theirNoticesNeedYouWithNoAnswerAndAllowAllPassesThem() throws {
        typealias ID = FixtureSessionFeed.AgentID
        let env = AppEnvironment.demo(sessions: .agents)
        let feed = try #require(env.fixtureFeed)
        #expect(feed.engine.loadPreviewNote(event: "Notification", sessionID: ID.geminiRunning, notificationType: "ToolPermission",
                                            source: "gemini"))
        #expect(feed.engine.loadPreviewNote(event: "Notification", sessionID: ID.grokDone, notificationType: "permission_prompt",
                                            source: "grok"))
        // Gemini's other notifications say nothing.
        #expect(feed.engine.loadPreviewNote(event: "Notification", sessionID: ID.geminiDone, notificationType: "Other", source: "gemini"))
        for id in [ID.geminiRunning, ID.grokDone] {
            guard case let .approval(card)? = env.sessions.card(for: id) else {
                Issue.record("no notice for \(id)")
                continue
            }
            #expect(card.isNotice && !card.isAnswerable, "\(id)")
            #expect(env.sessions.row(id: id)?.bucket == .needsYou, "\(id)")
            #expect(!BatchAnswer.covers(card, watch: BatchAnswer.watchAgents(env.settings)), "\(id)")
        }
        #expect(env.sessions.card(for: ID.geminiDone) == nil || env.sessions.row(id: ID.geminiDone)?.bucket != .needsYou)
        #expect(!BatchAnswer.targets(env).contains { [ID.geminiRunning, ID.grokDone].contains($0.sessionID) })
        let watch = BatchAnswer.watchAgents(env.settings)
        #expect(watch.isSuperset(of: [.other(.geminiCLI), .kind(.antigravity), .other(.grokBuild)]))
    }

    /// An Antigravity session, which no prompt ever names, shows with Antigravity's mark from its first model call.
    @Test
    func anAntigravitySessionShowsWithItsOwnMark() throws {
        let env = AppEnvironment.demo(sessions: .agentQuestion)
        let feed = try #require(env.fixtureFeed)
        let id = GeminiLaneRenders.antigravityID
        #expect(GeminiLaneRenders.addAntigravity(feed))
        let row = try #require(env.sessions.row(id: id))
        #expect(row.agent == .kind(.antigravity) && row.bucket == .running)
        #expect(AgentLook.of(row.agent).mark == .rise)
    }

    /// The bug report's Agent choice names each of the three as its row does.
    @Test
    func theBugReportNamesThem() {
        #expect(BugReport.agentOption(EngineSessionsModel.agent(.gemini)) == "Gemini CLI")
        #expect(BugReport.agentOption(EngineSessionsModel.agent(.antigravity)) == "Antigravity")
        #expect(BugReport.agentOption(EngineSessionsModel.agent(.grok)) == "Grok Build")
    }

    /// Each is found by its own command or its own folder, never by `~/.gemini` alone, which both Gemini CLI and
    /// Antigravity CLI keep (P1100).
    @Test
    func eachIsFoundOnlyByItsOwnSigns() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ji-watch-find-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: home.appendingPathComponent(".gemini/settings.json"))
        let specs = [AgentHookTable.gemini, AgentHookTable.antigravity, AgentHookTable.grok]
        func found(_ prepare: () throws -> Void) async throws -> [String] {
            try prepare()
            let table = TableAgents(installer: AgentHookInstaller(home: home, helperPath: home.path + "/hooks/JuiceHooks", bundledHelper: nil,
                                                                  ownFileStem: "juice-island", bridgeSocketPath: home.path + "/b.sock"),
                                    specs: specs, directories: { [bin.path] })
            await table.readAgain()
            return table.rows.map(\.id)
        }
        #expect(try await found {} == [])
        #expect(try await found { try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/antigravity-cli"),
                                                                          withIntermediateDirectories: true) } == ["antigravity"])
        #expect(try await found { try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini/tmp"),
                                                                          withIntermediateDirectories: true) } == ["gemini", "antigravity"])
        // A `grok` command alone is Homebrew's regex tool as often as Grok Build: only Grok's own folders find it (P1187).
        #expect(try await found {
            let grok = bin.appendingPathComponent("grok")
            try Data("#!/bin/sh\nexit 1\n".utf8).write(to: grok)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: grok.path)
        } == ["gemini", "antigravity"])
        #expect(try await found { try FileManager.default.createDirectory(at: home.appendingPathComponent(".grok/downloads"),
                                                                          withIntermediateDirectories: true) } == ["gemini", "antigravity", "grok"])
    }
}
