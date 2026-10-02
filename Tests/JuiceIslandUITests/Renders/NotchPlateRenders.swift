import AppKit
import CoreGraphics
import Foundation
import IslandHookNotes
import QuartzCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// The island where it meets the hardware notch (P790 to P796; the owner's screenshot of 2026-10-01): Solid and Glass,
/// light and dark, closed and opened, on both outlines, State tint on and the pill leading with a delegate (teal), each
/// as a screenshot shows it (`-shot`) and with a model of the hardware notch drawn over it (`-notch`: black, 4 pt flares
/// at the top and 8 pt bottom corners at a 32 pt notch, `hardwareNotch`), which is what the owner sees on the built-in
/// display. Black and Smoke too, dark, to hold them unchanged. Both outlines through `CARenderer` with the live glass
/// and materials (SwiftUI's from a hosting view, Core Animation's from the live rig in a window never ordered in), over
/// a wallpaper that changes only down the screen, so the two compose alike. Written to `$JI_NOTCH_OUT/<phase>`
/// (`JI_NOTCH_PHASE`, `after` unless set); skipped unless `JI_NOTCH_OUT` is set. `sheet` lays them out, the owner's case
/// first, before and after.
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["JI_NOTCH_OUT"] != nil))
struct NotchPlateRenders {
    static let notch = IslandTheme.Metrics.referenceNotch
    static let menuBar = IslandTheme.Metrics.referenceMenuBar
    static let openSize = CGSize(width: 540, height: 250)
    static let closedSize = CGSize(width: 300, height: 50)

