import AppKit
import Foundation
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Theme (P520 to P529): the setting, the palettes (Black exactly as it was), the environment the roots set, the glass
/// surface (fail closed, its stand-in, Reduce Transparency and Increase Contrast), its AppKit twin, and the widget's copy
/// of the theme. Legibility on the three backdrops is `ThemeContrastTests`.
@MainActor
@Suite(.serialized)
struct ThemeTests {
    // MARK: The setting

    @Test func blackIsTheDefaultAndAnUnknownChoiceReadsAsBlack() throws {
        #expect(AppSettings.ephemeral().juiceTheme == .black)
        // The picker's order: Black · Glass · Smoke · Solid.
        #expect(JuiceTheme.allCases == [.black, .glass, .smoke, .solid]
            && JuiceTheme.allCases.map(\.title) == ["Black", "Glass", "Smoke", "Solid"])
        let suite = "theme-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppSettings(defaults: defaults).juiceTheme == .black)
        let settings = AppSettings(defaults: defaults)
        settings.juiceTheme = .glass
        #expect(defaults.string(forKey: AppSettings.Key.juiceTheme) == "glass")
        #expect(AppSettings(defaults: defaults).juiceTheme == .glass)
        settings.juiceTheme = .smoke
        #expect(defaults.string(forKey: AppSettings.Key.juiceTheme) == "smoke")
        #expect(AppSettings(defaults: defaults).juiceTheme == .smoke)
        defaults.set("frost", forKey: AppSettings.Key.juiceTheme)
        #expect(AppSettings(defaults: defaults).juiceTheme == .black)
        #expect(JuiceTheme(stored: nil) == .black && JuiceTheme(stored: "") == .black && JuiceTheme(stored: "Glass") == .black)
    }

    /// The migration (P564): the smoked glass's build wrote "glass", and the owner asked for that choice to become glass
    /// without black, so "glass" reads as today's Glass and keeps being written as "glass"; Smoke is the new word, which
    /// an older build reads as Black (as any word it does not know), never as a crash or a stale look.
    @Test func aStoredGlassIsTodaysGlassAndSmokeIsNew() throws {
        let suite = "theme-migration-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("glass", forKey: AppSettings.Key.juiceTheme)
        let settings = AppSettings(defaults: defaults)
        #expect(settings.juiceTheme == .glass && settings.juiceTheme.adapts && settings.juiceTheme.knocksOut)
        #expect(defaults.string(forKey: AppSettings.Key.juiceTheme) == "glass", "reading never rewrites it")
        #expect(JuiceTheme.smoke.knocksOut && !JuiceTheme.smoke.adapts && !JuiceTheme.black.knocksOut && !JuiceTheme.black.adapts)
        // Glass's palettes are the adapting ones; Smoke's are the smoked glass's, as Glass's were until now.
        #expect(JuiceTheme.glass.island.adapts && JuiceTheme.glass.panel.adapts)
        #expect(!JuiceTheme.smoke.island.adapts && JuiceTheme.smoke.island.bg == Color.black.opacity(GlassStyle.island.floor))
        // An older build's reading of each word: its `init(stored:)` knew black and glass only.
        let older: (String?) -> String = { stored in ["black", "glass"].contains(stored ?? "") ? stored! : "black" }
        #expect(older(JuiceTheme.smoke.rawValue) == "black" && older(JuiceTheme.glass.rawValue) == "glass")
    }

    // MARK: The palettes

    /// Black is today's island and panel, token for token: a view that moves from `IslandTheme.x` to `palette.x` draws
    /// the same pixels in Black.
    @Test func blackIsTodaysTokensExactly() {
        let p = IslandPalette.black
        let pairs: [(Color, Color)] = [
            (p.bg, IslandTheme.bg), (p.card, IslandTheme.card), (p.ink, IslandTheme.ink), (p.ink2, IslandTheme.ink2),
            (p.ink3, IslandTheme.ink3), (p.idleMark, IslandTheme.idleMark), (p.headerIcon, IslandTheme.headerIcon),
            (p.headerIconRest, IslandTheme.headerIconRest), (p.statusClean, IslandTheme.statusClean),
            (p.statusDetailed, IslandTheme.statusDetailed), (p.you, IslandTheme.you), (p.rowAge, IslandTheme.rowAge),
            (p.toolVerb, IslandTheme.toolVerb), (p.toolLine, IslandTheme.toolLine), (p.jump, IslandTheme.jump),
            (p.footer, IslandTheme.footer), (p.footerHover, IslandTheme.footerHover), (p.message, IslandTheme.message),
            (p.groupCount, IslandTheme.groupCount), (p.kbd, IslandTheme.kbd), (p.fieldPlaceholder, IslandTheme.fieldPlaceholder),
            (p.codeText, IslandTheme.codeText), (p.codeComment, IslandTheme.codeComment), (p.sendText, IslandTheme.sendText),
            (p.line, IslandTheme.line), (p.usageHairline, IslandTheme.usageHairline), (p.rowHoverStroke, IslandTheme.rowHoverStroke),
            (p.codeBorder, IslandTheme.codeBorder), (p.fieldBorder, IslandTheme.fieldBorder),
            (p.fieldHoverBorder, IslandTheme.fieldHoverBorder), (p.islandHover, IslandTheme.islandHover),
            (p.rowHover, IslandTheme.rowHover), (p.button, IslandTheme.button), (p.codeBg, IslandTheme.codeBg),
            (p.fieldBg, IslandTheme.fieldBg), (p.fieldHoverBg, IslandTheme.fieldHoverBg), (p.groupBg, IslandTheme.groupBg),
            (p.send, IslandTheme.send),
            // The cards' (the island lane): what the cards drew.
            (p.buttonHover, Color(hex: 0x2A2A2D)), (p.sendHover, Color(hex: 0x222222)), (p.optionBg, CardTheme.optionBg),
            (p.optionHover, CardTheme.optionHover), (p.optionSelected, CardTheme.optionSelected), (p.optionBadge, CardTheme.optionBadge),
            (p.optionBadgeText, CardTheme.optionBadgeText), (p.optionSub, CardTheme.optionSub), (p.cardKbd, CardTheme.kbd),
            (p.reason, CardTheme.reason), (p.diffContext, CardTheme.diffContext), (p.optionChevron, IslandTheme.optionChevron),
            // A Done card's message (wave 6): what `DoneMessageView` drew.
            (p.messageCodeBox, MessageTheme.codeBox), (p.messageRule, MessageTheme.rule),
            // What Black's views drew straight from their statics (P563).
            (p.pillCount, Color.white), (p.topBarIdle, Color(hex: 0xE9EAEE)), (p.primary, IslandTheme.primary),
            (p.primaryHover, Color.white), (p.primaryText, IslandTheme.primaryText), (p.kbdOnPrimary, IslandTheme.kbdOnPrimary),
            (p.sendActive, IslandTheme.sendActive), (p.sendActiveInk, Color.black), (p.optionTitle, CardTheme.optionTitle),
            (p.optionBadgeSelectedText, Color.black), (p.diffAdded, CardTheme.diffAdded), (p.diffRemoved, CardTheme.diffRemoved),
            (p.diffAddedFill, CardTheme.diffAddedFill), (p.diffRemovedFill, CardTheme.diffRemovedFill), (p.link, MessageTheme.link),
            (p.messageHeader, MessageTheme.header), (p.selectionRing, SelectionMark.ring),
            (p.holdOnPrimary, Color.black.opacity(0.24)), (p.holdOnField, Color.white.opacity(0.3)), (p.hoverRing, Color.white(0.35)),
        ]
        for (index, pair) in pairs.enumerated() { #expect(pair.0 == pair.1, "token \(index)") }
        #expect(p.tagHost == IslandTheme.tagHost && p.tagTime == IslandTheme.tagTime && p.tagJump == IslandTheme.tagJump)
        // Every stored token is in the list above: a new one must be added there too (and `adapts`, false).
        #expect(Mirror(reflecting: p).children.count == pairs.count + 3 + 1 && !p.adapts)
        // A picked option's edge and badge: under Orange what the cards drew, the waiting orange at 40 % and in full.
        let orange = Color(hex: 0xE97B36)
        #expect(p.optionSelectedBorder(.orange) == orange.opacity(0.4) && p.optionBadgeSelected(.orange) == orange)
        for needsYou in NeedsYouColour.allCases {
            #expect(p.optionSelectedBorder(needsYou) == needsYou.wait.opacity(0.4) && p.optionBadgeSelected(needsYou) == needsYou.wait)
        }
        // Black's tones are the colours themselves.
        for colour in [IslandTheme.run, NeedsYouColour.pink.wait, NeedsYouColour.violet.wait, NeedsYouColour.orange.wait, IslandTheme.done,
                       IslandTheme.delegate, IslandTheme.agentClaude, IslandTheme.agentCodex] {
            #expect(p.tone(colour) == colour && p.toneText(colour) == colour && IslandPalette.smoke.tone(colour) == colour)
        }
        let q = PanelPalette.black
        #expect(q.surface == Theme.surface && q.ink == Theme.ink && q.ink2 == Theme.ink2 && q.track == Theme.track
            && q.line == Theme.line && q.divider == Theme.divider && q.edge == Theme.edge)
        #expect(Mirror(reflecting: q).children.count == 8 && !q.adapts)
        #expect(JuiceTheme.black.island == .black && JuiceTheme.black.panel == .black)
        #expect(JuiceTheme.glass.island == .glass && JuiceTheme.glass.panel == .glass)
        #expect(JuiceTheme.smoke.island == .smoke && JuiceTheme.smoke.panel == .smoke)
    }

    // MARK: The environment

    /// Views read the theme, a one-byte `@Entry`, and take their palette from it (P559): a computed key path
    /// (`\.islandPalette`, `\.panelPalette`) is read again and compared, all of its ~60 colours, for every reading view
    /// whenever anything in the environment changes, which cost Black's usage fold 1.3 ms of its heavy frame. A
    /// tripwire over the sources, as `SettingsConsumerTests`.
    @Test func viewsReadTheThemeNeverAComputedPalette() throws {
        let root = SettingsConsumerTests.root
        var reads: [String] = []
        for folder in ["App", "Widget"] {
            let url = root.appendingPathComponent(folder)
            guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in files where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                where line.contains("\\.islandPalette") || line.contains("\\.panelPalette") || line.contains("var islandPalette")
                    || line.contains("var panelPalette") {
                    reads.append("\(file.lastPathComponent):\(index + 1)")
                }
            }
        }
        #expect(reads.isEmpty, "\(reads.count): \(reads.prefix(8))")
    }

    /// Nothing sets the theme unless asked: a view reads Black; a root with `juiceThemeFromSettings()` reads the setting.
    @Test func theRootsTakeTheThemeFromTheSetting() throws {
        let box = ThemeBox()
        _ = try RenderHarness.hostedBitmap(ThemeProbe(box: box), "theme-probe", size: CGSize(width: 10, height: 10))
        #expect(box.seen == .black)
        let env = AppEnvironment.demo()
        env.settings.juiceTheme = .glass
        _ = try RenderHarness.hostedBitmap(ThemeProbe(box: box).juiceThemeFromSettings(), "theme-probe", size: CGSize(width: 10, height: 10), env: env)
        #expect(box.seen == .glass)
        #expect(box.palette == .glass)
    }

    // MARK: The glass surface

    /// Black draws exactly what the surfaces drew before: the shape filled with the pure black.
    @Test func aThemedSurfaceInBlackIsTheBlackFill() throws {
        for shape in [AnyShape(PillShape()), AnyShape(IslandShape()), AnyShape(RoundedRectangle(cornerRadius: Theme.Panel.radius))] {
            let size = CGSize(width: 160, height: 60)
            let before = try Self.pixels(Color.clear.frame(width: 140, height: 44).background(shape.fill(IslandTheme.bg)).padding(8), size: size)
            let after = try Self.pixels(Color.clear.frame(width: 140, height: 44).themedSurface(shape).padding(8), size: size)
            #expect(before.data == after.data)
        }
    }

    /// Nothing a glass surface draws (glass, floor, rim) lands outside its shape (P523): every pixel a point or more
    /// outside the outline is untouched.
    @Test func glassNeverDrawsPastItsOutline() throws {
        let size = CGSize(width: 200, height: 80), rect = CGRect(x: 20, y: 0, width: 160, height: 33)
        for shape in [AnyShape(PillShape()), AnyShape(IslandShape()), AnyShape(RoundedRectangle(cornerRadius: 12))] {
            for reduce in [false, true] {
                for contrast in [ColorSchemeContrast.standard, .increased] {
                    let view = GlassSurfaceBody(shape: shape, style: .island, rendering: .standIn, reduceTransparency: reduce, contrast: contrast)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .frame(width: size.width, height: size.height, alignment: .topLeading)
                    let pixels = try Self.pixels(view, size: size)
                    let path = shape.path(in: rect)
                    var stray = 0
                    for y in 0..<pixels.height {
                        for x in 0..<pixels.width where pixels.rgba(x, y).a > 0 {
                            let p = CGPoint(x: (CGFloat(x) + 0.5) / 2, y: (CGFloat(y) + 0.5) / 2)
                            let near = [-1.0, 0, 1].contains { dx in [-1.0, 0, 1].contains { dy in path.contains(CGPoint(x: p.x + dx, y: p.y + dy)) } }
                            if !near { stray += 1 }
                        }
                    }
                    #expect(stray == 0, "\(shape) reduce \(reduce) \(contrast): \(stray) pixels outside")
                }
            }
        }
    }

    /// Reduce Transparency: no glass and no floor, the style's opaque solid; Increase Contrast: the heavier floor and an
    /// even rim.
    @Test func reduceTransparencyIsSolidAndIncreaseContrastIsDarker() throws {
        let size = CGSize(width: 120, height: 60)
        func centre(_ reduce: Bool, _ contrast: ColorSchemeContrast) throws -> (r: Double, g: Double, b: Double, a: Double) {
            let view = GlassStage(backdrop: .white) {
                GlassSurfaceBody(shape: Rectangle(), style: .island, rendering: .standIn, reduceTransparency: reduce, contrast: contrast)
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
            return try Self.pixels(view, size: size).rgba(120, 60)
        }
        let solid = try centre(true, .standard), solidComponents = GlassContrast.components(GlassStyle.island.solid)
        #expect(abs(solid.r - solidComponents.r) < 0.01 && abs(solid.g - solidComponents.g) < 0.01 && solid.a == 1)
        let standard = try centre(false, .standard), increased = try centre(false, .increased)
        // Over white, the floor alone: 1 - 0.82 and 1 - 0.9.
        #expect(abs(standard.r - (1 - GlassStyle.island.floor)) < 0.01, "\(standard)")
        #expect(abs(increased.r - (1 - GlassStyle.island.floorIncreased)) < 0.01, "\(increased)")
        #expect(GlassStyle.island.edge(.increased).top == GlassStyle.island.edge(.increased).bottom)
        #expect(GlassStyle.island.edge(.increased).top >= 0.4)
    }

    /// The stand-in shows the backdrop behind it, blurred, where the surface is: the busy backdrop's colours come through,
    /// dimmed by the floor, and differ from place to place.
    @Test func theStandInShowsItsOwnPartOfTheBackdrop() throws {
        let size = CGSize(width: 400, height: 120)
        let view = GlassStage(backdrop: .busy) {
            HStack(spacing: 40) {
                Color.clear.frame(width: 120, height: 60).glassSurface(in: Rectangle())
                Color.clear.frame(width: 120, height: 60).glassSurface(in: Rectangle())
            }
            .padding(20)
        }
        .frame(width: size.width, height: size.height)
        let pixels = try Self.pixels(view, size: size)
        let left = pixels.rgba(2 * 80, 2 * 50), right = pixels.rgba(2 * 240, 2 * 50)
        #expect(max(left.r, left.g, left.b) <= 1 - GlassStyle.island.floor + 0.01)
        #expect(max(right.r, right.g, right.b) <= 1 - GlassStyle.island.floor + 0.01)
        #expect(abs(left.r - right.r) + abs(left.g - right.g) + abs(left.b - right.b) > 0.02, "\(left) \(right)")
        #expect(max(left.r, left.g, left.b) > 0.02)
    }

    // MARK: The AppKit glass

    @Test func theAppKitGlassIsBornMaskedAndKeepsItsMask() throws {
        for backdrop in [GlassSurfaceNSView.Backdrop.glass, .visualEffect, .solid, .rimOnly, .window] {
            let view = GlassSurfaceNSView(style: .island, backdrop: backdrop, increaseContrast: false)
            view.frame = CGRect(x: 0, y: 0, width: 200, height: 40)
            view.layoutSubtreeIfNeeded()
            #expect(view.layer?.mask === view.maskLayer)
            #expect(view.pathLayers.allSatisfy { $0.path?.isEmpty ?? false }, "born with nothing to show")
            switch backdrop {
            case .glass: #expect(view.effectView is NSGlassEffectView)
            case .visualEffect: #expect(view.effectView is NSVisualEffectView)
            case .window:
                // Solid: the window material, behind the window, always active (P770).
                let effect = try #require(view.effectView as? NSVisualEffectView)
                #expect(effect.material == .windowBackground && effect.blendingMode == .behindWindow && effect.state == .active)
            case .solid, .rimOnly: #expect(view.effectView == nil)
            }
            if backdrop == .rimOnly || backdrop == .window {
                // Glass: no glass and no floor of its own, never black; the rim alone, on the window's appearance. Solid:
                // the material and no floor, in the window's appearance too.
                #expect(view.floorLayer.fillColor == nil && view.appearance == nil)
            } else {
                let floorAlpha = view.floorLayer.fillColor?.alpha ?? 0
                #expect(abs(floorAlpha - (backdrop == .solid ? 1 : GlassStyle.island.floor)) < 0.001)
            }

            let path = NotchSurfaceShape.filling(CGRect(x: 10, y: 0, width: 180, height: 33), ear: 3, radius: 12.5).cgPath
            view.setPath(path)
            #expect(view.pathLayers.allSatisfy { $0.path == path })
            let animation = CAKeyframeAnimation(keyPath: "path")
            animation.values = [path, path]
            view.addPathAnimation(animation, forKey: "outline")
            #expect(view.pathLayers.allSatisfy { $0.animation(forKey: "outline") != nil })
            view.removePathAnimations(forKey: "outline")
            #expect(view.pathLayers.allSatisfy { $0.animation(forKey: "outline") == nil })

            view.layer?.mask = nil
            #expect(!view.isSound)
            #expect(!view.ensure())
            #expect(view.isSound && view.layer?.mask === view.maskLayer)
            #expect(view.ensure())
            #expect(view.hitTest(CGPoint(x: 50, y: 10)) == nil)
        }
        #expect(GlassSurfaceNSView.Backdrop.preferred(reduceTransparency: true) == .solid)
        #expect(GlassSurfaceNSView.Backdrop.preferred(reduceTransparency: false) == .glass)
        let contrast = GlassSurfaceNSView(style: .island, backdrop: .glass, increaseContrast: true)
        #expect(abs((contrast.floorLayer.fillColor?.alpha ?? 0) - GlassStyle.island.floorIncreased) < 0.001)
    }

    // MARK: The widget

    @Test func theThemeTravelsToTheWidgetAndAnOlderFileReadsAsBlack() throws {
        let settings = AppSettings.ephemeral()
        #expect(WidgetSnapshot.make(.demo(settings: settings, sessions: .allStates), at: DemoClock.now).juiceTheme == .black)
        settings.juiceTheme = .glass
        let snapshot = WidgetSnapshot.make(.demo(settings: settings, sessions: .allStates), at: DemoClock.now)
        #expect(snapshot.theme == "glass" && snapshot.juiceTheme == .glass)
        let read = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(read.juiceTheme == .glass)
        // An older build's file has no theme; a later build's may name one this build does not know.
        var older = snapshot
        older.theme = nil
        let data = try JSONEncoder().encode(older)
        #expect(!(String(data: data, encoding: .utf8) ?? "").contains("theme"))
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data).juiceTheme == .black)
        older.theme = "frost"
        #expect(older.juiceTheme == .black)
        older.theme = "smoke"
        #expect(older.juiceTheme == .smoke)
        // Quit keeps the theme, so a glass widget says "Not running" on glass.
        #expect(WidgetSnapshot.closed(at: DemoClock.now, theme: .glass).juiceTheme == .glass)
        #expect(WidgetSnapshot.closed(at: DemoClock.now).juiceTheme == .black)
        // A new theme reloads the widget at once: the owner just picked it.
        #expect(snapshot.urgentKey != WidgetSnapshot.make(.demo(sessions: .allStates), at: DemoClock.now).urgentKey)
    }

    @Test func theFeedReloadsAtOnceForANewTheme() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("theme-widget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: DemoClock.now),
                                 sessions: DStub(rows: [DStub.row("run", .codex, .running)]))
        let reloads = ReloadCounter()
        let feed = WidgetFeed(env: env, store: store, clock: { DemoClock.now }, reload: { reloads.bump($0) })
        feed.start()
        feed.drain()
        #expect(reloads.of(.sessions) == 1 && store.read()?.juiceTheme == .black)
        env.settings.juiceTheme = .glass
        for _ in 0..<100 where feed.last?.juiceTheme != .glass { try await Task.sleep(for: .milliseconds(10)) }
        feed.drain()
        #expect(store.read()?.juiceTheme == .glass)
        #expect(reloads.of(.sessions) == 2, "within the floor, and still at once")
        // Liquid's running look is followed by itself too (P388, P525), not only with the next other change.
        env.settings.liquidRunning = .full
        for _ in 0..<100 where feed.last?.liquidRunning != "full" { try await Task.sleep(for: .milliseconds(10)) }
        #expect(feed.last?.liquidRunning == "full")
        feed.stop()
        #expect(store.read()?.appRunning == false && store.read()?.juiceTheme == .glass)
    }

    // MARK: Helpers

    struct Pixels {
        var width: Int
        var height: Int
        var data: [UInt8]

        /// sRGB, 0 to 1, un-premultiplied.
        func rgba(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            let a = Double(data[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Double(data[i]) / 255 / a, Double(data[i + 1]) / 255 / a, Double(data[i + 2]) / 255 / a, a)
        }
    }

    /// `view` at 2x, in sRGB bytes (y down).
    static func pixels<V: View>(_ view: V, size: CGSize) throws -> Pixels {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .dark).environment(\.glassRendering, .standIn))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        data.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return Pixels(width: width, height: height, data: data)
    }
}

@MainActor
final class ThemeBox {
    var seen: JuiceTheme?
    var palette: IslandPalette?
}

/// Records the theme and palette it is drawn in.
private struct ThemeProbe: View {
    let box: ThemeBox
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        box.seen = theme
        box.palette = theme.island
        return Color.clear
    }
}
