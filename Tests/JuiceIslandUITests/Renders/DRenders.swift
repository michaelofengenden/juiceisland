import AppKit
import Foundation
import IslandEngine
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream D: the closed pill in each state, the opened island (Clean and Detailed, list and cards), the no-notch top
/// bar. Refs: `refs/D-*.png`. Each render sits in a plain stand-in for the prototype's wallpaper and menu bar, at the
/// reference shot's size, so `renders/compare/` lines up; the panel itself is never shown.
@MainActor
@Suite(.serialized)
struct DRenders {
    // MARK: Pill tiles (518 × 92)

    @Test func pillIdle() throws {
        try pillTile("D-pill-idle", rows: [])
    }

    @Test func pillRunning() throws {
        try pillTile("D-pill-running", rows: [DStub.row("r1", .claude, .running)])
    }

    @Test func pillWaiting() throws {
        try pillTile("D-pill-waiting", rows: [DStub.row("a", .claude, .needsYou, glyph: .bang), DStub.row("q", .claude, .needsYou, glyph: .ques)])
    }

    @Test func pillDone() throws {
        try pillTile("D-pill-done", rows: [DStub.row("d", .codex, .done)], recentlyFinished: .codex)
    }

    @Test func pillMixed() throws {
        try pillTile("D-pill-mixed", rows: [DStub.row("r1", .claude, .running), DStub.row("r2", .codex, .running),
                                            DStub.row("d1", .codex, .done), DStub.row("d2", .claude, .done)])
    }

    @Test func pillTopBarIdle() throws {
        try pillTile("D-pill-topbar-idle", rows: [], notch: nil)
    }

    @Test func pillBigCount() throws {
        try pillTile("D-pill-count-12", rows: (0..<12).map { DStub.row("r\($0)", $0 % 2 == 0 ? .claude : .codex, .running) }, glance: true)
    }

    @Test func pillDoneAfterTheFlash() throws {
        try pillTile("D-pill-done-dim", rows: [DStub.row("d", .codex, .done)])
    }

    @Test func pillTopBar() throws {
        try pillTile("D-pill-topbar", rows: [DStub.row("r1", .claude, .running)], notch: nil)
    }

    @Test func pillGlance() throws {
        try pillTile("D-pill-glance", rows: [DStub.row("r1", .claude, .running), DStub.row("d", .claude, .done)], glance: true)
    }

    @Test func pillThreeGlyphs() throws {
        try pillTile("D-pill-wide", rows: [DStub.row("q", .claude, .needsYou, glyph: .ques), DStub.row("a", .claude, .needsYou, glyph: .bang),
                                           DStub.row("r", .codex, .running)])
    }

    /// Closed-pill count "Needs you": approvals and questions only (the ref `D-pill-count-needs` is the whole board).
    @Test func pillCountNeeds() throws {
        try pillTile("D-pill-needs-count", rows: [DStub.row("a", .claude, .needsYou), DStub.row("r1", .claude, .running),
                                                  DStub.row("r2", .codex, .running)], countMode: .needsYou)
    }

    /// "Needs you" with nothing waiting: the count is blank.
    @Test func pillCountNeedsNone() throws {
        try pillTile("D-pill-needs-count-none", rows: [DStub.row("r1", .claude, .running)], countMode: .needsYou)
    }

    @Test func pillLive() throws {
        try RenderHarness.render(DScene.pill(ClosedPillView(animated: false)), "D-pill-live")
    }

    // MARK: Opened island, Clean (920 wide)

    /// The default: Header strip placement, the Next battery of each provider beside the notch.
    @Test func cleanList() throws { try island("D-island-clean-list") }

    @Test func cleanSection() throws {
        try island("D-island-clean-section") { $0.islandUsagePlacement = .section }
    }

    @Test func cleanSectionHover() throws {
        try island("D-island-clean-section-hover", ui: IslandUIState(hover: .account(DStub.accountID("Studio")))) {
            $0.islandUsagePlacement = .section
        }
    }

    @Test func cleanQuestion() throws { try island("D-island-clean-question", .card(sessionID: FixtureSessionFeed.ID.question)) }

    @Test func cleanApproval() throws { try island("D-island-clean-approval", .card(sessionID: FixtureSessionFeed.ID.approval)) }

    /// The owner's screenshot (2026-09-25), as the live island now draws it: the command in the box, the reason under.
    @Test func cleanCodexApproval() throws {
        try island("D-island-clean-codex-approval", .card(sessionID: FixtureSessionFeed.ID.codexApproval), scenario: .codexApproval)
    }

    @Test func cleanDone() throws {
        try island("D-island-clean-done", .card(sessionID: FixtureSessionFeed.ID.claudeDone), scenario: .allStates)
    }

