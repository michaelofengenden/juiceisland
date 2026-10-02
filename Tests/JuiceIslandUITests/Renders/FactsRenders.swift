import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 6's facts lane (P440, P443, P446): a long build fifteen minutes into its call, running beside a session stalled with
/// nothing in flight; a finished row's peek with Claude Code's recap, in both styles. The effort beside the model shows in
/// `rw-island-detailed` and `rw-peek-clean-codex`. Names `fx-…`: `zsh scripts/render-all.sh FactsRenders`.
@MainActor
@Suite(.serialized)
struct FactsRenders {
    typealias ID = FixtureSessionFeed.RowsID
    static let notch = IslandTheme.Metrics.referenceNotch

    /// The rows scenario with the long build, `minutes` after its call began.
    static func env(_ style: IslandStyle, minutes: TimeInterval = 15) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        let clock = FactsLaneUITests.Clock()
        clock.now = DemoClock.now + minutes * 60
        let (_, model) = FactsLaneUITests.model(clock: clock)
        return AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: model)
    }

    /// The opened island fifteen minutes into the long build: "Bash" and 15m, no Stalled; the session quiet with nothing
    /// in flight says Stalled.
    @Test(arguments: [IslandStyle.clean, .detailed])
    func longBuild(_ style: IslandStyle) throws {
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "fx-long-build-\(style.rawValue)", env: Self.env(style))
    }

    /// The finished Claude row's peek with the recap Claude Code wrote while the owner was away.
    @Test(arguments: [IslandStyle.clean, .detailed])
    func peekRecap(_ style: IslandStyle) throws {
        let settings = AppSettings.ephemeral()
        settings.islandStyle = style
        let env = AppEnvironment.demo(settings: settings, sessions: .rows, stalledAfter: 600)
        let row = try #require(env.sessions.row(id: ID.claudeDone))
        let read = SessionPeekRead(prompt: "fix it and run it 50 times", reply: FixtureSessionFeed.rowsDoneReply,
                                   recap: "We split the upload retries out of the client and the flaky test now passes 50 runs in a row. "
                                       + "Next: rename the old flag in the docs and add the lockfile to the CI cache key.")
        let peek = try #require(SessionPeek.make(row: row, clean: style == .clean, prompt: row.lastPrompt,
                                                 reply: FixtureSessionFeed.rowsDoneReply, replyIsCurrent: true, read: read))
        let ui = IslandUIState()
        ui.peek = peek
        let view = DScene.island(OpenedIslandView(presentation: .list, notch: Self.notch, ui: ui, animated: false), notch: Self.notch)
            .environment(\.sessionGlyphsAnimated, false)
        let hosting = NSHostingView(rootView: view.environment(env).environment(\.colorScheme, .dark))
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let size = CGSize(width: 920, height: ceil(hosting.fittingSize.height))
        try RenderHarness.renderHosted(view, "fx-peek-recap-\(style.rawValue)", size: size, env: env)
    }
}
