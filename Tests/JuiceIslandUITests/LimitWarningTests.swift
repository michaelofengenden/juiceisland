import Foundation
import IslandHookNotes
import JuiceCore
import SwiftUI
import Testing
@testable import IslandEngine
@testable import JuiceIslandUI
import OpenIslandCore

/// Sessions that stopped on a limit or an API error (P700 to P704), fed through the engine's live paths on a headless
/// preview engine, with the demo's batteries: a Claude session in the Research folder (its battery used up) that hit its
/// session limit, a Codex chat in the Team folder whose turn ended on its usage limit, and a Claude session the API
/// overloaded. Every profile folder is the demo's, under the home folder; nothing is read or opened.
@MainActor
enum LimitFixtures {
    static let claude = "demo-limit-claude"
    static let codex = "demo-limit-codex"
    static let overloaded = "demo-limit-overloaded"

    static func folder(_ name: String) -> String { NSHomeDirectory() + "/" + name }

    /// The Claude session's reset, as Claude Code writes it, an hour after the demo's clock (in the Mac's own zone, as the
    /// CLI writes it in its own).
    static func claudeReset(now: Date) -> Date { now + 3_600 }

    static func claudeMessage(now: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mma"
        let time = formatter.string(from: claudeReset(now: now)).lowercased().replacingOccurrences(of: ":00", with: "")
        return "You've hit your session limit · resets \(time) (\(TimeZone.current.identifier))"
    }

    /// The Codex turn's reset, as its message says it ("Try again at 3:45 PM."), 50 minutes after the demo's clock.
    static func codexReset(now: Date) -> Date {
        let minute = 60.0
        return Date(timeIntervalSinceReferenceDate: ((now + 50 * minute).timeIntervalSinceReferenceDate / minute).rounded(.down) * minute)
    }

    static func codexError(now: Date) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        let time = formatter.string(from: codexReset(now: now))
        return ["message": "You've hit your usage limit. Upgrade to Pro (https://example.com/pro), or try again at \(time).",
                "codex_error_info": "usage_limit_exceeded"]
    }

    static func line(_ type: String, _ payload: [String: Any], at date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
        return #"{"timestamp":"\#(formatter.string(from: date))","type":"\#(type)","payload":\#(String(decoding: data, as: UTF8.self))}"#
    }

    /// The engine, its profiles the demo's accounts (under the home folder), and the three sessions. `launched` hears
    /// "Open in" (never a window).
    static func engine(now: Date = DemoClock.now, launched: EngineFixtureBox<[FreshSessionLaunch]>? = nil,
                       clock: EngineFixtureBox<Date>? = nil) -> SessionEngine {
        let engine = SessionEngine.preview(clock: { clock?.current ?? now }, fresh: { launch in
            launched?.update { $0.append(launch) }
            return true
        })
        let accounts = DemoUsageData.accounts.map { account in
            Account(provider: account.provider, folder: (account.folder as NSString).expandingTildeInPath, alias: account.alias,
                    monitored: account.monitored, knownEmail: account.knownEmail)
        }
        // Claude: its transcript in the Research folder names its account (the failure's metadata carries it); the hook's
        // message, then the failure.
        engine.loadPreviewEvents(FixtureSessionFeed.start(Self.claude, title: "Port the parser to Swift", project: "notes-site",
                                                          prompt: "port the parser", at: now - 600, terminal: "Ghostty")
                                 + FixtureSessionFeed.start(Self.overloaded, title: "Tidy the release script", project: "juice-tools",
                                                            prompt: "tidy the release script", at: now - 900))
        failure(engine, Self.claude, error: "rate_limit", message: claudeMessage(now: now), at: now - 120,
                transcript: folder(".claude-research/projects/notes-site/limit.jsonl"))
        failure(engine, Self.overloaded, error: "overloaded", message: "API Error: 529 Overloaded", at: now - 300,
                transcript: folder(".claude-lab/projects/juice-tools/overloaded.jsonl"))
        // Codex: a chat in the Team folder whose turn ended on its usage limit.
        let rollout = folder(".codex-team/sessions/2026/09/24/rollout-limit.jsonl")
        engine.loadPreviewEvents(FixtureSessionFeed.start(codex, title: "Resize the store images", project: "store-assets",
                                                          prompt: "resize the store images", tool: .codex, at: now - 400,
                                                          transcript: rollout))
        engine.loadPreviewRollout(sessionID: codex, transcriptPath: rollout, lines: [
            line("session_meta", ["id": codex, "cwd": folder("Developer/store-assets"), "originator": "codex_cli_rs", "source": "cli"],
                 at: now - 400),
            line("event_msg", ["type": "user_message", "message": "resize the store images", "images": []], at: now - 399),
            line("event_msg", ["type": "task_started", "turn_id": "t1"], at: now - 398),
            line("event_msg", ["type": "task_complete", "turn_id": "t1", "last_agent_message": NSNull(), "error": codexError(now: now)],
                 at: now - 30),
        ])
        // The profiles once every session is in: each is tagged with its account from its transcript's folder.
        engine.setProfiles(accounts: accounts, discovered: [])
        return engine
    }

    /// A Claude StopFailure as the bridge sends it: the hook's message as the last message, the note, the completion.
    static func failure(_ engine: SessionEngine, _ id: String, error: String, message: String, at date: Date, transcript: String) {
        let prompt = engine.state.session(id: id)?.claudeMetadata?.lastUserPrompt
        engine.loadPreviewEvents([.claudeSessionMetadataUpdated(ClaudeSessionMetadataUpdated(
            sessionID: id, claudeMetadata: ClaudeSessionMetadata(transcriptPath: transcript, lastUserPrompt: prompt, lastAssistantMessage: message),
            timestamp: date))])
        engine.loadPreviewNote(event: "StopFailure", sessionID: id)
        engine.loadPreviewEvents([.sessionCompleted(SessionCompleted(sessionID: id, summary: error, timestamp: date))])
    }

    static func model(now: Date = DemoClock.now, live: Bool = false, launched: EngineFixtureBox<[FreshSessionLaunch]>? = nil)
        -> EngineSessionsModel {
        EngineSessionsModel(engine: engine(now: now, launched: launched), clock: { now }, jumps: live ? .live : .demo)
    }

    static func env(now: Date = DemoClock.now, settings: AppSettings = .ephemeral()) -> AppEnvironment {
        AppEnvironment(settings: settings, usage: DemoUsageModel(now: DemoClock.now), sessions: model(now: now))
    }
}

