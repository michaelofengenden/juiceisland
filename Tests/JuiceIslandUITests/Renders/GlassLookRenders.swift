import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// State tint, Frost and the pointer-lit rim (`GlassLook`, P630 to P639), headless: the real `IslandRootView` (SwiftUI's
/// outline) on the judged backdrops, Glass's glass the stand-in (`is-standin-*`'s), so every file is `look-standin-*`.
/// - `look-standin-tint-<theme>-<scene>-<tint>-<backdrop>`: Black's edge and Glass's veil for each lead state, and none;
///   `look-standin-tint-strip-<theme>`: the closed pill through none, needs you, delegating, finished, none.
/// - `look-standin-frost-<frost>-<scene>-<backdrop>`: Glass at Frost 0, 0.5 and 1; `look-standin-frost-strip`.
/// - `look-standin-rimlight-<scene>-<backdrop>`: Glass's rim lit near the pointer; `look-standin-rimlight-strip`: the light
///   following the pointer along the pill.
/// - `look-settings-island-glass`, `look-settings-preview-*`: Settings › Island with Glass (Frost and State tint), and the
///   preview in each.
@MainActor
@Suite(.serialized)
struct GlassLookRenders {
    typealias R = IslandGlassRenders

    /// The island's canvas as it lands in a scene `size` wide: its left, and its middle.
    static func canvasX(_ size: CGSize) -> CGFloat { (size.width - IslandPanelSizing.canvasWidth) / 2 }

    /// `ui` leading with `tint` (nil: a run, no tint), the pill's size unchanged.
    static func leading(_ ui: IslandUIState, _ tint: StateTint?) -> IslandUIState {
        switch tint {
        case .needsYou: ui.pill.lead = PillLead(glyph: .bang, agent: .claude, state: .waiting)
        case .finished: ui.pill.lead = PillLead(glyph: .check, agent: .claude, state: .done)
        case .delegating: ui.pill.lead = PillLead(glyph: .agents, agent: .claude, state: .delegating)
        case nil: ui.pill.lead = PillLead(glyph: .eq, agent: .claude, state: .running)
        }
        return ui
    }

    static func scene(_ ui: IslandUIState, size: CGSize, backdrop: GlassBackdrop, theme: JuiceTheme, tint: Bool = true,
                      frost: Double = 0) -> some View {
        R.scene(ui, size: size, backdrop: backdrop, theme: theme)
            .environment(\.islandStateTint, tint)
            .environment(\.glassFrost, frost)
    }

    /// The closed pill, the opened list and an approval's card.
    static func scenes(_ env: AppEnvironment) -> [(name: String, make: () -> IslandUIState, size: CGSize)] {
        let card = FixtureSessionFeed.ID.approval
        return [
            ("closed", { R.state(env) }, R.pillSize),
            ("open", { R.state(env, surface: .island) }, R.openSize),
            ("card", { R.state(env, surface: .island, card: card, events: [(0, .present(.card(sessionID: card)))], at: 1.5) }, R.openSize),
        ]
    }

    static let tints: [StateTint?] = [nil, .needsYou, .finished, .delegating]

    // MARK: State tint

    @Test(arguments: [JuiceTheme.black, .glass])
    func eachTintOnEachBackdrop(_ theme: JuiceTheme) throws {
        let env = R.environment()
        for scene in Self.scenes(env) {
            for tint in Self.tints {
                for backdrop in GlassBackdrop.judged {
                    let ui = Self.leading(scene.make(), tint)
                    try RenderHarness.render(Self.scene(ui, size: scene.size, backdrop: backdrop, theme: theme),
                                             "look-standin-tint-\(theme.rawValue)-\(scene.name)-\(tint?.rawValue ?? "none")-\(backdrop.rawValue)",
                                             env: env)
                }
            }
        }
    }

