import AppKit
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream B: the usage header (Section and Strip, both widths, names, hover captions, runway and no-key states), the
/// account list and the island's Clean usage block. Refs: `refs/B-*.png`. Each header render is cropped like its ref
/// (the `.aw-use` box plus 8 pt of the window around it; the window's 0.5 pt edge is not drawn). The refs draw Section,
/// so a render not named `strip` sets Section (the app's default is Strip).
@MainActor
@Suite(.serialized)
struct BRenders {
    /// The window's header at `width`: the toolbar line (usage on it when it fits) and the band under it, 8 pt of
    /// window around it and its own 1 pt bottom rule. `band` keeps the usage off the title line.
    private func header(_ name: String, width: CGFloat = 1200, env: AppEnvironment = Self.section(), hover: HoverTargetID? = nil,
                        band: Bool = false) throws {
        let view = WindowHeaderView(drawsTrafficLights: true, hover: hover, allowsTitleLine: !band)
            .overlay(alignment: .bottom) { WindowTheme.hairline.frame(height: 1) }
            .frame(width: width)
            .padding(8)
            .background(Color.black)
        let height = ceil(NSHostingView(rootView: view.fixedSize(horizontal: false, vertical: true).environment(env)
            .environment(\.colorScheme, .dark)).fittingSize.height)
        try RenderHarness.renderHosted(view, name, size: CGSize(width: width + 16, height: height), env: env)
    }

    private func env(_ configure: (AppSettings) -> Void = { _ in }, usage: DemoUsageModel.Variant = .standard) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.windowHeader = .section
        configure(settings)
        return .demo(settings: settings, usage: usage)
    }

    /// The demo with a Section header, as the refs draw it.
    private static func section() -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        settings.windowHeader = .section
        return .demo(settings: settings)
    }

    @Test func headerSection1200() throws { try header("B-header-section-1200") }
    @Test func headerSection900() throws { try header("B-header-section-900", width: 900) }
    @Test func headerStrip1200() throws { try header("B-header-strip-1200", env: env { $0.windowHeader = .strip }) }
    @Test func headerStrip900() throws { try header("B-header-strip-900", width: 900, env: env { $0.windowHeader = .strip }) }
    @Test func headerSectionNames() throws {
        try header("B-header-section-names-1200", env: env { $0.accountNamesUnderBatteries = true })
    }
    @Test func headerStripNames() throws {
        try header("B-header-strip-names-1200", env: env { $0.windowHeader = .strip; $0.accountNamesUnderBatteries = true })
    }
    @Test func headerHoverResearch() throws {
        let environment = env()
        let research = try #require(environment.usage.claudeRow?.batteries.first { $0.alias == "Research" })
        try header("B-header-hover-research", env: environment, hover: .account(research.id))
    }
    @Test func headerHoverAnthropic() throws { try header("B-header-hover-anthropic", hover: .money("Anthropic")) }
    @Test func headerHoverRunPod() throws { try header("B-header-hover-runpod", hover: .money("RunPod")) }
    @Test func headerNoMoney() throws { try header("B-header-nomoney", env: env { $0.windowShowsMoney = false }) }
    @Test func headerNoMoney900() throws { try header("B-header-nomoney-900", width: 900, env: env { $0.windowShowsMoney = false }) }
    @Test func headerSectionBand() throws {
        try header("B-header-section-band-1200", env: env { $0.windowShowsMoney = false }, band: true)
    }
    /// One Claude and one Codex account, no money reader: the whole header is the title line.
    @Test func headerTwoAccounts() throws {
        let (environment, directory) = try ARenders.twoAccountEnv()
        defer { try? FileManager.default.removeItem(at: directory) }
        try header("B-header-two-accounts-1200", env: environment)
        try header("B-header-two-accounts-900", width: 900, env: environment)
    }
    @Test func headerRunway18h() throws { try header("B-header-runway-18h", env: env(usage: .runway18h)) }
    @Test func headerRunway60h() throws { try header("B-header-runway-60h", env: env(usage: .runway60h)) }
    @Test func headerHetznerNoKey() throws { try header("B-header-hetzner-nokey", env: env(usage: .hetznerNoKey)) }
    @Test func headerStripHoverCaption() throws {
        try header("B-header-strip-hover-mark", env: env { $0.windowHeader = .strip }, hover: .provider(.codex))
    }

    /// The account list over the window, placed like the prototype: 12 left of and 10 below the clicked battery.
    private func popover(_ name: String, provider: Provider, alias: String) throws {
        let environment = Self.section()
        let row = try #require(environment.usage.row(provider))
        let index = try #require(row.batteries.firstIndex { $0.alias == alias })
        let rowIndex = provider == .claude ? 0 : 1
        // Band top 40 (the title line); battery x = 22 + 20 + 12 + 51·i; row top 35·r, battery bottom 6.5 + 18 into it.
        let batteryX = 22 + 20 + 12 + 51 * CGFloat(index)
        let batteryBottom = WindowChromeMetrics.standard.lineHeight + 35 * CGFloat(rowIndex) + 6.5 + 18
        let view = ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                WindowHeaderView(allowsTitleLine: false).overlay(alignment: .bottom) { WindowTheme.hairline.frame(height: 1) }
                Spacer(minLength: 0)
            }
            AccountListView(provider: provider, selected: row.batteries[index].id)
                .shadow(color: .black.opacity(0.6), radius: 25, y: 20)
                .offset(x: batteryX - 12, y: batteryBottom + 10)
        }
        .frame(width: 1200, height: 760, alignment: .topLeading)
        .background(WindowTheme.bg, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WindowTheme.edge, lineWidth: 0.5))
        .padding(12)
        // Hosted: the title line's drag area is an AppKit view, which `ImageRenderer` draws as a placeholder over it.
        try RenderHarness.renderHosted(view.background(Color(hex: 0x1A2420)), name, size: CGSize(width: 1224, height: 784), env: environment)
    }

    @Test func accountPopoverClaude() throws { try popover("B-account-popover-claude", provider: .claude, alias: "Main") }
    @Test func accountPopoverCodex() throws { try popover("B-account-popover-codex", provider: .codex, alias: "Team") }

    @Test func hoverChip() throws {
        let environment = AppEnvironment.demo()
        let label = try #require(HoverLabelText.full(.money("RunPod"), usage: environment.usage))
        try RenderHarness.render(HoverChipView(label: label).padding(20), "B-hover-chip", env: environment, background: .black)
    }
}

/// The island's Clean usage block (80 pt), cropped from `D-island-clean-list` for its ref.
@MainActor
@Suite(.serialized)
struct BCleanRenders {
    private func block(_ name: String, width: CGFloat = 636, usage: DemoUsageModel.Variant = .standard) throws {
        try RenderHarness.render(CleanUsageBlock(width: width), name, size: CGSize(width: width, height: 80),
                                 env: .demo(usage: usage), background: .black)
    }

    @Test func cleanUsage() throws { try block("B-island-clean-usage") }
    @Test func cleanUsageRunway18h() throws { try block("B-island-clean-usage-18h", usage: .runway18h) }
    @Test func cleanUsageNoKey() throws { try block("B-island-clean-usage-nokey", usage: .hetznerNoKey) }
    /// A narrow island: amounts leave whole (Hetzner, then OpenAI), never clipped.
    @Test func cleanUsageNarrow() throws { try block("B-island-clean-usage-narrow", width: 540) }
}
