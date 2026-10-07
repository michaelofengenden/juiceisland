import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › General › Appearance (P760 to P769) and Theme Solid (P770 to P779), headless: the setting, the look each
/// surface takes in each theme, the live switch (macOS's mode and the app's stood in for by windows and views of ours,
/// never the Mac's own setting), Glass's look pinned to the Appearance, Solid's material, and every light twin's contrast.
@MainActor
@Suite(.serialized)
struct AppearanceTests {
    typealias C = GlassContrast

    // MARK: The setting

    @Test func theSettingIsSystemByDefaultStoredAndMapped() throws {
        #expect(AppSettings.ephemeral().appearance == .system)
        #expect(AppearanceChoice.allCases == [.system, .light, .dark] && AppearanceChoice.allCases.map(\.title) == ["System", "Light", "Dark"])
        let suite = "appearance-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: defaults).appearance == .system)
        let settings = AppSettings(defaults: defaults)
        settings.appearance = .light
        #expect(defaults.string(forKey: AppSettings.Key.appearance) == "light")
        #expect(AppSettings(defaults: defaults).appearance == .light)
        settings.appearance = .dark
        #expect(AppSettings(defaults: defaults).appearance == .dark)
        // A word this build does not know reads as System.
        defaults.set("sepia", forKey: AppSettings.Key.appearance)
        #expect(AppSettings(defaults: defaults).appearance == .system)
        // System is none of the app's own (macOS's, live); Light and Dark pin aqua and darkAqua.
        #expect(AppearanceChoice.system.appearanceName == nil && AppearanceChoice.system.nsAppearance == nil)
        #expect(AppearanceChoice.light.appearanceName == .aqua && AppearanceChoice.light.nsAppearance?.name == .aqua)
        #expect(AppearanceChoice.dark.appearanceName == .darkAqua && AppearanceChoice.dark.nsAppearance?.name == .darkAqua)
        for system in [ColorScheme.light, .dark] {
            #expect(AppearanceChoice.system.scheme(system: system) == system)
            #expect(AppearanceChoice.light.scheme(system: system) == .light && AppearanceChoice.dark.scheme(system: system) == .dark)
        }
        #expect(NSAppearance(named: .darkAqua)?.colorScheme == .dark && NSAppearance(named: .aqua)?.colorScheme == .light)
        #expect(NSAppearance(named: .accessibilityHighContrastDarkAqua)?.colorScheme == .dark)
    }

