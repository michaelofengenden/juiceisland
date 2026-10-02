import AppKit
import Foundation
import IslandHookNotes
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// The owner's report of 2026-09-28 (P370): a main agent waiting on its subagents is a teal row, "Waiting on 1 agent",
/// between what runs and what finished, and the closed pill leads with the delegate's glyph while nothing else runs.
/// Fed to a preview engine as the superset helper and upstream's bridge feed the live one (fictional folders and
/// text). The glyph is the delegating helpers (P382) in `IslandTheme.delegate` (P381). Names `sw-…`:
/// `zsh scripts/render-all.sh SubagentWaitRenders`.
@MainActor
@Suite(.serialized)
struct SubagentWaitRenders {
    static let notch = IslandTheme.Metrics.referenceNotch

    @Test(arguments: [IslandStyle.clean, .detailed])
    func island(_ style: IslandStyle) throws {
        let scene = SubagentWaitScene()
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.glyphStyle = .pixel
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: scene.now), sessions: scene.model)
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "sw-island-\(style.rawValue)", env: env)
    }

    /// The Clean list in Liquid and Sand: the waiting rows' helpers beside running and done in each engine.
    @Test(arguments: [GlyphStyle.liquid, .sand])
    func islandEngines(_ glyph: GlyphStyle) throws {
        let scene = SubagentWaitScene()
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = glyph
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: scene.now), sessions: scene.model)
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "sw-island-clean-\(glyph.rawValue)", env: env)
    }

    /// The window's list: the waiting rows on the Running card.
    @Test
    func window() throws {
        let scene = SubagentWaitScene()
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: scene.now), sessions: scene.model)
        let view = SessionListView()
            .frame(width: 900, height: 420)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "sw-window-900", size: CGSize(width: 916, height: 436), env: env)
    }

    /// The closed pill while the only session at work waits on its agent, in each glyph style.
    @Test(arguments: [GlyphStyle.pixel, .liquid, .sand])
    func pill(_ style: GlyphStyle) throws {
        let scene = SubagentWaitScene(onlyWaiting: true)
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = style
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: scene.now), sessions: scene.model)
        #expect(PillLead.make(rows: scene.model.rows, recentlyFinished: nil)?.state == .delegating)
        try RenderHarness.render(DScene.pill(ClosedPillView(animated: false)), "sw-pill-\(style.rawValue)", env: env)
    }
}

/// Four Claude chats: one waiting on its background agent, one on two, one running, one finished; `onlyWaiting`, the
/// first alone.
@MainActor
final class SubagentWaitScene {
    typealias Feed = FixtureSessionFeed

    let now = DemoClock.now
    let engine: SessionEngine
    let model: EngineSessionsModel

    init(onlyWaiting: Bool = false) {
        let now = now
        let engine = SessionEngine.preview(clock: { now })
        self.engine = engine
        Self.waiting(engine, "sw-parser", title: "Claude · parser", project: "parser", prompt: "map the parser and fix the grammar",
                     agents: ["a1"], at: now - 420)
        if !onlyWaiting {
            Self.waiting(engine, "sw-docs", title: "Claude · docs", project: "docs", prompt: "check every page for broken links",
                         agents: ["b1", "b2"], at: now - 900)
            engine.loadPreviewEvents(Feed.start("sw-tests", title: "Claude · juice", project: "juice", prompt: "fix the flaky test",
                                                at: now - 200))
            engine.loadPreviewEvents(Feed.start("sw-notes", title: "Claude · notes", project: "notes", prompt: "tidy the release notes",
                                                at: now - 1_500)
                + [.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: "sw-notes", claudeMetadata: ClaudeSessionMetadata(
                    lastUserPrompt: "tidy the release notes", lastAssistantMessage: "Tidied the notes into three sections."), timestamp: now - 1_300)),
                   .sessionCompleted(SessionCompleted(sessionID: "sw-notes", summary: "Tidied the notes into three sections.",
                                                      timestamp: now - 1_300))])
        }
        model = EngineSessionsModel(engine: engine, clock: { now })
    }

    /// A chat whose main agent started background agents and ended its turn: each SubagentStart's note and the bridge's
    /// activity, then the Stop's note (naming the work in flight) and the bridge's completion.
    static func waiting(_ engine: SessionEngine, _ id: String, title: String, project: String, prompt: String,
                                agents: [String], at date: Date) {
        engine.loadPreviewEvents(Feed.start(id, title: title, project: project, prompt: prompt, at: date))
        for agent in agents {
            engine.ingest(note: HookContextNote(event: "SubagentStart", sessionID: id, agentPID: 900, agentID: agent, agentType: "worker",
                                               source: "claude"))
            engine.loadPreviewEvents([.activityUpdated(SessionActivityUpdated(sessionID: id, summary: "Started worker subagent.",
                                                                               phase: .running, timestamp: date + 30))])
        }
        engine.ingest(note: HookContextNote(event: "Stop", sessionID: id, agentPID: 900, source: "claude", backgroundTaskCount: agents.count))
        engine.loadPreviewEvents([.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
            lastUserPrompt: prompt, lastAssistantMessage: "Started the agents; I'll pick up their results."), timestamp: date + 40)),
                                  .sessionCompleted(SessionCompleted(sessionID: id, summary: "Started the agents.", timestamp: date + 40))])
    }
}
