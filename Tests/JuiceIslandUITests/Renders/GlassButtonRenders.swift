import AppKit
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Glass's card controls (P640 to P649), headless: every card type in the real island (SwiftUI's outline, snapped at
/// rest) on Black and on Glass over a white window (the light look), a black desktop (the dark look) and the busy photo:
/// an approval (No, Yes, Always allow), with ⌃ held, crowded (its modes on a line of their own, P490), a subagent's
/// held for the island (the time left along Yes), No's reason field; a plan; a question (its options, the field and the
/// send key), hovered, and a later step of a multi-select one (Back, Next); a read-only request (Open, ✕); a Done card's
/// reply. Offscreen the window server composites no glass, so the controls' glass is the stand-in
/// (`CardGlassStandIn`): `gb-standin-<card>-glass-<backdrop>`, and `gb-<card>-black`. Drawn hosted: the cards hold
/// AppKit text fields.
@MainActor
@Suite(.serialized)
struct GlassButtonRenders {
    typealias ID = FixtureSessionFeed.ID

    /// One card as the island shows it, and what the render asks of it (⌃ held, No's reason field, the pointer on it, an
    /// option drawn selected).
    struct Scene {
        var name: String
        var env: AppEnvironment
        var id: String
        var hints = false
        var reason = false
        var hovered = false
        var selected: Int?
    }

    static let workflow = "demo-claude-workflow"
    static let crowded = "demo-mode-crowded"

    /// The scenes, fed through the live paths of the demo engines.
    static func scenes() throws -> [Scene] {
        let prototype = { AppEnvironment.demo(settings: .ephemeral(), sessions: .prototype) }
        let allStates = { AppEnvironment.demo(settings: .ephemeral(), sessions: .allStates) }
        let reply = AppSettings.ephemeral()
        reply.replyFromCompletionCard = true
        // The second of three questions, multi-select, two picked: Back and Next.
        let questions = AppEnvironment.demo(settings: .ephemeral(), sessions: .cards)
        questions.sessions.answerQuestion(ID.questions, .option(1))
        questions.sessions.answerQuestion(ID.questions, .option(0))
        questions.sessions.answerQuestion(ID.questions, .option(2))
        return [
            Scene(name: "approval", env: prototype(), id: ID.approval),
            Scene(name: "approval-hints", env: prototype(), id: ID.approval, hints: true),
            Scene(name: "crowded", env: try crowdedEnv(), id: crowded),
            Scene(name: "held", env: try heldEnv(), id: workflow),
            Scene(name: "reason", env: prototype(), id: ID.approval, reason: true),
            Scene(name: "plan", env: allStates(), id: ID.plan),
            Scene(name: "question", env: prototype(), id: ID.question, selected: 0),
            Scene(name: "question-hovered", env: prototype(), id: ID.question, hovered: true, selected: 1),
            Scene(name: "questions-next", env: questions, id: ID.questions),
            Scene(name: "readonly", env: AppEnvironment.demo(settings: .ephemeral(), sessions: .attention), id: FixtureSessionFeed.AttentionID.codexApproval),
            Scene(name: "done-reply", env: AppEnvironment.demo(settings: reply, sessions: .allStates), id: ID.claudeDone, hovered: true),
        ]
    }

    /// The most a card offers: No, Yes, Always allow's rule, Accept edits and Bypass (`ShipRenders`' crowded card).
    static func crowdedEnv() throws -> AppEnvironment {
        let env = AppEnvironment.demo(settings: .ephemeral(), sessions: .cards)
        let feed = try #require(env.fixtureFeed)
        feed.engine.loadPreviewEvents(FixtureSessionFeed.start(crowded, title: "Shoot the site's charts", project: "notes-site",
                                                               prompt: "shoot the charts", at: DemoClock.now - 300))
        feed.engine.loadPreviewNote(event: "PreToolUse", sessionID: crowded, permissionMode: "bypassPermissions")
        var request = FixtureSessionFeed.claudeRequest(crowded, tool: "Bash", useID: "toolu_demo_mode_mkdir", input: [
            "command": "mkdir -p site/shots/light site/shots/dark", "description": "Make the folders for the shots"])
        request["permission_suggestions"] = [
            ["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "mkdir -p site/shots/light:*"]],
             "behavior": "allow", "destination": "localSettings"],
            ["type": "setMode", "mode": "acceptEdits", "destination": "session"],
        ]
        feed.engine.loadPreviewHookRequest(request, source: "claude", entrypoint: "cli")
        return env
    }

