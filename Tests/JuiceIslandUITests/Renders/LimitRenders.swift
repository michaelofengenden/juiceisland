import AppKit
@testable import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Limit warnings (P700 to P704), headless: the opened island's list (Clean and Detailed) with a Claude session at its
/// session limit, a Codex chat at its usage limit and a Claude session the API overloaded, and the island's cards for
/// the two limits, each offering the best other account ("work has 100% left", Open in work), on Black and on Glass
/// over a white window and a black desktop (`lw-<what>-<theme>[-<backdrop>]`); the window's list with its cards on
/// Black (`lw-window`); and a limit that reset, quiet (`lw-reset`). Drawn hosted: the cards hold AppKit text.
@MainActor
@Suite(.serialized)
struct LimitRenders {
    typealias L = LimitFixtures

    static func env(detailed: Bool = false, clock: EngineFixtureBox<Date>? = nil) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        if detailed { settings.islandStyle = .detailed }
        let model = clock.map { box in EngineSessionsModel(engine: L.engine(clock: box), clock: { box.current }) } ?? L.model()
        return AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: model)
    }

    static let backdrops: [GlassBackdrop] = [.white, .black]

    private func renderBoth(_ name: String, env: AppEnvironment, ui: IslandUIState, size: CGSize) throws {
        let scene = GlassButtonRenders.Scene(name: name, env: env, id: "")
        try GlassButtonRenders.render(scene, ui, size: size, theme: .black, backdrop: .black, name: "lw-\(name)-black")
        for backdrop in Self.backdrops {
            try GlassButtonRenders.render(scene, ui, size: size, theme: .glass, backdrop: backdrop, name: "lw-\(name)-glass-\(backdrop.rawValue)")
        }
    }

    /// The rows, as the opened island lists them.
    @Test func islandList() throws {
        for (style, detailed) in [("list", false), ("list-detailed", true)] {
            let env = Self.env(detailed: detailed)
            #expect(env.sessions.rows.count == 3)
            let ui = IslandGlassRenders.state(env, surface: .island)
            try renderBoth(style, env: env, ui: ui, size: CGSize(width: 540, height: detailed ? 330 : 260))
        }
    }

    /// Each limit's card, as the island shows it.
    @Test func islandCards() throws {
        for (name, id) in [("card-claude", L.claude), ("card-codex", L.codex), ("card-overloaded", L.overloaded)] {
            let env = Self.env()
            let scene = GlassButtonRenders.Scene(name: name, env: env, id: id)
            let (ui, size) = GlassButtonRenders.state(scene)
            #expect(ui.card != nil, "\(name): no card")
            try renderBoth(name, env: env, ui: ui, size: size)
        }
    }

    /// The window's list: the two Claude cards with what needs you, the Codex row with what is done.
    @Test func window() throws {
        let view = SessionListView()
            .frame(width: 900, height: 520)
            .padding(8)
            .background(Color.black)
            .environment(\.sessionGlyphsAnimated, false)
        try RenderHarness.renderHosted(view, "lw-window", size: CGSize(width: 916, height: 536), env: Self.env())
    }

    /// The Claude session's limit reset: no longer needing the owner, its row says so quietly.
    @Test func reset() throws {
        let clock = EngineFixtureBox(DemoClock.now)
        let env = Self.env(clock: clock)
        clock.update { $0 = L.claudeReset(now: DemoClock.now) + 60 }
        try #require(env.sessions as? EngineSessionsModel).tick()
        #expect(env.sessions.row(id: L.claude)?.limit?.line == "Limit reset")
        let ui = IslandGlassRenders.state(env, surface: .island)
        try renderBoth("reset", env: env, ui: ui, size: CGSize(width: 540, height: 260))
    }
}
