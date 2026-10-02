import AppKit
import Foundation
@testable import IslandEngine
import IslandHookNotes
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// P120: Diagnostics' Bridge and Last jump rows: real values from the live engine, and no row at all without one (demo
/// data, renders), never fixed words.
struct DiagnosticsBridgeTests {
    let now = DemoClock.now

    /// C18: the Needs you row counts what the request book did (never text, a path or an id), and names the helper
    /// generation in effect, the last note's.
    @Test
    func theNeedsYouRowCountsTheBook() {
        #expect(DiagnosticsText.attention(AttentionTally()) == nil)
        var tally = AttentionTally()
        tally.opened = ["claude.broker.cli": 5, "codex.broker.codexApp": 2, "codex.rollout.codexApp": 1]
        tally.confirmed = ["cli": 2, "codexApp": 1]
        tally.neverConfirmed = 4
        tally.notShown = ["autoReview": 1]
        tally.noteVersions = [2: 40, 1: 3]
        tally.lastNoteVersion = 1
        tally.closes = ["toolEvidence": 4, "turnEnd": 2, "islandAnswer": 1]
        let line = DiagnosticsText.attention(tally)
        #expect(line == "8 asked · 3 shown · 4 settled first · 1 not shown · helper v1\nclosed: 4 tool, 2 turn end, 1 island")
        let report = DiagnosticsText.report(lines: [], money: [], attention: line)
        #expect(report.contains("Needs you: 8 asked · 3 shown · 4 settled first · 1 not shown · helper v1 · closed: 4 tool, 2 turn end, 1 island"))
        #expect(!report.contains("in detail"))

        // The copied report alone carries the rest (C18); the row stays as it is.
        #expect(DiagnosticsText.attentionDetails(AttentionTally()) == nil)
        tally.held = 3
        tally.released = 4
        tally.releasedByWindow = ["cli": 1]
        tally.revivals = 1
        tally.codexUnmatched = 1
        tally.lostRaces = 1
        tally.codexQuestionsOpened = 1
        tally.codexQuestionsClosed = ["reply": 1]
        tally.subagentHolds = ["timeUp": 2, "hidden": 1]
        let details = DiagnosticsText.attentionDetails(tally)
        #expect(details == "opened: claude.broker.cli 5, codex.broker.codexApp 2, codex.rollout.codexApp 1 · broker: 3 held, 4 released"
            + " · not shown: autoReview 1 · released unconfirmed: cli 1 · subagent holds ended: timeUp 2, hidden 1"
            + " · revived 1 · Codex unmatched 1"
            + " · island answers that lost the race 1 · Codex questions 1 (closed: reply 1) · notes: v1 3, v2 40")
        #expect(DiagnosticsText.attention(tally) == line)
        let full = DiagnosticsText.report(lines: [], money: [], attention: line, attentionDetails: details)
        #expect(full.contains("\nNeeds you, in detail: opened: claude.broker.cli 5"))
    }

    /// P176: after Hook helper · Update, every new hook sends the new note version; the row names it at the next note,
    /// not the oldest version counted since launch, so it never says the old helper is still in effect.
    @Test @MainActor
    func theNeedsYouRowNamesTheHelperInEffectAfterAnUpdate() throws {
        let engine = SessionEngine.preview(clock: { DemoClock.now })
        for _ in 0..<3 { engine.ingest(note: HookContextNote(version: 1, event: "PreToolUse", sessionID: "s1")) }
        #expect(try #require(DiagnosticsText.attention(engine.attentionTally)).hasSuffix("helper v1"))
        // The owner's Update click: the next hooks run the new helper.
        engine.ingest(note: HookContextNote(version: 2, event: "PostToolUse", sessionID: "s1"))
        engine.ingest(note: HookContextNote(version: 2, event: "Stop", sessionID: "s2"))
        #expect(engine.attentionTally.noteVersions == [1: 3, 2: 2])
        #expect(try #require(DiagnosticsText.attention(engine.attentionTally)).hasSuffix("helper v2"))
        var counted = AttentionTally()
        counted.noteVersions = [1: 40, 2: 12]
        #expect(DiagnosticsText.attention(counted) == "0 asked · 0 shown · 0 settled first · helper v2")
    }

    @Test
    func theBridgeRowSaysWhetherTheHooksReachTheApp() {
        func line(on: Bool = true, live: Bool = true, refusal: String? = nil, _ health: BridgeHealth = .live(sockets: 2),
                  takenBackAt: Date? = nil, notes: String? = nil) -> String {
            DiagnosticsText.bridge(switchOn: on, live: live, refusal: refusal, health: health, takenBackAt: takenBackAt,
                                   notesProblem: notes, now: now)
        }
        #expect(line(on: false) == "Off")
        #expect(line(live: false, refusal: "Open Island is running — quit it to see live sessions")
                == "Open Island is running — quit it to see live sessions")
        #expect(line() == "Live · 2 sockets")
        #expect(line(.live(sockets: 1)) == "Live · 1 socket")
        #expect(line(takenBackAt: now - 125, notes: "Address already in use") == "Live · 2 sockets · taken back 2m ago · context notes off")
        #expect(line(.taken) == "Another app took the hook socket · waiting for it to quit")
    }

    @Test
    func theLastJumpRowSaysWhereItWentAndHowItEnded() {
        func outcome(_ result: JumpResult, _ failure: JumpFailure? = nil) -> JumpOutcome {
            JumpOutcome(id: UUID(), sessionID: "s1", host: "Ghostty", startedAt: now - 240, duration: 0.2, result: result,
                        failure: failure, message: "", steps: [])
        }
        #expect(DiagnosticsText.jump(outcome(.matched), now: now) == "Ghostty · exact tab · 4m ago")
        #expect(DiagnosticsText.jump(outcome(.fallbackActivated), now: now) == "Ghostty · app, not the tab · 4m ago")
        #expect(DiagnosticsText.jump(outcome(.failed, .automationDenied), now: now) == "Ghostty · automation denied · 4m ago")
        #expect(DiagnosticsText.jump(outcome(.noTarget), now: now) == "Ghostty · no target · 4m ago")
        // P660: a folder opened in Finder says why; a Codex app thread whose id is not known says so.
        #expect(DiagnosticsText.jump(outcome(.folderOpened), now: now) == "Ghostty · no app or terminal, folder in Finder · 4m ago")
        #expect(DiagnosticsText.jump(outcome(.failed, .threadUnknown), now: now) == "Ghostty · thread unknown · 4m ago")
    }

    /// A live engine that could not start: its bridge throws `error` (nothing is bound), as the production app keeps
    /// it.
    @MainActor
    static func refusedLive(_ error: any Error, otherIsland: Bool = false) -> LiveSessions {
        let settings = AppSettings.ephemeral()
        settings.liveSessions = true
        let live = LiveSessions(settings: settings, demo: { FixtureSessionFeed(scenario: .prototype).makeModel() }, engine: {
            var configuration = SessionEngine.Configuration.headless
            configuration.startBridge = true
            configuration.socketURL = URL(fileURLWithPath: "/tmp/juice-island-test-\(UUID().uuidString).sock")
            var dependencies = SessionEngine.Dependencies()
            dependencies.isOtherIslandRunning = { otherIsland }
            dependencies.socketHasOwner = { _ in false }
            dependencies.socketIdentity = { _ in nil }
            dependencies.startBridge = { _ in throw error }
            dependencies.startRuntime = { _ in }
            dependencies.updateProcessRoots = { _ in }
            return SessionEngine(configuration: configuration, dependencies: dependencies)
        }, profiles: { LiveProfiles(accounts: [], discovered: []) }, identity: .production)
        live.apply()
        return live
    }

    /// A start failure in macOS's words (a folder it may not write) is long: the Bridge row wraps to two lines and the
    /// pane stays as wide as the Settings window lets it be.
    @Test @MainActor
    func aLongRefusalNeverWidensThePane() throws {
        let env = AppEnvironment.demo()
        let error = CocoaError(.fileWriteNoPermission,
                               userInfo: [NSFilePathErrorKey: "/tmp/juice-island-test/Library/Application Support/Open Island"])
        let live = Self.refusedLive(error)
        defer { live.shutdown() }
        env.liveSessions = live
        let refusal = try #require(live.refusal)
        #expect(refusal.count > 90)
        let width: CGFloat = SettingsTheme.Metrics.width - SettingsTheme.Metrics.sidebarWidth - 40
        let size = NSHostingController(rootView: DiagnosticsPane().environment(env)).sizeThatFits(in: CGSize(width: width, height: 5_000))
        #expect(size.width <= width)
    }

    /// With the Bridge row saying Open Island runs, the Hooks footnote says it no more.
    @Test
    func openIslandRunningIsSaidOnce() {
        let integrations = HookIntegrations(openIslandRunning: true, vibeProfiles: 0, helperInBuild: true)
        #expect(HookRowText.integrationsLine(integrations) == "Helper in this build · Open Island running · no Vibe Island hooks")
        #expect(HookRowText.integrationsLine(integrations, openIslandSaid: true) == "Helper in this build · no Vibe Island hooks")
    }

    /// The pane's source holds no fixed words for these rows any more.
    @Test
    func thePaneHasNoPlaceholderRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("App/SettingsUI/Panes/DiagnosticsPane.swift"), encoding: .utf8)
        #expect(!source.contains("headless · no socket") && !source.contains("\"none yet\""))
        // Nor made-up CLI versions: none is read yet, so none is shown or copied.
        #expect(!source.contains("\"Tools\""))
        let report = DiagnosticsText.report(lines: [], money: [])
        #expect(!report.contains("Tools") && !report.contains("claude 2.") && !report.contains("codex 0."))
    }
}