    /// The app takes the setting, and only when it changes (`AppAppearance`, on a stand-in for the app).
    @Test func theAppTakesTheSetting() async {
        let settings = AppSettings.ephemeral()
        let app = NSView()
        let appearance = AppAppearance(settings: settings, target: app)
        #expect(app.appearance == nil, "System: macOS's")
        for (choice, name) in [(AppearanceChoice.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            settings.appearance = choice
            await FramePerf.wait(0.05)
            #expect(app.appearance?.name == name)
        }
        settings.appearance = .system
        await FramePerf.wait(0.05)
        #expect(app.appearance == nil)
        // Born with a pinned choice, it puts it on at once.
        let pinned = AppSettings.ephemeral()
        pinned.appearance = .dark
        let other = NSView()
        let second = AppAppearance(settings: pinned, target: other)
        #expect(other.appearance?.name == .darkAqua)
        _ = (appearance, second)
    }

    // MARK: Each surface in each theme

    /// Settings sets no appearance of its own in any theme (it takes the app's); the window is dark on Black and Smoke and
    /// the app's on Glass and Solid, and so is what floats over it; the Theme preview shows Glass and Solid in Settings'
    /// look, Black and Smoke dark (P762, P763, P768, P779).
    @Test(arguments: JuiceTheme.allCases)
    func eachSurfacesLookInEachTheme(_ theme: JuiceTheme) {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        let env = AppEnvironment.demo(settings: settings)
        let settingsWindow = SettingsWindowController(env: env, onClose: {})
        #expect(settingsWindow.window.appearance == nil)
        let main = MainWindowController(env: env)
        #expect(main.window.appearance?.name == (theme.adapts ? nil : .darkAqua))
        #expect(WindowLook.appearance(theme)?.name == (theme.adapts ? nil : .darkAqua))
        for app in [ColorScheme.light, .dark] {
            let look = WindowLook.scheme(theme, app: app)
            #expect(look == (theme.adapts ? app : .dark))
            #expect(WindowLook.tokens(theme, scheme: look) == (theme.adapts && app == .light ? .solid : .black))
            #expect(ThemePreview.look(theme, settings: app) == look)
            // The window's own background where SwiftUI has not drawn: white only where it is light.
            let background = Self.resolve(WindowLook.background(theme), app)
            #expect(background == (theme.adapts && app == .light ? 1 : 0), "\(theme) \(app): \(background)")
        }
    }

    /// The window follows the theme live: Glass and Solid hand it the app's look, Black and Smoke pin it dark again.
    @Test func theWindowFollowsTheThemeLive() async {
        let settings = AppSettings.ephemeral()
        let main = MainWindowController(env: .demo(settings: settings))
        #expect(main.window.appearance?.name == .darkAqua)
        for theme in [JuiceTheme.glass, .smoke, .solid, .black] {
            settings.juiceTheme = theme
            await FramePerf.wait(0.05)
            #expect(main.window.appearance?.name == (theme.adapts ? nil : .darkAqua), "\(theme)")
        }
    }

    // MARK: The live switch

    /// macOS's mode (a window standing in for it) and the app's appearance (a view standing in for `NSApp`, the target of
    /// `AppAppearance`) reach Settings' content at once in every case: System follows macOS both ways, Light and Dark
    /// pin it whatever macOS does. Nothing is polled: the switch is AppKit's own propagation of the appearance (P766).
    @Test func settingsFollowsTheModeAndTheSettingLive() async throws {
        let settings = AppSettings.ephemeral()
        let env = AppEnvironment.demo(settings: settings)
        let stage = LookStage(root: AnyView(SettingsRootView(navigation: SettingsNavigation(pane: .general), scrolls: false)
            .environment(env).environment(\.glassRendering, .standIn)), size: CGSize(width: SettingsTheme.Metrics.width, height: 560))
        let appearance = AppAppearance(settings: settings, target: stage.app)
        // The detail's ground at the bottom right: light (above 0.9) or dark (under 0.25).
        let point = CGPoint(x: SettingsTheme.Metrics.width - 6, y: 554)
        for (choice, system, want) in [(AppearanceChoice.system, ColorScheme.light, ColorScheme.light), (.system, .dark, .dark),
                                       (.light, .dark, .light), (.dark, .light, .dark), (.system, .light, .light)] {
            settings.appearance = choice
            stage.system(system)
            await FramePerf.wait(0.15)
            let seen = try stage.colour(at: point).r
            #expect(want == .light ? seen > 0.9 : seen < 0.25, "\(choice) under a \(system) Mac: \(seen), want \(want)")
        }
        _ = appearance
    }

    /// Window mode on Glass and Solid takes the look live; on Black it stays black under a light Mac.
    @Test(arguments: [JuiceTheme.glass, .solid, .black])
    func theWindowsContentFollowsTheLookLive(_ theme: JuiceTheme) async throws {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        let env = AppEnvironment.demo(settings: settings, sessions: .prototype)
        let size = WindowTheme.Metrics.minSize
        let stage = LookStage(root: AnyView(WindowRootView(drawsTrafficLights: true).environment(env).environment(\.glassRendering, .standIn)),
                              size: size)
        // The session list's ground, in its left padding at the bottom.
        let point = CGPoint(x: 4, y: size.height - 4)
        for system in [ColorScheme.light, .dark, .light] {
            stage.system(system)
            await FramePerf.wait(0.15)
            let seen = try stage.colour(at: point).r
            let want: Double = theme.adapts && system == .light ? 1 : 0
            #expect(abs(seen - want) < 0.02, "\(theme) under a \(system) Mac: \(seen)")
        }
    }

    /// The island's content on Glass and Solid takes the window's look (the Appearance's) and follows it live, on Core
    /// Animation's outline, which hands it to the edge line and the rim drawn outside the content (`glassScheme`, P568).
    /// Solid's surface there is the window material, in that same look: its view's appearance and its hairline follow.
    @Test(arguments: [JuiceTheme.glass, .solid])
    func theIslandFollowsTheLookLive(_ theme: JuiceTheme) async throws {
        _ = NSApplication.shared
        let rig = await IslandGlassTests.rig(.coreAnimation, theme: theme)
        for look in [ColorScheme.light, .dark, .light] {
            rig.window.appearance = NSAppearance.named(look)
            // Until the content has said its look and the rim's view has taken it, a hop on the main actor after the
            // content's (`observeGlassScheme`): a set 0.3 s looked between the two under a full run (P1258).
            await FramePerf.settle(rig) { rig.ui.glassScheme == look && rig.canvas.glassView?.effectiveAppearance.colorScheme == look }
            #expect(rig.ui.glassScheme == look, "\(theme): \(String(describing: rig.ui.glassScheme)), want \(look)")
            let glass = try #require(rig.canvas.glassView)
            #expect(glass.effectiveAppearance.colorScheme == look)
            if theme == .solid {
                let effect = try #require(glass.effectView as? NSVisualEffectView)
                #expect(effect.effectiveAppearance.colorScheme == look)
                // The hairline's full strength (the profile's bottom): the ink where it is light, white where it is dark.
                let line = try #require((glass.rimLayer.colors?[1]).map { $0 as! CGColor }?.components)
                #expect(look == .dark ? line[0] > 0.99 && abs(line[3] - 0.18) < 0.01 : line[0] < 0.01 && abs(line[3] - SolidLook.lightEdge) < 0.01,
                        "\(look): \(line)")
            }
        }
        rig.stop()
    }

