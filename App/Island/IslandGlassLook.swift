import AppKit
import Observation
import QuartzCore
import SwiftUI

// State tint and the pointer-lit rim on the island (`StateTint`, `RimLight`, P630 to P639), in both outline engines:
// - Glass's tint is a veil inside its glass, under the content (`IslandTintVeil`): the outline cuts it as it cuts the
//   glass, SwiftUI's clip or Core Animation's mask, so both engines draw it from the one view.
// - Black's tint is a line of the state's colour just inside the outline, over the #000 (`IslandTintRim` on SwiftUI's
//   outline, riding the surface's own two curves as Glass's rim does; `IslandStateEdgeLayers` on Core Animation's, on
//   the plan's keyframes, inside a mask of the outline of its own).
// - The rim's light (`IslandRimLight`, set from the island's own tracking area): a soft light in the rim's colour where
//   the pointer is, inside the rim's own line (`IslandRimLightView` in `IslandGlassRim`; `GlassSurfaceNSView.lightLayer`).
// Each is always inside the outline; each comes and goes as a cross-fade, which Reduce Motion keeps; none ticks at rest.

// MARK: The rim's light

/// Where Glass's rim catches the light, in the canvas's space (y down from its top): written by the panel from its
/// tracking area's events only while the pointer is over the island in Glass (`IslandPanelController.lightRim`), read by
/// the rim's light alone (E5). nil: no light.
@MainActor
@Observable
final class IslandRimLight {
    struct Spot: Equatable, Sendable {
        var centre: CGPoint
        var radius: CGFloat
    }

    private(set) var spot: Spot?

    /// A new place (or none); the same one writes nothing, so nothing redraws.
    func set(_ spot: Spot?) {
        if self.spot != spot { self.spot = spot }
    }
}

