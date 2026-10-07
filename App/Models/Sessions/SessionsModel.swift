import Foundation
import IslandEngine
import JuiceCore
import Observation
import OpenIslandCore

/// What every session surface (window list and cards, island rows and cards, closed pill, toolbar pill copy) binds
/// to. Rows come from the engine's one surfaced list in its own order (P14); cards are built from engine state only
/// (P42), so a question answered elsewhere drops its card.
@MainActor
protocol SessionsModel: AnyObject, Observable {
    /// Every row in display order (needs you first, then running, then done), as the engine ranks them.
    var rows: [SessionRow] { get }
    /// The clock ages count against.
    var now: Date { get }
    /// The card a row opens, from engine state; nil once the question or approval is gone.
    func card(for sessionID: String) -> SessionCard?
    /// The sessions whose card waits on you (an approval, a plan, a question), in the order they began to wait: after
    /// one is answered, the island shows the next (P130).
    var waiting: [SessionRow] { get }
    /// When the session's card that waits began to wait, on the awake clock (`ProcessInfo.systemUptime`): Allow all eats
    /// a press while a card it would answer has just come in (P1032). nil when unknown, or for a card that already
    /// waited when the model first looked.
    func waitingSince(_ sessionID: String) -> TimeInterval?
    /// Sends first: the card goes once the decision went, and stays with "Not sent · Retry" when it could not (P129).
    /// `request`: the engine request the card showed (`CardRequest.id`); a click whose request is no longer the one
    /// waiting answers nothing, so it never lands on the request that took its place (P170). nil: the session's.
    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?)
    /// A step on a question card: pick an option (on a multi-select question, pick or unpick it), type an answer, go
    /// on to the next question, or back. True once every question has its answer and they are on their way to the
    /// agent; the card stays until they went (P129). `request` as for `approve`.
    @discardableResult func answerQuestion(_ sessionID: String, _ input: QuestionInput, request: String?) -> Bool
    /// A reply on a Done card, typed into the session's own terminal where that is known exactly (P128).
    func reply(_ sessionID: String, text: String)
    /// Sends again what a card could not send ("Not sent · Retry").
    func retry(_ sessionID: String)
    /// Row click. Live runs the engine's jump off the main thread and notes an outcome that missed the exact tab;
    /// the demo never jumps and notes "Demo session".
    func jump(_ sessionID: String)
    /// ⌃G while the window or island has focus: the first row that needs you, through `jump`.
    func jumpToNextNeedsYou()
    func dismiss(_ sessionID: String)
    /// Open on a read-only card: the jump to where the agent asks (a Codex request with no output of its own to wait
    /// for closes then, C7). `request`: the engine request the card showed; once it is gone, a plain jump that closes
    /// nothing, never the request that took its place (P174). nil: the session's.
    func openRequest(_ sessionID: String, request: String?)
    /// ✕ on a read-only card: that notice goes; the agent keeps its own prompt. `request` as for `openRequest`: once the
    /// request the card showed is gone, nothing goes.
    func dismissRequest(_ sessionID: String, request: String?)
    /// The engine request whose card the island shows now, as the owner sees it (nil: none): a subagent's request held
    /// for the island is held only while its card shows (P350). Only the island reports it.
    func islandShows(requestID: String?)
    /// The engine requests whose cards the window shows the owner now (Window mode, P1050): a Codex request held for
    /// its card is held while the island or the window shows it. Only the window reports it.
    func windowShows(requestIDs: Set<String>)
    /// The last click's note, until it clears itself; nil after an exact jump.
    var jumpNote: JumpNote? { get }
    /// Where the island hears of a finish (`IslandAttention.signals`): the rows, or the live engine's Done signals.
    var finishSource: FinishSource { get }
    /// A row's peek in the island (P311), for its style (`clean`): nil when it would say nothing the row does not.
    func peek(_ sessionID: String, clean: Bool) async -> SessionPeek?
    /// What the session is at now, for its peek (P720, P721): Codex's reasoning summary, the agent's checklist; nil when
    /// nothing. Observable: a peek that shows follows it.
    func work(_ sessionID: String) -> SessionWork?
    /// "Open in <account>" on a card whose session stopped on its usage limit, or its row's menu (P703, P707): a new
    /// terminal window in the session's folder running the agent's CLI under that account, a fresh session. Only on the
    /// owner's click; the demo notes "Demo session".
    func openFresh(_ sessionID: String, in alternative: LimitAlternative)
    /// The sessions sent to the island, newest first, as their conversation cards (P1300 to P1324).
    var folded: [FoldedCardModel] { get }
    /// Send to island (a row's menu or hover button, the island's S, the system-wide key), on the owner's click or key
    /// only: the card goes on the island and the window into the Dock when it holds the tab alone. The answer: the
    /// window's bounds, for the fold's motion, whether it went or stayed (P1360); nil when its terminal said nothing or
    /// nothing folded.
    func sendToIsland(_ sessionID: String) async -> TuckBounds?
    /// The session whose tab is in front, for the system-wide key's Send front tab to island; nil for none.
    func frontmostFoldable() async -> String?
    /// A reply on a folded session's card: typed into its tab, or held for its turn's end, or through the agent's own
    /// resume when the tab is gone (P1303, P1306).
    func replyFolded(_ sessionID: String, text: String)
    /// Cancel on a held reply.
    func cancelHeld(_ sessionID: String)
    /// Retry on a folded card's "Not sent".
    func retryFolded(_ sessionID: String)
    /// Stop on a resumed run.
    func stopFolded(_ sessionID: String)
    /// Continue on a card whose session stopped mid-turn (P1419): on the owner's click only, the agent's own resume with
    /// the words the card shows.
    func continueFolded(_ sessionID: String)
    /// Open in terminal: the window back and its tab in front (or the conversation reopened, its tab gone); the card goes.
    func openFolded(_ sessionID: String)
    /// ✕ on a folded card: the card goes, the window stays where it is.
    func unfold(_ sessionID: String)
    /// Open in Claude, Open in Codex, Open in <App> (wave 8, P1510): on the owner's click on a card or a row's menu, the
    /// session goes on in its agent's own app, once nothing else holds it (`SessionHandoff`).
    func openInApp(_ sessionID: String)
    /// Cancel on "Opens in Claude when this turn ends".
    func cancelPendingApp(_ sessionID: String)
}

