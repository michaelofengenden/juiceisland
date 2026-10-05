import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Lane c37/keys, headless (P1025 to P1033): Settings › Shortcuts with today's keys and Mission Control's ⌃1 to ⌃4 taken
/// by macOS, with Option, two recorded keys and Switch sessions, and with Keyboard shortcuts off; the window's stacked
/// cards with Deny all and Allow all on the Needs you line (and with the keys held), the island's approval card with its
/// Allow all row, and the line Allow all leaves. Black and Glass, light and dark. Files `kl-*`; nothing on screen.
@MainActor
@Suite(.serialized)
struct KeysLaneRenders {
    typealias ID = FixtureSessionFeed.ID
    nonisolated static let themes: [JuiceTheme] = [.black, .glass]
    nonisolated static let schemes: [ColorScheme] = [.light, .dark]

    static func word(_ scheme: ColorScheme) -> String { scheme == .light ? "light" : "dark" }

    // MARK: Settings › Shortcuts

    private func pane(_ name: String, theme: JuiceTheme, scheme: ColorScheme, configure: (AppSettings) -> Void) throws {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        settings.appearance = scheme == .light ? .light : .dark
        configure(settings)
        let env = AppEnvironment.demo(settings: settings)
        env.systemShortcuts = ShortcutKeysTests.missionControl
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .shortcuts), drawsTrafficLights: true, scrolls: false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "\(name)-\(theme.rawValue)-\(Self.word(scheme))",
                                       size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env, scheme: scheme)
    }

    /// Today's keys, as an owner who never opens the pane has them; macOS takes ⌃1 and ⌃2 for its desktops.
    @Test(arguments: themes, schemes)
    func shortcutsPane(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        try pane("kl-settings-shortcuts", theme: theme, scheme: scheme) { _ in }
    }

    /// Option, Allow all and Deny all recorded (each with its Reset), and the key from any app switching sessions.
    @Test(arguments: themes, schemes)
    func shortcutsPaneOption(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        try pane("kl-settings-shortcuts-option", theme: theme, scheme: scheme) { settings in
            settings.shortcutModifier = .option
            settings.recordedCardKeys = [.allowAll: CardKey("l", shift: true), .denyAll: CardKey("k", shift: true)]
            settings.globalJumpKey = "ctrl+opt+j"
            settings.globalJumpEnabled = true
            settings.globalKeyAction = .switcher
        }
    }

    @Test func shortcutsPaneOff() throws {
        try pane("kl-settings-shortcuts-off", theme: .black, scheme: .dark) { settings in
            settings.shortcutsEnabled = false
            settings.globalJumpKey = "ctrl+opt+j"
            settings.globalJumpEnabled = true
        }
    }

    // MARK: The window's stacked cards

    /// Allow all, as a click on it would, and back once the five cards went (sent first, resolved once sent: P129).
    static func allowAll(_ env: AppEnvironment) async {
        let cards = BatchAnswer.targets(env)
        BatchAnswer.answer(.allowOnce, cards, env: env)
        for _ in 0..<200 where cards.contains(where: { env.sessions.card(for: $0.sessionID) != nil }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func window(_ name: String, theme: JuiceTheme, scheme: ColorScheme, hints: Bool = false,
                        allowed: Bool = false) async throws {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        settings.appearance = scheme == .light ? .light : .dark
        let env = AppEnvironment.demo(settings: settings, sessions: .cards)
        if allowed { await Self.allowAll(env) }
        let view = WindowRootView(drawsTrafficLights: true)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.showsShortcutHints, hints)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 1200, height: 900), env: env, scheme: scheme)
    }

    /// Eight cards wait: five Claude approvals, Codex's (Watch), a plan and a question. Deny all and Allow all cover the five.
    @Test(arguments: themes, schemes)
    func windowStackedCards(_ theme: JuiceTheme, _ scheme: ColorScheme) async throws {
        try await window("kl-window-allow-all-\(theme.rawValue)-\(Self.word(scheme))", theme: theme, scheme: scheme)
    }

    /// The modifier held: every button names its key, Allow all and Deny all too.
    @Test func windowStackedCardsWithKeys() async throws {
        try await window("kl-window-allow-all-keys-black-dark", theme: .black, scheme: .dark, hints: true)
    }

    /// After Allow all: the plan, the question and Codex's still wait, and the line says what went.
    @Test func windowNoteAfterAllowAll() async throws {
        try await window("kl-window-allowed-note-black-dark", theme: .black, scheme: .dark, allowed: true)
    }

    // MARK: The island's card

    private func island(_ name: String, theme: JuiceTheme, scheme: ColorScheme, card id: String?, hints: Bool = false,
                        allowed: Bool = false) async throws {
        let env = IslandGlassRenders.environment { settings in
            settings.juiceTheme = theme
            settings.appearance = scheme == .light ? .light : .dark
            settings.glassLook = .lightAndDark
        }
        let cardsEnv = AppEnvironment.demo(settings: env.settings, sessions: .cards)
        if allowed { await Self.allowAll(cardsEnv) }
        let ui = id.map { IslandGlassRenders.state(cardsEnv, surface: .island, card: $0, events: [(0, .present(.card(sessionID: $0)))], at: 1.5) }
            ?? IslandGlassRenders.state(cardsEnv, surface: .island)
        let size = CGSize(width: 540, height: id == nil ? 330 : 400)
        let scene = AppearanceRenders.islandScene(ui, size: size, backdrop: theme == .black ? .white : .busy, theme: theme, scheme: scheme)
            .environment(\.showsShortcutHints, hints)
        // Hosted: the card's diff scrolls in an AppKit scroll view, which `ImageRenderer` leaves empty.
        try RenderHarness.renderHosted(scene, name, size: size, env: cardsEnv, scheme: scheme)
    }

    /// The oldest of the five on show, as the island opens on it: its answers, then "5 approvals wait", Deny all, Allow all.
    @Test(arguments: themes, schemes)
    func islandApprovalCard(_ theme: JuiceTheme, _ scheme: ColorScheme) async throws {
        try await island("kl-island-allow-all-\(theme.rawValue)-\(Self.word(scheme))", theme: theme, scheme: scheme, card: ID.write)
    }

    @Test func islandApprovalCardWithKeys() async throws {
        try await island("kl-island-allow-all-keys-black-dark", theme: .black, scheme: .dark, card: ID.write, hints: true)
    }

    /// After Allow all: the list with what still waits, the line under the header.
    @Test func islandNoteAfterAllowAll() async throws {
        try await island("kl-island-allowed-note-black-dark", theme: .black, scheme: .dark, card: nil, allowed: true)
    }
}
