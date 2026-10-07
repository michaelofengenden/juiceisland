import Foundation
import IslandEngine
import IslandHookNotes
import Observation
import OpenIslandCore

/// `SessionsModel` over a `SessionEngine`: maps the engine's rows to `SessionRow`s and its waiting requests to cards.
/// A thin adapter in the app, not an engine change.
///
/// Views never observe the engine itself: every engine change (a liveness poll, a hook stamp, a heartbeat, a jump
/// record) would redraw every list. The model maps the rows and their cards once per engine change, after it, and
/// bumps `revision`, which views do observe, only when a row or a card differs from what they last drew. A read right
/// after a change maps at once, so it is never stale. Ages and the time-ranked order move on with `minute`.
@MainActor
@Observable
final class EngineSessionsModel: SessionsModel {
    @ObservationIgnored let engine: SessionEngine
    @ObservationIgnored private let clock: @MainActor () -> Date
    /// What a row click does: the demo only notes it; live runs the engine's jump.
    @ObservationIgnored private let jumps: Jumps
    @ObservationIgnored private let noteLifetime: Duration
    /// Account id → alias, for the account tag.
    @ObservationIgnored private let aliasForAccountID: @MainActor (String) -> String?
    /// Settings › General › Show Codex app threads, read while mapping, so a change maps the rows again.
    @ObservationIgnored private let showsCodexAppThreads: @MainActor () -> Bool
    /// Settings › Island › Stalled after, in seconds (nil: off), read while mapping as Show Codex app threads is (P312).
    @ObservationIgnored private let stalledAfter: @MainActor () -> TimeInterval?
    /// The Mac's awake time (`ProcessInfo.systemUptime`, which stands still while it sleeps); nil (the demo, tests that
    /// move the clock by hand) counts every second of the clock as awake.
    @ObservationIgnored private let uptime: (@MainActor () -> TimeInterval)?
    /// The spans the Mac slept, found at each mapping, so a stall counts awake time only (P312).
    @ObservationIgnored private var sleeps = SleepLog()
    /// Each session's folder's branch (P434): read off the main thread when a session is new or starts or ends a turn.
    @ObservationIgnored private let branches: GitBranches
    /// Sessions whose live jump has not answered yet: a second click on one waits for the first.
    @ObservationIgnored private var jumpsInFlight: Set<String> = []
    /// The jumps asked for, newest last, the last `requestedJumpLimit` (tests and the demo read these).
    private(set) var requestedJumps: [String] = []
    private(set) var jumpNote: JumpNote?
    /// Bumped when a row or a card changes; what views observe instead of the engine.
    private var revision = 0
    /// The clock's minute: ages ("3m") and the time-ranked order move on when it does.
    private var minute = 0
    /// The rows and cards now; nil once the engine has changed since they were mapped.
    @ObservationIgnored private var mapped: Mapped?
    /// The rows and cards views last saw (`revision`).
    @ObservationIgnored private var shown: Mapped?
    @ObservationIgnored private var publishScheduled = false
    /// Question cards' progress by session (`answerQuestion`).
    @ObservationIgnored private var questionDrafts: [String: QuestionDraft] = [:]
    /// What each waiting approval is about, for the request and input it was made from (`approvalContent`).
    @ObservationIgnored private var approvalContents: [String: (requestID: UUID, read: Bool, content: ApprovalContent.Mapped)] = [:]
    /// What each card sent and how that went, by session (P129): kept while its request, question or finished turn is.
    @ObservationIgnored private var sends: [String: SendRecord] = [:]
    /// When each waiting card began to wait, as an order: the engine request it shows, and its place (P130); and when,
    /// on the awake clock (`waitingSince`), nil for one that already waited at the first mapping.
    @ObservationIgnored private var arrivals: [String: (key: String, order: Int, at: TimeInterval?)] = [:]
    @ObservationIgnored private var nextArrival = 0
    /// Past the first mapping: a card that begins to wait from then on came in while the owner could be looking.
    @ObservationIgnored private var mappedOnce = false
    @ObservationIgnored private var minuteTimer: Timer?
    /// Each folded session's last answer as last seen, shown while its next turn runs (P1308).
    @ObservationIgnored private var foldMessages: [String: String] = [:]
    /// The answer each folded session had as the island's last resumed run of it began ("" for none), so a run whose
    /// hooks reported no answer shows the run's own once it ended (contract R3); and the sessions whose run is under way.
    @ObservationIgnored private var foldRunBase: [String: String] = [:]
    @ObservationIgnored private var foldRunLive: Set<String> = []

    static let requestedJumpLimit = 20

    /// One card's send: what it answered (the request or the question; none for a reply, which lasts while the turn it
    /// follows stays finished), where it stands, and what Retry sends again.
    private struct SendRecord {
        enum Retry { case approve(ApprovalDecision), answer(QuestionPromptResponse), reply(String) }
        var key: UUID?
        var state: CardSend
        var retry: Retry
    }

    /// One mapping of the engine: the rows in display order and the card each of them opens.
    private struct Mapped: Equatable {
        var rows: [SessionRow]
        var cards: [String: SessionCard]
        /// The folded sessions' conversation cards, newest first (P1300).
        var folded: [FoldedCardModel] = []

        /// Equal when views would draw the same. A row's `updatedAt` counts only to its minute: every hook event of a
        /// running session moves it, and ages show whole minutes, which the minute clock redraws anyway.
        static func == (lhs: Mapped, rhs: Mapped) -> Bool {
            lhs.cards == rhs.cards && lhs.folded == rhs.folded && lhs.rows.map(\.drawnAge) == rhs.rows.map(\.drawnAge)
        }
    }

    enum Jumps: Sendable {
        /// Fixture sessions: a click never jumps; it notes "Demo session".
        case demo
        /// `SessionEngine.jump(sessionID:)`: upstream's jump service through JumpRunner (deadlines, trace, fallback).
        case live
    }

    /// `stalledAfter`: off unless given (the app passes the setting; the demo's fixtures run as long as they like).
    init(engine: SessionEngine, clock: @escaping @MainActor () -> Date = { Date() },
         aliasForAccountID: @escaping @MainActor (String) -> String? = { _ in nil },
         jumps: Jumps = .demo, noteLifetime: Duration = JumpNote.lifetime,
         showsCodexAppThreads: @escaping @MainActor () -> Bool = { true },
         stalledAfter: @escaping @MainActor () -> TimeInterval? = { nil },
         uptime: (@MainActor () -> TimeInterval)? = nil, branches: GitBranches = GitBranches(.fixed([:]))) {
        self.engine = engine
        self.branches = branches
        self.clock = clock
        self.aliasForAccountID = aliasForAccountID
        self.showsCodexAppThreads = showsCodexAppThreads
        self.stalledAfter = stalledAfter
        self.uptime = uptime
        self.jumps = jumps
        self.noteLifetime = noteLifetime
        minute = Self.minute(of: clock())
        shown = current()
        mappedOnce = true
        // A branch read that changed what a row shows maps the rows again.
        branches.changed = { [weak self] in
            self?.mapped = nil
            self?.publish()
        }
        // Ages and the time-ranked order move on each minute, whatever the engine does. A fixed clock (the demo, renders)
        // never changes its minute, so nothing redraws.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.tick() }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    isolated deinit {
        minuteTimer?.invalidate()
    }