extension SessionsModel {
    func approve(_ sessionID: String, _ decision: ApprovalDecision) { approve(sessionID, decision, request: nil) }
    @discardableResult func answerQuestion(_ sessionID: String, _ input: QuestionInput) -> Bool {
        answerQuestion(sessionID, input, request: nil)
    }
    var jumpNote: JumpNote? { nil }
    var finishSource: FinishSource { .rows }
    var waiting: [SessionRow] { rows.filter(\.hasCard) }
    func waitingSince(_ sessionID: String) -> TimeInterval? { nil }
    func retry(_ sessionID: String) {}
    func openRequest(_ sessionID: String, request: String?) { jump(sessionID) }
    func dismissRequest(_ sessionID: String, request: String?) {}
    func islandShows(requestID: String?) {}
    func windowShows(requestIDs: Set<String>) {}
    func openFresh(_ sessionID: String, in alternative: LimitAlternative) {}
    var folded: [FoldedCardModel] { [] }
    func sendToIsland(_ sessionID: String) async -> TuckBounds? { nil }
    func frontmostFoldable() async -> String? { nil }
    func replyFolded(_ sessionID: String, text: String) {}
    func cancelHeld(_ sessionID: String) {}
    func retryFolded(_ sessionID: String) {}
    func stopFolded(_ sessionID: String) {}
    func continueFolded(_ sessionID: String) {}
    func openFolded(_ sessionID: String) {}
    func unfold(_ sessionID: String) {}
    func openInApp(_ sessionID: String) {}
    func cancelPendingApp(_ sessionID: String) {}
    func foldedCard(_ sessionID: String) -> FoldedCardModel? { folded.first { $0.sessionID == sessionID } }
    func openRequest(_ sessionID: String) { openRequest(sessionID, request: nil) }
    func dismissRequest(_ sessionID: String) { dismissRequest(sessionID, request: nil) }
    var needsYou: [SessionRow] { rows.filter { $0.bucket == .needsYou } }
    var running: [SessionRow] { rows.filter { $0.bucket == .running } }
    var done: [SessionRow] { rows.filter { $0.bucket == .done } }
    var totalCount: Int { rows.count }
    var needsYouCount: Int { needsYou.count }
    var runningCount: Int { running.count }
    func row(id: String) -> SessionRow? { rows.first { $0.id == id } }
    func work(_ sessionID: String) -> SessionWork? { nil }
    /// From the row alone: its last prompt, a finished turn's message, and its work.
    func peek(_ sessionID: String, clean: Bool) async -> SessionPeek? {
        guard let row = row(id: sessionID) else { return nil }
        return SessionPeek.make(row: row, clean: clean, prompt: row.lastPrompt, reply: row.bucket == .done ? row.detail : nil,
                                replyIsCurrent: true, read: nil, work: work(sessionID))
    }
}