@MainActor
struct LimitWarningTests {
    typealias L = LimitFixtures

    @Test
    func aClaudeSessionAtItsLimitSaysWhenItResets() throws {
        let model = L.model()
        let row = try #require(model.row(id: L.claude))
        let resets = RowLimit.resetText(L.claudeReset(now: DemoClock.now), now: DemoClock.now, zone: .current)
        #expect(resets.hasPrefix("resets "))
        // Still a failed turn: needs you, "×" in the waiting tone (today's rules, no more).
        #expect(row.bucket == .needsYou && row.glyph == .cross && row.glyphState == .waiting)
        #expect(row.limit?.line == "Limit reached · " + resets)
        #expect(row.detail == nil)
        #expect(SessionRowText.cleanStatus(row) == .init(word: "Limit reached", tone: .approval, toolVerb: nil, text: resets))
        #expect(SessionRowText.detailedStatus(row) == .init(word: "Limit reached", tone: .approval, isPrompt: false, text: resets))
        #expect(DetailedRowText.status(row).word == "Limit reached" && DetailedRowText.status(row).text == resets)
        #expect(SessionListLayout.groupStatus(row, now: DemoClock.now) == "Limit reached · " + resets)
        let card = try #require(model.card(for: L.claude))
        #expect(CardText.status(card) == .init(word: "Limit reached", tone: .approval, isPrompt: false, text: resets))
        guard case let .done(done) = card else { Issue.record("not a done card"); return }
        #expect(done.failed && done.message.isEmpty && DoneCardView.message(done) == nil)
    }

    @Test
    func anAPIErrorSaysItsKind() throws {
        let model = L.model()
        let row = try #require(model.row(id: L.overloaded))
        #expect(row.bucket == .needsYou && row.limit?.line == "API error · overloaded")
        #expect(SessionRowText.cleanStatus(row).word == "API error" && SessionRowText.cleanStatus(row).text == "overloaded")
        let card = try #require(model.card(for: L.overloaded))
        #expect(CardText.status(card).text == "overloaded")
        // No other account helps with the provider's own trouble: the card is its header alone.
        #expect(card.limitAlternative(DemoUsageModel(now: DemoClock.now).logins) == nil)
        #expect(card.isHeaderOnly(replySetting: false))
    }

    /// Codex: never a failed turn (no sound or island open beyond today's), a done row that says it, and a card that is
    /// never brief.
    @Test
    func aCodexChatAtItsLimitIsADoneRowThatSaysSo() throws {
        let model = L.model()
        let row = try #require(model.row(id: L.codex))
        #expect(row.bucket == .done && row.status == .done)
        let resets = RowLimit.resetText(L.codexReset(now: DemoClock.now), now: DemoClock.now, zone: .current)
        #expect(row.limit?.line == "Limit reached · " + resets)
        #expect(SessionRowText.doneCardStatus(row, now: DemoClock.now).text == resets)
        guard case let .done(done)? = model.card(for: L.codex) else { Issue.record("no card"); return }
        #expect(!done.failed && !DoneCardView.isBrief(done, style: .islandClean))
    }

