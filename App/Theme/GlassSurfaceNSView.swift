import AppKit
import QuartzCore
import SwiftUI

/// Theme Smoke where AppKit hosts the surface, and where Core Animation moves its outline (`IslandSurfaceLayers`): the
/// system's glass (`NSGlassEffectView`, or an `NSVisualEffectView` when asked), a dark floor and the rim, the same look
/// as `GlassSurface`, cut to a path the owner of the view sets or animates. Theme Glass keeps only the rim here
/// (`Backdrop.rimOnly`): its glass is the content's own (`inGlass`), under this view. Theme Solid is the window material
/// (`Backdrop.window`) with no floor, its hairline for a rim, in the window's appearance (P770, P771).
///
/// It fails closed (P523): the view is born masked by an empty path, so until a path is set it draws nothing, and the
/// mask is its own layer's, so no subview can draw past it; `ensure()` puts a lost mask back (as `IslandCanvas.ensure`
/// does for the outline's), and `isSound` says whether it had to. Every path layer (`pathLayers`) takes the same path
/// and the same animation (`setPath`, `addPathAnimation`), so the glass, its floor and its rim move as one with the
/// outline. It holds no timer and asks for no frames: nothing ticks at rest.
@MainActor
final class GlassSurfaceNSView: NSView {
    /// What is under the floor.
    enum Backdrop: Equatable, Sendable {
        /// `NSGlassEffectView`, regular.
        case glass
        /// `NSVisualEffectView`, the HUD material blended behind the window: the fallback where the glass view will not do.
        case visualEffect
        /// Reduce Transparency: no glass, `GlassStyle.solid`.
        case solid
        /// Glass: no glass and no floor of its own (the content under it sits in the system's glass), the rim alone.
        case rimOnly
        /// Solid: `NSVisualEffectView`, the window background material (`SolidLook.material`) blended behind the window
        /// and always active, in the appearance the view inherits (the Appearance's), so the system tints it with the
        /// wallpaper, or not, as it tints its own windows; no floor; the hairline for a rim (P770).
        case window

        /// Glass, or the solid under Reduce Transparency.
        static func preferred(reduceTransparency: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency) -> Backdrop {
            reduceTransparency ? .solid : .glass
        }
    }

    let backdrop: Backdrop
    let style: GlassStyle
    /// The system view behind the floor; nil for `.solid`.
    private(set) var effectView: NSView?
    /// The view's own mask: nothing it holds draws outside it.
    let maskLayer = CAShapeLayer()
    /// The floor (or, for `.solid`, the solid itself).
    let floorLayer = CAShapeLayer()
    /// The rim's light, shown through `rimStroke`.
    let rimLayer = CAGradientLayer()
    /// The outline stroked twice the rim's width; the mask keeps its inner half.
    let rimStroke = CAShapeLayer()
    /// Over the rim and inside the mask, as large as the view: the owner's own marks on its glass (the island's notch
    /// plate, `NotchPlate`), which the mask cuts to the outline as it does the glass.
    let marksLayer = CALayer()
    /// Glass (`rimOnly`): where the rim catches the light, near the pointer (`RimLight`): a radial light in the rim's
    /// colour, a sublayer of the rim's light, so the rim's own mask (`rimStroke`) keeps it to the line. Hidden until lit.
    let lightLayer = CAGradientLayer()
    /// The light's host, as large as the view, inside the rim's light: its mask is the rim's own profile
    /// (`RimLight.profile`), so the light, lit from below as the rim is, never lights the screen's edge.
    let lightHost = CALayer()
    private let lightProfile = CAGradientLayer()
    private let overlay = NSView()
    private var edge = GlassEdge(width: 1, top: 0, bottom: 0)

    /// Every layer that carries the outline.
    var pathLayers: [CAShapeLayer] { [maskLayer, floorLayer, rimStroke] }