enum SessionBucket: Sendable, Equatable { case needsYou, running, done }

/// Where a row's title comes from: the agent's own title, the owner's first prompt (then the status line never says
/// that prompt again, P203), or the repo, before any prompt (then the repo is not said again beside it, P204).
enum TitleSource: Sendable, Equatable { case agent, prompt, repo }

/// Where a finish comes from, for the island's Done card and Glance.
enum FinishSource: Equatable, Sendable {
    /// A row that turned done: the demo feed, renders and tests.
    case rows
    /// The live engine's Done signals, the last one it let out (nil before the first): after its 1.5 s hold, once per
    /// turn, and none while the session's own tab is in front when No alerts for focused sessions is on (spec §3.4).
    case engine(last: ReleasedFinish?)
}

/// One Done the engine let out; `serial` tells a later Done of the same session from the one already seen.
struct ReleasedFinish: Equatable, Sendable {
    var sessionID: String
    var serial: Int
}

/// What the owner does on a question card (`SessionsModel.answerQuestion`).
enum QuestionInput: Equatable, Sendable {
    /// Option `index` (0-based) of the question on show: ⌃1…⌃4 or a click.
    case option(Int)
    /// A typed answer to the question on show.
    case text(String)
    /// A multi-select question's picks: on to the next question, or sent on the last.
    case next
    case back
}