    /// Black's and Smoke's island content stays dark in a light window, and so does the panel's ink: they never read the
    /// Appearance (P760). Smoke's glass is pinned dark inside `GlassSurfaceBody` and `GlassSurfaceNSView`.
    @Test func blackAndSmokeStayDarkInALightWindow() async throws {
        for theme in [JuiceTheme.black, .smoke] {
            let box = SchemeBox()
            let stage = LookStage(root: AnyView(VStack {
                Color.clear.background(SchemeReader(box: box, key: "island")).modifier(IslandGlassContent(ui: IslandUIState(), outside: false))
                Color.clear.background(SchemeReader(box: box, key: "panel")).modifier(PanelInkScheme(theme: theme))
            }.environment(\.juiceTheme, theme)), size: CGSize(width: 60, height: 60))
            stage.system(.light)
            await FramePerf.wait(0.15)
            #expect(box.seen["island"] == .dark && box.seen["panel"] == .dark, "\(theme): \(box.seen)")
        }
        // Glass and Solid: the window's look, which is the Appearance's.
        for theme in [JuiceTheme.glass, .solid] {
            let box = SchemeBox()
            let stage = LookStage(root: AnyView(VStack {
                Color.clear.background(SchemeReader(box: box, key: "island")).modifier(IslandGlassContent(ui: IslandUIState(), outside: false))
                Color.clear.background(SchemeReader(box: box, key: "panel")).modifier(PanelInkScheme(theme: theme))
            }.environment(\.juiceTheme, theme)), size: CGSize(width: 60, height: 60))
            stage.system(.light)
            await FramePerf.wait(0.15)
            #expect(box.seen["island"] == .light && box.seen["panel"] == .light, "\(theme): \(box.seen)")
        }
    }

    // MARK: Glass pinned to the Appearance

    /// The content inside Glass's glass takes the colour scheme the glass is drawn in (the Appearance's, which the window
    /// carries), and `inGlass` says it again inside the glass so no look the glass might hand its content from what is
    /// behind it can reach the ink: a view inside a live glass in a window of one look, under an environment of the
    /// other, reads the environment's (P764). SwiftUI takes the glass's own light or dark face from that same scheme (seen
    /// on macOS 27 in the glass's layers, `glassBackground`: the light face lifts black to 0.40 under a 6 % white fill,
    /// the dark one keeps a 0.6 luma ceiling, whatever the window's appearance), so face and ink are one look.
    @Test(arguments: [ColorScheme.light, .dark])
    func glassContentTakesTheAppearancesLook(_ look: ColorScheme) async {
        let other: ColorScheme = look == .dark ? .light : .dark
        let box = SchemeBox()
        let stage = LookStage(root: AnyView(Color.clear.frame(width: 80, height: 40)
            .background(SchemeReader(box: box, key: "inside"))
            .inGlass(Rectangle(), style: GlassStyle.island.clear)
            .environment(\.colorScheme, look)), size: CGSize(width: 80, height: 40))
        stage.system(other)
        await FramePerf.wait(0.15)
        #expect(box.seen["inside"] == look)
    }

    // MARK: Solid

