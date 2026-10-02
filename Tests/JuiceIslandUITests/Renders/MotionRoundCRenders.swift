import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Motion round C as frame strips, Original over Refined at the same model times (`mc-*.png`): the open, the close, the
/// card and the hover, drawn as `DMotionRenders` draws its strips (the island's root at explicit model times, glyphs
/// still, the hardware notch over it). Refined's rows show round C: the soft edge (F6) the content fades into, the
/// earlier fold (F1's 30 ms), the pill's glyph and count riding the wings (F7) and the continuous bottom corners (F9).
/// `mc-edge-*.png` enlarge one frame of each, Original beside Refined, so the edge and the corners can be seen pixel by
/// pixel.
@MainActor
@Suite(.serialized)
struct MotionRoundCRenders {
    typealias Model = IslandChoreography
    typealias Events = [(TimeInterval, Model.Event)]

    static let original = MotionTuning()
    static let refined = MotionTuning(motion: .refined, hover: .quick)

    struct Row {
        var title: String
        var tuning: MotionTuning
        var surface: Model.Surface = .closed
        var events: Events
        var times: [TimeInterval]
        var zero: TimeInterval = 0
    }

    static func pair(_ title: String, surface: Model.Surface = .closed, events: Events, times: [TimeInterval],
                     zero: TimeInterval = 0) -> [Row] {
        [Row(title: "Original · \(title)", tuning: original.calm, surface: surface, events: events, times: times, zero: zero),
         Row(title: "Refined · \(title)", tuning: refined, surface: surface, events: events, times: times, zero: zero)]
    }

    @Test func open() throws {
        try strip("mc-open", Self.pair("open from the pill", events: [(0, .open(.hover, .list))],
                                       times: [0.03, 0.06, 0.1, 0.13, 0.17, 0.22, 0.28, 0.36, 0.6]))
    }

    @Test func close() throws {
        try strip("mc-close", Self.pair("close to the pill", surface: .island, events: [(0, .close(.fold))],
                                        times: [0, 0.04, 0.08, 0.12, 0.17, 0.22, 0.28, 0.34, 0.42, 0.6]))
    }

    @Test func card() throws {
        let events: Events = [(0, .present(.card(sessionID: FixtureSessionFeed.ID.approval))), (1, .present(.list))]
        try strip("mc-card", Self.pair("list → card", surface: .island, events: events, times: [0, 0.04, 0.08, 0.12, 0.18, 0.26, 0.4])
                  + Self.pair("card → list", surface: .island, events: events, times: [1, 1.04, 1.08, 1.14, 1.22, 1.32, 1.5], zero: 1),
                  card: FixtureSessionFeed.ID.approval)
    }

    @Test func hover() throws {
        try strip("mc-hover", Self.pair("the pointer rests on the pill, the dwell opens it (150 ms Calm, 110 Quick)",
                                        events: [(0, .swell(true))], times: [0, 0.04, 0.08, 0.12, 0.2, 0.3]).enumerated().map { i, row in
            var row = row
            row.events.append((i == 0 ? 0.15 : 0.11, .open(.hover, .list)))
            row.times += [0.16, 0.2, 0.26].map { $0 + (i == 0 ? 0.04 : 0) }
            row.times.sort()
            return row
        } + Self.pair("a reversing open: back 130 ms into the fold", surface: .island,
                      events: [(0, .close(.fold)), (0.13, .open(.hover, .list))], times: [0.1, 0.13, 0.17, 0.22, 0.3, 0.4, 0.567]))
    }

    /// One frame enlarged ×3, Original beside Refined: the bottom-left corner and the edge mid-open (100 ms), and the
    /// pill's glyph riding in mid-close (200 ms).
    @Test func edges() throws {
        for (name, surface, events, t) in [("mc-edge-open", Model.Surface.closed, [(0.0, Model.Event.open(.hover, .list))], 0.1),
                                           ("mc-edge-close", .island, [(0.0, .close(.fold))], 0.2),
                                           ("mc-edge-rest", .island, [], 0)] as [(String, Model.Surface, Events, TimeInterval)] {
            let rows = [Row(title: "Original", tuning: Self.original.calm, surface: surface, events: events, times: [t]),
                        Row(title: "Refined", tuning: Self.refined, surface: surface, events: events, times: [t])]
            try strip(name, rows, zoom: 3)
        }
    }

