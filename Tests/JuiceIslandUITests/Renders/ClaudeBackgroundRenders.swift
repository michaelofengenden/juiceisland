import AppKit
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// A folded Claude Code session in Claude Code's own background (wave 8, P1450 to P1484), headless: the opened island
/// with the folded card over the rows, in each of its lines (Background at its prompt with Stop and Open in terminal;
/// Background · Working · its tool; attached in Terminal; stopped; Moves to the background when this turn ends; Moving
/// to the background…; Not moved, with Open in terminal to reply), on Black and on Glass in light (over a white window)
/// and dark (over a black desktop), and Black over a white window in light: `fold-bg-<state>-black`, `-black-light`,
/// `-glass-light`, `-glass-dark`.
/// Drawn hosted, as `FoldRenders` draws the card.
@MainActor
@Suite(.serialized)
struct ClaudeBackgroundRenders {
    typealias ID = FoldFixtures.ID

    struct Scene {
        var name: String
        var id: String
        var stage: FoldBackground.Stage
        var setUp: (inout FoldBackground) -> Void = { _ in }
    }

    static let scenes: [Scene] = [
        Scene(name: "moved", id: ID.idle, stage: .moved),
        Scene(name: "working", id: ID.working, stage: .moved),
        Scene(name: "attached", id: ID.idle, stage: .moved, setUp: { $0.attachedIn = "Terminal" }),
        Scene(name: "stopped", id: ID.idle, stage: .moved, setUp: { $0.stoppedByOwner = true }),
        Scene(name: "waits", id: ID.working, stage: .waitsForTurnEnd),
        Scene(name: "moving", id: ID.working, stage: .moving),
        Scene(name: "notmoved", id: ID.idle, stage: .notMoved(.stillInTab)),
        Scene(name: "cannottell", id: ID.idle, stage: .notMoved(.cannotTell)),
    ]

    static func render(_ scene: Scene) throws {
        let feed = FoldFixtures.feed(folded: [scene.id])
        var background = FoldBackground(stage: scene.stage, shortID: scene.stage == .moved ? "0ca371e5" : nil,
                                        profile: "/tmp/ji-render-home/.claude", folder: "/tmp/juice-island")
        scene.setUp(&background)
        feed.engine.folds[scene.id]?.background = background
        let env = FoldFixtures.env(feed)
        let card = try #require(env.sessions.foldedCard(scene.id), "\(scene.name)")
        #expect(card.background != nil, "\(scene.name)")
        let (ui, size) = FoldRenders.state(env)
        let looks: [(String, JuiceTheme, GlassBackdrop, ColorScheme)] = [
            ("black", .black, .black, .dark), ("black-light", .black, .white, .light),
            ("glass-light", .glass, .white, .light), ("glass-dark", .glass, .black, .dark),
        ]
        for (look, theme, backdrop, scheme) in looks {
            env.settings.appearance = scheme == .light ? .light : .dark
            let view = AppearanceRenders.islandScene(ui, size: size, backdrop: backdrop, theme: theme, scheme: scheme)
                .environment(\.sessionGlyphsAnimated, false)
            try RenderHarness.renderHosted(view, "fold-bg-\(scene.name)-\(look)", size: size, env: env, scheme: scheme)
        }
    }

    @Test func everyLineOnBlackAndGlass() throws {
        for scene in Self.scenes { try Self.render(scene) }
    }
}
