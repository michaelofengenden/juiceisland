import Foundation
import IslandHookNotes
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// M5's app side: a StopFailure row reads "Turn failed" and sits with what needs you, and the new jump failures have
/// short notes. Headless preview engines only.
@MainActor
struct TurnFailedTests {
    static let failedID = "demo-turn-failed"

    /// The prototype's sessions plus one whose turn ended in a StopFailure, named by its context note.
    static func model(now: Date = DemoClock.now) -> EngineSessionsModel {
        let engine = SessionEngine.preview(clock: { now })
        engine.loadPreviewEvents(FixtureSessionFeed.events(.prototype, now: now))
        engine.loadPreviewEvents([
            .sessionStarted(SessionStarted(sessionID: failedID, title: "Ship the release notes", tool: .claudeCode, origin: .live,
                                           initialPhase: .running, summary: "Started.", timestamp: now - 300,
                                           jumpTarget: JumpTarget(terminalApp: "Ghostty", workspaceName: "juice-island",
                                                                  paneTitle: "claude", workingDirectory: "/tmp/juice-island"),
                                           claudeMetadata: ClaudeSessionMetadata(lastUserPrompt: "write the release notes"))),
            .activityUpdated(SessionActivityUpdated(sessionID: failedID, summary: SignalPipeline.promptPrefix + "write the release notes",
                                                    phase: .running, timestamp: now - 240)),
        ])
        engine.ingest(note: HookContextNote(event: "StopFailure", sessionID: failedID))
        engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: failedID, summary: "rate_limit", timestamp: now - 60))])
        return EngineSessionsModel(engine: engine, clock: { now })
    }

    @Test
    func aFailedTurnIsARowThatNeedsYou() throws {
        let model = Self.model()
        let row = try #require(model.row(id: Self.failedID))
        #expect(row.bucket == .needsYou)
        #expect(row.status == .failed)
        // "×" in the waiting tone, never an approval's "!" (P159).
        #expect(row.glyph == .cross && row.glyphState == .waiting)
        // The error kind in plain words, never the raw code (P132): a rate limit the CLI did not call the account's own
        // is the API's ("API error · rate limited", P700).
        #expect(row.limit?.line == "API error · rate limited" && row.detail == nil)
        #expect(!row.hasCard)
        #expect(model.needsYou.contains { $0.id == Self.failedID })
        #expect(SessionRowText.cleanStatus(row).word == "API error")
        #expect(SessionRowText.detailedStatus(row).word == "API error")
        #expect(DetailedRowText.status(row).word == "API error")
        #expect(SessionListLayout.groupStatus(row, now: DemoClock.now) == "API error · rate limited")
        #expect(SessionRowText.doneCardStatus(row, now: DemoClock.now).word == "API error")
        guard case let .done(card)? = model.card(for: Self.failedID) else {
            Issue.record("no card")
            return
        }
        #expect(card.failed && !card.interrupted && card.limit?.kind == .rateLimited && card.message.isEmpty)
    }

    private func outcome(_ result: JumpResult, _ failure: JumpFailure?, host: String = "Terminal", tool: String? = nil) -> JumpOutcome {
        JumpOutcome(id: UUID(), sessionID: "s1", host: host, startedAt: DemoClock.now, duration: 0, result: result,
                    failure: failure, message: "", steps: [], tool: tool)
    }

    @Test
    func theNewJumpFailuresHaveShortNotes() {
        #expect(JumpNote.text(for: outcome(.failed, .hostNotRunning, host: "iTerm")) == "iTerm isn't running")
        #expect(JumpNote.text(for: outcome(.fallbackActivated, .cliMissing, tool: "tmux")) == "tmux not found · brought Terminal forward")
        #expect(JumpNote.text(for: outcome(.activatedOnly, .cliMissing, host: "VS Code", tool: "code")) == "code not found")
        #expect(JumpNote.text(for: outcome(.failed, .detached)) == "Its tmux session isn't attached")
        #expect(JumpNote.text(for: outcome(.activatedOnly, .ambiguous, host: "Ghostty")) == "Several Ghostty tabs match")
        #expect(JumpNote.text(for: outcome(.activatedOnly, .wrongTab, host: "iTerm")) == "Brought iTerm forward, but not the session's own tab")
        #expect(JumpNote.text(for: outcome(.activatedOnly, .threadLinkFailed, host: "Codex.app")) == "Codex.app didn't open the thread")
        // P660: the Codex app came forward without a thread to open; a session with no app or terminal opened its folder.
        #expect(JumpNote.text(for: outcome(.activatedOnly, .threadUnknown, host: "Codex.app")) == "Brought Codex.app forward; the thread isn't known")
        #expect(JumpNote.text(for: outcome(.folderOpened, nil, host: "Unknown")) == "No app or terminal known · opened its folder in Finder")
        #expect(JumpNote.text(for: outcome(.fallbackActivated, .unknownHost, host: "Hyper")) == "Juice Island can't jump into Hyper yet · brought Hyper forward")
    }
}

/// Headless render of the list with a failed turn among what needs you. Nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct JRenders {
    @Test func listTurnFailed1200() throws {
        let model = TurnFailedTests.model()
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now), sessions: model)
        let view = SessionListView()
            .frame(width: 1200, height: 700)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "J-list-turn-failed-1200", size: CGSize(width: 1216, height: 716), env: env)
    }
}
