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

    // MARK: The widgets' grounds (P1224, P1401)

    /// The sessions widget as the desktop shows it, whatever the island's theme: full colour with the island's Glass look
    /// Widget ink, lifted (`SessionsWidgetInk`), on Glass (the system's material, `full`) and on Black (`black`); dimmed on
    /// the system's glass in one colour. Over the widgets' three wallpapers.
    /// Names `wg-clear-<wallpaper>-<face>-<full|black|dimmed>`.
    @Test(arguments: GlassBackdrop.widgetWallpapers)
    func clearLook(_ wallpaper: GlassBackdrop) throws {
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        for face in WidgetFace.allCases {
            for ground in ["full", "black", "dimmed"] {
                let dimmed = ground == "dimmed"
                let size = Size.of(face), margin = Self.margin
                let scene = GlassStage(backdrop: wallpaper) {
                    IslandWidgetView(snapshot: .preview(at: Self.now), face: face,
                                     size: CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin), date: Self.now,
                                     tinted: dimmed)
                        .modifier(SessionsWidgetInk(fullColour: !dimmed))
                        .padding(margin)
                        .frame(width: size.width, height: size.height)
                        .background {
                            if dimmed {
                                GlassFaceStandIn(shape: shape, style: GlassStyle.panel.clear, face: WidgetGlassRenders.widgetModel, scheme: .dark,
                                                 reduceTransparency: false, contrast: .standard)
                            } else if ground == "black" {
                                WidgetBackdrop(choice: .black)
                            } else {
                                WidgetBackdrop(choice: .glass)
                            }
                        }
                        .clipShape(shape)
                        .containerShape(shape)
                        .padding(24)
                }
                .frame(width: size.width + 48, height: size.height + 48)
                try RenderHarness.render(scene, "wg-clear-\(wallpaper.rawValue)-\(face.rawValue)-\(ground)")
            }
        }
    }
}
