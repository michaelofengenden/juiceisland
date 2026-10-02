import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The card's title line (P101): the tapped row lifts into the card's header place and the two cross, so exactly one
/// title line shows at rest, whichever way the card came (an attention open from the pill, a tap, another card, back
/// from the list, a flip either way), and the views hold what the model holds: a channel the model forgets or resets
/// (a part that went away, a close's reset, a card that unmounts) is forgotten in the views too, so nothing comes back
/// at the focus or the place it left with. The views' side is `IslandMotionDirector.write` replaying every command
/// into an `IslandUIState`, as the live island does.
@MainActor
struct DIslandCrossTests {
    typealias Model = IslandChoreography
    typealias Events = [(TimeInterval, Model.Event)]
    typealias Scenario = DIslandPanelSizingTests.Scenario

    static let notch = IslandTheme.Metrics.referenceNotch

    /// A Clean list of four rows (41 pt apart) under a usage block, the footer, and `card`'s card measured.
    static func layout(card: String? = nil, usage: Bool = true, without: Set<PartID> = []) -> ContentLayout {
        let top: CGFloat = usage ? 36 + 48 : 36
        var layout = ContentLayout(header: 34, list: (usage ? 48 : 0) + 2 + 4 * 41 + 20)
        if usage { layout.parts[.usage] = CGRect(x: 18, y: 36, width: 444, height: 48) }
        for i in 0..<4 { layout.parts[.row("r\(i)")] = CGRect(x: 18, y: top + CGFloat(i) * 41, width: 444, height: 41) }
        layout.parts[.footer] = CGRect(x: 18, y: top + 4 * 41, width: 444, height: 20)
        layout.cardHeaderTop = 34 + 8
        if let card {
            layout.card = 196
            layout.cardID = card
            layout.parts[.cardHeader] = CGRect(x: 18, y: 42, width: 444, height: 41)
            layout.parts[.cardBody] = CGRect(x: 18, y: 83, width: 444, height: 140)
        }
        for part in without { layout.parts[part] = nil }
        return layout
    }