/// The rim's light on SwiftUI's outline: a radial light in the rim's colour at the spot, inside `IslandGlassRim`'s line
/// (its clip keeps it there). It follows the spot eased (snapping under Reduce Motion), and comes and goes as a fade.
struct IslandRimLightView: View {
    let light: IslandRimLight
    var colour: Color
    /// The rim's own light (`RimLight.profile`): the light follows it, nothing at the screen's edge.
    var edge: GlassEdge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let profile = RimLight.profile(edge)
        spot
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.white.opacity(profile.top), .white], startPoint: .top, endPoint: .bottom)
                        .frame(height: profile.reach)
                    Color.white
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var spot: some View {
        ZStack(alignment: .topLeading) {
            if let spot = light.spot {
                RadialGradient(stops: RimLight.stops.map { Gradient.Stop(color: colour.opacity($0.alpha), location: $0.location) },
                               center: .center, startRadius: 0, endRadius: spot.radius)
                    .frame(width: spot.radius * 2, height: spot.radius * 2)
                    .position(spot.centre)
                    .transition(.opacity.animation(.easeInOut(duration: RimLight.fade)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .easeOut(duration: RimLight.follow), value: light.spot)
    }
}

// MARK: Glass: the tint's veil

/// Glass's state tint: the lead state's veil (`StateTint.veil`) over the whole canvas, inside the glass and under the
/// content, which the outline cuts. One fill per state, each fading in and out on its own (a finish's green slowly), so
/// a change of state cross-fades. Drawn only while State tint is on.
struct IslandTintVeil: View {
    let ui: IslandUIState
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.needsYouColour) private var needsYou

    var body: some View {
        let tint = StateTint(lead: ui.pill.lead)
        ZStack {
            ForEach(StateTint.allCases, id: \.self) { state in
                let on = state == tint
                Rectangle().fill(state.veil(contrast, needsYou: needsYou))
                    .opacity(on ? 1 : 0)
                    .animation(on ? .easeOut(duration: StateTint.fadeIn) : .easeInOut(duration: state.fadeOut()), value: on)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: Black: the tint's edge

/// Black's state tint on SwiftUI's outline: the lead state's colour as a line just inside the outline (`IslandTintRim`),
/// over the #000, which it leaves as it is everywhere else. Drawn only while State tint is on.
struct IslandStateEdge: View {
    let ui: IslandUIState

    var body: some View {
        IslandTintRim(surface: ui.live.surface, continuous: ui.tuning.continuousCorners, edge: StateTint.blackEdge,
                      tint: StateTint(lead: ui.pill.lead), liquid: ui.tuning.liquid ? ui.liquid : nil)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A rim in the tint's colour (`IslandGlassRim`'s line, its light from below: `edge`), on the outline's two curves, so it is
/// the clip's edge in every frame. It is always there while it may show, so a tint that comes mid-motion is already on
/// the edge where the edge is; each state's colour fades in and out on its own.
struct IslandTintRim: View {
    let surface: SurfaceBox
    var continuous: Bool
    var edge: GlassEdge
    var tint: StateTint?
    /// Motion: Liquid: the line on the union (`IslandGlassRim.liquid`), the belly, the drop and the bud's.
    var liquid: LiquidBox? = nil
    @Environment(\.needsYouColour) private var needsYou

    var body: some View {
        let geometry = surface.value
        let line = ZStack {
            ForEach(StateTint.allCases, id: \.self) { state in
                let on = state == tint
                Rectangle().fill(state.colour(needsYou))
                    .opacity(on ? 1 : 0)
                    .animation(on ? .easeOut(duration: StateTint.fadeIn) : .easeInOut(duration: state.fadeOut()), value: on)
            }
        }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.white.opacity(edge.top), .white.opacity(edge.bottom)], startPoint: .top, endPoint: .bottom)
                    .frame(height: edge.reach ?? 0)
                Color.white.opacity(edge.bottom)
            }
        }
        let clip = SurfaceRimClip(geometry: geometry, continuous: continuous, width: edge.width, height: surface.heightMotion.animation)
        // Liquid off: today's line exactly.
        if let liquid {
            line.animation(liquid.clock) {
                $0.modifier(LiquidClock(pulse: Double(liquid.pulse), frame: liquid.frame, clip: clip, width: surface.widthMotion.animation))
            }
        } else {
            line.animation(surface.widthMotion.animation) { $0.modifier(clip) }
        }
    }
}

// MARK: Black: the tint's edge on Core Animation's outline

/// Black's state tint where Core Animation draws the outline: in the black's own layer-hosting view, over its fill, a
/// host masked by the outline (`mask`, filled) holding the light (`light`: the tint's colour lit from below, as
/// `StateTint.blackEdge`) masked by the outline stroked twice the edge's width (`stroke`), so only its inner half shows.
/// `mask` and `stroke` take the plan's paths and keyframes with the black's fill (`IslandSurfaceLayers.edge`), in the
/// fill's own orientation. It fails closed: born masked by an empty path, so it draws nothing until a path is set, and
/// `ensure` puts a lost mask back. A new tint cross-fades the light's colours on the render server's clock; at none, once
/// faded, the host hides. It holds no timer and asks for no frames: nothing ticks at rest.
@MainActor
final class IslandStateEdgeLayers {
    let host = CALayer()
    let mask = CAShapeLayer()
    let light = CAGradientLayer()
    let stroke = CAShapeLayer()
    let edge: GlassEdge
    /// The tint it shows or is fading in (nil: none, or fading out).
    private(set) var tint: StateTint?
    /// Settings › Island › Needs you colour, which a needs-you tint shows (`setNeedsYou`).
    private(set) var needsYou = NeedsYouColour.pink
    /// Fades begun; a fade's end that is not the last does nothing.
    private var fades = 0

    /// The layers that carry the outline.
    var pathLayers: [CAShapeLayer] { [mask, stroke] }

    init(edge: GlassEdge = StateTint.blackEdge) {
        self.edge = edge
        host.name = "island.outline.tintEdge"
        mask.fillColor = CGColor(gray: 0, alpha: 1)
        stroke.fillColor = nil
        stroke.strokeColor = CGColor(gray: 1, alpha: 1)
        stroke.lineWidth = edge.width * 2
        host.mask = mask
        light.mask = stroke
        host.addSublayer(light)
        light.colors = Self.colours(nil, edge: edge, needsYou: needsYou)
        host.isHidden = true
        for layer in [host, mask, light, stroke] as [CALayer] { layer.actions = IslandSurfaceLayers.still }
        setPath(nil)
    }

    /// The light's colours for `tint`: its colour at the edge's `top` and `bottom` strengths (clear for none, in the
    /// colour it fades from).
    static func colours(_ tint: StateTint?, fading from: StateTint? = nil, edge: GlassEdge, needsYou: NeedsYouColour) -> [CGColor] {
        guard let colour = (tint ?? from).map({ GlassContrast.components($0.colour(needsYou)) }) else {
            return Array(repeating: CGColor(gray: 0, alpha: 0), count: 3)
        }
        let k = tint == nil ? 0.0 : 1.0
        func c(_ a: Double) -> CGColor { CGColor(srgbRed: colour.r, green: colour.g, blue: colour.b, alpha: a * k) }
        return [c(edge.top), c(edge.bottom), c(edge.bottom)]
    }

    /// Frames it at the canvas's size, its light's fall from the edge's top over its reach, in `yDown`'s orientation.
    func layout(canvas: CGSize, yDown: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = CGRect(origin: .zero, size: canvas)
        for layer in [host, mask, light, stroke] as [CALayer] { layer.frame = bounds }
        light.startPoint = CGPoint(x: 0.5, y: yDown ? 0 : 1)
        light.endPoint = CGPoint(x: 0.5, y: yDown ? 1 : 0)
        let reach = edge.reach.map { canvas.height > 0 ? min(1, $0 / canvas.height) : 1 } ?? 1
        light.locations = [0, NSNumber(value: Double(reach)), 1]
        CATransaction.commit()
    }

    /// The outline (nil: nothing shows), in the fill's orientation.
    func setPath(_ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in pathLayers { layer.path = path ?? CGMutablePath() }
        CATransaction.commit()
    }

    /// Shows `new` (nil: none), cross-fading the light's colours from where they are on the render server: in over
    /// `StateTint.fadeIn`, out over the old tint's `fadeOut()`. `animated` false: at once (the first show, a rebuild).
    func show(_ new: StateTint?, animated: Bool = true) {
        guard new != tint else { return }
        let old = tint
        tint = new
        fades += 1
        let fade = fades
        let to = Self.colours(new, fading: old, edge: edge, needsYou: needsYou)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if new != nil { host.isHidden = false }
        let from = light.presentation()?.colors ?? light.colors
        light.colors = to
        if animated, !host.isHidden {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = from
            animation.toValue = to
            animation.duration = new == nil ? (old?.fadeOut() ?? 0.45) : StateTint.fadeIn
            animation.timingFunction = CAMediaTimingFunction(name: new == nil ? .easeInEaseOut : .easeOut)
            light.add(animation, forKey: "tint")
            // Once it has played, one wake takes the ended animation off (Core Animation would leave it on until a commit,
            // P241) and, at none, hides the host: nothing of it is composited at rest. One wake a fade (50 ms more while a
            // late commit keeps it playing), never a tick.
            settle(fade, after: animation.duration + 0.05)
        } else if new == nil {
            hideNow()
        }
        CATransaction.commit()
    }

    /// A new needs-you colour, at once: the light takes it while a needs-you tint shows or fades in. A fade-out already
    /// under way (`tint` nil) ends in the colour it began in; it is gone within 0.45 s.
    func setNeedsYou(_ new: NeedsYouColour) {
        guard new != needsYou else { return }
        needsYou = new
        guard tint == .needsYou else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.removeAnimation(forKey: "tint")
        light.colors = Self.colours(tint, edge: edge, needsYou: new)
        CATransaction.commit()
    }

    private func settle(_ fade: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fades == fade else { return }
                guard !Self.sweep([self.light]) else { return self.settle(fade, after: 0.05) }
                if self.tint == nil { self.hideNow() }
            }
        }
    }

    private func hideNow() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.removeAnimation(forKey: "tint")
        host.isHidden = true
        CATransaction.commit()
    }

    /// Takes the ended animations off `layers` (their values are already their own): Core Animation leaves an ended
    /// animation on its layer until its next commit, and at rest there is none (P241). True while one still plays (its
    /// commit came late, on a busy main thread): the caller looks again shortly.
    @discardableResult
    static func sweep(_ layers: [CALayer]) -> Bool {
        var playing = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in layers {
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key) else { continue }
                if layer.convertTime(CACurrentMediaTime(), from: nil) >= animation.beginTime + animation.duration {
                    layer.removeAnimation(forKey: key)
                } else {
                    playing = true
                }
            }
        }
        CATransaction.commit()
        return playing
    }

    /// The masks are where they belong.
    var isSound: Bool { host.mask === mask && light.mask === stroke && light.superlayer === host }

    /// Puts the masks back where they belong; false when one had to be.
    @discardableResult
    func ensure() -> Bool {
        guard !isSound else { return true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        host.mask = mask
        light.mask = stroke
        if light.superlayer !== host { host.addSublayer(light) }
        CATransaction.commit()
        return false
    }

    /// Draws at the display's scale.
    func setContentsScale(_ scale: CGFloat) {
        for layer in [host, mask, light, stroke] as [CALayer] where layer.contentsScale != scale { layer.contentsScale = scale }
    }
}