    @Test func cleanStrip() throws {
        try island("D-island-clean-strip") { $0.islandUsagePlacement = .headerStrip }
    }

    @Test func cleanStripOpen() throws {
        try island("D-island-clean-strip-open", ui: IslandUIState(stripOpen: true)) { $0.islandUsagePlacement = .headerStrip }
    }

    @Test func cleanHoverMain() throws {
        try island("D-island-clean-hover-main", ui: IslandUIState(hover: .account(DStub.accountID("Main")), stripOpen: true))
    }

    @Test func cleanHoverStudio() throws {
        try island("D-island-clean-hover-studio", ui: IslandUIState(hover: .account(DStub.accountID("Studio")), stripOpen: true))
    }

    @Test func cleanHoverRunPod() throws {
        try island("D-island-clean-hover-runpod", ui: IslandUIState(hover: .money("RunPod"), stripOpen: true))
    }

    @Test func cleanNoUsage() throws {
        try island("D-island-clean-nousage") { $0.islandShowsUsage = false }
    }

    @Test func cleanAgentColours() throws {
        try island("D-island-clean-agent") { $0.glyphColour = .byAgent }
    }

    @Test func cleanEmpty() throws {
        try island("D-island-clean-empty", scenario: .empty)
    }

    @Test func cleanWideNotch() throws {
        try island("D-island-clean-notch-16in", notch: CGSize(width: 204, height: 34),
                   ui: IslandUIState(hover: .account(DStub.accountID("Research")), stripOpen: true))
    }

    // MARK: Opened island, Detailed

    @Test func detailedList() throws { try island("D-island-detailed-list") { $0.islandStyle = .detailed } }

    @Test func detailedSection() throws {
        try island("D-island-detailed-section") {
            $0.islandStyle = .detailed
            $0.islandUsagePlacement = .section
        }
    }

    @Test func detailedQuestion() throws {
        try island("D-island-detailed-question", .card(sessionID: FixtureSessionFeed.ID.question)) { $0.islandStyle = .detailed }
    }

    @Test func detailedApproval() throws {
        try island("D-island-detailed-approval", .card(sessionID: FixtureSessionFeed.ID.approval)) { $0.islandStyle = .detailed }
    }

    @Test func detailedDone() throws {
        try island("D-island-detailed-done", .card(sessionID: FixtureSessionFeed.ID.claudeDone), scenario: .allStates) {
            $0.islandStyle = .detailed
        }
    }

    @Test func detailedHoverResearch() throws {
        try island("D-island-detailed-hover-research", ui: IslandUIState(hover: .account(DStub.accountID("Research")), stripOpen: true)) {
            $0.islandStyle = .detailed
        }
    }

    @Test func detailedNoMoney() throws {
        try island("D-island-detailed-nomoney", ui: IslandUIState(stripOpen: true)) {
            $0.islandStyle = .detailed
            $0.islandShowsMoney = false
        }
    }

    // MARK: Helpers

    private func pillTile(_ name: String, rows: [SessionRow], notch: CGSize? = IslandTheme.Metrics.referenceNotch,
                          glance: Bool = false, recentlyFinished: GlyphPalette.Agent? = nil, countMode: PillCount = .active) throws {
        let settings = AppSettings.ephemeral()
        settings.closedPillCount = countMode
        let env = AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: DStub(rows: rows))
        let pill = ClosedPillView(notch: notch, animated: false, glance: glance, recentlyFinished: recentlyFinished)
        try RenderHarness.render(DScene.pill(pill, notch: notch != nil), name, env: env)
    }

    private func island(_ name: String, _ presentation: IslandPresentation = .list, scenario: FixtureSessionFeed.Scenario = .prototype,
                        notch: CGSize = IslandTheme.Metrics.referenceNotch, ui: IslandUIState = IslandUIState(),
                        settings configure: (AppSettings) -> Void = { _ in }) throws {
        let settings = AppSettings.ephemeral()
        configure(settings)
        let env = AppEnvironment.demo(settings: settings, sessions: scenario)
        let view = OpenedIslandView(presentation: presentation, notch: notch, ui: ui, animated: false)
        let scene = DScene.island(view, notch: notch)
        guard presentation != .list else {
            try RenderHarness.render(scene, name, env: env)
            return
        }
        // Cards hold AppKit text fields, which `ImageRenderer` leaves blank: draw them hosted, at the scene's own size.
        let probe = NSHostingView(rootView: scene.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(scene, name, size: probe.fittingSize, env: env)
    }
}