    /// A workflow's subagent asking for Bash, held for the island with 7 s of its 12 left (`OptInRenders`' held card).
    static func heldEnv() throws -> AppEnvironment {
        let now = DemoClock.now
        let feed = FixtureSessionFeed(scenario: .attention, now: now)
        feed.engine.loadPreviewEvents(FixtureSessionFeed.start(workflow, title: "Shoot the site's charts", project: "notes-site",
                                                               prompt: "run the site workflow", at: now - 180, terminal: "Claude.app"))
        feed.engine.answersSubagents = true
        feed.engine.loadPreviewHookRequest(FixtureSessionFeed.claudeRequest(workflow, tool: "Bash", useID: "toolu_demo_shots", input: [
            "command": "cd ~/Developer/notes-site/site && rm -f shots/* && node probe.cjs",
            "description": "Shoot pinned charts in light and dark"], agent: "agent-demo-wf1", agentType: "workflow-subagent"),
                                           source: "claude", entrypoint: "claude-desktop")
        let request = try #require(feed.engine.attentionHead(for: workflow))
        feed.engine.islandShows(requestID: request.id)
        let settings = AppSettings.ephemeral()
        settings.answerSubagentsOnIsland = true
        let model = EngineSessionsModel(engine: feed.engine, clock: { now + 5 })
        return AppEnvironment(settings: settings, usage: DemoUsageModel(now: now), sessions: model)
    }

    /// What the scene asks of the card, on any view.
    static func asked<V: View>(_ view: V, _ scene: Scene) -> some View {
        view
            .environment(\.showsShortcutHints, scene.hints)
            .environment(\.previewReasonField, scene.reason)
            .environment(\.previewCardHovered, scene.hovered)
            .environment(\.previewSelectedOption, scene.selected)
            .environment(\.sessionGlyphsAnimated, false)
    }

    /// The island's layout for the card as the scene draws it (`DMotionRenders.measure`, with the scene's asks).
    static func layout(_ scene: Scene) -> ContentLayout {
        _ = NSApplication.shared
        let ui = IslandUIState()
        ui.isOpen = true
        ui.card = scene.env.sessions.card(for: scene.id)
        ui.islandLive = false
        let targets = SurfaceTargets(notch: IslandGlassRenders.notch, pill: .empty, islandWidth: IslandSize.standard.outer)
        let director = IslandMotionDirector(model: IslandChoreography(metrics: .init(targets: targets)), ui: ui)
        let size = CGSize(width: IslandSize.standard.canvasWidth, height: 700)
        let root = IslandRootView(ui: ui, notch: IslandGlassRenders.notch, canvas: size, size: .standard, actions: IslandViewActions(),
                                  pillClicked: {}, measured: { [director] in director.measured($0) })
        let hosting = NSHostingView(rootView: AnyView(asked(root, scene).environment(scene.env).environment(\.colorScheme, .dark)))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = CGRect(origin: .zero, size: size)
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        director.flushMeasurements()
        window.contentView = nil
        return director.model.layout
    }

    /// The opened island at rest on the scene's card, and the render's size (the island and a margin under it).
    static func state(_ scene: Scene) -> (ui: IslandUIState, size: CGSize) {
        let ui = IslandGlassRenders.state(scene.env, surface: .island, card: scene.id, events: [(0, .present(.card(sessionID: scene.id)))],
                                          at: 1.5, layout: layout(scene))
        return (ui, CGSize(width: 540, height: (ui.live.surface.value.height + 24).rounded(.up)))
    }

    /// The scene in `theme` over `backdrop`, hosted.
    static func render(_ scene: Scene, _ ui: IslandUIState, size: CGSize, theme: JuiceTheme, backdrop: GlassBackdrop, name: String) throws {
        let view = asked(IslandGlassRenders.scene(ui, size: size, backdrop: backdrop, theme: theme), scene)
        try RenderHarness.renderHosted(view, name, size: size, env: scene.env)
    }

    /// Every card on Black and on Glass over each judged backdrop.
    @Test func everyCardOnBlackAndGlass() throws {
        for scene in try Self.scenes() {
            let (ui, size) = Self.state(scene)
            #expect(ui.card != nil, "\(scene.name): no card")
            try Self.render(scene, ui, size: size, theme: .black, backdrop: .black, name: "gb-\(scene.name)-black")
            for backdrop in GlassBackdrop.judged {
                try Self.render(scene, ui, size: size, theme: .glass, backdrop: backdrop, name: "gb-standin-\(scene.name)-glass-\(backdrop.rawValue)")
            }
        }
    }
}
