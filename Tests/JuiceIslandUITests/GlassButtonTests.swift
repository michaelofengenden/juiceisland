import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Glass's card controls (P640 to P649): on Glass a card's actions are the system's own interactive glass, the primary
/// answer prominent (tinted, under the key's own face), the one that refuses clear, the rest regular; at the size and in
/// the shape they had, so the rows wrap as before (P490); still under Reduce Motion and on an empty field's send key;
/// nothing ticking at rest. Black and Smoke draw what they drew (their renders byte-identical, a probe outside the
/// tree). The live glass is the window server's and cannot be seen headless (P565): the layer checks read what SwiftUI
/// builds for it.
@MainActor
@Suite(.serialized)
struct GlassButtonTests {
    typealias C = GlassContrast
    typealias ID = FixtureSessionFeed.ID

    // MARK: Which glass (P640, P641)

    /// Yes, Approve, a read-only card's Open, Next and Send take the prominent glass; No and Keep planning the clear
    /// one; everything else the regular one. Each is the system's glass, interactive.
    @Test func eachAnswerTakesItsGlass() {
        #expect(CardActionButton.glassRole(primary: true, refuses: false) == .prominent)
        #expect(CardActionButton.glassRole(primary: false, refuses: true) == .clear)
        #expect(CardActionButton.glassRole(primary: false, refuses: false) == .regular)
        let tint = IslandPalette.glass.primary
        #expect(CardGlass.glass(.prominent, tint: tint, interactive: true) == Glass.regular.tint(tint).interactive())
        #expect(CardGlass.glass(.regular, interactive: true) == Glass.regular.interactive())
        #expect(CardGlass.glass(.clear, interactive: true) == Glass.clear.interactive())
        // The three are told apart (the check above is not vacuous).
        #expect(Glass.regular.interactive() != Glass.clear.interactive())
        #expect(Glass.regular.tint(tint).interactive() != Glass.regular.interactive())
    }

    /// Reduce Motion, and a key that is off (the send key while its field is empty), hold the glass still under a press:
    /// the same glass, not interactive.
    @Test func reduceMotionAndAnOffKeyHoldTheGlassStill() {
        #expect(CardGlass.glass(.regular, interactive: false) == Glass.regular.interactive(false))
        #expect(CardGlass.glass(.regular, interactive: false) != Glass.regular.interactive())
        #expect(CardGlass.glass(.clear, interactive: false) == Glass.clear.interactive(false))
    }

    // MARK: Size, shape and wrapping (P490, P643)

    /// Every control keeps its size on Glass, live and in renders, so the island's rows measure and wrap as before.
    @Test func everyControlKeepsItsSizeOnGlass() {
        func size<V: View>(_ view: V, _ theme: JuiceTheme, _ rendering: GlassRendering, width: CGFloat? = nil) -> CGSize {
            let host = NSHostingController(rootView: view.environment(\.juiceTheme, theme).environment(\.glassRendering, rendering))
            return host.sizeThatFits(in: CGSize(width: width ?? 10_000, height: 1_000))
        }
        let option = QuestionCardModel.Option(label: "Juice Island", description: "Reads like a place; matches the repo juice-island.")
        for hints in [false, true] {
            let controls: [(String, AnyView, CGFloat?)] = [
                ("No", AnyView(CardActionButton(title: "No", key: "⌃D", refuses: true) {}), nil),
                ("Yes", AnyView(CardActionButton(title: "Yes", key: "⌃A", primary: true) {}), nil),
                ("Yes, shared", AnyView(CardActionButton(title: "Yes", key: "⌃A", primary: true, fills: true) {}), 140),
                ("Always allow", AnyView(CardActionButton(title: "Always allow git push:*", key: "⌃⇧A") {}), nil),
                ("✕", AnyView(CardDismissButton {}), nil),
                ("an option", AnyView(QuestionOptionButton(index: 0, option: option, selected: true) {}), 420),
                ("the field and its send key", AnyView(AnswerFieldView(placeholder: "Type your answer…") { _ in }), 420),
            ]
            for (name, view, width) in controls {
                let hinted = view.environment(\.showsShortcutHints, hints)
                let black = size(hinted, .black, .live, width: width)
                for rendering in [GlassRendering.live, .standIn] {
                    #expect(size(hinted, .glass, rendering, width: width) == black, "\(name), hints \(hints), \(rendering)")
                }
            }
        }
    }

