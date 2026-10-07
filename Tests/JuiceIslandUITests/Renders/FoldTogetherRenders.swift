import AppKit
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 8's three lanes on one card (P1535), headless: a background card whose app can take it (Stop and Open in
/// terminal on the line, Open in Claude in the header's menu); the same card while Open in Claude waits for its turn's
/// end (Stop stays, with Cancel in the words); and a card at its prompt with a held reply (Held · its text · Cancel, and
/// no hand-over while it waits). On Black and on Glass in light: `fold-together-<scene>-black`, `-glass-light`. Drawn
/// hosted, as `FoldRenders` draws its cards. Nothing is run, typed or opened.
@MainActor
@Suite(.serialized)
struct FoldTogetherRenders {
    typealias ID = FoldFixtures.ID

    struct Scene {
        var name: String
        var folded: String
        var state: HandoffState?
        var background = false
        var held: String?
        /// What the line must show on its right, in order.
        var actions: [String]
        /// What the header's menu offers (nothing while a reply is held or the hand-over waits).
        var menu: String?
    }

    static let scenes: [Scene] = [
        Scene(name: "bg-offered", folded: ID.app, background: true, actions: ["Stop", "Open in terminal"], menu: "Open in Claude"),
        Scene(name: "bg-pending", folded: ID.app, state: .pending(.claude), background: true, actions: ["Stop", "Open in terminal"]),
        Scene(name: "held", folded: ID.app, held: "then tag the release", actions: ["Open in terminal"]),
    ]

    static func render(_ scene: Scene) throws {
        let feed = FoldFixtures.feed(folded: [scene.folded])
        FoldFixtures.handoff(feed, states: scene.state.map { [scene.folded: $0] } ?? [:])
        if scene.background {
            feed.engine.folds[scene.folded]?.background = FoldBackground(stage: .moved, shortID: "0ca371e5",
                                                                         profile: NSHomeDirectory() + "/.claude", folder: "/tmp/juice-island")
        }
        if let held = scene.held { feed.engine.folds[scene.folded]?.held = held }
        let env = FoldFixtures.env(feed)
        let card = try #require(env.sessions.foldedCard(scene.folded), "\(scene.name)")
        #expect(FoldCardActionsTests.actions(card) == scene.actions, "\(scene.name)")
        #expect(card.row.appOffer == scene.menu, "\(scene.name)")
        let (ui, size) = FoldRenders.state(env)
        let looks: [(String, JuiceTheme, GlassBackdrop, ColorScheme)] = [("black", .black, .black, .dark), ("glass-light", .glass, .white, .light)]
        for (look, theme, backdrop, scheme) in looks {
            env.settings.appearance = scheme == .light ? .light : .dark
            let view = AppearanceRenders.islandScene(ui, size: size, backdrop: backdrop, theme: theme, scheme: scheme)
                .environment(\.sessionGlyphsAnimated, false)
            try RenderHarness.renderHosted(view, "fold-together-\(scene.name)-\(look)", size: size, env: env, scheme: scheme)
        }
    }

    @Test func eachSceneOnBlackAndGlass() throws {
        for scene in Self.scenes { try Self.render(scene) }
    }
}