    /// The closed pill through the tints, as the island goes through them: a strip per theme, each backdrop a column.
    @Test(arguments: [JuiceTheme.black, .glass])
    func tintStrip(_ theme: JuiceTheme) throws {
        let env = R.environment()
        // States are built before the view: building one measures the island, a render of its own.
        let states = GlassBackdrop.judged.map { _ in (Self.tints + [nil]).map { Self.leading(R.state(env), $0) } }
        let strip = HStack(spacing: 8) {
            ForEach(Array(GlassBackdrop.judged.enumerated()), id: \.offset) { column, backdrop in
                VStack(spacing: 4) {
                    ForEach(Array(states[column].enumerated()), id: \.offset) { _, ui in
                        Self.scene(ui, size: CGSize(width: 360, height: 44), backdrop: backdrop, theme: theme)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(white: 0.2))
        try RenderHarness.render(strip, "look-standin-tint-strip-\(theme.rawValue)", env: env)
    }

    // MARK: Frost

    @Test func frostAcrossItsRange() throws {
        let env = R.environment()
        for frost in [0.0, 0.5, 1.0] {
            for scene in Self.scenes(env) {
                for backdrop in GlassBackdrop.judged {
                    try RenderHarness.render(Self.scene(scene.make(), size: scene.size, backdrop: backdrop, theme: .glass, tint: false, frost: frost),
                                             "look-standin-frost-\(Int(frost * 100))-\(scene.name)-\(backdrop.rawValue)", env: env)
                }
            }
        }
        // The opened list over the busy photo and a white window, Frost 0 to 1 in quarters, and with the needs-you tint.
        let open = R.state(env, surface: .island)
        let strip = VStack(spacing: 6) {
            ForEach([GlassBackdrop.busy, .white], id: \.self) { backdrop in
                HStack(spacing: 6) {
                    ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { frost in
                        Self.scene(open, size: CGSize(width: 520, height: 200), backdrop: backdrop, theme: .glass, tint: false, frost: frost)
                    }
                    Self.scene(open, size: CGSize(width: 520, height: 200), backdrop: backdrop, theme: .glass, frost: 1)
                }
            }
        }
        .padding(8)
        .background(Color(white: 0.2))
        try RenderHarness.render(strip, "look-standin-frost-strip", env: env)
    }

    // MARK: The rim's light

    /// `ui` with its rim lit for a pointer at `pointer` in the canvas.
    static func lit(_ ui: IslandUIState, pointer: CGPoint) -> IslandUIState {
        let place = RimLight.place(pointer: pointer, target: ui.surface, midX: IslandPanelSizing.canvasWidth / 2)
        ui.rimLight.set(.init(centre: place.centre, radius: place.radius))
        return ui
    }

    @Test func theRimCatchesTheLight() throws {
        let env = R.environment()
        let mid = IslandPanelSizing.canvasWidth / 2
        for scene in Self.scenes(env) {
            for backdrop in GlassBackdrop.judged {
                let ui = scene.make()
                let pointer = CGPoint(x: mid - ui.surface.left + ui.surface.width * 0.2, y: ui.surface.height * 0.75)
                try RenderHarness.render(Self.scene(Self.lit(ui, pointer: pointer), size: scene.size, backdrop: backdrop, theme: .glass, tint: false),
                                         "look-standin-rimlight-\(scene.name)-\(backdrop.rawValue)", env: env)
            }
        }
        // The pointer along the closed pill, left to right, and the open island's corners, over the black desktop and
        // the busy photo, zoomed ×2.
        let pills = [0.1, 0.35, 0.65, 0.9].map { f -> IslandUIState in
            let ui = R.state(env)
            return Self.lit(ui, pointer: CGPoint(x: mid - ui.surface.left + ui.surface.width * f, y: ui.surface.height * 0.6))
        }
        let islands = [CGPoint(x: -200, y: 300), CGPoint(x: 0, y: 320), CGPoint(x: 200, y: 150)].map { p in
            Self.lit(R.state(env, surface: .island), pointer: CGPoint(x: mid + p.x, y: p.y))
        }
        let strip = HStack(alignment: .top, spacing: 8) {
            ForEach([GlassBackdrop.black, .busy, .white], id: \.self) { backdrop in
                VStack(spacing: 4) {
                    ForEach(Array(pills.enumerated()), id: \.offset) { _, ui in
                        Self.scene(ui, size: CGSize(width: 360, height: 44), backdrop: backdrop, theme: .glass, tint: false)
                    }
                    ForEach(Array(islands.enumerated()), id: \.offset) { _, ui in
                        Self.scene(ui, size: CGSize(width: 540, height: 360), backdrop: backdrop, theme: .glass, tint: false)
                            .scaleEffect(0.66, anchor: .topLeading).frame(width: 360, height: 240, alignment: .topLeading)
                    }
                }
            }
        }
        .padding(8)
        .background(Color(white: 0.2))
        try RenderHarness.render(strip.scaleEffect(2, anchor: .topLeading).frame(width: 2 * (3 * 360 + 16 + 16), height: 2 * (4 * 44 + 3 * 240 + 6 * 4 + 16),
                                                                                  alignment: .topLeading),
                                 "look-standin-rimlight-strip", env: env)
    }

    // MARK: Settings

    @Test func settingsWithGlass() throws {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = .glass
        settings.glassFrost = 0.4
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "look-settings-island-glass", size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
        for theme in JuiceTheme.allCases {
            for (tag, tint, frost) in [("tint", true, 0.0), ("plain", false, 0.0), ("frost", true, 1.0)] {
                let s = AppSettings.ephemeral()
                s.islandStateTint = tint
                s.glassFrost = frost
                try RenderHarness.render(ThemePreview(theme: theme).scaleEffect(3, anchor: .topLeading)
                    .frame(width: ThemePreview.size.width * 3, height: ThemePreview.size.height * 3, alignment: .topLeading),
                                         "look-settings-preview-\(theme.rawValue)-\(tag)", env: AppEnvironment.demo(settings: s))
            }
        }
    }
}