/// One session as the lists draw it. Plain values: views never touch `AgentSession`.
struct SessionRow: Identifiable, Equatable, Sendable {
    var id: String
    var agent: GlyphPalette.Agent
    var bucket: SessionBucket
    /// The workspace (folder) name, e.g. "WeatherStation".
    var project: String
    /// The session's working folder, whole (its right-click menu copies it and opens it in Finder); nil when unknown.
    var folder: String? = nil
    /// The chat's title, e.g. "Name the app": the agent's own, else the owner's first prompt, else the repo
    /// (`titleSource`). Never the agent's name, which its mark and colour say (P204).
    var task: String
    /// The engine's one honest status word (Thinking, Compacting, Interrupted, a tool, …).
    var status: StatusWord
    /// What the status is about: the approval's command, the question, the finished turn's last message.
    var detail: String?
    /// The owner's last prompt ("You: …").
    var lastPrompt: String?
    /// Host tag: "Terminal", "iTerm", "Ghostty", "Codex.app", …
    var host: String?
    /// The account tag from the transcript path (Detailed/window tag, Clean hover). nil when unknown.
    var accountAlias: String?
    var updatedAt: Date
    var isCodexApp: Bool
    /// The row's glyph and the state its colour comes from (`GlyphPalette.colour`).
    var glyph: PixelGlyph
    var glyphState: GlyphPalette.State
    /// True while a question, approval or plan waits: the row opens a card.
    var hasCard: Bool
    /// While running: when the current tool (or, with none, the current turn) started. nil when unknown.
    var activeSince: Date? = nil
    /// The subagent that asks ("worker"), said before the tool: its request waits on its parent's row.
    var asker: String? = nil
    /// How many of the session's requests wait on you (its card's and those behind it); 1 for a card with no engine
    /// request behind it.
    var waitingRequests: Int = 0
    /// Where `task` comes from.
    var titleSource: TitleSource = .agent
    /// A session the owner did not start at the top level: a scripted run (shown only with Show scripted runs) or a
    /// subagent's own thread. It never counts in the pill or leads it, except while a card of its waits on the owner;
    /// a list's footer counts it while it runs (P254).
    var isQuiet = false
    /// The model, the permission mode and the task progress, worded (`RowFacts`): said by Detailed rows and a Clean row's
    /// peek (P310).
    var facts = RowFacts()
    /// Running, nothing waiting on the owner, and no sign of life for Settings › Island › Stalled after: the row reads
    /// Stalled and its glyph holds still, and the island gives one quiet notice (P312).
    var isStalled = false
    /// While compacting: when the compaction began (its PreCompact), so the row reads "Compacting 0:42" (P433).
    var compactingSince: Date? = nil
    /// The branch the session's folder has checked out, when it is not the repo's default (`GitBranches`, P434 to P436):
    /// said by Detailed rows and a Clean row's peek, as the facts are.
    var branch: String? = nil
    /// The owner's first prompt, whatever titles the row (Settings › Island › Mute rules, P421); nil when unknown.
    /// Memory only, as the title is (P200).
    var firstPrompt: String? = nil
    /// The SSH host a remote session runs on ("gpu1", P745): said on every row style, as where it runs is not this Mac.
    var remoteHost: String? = nil
    /// The limit or API error its last turn stopped on (P700): the status line says it in place of "Turn failed" or the
    /// last message ("Limit reached · resets 15:00").
    var limit: RowLimit? = nil
    /// The profile folder the session runs in, from its transcript's path as the engine tags it (`SessionAccountTag`):
    /// which account it uses, for the accounts in use (`AccountsInUse`, P810). nil when not known.
    var account: RowAccount? = nil
    /// Its card is an approval the agent waits on with no prompt of its own (`AttentionRequest.waitsOnIslandAlone`: Codex
    /// behind the old helper, Copilot CLI, Devin, Qwen Code): no mute rule keeps it quiet (P931).
    var waitsOnIsland = false
    /// Its tab is known exactly, so it can be sent to the island (`SessionEngine.canFold`, P1300).
    var canFold = false
    /// Sent to the island: its conversation card stands for it in the island's list (P1307).
    var isFolded = false
    /// What its menu offers to go on in its agent's own app ("Open in Claude", P1510); nil: none.
    var appOffer: String? = nil

    var isInterrupted: Bool { status == .interrupted }
    /// What the closed pill and the footer's count may tell of: every row of the owner's, a quiet one only while its
    /// card waits.
    var tells: Bool { !isQuiet || hasCard }
    /// Archive is offered only on a finished row (P131).
    var canArchive: Bool { bucket == .done && !hasCard }
}

/// A session's provider and its profile folder (`CLAUDE_CONFIG_DIR` or `CODEX_HOME`), as its transcript's path names them:
/// the folder as the engine resolved it (links followed), and the id of the account whose folder it is (`Account.id`, as
/// the accounts file spells the folder), nil for a folder that is no account's.
struct RowAccount: Hashable, Sendable {
    var provider: Provider
    var folder: String
    var accountID: String? = nil
}

/// A session sent to the island, as its conversation card draws it (P1300 to P1324): the row says who and what it is
/// at (its glyph, mark, project and title, its state and tool); this says the rest.
struct FoldedCardModel: Equatable, Sendable, Identifiable {
    /// Where a reply goes now.
    enum Reach: Equatable, Sendable {
        /// Typed into its tab (route a).
        case tab
        /// Its tab is gone: the agent's own resume goes on with the conversation (route b).
        case resume
        /// Codex's shared background service holds the thread: a reply starts a turn there (P1487).
        case daemon
        /// Nowhere from the island: "Open in terminal to reply".
        case openOnly
        /// In Claude Code's own background: a reply goes through `claude attach` (wave 8, P1460).
        case background
    }