    // MARK: P704 The best other account

    @Test
    func theCardOffersTheOtherAccountWithTheMostLeft() throws {
        let model = L.model()
        let logins = DemoUsageModel(now: DemoClock.now).logins
        // Claude: Research is used up; Work has 100 % left, Main 82, Lab 37.
        let claude = try #require(model.card(for: L.claude)?.limitAlternative(logins))
        #expect(claude.line == "work has 100% left" && claude.action == "Open in work")
        #expect(LimitAlternative.same(claude.folder, "~/.claude-work") && claude.provider == .claude)
        // Codex: Team is its own; Home has 71 % left, Night 55, Spare's reading is stale, Edge signed out.
        let codex = try #require(model.card(for: L.codex)?.limitAlternative(logins))
        #expect(codex.line == "home has 71% left" && codex.action == "Open in home" && codex.provider == .codex)
        #expect(try #require(model.card(for: L.claude)).isHeaderOnly(replySetting: false, alternative: true) == false)
    }

    static func login(_ id: String, _ state: AccountState, folder: String, monitored: Bool = true, provider: Provider = .claude) -> LoginRow {
        LoginRow(id: id, provider: provider, email: id + "@example.com", plan: nil,
                 battery: BatteryModel(id: id, alias: id, state: state, isNext: false, hoverLabel: ""), monitored: monitored,
                 folders: [Account(provider: provider, folder: folder, alias: id)])
    }