    /// Solid's surfaces: the window material where AppKit hosts it (behind the window, always active, no floor, the
    /// view's appearance inherited), SwiftUI's own window background style where SwiftUI draws it (it builds the same
    /// layers, clipped by SwiftUI as no AppKit view would be, P771), the untinted ground in renders; Glass's palettes;
    /// State tint but no Frost; plain keys on its cards; the knock-outs of every theme but Black (P770, P772, P776).
    @Test func solidIsTheWindowMaterialInGlasssInk() {
        let solid = JuiceTheme.solid
        #expect(JuiceTheme(stored: "solid") == .solid && solid.title == "Solid")
        #expect(solid.adapts && solid.knocksOut)
        #expect(solid.island == .glass && solid.panel == .glass)
        #expect(GlyphFinish(solid) == .glass)
        #expect(!IslandPaneText.showsFrostRow(solid) && IslandPaneText.showsStateTintRow(solid))
        #expect(IslandPaneText.themeNote(solid) != nil && JuiceTheme.allCases.filter { IslandPaneText.themeNote($0) != nil } == [.solid])
        #expect(SolidLook.material == .windowBackground)
        let view = GlassSurfaceNSView(style: .island, backdrop: .window, increaseContrast: false)
        let effect = view.effectView as? NSVisualEffectView
        #expect(effect?.material == .windowBackground && effect?.blendingMode == .behindWindow && effect?.state == .active)
        #expect(view.appearance == nil && view.floorLayer.fillColor == nil)
        #expect(view.layer?.mask === view.maskLayer, "born masked, as every glass view")
        // The material's own layers, as AppKit builds them in each look: an opaque fill (white, #1E1E1E), and over the dark
        // one the system's desktop tint, which the wallpaper colours and "Allow wallpaper tinting in windows" switches.
        for look in [ColorScheme.light, .dark] {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 80, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance.named(look)
            let host = NSView(frame: CGRect(x: 0, y: 0, width: 80, height: 40))
            host.wantsLayer = true
            window.contentView = host
            let effect = NSVisualEffectView(frame: host.bounds)
            effect.material = SolidLook.material
            effect.blendingMode = .behindWindow
            effect.state = .active
            host.addSubview(effect)
            effect.layoutSubtreeIfNeeded()
            effect.display()
            CATransaction.flush()
            let layers = Self.flatten(effect.layer)
            let fill = layers.first { $0.name == "fill" }?.backgroundColor?.components ?? []
            let want = Double((look == .dark ? SolidLook.darkGround : SolidLook.lightGround) & 0xFF) / 255
            #expect(abs((fill.first ?? -1) - want) < 0.005 && (fill.last ?? 0) > 0.999, "\(look): fill \(fill)")
            let tint = layers.first { $0.name == "desktop tint" }
            print("Solid's material in the \(look) look: fill \(fill), desktop tint \(tint.map { "at \($0.opacity)" } ?? "none")")
            if look == .dark, let tint { #expect(abs(Double(tint.opacity) - SolidLook.darkTint) < 0.001) }
            window.contentView = nil
        }
    }

    /// Glass's twins hold on Solid's grounds: both lie on the ink's far side of Glass's bounds, the light ground lighter
    /// than the light glass's worst (#BFBFBF), the dark one, tinted by a white wallpaper, darker than the dark glass's
    /// (#404040), so every ratio Glass keeps Solid keeps with room (P775).
    @Test func glasssInkHoldsOnSolid() {
        #expect(SolidLook.worstLight >= C.bound(.light, .increased) && SolidLook.worstDark <= C.bound(.dark))
        var lowest: [String] = []
        for scheme in [ColorScheme.light, .dark] {
            let grey = scheme == .light ? SolidLook.worstLight : SolidLook.worstDark
            let ground = C.luminance(r: grey, g: grey, b: grey)
            var worst = (name: "", ratio: Double.infinity)
            for (name, colour) in GlassThemeTests.text + GlassThemeTests.words {
                let ratio = C.ratio(C.luminance(colour, scheme), ground)
                #expect(ratio >= C.text, "\(scheme) \(name): \(ratio)")
                if ratio < worst.ratio { worst = (name, ratio) }
            }
            for (name, colour) in GlassThemeTests.marks {
                let ratio = C.ratio(C.luminance(colour, scheme), ground)
                #expect(ratio >= C.mark, "\(scheme) mark \(name): \(ratio)")
            }
            lowest.append("\(scheme): \(worst.name) \(String(format: "%.2f", worst.ratio))")
        }
        print("Glass's ink on Solid's worst grounds: " + lowest.joined(separator: ", "))
    }

    /// Solid on Core Animation's outline: the window material in the black's place, under the content, masked by the
    /// outline exactly; no marks of the glass's (the notch plate is the content's, over the veil: P793) and no shade; the
    /// black's fill clear; a switch to Glass, Smoke or Black takes it away, and back to Solid brings it again (P771, P773).
    @Test func solidOnCoreAnimationsOutline() async throws {
        _ = NSApplication.shared
        let rig = await IslandGlassTests.rig(.coreAnimation, theme: .solid)
        let canvas = rig.canvas
        let glass = try #require(canvas.glassView)
        let surface = try #require(canvas.surfaceView), masked = try #require(canvas.maskedView)
        let views = try #require(rig.window.contentView?.subviews)
        #expect(glass.backdrop == .window && glass.effectView is NSVisualEffectView)
        #expect(views.firstIndex(of: surface)! < views.firstIndex(of: glass)! && views.firstIndex(of: glass)! < views.firstIndex(of: masked)!,
                "the material between the black's view and the content")
        #expect(canvas.layers.fill.fillColor == nil)
        let names = (glass.marksLayer.sublayers ?? []).compactMap(\.name)
        #expect(names.isEmpty, "\(names)")
        for step in [{}, { rig.open() }] as [@MainActor () -> Void] {
            step()
            await FramePerf.wait(1.6)
            let rest = rig.director.model.restGeometry
            #expect(glass.maskLayer.path == canvas.layers.path(rest, yDown: false))
            let outside = IslandGlassTests.maskOutside(glass, canvas: IslandGlassTests.canvasSize, expected: rest)
            #expect(outside.outside == 0 && outside.inside > 1000, "\(outside)")
            #expect(glass.pathLayers.allSatisfy { $0.animationKeys() == nil }, "nothing plays at rest")
        }
        for theme in [JuiceTheme.glass, .smoke, .black] {
            canvas.setTheme(theme)
            #expect(canvas.glassView?.backdrop != .window, "\(theme)")
            canvas.setTheme(.solid)
            #expect(canvas.glassView?.backdrop == .window && canvas.layers.fill.fillColor == nil)
            #expect((canvas.glassView?.marksLayer.sublayers ?? []).isEmpty, "no plate of the glass's after \(theme)")
        }
        rig.stop()
    }

    // MARK: Light twins