    var now: Date {
        _ = minute
        return clock()
    }

    var rows: [SessionRow] {
        _ = revision
        return current().rows
    }

    var folded: [FoldedCardModel] {
        _ = revision
        return current().folded
    }

    func card(for sessionID: String) -> SessionCard? {
        _ = revision
        let mapped = current()
        if let card = mapped.cards[sessionID] { return card }
        // A session that is not a row (overflow, or gone): read the engine for it.
        return mapped.rows.contains { $0.id == sessionID } ? nil : makeCard(for: sessionID)
    }

    /// The rows whose card waits on you, the one that has waited longest first.
    var waiting: [SessionRow] {
        let rows = self.rows.filter(\.hasCard)
        return rows.sorted { (arrivals[$0.id]?.order ?? .max) < (arrivals[$1.id]?.order ?? .max) }
    }

    func waitingSince(_ sessionID: String) -> TimeInterval? {
        _ = current()
        return arrivals[sessionID]?.at
    }

    // MARK: Publishing

    /// The rows and cards now: the last mapping, or a new one when the engine changed since. Mapping watches what it
    /// reads, so the engine's next change marks it stale and publishes it again.
    private func current() -> Mapped {
        if let mapped { return mapped }
        if let uptime { sleeps.note(wall: clock(), awake: uptime()) }
        let fresh = withObservationTracking {
            let rows = mapRows()
            let cards = rows.compactMap { row in makeCard(for: row.id).map { (row.id, $0) } }
            let folded = engine.foldedSessions.compactMap { fold in foldedCard(fold, listed: rows.first { $0.id == fold.sessionID }) }
            return Mapped(rows: rows, cards: Dictionary(uniqueKeysWithValues: cards), folded: folded)
        } onChange: { [weak self] in
            // The engine is main-actor isolated: its changes, and so this, happen on the main thread.
            MainActor.assumeIsolated { self?.engineChanged() }
        }
        mapped = fresh
        forgetAnswered()
        noteArrivals(fresh.rows)
        branches.keep(sessions: Set(fresh.rows.map(\.id)))
        return fresh
    }

    /// Drops the progress, the kept content and the sends of cards whose question or approval is gone, and a reply's
    /// once its session has moved on from the turn it followed.
    private func forgetAnswered() {
        let state = engine.state
        approvalContents = approvalContents.filter { state.session(id: $0.key)?.permissionRequest?.id == $0.value.requestID }
        questionDrafts = questionDrafts.filter { state.session(id: $0.key)?.questionPrompt?.id == $0.value.promptID }
        sends = sends.filter { id, record in
            guard let session = state.session(id: id) else { return false }
            switch record.retry {
            case .approve: return session.permissionRequest?.id == record.key
            case .answer: return session.questionPrompt?.id == record.key
            case .reply: return session.phase == .completed
            }
        }
    }

    /// Gives each card that began to wait since the last mapping its place in the queue; a session that asks again
    /// (a new request or question, or the next one of its queue) goes to the back.
    private func noteArrivals(_ rows: [SessionRow]) {
        var kept: [String: (key: String, order: Int, at: TimeInterval?)] = [:]
        let now = mappedOnce ? ProcessInfo.processInfo.systemUptime : nil
        for row in rows where row.hasCard {
            guard let key = engine.attentionHead(for: row.id)?.id else { continue }
            if let known = arrivals[row.id], known.key == key {
                kept[row.id] = known
            } else {
                nextArrival += 1
                kept[row.id] = (key, nextArrival, now)
            }
        }
        arrivals = kept
    }

    private func engineChanged() {
        mapped = nil
        guard !publishScheduled else { return }
        publishScheduled = true
        Task { @MainActor [weak self] in self?.publish() }
    }

    /// After a burst of engine changes: redraws only when a row or a card is not what views last saw.
    private func publish() {
        publishScheduled = false
        let fresh = current()
        guard fresh != shown else { return }
        shown = fresh
        revision &+= 1
    }

    /// The minute timer's tick (tests call it): a new minute redraws the ages and ranks the rows again.
    func tick() {
        let minute = Self.minute(of: clock())
        guard minute != self.minute else { return }
        self.minute = minute
        mapped = nil
        publish()
    }

    nonisolated static func minute(of date: Date) -> Int { Int((date.timeIntervalSinceReferenceDate / 60).rounded(.down)) }

    /// With Show Codex app threads off, a Codex app thread's running and done rows are left out, so nothing counts or
    /// shows them; one that waits on an approval or a question always shows, because the app shows no prompt of its
    /// own while our hook holds it (spec §3.4).
    private func mapRows() -> [SessionRow] {
        let showsAppThreads = showsCodexAppThreads()
        let mapped = engine.rows.map(row(for:)).filter { showsAppThreads || !$0.isCodexApp || $0.bucket == .needsYou }
        // Needs you, then running, then done; the engine's order inside each bucket.
        return mapped.filter { $0.bucket == .needsYou } + mapped.filter { $0.bucket == .running } + mapped.filter { $0.bucket == .done }
    }

    /// The engine request a waiting card stands for: the session's oldest confirmed one (its glyph's), and how many
    /// confirmed ones wait behind it.
    private func cardRequest(_ head: AttentionRequest) -> CardRequest {
        CardRequest(id: head.id, answerable: head.isAnswerable, place: head.place, agentType: Self.asker(head),
                    more: max(0, engine.attentionQueue(for: head.sessionID).count - 1), isNotice: head.content == .notice,
                    dismissable: head.channel == .open, holdEnds: head.holdEndsAt)
    }

    /// A card from the engine's book (C14): the session's oldest confirmed request, whatever the session's phase says;
    /// with none, a finished turn's card. A phase that says waiting with no request behind it opens nothing (P161).
    private func makeCard(for sessionID: String) -> SessionCard? {
        guard let session = engine.state.session(id: sessionID) else { return nil }
        let agent = self.agent(session)
        if let head = engine.attentionHead(for: sessionID) { return waitingCard(session, head: head, agent: agent) }
        switch session.phase {
        case .running:
            // A stalled turn's one quiet notice (P312): gone once the session shows a sign of life.
            guard isStalled(session, head: nil) else { return nil }
            return .done(DoneCardModel(sessionID: session.id, agent: agent, message: "", interrupted: false, stalled: true))
        case .waitingForAnswer, .waitingForApproval:
            return nil
        case .completed:
            // Its main agent waits on its subagents: not done, so no Done card (P370).
            if engine.isDelegating(session) { return nil }
            let canReply = engine.canReply(sessionID: session.id)
            // A limit or an API error: its status line says why, and nothing else of the turn (P700).
            let limit = rowLimit(session)
            if engine.hasFailedTurn(session) {
                // A StopFailure: the card says "Turn failed" and why, in plain words (P132).
                return .done(DoneCardModel(sessionID: session.id, agent: agent, message: limit == nil ? Self.failureText(session) ?? "" : "",
                                           interrupted: false, failed: true, canReply: canReply, send: sends[session.id]?.state,
                                           limit: limit))
            }
            // Never the bridge's summary, which can be "Prompt: <task-notification>…" (P155).
            return .done(DoneCardModel(sessionID: session.id, agent: agent, message: limit == nil ? Self.lastMessage(session) ?? "" : "",
                                       interrupted: engine.statusWord(for: session) == .interrupted, canReply: canReply,
                                       send: sends[session.id]?.state, limit: limit))
        }
    }

