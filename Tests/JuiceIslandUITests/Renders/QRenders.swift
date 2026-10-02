import AppKit
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// P125, the batteries' insight: the run-out in the window header's caption and the island's hover, the account list's
/// sparklines, and the island's quota notices (Clean and Detailed). Demo data: Lab burns out in about 45 minutes before
/// its reset in 2:05, Team in about 20 before its 1:02.
@MainActor
@Suite(.serialized)
struct QRenders {
    private static func environment(_ configure: (AppSettings) -> Void = { _ in }) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.windowHeader = .section
        configure(settings)
        return .demo(settings: settings)
    }

    private static func id(_ alias: String) -> String { DStub.accountID(alias) }

    // MARK: The window

    private func header(_ name: String, hover: HoverTargetID) throws {
        let env = Self.environment()
        let view = WindowHeaderView(drawsTrafficLights: true, hover: hover, allowsTitleLine: false)
            .overlay(alignment: .bottom) { WindowTheme.hairline.frame(height: 1) }
            .frame(width: 1200)
            .padding(8)
            .background(Color.black)
        let height = ceil(NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true).environment(env)
            .environment(\.colorScheme, .dark)).fittingSize.height)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: 1216, height: height), env: env)
    }

    @Test func headerHoverLab() throws { try header("Q-header-hover-lab", hover: .account(Self.id("Lab"))) }
    @Test func headerHoverTeam() throws { try header("Q-header-hover-team", hover: .account(Self.id("Team"))) }

    private func popover(_ name: String, provider: Provider, alias: String) throws {
        let env = Self.environment()
        let view = AccountListView(provider: provider, selected: Self.id(alias)).padding(20)
        try RenderHarness.render(view, name, env: env, background: WindowTheme.bg)
    }

    @Test func accountListClaude() throws { try popover("Q-account-list-claude", provider: .claude, alias: "Lab") }
    @Test func accountListCodex() throws { try popover("Q-account-list-codex", provider: .codex, alias: "Team") }

    // MARK: The island

    private func island(_ name: String, _ presentation: IslandPresentation = .list, ui: IslandUIState = IslandUIState(),
                        notice: QuotaNotice? = nil, style: IslandStyle = .clean) throws {
        let env = Self.environment { $0.islandStyle = style }
        env.islandNotice = notice
        let notch = IslandTheme.Metrics.referenceNotch
        let view = OpenedIslandView(presentation: presentation, notch: notch, ui: ui, animated: false)
        let scene = DScene.island(view, notch: notch)
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }

    @Test func islandHoverTeam() throws {
        try island("Q-island-clean-hover-team", ui: IslandUIState(hover: .account(Self.id("Team")), stripOpen: true))
    }

    @Test func islandHoverLab() throws {
        try island("Q-island-clean-hover-lab", ui: IslandUIState(hover: .account(Self.id("Lab")), stripOpen: true))
    }

    private static func notice(_ alias: String, _ kind: (BatteryModel, AccountReading) -> QuotaNotice.Kind) throws -> QuotaNotice {
        let usage = DemoUsageModel(now: DemoClock.now)
        let battery = try #require(usage.battery(id: id(alias)))
        let reading = try #require(usage.records[battery.id]?.lastGood)
        let provider = usage.account(id: battery.id)?.provider ?? .claude
        return QuotaNotice(account: battery.id, provider: provider, kind: kind(battery, reading), at: reading.readAt)
    }

    @Test(arguments: [IslandStyle.clean, .detailed])
    func noticeRunningOut(_ style: IslandStyle) throws {
        let notice = try Self.notice("Team") { battery, _ in .runningOut(battery.runOut!) }
        try island("Q-island-\(style.rawValue)-notice-runout", .card(sessionID: QuotaNoticeCard(notice: notice).sessionID),
                   notice: notice, style: style)
    }

    @Test func noticeLow() throws {
        let notice = try Self.notice("Team") { _, reading in
            .low(window: "5h", percentLeft: reading.windows[0].percentLeft, resetsAt: reading.windows[0].resetsAt)
        }
        try island("Q-island-clean-notice-low", .card(sessionID: QuotaNoticeCard(notice: notice).sessionID), notice: notice)
    }

    @Test func noticeBack() throws {
        let notice = try Self.notice("Work") { _, reading in .back(percentLeft: Rules.percentLeft(reading)) }
        try island("Q-island-clean-notice-back", .card(sessionID: QuotaNoticeCard(notice: notice).sessionID), notice: notice)
    }
}