    /// The most a card offers still never widens the island's lane on Glass: the mode buttons take a line of their own.
    @Test func aCrowdedRowOnGlassNeverWidensTheCard() {
        for rendering in [GlassRendering.live, .standIn] {
            for lane: CGFloat in [408, 428] {
                for hints in [false, true] {
                    let row = CardActionsRow(fills: true, top: 0) {
                        CardActionButton(title: "No", key: "⌃D", refuses: true, fills: true) {}
                        CardActionButton(title: "Yes", key: "⌃A", primary: true, fills: true) {}
                        CardActionButton(title: "Always allow mkdir -p site/shots/light:*", key: "⌃⇧A", fills: true) {}
                        ModeButtons(modes: [.acceptEdits, .bypassPermissions], plan: false, fills: true) { _ in }
                    }
                    .environment(\.showsShortcutHints, hints)
                    .environment(\.juiceTheme, .glass)
                    .environment(\.glassRendering, rendering)
                    let size = NSHostingController(rootView: row).sizeThatFits(in: CGSize(width: lane, height: 1000))
                    #expect(size.width <= lane, "\(rendering) lane \(lane), hints \(hints): \(size.width)")
                    #expect(size.height > 50, "\(rendering) lane \(lane), hints \(hints): \(size.height)")
                }
            }
        }
    }

    // MARK: The live glass (P641, P642, P644)

    /// What SwiftUI builds for the live island's card, headless: the glass shapes it hands the window server, the tints
    /// on them, and anything still animating.
    struct Glassware {
        /// Glass shapes (one per control; the island's own is a rectangle with no corner).
        var roundedShapes = 0
        /// Separate glass backdrops (a container's shapes share one).
        var backdrops = 0
        /// Tinted glass (the prominent key's).
        var tints = 0
        /// Layers still animating.
        var animating: [String] = []
        /// Glass backdrops with no mask above them: glass the island's outline does not cut (its mask is SwiftUI's clip on
        /// SwiftUI's outline, `IslandMaskedView`'s shape on Core Animation's).
        var uncut = 0

        init(_ root: CALayer) { walk(root) }

        private mutating func walk(_ layer: CALayer) {
            let kind = String(describing: type(of: layer))
            if kind.contains("Backdrop"), (layer.filters ?? []).contains(where: { String(describing: $0).contains("glassBackground") }) {
                backdrops += 1
                var above = layer.superlayer, cut = false
                while let ancestor = above, !cut {
                    cut = ancestor.mask != nil
                    above = ancestor.superlayer
                }
                if !cut { uncut += 1 }
            }
            if kind.contains("SDFElement"), layer.cornerRadius > 0, layer.superlayer?.superlayer?.name == "@0",
               layer.superlayer?.superlayer.map({ String(describing: type(of: $0)) })?.contains("SDFLayer") == true,
               layer.superlayer?.superlayer?.superlayer.map({ String(describing: type(of: $0)) })?.contains("Backdrop") == true {
                roundedShapes += 1
            }
            if kind == "CASDFLayer", (layer.value(forKey: "effect")).map({ String(describing: $0).contains("GradientEffect") }) == true {
                tints += 1
            }
            if let keys = layer.animationKeys(), !keys.isEmpty { animating.append("\(kind) \(keys)") }
            for sublayer in layer.sublayers ?? [] { walk(sublayer) }
        }
    }

