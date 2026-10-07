import AppKit
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Open in <App> on a folded card (wave 8, P1510 to P1519), headless: the opened island's list with the card in each of
/// the hand-over's states (offered beside Open in terminal; waiting for its turn's end with Cancel; opening; in Claude;
/// in Claude with Quit Claude first; the Codex app holding it; refused with Update Claude Code; picked in
/// OpenCode), on Black and on Glass in light and dark: `fold-app-<state>-black`, `-glass-light`, `-glass-dark`. Drawn hosted,
/// as `FoldRenders` draws its cards. Nothing is run, typed or opened.
@MainActor
@Suite(.serialized)
struct FoldAppRenders {
    typealias ID = FoldFixtures.ID

    struct Scene {
        var name: String
        var folded: String
        var state: HandoffState?
    }

    static let scenes: [Scene] = [
        Scene(name: "offered", folded: ID.app, state: nil),
        Scene(name: "pending", folded: ID.working, state: .pending(.claude)),
        Scene(name: "opening", folded: ID.idle, state: .opening(.claude)),
        Scene(name: "in-claude", folded: ID.idle, state: .inApp(.claude, note: nil)),
        Scene(name: "in-claude-held", folded: ID.idle, state: .inApp(.claude, note: HandoffWords.quitApp("Claude"))),
        Scene(name: "in-codex-held", folded: ID.gone, state: .inApp(.codex, note: HandoffWords.quitApp("ChatGPT"))),
        Scene(name: "update", folded: ID.app, state: .blocked(.claude, HandoffWords.updateClaude)),
        Scene(name: "pick", folded: ID.openCode, state: .pick(.opencode)),
    ]

    static func render(_ scene: Scene) throws {
        let feed = FoldFixtures.feed(folded: [scene.folded])
        FoldFixtures.handoff(feed, states: scene.state.map { [scene.folded: $0] } ?? [:])
        let env = FoldFixtures.env(feed)
        let card = try #require(env.sessions.foldedCard(scene.folded), "\(scene.name)")
        #expect(card.app != nil, "\(scene.name)")
        let (ui, size) = FoldRenders.state(env)
        let looks: [(String, JuiceTheme, GlassBackdrop, ColorScheme)] = [
            ("black", .black, .black, .dark), ("glass-light", .glass, .white, .light), ("glass-dark", .glass, .black, .dark),
        ]
        for (look, theme, backdrop, scheme) in looks {
            env.settings.appearance = scheme == .light ? .light : .dark
            let view = AppearanceRenders.islandScene(ui, size: size, backdrop: backdrop, theme: theme, scheme: scheme)
                .environment(\.sessionGlyphsAnimated, false)
            try RenderHarness.renderHosted(view, "fold-app-\(scene.name)-\(look)", size: size, env: env, scheme: scheme)
        }
    }

    @Test func everyHandOverStateOnBlackAndGlass() throws {
        for scene in Self.scenes { try Self.render(scene) }
    }
}