    var sessionID: String
    var id: String { sessionID }
    /// Its row, as the lists would draw it, whether they list it or not (a session whose tab closed and ended is listed
    /// nowhere else, P1303).
    var row: SessionRow
    var agent: GlyphPalette.Agent { row.agent }
    /// The agent's last answer, whole, in its own Markdown; nil before the first. While a turn runs, the answer before it.
    var message: String?
    /// A turn runs (in its tab, or the island's resumed run): the card reads Working, and a reply waits for its end.
    var working = false
    var reach: Reach = .tab
    /// One quiet line over the field: the resume's own note before its first reply, or "Not opened".
    var note: String?
    /// Why the last reply through the resume did not go, or its run failed ("Not sent · Claude Code not found",
    /// "Failed · …"): it takes the note's place, and a reply that did not go keeps its Retry (P1331).
    var problem: String?
    /// A reply held for the turn's end, shown on the line ("Held · <text> · Cancel", P1358).
    var held: String?
    /// Where the last reply stands: "Sending…", "Sent", "Not sent · Retry".
    var send: CardSend?
    /// The island's resumed run is under way: Stop ends it.
    var stoppable = false
    /// A held reply that did not go, for the field to take back (P1356, P1359): only a new Return sends it.
    var returned: String?
    /// Why it did not go ("Not sent · its tab closed"); both stay until the next Return or ✕.
    var unsent: String?
    /// Its agent ended while its turn ran ("Stopped when its window closed", P1415): the line says so.
    var stopped: String?
    /// What Continue sends, shown on the card before the click, while Continue is offered: stopped, its resume offered,
    /// nothing on its way or held (P1419).
    var continuePrompt: String?
    /// The terminal its window is in while that window sits in the Dock and its turn runs there: "Working in Terminal"
    /// (P1417).
    var inTerminal: String?
    /// In Claude Code's own background, or on its way there (wave 8, P1450 on): the line says where it stands.
    var background: FoldedBackgroundModel? = nil
    /// Continue or a reply met a turn Codex's background service goes on with: "Codex is still finishing this in the
    /// background" (P1488). Otherwise such a turn reads Working.
    var finishing = false
    /// Open in <App>: what the card offers, and where the hand-over stands (P1510 to P1519); nil: no app for it.
    var app: FoldedAppModel? = nil

    /// Open in terminal carries the stopped turn on in the new window, with `SessionEngine.continuePrompt` (P1439): the
    /// session stopped mid-turn, and its resume can open it.
    var continuesInTerminal: Bool { stopped != nil && (reach == .resume || reach == .daemon) }

    /// A message too long to read here whole: its box scrolls and ends with Open in terminal.
    var isLong: Bool { (message?.count ?? 0) > Self.longMessage || (message?.split(whereSeparator: \.isNewline).count ?? 0) > Self.longLines }

    static let longMessage = 600
    static let longLines = 8
}

/// A folded Claude Code session in Claude Code's own background, as its card's line says it (wave 8, P1450 on).
struct FoldedBackgroundModel: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Something waits on the owner in its tab: "Moves to the background when this turn ends".
        case waits
        /// `/background` was typed: "Moving to the background…".
        case moving
        /// "Background", with Working or "attached in Terminal".
        case moved
        /// Stop ran, or it ended: "Background · stopped".
        case stopped
        /// The move did not happen: its words ("Not moved · it is still in its tab").
        case notMoved(String)
    }

    var stage: Stage
    /// The terminal a window attached to it runs in, while one is.
    var attachedIn: String? = nil

    /// The line's words, but Working's, which the line draws with its tool.
    var words: String {
        switch stage {
        case .waits: "Moves to the background when this turn ends"
        case .moving: "Moving to the background…"
        case .moved: attachedIn.map { "Background · attached in \($0)" } ?? "Background"
        case .stopped: "Background · stopped"
        case let .notMoved(words): words
        }
    }

    /// The line's help. `/background` is typed after whatever sits unsent in its tab's prompt, which goes with it: the
    /// card says so while it waits, moves or did not move (P1543).
    var help: String {
        switch stage {
        case .waits: "It waits on you in its tab. Once its turn ends, /background is typed there: send or clear what you typed in it"
        case .moving: "/background was typed into its tab; anything typed there and not sent went with it"
        case .notMoved: "Text typed in its tab and not sent would have gone with /background: look in its tab"
        case .moved, .stopped: "It runs in Claude Code's background: closing a window leaves it running"
        }
    }
}