    private func waitingCard(_ session: AgentSession, head: AttentionRequest, agent: GlyphPalette.Agent) -> SessionCard? {
        let request = cardRequest(head)
        switch head.content {
        case .notice:
            // A prompt with no hook behind it (a sandbox network prompt, an MCP form): only where it waits.
            if head.kind.isQuestion {
                return .question(QuestionCardModel(sessionID: session.id, agent: agent, topic: nil, question: "", options: [],
                                                   request: request))
            }
            return .approval(ApprovalCardModel(sessionID: session.id, agent: agent, tool: "", body: .text(""), request: request))
        case let .question(prompt):
            let items = Self.questionItems(prompt)
            guard !items.isEmpty else { return nil }
            guard request.answerable else {
                // Read-only: every question with its options at once; the first one's topic when it is the only one.
                let first = items[0]
                return .question(QuestionCardModel(sessionID: session.id, agent: agent, topic: items.count == 1 ? first.header : nil,
                                                   question: first.question, options: first.options, multiSelect: first.multiSelect,
                                                   count: items.count, request: request,
                                                   shown: items.map { .init(topic: $0.header, question: $0.question, options: $0.options) }))
            }
            let draft = questionDraft(session.id, prompt: prompt)
            let step = min(draft.step, items.count - 1)
            let item = items[step]
            return .question(QuestionCardModel(sessionID: session.id, agent: agent, topic: item.header, question: item.question,
                                               options: item.options, multiSelect: item.multiSelect, step: step,
                                               count: items.count, picked: Set(draft.picks[step] ?? []),
                                               send: sends[session.id]?.state, request: request))
        case let .approval(permission):
            let answerable = request.answerable
            let send = answerable ? sends[session.id]?.state : nil
            // A subagent's, held for the island (P350): Yes and No only. No and stop would end the turn, not the subagent;
            // Always allow would take Claude's suggestions, which may widen the whole session's permissions.
            let canStop = answerable && head.isRoot && ApprovalChoices.canStop(session.tool)
            // The mode buttons: only for a Claude request on the main thread the island answers (P450, P453).
            let modes = answerable ? engine.modeChoices(for: head) : []
            if Self.isPlan(permission) {
                let plan = Self.plan(engine.toolCallInput(for: session.id))
                return .plan(PlanCardModel(sessionID: session.id, agent: agent, plan: plan, steps: SessionRowText.planSteps(plan),
                                           canStop: canStop, modes: modes, send: send, request: request))
            }
            let content = approvalContent(session, request: permission)
            let branch = session.claudeMetadata?.worktreeBranch.flatMap { $0.isEmpty ? nil : "branch \($0)" }
            let reason = [content.reason, branch].compactMap { $0 }.joined(separator: " · ")
            return .approval(ApprovalCardModel(sessionID: session.id, agent: agent, tool: content.tool, body: content.body,
                                               reason: reason.isEmpty ? nil : reason,
                                               alwaysAllowLabel: answerable && head.isRoot ? engine.alwaysAllowLabel(for: session.id) : nil,
                                               canStop: canStop, modes: modes, send: send, request: request))
        }
    }

    /// What the approval is about (`ApprovalContent`), kept per request, before and after its input is read (a
    /// request's input never changes once read): a change's diff is worked out once, not at every engine change while
    /// the card waits.
    private func approvalContent(_ session: AgentSession, request: PermissionRequest) -> ApprovalContent.Mapped {
        let input = engine.toolCallInput(for: session.id)
        if let kept = approvalContents[session.id], kept.requestID == request.id, kept.read == (input != nil) { return kept.content }
        let content = ApprovalContent.make(request: request, input: input, tool: session.tool,
                                           folder: session.jumpTarget?.workingDirectory)
        approvalContents[session.id] = (request.id, input != nil, content)
        return content
    }

    func approve(_ sessionID: String, _ decision: ApprovalDecision, request: String?) {
        Task { await decide(sessionID, decision, request: request) }
    }

    /// `approve`, awaited (tests): a decision that did not go out keeps its card, with Retry sending it again. It goes
    /// to the request the card showed (`request`), by its id, only while that one still waits (P170).
    func decide(_ sessionID: String, _ decision: ApprovalDecision, request requestID: String? = nil) async {
        guard let head = engine.attentionHead(for: sessionID), requestID == nil || head.id == requestID,
              let permission = head.permissionRequest else { return }
        let outcome = await engine.approve(requestID: head.id, decision: decision)
        record(sessionID, outcome, SendRecord(key: permission.id, state: .notSent, retry: .approve(decision)))
    }

    /// Notes a card's send that did not go out, or clears the note once one did; a send that found nothing to answer
    /// leaves things as they are.
    private func record(_ sessionID: String, _ outcome: SendOutcome, _ failure: SendRecord) {
        switch outcome {
        case .notSent: store(failure, for: sessionID)
        case .sent: if sends[sessionID] != nil { store(nil, for: sessionID) }
        case .nothingToSend: break
        }
    }

    /// Stores a card's send and redraws the card.
    private func store(_ record: SendRecord?, for sessionID: String) {
        sends[sessionID] = record
        mapped = nil
        publish()
    }

    func retry(_ sessionID: String) {
        guard let record = sends[sessionID], record.state == .notSent else { return }
        // Retry names the request its failed send was for, taken at the click, so a request that took its place
        // before the send runs gets nothing (P170, P186).
        let head = engine.attentionHead(for: sessionID)
        switch record.retry {
        case let .approve(decision):
            guard let head, head.permissionRequest?.id == record.key else { return }
            approve(sessionID, decision, request: head.id)
        case let .answer(response):
            guard let head, head.questionPrompt?.id == record.key else { return }
            let requestID = head.id
            Task { await sendAnswers(sessionID, response, request: requestID) }
        case let .reply(text): reply(sessionID, text: text)
        }
    }

    // MARK: Questions

    /// One of a prompt's questions as the card shows it: upstream's "Other" (a free-form option it adds to every
    /// Claude question) is left out, as the card's answer field is that.
    struct QuestionItem: Equatable {
        var question: String
        var header: String?
        var options: [QuestionCardModel.Option]
        var multiSelect: Bool
    }

    /// A question card's progress: the question it shows and what was picked or typed on each, for the prompt it
    /// was made on, so another prompt starts afresh (P42, P96).
    struct QuestionDraft: Equatable {
        var promptID: UUID
        var step = 0
        var picks: [Int: [Int]] = [:]
        var typed: [Int: String] = [:]
    }

    static func questionItems(_ prompt: QuestionPrompt) -> [QuestionItem] {
        guard !prompt.questions.isEmpty else {
            return [QuestionItem(question: prompt.title, header: nil, options: prompt.options.map { .init(label: $0, description: "") },
                                 multiSelect: false)]
        }
        return prompt.questions.map { item in
            let header = item.header.trimmingCharacters(in: .whitespaces)
            return QuestionItem(question: item.question, header: isFillerHeader(header) ? nil : header,
                                options: item.options.filter { !$0.allowsFreeform }.map { .init(label: $0.label, description: $0.description) },
                                multiSelect: item.multiSelect)
        }
    }

