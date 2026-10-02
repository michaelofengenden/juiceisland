import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// In-app Update: the toolbar and Settings › About up to date, with changes on origin/main (the list shut and open),
/// a build not from origin/main, GitHub out of reach, each step of a run, after a failure (the control's one Retry),
/// when the owner is asked to restart (P98), and once after the relaunch; an update prepared ahead or being prepared (P711);
/// What's new in About, the window and the island (P716). No reference shots (the prototype has no updater).
/// `zsh scripts/render-all.sh UpdateRenders`.
@MainActor
@Suite(.serialized)
struct UpdateRenders {
    private static let stamp = BuildStamp(commit: "3d741591c0ffee2a7b8e9f00112233445566aabb", date: Date(timeIntervalSince1970: 1_790_236_800),
                                          repoPath: "/tmp/juice-island")
    private static let checkedAt = Date(timeIntervalSince1970: 1_790_236_800)
    private static let upToDate = UpdateCheckState.checked(UpdateInfo(newer: 0, subjects: []), at: checkedAt)
    private static let info = UpdateInfo(newer: 12, subjects: [
        "Add the in-app Update button", "Keep the island pill centred on a second display", "Show the Codex app's waiting threads",
        "Fix the money strip's amount when the island opens", "Read the build stamp from Info.plist", "Stop the hourly check on quit",
        "Name the update log in About", "Round the toolbar pill copy's corners", "Tighten the Diagnostics table columns",
        "Record the owner's decision on updates",
    ])

    private static func env(phase: UpdatePhase = .idle, state: UpdateCheckState? = nil, showsChanges: Bool = false) -> AppEnvironment {
        let checker = UpdateChecker(stamp: stamp, git: NoGitRunner(), state: state ?? .checked(info, at: checkedAt))
        checker.showsChanges = showsChanges
        let controller = UpdateController(repoPath: stamp.repoPath, phase: phase)
        return .demo(sessions: .prototype, updateChecker: checker, updateController: controller)
    }

    @Test func toolbarWithAnUpdate() throws {
        try RenderHarness.renderHosted(WindowToolbarView(drawsTrafficLights: true).background(Color.black), "U-toolbar-update-available",
                                       size: CGSize(width: 1200, height: WindowChromeMetrics.standard.lineHeight), env: Self.env())
    }

    @Test func toolbarBuilding() throws {
        try RenderHarness.renderHosted(WindowToolbarView(drawsTrafficLights: true).background(Color.black), "U-toolbar-building",
                                       size: CGSize(width: 1200, height: WindowChromeMetrics.standard.lineHeight), env: Self.env(phase: .building))
    }

    @Test func toolbarUpToDateShowsNothing() throws {
        try RenderHarness.renderHosted(WindowToolbarView(drawsTrafficLights: true).background(Color.black), "U-toolbar-up-to-date",
                                       size: CGSize(width: 1200, height: WindowChromeMetrics.standard.lineHeight), env: Self.env(state: Self.upToDate))
    }

    @Test func toolbarRestartNeeded() throws {
        try RenderHarness.renderHosted(WindowToolbarView(drawsTrafficLights: true).background(Color.black), "U-toolbar-restart-needed",
                                       size: CGSize(width: 1200, height: WindowChromeMetrics.standard.lineHeight),
                                       env: Self.env(phase: .restartNeeded))
    }

    @Test func toolbarUpdated() throws {
        try RenderHarness.renderHosted(WindowToolbarView(drawsTrafficLights: true).background(Color.black), "U-toolbar-updated",
                                       size: CGSize(width: 1200, height: WindowChromeMetrics.standard.lineHeight),
                                       env: Self.env(phase: .updated("3d74159"), state: Self.upToDate))
    }

    @Test func aboutRestartNeeded() throws {
        try renderAbout("U-settings-about-restart-needed", env: Self.env(phase: .restartNeeded))
    }

    @Test func aboutUpdated() throws {
        try renderAbout("U-settings-about-updated", env: Self.env(phase: .updated("3d74159"), state: Self.upToDate))
    }

    @Test func aboutUpToDate() throws {
        try renderAbout("U-settings-about-up-to-date", env: Self.env(state: Self.upToDate))
    }

    /// "12 changes", the list shut: the default.
    @Test func aboutWithAnUpdate() throws {
        try renderAbout("U-settings-about-update-available", env: Self.env())
    }

    @Test func aboutWithAnUpdateListOpen() throws {
        try renderAbout("U-settings-about-update-list-open", env: Self.env(showsChanges: true))
    }

    /// A dirty build of origin/main's commit: nothing new, still offered origin/main.
    @Test func aboutNotBuiltFromOriginMain() throws {
        let dirty = BuildStamp(commit: Self.stamp.commit, dirty: true, date: Self.stamp.date, repoPath: Self.stamp.repoPath)
        let checker = UpdateChecker(stamp: dirty, git: NoGitRunner(),
                                    state: .checked(UpdateInfo(newer: 0, subjects: [], dirty: true), at: Self.checkedAt))
        let env = AppEnvironment.demo(sessions: .prototype, updateChecker: checker,
                                      updateController: UpdateController(repoPath: dirty.repoPath))
        try renderAbout("U-settings-about-not-origin-main", env: env)
    }

