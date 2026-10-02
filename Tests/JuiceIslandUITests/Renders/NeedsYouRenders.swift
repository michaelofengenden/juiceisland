import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Needs you colour, headless (P780 to P784): every surface that draws what waits on the owner, on
/// Black, Glass and Solid in Light and in Dark, in Pixel, Liquid and Sand, in each choice. Files
/// `ny-<choice>-<look>-<style>-<scene>`; Orange's are the base commit's pixel for pixel.
@MainActor
@Suite(.serialized)
struct NeedsYouRenders {
    nonisolated static let choices = NeedsYouColour.allCases

    struct Look: Sendable {
        var name: String
        var theme: JuiceTheme
        var scheme: ColorScheme
        var backdrop: GlassBackdrop
    }

    nonisolated static let looks: [Look] = [
        Look(name: "black", theme: .black, scheme: .dark, backdrop: .busy),
        Look(name: "glass-light", theme: .glass, scheme: .light, backdrop: .white),
        Look(name: "glass-dark", theme: .glass, scheme: .dark, backdrop: .busy),
        Look(name: "solid-light", theme: .solid, scheme: .light, backdrop: .white),
        Look(name: "solid-dark", theme: .solid, scheme: .dark, backdrop: .busy),
    ]
    nonisolated static let styles: [GlyphStyle] = [.pixel, .liquid, .sand]

    static func environment(_ look: Look, style: GlyphStyle, choice: NeedsYouColour) -> AppEnvironment {
        IslandGlassRenders.environment { settings in
            settings.needsYouColour = choice
            settings.glyphStyle = style
            settings.glyphEdgeLine = true
            settings.juiceTheme = look.theme
            settings.appearance = look.scheme == .light ? .light : .dark
        }
    }

    static func states(_ look: Look, style: GlyphStyle, choice: NeedsYouColour)
        -> [(name: String, env: AppEnvironment, ui: IslandUIState, size: CGSize)] {
        let env = Self.environment(look, style: style, choice: choice)
        func card(_ id: String) -> IslandUIState {
            IslandGlassRenders.state(env, surface: .island, card: id, events: [(0, .present(.card(sessionID: id)))], at: 1.5)
        }
        return [
            ("closed", env, IslandGlassRenders.state(env), IslandGlassRenders.pillSize),
            ("open", env, IslandGlassRenders.state(env, surface: .island), IslandGlassRenders.openSize),
            ("card-approval", env, card(FixtureSessionFeed.ID.approval), CGSize(width: 540, height: 330)),
            ("card-question", env, card(FixtureSessionFeed.ID.question), CGSize(width: 540, height: 330)),
        ]
    }

    static func name(_ choice: NeedsYouColour, _ look: Look, _ rest: String) -> String { "ny-\(choice.rawValue)-\(look.name)-\(rest)" }

    /// The island: the closed pill, the opened list, an approval's card and a question's with its options.
    @Test(arguments: choices, styles)
    func island(_ choice: NeedsYouColour, _ style: GlyphStyle) throws {
        for look in Self.looks {
            for state in Self.states(look, style: style, choice: choice) {
                let scene = AppearanceRenders.islandScene(state.ui, size: state.size, backdrop: look.backdrop, theme: look.theme,
                                                          scheme: look.scheme)
                    .environment(\.needsYouColour, choice)
                let name = Self.name(choice, look, "\(style.rawValue)-\(state.name)")
                if state.name == "card-question" {
                    try RenderHarness.renderHosted(scene, name, size: state.size, env: state.env, scheme: look.scheme)
                } else {
                    try RenderHarness.render(scene, name, env: state.env, scheme: look.scheme)
                }
            }
        }
    }

    /// A question's options with one picked (its badge and edge), and a multi-select one with its check, on the island's
    /// surface in each look.
    @Test(arguments: choices)
    func questionPicked(_ choice: NeedsYouColour) throws {
        for look in Self.looks {
            let env = Self.environment(look, style: .pixel, choice: choice)
            guard case var .question(card)? = env.sessions.card(for: FixtureSessionFeed.ID.question) else {
                Issue.record("no question card")
                return
            }
            var multi = card
            multi.multiSelect = true
            multi.picked = [0, 2]
            card.picked = [1]
            let size = CGSize(width: 480, height: 560)
            let scene = GlassStage(backdrop: look.backdrop, look: look.scheme) {
                VStack(spacing: 12) {
                    QuestionCardView(card: card, style: .islandClean)
                    QuestionCardView(card: multi, style: .islandClean)
                }
                .padding(12)
                .themedSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(12)
                .frame(width: size.width, height: size.height, alignment: .top)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.juiceTheme, look.theme)
            .environment(\.needsYouColour, choice)
            .environment(\.sessionGlyphsAnimated, false)
            try RenderHarness.renderHosted(scene, Self.name(choice, look, "question-picked"), size: size, env: env, scheme: look.scheme)
        }
    }