    /// The live island on a card, at rest, in `theme` on `outline`.
    static func glassware(_ id: String, theme: JuiceTheme, outline: IslandOutline, reduceMotion: Bool = false) async throws -> Glassware {
        _ = NSApplication.shared
        let rig = FramePerf.IslandRig(style: .clean, glyph: .pixel, glyphsMove: false, outline: outline, theme: theme)
        await rig.start()
        rig.open(.card(sessionID: id))
        await FramePerf.wait(1.5)
        let glassware = Glassware(try #require(rig.host.layer))
        rig.stop()
        return glassware
    }

    /// Glass: an approval's No, Yes and Always allow are three glass shapes of their own (no container: one would lay
    /// Yes's tint over Always allow, P642), one of them tinted; a question's four options share one container's glass,
    /// the send key has its own; every glass lies under the outline's mask, so none draws past the island (fail-closed,
    /// as the island's own); nothing animates at rest. Black and Smoke build no glass for a card at all.
    @Test(arguments: [IslandOutline.swiftUI, .coreAnimation])
    func theLiveCardIsTheSystemsGlass(_ outline: IslandOutline) async throws {
        let approval = try await Self.glassware(ID.approval, theme: .glass, outline: outline)
        #expect(approval.roundedShapes == 3 && approval.tints == 1, "\(approval)")
        // The island's own glass and one for each answer, every one under the island's cut (its clip or its mask).
        #expect(approval.backdrops == 4 && approval.uncut == 0, "\(approval)")
        #expect(approval.animating.isEmpty, "\(approval.animating)")

        let question = try await Self.glassware(ID.question, theme: .glass, outline: outline)
        // Four options and the send key; the island's glass, the options' one and the send key's.
        #expect(question.roundedShapes == 5 && question.tints == 0 && question.backdrops == 3 && question.uncut == 0, "\(question)")
        #expect(question.animating.isEmpty, "\(question.animating)")

        for theme in [JuiceTheme.black, .smoke] {
            let card = try await Self.glassware(ID.approval, theme: theme, outline: outline)
            #expect(card.roundedShapes == 0 && card.tints == 0, "\(theme): \(card)")
            #expect(card.animating.isEmpty, "\(theme): \(card.animating)")
        }
    }

    // MARK: Legibility (P645)

    /// A control's title and key hint hold on its glass in each look. The regular and the clear glass are bounded as the
    /// island's is (the clear one shows the island's glass): the title 4.5:1 on the look's worst surface, the title and
    /// the hint 4:1 there and under the pointer's veil (`button`: `buttonHover` left a hint 3.70:1 on the dark look). The
    /// key's title on its own face, the send key's arrow on its face, a picked option's title on its veil. The stand-in's
    /// lens is drawing only: it never darkens the dark look's ground, so a render never flatters a light ink there.
    @Test func theTitlesHoldOnTheirGlass() {
        let p = IslandPalette.glass
        for scheme in [ColorScheme.light, .dark] {
            #expect(C.worstAdaptedRatio(p.ink, scheme) >= C.text, "\(scheme) title")
            for (name, fills) in [("bare", [Color]()), ("hovered", [p.button])] {
                let title = C.worstAdaptedRatio(p.ink, scheme, fills: fills), key = C.worstAdaptedRatio(p.cardKbd, scheme, fills: fills)
                #expect(title >= C.textOnFill && key >= C.textOnFill, "\(scheme) \(name): title \(title), key \(key)")
            }
            for (name, ink, face) in [("primary", p.primaryText, p.primary), ("primary hovered", p.primaryText, p.primaryHover),
                                      ("send", p.sendActiveInk, p.sendActive)] {
                let ratio = C.ratio(C.luminance(ink, scheme), C.luminance(face, scheme))
                #expect(ratio >= C.text, "\(scheme) \(name): \(ratio)")
            }
            #expect(C.worstAdaptedRatio(p.optionTitle, scheme, fills: [p.optionSelected]) >= C.textOnFill)
            #expect(C.worstAdaptedRatio(p.sendText, scheme, fills: [p.sendHover]) >= C.mark)
            for role in [CardGlass.Role.regular, .clear] where scheme == .dark {
                let lens = Color.white.opacity(CardGlass.standInLift(role, scheme))
                #expect(C.worstAdaptedRatio(p.ink, scheme, fills: [lens]) <= C.worstAdaptedRatio(p.ink, scheme))
            }
        }
    }
}