    /// Show all and the usage strip (E6), live: the island's root in an offscreen window, SwiftUI running its own
    /// animations in real time (the rows a list change moves are laid out by SwiftUI, not drawn from the model) and the
    /// model's jobs firing as their moments come. Each frame is labelled with when it was drawn; drawing one headless
    /// takes some 50 ms, in which the run loop stands still, so the model's steps (the change written once what leaves
    /// has faded, the edge's start once the list is measured) can land a frame late here: the strip shows how a change is
    /// composed, and `MotionRoundCTests` holds its timing. Original over Refined, Header strip placement, every session.
    @Test func listChanges() throws {
        let times: [TimeInterval] = [0, 0.04, 0.08, 0.12, 0.16, 0.22, 0.3, 0.45]
        var drawn: [(String, [(String, NSImage)])] = []
        let plays: [(String, Model.ListChange, Model.ListChange?)] = [("Show all", .showAll, nil), ("the strip opens", .strip(true), nil),
                                                                    ("the strip folds", .strip(false), .strip(true))]
        for (title, change, setUp) in plays {
            for tuning in [Self.original.calm, Self.refined] {
                let settings = AppSettings.ephemeral()
                settings.islandStyle = .clean
                settings.islandUsagePlacement = .headerStrip
                settings.glyphStyle = .pixel
                let island = LiveIslandHarness(env: .demo(settings: settings), presenting: nil, tuning: tuning, maxHeight: 900)
                defer { island.close() }
                if let setUp {
                    island.director.send(.list(setUp))
                    try island.play(for: 0.8)
                }
                var frames: [(String, NSImage)] = [], next = 0
                island.director.send(.list(change))
                try island.play(for: times.last! + 0.05) { elapsed in
                    guard next < times.count, elapsed >= times[next] else { return }
                    frames.append(("\(Int((elapsed * 1000).rounded())) ms", try Self.island(island.snapshot())))
                    while next < times.count, times[next] <= elapsed { next += 1 }
                }
                drawn.append(("\(tuning.motion == .refined ? "Refined" : "Original") · \(title)", frames))
            }
        }
        let tile = CGSize(width: Self.crop.width / 2, height: Self.crop.height / 2)
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(drawn.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.0).font(Fonts.sys(11)).foregroundStyle(IslandTheme.ink2)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.1.enumerated()), id: \.offset) { _, frame in
                            VStack(alignment: .leading, spacing: 4) {
                                Image(nsImage: frame.1).resizable().frame(width: tile.width, height: tile.height)
                                    .background(Color(white: 0.3))
                                Text(frame.0).font(Fonts.mono(10)).foregroundStyle(IslandTheme.ink3)
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Color(hex: 0x0B0D0D))
        try RenderHarness.render(view, "mc-list", env: .demo())
    }

    /// The live canvas's region the island opens in (points, from its top-left).
    static let crop = CGRect(x: (IslandPanelSizing.canvasWidth - 540) / 2, y: 0, width: 540, height: 520)

    /// `image` cut to `crop`.
    static func island(_ image: NSImage) throws -> NSImage {
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        let scale = CGFloat(rep.pixelsWide) / image.size.width
        let cg = try #require(rep.cgImage?.cropping(to: CGRect(x: crop.minX * scale, y: crop.minY * scale,
                                                               width: min(crop.width, image.size.width - crop.minX) * scale,
                                                               height: min(crop.height, image.size.height - crop.minY) * scale)))
        return NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    // MARK: Drawing

    /// The prototype's sessions in Clean, Header strip placement, Pixel, as `DMotionRenders` draws them.
    private func strip(_ name: String, _ rows: [Row], card: String? = nil, zoom: CGFloat = 1) throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = .pixel
        let env = AppEnvironment.demo(settings: settings, sessions: .prototype)
        let notch = IslandTheme.Metrics.referenceNotch, menuBar = IslandTheme.Metrics.referenceMenuBar
        let pill = PillContent.make(rows: env.sessions.rows, settings: settings, glance: false, recentlyFinished: nil,
                                    now: env.sessions.now, notch: notch, menuBar: menuBar)
        let layout = DMotionRenders.measure(env: env, notch: notch, card: card)
        let tile = CGSize(width: 500, height: 272)
        var drawn: [(String, [(String, IslandUIState)])] = []
        for row in rows {
            let start = Model(metrics: .init(targets: SurfaceTargets(notch: notch, pill: pill), layout: layout, tuning: row.tuning),
                              surface: row.surface)
            var frames: [(String, IslandUIState)] = []
            for t in row.times {
                let (model, _) = Model.replay(start, row.events, until: t)
                let ui = IslandUIState()
                IslandMotionDirector.snap(ui, to: model, at: t)
                ui.presentation = model.presentation
                ui.card = model.cardMounted.flatMap { env.sessions.card(for: $0) }
                ui.islandLive = false
                ui.pillLive = false
                frames.append(("\(Int(((t - row.zero) * 1000).rounded())) ms", ui))
            }
            drawn.append((row.title, frames))
        }
        let view = VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(drawn.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.0).font(Fonts.sys(11)).foregroundStyle(IslandTheme.ink2)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Array(row.1.enumerated()), id: \.offset) { _, frame in
                            VStack(alignment: .leading, spacing: 4) {
                                DMotionRenders.frame(frame.1, notch: notch, menuBar: menuBar, size: tile)
                                    .scaleEffect(zoom, anchor: .topLeading)
                                    .frame(width: tile.width * zoom, height: tile.height * zoom, alignment: .topLeading)
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

extension MotionTuning {
    /// This feel with Hover: Calm.
    var calm: MotionTuning { MotionTuning(motion: motion, hover: .calm) }
}