    /// A topic that says nothing: none, or the "Question" and "Question 2" OpenCode's plugin and upstream put on a
    /// question that has no header, which the card would draw as "Question · Question 2" (P153).
    static func isFillerHeader(_ header: String) -> Bool {
        header.isEmpty || header.range(of: #"^Question( \d+)?$"#, options: .regularExpression) != nil
    }

    private func questionDraft(_ sessionID: String, prompt: QuestionPrompt) -> QuestionDraft {
        guard let draft = questionDrafts[sessionID], draft.promptID == prompt.id else { return QuestionDraft(promptID: prompt.id) }
        return draft
    }

    /// Only on a question the island can answer, and only while the card's request (`request`) is the one waiting
    /// (P170).
    @discardableResult
    func answerQuestion(_ sessionID: String, _ input: QuestionInput, request requestID: String?) -> Bool {
        guard let head = engine.attentionHead(for: sessionID), head.isAnswerable, requestID == nil || head.id == requestID,
              case let .question(prompt) = head.content else { return false }
        let items = Self.questionItems(prompt)
        guard !items.isEmpty else { return false }
        var draft = questionDraft(sessionID, prompt: prompt)
        let step = min(draft.step, items.count - 1)
        let item = items[step]
        switch input {
        case let .option(index):
            guard item.options.indices.contains(index) else { return false }
            draft.typed[step] = nil
            if item.multiSelect {
                var picks = Set(draft.picks[step] ?? [])
                if picks.remove(index) == nil { picks.insert(index) }
                draft.picks[step] = picks.sorted()
                return keep(draft, for: sessionID)
            }
            draft.picks[step] = [index]
        case let .text(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            draft.typed[step] = trimmed
            draft.picks[step] = nil
        case .next:
            guard Self.answer(item, step: step, draft: draft) != nil else { return false }
        case .back:
            guard step > 0 else { return false }
            draft.step = step - 1
            return keep(draft, for: sessionID)
        }
        guard step + 1 >= items.count else {
            draft.step = step + 1
            return keep(draft, for: sessionID)
        }
        // The last question answered: every answer goes at once, as upstream's own card sends them. The progress stays
        // until they went, so a send that failed keeps the card as it was, with Retry.
        let response = Self.response(prompt, items: items, draft: draft)
        questionDrafts[sessionID] = draft
        let requestID = head.id
        Task { await sendAnswers(sessionID, response, request: requestID) }
        return true
    }

    /// Sends a question card's answers (awaited by tests) to the question they were made on (`request`, when given: never
    /// to one that took its place meanwhile, P170); a send that did not go out keeps the card, with Retry.
    func sendAnswers(_ sessionID: String, _ response: QuestionPromptResponse, request requestID: String? = nil) async {
        guard let head = engine.attentionHead(for: sessionID), requestID == nil || head.id == requestID,
              let prompt = head.questionPrompt else { return }
        let outcome = await engine.answer(requestID: head.id, response: response)
        record(sessionID, outcome, SendRecord(key: prompt.id, state: .notSent, retry: .answer(response)))
    }

    /// Keeps a question card's progress and redraws it; false: nothing was sent.
    private func keep(_ draft: QuestionDraft, for sessionID: String) -> Bool {
        questionDrafts[sessionID] = draft
        mapped = nil
        publish()
        return false
    }

    /// A question's answer: what was typed, else the picked labels in the options' order, joined by ", ".
    static func answer(_ item: QuestionItem, step: Int, draft: QuestionDraft) -> String? {
        if let typed = draft.typed[step] { return typed }
        let labels = (draft.picks[step] ?? []).sorted().compactMap { item.options.indices.contains($0) ? item.options[$0].label : nil }
        return labels.isEmpty ? nil : labels.joined(separator: ", ")
    }

    /// Upstream's shape (`IslandPanelView` `submitAnswer`): each question's answer under its text, and the answer
    /// alone as well when there is one question; a prompt with no questions gets the answer alone.
    static func response(_ prompt: QuestionPrompt, items: [QuestionItem], draft: QuestionDraft) -> QuestionPromptResponse {
        let answers = items.indices.map { answer(items[$0], step: $0, draft: draft) }
        guard !prompt.questions.isEmpty else { return QuestionPromptResponse(answer: answers.first.flatMap { $0 } ?? "") }
        var map: [String: String] = [:]
        for (item, answer) in zip(items, answers) { if let answer { map[item.question] = answer } }
        return QuestionPromptResponse(rawAnswer: items.count == 1 ? answers[0] : nil, answers: map)
    }

    func reply(_ sessionID: String, text: String) {
        Task { await sendReply(sessionID, text) }
    }

    /// A Done card's reply (awaited by tests): "Sending…", then "Sent" or "Not sent · Retry" on the card until the
    /// session moves on.
    func sendReply(_ sessionID: String, _ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, sends[sessionID]?.state != .sending else { return }
        // The agent left its prompt since the card was drawn (stopped, quit, P139): the card is drawn again, without
        // its field.
        guard engine.canReply(sessionID: sessionID) else { return store(nil, for: sessionID) }
        store(SendRecord(state: .sending, retry: .reply(trimmed)), for: sessionID)
        let outcome = await engine.reply(sessionID: sessionID, text: trimmed)
        // The session moved on meanwhile (a new turn): its card went, and the note with it.
        guard sends[sessionID] != nil else { return }
        switch outcome {
        case .sent: store(SendRecord(state: .sent, retry: .reply(trimmed)), for: sessionID)
        case .notSent: store(SendRecord(state: .notSent, retry: .reply(trimmed)), for: sessionID)
        case .nothingToSend: store(nil, for: sessionID)
        }
    }

    func jump(_ sessionID: String) { startJump(sessionID) }

    /// A row click, answered at once on the main thread. Live hands the jump to the engine, whose runner works on
    /// its own thread, and notes the outcome when it arrives; the returned task ends then (tests await it).
    @discardableResult
    func startJump(_ sessionID: String) -> Task<Void, Never>? {
        switch jumps {
        case .demo:
            noteRequested(sessionID)
            show(JumpNote(sessionID: sessionID, text: JumpNote.demo))
            return nil
        case .live:
            guard jumpsInFlight.insert(sessionID).inserted else { return nil }
            noteRequested(sessionID)
            let engine = engine
            return Task { @MainActor [weak self] in
                let outcome = await engine.jump(sessionID: sessionID)
                self?.jumpsInFlight.remove(sessionID)
                self?.note(outcome)
            }
        }
    }

    private func noteRequested(_ sessionID: String) {
        requestedJumps.append(sessionID)
        let extra = requestedJumps.count - Self.requestedJumpLimit
        if extra > 0 { requestedJumps.removeFirst(extra) }
    }

    private func note(_ outcome: JumpOutcome) {
        if let text = JumpNote.text(for: outcome) {
            show(JumpNote(sessionID: outcome.sessionID, text: text))
        } else if jumpNote?.sessionID == outcome.sessionID {
            jumpNote = nil
        }
    }

    private func show(_ note: JumpNote) {
        jumpNote = note
        let id = note.id, lifetime = noteLifetime
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: lifetime)
            if self?.jumpNote?.id == id { self?.jumpNote = nil }
        }
    }

