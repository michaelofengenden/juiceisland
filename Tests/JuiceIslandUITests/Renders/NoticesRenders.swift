import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Remind again (P410), Questions open the island (P411) and Notification banners (P412). `NT-settings-general-*`: the
/// Behavior section with Remind again at 2 min and Notification banners on, allowed (`-notices`), not asked yet (Allow)
/// and turned off in System Settings (Open System Settings). `NT-settings-island-questions-off`: the Sessions section
/// with its line. `NT-pill-nudge-*`: the closed pill at rest and at the reminder's peak, Pixel and Liquid (Reduce
/// Motion's dimmed step is checked by value: the environment's flag cannot be set in a render). A fake notification
/// center: nothing asks macOS or posts.
@MainActor
@Suite(.serialized)
struct NoticesRenders {
    private func renderPane(_ pane: SettingsPane, _ name: String, env: AppEnvironment) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: pane), drawsTrafficLights: true, scrolls: false)
            .environment(\.sessionGlyphsAnimated, false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    private func generalPane(_ name: String, permission: BannerPermission) async throws {
        let settings = AppSettings.ephemeral()
        settings.followUpAfter = .twoMinutes
        settings.notificationBanners = true
        let env = AppEnvironment.demo(settings: settings)
        let center = FakeBannerCenter()
        center.status = permission
        let banners = Banners(settings: settings, sessions: env.sessions, center: { center })
        env.banners = banners
        banners.start()
        await NoticeFixtures.settle { banners.permission == permission }
        #expect(banners.permission == permission && center.asked == 0)
        try renderPane(.general, name, env: env)
    }

    @Test func generalNotices() async throws {
        try await generalPane("NT-settings-general-notices", permission: .allowed)
    }

    @Test func generalBannersNotAsked() async throws {
        try await generalPane("NT-settings-general-banners-not-asked", permission: .notAsked)
    }

    @Test func generalBannersDenied() async throws {
        try await generalPane("NT-settings-general-banners-denied", permission: .denied)
    }

    @Test func islandQuestionsOff() throws {
        let settings = AppSettings.ephemeral()
        settings.questionsOpenIsland = false
        try renderPane(.island, "NT-settings-island-questions-off", env: .demo(settings: settings))
    }

    @Test func thePillsReminder() throws {
        let rows = [NoticeFixtures.waiting("q", question: true), ActiveCountTests.row("r", .codex, .running, ago: 10)]
        for style in [GlyphStyle.pixel, .liquid] {
            let settings = AppSettings.ephemeral()
            settings.glyphStyle = style
            let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
            let content = QuietModeTests.pill(rows, settings: settings, fullScreen: false)
            #expect(content.lead?.glyph == .ques)
            for (moment, phase) in [("rest", nil), ("peak", 0.16)] as [(String, TimeInterval?)] {
                let pill = ClosedPillView(animated: false, content: content, nudge: 1, nudgePhase: phase)
                try RenderHarness.render(DScene.pill(pill), "NT-pill-nudge-\(style.rawValue)-\(moment)", env: env)
            }
        }
        let peak = NudgePulse.value(at: 0.16, reduceMotion: false)
        #expect(peak.scale > 1.1 && peak.scale <= NudgePulse.peak + 0.001 && peak.glow > 0.3)
        #expect(NudgePulse.value(at: NudgePulse.duration, reduceMotion: false) == NudgePulse.Values())
        let dimmed = NudgePulse.value(at: 0.2, reduceMotion: true)
        #expect(dimmed.scale == 1 && dimmed.opacity < 0.4)
    }
}
