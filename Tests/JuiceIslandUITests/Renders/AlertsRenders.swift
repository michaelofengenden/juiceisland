import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 3's alerts lane (P1000 to P1024), headless, every file named `al-*`: Settings › Sound with Juice's sounds and a
/// chosen file; Settings › Island with Show model and Show branch (Clean), Quiet while presenting, Quiet during Focus (as
/// it starts, and while a Focus quiets the island) and a Tool mute rule, on Black and Glass in Light and Dark; the opened
/// island's Clean rows with the model and the branch, and an approval card whose header says them, on Black and Glass in
/// Light and Dark; and the island at text size 16 (Clean and Detailed lists, an approval's, a question's and a Done
/// card). Fixture sessions only; glass is the stand-in (`is-standin` explains); nothing shows on screen.
@MainActor
@Suite(.serialized)
struct AlertsRenders {
    typealias ID = FixtureSessionFeed.ID
    static let notch = IslandTheme.Metrics.referenceNotch

    struct Look: Sendable {
        var name: String
        var theme: JuiceTheme
        var scheme: ColorScheme
        var backdrop: GlassBackdrop
    }

    nonisolated static let looks: [Look] = [
        Look(name: "black-dark", theme: .black, scheme: .dark, backdrop: .busy),
        Look(name: "black-light", theme: .black, scheme: .light, backdrop: .white),
        Look(name: "glass-light", theme: .glass, scheme: .light, backdrop: .white),
        Look(name: "glass-dark", theme: .glass, scheme: .dark, backdrop: .busy),
    ]

    nonisolated static let themes: [JuiceTheme] = [.black, .glass]
    nonisolated static let schemes: [ColorScheme] = [.light, .dark]
    static func word(_ scheme: ColorScheme) -> String { scheme == .light ? "light" : "dark" }

    // MARK: Settings