    func jumpToNextNeedsYou() {
        guard let first = needsYou.first else { return }
        jump(first.id)
    }

    /// Open on a read-only card: the engine's jump for the request the card showed. Once that request is gone (closed
    /// by its own evidence on the way), a plain jump to the session, which closes nothing: never the request that took
    /// its place, unseen (P174).
    func openRequest(_ sessionID: String, request requestID: String?) {
        guard case .live = jumps, let shown = requestShown(sessionID, requestID) else { return jump(sessionID) }
        guard jumpsInFlight.insert(sessionID).inserted else { return }
        noteRequested(sessionID)
        let engine = engine
        Task { @MainActor [weak self] in
            let outcome = await engine.openRequest(requestID: shown.id)
            self?.jumpsInFlight.remove(sessionID)
            if let outcome { self?.note(outcome) }
        }
    }

    /// ✕ on a read-only card: only the notice the card showed goes (never a request the island holds for the agent's
    /// answer, a subagent's held for the island included, whose card draws No and Yes and no ✕, P350; nor one that took
    /// its place in the session's queue, P174). A ✕ after a subagent's hold ended is kept for Claude's notice that
    /// follows it (P352).
    func dismissRequest(_ sessionID: String, request requestID: String?) {
        guard let shown = requestShown(sessionID, requestID), shown.channel == .open else { return }
        engine.dismissRequest(requestID: shown.id)
    }

    func islandShows(requestID: String?) { engine.islandShows(requestID: requestID) }
    func windowShows(requestIDs: Set<String>) { engine.windowShows(requestIDs: requestIDs) }

    /// The session's open request a card's button acts on: the one the card showed (`requestID`) while it is still
    /// open; with no id, the session's head.
    func requestShown(_ sessionID: String, _ requestID: String?) -> AttentionRequest? {
        guard let requestID else { return engine.attentionHead(for: sessionID) }
        return engine.openRequests.first { $0.id == requestID && $0.sessionID == sessionID }
    }

    /// Archive, for a finished session only: one that waits on an approval or a question is never hidden, as its agent
    /// would go on waiting with no card anywhere (P131).
    func dismiss(_ sessionID: String) {
        guard engine.attentionHead(for: sessionID) == nil,
              engine.state.session(id: sessionID)?.phase.requiresAttention != true else { return }
        engine.dismiss(sessionID: sessionID)
    }

    // MARK: Mapping

    /// A row from the engine's book (P161): "!" and "?" only for the session's oldest confirmed request, "×" for a turn
    /// that failed, never from the session's phase alone (a restored phase, a pending or released request).
    private func row(for session: AgentSession) -> SessionRow {
        let head = engine.attentionHead(for: session.id)
        let word = engine.statusWord(for: session)
        // A failed turn (StopFailure) needs you like a waiting session (spec §3.4).
        let failed = word == .failed
        let status = Self.status(word, head: head)
        // A main agent that waits on its subagents is at work, not done (P370).
        let delegating = head == nil && Self.isDelegating(word)
        let bucket: SessionBucket = engine.needsAttention(session) ? .needsYou
            : session.phase == .completed && !delegating ? .done : .running
        let limit = head == nil ? rowLimit(session) : nil
        // A usage limit whose reset passed waits at its prompt as an interrupted turn does: the idle check (P702).
        let (glyph, glyphState) = Self.glyph(head: head?.kind, failed: failed, phase: session.phase,
                                             interrupted: word == .interrupted || limit?.passed == true, delegating: delegating)
        let detail: String?
        if let head {
            detail = switch head.content {
            case .notice: nil
            case let .question(prompt): Self.nonEmpty(prompt.questions.first?.question ?? prompt.title)
            case let .approval(request):
                Self.isPlan(request) ? Self.plan(engine.toolCallInput(for: session.id)) : approvalContent(session, request: request).rowText
            }
        } else if session.phase == .completed, !delegating {
            // A limit's line says it all (P700); the CLI's own message for it is no reply.
            detail = limit != nil ? nil : failed ? Self.failureText(session) : Self.lastMessage(session).flatMap(Self.rowText)
        } else {
            detail = nil
        }
        let workingDirectory = session.jumpTarget?.workingDirectory
        let project = session.jumpTarget?.workspaceName
            ?? workingDirectory.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        // A remote session's folder is the host's: no folder menu or branch is read from this Mac, and its host tag is the
        // SSH host it came from (P745).
        let remote = engine.remoteHost(for: session.id)
        let localFolder = remote == nil ? workingDirectory : nil
        let title = Self.title(engine.chatTitle(for: session), project: project, agent: agent(session))
        // The flag alone misses a thread the app's hooks made (P665).
        let isCodexApp = engine.isCodexAppThread(session)
        return SessionRow(
            id: session.id, agent: agent(session), bucket: bucket, project: project,
            folder: localFolder.flatMap { $0.isEmpty ? nil : $0 }, task: title.text,
            status: status, detail: detail, lastPrompt: Self.lastPrompt(session),
            host: remote?.hostName ?? (isCodexApp ? "Codex.app" : Self.host(session.jumpTarget?.terminalApp, agent: agent(session))),
            accountAlias: engine.accountTag(for: session.id).map { tag in tag.accountID.flatMap(aliasForAccountID) ?? tag.alias },
            updatedAt: session.updatedAt, isCodexApp: isCodexApp, glyph: glyph, glyphState: glyphState,
            hasCard: head != nil, activeSince: engine.activeSince(for: session), asker: head.flatMap(Self.asker),
            waitingRequests: head == nil ? 0 : engine.attentionQueue(for: session.id).count, titleSource: title.source,
            isQuiet: engine.scope(of: session) != .owner, facts: RowFacts(engine.facts(for: session)),
            isStalled: isStalled(session, head: head), compactingSince: engine.compactingSince(for: session),
            branch: remote != nil ? nil : branches.branch(folder: workingDirectory, session: session.id, moment: bucket == .done ? .done : .working,
                                                          metadata: session.claudeMetadata?.worktreeBranch),
            firstPrompt: engine.firstPrompt(for: session), remoteHost: remote?.hostName, limit: limit,
            // An SSH session's folders are the host's: never one of this Mac's accounts (P816).
            account: remote != nil ? nil : engine.accountTag(for: session.id).map { RowAccount(provider: $0.provider, folder: $0.folder, accountID: $0.accountID) },
            waitsOnIsland: head?.waitsOnIslandAlone == true, canFold: engine.canFold(sessionID: session.id),
            isFolded: engine.isFolded(session.id), appOffer: engine.appHandoff?.offer(for: session.id)?.title)
    }

    // MARK: Folded sessions (P1300 to P1324)

