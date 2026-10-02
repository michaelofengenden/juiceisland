import AppKit
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The Update control (P803 to P809), headless, in Black, Glass light and dark, and Solid light: a sheet of every state
/// at both sizes (the toolbar's on the window, About's on a Settings group), the glow at its height and Reduce Motion's
/// track and words; and the toolbar and Settings › About with the control offered, building at 63 %, finished, and
/// failed, and the whole window while it builds. Files `uc-*`. `zsh scripts/render-all.sh UpdateControlRenders`.
@MainActor
@Suite(.serialized)
struct UpdateControlRenders {
    struct Look: Sendable {
        var name: String
        var theme: JuiceTheme
        var scheme: ColorScheme
    }

    nonisolated static let looks = [Look(name: "black", theme: .black, scheme: .dark), Look(name: "glass-light", theme: .glass, scheme: .light),
                                    Look(name: "glass-dark", theme: .glass, scheme: .dark), Look(name: "solid-light", theme: .solid, scheme: .light)]

    /// Every state, in a run's order, with what the sheet calls it.
    static let states: [(name: String, state: UpdateControlState, glow: Double, reduceMotion: Bool)] = [
        ("offered", .offer(restart: false), 0, false),
        ("prepared", .offer(restart: true), 0, false),
        ("hover", .offer(restart: false), 0, false),
        ("fetching", .running(words: "Fetching", fraction: UpdateProgress.fetching), 0, false),
        ("building, no estimate", .running(words: "Building", fraction: UpdateProgress.fetchEnd), 0, false),
        ("building 21%", .running(words: "Building 21%", fraction: 0.04 + 0.88 * 0.21), 0, false),
        ("building 63%", .running(words: "Building 63%", fraction: 0.04 + 0.88 * 0.63), 0, false),
        ("past the estimate", .running(words: "Building", fraction: UpdateProgress.buildEnd), 0, false),
        ("installing", .running(words: "Installing", fraction: UpdateProgress.checking), 0, false),
        ("finished", .finished, 0, false),
        ("finished, glowing", .finished, 1, false),
        ("restart needed", .restartNeeded, 0, false),
        ("failed", .failed(reason: "the build failed"), 0, false),
        ("failed, Retry hovered", .failed(reason: "the build failed"), 0, false),
        ("updated", .updated("3d74159"), 0, false),
        ("Reduce Motion: building 63%", .running(words: "Building 63%", fraction: 0.04 + 0.88 * 0.63), 0, true),
        ("Reduce Motion: finished", .finished, 0, true),
    ]

    @Test(arguments: looks)
    func sheet(_ look: Look) throws {
        let rows = VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Self.states.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 18) {
                    Text(row.name).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink2).frame(width: 190, alignment: .leading)
                    UpdateControlFace(state: row.state, size: .toolbar, hovering: row.name == "hover",
                                      hoveringRetry: row.name == "failed, Retry hovered", glow: row.glow, reduceMotion: row.reduceMotion)
                        .padding(12)
                        .background(WindowTheme.bg)
                    UpdateControlFace(state: row.state, size: .about, hovering: row.name == "hover",
                                      hoveringRetry: row.name == "failed, Retry hovered", glow: row.glow, reduceMotion: row.reduceMotion)
                        .padding(12)
                        .background(SettingsTheme.group)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .padding(.vertical, 12)
        .frame(width: 620, alignment: .leading)
        .background(SettingsTheme.window)
        let env = Self.env(look, phase: .idle)
        try RenderHarness.renderHosted(rows, "uc-sheet-\(look.name)", size: CGSize(width: 620, height: 24 + CGFloat(Self.states.count) * 60),
                                       env: env, scheme: look.scheme)
    }

    /// The four moments the owner sees most, in the window's toolbar and in About.
    static let moments: [(name: String, phase: UpdatePhase, progress: UpdateProgress?)] = [
        ("offered", .idle, nil),
        ("building", .building, UpdateProgress(fraction: 0.04 + 0.88 * 0.63, buildPercent: 63, secondsLeft: 53)),
        ("finished", .restarting, nil),
        ("failed", .failed(reason: "the build failed"), nil),
    ]

    @Test(arguments: looks)
    func toolbar(_ look: Look) throws {
        for moment in Self.moments {
            let env = Self.env(look, phase: moment.phase, progress: moment.progress)
            let view = WindowToolbarView(drawsTrafficLights: true).background(WindowTheme.bg).windowLookFromSettings()
            try RenderHarness.renderHosted(view, "uc-toolbar-\(moment.name)-\(look.name)",
                                           size: CGSize(width: 900, height: WindowChromeMetrics.standard.lineHeight), env: env, scheme: look.scheme)
        }
    }

    @Test(arguments: looks)
    func about(_ look: Look) throws {
        for moment in Self.moments {
            let env = Self.env(look, phase: moment.phase, progress: moment.progress)
            let view = SettingsRootView(navigation: SettingsNavigation(pane: .about), drawsTrafficLights: true, scrolls: false)
            let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
            try RenderHarness.renderHosted(view, "uc-about-\(moment.name)-\(look.name)",
                                           size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env, scheme: look.scheme)
        }
    }

    /// A failure restored at launch, before the first check ends: no update known, so the control's row has no words
    /// of its own, and the reason with Show Log is under it.
    @Test(arguments: [looks[1]])
    func aboutFailedWithNoUpdateKnown(_ look: Look) throws {
        let env = Self.env(look, phase: .failed(reason: "the build failed"), known: false)
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .about), drawsTrafficLights: true, scrolls: false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, "uc-about-failed-unknown-\(look.name)",
                                       size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env, scheme: look.scheme)
    }

    /// The whole window at its default size, building: the control beside the usage on the title line.
    @Test(arguments: [looks[0], looks[1]])
    func window(_ look: Look) throws {
        let env = Self.env(look, phase: .building, progress: Self.moments[1].progress)
        try RenderHarness.renderHosted(WindowRootView(drawsTrafficLights: true), "uc-window-building-\(look.name)",
                                       size: WindowTheme.Metrics.defaultSize, env: env, scheme: look.scheme)
    }

    /// Twelve changes offered at a known tip (none known when `known` is false: no check has ended), the run at `phase`.
    static func env(_ look: Look, phase: UpdatePhase, progress: UpdateProgress? = nil, known: Bool = true) -> AppEnvironment {
        let stamp = BuildStamp(commit: "3d741591c0ffee2a7b8e9f00112233445566aabb", date: Date(timeIntervalSince1970: 1_790_236_800),
                               repoPath: "/tmp/juice-island")
        var info = UpdateInfo(newer: 12, subjects: ["Give the Update button its progress", "Say the time a build has left"])
        info.tip = String(repeating: "5", count: 40)
        let checker = UpdateChecker(stamp: stamp, git: NoGitRunner(),
                                    state: known ? .checked(info, at: Date(timeIntervalSince1970: 1_790_236_800)) : .idle)
        let controller = UpdateController(repoPath: stamp.repoPath, commit: stamp.commit, phase: phase, progress: progress)
        let settings = AppSettings.ephemeral()
        settings.juiceTheme = look.theme
        settings.appearance = look.scheme == .light ? .light : .dark
        return .demo(settings: settings, sessions: .prototype, updateChecker: checker, updateController: controller)
    }
}
