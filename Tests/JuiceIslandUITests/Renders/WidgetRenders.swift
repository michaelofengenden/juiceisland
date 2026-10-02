import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The desktop widget (spec §4.7), headless: `IslandWidgetView` in each family's size on a wallpaper, with the widget's
/// rounded black and content margins drawn here as WidgetKit would. The tinted look (the desktop's vibrant or accented
/// rendering) has no black and draws in one colour. Names `wg-…`: `zsh scripts/render-all.sh WidgetRenders`.
@MainActor
@Suite(.serialized)
struct WidgetRenders {
    static let now = DemoClock.now

    /// macOS desktop sizes (the large one's height is the medium's two rows and the gap), with the desktop's margin.
    enum Size {
        static let small = CGSize(width: 170, height: 170)
        static let medium = CGSize(width: 364, height: 170)
        static let large = CGSize(width: 364, height: 382)
        static func of(_ face: WidgetFace) -> CGSize {
            switch face {
            case .small: small
            case .medium: medium
            case .large: large
            }
        }
    }

    static let margin: CGFloat = 14
    static let radius: CGFloat = 22

    private func scene(_ snapshot: WidgetSnapshot?, _ face: WidgetFace, size: CGSize? = nil, tinted: Bool = false,
                       margin: CGFloat = margin) -> some View {
        let size = size ?? Size.of(face)
        // No scheme: `ImageRenderer` cannot draw a `Link`, which WidgetKit draws as its label.
        return IslandWidgetView(snapshot: snapshot, face: face, size: CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin),
                                date: Self.now, tinted: tinted)
            .padding(margin)
            .frame(width: size.width, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(tinted ? AnyShapeStyle(Color.white.opacity(0.14)) : AnyShapeStyle(IslandTheme.bg))
            }
            .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
            .padding(24)
            .background(wallpaper)
    }

    private var wallpaper: some View {
        LinearGradient(stops: [.init(color: Color(hex: 0x33485A), location: 0), .init(color: Color(hex: 0x5B6E7A), location: 0.6),
                               .init(color: Color(hex: 0x8C7A62), location: 1)], startPoint: .top, endPoint: .bottom)
    }

    private func render(_ snapshot: WidgetSnapshot?, _ name: String, faces: [WidgetFace] = WidgetFace.allCases,
                        tinted: Bool = false) throws {
        for face in faces {
            try RenderHarness.render(scene(snapshot, face, tinted: tinted), "wg-\(name)-\(face.rawValue)")
        }
    }

    private func demo(_ scenario: FixtureSessionFeed.Scenario, settings: AppSettings = .ephemeral()) -> WidgetSnapshot {
        WidgetSnapshot.make(.demo(settings: settings, sessions: scenario), at: Self.now)
    }

    @Test func preview() throws { try render(.preview(at: Self.now), "preview") }
    @Test func allStates() throws { try render(demo(.allStates), "all-states") }
    @Test func attention() throws { try render(demo(.attention), "attention") }
    @Test func agents() throws { try render(demo(.agents), "agents") }
    @Test func look() throws { try render(demo(.look), "look") }

    @Test func byAgentAndGlyphStyles() throws {
        for style in [GlyphStyle.liquid, .sand] {
            let settings = AppSettings.ephemeral()
            settings.glyphStyle = style
            settings.glyphColour = .byAgent
            try render(demo(.allStates, settings: settings), "all-states-\(style.rawValue)-agent", faces: [.small, .medium])
        }
    }

    @Test func runningOnly() throws {
        var snapshot = WidgetSnapshot.preview(at: Self.now)
        snapshot.rows.removeAll { $0.kind == .needsYou }
        try render(snapshot, "running")
    }

    @Test func noSessions() throws {
        var snapshot = WidgetSnapshot.preview(at: Self.now)
        snapshot.rows = []
        try render(snapshot, "no-sessions")
    }

    @Test func notRunning() throws {
        try render(.closed(at: Self.now), "closed", faces: [.small, .medium])
        try render(nil, "none", faces: [.small])
    }

    @Test func tinted() throws {
        try render(.preview(at: Self.now), "preview-tinted", tinted: true)
        try render(.closed(at: Self.now), "closed-tinted", faces: [.small], tinted: true)
    }

    /// Long titles and many rows: titles cut at the end, the rest counted.
    @Test func crowded() throws {
        var snapshot = WidgetSnapshot.preview(at: Self.now)
        snapshot.rows[0].title = "Rewrite the release notes for the September build and the changelog page"
        snapshot.rows[0].detail = "link-checker · Bash · in Ghostty"
        snapshot.rows += (1...5).map { index in
            WidgetSnapshot.Row(id: "run-\(index)", agent: index % 2 == 0 ? "claude" : "geminiCLI", kind: .running,
                               title: "Background job number \(index) with a long title", glyph: "eq")
        }
        snapshot.more = 3
        try render(snapshot, "crowded")
    }

    /// Smaller canvases (an iPad-sized medium, the desktop's tighter margin) keep every battery by shrinking the rows.
    @Test func narrow() throws {
        let snapshot = WidgetSnapshot.preview(at: Self.now)
        try RenderHarness.render(scene(snapshot, .small, size: CGSize(width: 155, height: 155), margin: 11), "wg-narrow-small")
        try RenderHarness.render(scene(snapshot, .medium, size: CGSize(width: 329, height: 155), margin: 11), "wg-narrow-medium")
        try RenderHarness.render(scene(snapshot, .large, size: CGSize(width: 329, height: 345), margin: 11), "wg-narrow-large")
    }

    // MARK: Theme (spec §4.8, P540 to P545, P566)

    /// The glass themes, as the files name them: Smoke's are Glass's before 2026-09-29, byte for byte.
    nonisolated static let glassThemes: [JuiceTheme] = [.glass, .smoke]

    /// The widget in `theme` on a judged backdrop, its container background the widget's own (`WidgetBackground`) in
    /// WidgetKit's rounded shape, its content in the scheme the entry view gives it (`WidgetInkScheme`: Glass's light
    /// ink). Offscreen there is no glass and no system platter: Smoke's stand-in blurs the backdrop under the floor, and
    /// Glass shows it sharp under its veil, where live the system's platter or the desktop shows through (P541). Names
    /// `wg-standin-…`.
    private func themed(_ snapshot: WidgetSnapshot?, _ face: WidgetFace, _ theme: JuiceTheme, on backdrop: GlassBackdrop,
                        reduceTransparency: Bool = false, contrast: ColorSchemeContrast = .standard) -> some View {
        let size = Size.of(face), margin = Self.margin
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        return GlassStage(backdrop: backdrop) {
            IslandWidgetView(snapshot: snapshot, face: face, size: CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin),
                             date: Self.now)
                .padding(margin)
                .frame(width: size.width, height: size.height)
                .background {
                    if reduceTransparency || contrast != .standard, theme == .smoke {
                        WidgetSmokeBody(rendering: .standIn, reduceTransparency: reduceTransparency, contrast: contrast)
                    } else if reduceTransparency || contrast != .standard, theme == .glass {
                        WidgetGlassBody(rendering: .standIn, reduceTransparency: reduceTransparency, contrast: contrast)
                    } else {
                        WidgetBackground()
                    }
                }
                .clipShape(shape)
                .containerShape(shape)
                .modifier(WidgetInkScheme(scheme: IslandWidgetEntryView.lightInk(theme, .fullColor) ? .light : nil))
                .padding(24)
        }
        .frame(width: size.width + 48, height: size.height + 48)
        .environment(\.juiceTheme, theme)
    }

    /// Glass and Smoke, each face on a white window's worth of wallpaper, a black desktop and a busy photo.
    @Test(arguments: GlassBackdrop.judged, glassThemes)
    func glass(_ backdrop: GlassBackdrop, _ theme: JuiceTheme) throws {
        for face in WidgetFace.allCases {
            try RenderHarness.render(themed(.preview(at: Self.now), face, theme, on: backdrop),
                                     "wg-standin-\(theme.rawValue)-\(backdrop.rawValue)-\(face.rawValue)")
        }
    }

    /// Black, Glass and Smoke side by side on each judged backdrop, one sheet a face.
    @Test func themeSheets() throws {
        for face in WidgetFace.allCases {
            let sheet = VStack(alignment: .leading, spacing: 8) {
                ForEach(GlassBackdrop.judged, id: \.self) { backdrop in
                    HStack(spacing: 8) {
                        ForEach(JuiceTheme.allCases, id: \.self) { theme in
                            themed(.preview(at: Self.now), face, theme, on: backdrop)
                        }
                    }
                }
            }
            .padding(8)
            .background(Color(white: 0.2))
            try RenderHarness.render(sheet, "wg-standin-sheet-\(face.rawValue)")
        }
    }

    /// Glass and Smoke with every state and both agents' colours, by agent in Liquid, not running, and nothing running, on
    /// the busy photo; Reduce Transparency and Increase Contrast.
    @Test(arguments: glassThemes)
    func glassStates(_ theme: JuiceTheme) throws {
        let name = "wg-standin-\(theme.rawValue)"
        try RenderHarness.render(themed(demo(.allStates), .large, theme, on: .busy), "\(name)-all-states-busy-large")
        let settings = AppSettings.ephemeral()
        settings.glyphStyle = .liquid
        settings.glyphColour = .byAgent
        try RenderHarness.render(themed(demo(.allStates, settings: settings), .medium, theme, on: .busy),
                                 "\(name)-all-states-liquid-agent-busy-medium")
        try RenderHarness.render(themed(.closed(at: Self.now, theme: theme), .small, theme, on: .busy), "\(name)-closed-busy-small")
        var idle = WidgetSnapshot.preview(at: Self.now)
        idle.rows = []
        try RenderHarness.render(themed(idle, .medium, theme, on: .white), "\(name)-no-sessions-white-medium")
        try RenderHarness.render(themed(.preview(at: Self.now), .medium, theme, on: .busy, reduceTransparency: true),
                                 "\(name)-busy-medium-reduce-transparency")
        try RenderHarness.render(themed(.preview(at: Self.now), .medium, theme, on: .busy, contrast: .increased),
                                 "\(name)-busy-medium-increase-contrast")
    }
}