    @Test
    func neverItsOwnLoginANoPlanOneOrOneWithNothingToTell() {
        let limit = RowLimit(SessionLimit(kind: .usageLimit, resetsAt: DemoClock.now + 60), provider: .claude,
                             folder: "/demo/.claude-own", now: DemoClock.now)
        func best(_ rows: [LoginRow]) -> String? {
            LimitAlternative.best(for: limit, logins: [ProviderLogins(provider: .claude, logins: rows, folders: [])])?.name
        }
        let own = Self.login("own", .available(percentLeft: 90, isLow: false), folder: "/demo/.claude-own")
        // The session's own login, even with the most left, is never offered; nor a No plan or No limits one, one not
        // monitored, one used up, stale, signed out or not read.
        #expect(best([own, Self.login("two", .available(percentLeft: 40, isLow: false), folder: "/demo/.claude-two")]) == "two")
        #expect(best([own, Self.login("plan", .noPlan, folder: "/demo/.claude-plan"), Self.login("org", .noLimits, folder: "/demo/.claude-org"),
                      Self.login("off", .available(percentLeft: 99, isLow: false), folder: "/demo/.claude-off", monitored: false),
                      Self.login("out", .usedUp(refill: nil), folder: "/demo/.claude-out"),
                      Self.login("old", .stale(lastPercentLeft: 80), folder: "/demo/.claude-old"),
                      Self.login("gone", .signInNeeded, folder: "/demo/.claude-gone"),
                      Self.login("new", .unknown, folder: "/demo/.claude-new")]) == nil)
        // The most left wins; a tie goes to the first in the list.
        #expect(best([own, Self.login("a", .available(percentLeft: 30, isLow: false), folder: "/demo/.claude-a"),
                      Self.login("b", .available(percentLeft: 64, isLow: false), folder: "/demo/.claude-b"),
                      Self.login("c", .available(percentLeft: 64, isLow: false), folder: "/demo/.claude-c")]) == "b")
        // Only the provider's own logins.
        #expect(LimitAlternative.best(for: limit, logins: [
            ProviderLogins(provider: .claude, logins: [own], folders: []),
            ProviderLogins(provider: .codex, logins: [Self.login("x", .available(percentLeft: 99, isLow: false), folder: "/demo/.codex-x",
                                                                 provider: .codex)], folders: [])]) == nil)
        // The session's login not known: nothing, as the one offered could be its own.
        #expect(best([Self.login("two", .available(percentLeft: 40, isLow: false), folder: "/demo/.claude-two")]) == nil)
        // Not the account's limit, or a limit that reset: no other account.
        for other in [RowLimit(SessionLimit(kind: .rateLimited), provider: .claude, folder: "/demo/.claude-own", now: DemoClock.now),
                      RowLimit(SessionLimit(kind: .usageLimit, resetsAt: DemoClock.now - 60), provider: .claude, folder: "/demo/.claude-own",
                               now: DemoClock.now),
                      RowLimit(SessionLimit(kind: .usageLimit), now: DemoClock.now)] {
            #expect(LimitAlternative.best(for: other, logins: [ProviderLogins(provider: .claude, logins: [
                own, Self.login("two", .available(percentLeft: 40, isLow: false), folder: "/demo/.claude-two")], folders: [])]) == nil)
        }
    }

    // MARK: P703 Open in

    @Test
    func openInRunsTheAccountsCLIInTheSessionsFolderAndTerminal() async throws {
        let launched = EngineFixtureBox<[FreshSessionLaunch]>([])
        let model = L.model(live: true, launched: launched)
        let alternative = try #require(model.card(for: L.claude)?.limitAlternative(DemoUsageModel(now: DemoClock.now).logins))
        model.openFresh(L.claude, in: alternative)
        for _ in 0..<200 where launched.current.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        let launch = try #require(launched.current.first)
        // Ghostty, the session's terminal; its folder; the Work folder's variable; a fresh `claude`, never a resume.
        #expect(launch.host == .ghostty && launch.folder == L.folder("Developer/notes-site"))
        #expect(launch.line == "cd '\(L.folder("Developer/notes-site"))' && CLAUDE_CONFIG_DIR='\(L.folder(".claude-work"))' claude")
        #expect(!launch.line.contains("resume") && !launch.line.contains("--continue"))
        // The owner went on elsewhere: the failed turn no longer needs them, and the row still says why it stopped.
        for _ in 0..<200 where model.row(id: L.claude)?.bucket == .needsYou { try await Task.sleep(for: .milliseconds(5)) }
        let row = try #require(model.row(id: L.claude))
        #expect(row.bucket == .done && row.limit?.word == "Limit reached")
        #expect(launched.current.count == 1)
    }

    @Test
    func theDemoOpensNothing() throws {
        let launched = EngineFixtureBox<[FreshSessionLaunch]>([])
        let model = L.model(launched: launched)
        let alternative = try #require(model.card(for: L.codex)?.limitAlternative(DemoUsageModel(now: DemoClock.now).logins))
        model.openFresh(L.codex, in: alternative)
        #expect(model.jumpNote?.text == JumpNote.demo)
        #expect(launched.current.isEmpty)
    }

    // MARK: P707 The row's menu

    /// The row's right-click menu offers the card's other account while the limit holds (P707): a Codex limit's Done
    /// card folds away after a few seconds or never opens (a focused terminal, Glance, a mute rule, Quiet hours), and a
    /// Claude card dismissed in the window is gone, while the row stays.
    @Test
    func theRowsMenuOffersOpenInWhileTheLimitHolds() throws {
        let model = L.model()
        let logins = DemoUsageModel(now: DemoClock.now).logins
        let codex = try #require(model.row(id: L.codex))
        let alternative = try #require(SessionMenuModel.alternative(codex, logins: logins))
        #expect(alternative == model.card(for: L.codex)?.limitAlternative(logins))
        #expect(SessionMenuItem.openIn(alternative).title == "Open in home")
        #expect(SessionMenuModel.groups(codex, card: nil, alternative: alternative).first == [.jump, .openIn(alternative)])
        // It runs the card's own open, for the row's session.
        let spy = MenuSpy(model)
        SessionMenuPerformer(sessions: spy, jump: { _ in }).perform(.openIn(alternative), row: codex, card: nil)
        #expect(spy.opened.count == 1 && spy.opened.first?.sessionID == L.codex && spy.opened.first?.alternative == alternative)
        // The API's trouble: no other account, no item.
        let overloaded = try #require(model.row(id: L.overloaded))
        #expect(SessionMenuModel.alternative(overloaded, logins: logins) == nil)
        #expect(SessionMenuModel.groups(overloaded, card: nil, alternative: nil).first == [.jump])
    }

    // MARK: P702 The reset

    @Test
    func onceTheResetPassesTheWarningGoesQuiet() throws {
        let clock = EngineFixtureBox(DemoClock.now)
        let model = EngineSessionsModel(engine: L.engine(clock: clock), clock: { clock.current })
        #expect(model.row(id: L.claude)?.bucket == .needsYou)
        clock.update { $0 = L.claudeReset(now: DemoClock.now) + 1 }
        // The minute clock maps again: nothing needs the owner, the idle check, a quiet "Limit reset".
        model.tick()
        let row = try #require(model.row(id: L.claude))
        #expect(row.bucket == .done && row.glyph == .check && row.glyphState == .idle)
        #expect(row.limit?.passed == true && row.limit?.line == "Limit reset")
        #expect(SessionRowText.cleanStatus(row).tone == .plain)
        #expect(SessionRowText.detailedStatus(row).tone == .muted)
        #expect(model.card(for: L.claude)?.limitAlternative(DemoUsageModel(now: DemoClock.now).logins) == nil)
        #expect(SessionMenuModel.alternative(row, logins: DemoUsageModel(now: DemoClock.now).logins) == nil)
    }
}
