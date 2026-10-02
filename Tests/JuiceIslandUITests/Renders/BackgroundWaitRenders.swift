import AppKit
import Foundation
import IslandHookNotes
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// The owner's report after fc28c1e1 (P510, P513): a main agent waiting on a workflow, on agents and a workflow, and a
/// Codex chat whose turn ended while its subagents run, each a teal row between what runs and what finished. Fed to a
/// preview engine as the superset helper (its Stop notes counting `background_tasks` by kind) and upstream's bridge feed
/// the live one (fictional folders and text). Names `bw-…`: `zsh scripts/render-all.sh BackgroundWaitRenders`.
@MainActor
@Suite(.serialized)
struct BackgroundWaitRenders {
    static let notch = IslandTheme.Metrics.referenceNotch

    @Test(arguments: [IslandStyle.clean, .detailed])
    func islandLiquid(_ style: IslandStyle) throws {
        let scene = BackgroundWaitScene()
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.glyphStyle = .liquid
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: scene.now), sessions: scene.model)
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "bw-island-\(style.rawValue)-liquid", env: env)
    }

    @Test
    func islandPixel() throws {
        let scene = BackgroundWaitScene()
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = .pixel
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: scene.now), sessions: scene.model)
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "bw-island-clean-pixel", env: env)
    }

    /// The window's list: the waiting rows on the Running card, the Codex chat in its group.
    @Test
    func window() throws {
        let scene = BackgroundWaitScene()
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = .liquid
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: scene.now), sessions: scene.model)
        let view = SessionListView()
            .frame(width: 900, height: 460)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "bw-window-900", size: CGSize(width: 916, height: 476), env: env)
    }

    /// What the scene shows, in words: each wait said once.
    @Test
    func theRowsSayEachWaitOnce() {
        let rows = BackgroundWaitScene().model.rows
        let words = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, SessionRowText.cleanStatus($0).text ?? "") })
        #expect(words["bw-review"] == "Waiting on 1 workflow")
        #expect(words["bw-parser"] == "Waiting on 2 agents · 1 workflow")
        #expect(words["bw-codex"] == "Waiting on 2 agents")
        #expect(rows.filter { $0.glyphState == .delegating }.count == 3)
    }
}

/// Five chats: a Claude one waiting on its workflow (the owner's report), one on two agents and a workflow (a dev server
/// beside them says nothing), a Codex chat whose turn ended while its two subagents run, one running, one finished.
@MainActor
final class BackgroundWaitScene {
    typealias Feed = FixtureSessionFeed

    let now = DemoClock.now
    let engine: SessionEngine
    let model: EngineSessionsModel

    init() {
        let now = now
        let engine = SessionEngine.preview(clock: { now })
        self.engine = engine
        Self.waiting(engine, "bw-review", title: "Claude · review", project: "review", prompt: "review the branch with a workflow",
                     kinds: ["workflow": 1], at: now - 1_900)
        Self.waiting(engine, "bw-parser", title: "Claude · parser", project: "parser", prompt: "map the parser and fix the grammar",
                     kinds: ["subagent": 2, "workflow": 1, "shell": 1], at: now - 600)
        engine.loadPreviewEvents(Feed.start("bw-tests", title: "Claude · juice", project: "juice", prompt: "fix the flaky test",
                                            at: now - 200))
        engine.loadPreviewEvents(Feed.start("bw-notes", title: "Claude · notes", project: "notes", prompt: "tidy the release notes",
                                            at: now - 1_500)
            + [.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: "bw-notes", claudeMetadata: ClaudeSessionMetadata(
                lastUserPrompt: "tidy the release notes", lastAssistantMessage: "Tidied the notes into three sections."), timestamp: now - 1_300)),
               .sessionCompleted(SessionCompleted(sessionID: "bw-notes", summary: "Tidied the notes into three sections.",
                                                  timestamp: now - 1_300))])
        engine.loadPreviewEvents([
            .sessionStarted(SessionStarted(sessionID: "bw-codex", title: "Codex · docs", tool: .codex, origin: .live, initialPhase: .running,
                                           summary: "Started.", timestamp: now - 900,
                                           jumpTarget: JumpTarget(terminalApp: "Terminal", workspaceName: "docs", paneTitle: "codex",
                                                                  workingDirectory: "/tmp/docs"),
                                           codexMetadata: CodexSessionMetadata(transcriptPath: "/tmp/sessions/rollout-bw-codex.jsonl",
                                                                               lastUserPrompt: "check every page for broken links"))),
            .activityUpdated(SessionActivityUpdated(sessionID: "bw-codex", summary: "Prompt: check every page for broken links",
                                                    phase: .running, timestamp: now - 900)),
        ])
        engine.takeCodexChildren(["k1", "k2"].map {
            CodexChildThread(id: $0, parentID: "bw-codex", rootID: "bw-codex", name: "worker", isRunning: true, updatedAt: now - 60,
                             transcriptPath: "")
        })
        engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: "bw-codex", summary: "Asked two workers.",
                                                                     timestamp: now - 800))])
        model = EngineSessionsModel(engine: engine, clock: { now })
    }

    /// A chat whose main agent started background work and ended its turn: the Stop's note (its `background_tasks` by
    /// kind) and the bridge's completion.
    private static func waiting(_ engine: SessionEngine, _ id: String, title: String, project: String, prompt: String,
                                kinds: [String: Int], at date: Date) {
        engine.loadPreviewEvents(Feed.start(id, title: title, project: project, prompt: prompt, at: date))
        engine.ingest(note: HookContextNote(event: "Stop", sessionID: id, agentPID: 900, source: "claude",
                                           backgroundTaskCount: kinds.values.reduce(0, +), backgroundTaskKinds: kinds))
        engine.loadPreviewEvents([.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: prompt, lastAssistantMessage: "Started the work; I'll pick up its results."), timestamp: date + 40)),
                                  .sessionCompleted(SessionCompleted(sessionID: id, summary: "Started the work.", timestamp: date + 40))])
    }
}