/// Stand-ins for the prototype's board: its dusk wallpaper (as a gradient), the translucent menu bar and the hardware
/// notch, sized like the reference crops.
@MainActor
enum DScene {
    /// The pill on the prototype's board: the menu bar (the reference display's 33 pt, or 24 without a notch), the pill
    /// placed by its notch, and the hardware notch drawn over it, as the display's cutout is.
    static func pill<V: View>(_ pill: V, notch: Bool = true) -> some View {
        ZStack(alignment: .notchTop) {
            LinearGradient(stops: [.init(color: Color(hex: 0x161E1D), location: 0), .init(color: Color(hex: 0x1D2824), location: 0.4),
                                   .init(color: Color(hex: 0x2A3932), location: 1)], startPoint: .top, endPoint: .bottom)
            Rectangle().fill(Color(red: 10 / 255, green: 14 / 255, blue: 13 / 255).opacity(0.28))
                .frame(height: notch ? IslandTheme.Metrics.referenceMenuBar : IslandTheme.Metrics.topBarFallbackHeight)
            pill
            if notch { hardwareNotch() }
        }
        .frame(width: 518, height: 92)
    }

    static func island<V: View>(_ island: V, notch: CGSize) -> some View {
        VStack(spacing: 0) {
            island
            Color.clear.frame(height: 56)
        }
        .frame(width: 920)
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                wallpaper
                Rectangle().fill(Color(red: 10 / 255, green: 14 / 255, blue: 13 / 255).opacity(0.28)).frame(height: 32)
                hardwareNotch(notch)
            }
        }
    }

    static func hardwareNotch(_ size: CGSize = IslandTheme.Metrics.referenceNotch) -> some View {
        UnevenRoundedRectangle(bottomLeadingRadius: IslandTheme.Metrics.referenceNotchRadius,
                               bottomTrailingRadius: IslandTheme.Metrics.referenceNotchRadius)
            .fill(.black).frame(width: size.width, height: size.height)
    }

    /// The wallpaper at the reference's scale (920 × 597, horizon at 358), then the dark sea.
    private static var wallpaper: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                .init(color: Color(hex: 0x121A19), location: 0), .init(color: Color(hex: 0x27332F), location: 0.36),
                .init(color: Color(hex: 0x414537), location: 0.54), .init(color: Color(hex: 0x6F6147), location: 0.72),
                .init(color: Color(hex: 0xC08D58), location: 0.9), .init(color: Color(hex: 0xE7BE88), location: 1),
            ], startPoint: .top, endPoint: .bottom).frame(height: 358)
            LinearGradient(colors: [Color(hex: 0x283734), Color(hex: 0x0F1B1B), Color(hex: 0x091314)], startPoint: .top, endPoint: .bottom)
                .frame(height: 400)
        }
        .frame(width: 920, height: 1400, alignment: .top)
    }
}

/// A sessions model with fixed rows, for pill states the fixture feed has no scenario for.
@MainActor
@Observable
final class DStub: SessionsModel {
    var rows: [SessionRow]
    var now: Date { DemoClock.now }

    init(rows: [SessionRow]) { self.rows = rows }

    func card(for sessionID: String) -> SessionCard? { nil }
    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) {}
    func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool { false }
    func reply(_ sessionID: String, text: String) {}
    func jump(_ sessionID: String) {}
    func jumpToNextNeedsYou() {}
    func dismiss(_ sessionID: String) {}

    static func row(_ id: String, _ agent: GlyphPalette.Agent, _ bucket: SessionBucket, glyph: PixelGlyph? = nil,
                    status: StatusWord? = nil, project: String = "juice-island", task: String = "Task",
                    minutesAgo: Double = 3) -> SessionRow {
        let (defaultGlyph, state): (PixelGlyph, GlyphPalette.State) = switch bucket {
        case .needsYou: (.bang, .waiting)
        case .running: (.eq, .running)
        case .done: (.check, .done)
        }
        let word: StatusWord = status ?? (bucket == .needsYou ? (glyph == .ques ? .question : .needsApproval(tool: "Bash"))
            : bucket == .running ? .tool(name: "Edit", detail: "App/Island/ClosedPillView.swift") : .done)
        return SessionRow(id: id, agent: agent, bucket: bucket, project: project, task: task, status: word, detail: "git push",
                          lastPrompt: "build it", host: "Terminal", accountAlias: nil,
                          updatedAt: DemoClock.now.addingTimeInterval(-minutesAgo * 60), isCodexApp: false,
                          glyph: glyph ?? defaultGlyph, glyphState: state, hasCard: bucket == .needsYou)
    }

    /// The demo account id for an alias ("Main", "Studio", …).
    static func accountID(_ alias: String) -> String {
        DemoUsageModel(now: DemoClock.now).accounts.first { $0.alias == alias }?.id ?? alias
    }
}
