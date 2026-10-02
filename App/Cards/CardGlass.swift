import SwiftUI

// Theme Glass's card controls (P640 to P649): a card's actions (No, Yes, Always allow, a mode, Open, ✕, a question's
// options, Back, Next or Send, the send key) are the system's own interactive glass, so they give and shimmer under a
// press. The glass is laid on the Button from outside (`cardControlGlass`), never inside its label, so the Button keeps
// the click whatever the glass's own press does; the label keeps its size, its shape (r7), its hints and its content
// shape, so the row wraps as before (P490) and a click lands where it did (P170, P172). Black and Smoke read none of
// this: they draw what they drew, byte for byte.

/// What a card control is on Glass, and the glass it takes.
enum CardGlass {
    enum Role: Equatable, Sendable {
        /// The answer that stands out: Yes, Approve, a read-only card's Open, a question's Next or Send, the send key once
        /// its field has text. The glass tinted with the key's colour, under the key's own face.
        case prominent
        /// Any other: Always allow, a mode, a plan's Open, Back, ✕, a question's option, the empty send key.
        case regular
        /// The answer that refuses: No, Keep planning. The clear glass, which recedes.
        case clear
    }

    /// The system's glass for `role`: interactive (it gives and shimmers under a press) unless `interactive` is false
    /// (Reduce Motion, or a control that is off).
    static func glass(_ role: Role, tint: Color? = nil, interactive: Bool) -> Glass {
        let glass: Glass = switch role {
        case .prominent: .regular.tint(tint)
        case .regular: .regular
        case .clear: .clear
        }
        return glass.interactive(interactive)
    }

    /// A question's options share one glass container (one sampling, one backdrop for the four) with no melt between
    /// them: a container's spacing is the glass's smoothness, and its default (8) bridges the options' 4 pt gaps into one
    /// blob. A row of answers takes none: a container lays one glass's tint over every regular glass beside it, so Always
    /// allow would turn Yes's colour (P642).
    static let containerSpacing: CGFloat = 0

    /// The key's gloss: a line of light along the top of its face, fading by its middle (the system's own rim lies under
    /// the face, which covers it).
    static let gloss = (top: 0.42, middle: 0.0)

    /// The render suites' stand-in for the glass under a control (`CardGlassStandIn`), as white veils over each look: a
    /// lens a little lighter than the glass around it, and its rim.
    static func standInLift(_ role: Role, _ scheme: ColorScheme) -> Double {
        switch (role, scheme) {
        case (.clear, .light): 0.16
        case (.clear, _): 0.035
        case (_, .light): 0.5
        default: 0.1
        }
    }
}

extension View {
    /// The ground of a card control's label, in `shape`. Black and Smoke: `fill`, as they drew it. Glass: `glassFill` (the
    /// key's face, or a veil for a hover or a picked option) on the glass, or nothing, so the glass shows; a key's face
    /// takes the gloss.
    func cardControlGround<S: InsettableShape>(_ shape: S, fill: Color, glassFill: Color?, key: Bool = false) -> some View {
        modifier(CardControlGround(shape: shape, fill: fill, glassFill: glassFill, key: key))
    }

    /// The system's interactive glass under a card control (a Button, from outside), in `shape`; nothing on Black and
    /// Smoke. `interactive`: false for a control that is off (the send key with an empty field).
    func cardControlGlass<S: InsettableShape>(_ shape: S, role: CardGlass.Role, tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(CardControlGlass(shape: shape, role: role, tint: tint, interactive: interactive))
    }

    /// Card controls of one glass (a question's options) in one glass container on Glass's live glass; as they are
    /// anywhere else.
    func cardGlassGroup() -> some View { modifier(CardGlassGroup()) }
}

/// `cardControlGround(_:fill:glassFill:key:)`.
struct CardControlGround<S: InsettableShape>: ViewModifier {
    var shape: S
    var fill: Color
    var glassFill: Color?
    var key: Bool
    @Environment(\.juiceTheme) private var theme

    func body(content: Content) -> some View {
        if theme == .glass {
            content.background {
                if let glassFill {
                    shape.fill(glassFill)
                        .overlay {
                            if key {
                                shape.strokeBorder(LinearGradient(colors: [.white.opacity(CardGlass.gloss.top), .white.opacity(CardGlass.gloss.middle)],
                                                                  startPoint: .top, endPoint: .center), lineWidth: 1)
                            }
                        }
                }
            }
        } else {
            content.background(fill, in: shape)
        }
    }
}

/// `cardControlGlass(_:role:tint:interactive:)`. Live: the system's glass; renders: the stand-in (`CardGlassStandIn`).
/// Reduce Motion: the glass holds still under a press.
struct CardControlGlass<S: InsettableShape>: ViewModifier {
    var shape: S
    var role: CardGlass.Role
    var tint: Color?
    var interactive: Bool
    @Environment(\.juiceTheme) private var theme
    @Environment(\.glassRendering) private var rendering
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if theme == .glass {
            switch rendering {
            case .live:
                content.glassEffect(CardGlass.glass(role, tint: tint, interactive: interactive && !reduceMotion), in: shape)
            case .standIn:
                content.background { CardGlassStandIn(role: role, shape: shape) }
            }
        } else {
            content
        }
    }
}

/// `cardGlassGroup()`.
struct CardGlassGroup: ViewModifier {
    @Environment(\.juiceTheme) private var theme
    @Environment(\.glassRendering) private var rendering

    func body(content: Content) -> some View {
        if theme == .glass, rendering == .live {
            GlassEffectContainer(spacing: CardGlass.containerSpacing) { content }
        } else {
            content
        }
    }
}

/// The render suites' stand-in for a control's glass (renders only, never live, P565): a white lens a little lighter
/// than the glass around it (`CardGlass.standInLift`) and its rim, lit from above, white on the dark look and the ink at
/// half strength on the light (`GlassAdapted.rimColour`); the key's face covers it.
struct CardGlassStandIn<S: InsettableShape>: View {
    var role: CardGlass.Role
    var shape: S
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let rim = role == .clear ? 0.7 : 1
        shape.fill(Color.white.opacity(CardGlass.standInLift(role, scheme)))
            .overlay {
                shape.strokeBorder(LinearGradient(colors: [GlassAdapted.rimColour.opacity(0.5 * rim), GlassAdapted.rimColour.opacity(0.14 * rim)],
                                                  startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
