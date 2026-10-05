import AppKit
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The desktop panel and its hover chip in Themes Smoke and Glass (P530 to P535, P560): Black exactly as it was, the glass and its
/// shadow each on their side of the outline, the batteries' cuts showing the glass and never punching through, the
/// chip following the panel's theme, and every ink legible on the glass over any wallpaper.
@MainActor
@Suite(.serialized)
struct PanelGlassTests {
    typealias C = GlassContrast

    static let red = Color(red: 1, green: 0, blue: 0)
    static let blue = Color(red: 0, green: 0, blue: 1)

    // MARK: Black

    /// Black is today's panel and chip, pixel for pixel: `PanelSurface` in Black is the fill, the edge and the shadow they
    /// drew, and the chip's window draws the same chip whatever the system's appearance. Once, in a full `swift test` run
    /// under heavy load, a render here differed from its twin; each comparison therefore draws today's view before and
    /// after the new one and asks the new one to match either, and says how far apart the three were if it matches neither.
    @Test func blackIsTodaysPanelAndChip() throws {
        func same<A: View, B: View>(_ today: A, _ new: B, size: CGSize, _ name: String) throws {
            let first = try ThemeTests.pixels(today, size: size)
            let drawn = try ThemeTests.pixels(new, size: size)
            let second = try ThemeTests.pixels(today, size: size)
            #expect(drawn.data == first.data || drawn.data == second.data,
                    "\(name): \(Self.difference(first, drawn)) and \(Self.difference(second, drawn)); today's twice: \(Self.difference(first, second))")
        }
        for radius in [Theme.Panel.radius, 10] {
            let shape = RoundedRectangle(cornerRadius: radius)
            let content = Capsule().fill(Theme.ink).frame(width: 120, height: 14).frame(width: 200, height: 60)
            let today = content
                .background { shape.fill(Theme.surface) }
                .overlay { shape.strokeBorder(Theme.edge, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.14), radius: 8, y: 2)
                .padding(24)
            try same(today, content.modifier(PanelSurface(radius: radius)).padding(24), size: CGSize(width: 248, height: 108), "radius \(radius)")
        }
        let text = "Claude · 57% · resets in 2h 5m"
        try same(PanelHoverLabelView(text: text).fixedSize().environment(\.colorScheme, .light),
                 PanelHoverChip(text: text, theme: .black).fixedSize().environment(\.colorScheme, .light), size: CGSize(width: 320, height: 60), "chip")
    }

    // MARK: The glass and its shadow

    /// On glass, nothing but the shadow lies past the panel's outline (the glass, its floor and its rim are clipped to
    /// it), and the shadow is Black's: black, no darker than 0.14, on every side.
    @Test func onGlassOnlyTheShadowLiesPastTheOutline() throws {
        let env = AppEnvironment.demo()
        let content = PanelGlassRenders.statesContent(env)
        let panel = try #require(content.size)
        let view = DesktopPanelBody(content: content, size: panel).padding(PanelGeometry.margin).environment(\.juiceTheme, .smoke)
        let window = PanelGeometry.windowSize(for: panel)
        let pixels = try ThemeTests.pixels(view, size: window)
        let path = RoundedRectangle(cornerRadius: Theme.Panel.radius)
            .path(in: CGRect(origin: CGPoint(x: PanelGeometry.margin, y: PanelGeometry.margin), size: panel))
        var shadow = 0, stray = 0, darkest = 0.0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                let near = [-1.0, 0, 1].contains { dx in [-1.0, 0, 1].contains { dy in path.contains(CGPoint(x: p.x + dx, y: p.y + dy)) } }
                guard !near else { continue }
                let px = pixels.rgba(x, y)
                guard px.a > 0 else { continue }
                if max(px.r, px.g, px.b) > 0.02 || px.a > 0.15 { stray += 1 } else { shadow += 1 }
                darkest = max(darkest, px.a)
            }
        }
        #expect(stray == 0, "\(stray) pixels past the outline that are not the shadow")
        #expect(shadow > 1000 && darkest > 0.02, "the shadow is there: \(shadow) pixels, darkest \(darkest)")
    }

    /// The shadow's own layer draws nothing inside the outline: behind the live glass the window is empty, so the glass
    /// blurs the desktop and nothing of the app (P530).
    @Test func theGlassShadowLeavesTheInsideEmpty() throws {
        let panel = Theme.Panel.size, margin = PanelGeometry.margin
        let view = PanelGlassShadow(shape: RoundedRectangle(cornerRadius: Theme.Panel.radius))
            .frame(width: panel.width, height: panel.height)
            .padding(margin)
        let pixels = try ThemeTests.pixels(view, size: PanelGeometry.windowSize(for: panel))
        let path = RoundedRectangle(cornerRadius: Theme.Panel.radius).path(in: CGRect(x: margin, y: margin, width: panel.width, height: panel.height))
        var inside = 0, outside = 0
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.rgba(x, y).a > 0 {
                let p = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                let deep = [-0.5, 0, 0.5].allSatisfy { dx in [-0.5, 0, 0.5].allSatisfy { dy in path.contains(CGPoint(x: p.x + dx, y: p.y + dy)) } }
                if deep { inside += 1 } else { outside += 1 }
            }
        }
        #expect(inside == 0, "\(inside) pixels behind the glass")
        #expect(outside > 1000)
    }

    /// Glass draws the glass: over the busy photo the panel's surface shows the photo through its floor, where Black is
    /// the pure black.
    @Test func thePanelIsGlassInGlassAndBlackInBlack() throws {
        let env = AppEnvironment.demo()
        func interior(_ theme: JuiceTheme) throws -> [(r: Double, g: Double, b: Double, a: Double)] {
            let view = PanelGlassRenders.staged(DesktopPanelBody(content: PanelGlassRenders.statesContent(env), size: Theme.Panel.size)
                .padding(PanelGeometry.margin), .busy, theme, size: PanelGlassRenders.window)
            let pixels = try ThemeTests.pixels(view.environment(env), size: PanelGlassRenders.window)
            // The band between the divider and the money, and the panel's right edge strip.
            return [(40.0, 119.0), (200, 119), (360, 119), (378, 60), (378, 180)].map { pixels.rgba(Int(2 * $0.0), Int(2 * $0.1)) }
        }
        for p in try interior(.black) { #expect(p.r < 0.005 && p.g < 0.005 && p.b < 0.005, "\(p)") }
        let glass = try interior(.smoke)
        #expect(glass.contains { max($0.r, $0.g, $0.b) > 0.02 }, "\(glass)")
        // No brighter than the floor over white (a saturated colour's one channel may be; its luminance is not).
        let worst = C.worstSurface(floor: GlassStyle.panel.floor)
        #expect(glass.allSatisfy { C.luminance(r: $0.r, g: $0.g, b: $0.b) <= worst + 0.002 }, "\(glass)")
        let spread = glass.map { $0.r - $0.b }
        #expect((spread.max() ?? 0) - (spread.min() ?? 0) > 0.01, "the photo's colours come through: \(glass)")
    }

    // MARK: Cuts

    /// A battery's cuts (the digits over the fill, the stale slash's band) show what is behind the battery on glass and
    /// are the black on Black; they never punch through past the battery: over a blue surface on a red wallpaper, glass
    /// shows the blue, never the red, and no pixel goes transparent. Both batteries (Juice's and the window's, with and
    /// without Next), drawn both ways: `ImageRenderer`, and a hosting view's layers (where a compositing group let the
    /// cut through, P531).
    @Test func cutsShowTheSurfaceBehindTheBatteryAndNeverPunchThrough() throws {
        // 100: every digit on the fill; 57: one on the fill, one across the edge on the track (a cut halo); 45: one across
        // the edge on the fill; 8: no digit on the fill, so no cut; stale: the slash's band.
        let states: [AccountState] = [.available(percentLeft: 100, isLow: false), .available(percentLeft: 57, isLow: false),
                                      .available(percentLeft: 45, isLow: false), .available(percentLeft: 8, isLow: true),
                                      .stale(lastPercentLeft: 40)]
        let size = CGSize(width: 69, height: 42)
        for theme in JuiceTheme.allCases {
            for window in [false, true] {
                for state in states {
                    for next in [false, true] {
                        let battery = BatteryModel(id: "b", alias: "b", state: state, isNext: next, hoverLabel: "b")
                        let cell: AnyView = window ? AnyView(UsageBatteryView(battery: battery, now: DemoClock.now, theme: theme))
                            : AnyView(BatteryView(battery: battery, now: DemoClock.now, theme: theme))
                        let view = cell
                            .padding(8)
                            .background(Self.blue)
                            .padding(4)
                            .background(Self.red)
                            .environment(\.juiceTheme, theme)
                        let name = "\(theme) \(window ? "window" : "panel") \(state)\(next ? " next" : "")"
                        let drawn = try ThemeTests.pixels(view, size: size)
                        let hosted = try RenderHarness.hostedBitmap(view, "cuts", size: size)
                        for (path, rgba) in [("renderer", { (x: Int, y: Int) in drawn.rgba(x, y) }),
                                             ("layers", { (x: Int, y: Int) in Self.rgba(hosted, x, y) })] {
                            var holes = 0, blue = 0, red = 0, ink = 0
                            for y in 0..<Int(2 * size.height) {
                                for x in 0..<Int(2 * size.width) {
                                    let p = rgba(x, y)
                                    if p.a < 0.99 { holes += 1 }
                                    // Inside the body, clear of its outline.
                                    if x >= 2 * 15, x < 2 * 52, y >= 2 * 15, y < 2 * 27 {
                                        if p.b > 0.8 && p.r < 0.2 && p.g < 0.2 { blue += 1 }
                                        if p.r > 0.8 && p.g < 0.2 && p.b < 0.2 { red += 1 }
                                    }
                                    // The Next bar, under the body.
                                    if x >= 2 * 25, x < 2 * 36, y >= 2 * 32, y < 2 * 34, p.r > 0.8 && p.g > 0.8 && p.b > 0.8 { ink += 1 }
                                }
                            }
                            #expect(holes == 0, "\(name), \(path): \(holes) pixels punched through")
                            #expect(red == 0, "\(name), \(path): the wallpaper shows through the cut")
                            #expect((ink > 10) == next, "\(name), \(path): the Next bar (\(ink))")
                            if theme == .black {
                                #expect(blue == 0, "\(name), \(path): Black's cuts are the black")
                            } else if state != .available(percentLeft: 8, isLow: true) {
                                #expect(blue > 20, "\(name), \(path): the cut shows the surface (\(blue) pixels)")
                            }
                        }
                    }
                }
            }
        }
        // A battery's digits alone set up no group: on glass they draw the black, and punch through nothing.
        let digits = try ThemeTests.pixels(BatteryDigits(percent: 100).padding(4).background(Self.red).environment(\.juiceTheme, .smoke),
                                           size: CGSize(width: 50, height: 26))
        var holes = 0
        for y in 0..<digits.height { for x in 0..<digits.width where digits.rgba(x, y).a < 0.999 { holes += 1 } }
        #expect(holes == 0)
    }

    /// The real window's layers (the live path, less the glass the window server adds): behind the glass is the floor
    /// alone, never the shadow's caster, and the cuts show the floor, never a hole to the desktop; Black is the opaque
    /// black. Glass under Glass look Widget (the default) has Frost's dark ground inside the glass from the floor of the
    /// desktop widgets' look of the moment, which the window follows (P1214), and its cuts show that (deepened by the
    /// ink's lift, never a hole); under Light and dark nothing. The background moves the window when unlocked, in every
    /// theme.
    @Test func theRealWindowsLayersKeepTheFloorAndTheCuts() throws {
        _ = NSApplication.shared
        let cases = JuiceTheme.allCases.map { ($0, GlassLookChoice.widget) } + [(JuiceTheme.glass, GlassLookChoice.lightAndDark)]
        for (theme, look) in cases {
            let env = AppEnvironment.demo()
            env.settings.juiceTheme = theme
            env.settings.glassLook = look
            let window = DesktopPanelWindow.make(env: env)
            defer { window.close() }
            window.setPanelFrame(CGRect(x: 100, y: 100, width: 362, height: 184))
            let host = try #require(window.contentView)
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            host.layoutSubtreeIfNeeded()
            let size = host.bounds.size
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            // Glass lays nothing of its own under the content (its glass is the window server's, absent headless): no
            // floor, no black, and its cuts show that same nothing; under Widget, Frost's dark ground at the floor of the
            // widgets' look the window follows (the frontmost app's: dimmed, or full colour with Finder in front).
            let state = window.widgets?.state ?? .overApps
            #expect(state.onDesktop)
            let glass = look == .widget ? GlassFrost.widgetOpacity(env.settings.glassFrost, state: state) : 0
            let lifted = theme == .glass && look == .widget
            let surface = theme == .smoke ? GlassStyle.panel.floor : theme == .glass ? glass : 1
            // The band under the divider, the right strip; the demo's 100 % battery's digits (all on the fill).
            for p in [(200.0, 119.0), (378, 60)] {
                #expect(abs(Self.rgba(rep, Int(2 * p.0), Int(2 * p.1)).a - surface) < 0.01, "\(theme) \(look) \(p)")
            }
            var lowest = 1.0
            for y in Int(2 * 48.5)..<Int(2 * 60.5) { for x in Int(2 * 125)..<Int(2 * 159) { lowest = min(lowest, Self.rgba(rep, x, y).a) } }
            #expect(lifted ? lowest > surface - 0.02 : abs(lowest - surface) < 0.02, "\(theme) \(look): the cuts show \(lowest), the surface is \(surface)")
            // Unlocked, a press on the band under the divider and a move drag the window itself (P1200).
            window.movesByDragging = true
            let start = window.frame.origin
            var at = CGPoint(x: window.frame.minX + 200, y: window.frame.maxY - 119)
            window.pointer = { at }
            func send(_ type: NSEvent.EventType) {
                _ = window.handle(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            send(.leftMouseDown)
            at.x += 30
            send(.leftMouseDragged)
            send(.leftMouseUp)
            #expect(window.frame.origin == CGPoint(x: start.x + 30, y: start.y), "\(theme)")
        }
    }

    /// How many bytes differ, and by how much at most.
    static func difference(_ a: ThemeTests.Pixels, _ b: ThemeTests.Pixels) -> (bytes: Int, most: Int) {
        var bytes = 0, most = 0
        for (x, y) in zip(a.data, b.data) where x != y {
            bytes += 1
            most = max(most, abs(Int(x) - Int(y)))
        }
        return (bytes, most)
    }

    /// sRGB components of a bitmap's pixel (y down), un-premultiplied.
    static func rgba(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return (0, 0, 0, 0) }
        return (c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
    }

    // MARK: The chip

    /// The chip's window has no environment: it takes the panel's theme at each show, and draws glass in Glass.
    @Test func theChipTakesThePanelsTheme() throws {
        _ = NSApplication.shared
        let window = PanelHoverLabelWindow(above: DesktopPanelWindow.panelLevel)
        defer { window.close() }
        #expect(window.theme == .black)
        window.setText("Claude · 57%", theme: .smoke)
        #expect(window.theme == .smoke && !window.isVisible)
        window.setText("Codex · 12%")
        #expect(window.theme == .black)
        // Over white, a Smoke chip's surface is the floor over white; Glass's is the light glass (white); Black's is the black;
        // Solid's the window background of the render's (dark) look.
        let size = CGSize(width: 200, height: 56)
        for theme in JuiceTheme.allCases {
            let view = GlassStage(backdrop: .white) {
                PanelHoverChip(text: "Claude", theme: theme).fixedSize().frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .frame(width: size.width, height: size.height)
            let pixels = try ThemeTests.pixels(view, size: size)
            // Inside the chip, in its left padding.
            let p = pixels.rgba(2 * 16, 2 * 26)
            let expected = switch theme {
            case .smoke: 1 - GlassStyle.panel.floor
            case .glass: 1.0
            case .solid: Double(SolidLook.darkGround & 0xFF) / 255
            case .black: 0.0
            }
            #expect(abs(p.r - expected) < 0.03, "\(theme): \(p)")
        }
    }

    /// Frost reaches the chip as it reaches the panel (P668): its window has no environment, so it takes the panel's
    /// Frost at each show with the theme, and a frosted Glass chip draws its veil.
    @Test func theChipTakesThePanelsFrost() throws {
        _ = NSApplication.shared
        let window = PanelHoverLabelWindow(above: DesktopPanelWindow.panelLevel)
        defer { window.close() }
        #expect(window.frost == 0)
        window.setText("Claude · 57%", theme: .glass, frost: 0.7)
        #expect(window.theme == .glass && window.frost == 0.7 && !window.isVisible)
        window.setText("Codex · 12%", theme: .glass)
        #expect(window.frost == 0)
        // Over the black desktop the dark glass is black; Frost's dark ground lifts it inside the chip.
        let size = CGSize(width: 200, height: 56)
        func inside(_ frost: Double) throws -> Double {
            let view = GlassStage(backdrop: .black) {
                PanelHoverChip(text: "Claude", theme: .glass, frost: frost).fixedSize()
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .frame(width: size.width, height: size.height)
            return try ThemeTests.pixels(view, size: size).rgba(2 * 16, 2 * 26).r
        }
        let clear = try inside(0), frosted = try inside(1)
        #expect(frosted - clear > 0.04, "clear \(clear), frosted \(frosted)")
    }

    // MARK: Legibility

    /// Every ink the panel draws holds its contrast on the panel's glass where it is brightest (the floor over a white
    /// wallpaper), worked out and then measured on the stand-in over the three wallpapers: text 4.5:1 (money names and
    /// amounts, suffixes, the used-up label, the digits on the track, a cut digit on the ink or amber fill), marks 3:1
    /// (the outline, nub and rails, the marks, the "?", the signing-in dots, the stale fill against the track).
    @Test func everyPanelInkHoldsOnItsGlass() throws {
        let floor = GlassStyle.panel.floor
        let white = C.surface(over: (1, 1, 1), floor: floor)
        let track = C.over(PanelPalette.smoke.track, white)
        func lum(_ c: (r: Double, g: Double, b: Double)) -> Double { C.luminance(r: c.r, g: c.g, b: c.b) }
        let stale = C.over(Theme.ink.opacity(0.35), track)
        let checks: [(String, Double, Double, Double)] = [
            ("ink", C.luminance(Theme.ink), lum(white), C.text),
            ("ink2", C.luminance(Theme.ink2), lum(white), C.text),
            ("warn amount", C.luminance(Theme.warn), lum(white), C.text),
            ("attention amount", C.luminance(Theme.attention), lum(white), C.text),
            ("digit on the track", C.luminance(Theme.ink), lum(track), C.text),
            ("cut digit on the fill", lum(white), C.luminance(Theme.ink), C.text),
            ("cut digit on amber", lum(white), C.luminance(Theme.warn), C.text),
            ("line", C.luminance(Theme.line), lum(white), C.mark),
            ("claude mark", C.luminance(Theme.claudeMark), lum(white), C.mark),
            ("codex mark", C.luminance(Theme.codexMark), lum(white), C.mark),
            ("? on the track", C.luminance(Theme.ink2), lum(track), C.mark),
            ("stale fill on the track", lum(stale), lum(track), 2.0),
        ]
        for (name, a, b, least) in checks { #expect(C.ratio(a, b) >= least, "\(name): \(C.ratio(a, b))") }

        // Measured: the panel's own surface (the stand-in) over each wallpaper, its brightest pixel clear of the rim.
        let panel = Theme.Panel.size, margin = PanelGeometry.margin
        for backdrop in GlassBackdrop.judged {
            let view = PanelGlassRenders.staged(Color.clear.frame(width: panel.width, height: panel.height)
                .modifier(PanelSurface(radius: Theme.Panel.radius)).padding(margin), backdrop, .smoke, size: PanelGlassRenders.window)
            let pixels = try ThemeTests.pixels(view, size: PanelGlassRenders.window)
            var brightest = 0.0
            let inset = Theme.Panel.radius
            for y in Int(2 * (margin + 4))..<Int(2 * (margin + panel.height - 4)) {
                for x in Int(2 * (margin + inset))..<Int(2 * (margin + panel.width - inset)) {
                    let p = pixels.rgba(x, y)
                    brightest = max(brightest, C.luminance(r: p.r, g: p.g, b: p.b))
                }
            }
            #expect(brightest <= lum(white) + 0.002, "\(backdrop): \(brightest)")
            #expect(C.ratio(C.luminance(Theme.ink2), brightest) >= C.text, "\(backdrop)")
            #expect(C.ratio(C.luminance(Theme.line), brightest) >= C.mark, "\(backdrop)")
            #expect(C.ratio(C.luminance(Theme.claudeMark), brightest) >= C.mark, "\(backdrop)")
        }
    }
}