    @Test func aboutCantReachGitHub() throws {
        try renderAbout("U-settings-about-cant-reach-github", env: Self.env(state: .failed(UpdateChecker.unreachable, at: Self.checkedAt)))
    }

    @Test func aboutChecking() throws {
        try renderAbout("U-settings-about-checking", env: Self.env(state: .checking))
    }

    @Test func aboutFetching() throws {
        try renderAbout("U-settings-about-fetching", env: Self.env(phase: .pulling))
    }

    @Test func aboutBuilding() throws {
        try renderAbout("U-settings-about-building", env: Self.env(phase: .building))
    }

    @Test func aboutInstalling() throws {
        try renderAbout("U-settings-about-installing", env: Self.env(phase: .installing))
    }

    @Test func aboutRestarting() throws {
        try renderAbout("U-settings-about-restarting", env: Self.env(phase: .restarting))
    }

    @Test func aboutFailed() throws {
        try renderAbout("U-settings-about-failed", env: Self.env(phase: .failed(reason: "the new build's signature does not verify")))
    }

    /// The update's own fetch failed after a check had found the changes: they stay, with no Update now beside
    /// them; the control says Update failed with its one Retry.
    @Test func aboutFailedCantReachGitHub() throws {
        try renderAbout("U-settings-about-failed-offline", env: Self.env(phase: .failed(reason: "can't reach GitHub")))
    }

    // MARK: Prepared ahead (P711) and What's new (P716)

    private static let tip = String(repeating: "5", count: 40)

    /// An offered update a background prepare is building (`preparing`) or has built (`prepared`).
    private static func preparedEnv(preparing: Bool = false) -> AppEnvironment {
        var offered = info
        offered.tip = tip
        let checker = UpdateChecker(stamp: stamp, git: NoGitRunner(), state: .checked(offered, at: checkedAt))
        let controller = UpdateController(repoPath: stamp.repoPath, commit: stamp.commit, prepared: preparing ? nil : tip,
                                          preparing: preparing, context: UpdateController.Context(prepareEnabled: { true }))
        return .demo(sessions: .prototype, updateChecker: checker, updateController: controller)
    }

    @Test func toolbarRestartToUpdate() throws {
        try RenderHarness.renderHosted(WindowToolbarView(drawsTrafficLights: true).background(Color.black), "U-toolbar-restart-to-update",
                                       size: CGSize(width: 1200, height: WindowChromeMetrics.standard.lineHeight), env: Self.preparedEnv())
    }

    @Test func aboutPrepared() throws {
        try renderAbout("U-settings-about-prepared", env: Self.preparedEnv())
    }

    @Test func aboutPreparing() throws {
        try renderAbout("U-settings-about-preparing", env: Self.preparedEnv(preparing: true))
    }

    /// After the relaunch: What's new in the place of "Updated", its list open.
    @Test func aboutWhatsNew() throws {
        try renderAbout("U-settings-about-whats-new", env: try WhatsNewTests.env(subjects: 7, phase: .updated("2222222"), listOpen: true))
    }

    @Test func aboutWhatsNewShut() throws {
        try renderAbout("U-settings-about-whats-new-shut", env: try WhatsNewTests.env(subjects: 7))
    }

    /// The card under the window's header: four subjects and "and 12 more".
    @Test func windowWhatsNew() throws {
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "U-window-whats-new", size: WindowTheme.Metrics.defaultSize,
                                       env: try WhatsNewTests.env(subjects: 7))
    }

    /// Two changes: no "and N more".
    @Test func windowWhatsNewShort() throws {
        let env = try WhatsNewTests.env(subjects: 2)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "U-window-whats-new-short", size: CGSize(width: 900, height: 560),
                                       env: env)
    }

    @Test(arguments: [JuiceTheme.black, .glass, .smoke])
    func islandWhatsNew(_ theme: JuiceTheme) throws {
        let env = try WhatsNewTests.env(subjects: 7)
        env.settings.juiceTheme = theme
        let view = OpenedIslandView(presentation: .list, notch: IslandTheme.Metrics.referenceNotch, ui: IslandUIState(), animated: false)
            .environment(\.juiceTheme, theme)
        try RenderHarness.render(DScene.island(view, notch: IslandTheme.Metrics.referenceNotch), "U-island-whats-new-\(theme.rawValue)", env: env)
    }

    private func renderAbout(_ name: String, env: AppEnvironment) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .about), drawsTrafficLights: true, scrolls: false)
        let hosting = NSHostingView(rootView: view.frame(width: SettingsTheme.Metrics.width).fixedSize(horizontal: false, vertical: true)
            .environment(env).environment(\.colorScheme, .dark))
        let height = max(SettingsTheme.Metrics.minHeight, ceil(hosting.fittingSize.height))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }
}