    /// Settings' light twins: text 4.5:1 and marks 3:1 on the light window, a group and the sidebar; a button's title on
    /// its own fill (P763). The dark twins are today's values (`SettingsDarkIsTodaysTokensExactly`).
    @Test func settingsLightTwinsHold() {
        let window = C.components(SettingsTheme.window, .light)
        let ground = (r: window.r, g: window.g, b: window.b)
        let grounds: [(String, (r: Double, g: Double, b: Double))] = [("window", ground), ("group", C.over(SettingsTheme.group, ground, .light))]
        let words: [(String, Color)] = [("ink", SettingsTheme.ink), ("ink2", SettingsTheme.ink2), ("ink3", SettingsTheme.ink3),
                                        ("amber", SettingsTheme.statusAmber), ("red", SettingsTheme.statusRed),
                                        ("destructive", SettingsTheme.destructive), ("accent", SettingsTheme.accent)]
        var lowest = Double.infinity
        for (place, g) in grounds {
            let l = C.luminance(r: g.r, g: g.g, b: g.b)
            for (name, colour) in words {
                let ratio = C.ratio(C.luminance(colour, .light), l)
                #expect(ratio >= C.text, "\(name) on the \(place): \(ratio)")
                lowest = min(lowest, ratio)
            }
        }
        // The sidebar's labels, on it and on a selected or hovered item.
        let sidebar = C.over(SettingsTheme.sidebar, ground, .light)
        for (name, fill) in [("the sidebar", nil), ("a selected item", SettingsTheme.itemSelected), ("a hovered item", SettingsTheme.itemHover)] as [(String, Color?)] {
            let g = fill.map { C.over($0, sidebar, .light) } ?? sidebar
            let ratio = C.ratio(C.luminance(SettingsTheme.ink, .light), C.luminance(r: g.r, g: g.g, b: g.b))
            #expect(ratio >= C.text, "ink on \(name): \(ratio)")
        }
        // Titles on their own fills.
        for (name, ink, fill) in [("push", SettingsTheme.pushInk, SettingsTheme.push), ("blue", Color.white, SettingsTheme.accent),
                                  ("destructive", Color.white, SettingsTheme.destructive),
                                  ("a segment", SettingsTheme.ink, SettingsTheme.control),
                                  ("the picked segment", SettingsTheme.ink, SettingsTheme.segmentSelected),
                                  ("a field", SettingsTheme.ink, SettingsTheme.field)] {
            let ratio = C.ratio(C.luminance(ink, .light), C.luminance(fill, .light))
            #expect(ratio >= C.text, "\(name): \(ratio)")
        }
        // The sidebar's icons: marks, 3:1 on the light sidebar.
        for pane in SettingsPane.allCases {
            let hex = UInt32(SettingsPaneIcon.colourHex(pane, .light).dropFirst(), radix: 16) ?? 0
            let ratio = C.ratio(C.luminance(Color(hex: hex)), C.luminance(r: sidebar.r, g: sidebar.g, b: sidebar.b))
            #expect(ratio >= C.mark, "\(pane)'s icon: \(ratio)")
            #expect(SettingsPaneIcon.svg(pane, .light).contains(SettingsPaneIcon.cutHex(.light)) || !SettingsPaneIcon.svg(pane).contains("#1C1C1E"),
                    "\(pane): its holes in the light window's grey")
        }
        print("Settings' light twins: lowest text ratio \(String(format: "%.2f", lowest))")
    }

    /// The dark twins are today's values exactly: Settings with Appearance Dark draws what it always drew.
    @Test func settingsDarkIsTodaysTokensExactly() {
        let today: [(Color, Color)] = [
            (SettingsTheme.window, Color(hex: 0x1C1C1E)), (SettingsTheme.ink, Color(hex: 0xEBEBF0)), (SettingsTheme.ink2, Color(hex: 0x98989D)),
            (SettingsTheme.ink3, Color(hex: 0x6C6C70)), (SettingsTheme.control, Color(hex: 0x3A3A3C)),
            (SettingsTheme.segmentSelected, Color(hex: 0x636366)), (SettingsTheme.accent, Color(hex: 0x0A84FF)),
            (SettingsTheme.switchOff, Color(hex: 0x4A4A4E)), (SettingsTheme.push, Color(hex: 0x56565A)),
            (SettingsTheme.destructive, Color(hex: 0xFF4A4A)), (SettingsTheme.statusAmber, Color(hex: 0xFFC16E)),
            (SettingsTheme.statusRed, Color(hex: 0xFF7C75)), (SettingsTheme.field, Color(hex: 0x0F0F11)),
            (SettingsTheme.sidebar, Color.white(0.035)), (SettingsTheme.sidebarStroke, Color.white(0.08)),
            (SettingsTheme.itemHover, Color.white(0.05)), (SettingsTheme.itemSelected, Color.white(0.11)),
            (SettingsTheme.group, Color.white(0.05)), (SettingsTheme.groupStroke, Color.white(0.06)),
            (SettingsTheme.separator, Color.white(0.07)), (SettingsTheme.popupCircle, Color.white(0.10)),
            (SettingsTheme.pushQuiet, Color.white(0.07)), (SettingsTheme.controlEdge, Color.white(0.12)),
            (SettingsTheme.roundHover, Color.white(0.16)), (SettingsTheme.chip, Color.white(0.08)), (SettingsTheme.pushInk, Color.white),
            (WindowTheme.bg, Color(hex: 0x000000)), (WindowTheme.hairline, Color.white(0.08)), (WindowTheme.sectionHeader, Color(hex: 0x86868B)),
            (WindowTheme.popoverBg, Color(hex: 0x1C1C1E)), (WindowTheme.chipEdge, Color.white(0.26)),
            (WindowTheme.iconButtonHover, Color(hex: 0x141414)),
        ]
        for (index, (token, value)) in today.enumerated() {
            #expect(C.components(token, .dark) == C.components(value, .dark), "token \(index)")
        }
        for pane in SettingsPane.allCases { #expect(SettingsPaneIcon.svg(pane, .dark) == SettingsPaneIcon.svg(pane)) }
        #expect(SettingsPaneIcon.svg(.island).contains("#1C1C1E") && SettingsPaneIcon.colourHex(.accounts) == "#FFD60A")
    }

    /// The window's light twins on the white window: words 4.5:1, counts and marks 3:1, on their own fills too (P762).
    @Test func windowLightTwinsHold() {
        let white = 1.0
        for (name, colour, fill, need) in [
            ("filter", WindowTheme.filterText, nil, C.text), ("filter count", WindowTheme.filterCount, nil, C.mark),
            ("picked filter", WindowTheme.filterSelectedText, WindowTheme.filterSelectedBg, C.text),
            ("picked filter count", WindowTheme.filterSelectedCount, WindowTheme.filterSelectedBg, C.text),
            ("section", WindowTheme.sectionHeader, nil, C.text), ("section count", WindowTheme.sectionCount, nil, C.text),
            ("picked segment", WindowTheme.segmentSelectedText, WindowTheme.segmentSelectedBg, C.text),
            ("account name", WindowTheme.accountName, nil, C.text), ("empty", WindowTheme.emptyText, nil, C.text),
            ("icon", WindowTheme.iconButton, nil, C.mark), ("icon hovered", WindowTheme.iconButton, WindowTheme.iconButtonHover, C.mark),
        ] as [(String, Color, Color?, Double)] {
            let ground: (r: Double, g: Double, b: Double) = fill.map { C.over($0, (white, white, white), .light) } ?? (white, white, white)
            let ratio = C.ratio(C.luminance(colour, .light), C.luminance(r: ground.r, g: ground.g, b: ground.b))
            #expect(ratio >= need, "\(name): \(ratio)")
        }
        // The section header reads louder than its count, as on the black.
        #expect(C.luminance(WindowTheme.sectionHeader, .light) < C.luminance(WindowTheme.sectionCount, .light))
    }

    // MARK: The second look

    /// Every provider mark on a ground that follows the Appearance (Settings, the window's header, the account list) takes
    /// the tokens of its look: Codex's own cyan is 1.9:1 on white, so the light look draws its Glass twin; the dark look
    /// keeps Black's cyan (P762, P763).
    @Test func providerMarksTakeTheLooksTokens() throws {
        var bare: [String] = []
        for folder in ["App/SettingsUI", "App/Hooks", "App/Usage"] {
            let url = RenderHarness.root.appendingPathComponent(folder)
            let files = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in text.components(separatedBy: "\n").enumerated() where line.contains("ProviderMarkView(") {
                    if !line.contains("theme:"), !line.contains("tint:") { bare.append("\(file.lastPathComponent):\(index + 1)") }
                }
            }
        }
        #expect(bare.isEmpty, "marks in Black's cyan whatever the look: \(bare)")
        // The window's header, light: the mark's darkest pixel holds a mark's 3:1 on white.
        let env = AppEnvironment.demo()
        let row = try #require(env.usage.codexRow)
        let size = CGSize(width: 40, height: 30)
        let view = UsageBatteryRow(row: row, now: env.usage.now).frame(width: size.width, height: size.height, alignment: .leading)
            .clipped().background(Color.white).environment(\.juiceTheme, JuiceTheme.opaque(.light))
        let ratio = try Self.darkestRatioOnWhite(view, size: size, env: env, columns: 0 ..< 40)
        #expect(ratio >= C.mark, "Codex's mark on the light window: \(ratio)")
    }

    /// The window toolbar's brand glyph in the light look: Glass's finish (the brand's orange at full strength inside
    /// its edge), as the island draws it, so it holds a mark's 3:1 on the white window; the source badge's words, dot and
    /// capsule have their light twins too, and the dark look keeps today's (P762).
    @Test func theToolbarTakesTheLook() throws {
        let env = AppEnvironment.demo()
        let size = CGSize(width: 160, height: 40)
        let view = ToolbarLeading().frame(width: size.width, height: size.height, alignment: .leading)
            .background(Color.white).environment(\.juiceTheme, JuiceTheme.opaque(.light))
        let ratio = try Self.darkestRatioOnWhite(view, size: size, env: env, columns: 0 ..< 320)
        #expect(ratio >= C.mark, "the brand glyph on the light window: \(ratio)")
        // The badge (drawn only by a live switch, never in renders): its words 4.5:1 and its dot 3:1 on its capsule over
        // the white window; on Black, today's colours.
        let light = JuiceTheme.opaque(.light), capsule = C.over(SessionSourceBadge.capsule(light), (1, 1, 1), .light)
        let ground = C.luminance(r: capsule.r, g: capsule.g, b: capsule.b)
        for (kind, mark) in [(SessionSourceBadge.Kind.live, true), (.live, false), (.demo, false), (.problem, false)] {
            let ratio = C.ratio(C.luminance(SessionSourceBadge.colour(kind, light, mark: mark), .light), ground)
            #expect(ratio >= (mark ? C.mark : C.text), "\(kind) \(mark ? "dot" : "word"): \(ratio)")
        }
        #expect(C.components(SessionSourceBadge.colour(.demo, .black), .dark) == C.components(IslandTheme.ink2, .dark))
        #expect(C.components(SessionSourceBadge.colour(.problem, .black), .dark) == C.components(Color(hex: 0xFFC16E), .dark))
        #expect(C.components(SessionSourceBadge.capsule(.black), .dark) == C.components(Color.white(0.08), .dark))
    }

    /// Solid's island casts no shadow on Core Animation's outline: its window is exactly the outline at rest (P36), so a
    /// shadow past the outline would be cut at the window's edges and show only as wedges under the ears (P774).
    @Test func solidsIslandCastsNoShadowItsWindowWouldCut() async throws {
        _ = NSApplication.shared
        let rig = await IslandGlassTests.rig(.coreAnimation, theme: .solid)
        let canvas = rig.canvas
        for step in [{}, { rig.open() }] as [@MainActor () -> Void] {
            step()
            await FramePerf.wait(1.6)
            let ours = Self.flatten(canvas.surfaceView?.root) + Self.flatten(canvas.glassView?.layer)
            let casting = ours.filter { $0.shadowOpacity > 0 }.map { $0.name ?? "unnamed" }
            #expect(casting.isEmpty, "\(casting)")
        }
        rig.stop()
    }

    /// Solid's hairline reaches its full strength within the top bar's 24 pt pill, so the light island keeps its edge
    /// against a light menu bar on both outlines, closed as opened (P774).
    @Test func solidsHairlineIsFullOnTheClosedPill() {
        let edge = SolidLook.islandEdge
        #expect((edge.reach ?? 0) <= IslandTheme.Metrics.topBarFallbackHeight / 3 && edge.bottom == 1, "\(edge)")
    }

    /// The sidebar's icons hold a mark's 3:1 on the selected item too, not only on the plain sidebar (P763).
    @Test func sidebarIconsHoldOnTheSelectedItem() {
        let window = C.components(SettingsTheme.window, .light)
        let sidebar = C.over(SettingsTheme.sidebar, (window.r, window.g, window.b), .light)
        for (place, fill) in [("selected", SettingsTheme.itemSelected), ("hovered", SettingsTheme.itemHover)] {
            let g = C.over(fill, sidebar, .light)
            for pane in SettingsPane.allCases {
                let hex = UInt32(SettingsPaneIcon.colourHex(pane, .light).dropFirst(), radix: 16) ?? 0
                let ratio = C.ratio(C.luminance(Color(hex: hex)), C.luminance(r: g.r, g: g.g, b: g.b))
                #expect(ratio >= C.mark, "\(pane)'s icon on the \(place) item: \(ratio)")
            }
        }
    }

    /// The shortcut field has a ground of its own in each look: a little darker than the group where it is light, a
    /// little lighter where it is dark (P763).
    @Test(arguments: [ColorScheme.light, .dark])
    func theKeyFieldHasAGround(_ scheme: ColorScheme) async throws {
        // Hosted, as Settings hosts it: the recorder's key catcher is an AppKit view, which an image renderer cannot draw.
        let size = CGSize(width: 150, height: 24)
        let stage = LookStage(root: AnyView(KeyRecorder(storage: .constant(nil)).frame(width: size.width, height: size.height, alignment: .leading)
            .background(SettingsTheme.group).background(SettingsTheme.window)), size: size)
        stage.system(scheme)
        await FramePerf.wait(0.1)
        let luma = { (c: (r: Double, g: Double, b: Double)) in C.luminance(r: c.r, g: c.g, b: c.b) }
        let inside = try luma(stage.colour(at: CGPoint(x: 4, y: 12))), outside = try luma(stage.colour(at: CGPoint(x: 145, y: 12)))
        #expect(scheme == .light ? inside < outside - 0.02 : inside > outside + 0.005, "\(scheme): field \(inside), group \(outside)")
    }

    /// The help lines say no more than is true: Black and Smoke keep the window and the panel dark too, and Solid takes
    /// the wallpaper's tint only where it is dark (macOS 27 tints no light window).
    @Test func theHelpLinesHold() {
        #expect(GeneralPaneText.appearance == "Black and Smoke stay dark.")
        let note = IslandPaneText.themeNote(.solid) ?? ""
        #expect(note.contains("Appearance") && note.contains("Dark takes the wallpaper"), "\(note)")
    }

    /// What's New's blue is the dark static it was, which Glass's tone nudges for each look: an adaptive twin would be
    /// read through its light side, moving Glass in Dark (P762).
    @Test func whatsNewsBlueIsTodays() {
        let blue = C.components(WhatsNewCard.blue, .light), today = C.components(Color(hex: 0x0A84FF), .light)
        #expect(blue == today, "\(blue)")
    }

    /// Glass's pin, in the source: a bare `glassEffect` already hands its content the environment's scheme offscreen, so
    /// `glassContentTakesTheAppearancesLook` guards the look but cannot see the pin go; this sees it go (P764).
    @Test func theGlassPinIsInTheSource() throws {
        let source = try String(contentsOf: RenderHarness.root.appendingPathComponent("App/Theme/GlassSurface.swift"), encoding: .utf8)
        let start = try #require(source.range(of: "struct InGlass<S: Shape>: ViewModifier {"))
        let body = source[start.upperBound...].prefix(2000)
        #expect(body.components(separatedBy: "content.environment(\\.colorScheme, look).glassEffect(.regular, in:").count == 3)
    }

    /// The widget's snapshot carries the Appearance, so Solid's widget takes the look the island and the panel take
    /// (P777).
    @Test func theWidgetCarriesTheAppearance() throws {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = .solid
        settings.appearance = .dark
        let snapshot = WidgetSnapshot.make(.demo(settings: settings), at: Date(timeIntervalSince1970: 0))
        let json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        #expect(json["appearance"] as? String == "dark", "\(json.keys.sorted())")
        // The widgets themselves follow the system's widgets since wave A5, whatever the theme (P1224); the file still
        // carries the pin, under Solid only.
        for theme in [JuiceTheme.black, .glass, .smoke] {
            #expect(WidgetSnapshot.closed(at: .now, theme: theme, appearance: .dark).appearance == nil)
        }
        // An older file has none: System. A new pin reloads the widget at once.
        var older = snapshot
        older.appearance = nil
        #expect(older.appearanceChoice == .system && older.urgentKey != snapshot.urgentKey)
    }

    // MARK: Helpers

    /// The contrast with white of the darkest pixel `view` draws in `columns` (device pixels at 2x) in the light look.
    static func darkestRatioOnWhite<V: View>(_ view: V, size: CGSize, env: AppEnvironment, columns: Range<Int>) throws -> Double {
        let pixels = try AppearanceRenders.bitmap(view, size: size, env: env, scheme: .light)
        let width = Int(size.width * 2), height = Int(size.height * 2)
        var darkest = 1.0
        for y in 0 ..< height {
            for x in columns where x < width {
                let i = (y * width + x) * 4
                darkest = min(darkest, C.luminance(r: Double(pixels[i]) / 255, g: Double(pixels[i + 1]) / 255, b: Double(pixels[i + 2]) / 255))
            }
        }
        return C.ratio(1, darkest)
    }

    /// `colour`'s red component (0 to 1) as AppKit resolves it in `scheme`.
    static func resolve(_ colour: NSColor, _ scheme: ColorScheme) -> Double {
        var red: CGFloat = -1
        NSAppearance.named(scheme)?.performAsCurrentDrawingAppearance {
            red = colour.usingColorSpace(.sRGB)?.redComponent ?? -1
        }
        return Double(red)
    }

    static func flatten(_ layer: CALayer?) -> [CALayer] {
        guard let layer else { return [] }
        return [layer] + (layer.sublayers ?? []).flatMap(flatten)
    }
}

/// A view hosted offscreen (a window never ordered in) between two stand-ins: the window for macOS's own appearance
/// (`system`) and its content view for the app's (`app`, the target of `AppAppearance`).
@MainActor
final class LookStage {
    let window: NSWindow
    let app = NSView()
    let host: NSHostingView<AnyView>

    init(root: AnyView, size: CGSize) {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: root)
        app.frame = CGRect(origin: .zero, size: size)
        host.frame = app.bounds
        app.addSubview(host)
        window.contentView = app
        system(.dark)
    }

    /// macOS's mode, as the window stands in for it.
    func system(_ scheme: ColorScheme) { window.appearance = NSAppearance.named(scheme) }

    /// The colour at `point` (points from the top left) of the hosting view as it draws now.
    func colour(at point: CGPoint) throws -> (r: Double, g: Double, b: Double) {
        host.layoutSubtreeIfNeeded()
        let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let c = try #require(rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(.sRGB))
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
}

@MainActor
final class SchemeBox {
    var seen: [String: ColorScheme] = [:]
}

/// Draws nothing; keeps the colour scheme it is drawn in.
struct SchemeReader: View {
    let box: SchemeBox
    let key: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .onChange(of: scheme, initial: true) { _, new in box.seen[key] = new }
    }
}