    init(style: GlassStyle = .island, backdrop: Backdrop = .preferred(),
         increaseContrast: Bool = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast) {
        self.style = style
        self.backdrop = backdrop
        super.init(frame: .zero)
        wantsLayer = true
        layer?.mask = maskLayer
        // Smoke's glass is dark whatever the system's appearance; Glass's rim takes the one its owner sets, the look the
        // content's glass under it has (`IslandCanvas`, P568), or the window's until then (`paintRim`); Solid's material
        // and hairline take the window's, the Appearance's.
        if backdrop != .rimOnly, backdrop != .window { appearance = NSAppearance(named: .darkAqua) }
        switch backdrop {
        case .glass:
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            effectView = glass
        case .visualEffect:
            let effect = NSVisualEffectView()
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effectView = effect
        case .window:
            let effect = NSVisualEffectView()
            effect.material = SolidLook.material
            effect.blendingMode = .behindWindow
            effect.state = .active
            effectView = effect
        case .solid, .rimOnly:
            effectView = nil
        }
        if let effectView { addSubview(effectView) }
        // The floor and the rim over the glass: a layer-hosting view of their own, above it.
        overlay.layer = CALayer()
        overlay.wantsLayer = true
        addSubview(overlay)
        let contrast: ColorSchemeContrast = increaseContrast ? .increased : .standard
        switch backdrop {
        case .solid: floorLayer.fillColor = NSColor(style.solid).cgColor
        case .rimOnly, .window: floorLayer.fillColor = nil
        default: floorLayer.fillColor = CGColor(gray: 0, alpha: style.floor(contrast))
        }
        let edge = backdrop == .window ? SolidLook.islandEdge : style.edge(contrast)
        self.edge = edge
        paintRim()
        // Unit space, y up (the overlay's layer is not flipped): its top first.
        rimLayer.startPoint = CGPoint(x: 0.5, y: 1)
        rimLayer.endPoint = CGPoint(x: 0.5, y: 0)
        rimStroke.fillColor = nil
        rimStroke.strokeColor = CGColor(gray: 1, alpha: 1)
        rimStroke.lineWidth = edge.width * 2
        rimLayer.mask = rimStroke
        overlay.layer?.addSublayer(floorLayer)
        overlay.layer?.addSublayer(rimLayer)
        overlay.layer?.addSublayer(marksLayer)
        for layer in [maskLayer, floorLayer, rimStroke, rimLayer, marksLayer] as [CALayer] { layer.actions = IslandSurfaceLayers.still }
        lightLayer.type = .radial
        lightLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        lightLayer.endPoint = CGPoint(x: 1, y: 1)
        lightLayer.locations = RimLight.stops.map { NSNumber(value: $0.location) }
        lightLayer.opacity = 0
        lightLayer.isHidden = true
        lightProfile.colors = [CGColor(gray: 1, alpha: RimLight.profile(edge).top), CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1)]
        lightProfile.startPoint = CGPoint(x: 0.5, y: 1)
        lightProfile.endPoint = CGPoint(x: 0.5, y: 0)
        lightHost.mask = lightProfile
        lightHost.addSublayer(lightLayer)
        for layer in [lightHost, lightProfile] { layer.actions = IslandSurfaceLayers.still }
        if backdrop == .rimOnly { rimLayer.addSublayer(lightHost) }
        maskLayer.fillColor = CGColor(gray: 0, alpha: 1)
        setPath(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The rim's light: white; Glass's (`rimOnly`) white where the view's appearance is dark and the ink at half strength
    /// where it is light (`GlassAdapted.rimColour`), as the island's rim on SwiftUI's outline; Solid's (`window`) its
    /// hairline in the look's twin (`SolidLook.edgeColour`).
    private func paintRim() {
        var light = (r: CGFloat(1), g: CGFloat(1), b: CGFloat(1), a: CGFloat(1))
        let dark = effectiveAppearance.colorScheme == .dark
        if backdrop == .rimOnly, !dark {
            light = (0x1D / 255, 0x1D / 255, 0x1F / 255, 0.5)
        } else if backdrop == .window {
            light = dark ? (1, 1, 1, 0.18) : (0, 0, 0, CGFloat(SolidLook.lightEdge))
        }
        let tinted = backdrop == .rimOnly || backdrop == .window
        func colour(_ alpha: Double) -> CGColor {
            tinted ? CGColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: light.a * alpha) : CGColor(gray: 1, alpha: alpha)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rimLayer.colors = [colour(edge.top), colour(edge.bottom), colour(edge.bottom)]
        lightLayer.colors = RimLight.stops.map { CGColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: light.a * $0.alpha) }
        CATransaction.commit()
    }

