import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Lane c14/island: Settings › Island › Width and Text size at their narrowest and smallest and widest and largest
/// (`IS-island-*`, `IS-card-*`), the update dot on the pill and the gear (`IS-pill-update`, `IS-island-update`), the pane
/// with its new rows (`IS-settings-island`), and Show all over 120 sessions, live, at its top and scrolled far down
/// (`IS-many-*`). Nothing is shown on screen.
@MainActor
@Suite(.serialized)
struct IslandSizeRenders {
    typealias ID = FixtureSessionFeed.ID
    static let notch = IslandTheme.Metrics.referenceNotch

    @Test func narrowestAndWidest() throws {
        for style in IslandStyle.allCases {
            for (width, text) in [(460, 12), (640, 15)] {
                try island("IS-island-\(style.rawValue)-\(width)-\(text)", size: IslandSize(width: width, text: text)) {
                    $0.islandStyle = style
                    $0.islandUsagePlacement = .headerStrip
                }
            }
        }
    }

    @Test func cardsAtTheLargestText() throws {
        for (style, id) in [(IslandStyle.clean, ID.approval), (.detailed, ID.question)] {
            for width in [480, 640] {
                try island("IS-card-\(style.rawValue)-\(width)-15", .card(sessionID: id), size: IslandSize(width: width, text: 15)) {
                    $0.islandStyle = style
                }
            }
        }
        try island("IS-card-done-640-15", .card(sessionID: ID.markdownDone), scenario: .markdown, size: IslandSize(width: 640, text: 15))
    }

    @Test func theUpdateDot() throws {
        let checker = UpdateChecker(stamp: BuildStamp(commit: "3d741591c0ffee2a7b8e9f00112233445566aabb", repoPath: "/tmp/juice-island"),
                                    git: NoGitRunner(), state: .checked(UpdateInfo(newer: 3, subjects: ["Fix the island"]), at: DemoClock.now))
        let env = AppEnvironment.demo(settings: .ephemeral(), sessions: .prototype, updateChecker: checker)
        let pill = PillContent.make(rows: env.sessions.rows, settings: env.settings, glance: false, recentlyFinished: nil, now: env.sessions.now,
                                    notch: Self.notch, menuBar: IslandTheme.Metrics.referenceMenuBar, update: true)
        #expect(pill.update)
        try RenderHarness.render(DScene.pill(ClosedPillView(animated: false, content: pill)), "IS-pill-update", env: env)
        let view = OpenedIslandView(presentation: .list, notch: Self.notch, ui: IslandUIState(), animated: false)
        try RenderHarness.render(DScene.island(view, notch: Self.notch), "IS-island-update", env: env)
    }

    @Test func settingsIsland() throws {
        let settings = AppSettings.ephemeral()
        settings.islandWidth = 580
        settings.islandTextSize = 14
        let env = AppEnvironment.demo(settings: settings)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .island), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
            .environment(\.locale, Locale(identifier: "en_GB"))
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "IS-settings-island", size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    /// Show all over 120 sessions in the live island (its list in its scroll view), at its top, then scrolled to the 81st
    /// row by the keys, its rows built lazily as the list reached them.
    @Test func showAllOverManySessions() throws {
        let island = ManySessionsTests.harness(count: 120, maxHeight: 500)
        defer { island.close() }
        island.director.send(.list(.showAll))
        island.settle(0.8)
        try Self.write(island.snapshot(), "IS-many-showall-top")
        let order = SessionListLayout.displayOrder(island.env.sessions.rows, now: island.env.sessions.now)
        island.ui.selectedRow = order[80].id
        island.settle(1.0)
        try Self.write(island.snapshot(), "IS-many-showall-scrolled")
    }

    // MARK: Helpers

    private func island(_ name: String, _ presentation: IslandPresentation = .list, scenario: FixtureSessionFeed.Scenario = .prototype,
                        size: IslandSize, settings configure: (AppSettings) -> Void = { _ in }) throws {
        let settings = AppSettings.ephemeral()
        configure(settings)
        let env = AppEnvironment.demo(settings: settings, sessions: scenario)
        let view = OpenedIslandView(presentation: presentation, notch: Self.notch, ui: IslandUIState(), animated: false)
            .environment(\.islandSize, size)
        let scene = DScene.island(view, notch: Self.notch)
        guard presentation != .list else {
            try RenderHarness.render(scene, name, env: env)
            return
        }
        // Cards hold AppKit text fields, which `ImageRenderer` leaves blank: draw them hosted, at the scene's own size.
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }

    static func write(_ image: NSImage, _ name: String) throws {
        let data = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: RenderHarness.directory, withIntermediateDirectories: true)
        try data.write(to: RenderHarness.directory.appendingPathComponent(name + ".png"))
    }
}