/// A folded card's Open in <App> (P1510 to P1519): offered, waiting for its turn's end, under way, in the app, picked
/// there, or refused and why.
struct FoldedAppModel: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case offered
        /// "Opens in Claude when this turn ends · Cancel".
        case pending
        /// "Opening in Claude…".
        case opening
        /// "In Claude", or why Open in terminal waits ("Quit Claude first").
        case inApp(note: String?)
        /// "Pick this session in VS Code".
        case pick
        /// It did not go: why, in one line.
        case blocked(String)
    }

    var app: HandoffApp
    var state: State
    /// It can be clicked again (offered, or refused once).
    var offered = false

    /// "Claude", "Codex", "VS Code".
    var name: String { app.name }
    var title: String { "Open in \(name)" }

    /// The reply field hides while the app holds the conversation, is about to, or waits to (no reply would reach it).
    var hidesField: Bool {
        switch state {
        case .offered, .blocked: false
        case .pending, .opening, .inApp, .pick: true
        }
    }

    /// What the line's left says; nil: nothing (only the link offers it).
    var words: String? {
        switch state {
        case .offered: nil
        case .pending: HandoffWords.pending(app)
        case .opening: HandoffWords.opening(app)
        case let .inApp(note): note ?? HandoffWords.inApp(app)
        case .pick: HandoffWords.pick(app)
        case let .blocked(why): why
        }
    }

    /// The words say why it waits or did not go: the waits colour.
    var warns: Bool {
        switch state {
        case .blocked: true
        case let .inApp(note): note != nil
        default: false
        }
    }

    /// The card's model of the engine's state and offer.
    static func make(state: HandoffState?, offer: HandoffOffer?) -> FoldedAppModel? {
        guard let state else { return offer.map { FoldedAppModel(app: $0.app, state: .offered, offered: true) } }
        let mapped: State = switch state {
        case .pending: .pending
        case .opening: .opening
        case let .inApp(_, note): .inApp(note: note)
        case .pick: .pick
        case let .blocked(_, why): .blocked(why)
        }
        return FoldedAppModel(app: state.app, state: mapped, offered: offer != nil)
    }
}

/// The cards (question, approval, plan ready, done) as plain values, and the island's quota notice (P125), which is
/// no session's and comes from the usage model (`AppEnvironment.card(for:)`).
enum SessionCard: Equatable, Sendable {
    case question(QuestionCardModel)
    case approval(ApprovalCardModel)
    case plan(PlanCardModel)
    case done(DoneCardModel)
    case quota(QuotaNoticeCard)

    var sessionID: String {
        switch self {
        case let .question(card): card.sessionID
        case let .approval(card): card.sessionID
        case let .plan(card): card.sessionID
        case let .done(card): card.sessionID
        case let .quota(card): card.sessionID
        }
    }
}

/// Where a card's answer, decision or reply stands once the owner sent it: only what the card still shows. A decision
/// or an answer that went takes its card with it, so for them only `.notSent` shows; a reply shows all three.
enum CardSend: Equatable, Sendable {
    case sending
    case sent
    /// It did not go out: "Not sent · Retry".
    case notSent
}

/// The engine request a card stands for (the needs-you design §3.5): its id, whether the island can answer it, where
/// Open goes, a subagent's name, and how many more wait behind it. nil on a card with no engine behind it.
struct CardRequest: Equatable, Sendable {
    var id: String
    /// The island holds the agent's hook: the answer buttons and field work. False: read-only, Open and ✕ only; the
    /// agent's own prompt is where it is answered.
    var answerable: Bool
    /// Where Open goes, and what a read-only card names ("in Codex").
    var place: AttentionRequest.Place
    /// A subagent's type ("worker"), before the tool.
    var agentType: String?
    /// Confirmed requests waiting behind this one in the same session ("· 2 more").
    var more: Int
    /// A prompt with no hook behind it (a sandbox network prompt, an MCP form): no content to show.
    var isNotice: Bool
    /// ✕ closes it: a read-only request only, never one the island holds.
    var dismissable: Bool
    /// A subagent's request the island holds while its card shows (Answer subagents on the island, P350): when the hold
    /// ends and the card turns read-only. The Yes button's countdown runs out then. nil for every other card.
    var holdEnds: Date? = nil
}