    /// Every way to a card and back, on the notch and the top bar, with and without Reduce Motion. A card measures a
    /// frame after it mounts (as the live island reports it), the list without it once it has gone.
    static var scenarios: [Scenario] {
        var all: [Scenario] = []
        for notch in [Optional(Self.notch), nil] {
            for reduce in [false, true] {
                func model(_ surface: Model.Surface = .closed, layout: ContentLayout = layout(),
                           presentation: IslandPresentation = .list) -> Model {
                    let pill = DIslandPanelSizingTests.pill(notch: notch)
                    return Model(metrics: .init(targets: SurfaceTargets(notch: notch, pill: pill), layout: layout, reduceMotion: reduce),
                                 surface: surface, presentation: presentation)
                }
                let tag = "\(notch == nil ? "bar" : "notch")\(reduce ? " reduced" : "")"
                func card(_ id: String, at t: TimeInterval) -> Events {
                    [(t, .present(.card(sessionID: id))), (t + 0.016, .content(layout(card: id)))]
                }
                all += [
                    Scenario(name: "attention \(tag)", start: model(),
                             events: [(0, .open(.attention, .card(sessionID: "r0"))), (0.016, .content(layout(card: "r0")))]),
                    Scenario(name: "tap \(tag)", start: model(.island), events: card("r0", at: 0)),
                    Scenario(name: "tap-row4 \(tag)", start: model(.island), events: card("r3", at: 0)),
                    Scenario(name: "swap \(tag)", start: model(.island, layout: layout(card: "r1"), presentation: .card(sessionID: "r1")),
                             events: card("r0", at: 0)),
                    Scenario(name: "back \(tag)", start: model(.island),
                             events: card("r0", at: 0) + [(0.6, .present(.list)), (0.92, .content(layout()))] + card("r0", at: 1.2)),
                    Scenario(name: "flip \(tag)", start: model(.island),
                             events: card("r2", at: 0) + [(0.5, .present(.list)), (0.6, .present(.card(sessionID: "r2")))]),
                    Scenario(name: "flip-before-the-cross \(tag)", start: model(.island),
                             events: card("r2", at: 0) + [(0.06, .present(.list))]),
                    Scenario(name: "swap-before-the-row-went-home \(tag)", start: model(.island),
                             events: card("r2", at: 0) + card("r0", at: 0.15) + [(1, .present(.list))]),
                    Scenario(name: "another-card-before-the-row-got-home \(tag)", start: model(.island),
                             events: card("r2", at: 0) + [(0.6, .present(.list))] + card("r1", at: 0.63) + [(1.5, .present(.list))]),
                    Scenario(name: "flip-back-before-home \(tag)", start: model(.island),
                             events: card("r2", at: 0) + [(0.5, .present(.list)), (0.53, .present(.card(sessionID: "r2")))]),
                    // The owner's double title line (2026-09-25): a row left the list while it showed (the rows sorted
                    // again), came back while the island was closed, then asked for approval and opened its card.
                    Scenario(name: "returned-row \(tag)", start: model(.island),
                             events: [(0, .content(layout(without: [.row("r0")]))), (0.4, .close(.fold)), (1.4, .content(layout())),
                                      (2, .open(.attention, .card(sessionID: "r0"))), (2.016, .content(layout(card: "r0")))]),
                    Scenario(name: "open-over-a-card-on-its-way \(tag)", start: model(.island),
                             events: card("r2", at: 0) + [(0.05, .open(.click, .card(sessionID: "r2")))]),
                    // An open over an island already opening: an approval (or a tap) while the list still unfolds
                    // from a hover, a hover while a card opens, and an approval while the island closes.
                    Scenario(name: "hover-then-attention \(tag)", start: model(),
                             events: [(0, .open(.hover, .list)), (0.12, .open(.attention, .card(sessionID: "r0"))),
                                      (0.136, .content(layout(card: "r0")))]),
                    Scenario(name: "hover-then-attention-row4 \(tag)", start: model(),
                             events: [(0, .open(.hover, .list)), (0.05, .open(.attention, .card(sessionID: "r3"))),
                                      (0.066, .content(layout(card: "r3")))]),
                    Scenario(name: "hover-then-tap \(tag)", start: model(), events: [(0, .open(.hover, .list))] + card("r1", at: 0.2)),
                    Scenario(name: "attention-then-hover \(tag)", start: model(),
                             events: [(0, .open(.attention, .card(sessionID: "r2"))), (0.016, .content(layout(card: "r2"))),
                                      (0.1, .open(.hover, .list))]),
                    Scenario(name: "close-then-attention \(tag)", start: model(.island),
                             events: [(0, .close(.fold)), (0.15, .open(.attention, .card(sessionID: "r1"))),
                                      (0.166, .content(layout(card: "r1")))]),
                    Scenario(name: "close-mid-glide \(tag)", start: model(.island),
                             events: card("r2", at: 0) + [(0.1, .close(.fold)), (1.2, .open(.hover, .list))]),
                    Scenario(name: "close-before-the-glide \(tag)", start: model(.island),
                             events: [(0, .present(.card(sessionID: "r2"))), (0.005, .close(.dismiss)),
                                      (1, .open(.attention, .card(sessionID: "r1"))), (1.016, .content(layout(card: "r1")))]),
                    Scenario(name: "dismiss-mid-glide-home \(tag)", start: model(.island),
                             events: card("r2", at: 0) + [(0.6, .present(.list)), (0.62, .close(.dismiss)), (1.5, .open(.hover, .list))]),
                    Scenario(name: "usage-folds-and-opens \(tag)", start: model(.island),
                             events: [(0, .content(layout(usage: false))), (0.5, .content(layout()))]),
                    Scenario(name: "footer-goes-and-comes \(tag)", start: model(.island),
                             events: [(0, .content(layout(without: [.footer]))), (0.5, .close(.fold)), (1.3, .content(layout())),
                                      (1.6, .open(.hover, .list))]),
                    Scenario(name: "display-change-mid-card \(tag)", start: model(.island),
                             events: card("r2", at: 0) + [(0.08, .display(model(.island).metrics))]),
                ]
            }
        }
        return all
    }

