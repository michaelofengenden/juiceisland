import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Glass look Widget follows macOS's desktop widgets on the desktop panel (P1204 to P1214): full colour while the desktop
/// is in front, the regular glass's dark face with nothing of ours in it and white ink lifted by a soft shadow; dimmed
/// while an app is, the same a tenth deeper. Over the apps (the island) it is Widget as it was.
@MainActor
struct WidgetFullColourTests {
    // MARK: What macOS says

    /// Dim widgets on desktop, as macOS stores it (`com.apple.widgets` › `widgetAppearance`): 0 recessed (Always),
    /// 1 original (Never), 2 automatic; absent, unknown, a Boolean or anything else is Automatically, macOS's default.
    /// System Settings' own code reads and writes it so (P1208): its intents' numbering (Automatically 0, Never 1,
    /// Always 2) is a separate enum for Shortcuts, never stored.
    @Test func theSettingReadsMacOSsValues() {
        #expect(DimWidgetsSetting(stored: nil) == .automatically)
        #expect(DimWidgetsSetting(stored: NSNumber(value: 0)) == .always)
        #expect(DimWidgetsSetting(stored: NSNumber(value: 1)) == .never)
        #expect(DimWidgetsSetting(stored: NSNumber(value: 2)) == .automatically)
        #expect(DimWidgetsSetting(stored: NSNumber(value: 9)) == .automatically)
        #expect(DimWidgetsSetting(stored: kCFBooleanTrue) == .automatically)
        #expect(DimWidgetsSetting(stored: "recessed") == .always)
        #expect(DimWidgetsSetting(stored: "original") == .never)
        #expect(DimWidgetsSetting(stored: "automatic") == .automatically)
        #expect(DimWidgetsSetting(stored: Data()) == .automatically)
        #expect(DimWidgetsSetting.domain == "com.apple.widgets" && DimWidgetsSetting.key == "widgetAppearance")
    }

    /// Automatically: full colour while Finder (the desktop) is in front, dimmed under any other app or none; Always
    /// dimmed; Never full colour.
    @Test func theLookIsTheWidgetsLook() {
        for app in ["com.apple.finder", "com.apple.Safari", "com.apple.Terminal", nil] as [String?] {
            #expect(DesktopWidgets.state(frontmost: app, setting: .automatically) == (app == "com.apple.finder" ? .fullColour : .dimmed))
            #expect(DesktopWidgets.state(frontmost: app, setting: .always) == .dimmed)
            #expect(DesktopWidgets.state(frontmost: app, setting: .never) == .fullColour)
        }
    }

    final class Front { var app: String?; var setting = DimWidgetsSetting.automatically; var reads = 0 }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    /// The watch reads the frontmost app and the setting at each activation notice and nowhere else, and its state (what
    /// the panel observes) changes only when the look does: never for a switch between two apps.
    @Test func theWatchFollowsActivationsAndChangesOnlyWithTheLook() {
        let center = NotificationCenter()
        let front = Front()
        front.app = "com.apple.Safari"
        let watch = DesktopWidgetWatch(workspace: center, frontmost: { front.app }, setting: { front.reads += 1; return front.setting })
        defer { watch.stop() }
        #expect(watch.state == .dimmed && front.reads == 1)
        let counter = Counter()
        func track() { withObservationTracking { _ = watch.state } onChange: { counter.add() } }
        var changes: Int { counter.value }
        track()
        front.app = "com.apple.Terminal"
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(watch.state == .dimmed && changes == 0 && front.reads == 2)
        front.app = "com.apple.finder"
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(watch.state == .fullColour && changes == 1)
        track()
        front.setting = .always
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(watch.state == .dimmed && changes == 2)
        watch.stop()
        front.setting = .never
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(watch.state == .dimmed && front.reads == 4)
    }

    // MARK: The look