    static func renderPane(_ pane: SettingsPane, _ name: String, env: AppEnvironment, scheme: ColorScheme) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env, scheme: scheme)
    }

    static func settings(_ theme: JuiceTheme, _ scheme: ColorScheme) -> AppSettings {
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = theme
        settings.appearance = scheme == .light ? .light : .dark
        return settings
    }

    /// Sound: Needs you on Juice's Tap, Question on Rise, Done on a chosen file (its name on the face).
    @Test(arguments: themes, schemes)
    func soundPane(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let settings = Self.settings(theme, scheme)
        settings.needsYouSound = .juice(.tap)
        settings.questionSound = .juice(.rise)
        settings.doneSound = .file("done/Desk bell.wav")
        try Self.renderPane(.sound, "al-settings-sound-\(theme.rawValue)-\(Self.word(scheme))", env: .demo(settings: settings), scheme: scheme)
    }

    /// Sound as it starts: Glass, Same as Needs you, None, as before.
    @Test func soundPaneAsItStarts() throws {
        try Self.renderPane(.sound, "al-settings-sound-default", env: .demo(settings: .ephemeral()), scheme: .dark)
    }

    /// A file too long for Done, refused: its line under the row, the choice as it was.
    @Test func soundPaneWithAFileRefused() throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .sound), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.previewSoundRefusals, [.done: .tooLong])
        let env = AppEnvironment.demo(settings: .ephemeral())
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "al-settings-sound-refused", size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    /// Island: Clean with Show model on, Quiet while presenting on, Quiet during Focus as it starts, and two mute rules,
    /// one a Tool's.
    @Test(arguments: themes, schemes)
    func islandPane(_ theme: JuiceTheme, _ scheme: ColorScheme) throws {
        let settings = Self.settings(theme, scheme)
        settings.rowShowsModel = true
        settings.quietWhilePresenting = true
        settings.muteRules = [MuteRule(field: .tool, text: "mcp__github__*"), MuteRule(field: .folder, text: "notes-site")]
        try Self.renderPane(.island, "al-settings-island-\(theme.rawValue)-\(Self.word(scheme))", env: .demo(settings: settings), scheme: scheme)
    }

    /// Island while a Focus quiets it (its row says so), in Detailed (no Show model or Show branch), with a Tool rule
    /// just added.
    @Test func islandPaneWhileAFocusQuiets() throws {
        let settings = Self.settings(.black, .dark)
        settings.islandStyle = .detailed
        settings.muteRules = [MuteRule(field: .tool)]
        let env = AppEnvironment.demo(settings: settings)
        let focus = FocusFilterState()
        focus.apply(quiet: true)
        env.quietScenes = QuietScenes(settings: settings, focus: focus, mirrored: { false })
        try Self.renderPane(.island, "al-settings-island-focus-quiet-detailed", env: env, scheme: .dark)
    }

    // MARK: Rows and cards with the model and the branch (P1015)

    /// The demo's rows with the facts and branches its sessions would report: the approval's Claude runs Opus 5.5 at
    /// high on its worktree's branch, a running Claude Sonnet 4.5.
    final class Reported: SessionsModel {
        let base: any SessionsModel
        let facts: [String: RowFacts]
        /// The branch a session's folder has checked out, where the scenario's own folders say none.
        let branches: [String: String]
        init(_ base: any SessionsModel, facts: [String: RowFacts], branches: [String: String] = [:]) {
            self.base = base
            self.facts = facts
            self.branches = branches
        }

        var rows: [SessionRow] {
            base.rows.map { row in
                var row = row
                if let facts = facts[row.id] { row.facts = facts }
                if let branch = branches[row.id] { row.branch = branch }
                return row
            }
        }
        var now: Date { base.now }
        var waiting: [SessionRow] { base.waiting.compactMap { row(id: $0.id) } }
        func card(for sessionID: String) -> SessionCard? { base.card(for: sessionID) }
        func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) {}
        func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool { false }
        func reply(_ sessionID: String, text: String) {}
        func jump(_ sessionID: String) {}
        func jumpToNextNeedsYou() {}
        func dismiss(_ sessionID: String) {}
    }

    static func reportedEnvironment(model: Bool, branch: Bool, theme: JuiceTheme, scheme: ColorScheme,
                                    scenario: FixtureSessionFeed.Scenario = .prototype) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = .clean
        settings.islandUsagePlacement = .headerStrip
        settings.rowShowsModel = model
        settings.rowShowsBranch = branch
        settings.juiceTheme = theme
        settings.appearance = scheme == .light ? .light : .dark
        let demo = AppEnvironment.demo(settings: settings, sessions: scenario)
        let facts: [String: RowFacts] = [
            ID.approval: RowFacts(model: "Opus 5.5", mode: "default", effort: "high"),
            ID.question: RowFacts(model: "Sonnet 4.5"),
            FixtureSessionFeed.DetailsID.codexBranch: RowFacts(model: "GPT-5.1 Codex", effort: "medium"),
        ]
        return AppEnvironment(settings: settings, usage: demo.usage, sessions: Reported(demo.sessions, facts: facts))
    }

    /// The island on `look`'s backdrop, in its theme and Appearance, at `island`'s size.
    static func scene(_ ui: IslandUIState, look: Look, size: CGSize, island: IslandSize = .standard) -> some View {
        GlassStage(backdrop: look.backdrop, look: look.scheme) {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.black.opacity(0.1)).frame(height: IslandGlassRenders.menuBar)
                IslandRootView(ui: ui, notch: Self.notch, canvas: CGSize(width: island.canvasWidth, height: size.height), size: island,
                               actions: IslandViewActions(), pillClicked: {}, measured: { _ in })
                DScene.hardwareNotch(Self.notch)
            }
            .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .environment(\.juiceTheme, look.theme)
        .environment(\.islandStateTint, true)
        .environment(\.islandSize, island)
        .environment(\.sessionGlyphsAnimated, false)
    }

    static func card(_ env: AppEnvironment, _ id: String, island: IslandSize = .standard) -> IslandUIState {
        IslandGlassRenders.state(env, surface: .island, card: id, events: [(0, .present(.card(sessionID: id)))], at: 1.5, island: island)
    }

    /// Clean rows with Show model and Show branch on (the Codex row's branch and model, the compacting Claude's
    /// worktree), the same rows with both off as they were, and an approval whose header says Opus 5.5 · high and
    /// window-mode while its reason line no longer does.
    @Test func cleanRowsAndCardsSayTheirModelAndBranch() throws {
        for look in Self.looks {
            let on = Self.reportedEnvironment(model: true, branch: true, theme: look.theme, scheme: look.scheme, scenario: .details)
            try RenderHarness.render(Self.scene(IslandGlassRenders.state(on, surface: .island), look: look, size: CGSize(width: 540, height: 300)),
                                     "al-rows-model-branch-\(look.name)", env: on, scheme: look.scheme)
            let card = Self.reportedEnvironment(model: true, branch: true, theme: look.theme, scheme: look.scheme)
            try RenderHarness.render(Self.scene(Self.card(card, ID.approval), look: look, size: CGSize(width: 540, height: 360)),
                                     "al-card-model-branch-\(look.name)", env: card, scheme: look.scheme)
        }
        let off = Self.reportedEnvironment(model: false, branch: false, theme: .black, scheme: .dark, scenario: .details)
        try RenderHarness.render(Self.scene(IslandGlassRenders.state(off, surface: .island), look: Self.looks[0], size: CGSize(width: 540, height: 300)),
                                 "al-rows-model-branch-off-black-dark", env: off)
        let offCard = Self.reportedEnvironment(model: false, branch: false, theme: .black, scheme: .dark)
        try RenderHarness.render(Self.scene(Self.card(offCard, ID.approval), look: Self.looks[0], size: CGSize(width: 540, height: 360)),
                                 "al-card-model-branch-off-black-dark", env: offCard)
    }

    // MARK: Text size 16 (P1012)

    static func sized(_ style: IslandStyle, theme: JuiceTheme, scheme: ColorScheme, scenario: FixtureSessionFeed.Scenario = .prototype,
                      width: Int = 480) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        settings.islandUsagePlacement = .headerStrip
        settings.islandTextSize = 16
        settings.islandWidth = width
        settings.juiceTheme = theme
        settings.appearance = scheme == .light ? .light : .dark
        return AppEnvironment.demo(settings: settings, sessions: scenario)
    }

    /// The Clean and Detailed lists, a Clean approval card and a Detailed question card at 16 pt; a Done card with a
    /// table and code at 16 pt in the widest island.
    @Test func theIslandAtTextSize16() throws {
        let island = IslandSize(width: 480, text: 16)
        for look in Self.looks {
            for style in IslandStyle.allCases {
                let env = Self.sized(style, theme: look.theme, scheme: look.scheme)
                try RenderHarness.render(Self.scene(IslandGlassRenders.state(env, surface: .island, island: island), look: look,
                                                    size: CGSize(width: 540, height: style == .clean ? 360 : 520), island: island),
                                         "al-size16-\(style.rawValue)-list-\(look.name)", env: env, scheme: look.scheme)
            }
            let clean = Self.sized(.clean, theme: look.theme, scheme: look.scheme)
            try RenderHarness.render(Self.scene(Self.card(clean, ID.approval, island: island), look: look, size: CGSize(width: 540, height: 400),
                                                island: island),
                                     "al-size16-card-approval-\(look.name)", env: clean, scheme: look.scheme)
            let detailed = Self.sized(.detailed, theme: look.theme, scheme: look.scheme)
            let question = Self.scene(Self.card(detailed, ID.question, island: island), look: look, size: CGSize(width: 540, height: 460),
                                      island: island)
            try RenderHarness.renderHosted(question, "al-size16-card-question-\(look.name)", size: CGSize(width: 540, height: 460),
                                           env: detailed, scheme: look.scheme)
        }
        // As `IS-card-done-640-15` draws it: the card opened from its row, whole, in the widest island.
        let done = Self.sized(.clean, theme: .black, scheme: .dark, scenario: .markdown, width: 640)
        let view = OpenedIslandView(presentation: .card(sessionID: ID.markdownDone), notch: Self.notch, ui: IslandUIState(), animated: false)
            .environment(\.islandSize, IslandSize(width: 640, text: 16))
        let scene = DScene.island(view, notch: Self.notch)
        let probe = NSHostingView(rootView: scene.environment(done).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, "al-size16-card-done-640-black-dark", size: probe.fittingSize, env: done)
    }
}