    /// A folded session's card, from the engine's fold: its row (the listed one, or one made for a session that ended
    /// and is listed nowhere, from the fold's own copy once upstream's monitor dropped it, P1355), its last answer (kept
    /// while a new turn runs, as upstream's metadata drops it at the next prompt), where a reply goes and where the last
    /// one stands.
    private func foldedCard(_ fold: FoldedSession, listed: SessionRow?) -> FoldedCardModel? {
        guard let session = engine.state.session(id: fold.sessionID) ?? fold.session else { return nil }
        let row = listed ?? row(for: session)
        let resume = engine.conversationResume
        let running = resume?.isRunning(fold.sessionID) == true
        let reported = Self.lastMessage(session) ?? foldMessages[fold.sessionID]
        foldMessages[fold.sessionID] = reported
        var message = reported
        if running {
            if foldRunLive.insert(fold.sessionID).inserted { foldRunBase[fold.sessionID] = reported ?? "" }
        } else {
            foldRunLive.remove(fold.sessionID)
            // The run ended and its hooks reported nothing new: its own final text.
            if let base = foldRunBase[fold.sessionID], (reported ?? "") == base, let answer = resume?.answer(fold.sessionID) {
                message = answer
            }
        }
        let reach = engine.foldReach(fold.sessionID)
        let working = engine.foldTurnRuns(fold.sessionID)
        // Codex's background service's note waits for its turn's end: until then the card reads Working (P1487).
        let resumeNote: String? = switch reach {
        case let .resume(note): note
        case let .daemon(note): working ? nil : note
        default: nil
        }
        // Why the last resumed reply did not go or its run failed, said only where a reply goes on through the resume
        // and only once this fold tried one (a fold of later has nothing to do with it). A background session's: why a
        // reply through its attach, or its Stop, did not go (P1460, P1463).
        // Codex's background service still runs the turn Continue or a reply met (P1488): said as that, never as a failure.
        let saysFinishing = resume?.problem(fold.sessionID) == SessionResumer.finishingWords
        let problem: String? = switch reach {
        case .resume, .daemon: (fold.resumed || fold.send == .notSent) && !saysFinishing ? resume?.problem(fold.sessionID) : nil
        case .background: engine.claudeBackground?.problem(fold.sessionID)
        case .tab, .openOnly: nil
        }
        let send: CardSend? = switch fold.send {
        case .sending: .sending
        case .sent: .sent
        case .notSent: .notSent
        case nil: nil
        }
        let route: FoldedCardModel.Reach = switch reach {
        case .tab: .tab
        case .resume: .resume
        case .daemon: .daemon
        case .openOnly: .openOnly
        case .background: .background
        }
        let background = fold.background.flatMap { Self.backgroundModel($0, working: working) }
        // Continue only on a stopped session its resume can carry on, with nothing on its way or held (P1419).
        let offersContinue = fold.stopped != nil && (route == .resume || route == .daemon) && !working && fold.send != .sending
            && fold.held == nil
        // Continue or a reply met a turn Codex's background service goes on with; otherwise the card reads Working (P1488).
        let finishing = saysFinishing && route != .tab && !running && resume?.serviceTurnRuns(fold.sessionID) == true
        return FoldedCardModel(
            sessionID: fold.sessionID, row: row, message: message, working: working,
            reach: route,
            note: fold.notOpened ? "Not opened" : resumeNote, problem: problem, held: fold.held, send: send,
            // A background copy's Stop, but never while an app holds or takes the conversation (P1535).
            stoppable: running || background?.stage == .moved && engine.appHandoff?.app(holding: fold.sessionID) == nil, returned: fold.returned?.text, unsent: fold.returned.map { Self.unsentWords($0.why, reach: route) },
            stopped: fold.stopped?.words, continuePrompt: offersContinue ? SessionEngine.continuePrompt : nil,
            // The window still holds the run while it sits in the Dock (P1417).
            inTerminal: fold.tucked && route == .tab && working && !running ? fold.host : nil,
            background: background, finishing: finishing,
            app: engine.appHandoff.flatMap { FoldedAppModel.make(state: $0.state(for: fold.sessionID), offer: $0.offer(for: fold.sessionID)) })
    }

    /// A background fold as its card's line says it (P1450 on). A move that did not happen but left its tab sure (not
    /// typed, or its tab in front) is said until a turn runs in that tab again; then the card is a tab's card.
    static func backgroundModel(_ background: FoldBackground, working: Bool = false) -> FoldedBackgroundModel? {
        let stage: FoldedBackgroundModel.Stage
        switch background.stage {
        case .waitsForTurnEnd: stage = .waits
        case .moving: stage = .moving
        // A reply woke a stopped one once a turn runs there again.
        case .moved: stage = !working && (background.stoppedByOwner || background.listed?.hasEnded == true) ? .stopped : .moved
        case let .notMoved(miss):
            if working, !background.leftItUnsure { return nil }
            // It may run in the background under an id the list could not tell: no "Not moved" then (P1457).
            stage = .notMoved(miss == .cannotTell ? "Not sure it moved to the background" : "Not moved · " + miss.rawValue)
        }
        return FoldedBackgroundModel(stage: stage, attachedIn: stage == .moved ? background.attachedIn : nil)
    }

    /// Why a held reply went back to the field (P1356, P1359), as the card's line says it.
    static func unsentWords(_ why: ReturnedReply.Why, reach: FoldedCardModel.Reach) -> String {
        switch why {
        case .tabInFront: "Not sent · its tab was in front"
        case .windowInFront: "Not sent · its window was in front"
        case .wayChanged:
            switch reach {
            case .tab: "Not sent · its tab is back"
            case .resume: "Not sent · its tab closed"
            case .daemon, .openOnly: "Not sent"
            case .background: "Not sent · it moved to the background"
            }
        }
    }

    func sendToIsland(_ sessionID: String) async -> TuckBounds? {
        guard case let .folded(bounds) = await engine.fold(sessionID: sessionID) else { return nil }
        return bounds
    }

    func frontmostFoldable() async -> String? { await engine.frontmostFoldable() }

    func replyFolded(_ sessionID: String, text: String) {
        Task { await engine.replyFolded(sessionID: sessionID, text: text) }
    }

    func cancelHeld(_ sessionID: String) { engine.cancelHeldReply(sessionID: sessionID) }

    func retryFolded(_ sessionID: String) {
        Task { await engine.retryFolded(sessionID: sessionID) }
    }

    func stopFolded(_ sessionID: String) { engine.stopFolded(sessionID: sessionID) }

    func continueFolded(_ sessionID: String) {
        Task { await engine.continueFolded(sessionID: sessionID) }
    }

    /// Open in terminal: live, the window back and the exact jump (or the conversation reopened); the demo unfolds and
    /// notes "Demo session", as its jumps do.
    func openFolded(_ sessionID: String) {
        guard case .live = jumps else {
            engine.unfold(sessionID: sessionID)
            return show(JumpNote(sessionID: sessionID, text: JumpNote.demo))
        }
        guard jumpsInFlight.insert(sessionID).inserted else { return }
        noteRequested(sessionID)
        let engine = engine
        Task { @MainActor [weak self] in
            let outcome = await engine.openFolded(sessionID: sessionID)
            self?.jumpsInFlight.remove(sessionID)
            if let outcome { self?.note(outcome) }
        }
    }