    /// Glass: the rim's light at `spot` (the canvas's space, y down; nil: none). It follows the spot on the render server,
    /// eased over `RimLight.follow` (at once under Reduce Motion), and fades in and out over `RimLight.fade`: animations
    /// Core Animation plays and ends by itself, so nothing ticks, moving or at rest.
    func setRimLight(_ spot: IslandRimLight.Spot?, reduceMotion: Bool = false) {
        guard backdrop == .rimOnly else { return }
        defer { sweepLight() }
        let wasLit = !lightLayer.isHidden && lightLayer.opacity > 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let spot {
            let frame = CGRect(x: spot.centre.x - spot.radius, y: bounds.height - spot.centre.y - spot.radius,
                               width: spot.radius * 2, height: spot.radius * 2)
            // From where it is on screen (its model, where nothing has been drawn yet).
            let from = lightLayer.presentation() ?? lightLayer
            lightLayer.isHidden = false
            let position = CGPoint(x: frame.midX, y: frame.midY)
            if wasLit, !reduceMotion {
                for (key, old, new) in [("position", NSValue(point: from.position), NSValue(point: position)),
                                        ("bounds", NSValue(rect: from.bounds), NSValue(rect: CGRect(origin: .zero, size: frame.size)))] {
                    let animation = CABasicAnimation(keyPath: key)
                    animation.fromValue = old
                    animation.toValue = new
                    animation.duration = RimLight.follow
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    lightLayer.add(animation, forKey: "follow." + key)
                }
            }
            lightLayer.bounds = CGRect(origin: .zero, size: frame.size)
            lightLayer.position = position
            if lightLayer.opacity != 1 { fadeLight(to: 1) }
        } else if wasLit {
            fadeLight(to: 0)
        }
        CATransaction.commit()
    }

    /// Light moves begun; only the last one's wake sweeps.
    private var lightMoves = 0

    /// Once the last move and fade have played, one wake takes their ended animations off (P241) and hides a light
    /// faded out: nothing of it is composited at rest. One wake a move (50 ms more while a late commit keeps one
    /// playing), never a tick.
    private func sweepLight() {
        lightMoves += 1
        settleLight(lightMoves, after: max(RimLight.follow, RimLight.fade) + 0.05)
    }

    private func settleLight(_ move: Int, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.lightMoves == move else { return }
                guard !IslandStateEdgeLayers.sweep([self.lightLayer]) else { return self.settleLight(move, after: 0.05) }
                if self.lightLayer.opacity == 0, self.lightLayer.animationKeys() == nil {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.lightLayer.isHidden = true
                    CATransaction.commit()
                }
            }
        }
    }

    private func fadeLight(to opacity: Float) {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = lightLayer.presentation()?.opacity ?? lightLayer.opacity
        animation.toValue = opacity
        animation.duration = RimLight.fade
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        lightLayer.opacity = opacity
        lightLayer.add(animation, forKey: "fade")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if backdrop == .rimOnly || backdrop == .window { paintRim() }
    }

    /// Decoration only: every click goes to what is under or over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectView?.frame = bounds
        overlay.frame = bounds
        for layer in [maskLayer, floorLayer, rimStroke, rimLayer, marksLayer, lightHost, lightProfile] as [CALayer] { layer.frame = bounds }
        // The rim's light: `top` to `bottom` across the height, or over its `reach` from the top (`GlassEdge`).
        let reach = edge.reach.map { bounds.height > 0 ? min(1, $0 / bounds.height) : 1 } ?? 1
        rimLayer.locations = [0, NSNumber(value: Double(reach)), 1]
        lightProfile.locations = rimLayer.locations
        CATransaction.commit()
    }

    /// The outline, in this view's layer coordinates (y up from its bottom left, as `bounds`). nil: nothing shows.
    func setPath(_ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in pathLayers { layer.path = path ?? CGMutablePath() }
        CATransaction.commit()
    }

    /// Draws its layers at the display's scale: layers the view made itself (the path layers, the rim, the marks) take
    /// none from AppKit, and a shape layer at 1× on a 2× display draws a soft, stepped edge.
    func setContentsScale(_ scale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var layers: [CALayer] = [maskLayer, floorLayer, rimStroke, rimLayer, marksLayer, lightLayer, lightHost, lightProfile]
        layers += marksLayer.sublayers ?? []
        layers += (marksLayer.sublayers ?? []).compactMap(\.mask)
        for layer in layers where layer.contentsScale != scale { layer.contentsScale = scale }
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let scale = window?.backingScaleFactor { setContentsScale(scale) }
    }

    /// The same animation of `path` on every path layer, so the glass, the floor and the rim move as one.
    func addPathAnimation(_ animation: CAAnimation, forKey key: String) {
        for layer in pathLayers {
            guard let copy = animation.copy() as? CAAnimation else { continue }
            layer.add(copy, forKey: key)
        }
    }

    func removePathAnimations(forKey key: String) {
        for layer in pathLayers { layer.removeAnimation(forKey: key) }
    }

    /// The mask is where it belongs.
    var isSound: Bool { layer?.mask === maskLayer && rimLayer.mask === rimStroke }

    /// Whether the rim's light shows (Glass, the pointer over the island).
    var isLit: Bool { !lightLayer.isHidden && lightLayer.opacity > 0 }

    /// Puts the masks back where they belong; false when one had to be (or could not be).
    @discardableResult
    func ensure() -> Bool {
        guard !isSound else { return true }
        wantsLayer = true
        layer?.mask = maskLayer
        rimLayer.mask = rimStroke
        return false
    }
}
