import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The card's title line (P101) as frame strips: a Codex approval with a long title and status (the owner's card of
/// 2026-09-25), the question and a Done card, each reached from the pill by something that needs you, by a tap in the
/// list, in place of another card, back from the list, and by the owner's way (a row that left the list while it
/// showed, came back while the island was closed, then asked for approval). Each frame holds what the live island holds:
/// every command the model emitted up to then, written through `IslandMotionDirector.write`, with the channels it
/// moves at their values then. The last frame of each row is its rest. Renders: `m-cross-*.png`.
@MainActor
@Suite(.serialized)
struct DCrossRenders {
    typealias Model = IslandChoreography
    typealias Events = [(TimeInterval, Model.Event)]
    typealias ID = FixtureSessionFeed.ID

    struct Path {
        var title: String
        var start: Model
        var events: Events
        var times: [TimeInterval]
        var zero: TimeInterval = 0
    }

    static let notch = IslandTheme.Metrics.referenceNotch
    static let rest: TimeInterval = 4

    @Test func approval() throws { try strips("approval", card: ID.codexApproval, other: ID.question) }
    @Test func question() throws { try strips("question", card: ID.question, other: ID.codexApproval) }
    @Test func done() throws { try strips("done", card: ID.claudeDone, other: ID.codexApproval) }

    /// The approval in Detailed, at rest only.
    @Test func approvalDetailed() throws {
        try strips("approval-detailed", card: ID.codexApproval, other: ID.question, style: .detailed, frames: false)
    }

    // MARK: Drawing

    private func strips(_ name: String, card id: String, other: String, style: IslandStyle = .clean, frames: Bool = true) throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = .pixel
        let env = AppEnvironment.demo(settings: settings, sessions: .codexApproval)
        let menuBar = IslandTheme.Metrics.referenceMenuBar
        let pill = PillContent.make(rows: env.sessions.rows, settings: settings, glance: false, recentlyFinished: nil,
                                    now: env.sessions.now, notch: Self.notch, menuBar: menuBar)
        let list = DMotionRenders.measure(env: env, notch: Self.notch, card: nil)
        let card = DMotionRenders.measure(env: env, notch: Self.notch, card: id)
        let otherCard = DMotionRenders.measure(env: env, notch: Self.notch, card: other)
        var without = list
        without.parts[.row(id)] = nil
        func model(_ surface: Model.Surface, _ layout: ContentLayout, _ presentation: IslandPresentation = .list) -> Model {
            Model(metrics: .init(targets: SurfaceTargets(notch: Self.notch, pill: pill), layout: layout), surface: surface,
                  presentation: presentation)
        }
        func present(_ at: TimeInterval) -> Events { [(at, .present(.card(sessionID: id))), (at + 0.016, .content(card))] }
        let paths = [
            Path(title: "something that needs you opens it from the pill", start: model(.closed, list),
                 events: [(0, .open(.attention, .card(sessionID: id))), (0.016, .content(card))],
                 times: [0.06, 0.1, 0.15, 0.2, 0.3, Self.rest]),
            Path(title: "a tap in the list: the row lifts into the header's place", start: model(.island, list), events: present(0),
                 times: [0, 0.04, 0.08, 0.1, 0.13, 0.2, Self.rest]),
            Path(title: "in place of another card", start: model(.island, otherCard, .card(sessionID: other)), events: present(0),
                 times: [0, 0.02, 0.05, 0.1, 0.2, Self.rest]),
            Path(title: "back from the list, then the card again", start: model(.island, list),
                 events: present(0) + [(0.6, .present(.list)), (0.92, .content(list))] + present(1.2),
                 times: [0.6, 0.66, 0.75, 1.2, 1.28, 1.35, Self.rest], zero: 0.6),
            Path(title: "the owner's way: the row left the list while it showed and came back while closed",
                 start: model(.island, list),
                 events: [(0, .content(without)), (0.4, .close(.fold)), (1.4, .content(list)),
                          (2, .open(.attention, .card(sessionID: id))), (2.016, .content(card))],
                 times: [2.06, 2.1, 2.15, 2.2, 2.3, Self.rest], zero: 2),
        ]
        let tile = CGSize(width: 500, height: 330)
        func rows(_ restOnly: Bool) -> [(String, [(String, IslandUIState)])] {
            paths.map { path in
                let times = restOnly ? [Self.rest] : path.times
                return (path.title, times.map { t in
                    (t == Self.rest ? "rest" : "\(Int(((t - path.zero) * 1000).rounded())) ms", Self.view(path, at: t, env: env))
                })
            }
        }
        if frames { try sheet("m-cross-\(name)", rows(false), tile: tile, env: env, menuBar: menuBar) }
        try sheet("m-cross-\(name)-rest", rows(true), tile: tile, env: env, menuBar: menuBar)
    }

    /// What the live island holds at `t`: every command up to then written into its state, each channel the model moves
    /// where the model has it then (SwiftUI runs the same springs); a channel the model no longer knows holds the last
    /// value it was given.
    static func view(_ path: Path, at t: TimeInterval, env: AppEnvironment) -> IslandUIState {
        let ui = IslandUIState()
        IslandMotionDirector.snap(ui, to: path.start, at: 0)
        ui.card = path.start.cardMounted.flatMap { env.sessions.card(for: $0) }
        let (model, commands) = Model.replay(path.start, path.events, until: t)
        for command in commands {
            IslandMotionDirector.write(command, to: ui)
            if case let .effect(.cardSnapshot(id)) = command { ui.card = id.flatMap { env.sessions.card(for: $0) } }
        }
        ui.apply(model.frame(at: t).values)
        ui.presentation = model.presentation
        ui.islandLive = false
        ui.pillLive = false
        return ui
    }

    private func sheet(_ name: String, _ rows: [(String, [(String, IslandUIState)])], tile: CGSize, env: AppEnvironment,
                       menuBar: CGFloat) throws {
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.0).font(Fonts.sys(11)).foregroundStyle(IslandTheme.ink2)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.1.enumerated()), id: \.offset) { _, frame in
                            VStack(alignment: .leading, spacing: 4) {
                                DMotionRenders.frame(frame.1, notch: Self.notch, menuBar: menuBar, size: tile)
                                Text(frame.0).font(Fonts.mono(10)).foregroundStyle(IslandTheme.ink3)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0x0B0D0D))
        try RenderHarness.render(view, name, env: env)
    }
}