    /// Every replay the island's tests know: these and the panel's.
    static var everyScenario: [Scenario] { scenarios + DIslandPanelSizingTests.scenarios }

    /// Every replay as it is, or under Motion: Refined and Hover: Quick.
    static func everyScenario(refined: Bool) -> [Scenario] { refined ? everyScenario.map(\.refined) : everyScenario }

    // MARK: The views and the model

    /// The views' state as the live island's: `start` snapped, then every command the model emits, in order.
    static func playView(_ scenario: Scenario, until end: TimeInterval = 3.5,
                         _ body: (_ model: Model, _ ui: IslandUIState, _ t: TimeInterval) -> Void = { _, _, _ in }) -> (Model, IslandUIState) {
        let ui = IslandUIState()
        IslandMotionDirector.snap(ui, to: scenario.start, at: 0)
        var last = scenario.start
        DIslandPanelSizingTests.play(scenario, until: end) { model, t, commands in
            for command in commands { IslandMotionDirector.write(command, to: ui) }
            last = model
            body(model, ui, t)
        }
        return (last, ui)
    }

    /// The value the views were last given for `channel` (they head there on its curve).
    static func viewTarget(_ ui: IslandUIState, _ channel: Channel) -> Double {
        switch channel {
        case .left: Double(ui.surface.left)
        case .right: Double(ui.surface.right)
        case .height: Double(ui.surface.height)
        case .ear: Double(ui.surface.ear)
        case .radius: Double(ui.surface.radius)
        case .rimLift: Double(ui.channels.rimLift)
        case .pill: ui.channels.pill
        case .pillArrive: ui.channels.pillArrive
        case .header: ui.channels.header
        case let .part(part): ui.channels.part(part)
        case let .glide(id): Double(ui.channels.glide(id))
        case .cardRide: Double(ui.channels.cardRide)
        case .shoulders: ui.channels.shoulders
        // Motion: Liquid's values are the outline's, never a view's box: the views hold what the model does.
        case let .liquid(key): Double(LiquidParams.rest[key])
        }
    }

    static func modelTarget(_ model: Model, _ channel: Channel) -> Double {
        model.values[channel]?.target ?? Model.defaultValue(channel)
    }

    /// Every channel either side knows.
    static func channels(_ model: Model, _ ui: IslandUIState) -> Set<Channel> {
        Set(model.values.keys).union(ui.channels.parts.keys.map(Channel.part)).union(ui.channels.glides.keys.map(Channel.glide))
    }

    /// At every millisecond of every replay the views head exactly where the model does: nothing the model forgot or
    /// reset stays behind in them.
    @Test(arguments: [false, true])
    func theViewsAlwaysHeadWhereTheModelDoes(refined: Bool) {
        for scenario in Self.everyScenario(refined: refined) {
            var first: String?
            _ = Self.playView(scenario, until: 3) { model, ui, t in
                guard first == nil else { return }
                for channel in Self.channels(model, ui) {
                    let view = Self.viewTarget(ui, channel), target = Self.modelTarget(model, channel)
                    if abs(view - target) > 1e-6 { first = "\(channel) at \(Int((t * 1000).rounded())) ms: views \(view), model \(target)" }
                }
            }
            #expect(first == nil, "\(scenario.name): \(first ?? "")")
        }
    }

