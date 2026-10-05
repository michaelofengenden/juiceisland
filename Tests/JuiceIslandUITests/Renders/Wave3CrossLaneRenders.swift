import AppKit
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 3's lanes on one surface (P1078): the island's approval card at text size 16 with Show model and Show branch on,
/// its Allow all row, and Option's keys held. Black dark and Glass light. Files `w3i-*`; nothing on screen.
@MainActor
@Suite(.serialized)
struct Wave3CrossLaneRenders {
    typealias ID = FixtureSessionFeed.ID

    /// The oldest of the five approvals of the cards scenario, at 16 pt in the island, with the keys shown as Option
    /// makes them. Its session reports a model at an effort and a long branch (the scenario's own sessions report
    /// neither, W3R-4), so the header carries "N more", the branch and "Opus 5.5 · high" at once.
    @Test func theApprovalCardAtSixteenWithAllowAll() throws {
        let island = IslandSize(width: 480, text: 16)
        for look in [AlertsRenders.looks[0], AlertsRenders.looks[2]] {
            let sized = AlertsRenders.sized(.clean, theme: look.theme, scheme: look.scheme, scenario: .cards)
            let sessions = AlertsRenders.Reported(sized.sessions, facts: [ID.write: RowFacts(model: "Opus 5.5", effort: "high")],
                                                  branches: [ID.write: "release-notes-for-the-spring-update"])
            let env = AppEnvironment(settings: sized.settings, usage: sized.usage, sessions: sessions)
            #expect(env.sessions.row(id: ID.write)?.branch == "release-notes-for-the-spring-update")
            #expect(BatchAnswer.targets(env).count == 5)
            env.settings.rowShowsModel = true
            env.settings.rowShowsBranch = true
            env.settings.shortcutModifier = .option
            let size = CGSize(width: 540, height: 470)
            let scene = AlertsRenders.scene(AlertsRenders.card(env, ID.write, island: island), look: look, size: size, island: island)
                .environment(\.showsShortcutHints, true)
            try RenderHarness.renderHosted(scene, "w3i-island-allow-all-16-\(look.name)", size: size, env: env, scheme: look.scheme)
        }
    }
}