    /// Open in <App> (P1510): live, the hand-over runs off the main thread's waits; a row's outcome that needs saying
    /// ("Update Claude Code to open this in Claude", "Pick this session in VS Code") is a note under the row, and a folded
    /// card says it on its line. The demo only notes "Demo session".
    func openInApp(_ sessionID: String) {
        guard case .live = jumps else { return show(JumpNote(sessionID: sessionID, text: JumpNote.demo)) }
        guard let handoff = engine.appHandoff else { return }
        let folded = engine.isFolded(sessionID)
        Task { @MainActor [weak self] in
            await handoff.open(sessionID)
            // A folded card keeps what it came to on its line; a row says it once, under itself.
            guard !folded, let state = handoff.state(for: sessionID) else { return }
            switch state {
            case let .blocked(_, why): self?.show(JumpNote(sessionID: sessionID, text: why))
            case let .pick(app): self?.show(JumpNote(sessionID: sessionID, text: HandoffWords.pick(app)))
            case .inApp, .opening, .pending: break
            }
            if case .opening = state { return }
            handoff.forget(sessionID)
        }
    }

    func cancelPendingApp(_ sessionID: String) { engine.appHandoff?.cancelPending(sessionID) }

    func unfold(_ sessionID: String) {
        engine.unfold(sessionID: sessionID)
        foldMessages[sessionID] = nil
        foldRunBase[sessionID] = nil
        foldRunLive.remove(sessionID)
    }

    /// The limit or API error the session's last turn stopped on, worded at this mapping's time (P700), with its account
    /// for the best other one (P704).
    private func rowLimit(_ session: AgentSession) -> RowLimit? {
        guard let limit = engine.limit(for: session) else { return nil }
        let tag = engine.accountTag(for: session.id)
        return RowLimit(limit, provider: tag?.provider, folder: tag?.folder, accountID: tag?.accountID, now: clock())
    }

    /// "Open in <account>" (P703): live, the engine opens the window off the main thread, and a window that did not
    /// open leaves a note under the row; the demo only notes "Demo session".
    func openFresh(_ sessionID: String, in alternative: LimitAlternative) {
        guard case .live = jumps else { return show(JumpNote(sessionID: sessionID, text: JumpNote.demo)) }
        guard jumpsInFlight.insert(sessionID).inserted else { return }
        let engine = engine
        let host = engine.freshLaunch(sessionID: sessionID, provider: alternative.provider, profileFolder: alternative.folder)?.host
        Task { @MainActor [weak self] in
            let opened = await engine.openFresh(sessionID: sessionID, provider: alternative.provider, profileFolder: alternative.folder)
            self?.jumpsInFlight.remove(sessionID)
            if !opened { self?.show(JumpNote(sessionID: sessionID, text: "Could not open \(host?.name ?? "a terminal")")) }
        }
    }

    /// Running, nothing it asks waiting (a phase no request stands behind reads as running too, P161), and no sign of
    /// life for Stalled after (P312) of the Mac's awake time: an agent is suspended with a Mac that sleeps, so a wake is
    /// never a stall. A Codex chat whose subagents run is not stalled: its activity is theirs, in their own rollouts. A
    /// session with a tool call still in flight (a long build says nothing until it ends) is at work: it keeps "Running
    /// Bash · 15m" and stalls only past `inFlightStall` (P440). Read at every mapping, which the minute clock repeats, so a
    /// stall shows within a minute with no timer of its own.
    private func isStalled(_ session: AgentSession, head: AttentionRequest?) -> Bool {
        guard head == nil, session.phase == .running, let limit = stalledAfter() else { return false }
        // Its own command beside them (P378) included.
        if engine.isDelegating(session) || (session.tool == .codex && engine.runningSubagents(for: session.id) > 0) { return false }
        let needed = engine.toolInFlightSince(for: session) == nil ? limit : max(limit, Self.inFlightStall)
        return sleeps.awake(since: engine.lastActivity(for: session), until: clock()) >= needed
    }

    /// How long a session with a tool call in flight may say nothing before it reads as Stalled (P440): a tuning
    /// constant; an hour covers a long build or test run, and a call past it is more likely hung than working.
    static let inFlightStall: TimeInterval = 60 * 60

    // MARK: Peek

    /// A row's peek (P311): the session's metadata, with a Claude session's transcript tail read off the main thread for
    /// a turn still running (its metadata has only the turn before's reply). Read at the moment it shows, never kept.
    func peek(_ sessionID: String, clean: Bool) async -> SessionPeek? {
        guard engine.state.session(id: sessionID) != nil else { return nil }
        let read = await engine.readPeek(sessionID: sessionID)
        // The row as it is now, after the read (which may have named the session's model).
        guard let session = engine.state.session(id: sessionID), let row = rows.first(where: { $0.id == sessionID }) else { return nil }
        let replyIsCurrent = session.phase == .completed || session.tool == .codex
        return SessionPeek.make(row: row, clean: clean, prompt: Self.lastPrompt(session), reply: Self.lastMessage(session),
                                replyIsCurrent: replyIsCurrent, read: read, work: engine.work(for: sessionID))
    }

    /// The engine's work for the session (`SessionEngine.work(for:)`, P720, P721): read where a peek shows, which follows it.
    func work(_ sessionID: String) -> SessionWork? { engine.work(for: sessionID) }

    /// The row's title: the chat's (`SessionEngine.chatTitle`), else the repo, else, with neither, the agent's name.
    static func title(_ chat: ChatTitle?, project: String, agent: GlyphPalette.Agent) -> (text: String, source: TitleSource) {
        if let chat { return (chat.text, chat.source == .agent ? .agent : .prompt) }
        return (project.isEmpty ? agent.displayName : project, .repo)
    }

    /// The row's glyph: the oldest confirmed request's "!" (an approval or a plan) or "?" (a question or a form); else
    /// "×" for a failed turn, in the waiting tone; else a main agent waiting on its subagents in the delegate teal
    /// (P370); else the phase's own, where a waiting phase with no request behind it reads as running (P161).
    static func glyph(head: AttentionRequest.Kind?, failed: Bool, phase: SessionPhase, interrupted: Bool,
                      delegating: Bool = false) -> (PixelGlyph, GlyphPalette.State) {
        if let head { return head.isQuestion ? (.ques, .waiting) : (.bang, .waiting) }
        if failed { return (.cross, .waiting) }
        if delegating { return (.agents, .delegating) }
        return phase == .completed ? (.check, interrupted ? .idle : .done) : (.eq, .running)
    }

    /// The main agent waits on its subagents: a Claude session whose main turn ended while they run, a Codex chat whose
    /// turn waits on them (`SessionEngine.isDelegating`).
    static func isDelegating(_ word: StatusWord) -> Bool {
        if case .subagents = word { return true }
        return false
    }

    /// The row's word from the book: the request's kind while one is confirmed; a waiting word with none (a phase no
    /// request stands behind) reads as working.
    static func status(_ word: StatusWord, head: AttentionRequest?) -> StatusWord {
        if let head {
            if head.kind.isQuestion { return .question }
            return .needsApproval(tool: head.content == .notice ? nil : head.toolName ?? head.permissionRequest?.toolName)
        }
        switch word {
        case .needsApproval, .question: return .working
        default: return word
        }
    }