    /// At rest exactly one title line shows: a card's header and no list part under it, or the list and no card; every
    /// row home and the card's body where it hangs.
    @Test(arguments: [false, true])
    func atRestExactlyOneTitleLineShows(refined: Bool) {
        for scenario in Self.everyScenario(refined: refined) {
            let (model, ui) = Self.playView(scenario)
            let parts = Set(model.layout.parts.keys).union(ui.channels.parts.keys)
            for part in parts {
                let shown = model.isOpen && model.presentedParts.contains(part)
                let view = ui.channels.part(part), value = model.value(.part(part), at: 3.5)
                #expect(abs(view - (shown ? 1 : 0)) < 1e-9 && abs(value - (shown ? 1 : 0)) < 0.01,
                        "\(scenario.name): \(part) views \(view), model \(value), \(shown ? "shown" : "hidden")")
            }
            if model.isOpen, case let .card(id) = model.presentation {
                #expect(model.cardMounted == id && ui.channels.part(.cardHeader) == 1 && ui.channels.part(.row(id)) == 0, "\(scenario.name)")
            }
            // Every row home and the body unhung; the views' maps hold only what shows, so they never grow with history.
            #expect(ui.channels.glides.isEmpty && ui.channels.cardRide == 0,
                    "\(scenario.name): glides \(ui.channels.glides), ride \(ui.channels.cardRide)")
            #expect(Set(ui.channels.parts.keys) == Set(model.isOpen ? model.presentedParts : []), "\(scenario.name): \(ui.channels.parts)")
        }
    }

    /// A fresh model (a new display, a new show) leaves nothing behind in the views: no part, glide or card it does not
    /// know.
    @Test func aFreshModelClearsWhatTheViewsHeld() {
        let ui = IslandUIState()
        ui.apply([.part(.row("r0")): 1, .part(.cardHeader): 0.4, .glide("r2"): -129, .cardRide: 40])
        ui.card = AppEnvironment.demo().sessions.card(for: FixtureSessionFeed.ID.approval)
        let fresh = Model(metrics: .init(targets: SurfaceTargets(notch: Self.notch, pill: DIslandPanelSizingTests.pill())), ordered: false)
        IslandMotionDirector.snap(ui, to: fresh, at: 0)
        #expect(ui.channels.parts.isEmpty && ui.channels.glides.isEmpty && ui.channels.cardRide == 0 && ui.card == nil)
    }

    /// The lifted row and the card's header cross in a brief blend: never both past half, and both past a quarter for
    /// no more than 40 ms a crossing.
    @Test(arguments: [false, true])
    func theRowAndTheCardHeaderCrossInABriefBlend(refined: Bool) {
        for scenario in (refined ? Self.scenarios.map(\.refined) : Self.scenarios) where !scenario.name.contains("reduced") {
            guard let id = scenario.events.lazy.compactMap({ event -> String? in
                if case let .present(.card(id)) = event.1 { return id }
                if case let .open(_, .card(id)) = event.1 { return id }
                return nil
            }).first else { continue }
            var both = 0, half = 0
            _ = Self.playView(scenario) { model, _, t in
                let row = model.value(.part(.row(id)), at: t), header = model.value(.part(.cardHeader), at: t)
                if min(row, header) > 0.25 { both += 1 }
                if min(row, header) > 0.5 { half += 1 }
            }
            let crossings = max(1, scenario.events.filter { if case .present = $0.1 { true } else { false } }.count)
            #expect(half == 0 && both <= 40 * crossings, "\(scenario.name): both past a quarter \(both) ms, past half \(half) ms")
        }
    }

    /// A row that shows never jumps: its drawn place (home, glide and focus drift) moves less than 2 pt a millisecond
    /// while it is in focus, and so does the card's body under its ride.
    @Test(arguments: [false, true])
    func aShowingRowOrCardBodyNeverJumps(refined: Bool) {
        for scenario in (refined ? Self.scenarios.map(\.refined) : Self.scenarios) where !scenario.name.contains("reduced") {
            // A new measurement moves a home slot at once here; the views move it on the rows' own animation.
            var previous: [PartID: (home: CGRect, y: CGFloat)] = [:]
            var worst = (jump: CGFloat(0), at: "")
            _ = Self.playView(scenario) { model, _, t in
                for (part, rect) in model.layout.parts where part == .cardBody || { if case .row = part { true } else { false } }() {
                    let p = model.value(.part(part), at: t)
                    guard p > 0.05 else {
                        previous[part] = nil
                        continue
                    }
                    let y = MotionRefinedTests.drawn(model, part, rect, at: t).minY
                    if let before = previous[part], before.home == rect, abs(y - before.y) > worst.jump {
                        worst = (abs(y - before.y), "\(part) at \(Int((t * 1000).rounded())) ms")
                    }
                    previous[part] = (rect, y)
                }
            }
            #expect(worst.jump < 2, "\(scenario.name): \(worst)")
        }
    }
}