    /// Window mode: the Detailed rows and the card beside them.
    @Test(arguments: choices)
    func window(_ choice: NeedsYouColour) throws {
        for look in Self.looks {
            let settings = AppSettings.ephemeral()
            settings.needsYouColour = choice
            settings.juiceTheme = look.theme
            settings.appearance = look.scheme == .light ? .light : .dark
            let env = ARenders.withBadge(AppEnvironment.demo(settings: settings, sessions: .prototype))
            try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), Self.name(choice, look, "window"),
                                           size: CGSize(width: 1000, height: 640), env: env, scheme: look.scheme)
        }
    }

    /// The desktop panel: batteries and money, no needs-you colour of its own.
    @Test(arguments: choices)
    func panel(_ choice: NeedsYouColour) throws {
        for look in Self.looks {
            let env = AppEnvironment.demo()
            let size = CGSize(width: 410, height: 232)
            let staged = GlassStage(backdrop: look.backdrop, look: look.scheme) {
                DesktopPanelView().padding(PanelGeometry.margin).frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .frame(width: size.width, height: size.height)
            .environment(\.juiceTheme, look.theme)
            .environment(\.needsYouColour, choice)
            try RenderHarness.render(staged, Self.name(choice, look, "panel"), size: size, env: env, scheme: look.scheme)
        }
    }

    /// The widget's large face with every state, as WidgetKit would draw it in full colour.
    @Test(arguments: choices)
    func widget(_ choice: NeedsYouColour) throws {
        for look in Self.looks {
            for style in Self.styles {
                let settings = AppSettings.ephemeral()
                settings.needsYouColour = choice
                settings.glyphStyle = style
                settings.juiceTheme = look.theme
                settings.appearance = look.scheme == .light ? .light : .dark
                let snapshot = WidgetSnapshot.make(.demo(settings: settings, sessions: .allStates), at: WidgetRenders.now)
                let size = WidgetRenders.Size.large, margin = WidgetRenders.margin
                let shape = RoundedRectangle(cornerRadius: WidgetRenders.radius, style: .continuous)
                let scene = GlassStage(backdrop: look.backdrop, look: look.scheme) {
                    IslandWidgetView(snapshot: snapshot, face: .large,
                                     size: CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin), date: WidgetRenders.now)
                        .padding(margin)
                        .frame(width: size.width, height: size.height)
                        .background { WidgetBackground() }
                        .clipShape(shape)
                        .containerShape(shape)
                        .modifier(WidgetInkScheme(scheme: IslandWidgetEntryView.inkScheme(snapshot, .fullColor)))
                        .padding(24)
                }
                .frame(width: size.width + 48, height: size.height + 48)
                .environment(\.juiceTheme, look.theme)
                try RenderHarness.render(scene, Self.name(choice, look, "\(style.rawValue)-widget"), scheme: look.scheme)
            }
        }
    }

    /// Settings › Island's two previews: Glyph style's (running, delegating, "!", "?", done) and Theme's pill.
    @Test(arguments: choices)
    func settingsPreviews(_ choice: NeedsYouColour) throws {
        for look in Self.looks {
            for style in Self.styles {
                let settings = AppSettings.ephemeral()
                settings.needsYouColour = choice
                settings.glyphStyle = style
                settings.juiceTheme = look.theme
                let env = AppEnvironment.demo(settings: settings)
                let view = VStack(alignment: .leading, spacing: 8) {
                    GlyphStylePreview(style: style)
                    ThemePreview(theme: look.theme)
                }
                .padding(10)
                .background(look.scheme == .light ? Color(white: 0.93) : Color(white: 0.12))
                .environment(\.sessionGlyphsAnimated, false)
                try RenderHarness.render(view, Self.name(choice, look, "\(style.rawValue)-settings"), env: env, scheme: look.scheme)
            }
        }
    }
}