    /// A subagent's name before the tool ("worker"), when the request is a subagent's.
    static func asker(_ request: AttentionRequest) -> String? {
        guard request.agentID != nil else { return nil }
        return nonEmpty(request.agentType?.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "subagent"
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// The session's own agent, with the label the engine took from its hooks (Copilot, Devin, Kilo, an agent behind
    /// Claude's hooks, P913).
    func agent(_ session: AgentSession) -> GlyphPalette.Agent { Self.agent(engine.agent(of: session)) }

    /// An agent kind as the rows draw it: Claude's and Codex's own marks, an agent upstream has a tool for as that tool,
    /// and the rest as themselves.
    static func agent(_ kind: AgentKind) -> GlyphPalette.Agent {
        switch kind {
        case .claude: .claude
        case .codex: .codex
        default: AgentKind(tool: kind.carrierTool) == kind ? .other(kind.carrierTool) : .kind(kind)
        }
    }

    /// The session's own agent: a Claude Code fork (Kimi, Qwen, Factory, …) or any other agent the engine knows is
    /// itself, never Claude (P151).
    static func agent(_ session: AgentSession) -> GlyphPalette.Agent {
        switch session.tool {
        case .claudeCode: .claude
        case .codex: .codex
        default: .other(session.tool)
        }
    }

    /// The terminal a row names; nil for upstream's "Unknown" (a hook that could not tell, as OpenCode's plugin
    /// outside a known terminal), which would be a tag that says nothing, and for a host that is the agent itself
    /// (Cursor's hooks run in Cursor), which its mark already says.
    static func host(_ terminalApp: String?, agent: GlyphPalette.Agent) -> String? {
        guard let app = terminalApp?.trimmingCharacters(in: .whitespaces), !app.isEmpty, app != "Unknown",
              app.caseInsensitiveCompare(agent.displayName) != .orderedSame else { return nil }
        return app
    }

    static func isPlan(_ request: PermissionRequest) -> Bool {
        request.toolName == "ExitPlanMode" || request.title == "ExitPlanMode"
    }

    /// ExitPlanMode's `input.plan`, as the transcript has it; nil until it is read (never upstream's sentence).
    static func plan(_ input: ClaudeHookJSONValue?) -> String? {
        guard case let .object(fields)? = input, case let .string(plan)? = fields["plan"] else { return nil }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The turn's last message, from the session's own metadata block: Claude's (and its forks'), Codex's (a review's
    /// answer as its explanation, never its JSON, P217), Gemini's reply (`GeminiReply`, never upstream's cubic
    /// `completionAssistantMessageText`, P152), OpenCode's, Cursor's or Pi's; Grok's hooks keep none, so its finished
    /// turn's summary (`grokMessage`).
    static func lastMessage(_ session: AgentSession) -> String? {
        let codex = session.codexMetadata?.lastAssistantMessage.map { PromptText.reviewExplanation($0) ?? $0 }
        return firstText([session.claudeMetadata?.lastAssistantMessage, codex,
                   session.geminiMetadata.flatMap(GeminiReply.text), session.openCodeMetadata?.lastAssistantMessage,
                   session.cursorMetadata?.lastAssistantMessage, session.piMetadata?.lastAssistantMessage, grokMessage(session)])
    }

    /// A finished Grok turn's message: its Stop's summary, which is the message (upstream's 110-character preview of
    /// it), unless it is one of upstream's sentences for a turn that left none or for another event ("Grok completed a
    /// turn in Desktop.", "Grok turn interrupted in Desktop.", "Started Grok session in Desktop.", a notification's
    /// "Grok is idle in Desktop."), which no row shows (P151). A message of Grok's own that begins "Grok " goes with
    /// them; its card still shows the summary.
    static func grokMessage(_ session: AgentSession) -> String? {
        guard session.tool == .grokBuild, session.phase == .completed else { return nil }
        let summary = session.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = ["Grok ", "Started Grok session in ", "Resumed Grok session in ", "Prompt: "]
        guard !summary.isEmpty, !sentences.contains(where: summary.hasPrefix) else { return nil }
        return summary
    }

    /// A last message on a row's one line: its Markdown and directives as plain text (`MessageMarkup.plain`); nil
    /// when nothing of it reads as text, or when it is JSON (a reviewer's verdict, P212): the row then says Done. The
    /// Done card draws the message itself.
    static func rowText(_ message: String) -> String? {
        guard !PromptText.isJSON(message) else { return nil }
        let text = MessageMarkup.plain(message)
        return text.isEmpty ? nil : text
    }

    /// What the bridge kept of a StopFailure (the hook's error, or else its message text), in plain words (P132).
    static func failureText(_ session: AgentSession) -> String? {
        let text = TurnFailure.words(session.summary)
        return text.isEmpty ? nil : text
    }

    /// The owner's last prompt, from the session's own metadata block, as `lastMessage`; machine text (a restored
    /// record written before P155, another agent's metadata) is never shown as one.
    static func lastPrompt(_ session: AgentSession) -> String? {
        [session.claudeMetadata?.lastUserPrompt, session.codexMetadata?.lastUserPrompt,
         session.geminiMetadata?.lastUserPrompt, session.openCodeMetadata?.lastUserPrompt,
         session.cursorMetadata?.lastUserPrompt, session.piMetadata?.lastUserPrompt].lazy.compactMap { PromptText.human($0) }.first
            .flatMap { PromptText.isJSON($0) ? nil : oneLine($0) }
    }

    /// A prompt on a row's one line: its lines joined by spaces, so a prompt that starts with a blank or short line
    /// still says what it asks.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The first of `texts` with something in it besides blanks.
    static func firstText(_ texts: [String?]) -> String? {
        texts.lazy.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    nonisolated static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

private extension SessionRow {
    /// The row as the lists compare it: `updatedAt` to its minute (`EngineSessionsModel.Mapped`).
    var drawnAge: SessionRow {
        var row = self
        row.updatedAt = Date(timeIntervalSinceReferenceDate: TimeInterval(EngineSessionsModel.minute(of: updatedAt)) * 60)
        return row
    }
}

/// The spans a Mac slept, found by comparing the wall clock with its awake time (`ProcessInfo.systemUptime`, which
/// stands still in sleep) at each look: the wall clock running ahead of the awake time by more than `tolerance` is a
/// sleep (or the clock set ahead: neither is a session's silence). Kept for `keep`, far past any Stalled after. Pure, so
/// tests give it both clocks.
struct SleepLog: Sendable {
    static let tolerance: TimeInterval = 2
    static let keep: TimeInterval = 24 * 60 * 60

    private var last: (wall: Date, awake: TimeInterval)?
    private(set) var spans: [DateInterval] = []

    mutating func note(wall: Date, awake: TimeInterval) {
        if let last {
            let gap = wall.timeIntervalSince(last.wall) - (awake - last.awake)
            if gap > Self.tolerance {
                let start = max(last.wall, wall.addingTimeInterval(-gap))
                spans.append(DateInterval(start: start, end: wall))
            }
        }
        last = (wall, awake)
        spans.removeAll { $0.end < wall.addingTimeInterval(-Self.keep) }
    }

    /// The awake time from `since` to `until`: the clock's time less the sleeps in it.
    func awake(since: Date, until: Date) -> TimeInterval {
        let elapsed = until.timeIntervalSince(since)
        guard elapsed > 0 else { return elapsed }
        let window = DateInterval(start: since, end: until)
        let slept = spans.reduce(0) { total, span in total + (span.intersection(with: window)?.duration ?? 0) }
        return elapsed - slept
    }
}