    static var out: URL {
        let env = ProcessInfo.processInfo.environment
        return URL(fileURLWithPath: env["JI_NOTCH_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
    }

    static var phase: String { ProcessInfo.processInfo.environment["JI_NOTCH_PHASE"] ?? "after" }

    enum Outline: String, CaseIterable { case su, ca }

    // MARK: The hardware notch, modelled

    /// The hardware notch as public measurements give it (NotchBay, measured on a 14-inch MacBook Pro with the screen's
    /// own safe area: "roughly 4 pt at the top and 8 pt at the bottom"), scaled with the notch's height: the auxiliary
    /// areas' gap wide, concave flares into the screen's top edge outside it, rounded bottom corners.
    static func hardwareNotch(_ notch: CGSize) -> some View {
        let flare = 4 * notch.height / 32, radius = 8 * notch.height / 32
        return NotchSurfaceShape(geometry: SurfaceGeometry(width: notch.width + 2 * flare, height: notch.height, ear: flare, radius: radius))
            .fill(.black)
            .frame(width: notch.width + 2 * flare, height: notch.height)
    }

    /// A wallpaper that changes only down the screen (so a render of the panel alone and of the whole stage line up), and
    /// the menu bar's band over it.
    static func backdrop(_ look: ColorScheme) -> some View {
        let light = look == .light
        // The gradient is as tall whatever the frame, so a point's colour depends on its depth alone.
        return Color.clear.overlay(alignment: .top) {
            ZStack(alignment: .top) {
                LinearGradient(colors: light ? [Color(hex: 0xC9D6DF), Color(hex: 0x9FB4C2)] : [Color(hex: 0x233040), Color(hex: 0x0F151C)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 600)
                Rectangle().fill(light ? Color.white.opacity(0.55) : Color.black.opacity(0.28)).frame(height: menuBar)
            }
        }
        .clipped()
    }

    // MARK: The scene

    /// The owner's case: two chats waiting on their agents and two finished, so nothing runs or needs you and the pill
    /// leads with the delegate (State tint's teal).
    static func feed(_ engine: SessionEngine, now: Date) {
        SubagentWaitScene.waiting(engine, "np-parser", title: "Claude · parser", project: "parser", prompt: "map the parser and fix the grammar",
                                  agents: ["a1"], at: now - 420)
        SubagentWaitScene.waiting(engine, "np-docs", title: "Claude · docs", project: "docs", prompt: "check every page for broken links",
                                  agents: ["b1", "b2"], at: now - 900)
        let done: [(String, String, String, String, TimeInterval)] = [
            ("np-notes", "notes", "tidy the release notes", "Tidied the notes into three sections.", 1_500),
            ("np-icons", "icons", "redraw the menu bar icon", "Redrew the icon at 16 and 32 pt.", 2_400),
        ]
        for (id, project, prompt, reply, ago) in done {
            engine.loadPreviewEvents(FixtureSessionFeed.start(id, title: "Claude · \(project)", project: project, prompt: prompt, at: now - ago)
                + [.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(sessionID: id, claudeMetadata: ClaudeSessionMetadata(
                    lastUserPrompt: prompt, lastAssistantMessage: reply), timestamp: now - ago + 200)),
                   .sessionCompleted(SessionCompleted(sessionID: id, summary: reply, timestamp: now - ago + 200))])
        }
    }

    static func settings(glyph: GlyphStyle = .pixel) -> AppSettings {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.glyphStyle = glyph
        return settings
    }

    /// `idle`: no sessions, so the closed island is the notch alone. `glyph`: Liquid and Sand draw the pill's edge line
    /// (Pill edge line is on by default).
    static func environment(idle: Bool = false, glyph: GlyphStyle = .pixel) -> AppEnvironment {
        let now = DemoClock.now
        let engine = SessionEngine.preview(clock: { now })
        if !idle { feed(engine, now: now) }
        return AppEnvironment(settings: settings(glyph: glyph), usage: DemoUsageModel(now: now),
                              sessions: EngineSessionsModel(engine: engine, clock: { now }))
    }

    // MARK: Rendering

    /// SwiftUI's outline: the root on the wallpaper at `size`, the live glass and materials, through `CARenderer`.
    static func swiftUIs(theme: JuiceTheme, look: ColorScheme, open: Bool, idle: Bool = false, glyph: GlyphStyle = .pixel,
                         size: CGSize) throws -> CGImage {
        let env = environment(idle: idle, glyph: glyph)
        #expect(idle || PillLead.make(rows: env.sessions.rows, recentlyFinished: nil)?.state == .delegating)
        let ui = IslandGlassRenders.state(env, surface: open ? .island : .closed)
        let island = IslandSize.standard
        let root = ZStack(alignment: .top) {
            backdrop(look)
            IslandRootView(ui: ui, notch: notch, canvas: CGSize(width: island.canvasWidth, height: size.height), size: island,
                           actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .environment(env)
        .environment(\.juiceTheme, theme)
        .environment(\.islandStateTint, true)
        .environment(\.glassRendering, .live)
        .environment(\.sessionGlyphsAnimated, false)
        return try hosted(AnyView(root), size: size, look: look)
    }

    /// `LiquidRenders.hostedRender` in `look`'s appearance.
    static func hosted(_ view: AnyView, size: CGSize, look: ColorScheme) throws -> CGImage {
        try autoreleasepool {
            _ = NSApplication.shared
            let hosting = NSHostingView(rootView: view)
            let rect = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: look == .light ? .aqua : .darkAqua)
            window.contentView = hosting
            hosting.frame = rect
            for _ in 0..<3 {
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            hosting.displayIfNeeded()
            defer { window.contentView = nil; window.close() }
            guard let layer = hosting.layer else { throw RenderHarness.RenderError.noImage("layer") }
            return try LiquidRenders.render(layer, size: size, crop: CGRect(origin: .zero, size: size), at: CACurrentMediaTime())
        }
    }

    /// Core Animation's outline: the live rig (a window never ordered in) in `look`'s appearance, at rest, drawn by
    /// `CARenderer` over the wallpaper, and where the notch's middle lies in it.
    static func coreAnimations(theme: JuiceTheme, look: ColorScheme, open: Bool, idle: Bool = false, glyph: GlyphStyle = .pixel) async throws
        -> (image: CGImage, notchMidX: CGFloat) {
        _ = NSApplication.shared
        let rig = FramePerf.IslandRig(style: .clean, glyph: glyph, placement: .headerStrip, scenario: .empty, glyphsMove: false,
                                      outline: .coreAnimation, theme: theme, stateTint: true,
                                      prepare: { if !idle { Self.feed($0.engine, now: Date()) } })
        rig.window.appearance = NSAppearance(named: look == .light ? .aqua : .darkAqua)
        await rig.start()
        #expect(idle || rig.ui.pill.lead?.state == .delegating, "the pill leads with the delegate")
        if open {
            rig.open()
            await FramePerf.wait(1.6)
        } else {
            await FramePerf.wait(0.6)
        }
        let content = try #require(rig.window.contentView)
        let ground = ImageRenderer(content: backdrop(look).frame(width: content.bounds.width, height: content.bounds.height))
        ground.scale = 2
        let image = try LiquidLookRenders.render(content, backdrop: try #require(ground.cgImage), at: CACurrentMediaTime())
        // The canvas's middle (the notch's) in the window: from the canvas's own views, as the window a rig never orders
        // in may round its frame to whole points where the panel asked for a half.
        let midX = try #require(rig.canvas.surfaceView).frame.midX
        rig.stop()
        return (image, midX)
    }

    /// `island` (2×, its top the screen's) on the wallpaper at `size`, its notch's middle on the stage's, with the notch
    /// drawn over it or not.
    static func stage(_ island: CGImage, notchMidX: CGFloat, size: CGSize, look: ColorScheme, notch drawn: Bool,
                      extra: AnyView? = nil) throws -> CGImage {
        let view = ZStack(alignment: .topLeading) {
            backdrop(look)
            Image(decorative: island, scale: 2).offset(x: size.width / 2 - notchMidX)
        }
        .overlay(alignment: .top) { if let extra { extra } }
        .overlay(alignment: .top) { if drawn { hardwareNotch(notch) } }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return try #require(renderer.cgImage)
    }

    static func write(_ image: CGImage, _ name: String) throws {
        let folder = out.appendingPathComponent(phase, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: folder.appendingPathComponent(name + ".png"))
    }

    static func word(_ look: ColorScheme) -> String { look == .light ? "light" : "dark" }

    /// One case, both ways: `np-<theme>-<look>-<state>-<outline>-shot` and `-notch`.
    static func render(_ theme: JuiceTheme, _ look: ColorScheme, open: Bool, _ outline: Outline) async throws {
        let size = open ? openSize : closedSize
        let (image, midX): (CGImage, CGFloat) = switch outline {
        case .su: (try swiftUIs(theme: theme, look: look, open: open, size: size), size.width / 2)
        case .ca: try await coreAnimations(theme: theme, look: look, open: open)
        }
        let name = "np-\(theme.rawValue)-\(word(look))-\(open ? "open" : "closed")-\(outline.rawValue)"
        try write(try stage(image, notchMidX: midX, size: size, look: look, notch: false), name + "-shot")
        try write(try stage(image, notchMidX: midX, size: size, look: look, notch: true), name + "-notch")
        // The closed pill's other way (the black down to the pill's bottom along the notch's curve), drawn over it.
        if theme == .solid, !open {
            let down = AnyView(NotchSurfaceShape(geometry: SurfaceGeometry(width: notch.width - 1, height: notch.height + 1, ear: 0, radius: 12))
                .fill(.black).frame(width: notch.width - 1, height: notch.height + 1))
            try write(try stage(image, notchMidX: midX, size: size, look: look, notch: false, extra: down), name + "-blackdown-shot")
            try write(try stage(image, notchMidX: midX, size: size, look: look, notch: true, extra: down), name + "-blackdown-notch")
        }
    }

    // MARK: Renders

    @Test(arguments: [JuiceTheme.solid, .glass])
    func adaptingThemes(_ theme: JuiceTheme) async throws {
        for look in [ColorScheme.light, .dark] {
            for open in [false, true] {
                for outline in Outline.allCases { try await Self.render(theme, look, open: open, outline) }
            }
        }
    }

    /// Solid with nothing to show: the closed island is the notch alone, `np-solid-<look>-idle-<outline>-shot`, `-notch`.
    @Test func solidIdle() async throws {
        for look in [ColorScheme.light, .dark] {
            for outline in Outline.allCases {
                let (image, midX): (CGImage, CGFloat) = switch outline {
                case .su: (try Self.swiftUIs(theme: .solid, look: look, open: false, idle: true, size: Self.closedSize), Self.closedSize.width / 2)
                case .ca: try await Self.coreAnimations(theme: .solid, look: look, open: false, idle: true)
                }
                let name = "np-solid-\(Self.word(look))-idle-\(outline.rawValue)"
                try Self.write(try Self.stage(image, notchMidX: midX, size: Self.closedSize, look: look, notch: false), name + "-shot")
                try Self.write(try Self.stage(image, notchMidX: midX, size: Self.closedSize, look: look, notch: true), name + "-notch")
            }
        }
    }

    /// Solid's closed pill with Liquid's glyphs and Pill edge line on: the line passes under the plate (P797),
    /// `np-solid-<look>-closed-<outline>-liquid-shot`, `-notch`.
    @Test func solidEdgeLine() async throws {
        for look in [ColorScheme.light, .dark] {
            for outline in Outline.allCases {
                let (image, midX): (CGImage, CGFloat) = switch outline {
                case .su: (try Self.swiftUIs(theme: .solid, look: look, open: false, glyph: .liquid, size: Self.closedSize), Self.closedSize.width / 2)
                case .ca: try await Self.coreAnimations(theme: .solid, look: look, open: false, glyph: .liquid)
                }
                let name = "np-solid-\(Self.word(look))-closed-\(outline.rawValue)-liquid"
                try Self.write(try Self.stage(image, notchMidX: midX, size: Self.closedSize, look: look, notch: false), name + "-shot")
                try Self.write(try Self.stage(image, notchMidX: midX, size: Self.closedSize, look: look, notch: true), name + "-notch")
            }
        }
    }

    /// Black and Smoke, dark as they always are: the same bytes before and after.
    @Test(arguments: [JuiceTheme.black, .smoke])
    func darkThemes(_ theme: JuiceTheme) async throws {
        for open in [false, true] {
            for outline in Outline.allCases { try await Self.render(theme, .dark, open: open, outline) }
        }
    }
}
