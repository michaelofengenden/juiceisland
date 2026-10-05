import AppKit
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Wave 3's app lane, headless, every file named `w3a-*`: each pane it changed, in both flavors where they differ.
/// Settings › Island (Motion in the private app only; Hover in both), Settings › Diagnostics (Motion's tools in the
/// private app; Report a Bug beside Copy Report in the public one), Settings › About (Prepare and Install automatically
/// in the private app, Install automatically alone over the public feed), Settings › Accounts with Add Folder… (the same
/// in both), and the window's What's new card after an automatic install. Fixture data only; nothing is shown.
@MainActor
@Suite(.serialized)
struct AppLaneRenders {
    static let stamp = BuildStamp(commit: "3d741591c0ffee2a7b8e9f00112233445566aabb", date: Date(timeIntervalSince1970: 1_790_236_800),
                                  repoPath: "/tmp/juice-island")

    static func flavorWord(_ flavor: AppFlavor) -> String { flavor.isPublic ? "public" : "private" }
    nonisolated static let flavors: [AppFlavor] = [.private, AppFlavor(kind: .public, productName: "Juice",
                                                                        bundleIdentifier: "io.github.michaelofengenden.juice",
                                                                        publicRepo: "michaelofengenden/juiceisland")]

    private func render(_ pane: SettingsPane, _ name: String, env: AppEnvironment) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    @Test(arguments: flavors)
    func islandPane(_ flavor: AppFlavor) throws {
        let env = AppEnvironment.demo()
        env.flavor = flavor
        try render(.island, "w3a-settings-island-\(Self.flavorWord(flavor))", env: env)
    }

    @Test(arguments: flavors)
    func diagnosticsPane(_ flavor: AppFlavor) throws {
        let env = AppEnvironment.demo()
        env.flavor = flavor
        try render(.diagnostics, "w3a-settings-diagnostics-\(Self.flavorWord(flavor))", env: env)
    }

    /// The private app: Prepare on, Install automatically off (the default), then on, over an offered update.
    @Test func aboutPanePrivate() throws {
        for automatic in [false, true] {
            let checker = UpdateChecker(stamp: Self.stamp, git: NoGitRunner(),
                                        state: .checked(UpdateInfo(newer: 3, subjects: ["Install updates by themselves", "Add Folder…",
                                                                                         "Report a bug"]), at: Date(timeIntervalSince1970: 1_790_236_800)))
            let env = AppEnvironment.demo(updateChecker: checker, updateController: UpdateController(repoPath: Self.stamp.repoPath))
            env.flavor = .private
            env.settings.installAutomatically = automatic
            try render(.about, "w3a-settings-about-private" + (automatic ? "-automatic" : ""), env: env)
        }
    }

    /// The public flavor: its feed's rows, Install automatically alone (no Prepare), off.
    @Test func aboutPanePublic() throws {
        let settings = AppSettings.ephemeral()
        let (checker, controller) = AppEnvironment.updates(stamp: Self.stamp, settings: settings, flavor: PublicFlavorTests.publicFlavor,
                                                           feed: StillFeed(), version: "0.4.0", memory: .inMemory())
        checker.report(.checked(UpdateInfo(newer: 0, subjects: []), at: Date(timeIntervalSince1970: 1_790_236_800)))
        let env = AppEnvironment.demo(settings: settings, updateChecker: checker, updateController: controller)
        env.flavor = PublicFlavorTests.publicFlavor
        try render(.about, "w3a-settings-about-public", env: env)
    }

    /// Settings › Accounts over the live model's fixture: Add Folder… in the last group, beside the sign-in browser.
    @Test func accountsPane() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let model = try await AccountsRenders.model(fakes)
        defer {
            model.stop()
            fakes.holdQuestions.withValue { $0 = false }
        }
        try render(.accounts, "w3a-settings-accounts-add-folder", env: RRenders.environment(model))
    }

    /// The build Install automatically opened: the window's card says "Updated automatically" over what changed.
    @Test func windowUpdatedAutomatically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-auto-render-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = UpdateController.Paths(statusFile: root.appendingPathComponent("update-status"), logFile: root.appendingPathComponent("update.log"))
        let subjects = Array(WhatsNewTests.sampleSubjects.prefix(3))
        try WhatsNewTests.file(count: 3, subjects).write(to: paths.whatsNewFile, atomically: true, encoding: .utf8)
        var marker: String? = WhatsNewTests.new
        let context = UpdateController.Context(automaticCommit: { marker }, markAutomatic: { marker = $0 })
        let controller = UpdateController(repoPath: "/tmp/juice-island", build: String(WhatsNewTests.new.prefix(7)), commit: WhatsNewTests.new,
                                          paths: paths, bundlePath: "/tmp/Juice Island.app", context: context)
        controller.restoreAfterLaunch()
        #expect(controller.installedAutomatically && controller.showsWhatsNewCard && marker == nil)
        let env = AppEnvironment.demo(sessions: .prototype, updateController: controller)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true).environment(\.sessionGlyphsAnimated, false),
                                       "w3a-window-updated-automatically", size: CGSize(width: 900, height: 560), env: env)
    }
}

/// A feed that never checks or reports: the public About pane as it is between checks.
@MainActor
private final class StillFeed: FeedUpdating {
    func start(report: @escaping @MainActor (FeedUpdateEvent) -> Void) {}
    func checkNow() -> Bool { false }
    func install() -> Bool { false }
    func relaunch() {}
}
