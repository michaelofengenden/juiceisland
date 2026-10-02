import AppKit
import Foundation
@testable import IslandEngine
import OpenIslandCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// The providers lane (P480 to P485): Setup's OpenCode row in each of its states, and OpenCode's questions on the
/// island, answerable under OpenCode 1 and read-only under OpenCode 2. Fixture rows and demo engines; nothing is read,
/// written or shown on screen.
@MainActor
@Suite(.serialized)
struct ProvidersRenders {
    static let v2Question = "opencode2-ses_demo_release"

    static func row(_ file: OpenCodePluginFile, _ version: OpenCodeVersion?, openIsland: Bool = false,
                    refusal: String? = nil) -> OpenCodeSetupRow {
        OpenCodeSetupRow.make(file: file, version: version, openIslandRunning: openIsland, clickRefusal: refusal, busy: false,
                              folder: "~/.config/opencode")
    }

    static let two = OpenCodeVersion(major: 2, minor: 0, patch: 18)
    static let one = OpenCodeVersion(major: 1, minor: 18, patch: 33)

    private func renderSettings(_ name: String, env: AppEnvironment) throws {
        let view = SettingsRootView(navigation: SettingsNavigation(pane: .setup), drawsTrafficLights: true, scrolls: false)
        let height = max(SettingsTheme.Metrics.minHeight, ARenders.fittingHeight(view, env: env))
        try RenderHarness.renderHosted(view, name, size: CGSize(width: SettingsTheme.Metrics.width, height: height), env: env)
    }

    /// Setup as the owner finds it under OpenCode 2 with Open Island's plugin still in place: "For OpenCode 1 · Update".
    @Test func setupWithOpenIslandsPluginUnderOpenCode2() throws {
        let env = AppEnvironment.demo()
        env.hooks = DemoHooksModel(openCodeRow: Self.row(.openIsland, Self.two))
        try renderSettings("PR-setup-opencode", env: env)
    }

    /// Every state of the row, one under the other, as Setup draws it.
    @Test func openCodeRowStates() throws {
        let env = AppEnvironment.demo()
        let rows: [OpenCodeSetupRow] = [
            Self.row(.missing, Self.two),
            Self.row(.ours(revision: OpenCodePlugin.revision), Self.two),
            Self.row(.openIsland, Self.two),
            Self.row(.openIsland, Self.one),
            Self.row(.ours(revision: OpenCodePlugin.revision - 1), nil),
            Self.row(.foreign, Self.two),
            Self.row(.linked, Self.one),
            Self.row(.missing, Self.two, openIsland: true),
            Self.row(.missing, Self.two, refusal: OpenCodePluginError.writeFailed("").refusal),
        ]
        let view = FormPane {
            FormSection("OpenCode") {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in OpenCodeSetupRowView(row: row) }
            }
        }
        .padding(SettingsTheme.Metrics.panePadding)
        .frame(width: SettingsTheme.Metrics.width - 200)
        .background(SettingsTheme.window)
        let probe = NSHostingView(rootView: view.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(view, "PR-opencode-row-states", size: probe.fittingSize, env: env)
    }

    /// OpenCode 2's question beside OpenCode 1's: the same question, read-only (Open) for OpenCode 2, answerable for 1.
    @Test(arguments: [CardStyle.islandClean, .window])
    func openCodeQuestions(_ style: CardStyle) throws {
        let env = AppEnvironment.demo(sessions: .agentQuestion)
        let feed = try #require(env.fixtureFeed)
        let now = feed.now
        let folder = FixtureSessionFeed.folder("notes-site")
        let start = OpenCodeHookPayload(hookEventName: .sessionStart, sessionID: Self.v2Question, cwd: folder)
        var asked = OpenCodeHookPayload(hookEventName: .questionAsked, sessionID: Self.v2Question, cwd: folder)
        asked.questions = [OpenCodeQuestionPayload(question: "Which branch should the release go out from?", header: "Branch", options: [
            OpenCodeQuestionOptionPayload(label: "main", description: "What is merged today."),
            OpenCodeQuestionOptionPayload(label: "release/0.4", description: "Cut last week, fixes only."),
        ])]
        _ = feed.engine.loadPreviewEvents([
            .sessionStarted(SessionStarted(sessionID: Self.v2Question, title: start.sessionTitle, tool: .openCode, origin: .live,
                                           initialPhase: .running, summary: start.implicitStartSummary, timestamp: now - 300,
                                           jumpTarget: start.defaultJumpTarget)),
            .questionAsked(QuestionAsked(sessionID: Self.v2Question, prompt: asked.questionPrompt, timestamp: now - 60)),
        ])
        let v2 = try #require(env.sessions.card(for: Self.v2Question))
        let v1 = try #require(env.sessions.card(for: FixtureSessionFeed.AgentID.openCodeQuestion))
        guard case let .question(v2Model) = v2, case let .question(v1Model) = v1 else {
            Issue.record("not question cards"); return
        }
        #expect(!v2Model.isAnswerable)
        #expect(v1Model.isAnswerable)
        let width: CGFloat = style == .window ? 579 : 460
        let view = VStack(alignment: .leading, spacing: 14) {
            SessionCardView(card: v2, style: style).frame(width: width)
            SessionCardView(card: v1, style: style).frame(width: width)
        }
        .padding(12)
        .background(Color.black)
        .environment(\.sessionGlyphsAnimated, false)
        let probe = NSHostingView(rootView: view.environment(env).environment(\.colorScheme, .dark))
        try RenderHarness.renderHosted(view, "PR-opencode-questions-\(style == .window ? "window" : "island")", size: probe.fittingSize,
                                       env: env)
    }
}