struct QuestionCardModel: Equatable, Sendable {
    struct Option: Equatable, Sendable { var label: String; var description: String }
    var sessionID: String
    var agent: GlyphPalette.Agent
    /// The bracketed topic, e.g. "App name".
    var topic: String?
    var question: String
    /// ⌃1…⌃4 pick the first four. Upstream's "Other" is the answer field, not an option.
    var options: [Option]
    /// Several options may be picked; a Next or Send button sends them.
    var multiSelect = false
    /// Which of the prompt's questions shows (0-based), of `count`: Claude asks one to four at once.
    var step = 0
    var count = 1
    /// The options picked on this question so far: a multi-select's picks, or a pick made before going back.
    var picked: Set<Int> = []
    var send: CardSend?
    var request: CardRequest? = nil
    /// A read-only card's questions, every one with its options, drawn as plain lines: the agent's own prompt is where
    /// they are answered, so the card shows them all at once. Empty on a card the island answers.
    var shown: [Shown] = []

    struct Shown: Equatable, Sendable {
        var topic: String?
        var question: String
        var options: [Option]
    }

    var isLastStep: Bool { step >= count - 1 }
    /// The island can answer it: options to pick and a field (a card with no engine request behind it too).
    var isAnswerable: Bool { request?.answerable ?? true }
}

struct ApprovalCardModel: Equatable, Sendable {
    var sessionID: String
    var agent: GlyphPalette.Agent
    /// "Bash", "Edit", …: the header reads "Needs approval · Bash".
    var tool: String
    /// What is approved, in the box: the whole command, the change as a diff, the URL (`ApprovalContent`).
    var body: ApprovalBody
    /// The dim line under the box: why, when the agent said (Bash's description, Codex's justification), and the
    /// worktree's branch.
    var reason: String?
    /// The third button in Claude's own words (C4), e.g. "Yes, allow git push in this project"; nil hides it.
    var alwaysAllowLabel: String?
    /// A No can also end the turn (⌃⇧D): Claude only (`ApprovalChoices.canStop`).
    var canStop = false
    /// Yes and switch the session to one of these modes, one button each, no key (`SessionEngine.modeChoices`, P450).
    var modes: [ClaudePermissionMode] = []
    var send: CardSend?
    var request: CardRequest? = nil

    var isAnswerable: Bool { request?.answerable ?? true }
    /// A prompt with no hook behind it: nothing to show but where it waits.
    var isNotice: Bool { request?.isNotice == true }
}

struct PlanCardModel: Equatable, Sendable {
    var sessionID: String
    var agent: GlyphPalette.Agent
    /// The plan, read from the transcript (`input.plan`); nil shows just "Plan ready" and the buttons, never
    /// upstream's own sentence.
    var plan: String?
    /// "N steps": the plan's steps (`SessionRowText.planSteps`).
    var steps: Int?
    var canStop = false
    /// Approve into one of these modes, one button each, no key; the plain Approve sends none (P450, P452).
    var modes: [ClaudePermissionMode] = []
    var send: CardSend?
    var request: CardRequest? = nil

    var isAnswerable: Bool { request?.answerable ?? true }
}

struct DoneCardModel: Equatable, Sendable {
    var sessionID: String
    var agent: GlyphPalette.Agent
    var message: String
    var interrupted: Bool
    /// The turn ended in a StopFailure (an API error or a rate limit): it needs you. `message` is then why, in plain
    /// words (`TurnFailure.words`).
    var failed = false
    /// The session's terminal is known exactly, so a reply can be typed into it (P128); false hides the field.
    var canReply = false
    /// The reply's state once one was sent.
    var send: CardSend?
    /// Not a finish: a running turn that stalled (P312). The card is its one quiet notice, brief like a finish's and
    /// gone once the session shows a sign of life; its header, the row, says what it was on (no message).
    var stalled = false
    /// The limit or API error the turn stopped on (P700): the status line says it, and for the account's limit the card
    /// offers the best other account (`LimitAlternative`). `message` is then empty.
    var limit: RowLimit? = nil
}