    /// Over the apps, Widget's Frost is as it was (its floor at 0); on the desktop, dimmed, from a tenth; in full colour
    /// nothing at 0; each up to the dark ground's 0.6 at 1, never the light one. Light and dark's is untouched by any.
    @Test func fullColourLaysNoGroundUnlessFrostAsks() {
        for frost in stride(from: 0.0, through: 1.0, by: 0.1) {
            let stored = GlassFrost.stored(frost)
            #expect(abs(GlassFrost.widgetOpacity(frost, state: .fullColour) - stored * GlassFrost.widgetMaximum) < 1e-9)
            #expect(abs(GlassFrost.widgetOpacity(frost, state: .dimmed) - (0.1 + stored * 0.5)) < 1e-9)
            #expect(GlassFrost.widgetOpacity(frost, state: .overApps) == GlassFrost.widgetOpacity(frost))
            #expect(abs(GlassFrost.widgetOpacity(frost) - (0.5 + stored * 0.1)) < 1e-9)
            for scheme in [ColorScheme.light, .dark] {
                let full = GlassContrast.components(GlassFrost.colour(frost, look: .widget, state: .fullColour), scheme)
                #expect(abs(full.a - stored * GlassFrost.widgetMaximum) < 0.002 && full.r < 0.15, "\(frost) \(scheme)")
                let before = GlassContrast.components(GlassFrost.colour(frost), scheme)
                let either = GlassContrast.components(GlassFrost.colour(frost, look: .lightAndDark, state: .fullColour), scheme)
                #expect(before == either)
            }
        }
        #expect(GlassFrost.widgetOpacity(0, state: .fullColour) == 0 && GlassFrost.widgetDimmedFloor == 0.1)
    }

    /// The panel's ground while the widgets are dimmed (P1214), against the only measured dimmed widget (lavender
    /// #8A8CC8 under it came out #6F6FC4, P872) through the dark face (`GlassFaceModel.dark`): no ground of ours 15.7, a
    /// tenth 17.1, a fifth 19.2 (no public glass deepens and saturates at once), the old half 32.2; over the dimmed
    /// widgets' model's colours (`WidgetGlassRenders.widgetModel`: the lavender, its pink, a night sky, white, a mid
    /// grey) a tenth is the closest of the four, mean ΔE 9.4 against 10.1 with none.
    @Test func theDimmedGroundIsATenth() {
        func through(_ hex: UInt32, ground: Double, face: GlassFaceModel = .dark) -> UInt32 {
            let c = Self.rgb(hex), f = face.apply(c.r, c.g, c.b), g = Self.rgb(0x242427)
            return Self.hex((f.r * (1 - ground) + g.r * ground, f.g * (1 - ground) + g.g * ground, f.b * (1 - ground) + g.b * ground))
        }
        let grounds = [0.0, 0.1, 0.2, 0.5]
        let measured = grounds.map { Self.deltaE(through(0x8A8CC8, ground: $0), 0x6F6FC4) }
        #expect(measured[0] < 16 && measured[1] < 18 && measured[2] < 20 && measured[3] > 30, "\(measured)")
        let colours: [UInt32] = [0x8A8CC8, 0xE58BC0, 0x1B2440, 0xFFFFFF, 0x808080]
        let model = WidgetGlassRenders.widgetModel
        let mean = grounds.map { ground in
            colours.map { Self.deltaE(through($0, ground: ground), through($0, ground: 0, face: model)) }.reduce(0, +) / Double(colours.count)
        }
        #expect(mean.indices.min { mean[$0] < mean[$1] } == 1, "\(mean)")
    }

    /// The candidates measured for the widgets' full-colour glass (Core Animation drawing each one's own filters over flat
    /// colours, offscreen, macOS 27; P1205), against the owner's screenshot: just outside the Batteries widget #8E8CC9
    /// above and #AE97C6 below, just inside it #9A88C8 and #A78CC4. The regular glass's dark face is the closest public
    /// glass (ΔE 4.9 on average), and `GlassFaceModel.dark` gives back its two measurements; the old Widget's ground made
    /// it ΔE 28.7, the light face 16.
    @Test func theDarkFaceIsTheClosestGlassToTheWidgets() {
        let pairs: [(outside: UInt32, inside: UInt32)] = [(0x8E8CC9, 0x9A88C8), (0xAE97C6, 0xA78CC4)]
        let measured: [(String, [UInt32])] = [
            ("regular, dark face", [0x8684C6, 0xA188BA]),
            ("clear, dark face", [0x7D7BB5, 0x9882AF]),
            ("clear, light face", [0xA7A5DC, 0xC0ACD6]),
            ("regular, light face", [0xB6B3F7, 0xD0B7EA]),
            ("regular, light face, tinted white", [0x9D9BCB, 0xB2A0C4]),
            ("old Widget: dark face, ground 0.5", [0x555476, 0x625670]),
        ]
        func error(_ outs: [UInt32]) -> Double { zip(outs, pairs).map { Self.deltaE($0, $1.inside) }.reduce(0, +) / 2 }
        let ranked = measured.sorted { error($0.1) < error($1.1) }
        #expect(ranked.first?.0 == "regular, dark face", "\(ranked.map { ($0.0, error($0.1)) })")
        #expect(abs(error(measured[0].1) - 4.9) < 0.15 && error(measured[5].1) > 25)
        for (pair, out) in zip(pairs, measured[0].1) {
            let c = Self.rgb(pair.outside), face = GlassFaceModel.dark.apply(c.r, c.g, c.b), want = Self.rgb(out)
            for (got, w) in [(face.r, want.r), (face.g, want.g), (face.b, want.b)] { #expect(abs(got - w) <= 2.5 / 255) }
        }
        // The renders' reference, fitted to the two pairs: ΔE 3.2 on average (the top's hue turn, 6.4, is the blur's
        // pinker light from below, which no flat model draws).
        let reference = pairs.map { pair in
            let c = Self.rgb(pair.outside)
            return Self.deltaE(Self.hex(WidgetGlassRenders.fullColourModel.apply(c.r, c.g, c.b)), pair.inside)
        }
        #expect(reference.reduce(0, +) / 2 < 3.5 && reference.allSatisfy { $0 < 7 }, "\(reference)")
    }

    /// White ink lifted by `WidgetInkLift` over the full-colour glass at its brightest: the dark face over a white window
    /// or a near-white wallpaper (#B4B4B4, #B4B2AF), where white alone is 2.1:1. The ground half a point to a point off
    /// each stroke (past the stroke's own antialiasing) is dark enough that the white holds 4.5:1 against it; without the
    /// lift it does not. Over the owner's lavender (the face's #9486BF) and a night sky it holds with room.
    @Test(arguments: [0xB4B4B4, 0xB4B2AF, 0x9486BF, 0x2D385B] as [UInt32])
    func theLiftedInkHoldsOverThePalestGlass(_ ground: UInt32) throws {
        let lifted = try Self.ringContrast(ground: ground, lift: true)
        #expect(lifted >= 4.5, "#\(String(ground, radix: 16)): \(lifted)")
        if ground == 0xB4B4B4 {
            let bare = try Self.ringContrast(ground: ground, lift: false)
            #expect(bare < 3, "bare \(bare)")
        }
    }

    /// The lift is Widget's on the desktop only, in either of the widgets' looks: over the apps (the island) and Light
    /// and dark draw the very pixels they drew.
    @Test func theLiftIsTheDesktopsOnly() throws {
        func bitmap(_ look: GlassLookChoice, _ state: WidgetGlassState?) throws -> [UInt8] {
            let text = Text("OpenRouter $7,595").font(.system(size: 12.5)).foregroundStyle(.white).padding(8).modifier(WidgetInkLift())
                .background(Color(hex: 0xB4B4B4)).environment(\.glassLook, look)
            let view = state.map { AnyView(text.environment(\.widgetGlassState, $0)) } ?? AnyView(text)
            return try AppearanceRenders.bitmap(view, size: CGSize(width: 140, height: 32), env: .demo(), scheme: .light)
        }
        // Two renders of one view differ by a few dozen bytes of a glyph's antialiasing (P769): alike, not equal.
        let plain = try bitmap(.lightAndDark, nil)
        #expect(try WidgetGlassRenders.alike(bitmap(.widget, nil), plain))
        #expect(try WidgetGlassRenders.alike(bitmap(.widget, .overApps), plain))
        #expect(try WidgetGlassRenders.alike(bitmap(.lightAndDark, .fullColour), plain))
        #expect(try WidgetGlassRenders.alike(bitmap(.lightAndDark, .dimmed), plain))
        #expect(try !WidgetGlassRenders.alike(bitmap(.widget, .fullColour), plain))
        #expect(try !WidgetGlassRenders.alike(bitmap(.widget, .dimmed), plain))
    }

    /// The panel takes the widgets' look through its root and its chip at each show; a window made for the app follows
    /// macOS's widgets; the island and the Settings preview read none of it (over the apps, Widget as it was).
    @Test func thePanelAndItsChipTakeTheWidgetsLook() throws {
        let env = AppEnvironment.demo()
        env.settings.juiceTheme = .glass
        env.settings.glassLook = .widget
        let window = DesktopPanelWindow.make(env: env)
        defer { window.close() }
        #expect(window.widgets != nil)
        window.widgets?.stop()
        let chip = PanelHoverLabelWindow(above: .normal)
        chip.setText("Claude · 57%", theme: .glass, look: .widget, widgets: .fullColour)
        #expect(chip.widgets == .fullColour)
        chip.setText("Codex · 12%", theme: .glass, look: .widget)
        #expect(chip.widgets == .overApps)
        // The root: without a watch Widget as it was; dimmed a tenth of the ground, much lighter; full colour none.
        let center = NotificationCenter()
        let front = Front()
        let watch = DesktopWidgetWatch(workspace: center, frontmost: { front.app }, setting: { .automatically })
        defer { watch.stop() }
        func bitmap(_ root: AnyView) throws -> [UInt8] {
            let scene = GlassStage(backdrop: .gradient) { root.frame(width: 410, height: 232) }
                .environment(\.juiceTheme, .glass).environment(\.glassLook, .widget)
            return try AppearanceRenders.bitmap(scene, size: CGSize(width: 410, height: 232), env: env, scheme: .light)
        }
        let actions = PanelActions.desktop(env: env)
        let old = try bitmap(AnyView(DesktopPanelRootView(actions: actions, hover: { _ in })))
        #expect(watch.state == .dimmed)
        let dimmed = try bitmap(AnyView(DesktopPanelRootView(actions: actions, hover: { _ in }, widgets: watch)))
        #expect(!WidgetGlassRenders.alike(old, dimmed))
        front.app = DesktopWidgets.finder
        center.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        #expect(watch.state == .fullColour)
        let full = try bitmap(AnyView(DesktopPanelRootView(actions: actions, hover: { _ in }, widgets: watch)))
        // The band under the panel's top padding: far lighter dimmed than the old ground, lighter still in full colour.
        func luma(_ data: [UInt8], _ x: Int, _ y: Int) -> Double {
            let i = (y * 820 + x) * 4
            return 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])
        }
        let at = (2 * 200, 2 * 32)
        #expect(luma(dimmed, at.0, at.1) > luma(old, at.0, at.1) + 20, "\(luma(dimmed, at.0, at.1)) \(luma(old, at.0, at.1))")
        #expect(luma(full, at.0, at.1) > luma(dimmed, at.0, at.1) + 4, "\(luma(full, at.0, at.1)) \(luma(dimmed, at.0, at.1))")
    }

    // MARK: Helpers

    /// White text (12.5 pt, the money's) over `ground`, with or without Widget's lift on the desktop: the contrast of the
    /// white against the mean of the ground a point either side of its strokes (rendered at 2x).
    static func ringContrast(ground: UInt32, lift: Bool, skip: Int = 1, reach: Int = 2) throws -> Double {
        let size = CGSize(width: 160, height: 36)
        let view = Text("OpenRouter $7,595").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .modifier(WidgetInkLift())
            .background(Color(hex: ground))
            .environment(\.glassLook, .widget)
            .environment(\.widgetGlassState, lift ? .fullColour : .overApps)
        let data = try AppearanceRenders.bitmap(view, size: size, env: .demo(), scheme: .light)
        return ring(data, size: size, skip: skip, reach: reach)
    }

    /// The contrast of white against the mean ground from `skip` to `reach` pixels (2x) off the white strokes in `data`.
    static func ring(_ data: [UInt8], size: CGSize, skip: Int, reach: Int) -> Double {
        let w = Int(size.width * 2), h = Int(size.height * 2)
        func lum(_ i: Int) -> Double {
            func lin(_ c: UInt8) -> Double { let v = Double(c) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(data[i]) + 0.7152 * lin(data[i + 1]) + 0.0722 * lin(data[i + 2])
        }
        var core = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w { core[y * w + x] = lum((y * w + x) * 4) > 0.9 } }
        var sum = 0.0, count = 0
        for y in 0..<h { for x in 0..<w where !core[y * w + x] {
            var nearest = Int.max
            for dy in -reach...reach { for dx in -reach...reach {
                let (nx, ny) = (x + dx, y + dy)
                if nx >= 0, ny >= 0, nx < w, ny < h, core[ny * w + nx] { nearest = min(nearest, max(abs(dx), abs(dy))) }
            } }
            if nearest > skip, nearest <= reach { sum += lum((y * w + x) * 4); count += 1 }
        } }
        let ring = sum / Double(max(1, count))
        return 1.05 / (ring + 0.05)
    }

    static func rgb(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    static func hex(_ c: (r: Double, g: Double, b: Double)) -> UInt32 {
        func b(_ v: Double) -> UInt32 { UInt32((min(1, max(0, v)) * 255).rounded()) }
        return b(c.r) << 16 | b(c.g) << 8 | b(c.b)
    }

    /// CIE76 ΔE between two sRGB colours (D65).
    static func deltaE(_ a: UInt32, _ b: UInt32) -> Double {
        func lab(_ hex: UInt32) -> (Double, Double, Double) {
            let c = rgb(hex)
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let (r, g, b) = (lin(c.r), lin(c.g), lin(c.b))
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
            func f(_ t: Double) -> Double { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
            return (116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        let (p, q) = (lab(a), lab(b))
        return ((p.0 - q.0) * (p.0 - q.0) + (p.1 - q.1) * (p.1 - q.1) + (p.2 - q.2) * (p.2 - q.2)).squareRoot()
    }
}
