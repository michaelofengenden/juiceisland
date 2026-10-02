import CoreGraphics
import Foundation

/// When the island opens and closes (P35), as a pure value: the panel feeds it pointer and command events and carries
/// out the effects; tests drive it with plain sequences. Inside and outside are judged against the surface's target
/// shape, never the panel.
/// - A rest opens it: Hover's `openDelay` after the last pointer sample faster than `restSpeed`, so a sweep across the
///   menu bar never opens it. The first slow sample (no faster than `swellSpeed`) swells the pill, a nod that it noticed.
/// - Leaving within `abortWindow` of the open folds it straight back (a flick); leaving while it still opens turns the
///   content that has not landed back and closes after `openingGrace`; once landed (`landedAfter`), leaving closes it
///   after `closeGrace`, and the pointer may stray `band` outside the island meanwhile. Coming back inside a grace keeps
///   it (a retreat resumes).
/// - Coming back within `reverseWindow` of a pointer close reverses the fold in place; after that, a fresh rest.
/// - After a close the pointer did not cause (Esc, a key, a jump, an answer), the pointer must leave and come back
///   before hovering opens it again.
/// - A click opens it at once; so does something that needs you (a card), which also takes over an island that is open
///   or still in its leave grace, and then holds it instead of the pointer: when its card goes with the pointer away
///   (`closesWithItsCard`), the island closes (P97).
/// - An island that something needing you opened by itself folds back into the pill after `attentionIdle` with no
///   pointer on it (P292): the owner stayed in the app in front, which no notice reports (P270). Never under the
///   pointer, never with a field's draft or the keys (`drafting`: the time starts again), never while its card takes an
///   answer here (`answerable`: an approval, a plan or a question the island holds keeps its Allow in sight; the time
///   starts again), never with Keep open, never once the owner asked for it (`ownerAsked`, a widget's tap); what waits
///   stays on the pill and a new request opens it again. A card that stops taking an answer while it shows (a subagent's
///   hold ran out, `answerEnded`, P350) folds at once when its time is up.
/// - A finished session's Done card (Card) is brief (P95): it closes by itself `doneCardLife` after it shows, with the
///   normal fold. The pointer on the island holds it (a leave closes it after the normal grace, as any hover; the island
///   moving off a still pointer starts its time again); a newer finish starts the time again (one timer, never two);
///   something that needs you takes over and never closes by itself.
/// - Keep open until approve or deny (`holdOpen`): leaving does not close it.
/// - The surface resizing under a still pointer (`pointerRelocated`) never opens or closes it.
/// - The owner going elsewhere (`focusLeft`: another app became active, or a click outside took the panel's keys, P270)
///   folds it back into the pill with the normal fold, whatever holds it (a card that needs you, Keep open, a Done
///   card under a still pointer), unless the pointer is on the island, having moved there; then its next leave closes
///   it, Keep open or not. Not a pointer close: no reverse, and a pointer still inside must leave before a rest opens
///   it again.
/// Session changes never feed the machine, so an empty list cannot make it flicker.
struct IslandHoverMachine: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case closed, opening, open, closing }
    enum OpenReason: Equatable, Sendable { case hover, click, attention }
    /// How a close moves: the normal fold, the flick's straight return, or a close the pointer did not cause.
    enum CloseStyle: Equatable, Sendable { case fold, abort, dismiss }

    enum Event: Equatable, Sendable {
        case pointerEntered(at: TimeInterval)
        /// A real pointer sample inside the target shape, at its speed (points a second).
        case pointerMoved(speed: CGFloat, at: TimeInterval)
        case pointerExited(at: TimeInterval)
        /// The target shape moved under a still pointer: now it is (or is not) inside.
        case pointerRelocated(inside: Bool)
        /// A timer the machine asked for; stale generations are ignored.
        case timerFired(generation: Int, at: TimeInterval)
        case clicked(at: TimeInterval)
        /// Something needs you: a question, an approval, a plan (or a failed turn).
        case attention(at: TimeInterval)
        /// A session finished with "Card": its Done card shows, and closes by itself.
        case finished(at: TimeInterval)
        /// A close the pointer did not cause: Esc, a key, a jump, an answer.
        case dismissed
        /// The owner went elsewhere: another app became active, or a click outside the island took the panel's keys
        /// (`IslandFocus`, P270). `pointerHolds`: the pointer is on the island and moved there, never a still pointer
        /// the island opened under (`PointerEngagement`).
        case focusLeft(pointerHolds: Bool, at: TimeInterval)
        /// The card on show stopped taking an answer here: a subagent's hold ran out, its Yes gone (P350). An island that
        /// opened by itself and was kept past its idle time only for that Yes folds now, as the idle fold would have.
        case answerEnded(at: TimeInterval)
    }

    enum Effect: Equatable, Sendable {
        case open(OpenReason)
        case close(CloseStyle)
        /// The pointer left while it was opening: what has not landed turns back.
        case retreat
        /// It came back within that grace.
        case resume
        case swell(Bool)
        case schedule(after: TimeInterval, generation: Int)
    }

    /// The rest that opens it (Hover: Calm; `MotionTuning.openDelay`).
    static let openDelay: TimeInterval = 0.15
    /// A sample faster than this restarts the rest (points a second, the mean over the last 40 ms).
    static let restSpeed: CGFloat = 120
    /// A sample no faster than this swells the pill; a sweep faster than it never does.
    static let swellSpeed: CGFloat = 800
    /// Once landed, how long the pointer may be away before it closes.
    static let closeGrace: TimeInterval = 0.15
    /// How far outside the landed island the pointer still counts as inside.
    static let band: CGFloat = 8
    /// While still opening, how long the pointer may be away before it closes.
    static let openingGrace: TimeInterval = 0.04
    /// Leaving this soon after the open folds it straight back.
    static let abortWindow: TimeInterval = 0.12
    /// Its content is sharp by now: the band and the long grace apply.
    static let landedAfter: TimeInterval = 0.35
    /// Coming back this soon after a pointer close reverses the fold.
    static let reverseWindow: TimeInterval = 0.40
    /// How long a finished session's Done card shows before it folds back into the pill, the pointer away.
    static let doneCardLife: TimeInterval = 3
    /// How long an island that opened by itself for something that needs you waits, with no pointer on it and nothing
    /// being typed, before it folds back into the pill (P292). The tuning constant.
    static let attentionIdle: TimeInterval = 6

    private(set) var phase: Phase = .closed
    private(set) var pointerInside = false
    private(set) var mustLeaveBeforeReopen = false
    private(set) var openReason: OpenReason?
    private(set) var generation = 0
    private(set) var openedAt: TimeInterval?
    /// When the last pointer-caused close began (nil after any other close).
    private(set) var foldStartedAt: TimeInterval?
    private(set) var swollen = false
    private(set) var retreated = false
    /// The open island shows a finished session's Done card, which closes by itself.
    private(set) var brief = false
    /// The owner went elsewhere while the pointer held the island (`focusLeft`): the pointer's next leave closes it,
    /// Keep open or not, and so does the island moving off the still pointer.
    private(set) var focusAway = false
    var holdOpen = false
    /// A field of the card holds a draft, or the island has the keys: the owner is typing, so an idle fold waits (P292).
    var drafting = false
    /// The card on show takes an answer on the island (its buttons work: an approval, a plan or a question the island
    /// holds): an idle fold would hide its Allow, so it waits, and the next look folds it once the card is read-only
    /// (P292).
    var answerable = false
    /// Settings › Island › Hover: the rest that opens it.
    var tuning = MotionTuning()

    var isOpen: Bool { phase == .open || phase == .closing }

    /// Open with the pointer away: only its card holds it (one that arrived, or Keep open until approve or deny), and no
    /// leave or timer is coming, so when that card goes (answered elsewhere, a new prompt) the island closes (P97).
    var closesWithItsCard: Bool { phase == .open && !pointerInside }

    /// Open, and its content sharp: the hover band applies.
    func landed(at t: TimeInterval) -> Bool {
        phase == .open && openedAt.map { t - $0 >= Self.landedAfter } == true
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case let .pointerEntered(t):
            pointerInside = true
            return enter(at: t)

        case let .pointerMoved(speed, t):
            guard pointerInside else { return [] }
            var effects: [Effect] = []
            // The first real motion after a relocation inside starts the rest, as an entry would.
            if phase == .closed { effects = enter(at: t) }
            guard phase == .opening else { return effects }
            if !swollen && speed <= Self.swellSpeed {
                swollen = true
                effects.append(.swell(true))
            }
            if speed > Self.restSpeed {
                generation += 1
                effects.append(.schedule(after: tuning.openDelay, generation: generation))
            }
            return effects

        case let .pointerExited(t):
            pointerInside = false
            mustLeaveBeforeReopen = false
            switch phase {
            case .opening:
                phase = .closed
                generation += 1
                return unswell()
            case .open:
                if holdOpen, !focusAway { return [] }
                let since = t - (openedAt ?? t)
                generation += 1
                if since < Self.abortWindow {
                    phase = .closed
                    openReason = nil
                    brief = false
                    foldStartedAt = t
                    return [.close(.abort)]
                }
                phase = .closing
                if since < Self.landedAfter {
                    retreated = true
                    return [.retreat, .schedule(after: Self.openingGrace, generation: generation)]
                }
                return [.schedule(after: Self.closeGrace, generation: generation)]
            case .closed, .closing:
                return []
            }

        case let .pointerRelocated(inside):
            pointerInside = inside
            guard !inside else { return [] }
            mustLeaveBeforeReopen = false
            // The owner went elsewhere and the pointer that held the island is off it now.
            if focusAway, phase == .open || phase == .closing { return yield() }
            if phase == .open, brief {
                // The island moved off a still pointer: no leave to close it, so the Done card's time starts again.
                generation += 1
                return [.schedule(after: Self.doneCardLife, generation: generation)]
            }
            // The same for a card that opened by itself: its idle time starts again (P292).
            if phase == .open, openReason == .attention { return armIdle() }
            guard phase == .opening else { return [] }
            phase = .closed
            generation += 1
            return unswell()

        case let .timerFired(fired, t):
            guard fired == generation else { return [] }
            switch phase {
            case .opening:
                return pointerInside ? open(.hover, at: t) : []
            case .closing:
                phase = .closed
                openReason = nil
                retreated = false
                brief = false
                foldStartedAt = t
                return [.close(.fold)]
            case .open:
                guard !pointerInside else { return [] }
                if !brief {
                    // Opened by itself for something that needs you and left alone (P292): it folds unless Keep open holds
                    // it; a draft, the keys or a card the island answers start its time again.
                    guard openReason == .attention, !holdOpen else { return [] }
                    if drafting || answerable { return armIdle() }
                }
                // The Done card's time is up, or the card that needs you was left alone, the pointer away: it folds back
                // into the pill. Not a pointer close, so no reverse; a rest opens it again.
                phase = .closed
                openReason = nil
                brief = false
                foldStartedAt = nil
                return [.close(.fold)]
            case .closed:
                return []
            }

        case let .clicked(t):
            mustLeaveBeforeReopen = false
            switch phase {
            case .closed, .opening: return open(.click, at: t)
            case .closing: return keep()
            case .open: return []
            }

        case let .attention(t):
            // It takes over whatever shows, a Done card included; with no pointer on it, it folds once left alone (P292),
            // and a request that comes while it is open starts that time again.
            brief = false
            switch phase {
            case .closed, .opening: return open(.attention, at: t) + armIdle()
            case .open: return armIdle()
            case .closing: return hold() + armIdle()
            }

        case let .finished(t):
            var effects: [Effect] = []
            switch phase {
            case .closed, .opening: effects = open(.attention, at: t)
            // A newer finish: its card replaces the last, and the time starts again (the old timer goes stale).
            case .open: generation += 1
            case .closing: effects = hold()
            }
            brief = true
            if !pointerInside { effects.append(.schedule(after: Self.doneCardLife, generation: generation)) }
            return effects

        case .dismissed:
            mustLeaveBeforeReopen = pointerInside
            foldStartedAt = nil
            brief = false
            focusAway = false
            guard phase != .closed else { return [] }
            phase = .closed
            openReason = nil
            retreated = false
            swollen = false
            generation += 1
            return [.close(.dismiss)]

        case let .answerEnded(t):
            // Left alone as the idle fold asks (P292), and its card no longer taking an answer: past its idle time it
            // folds now, the normal fold; sooner, its time runs from here.
            guard phase == .open, openReason == .attention, !brief, !pointerInside, !holdOpen, !drafting, !answerable else { return [] }
            guard let opened = openedAt, t - opened >= Self.attentionIdle else { return armIdle() }
            phase = .closed
            openReason = nil
            foldStartedAt = nil
            generation += 1
            return [.close(.fold)]

        case let .focusLeft(pointerHolds, _):
            switch phase {
            case .closed:
                return []
            case .opening:
                // Resting on the pill as the owner switched with the keyboard: the rest goes on only under the pointer.
                guard !pointerHolds else { return [] }
                phase = .closed
                generation += 1
                return unswell()
            case .open, .closing:
                guard !pointerHolds else {
                    focusAway = true
                    return []
                }
                return yield()
            }
        }
    }

    /// The owner went elsewhere: the island folds back into the pill with the normal fold, whatever held it open. Not
    /// a pointer close, so no reverse; a pointer still inside (a still one the island opened under) must leave first.
    private mutating func yield() -> [Effect] {
        phase = .closed
        openReason = nil
        brief = false
        retreated = false
        swollen = false
        focusAway = false
        foldStartedAt = nil
        mustLeaveBeforeReopen = pointerInside
        generation += 1
        return [.close(.fold)]
    }

    private mutating func enter(at t: TimeInterval) -> [Effect] {
        switch phase {
        case .closed:
            if mustLeaveBeforeReopen { return [] }
            // Back while it folds: the fold reverses in place, with no rest.
            if let fold = foldStartedAt, t - fold <= Self.reverseWindow { return open(.hover, at: t) }
            phase = .opening
            generation += 1
            return [.schedule(after: tuning.openDelay, generation: generation)]
        case .closing:
            return keep()
        case .opening, .open:
            return []
        }
    }

    /// The island stopped showing the Done card (another card, the list): it no longer closes by itself, and the card's
    /// time comes to nothing (a timer that fires on the open island is an idle fold's, P292).
    mutating func endBrief() {
        guard brief else { return }
        brief = false
        if phase == .open { generation += 1 }
    }

    /// The owner asked for what the open island shows (a widget's tap, P343): it holds as a click's open does, so it
    /// never folds by itself when left alone (P292); a timer already asked for comes to nothing.
    mutating func ownerAsked() {
        guard phase == .open, openReason == .attention, !brief else { return }
        openReason = .click
        generation += 1
    }

    /// Opened by itself for something that needs you, with no pointer on it: its idle fold is due `attentionIdle` from
    /// now (P292). Any other open island, and one under the pointer, waits for the pointer as before.
    private mutating func armIdle() -> [Effect] {
        guard phase == .open, openReason == .attention, !brief, !pointerInside else { return [] }
        generation += 1
        return [.schedule(after: Self.attentionIdle, generation: generation)]
    }

    /// Something arrived in the leave grace: the close is off, and the island is held by what arrived, not the pointer.
    private mutating func hold() -> [Effect] {
        openReason = .attention
        return keep()
    }

    /// Back inside a grace: the close is off, and a retreat resumes.
    private mutating func keep() -> [Effect] {
        phase = .open
        generation += 1
        guard retreated else { return [] }
        retreated = false
        return [.resume]
    }

    private mutating func unswell() -> [Effect] {
        guard swollen else { return [] }
        swollen = false
        return [.swell(false)]
    }

    private mutating func open(_ reason: OpenReason, at t: TimeInterval) -> [Effect] {
        phase = .open
        openReason = reason
        openedAt = t
        generation += 1
        foldStartedAt = nil
        swollen = false
        retreated = false
        brief = false
        focusAway = false
        return [.open(reason)]
    }
}

/// The pointer's speed: the mean over the samples of the last `window` seconds (points a second), each timed by when it
/// happened (`PointerSample`), not when it was handled. A sample that arrives after a later one (an event a busy main
/// thread handled after the poll's) takes its place in time.
struct PointerSpeed: Sendable {
    static let window: TimeInterval = 0.040

    private var samples: [(point: CGPoint, time: TimeInterval)] = []

    /// Adds a sample and returns the speed now.
    mutating func add(_ point: CGPoint, at time: TimeInterval) -> CGFloat {
        let index = samples.lastIndex { $0.time <= time }.map { $0 + 1 } ?? 0
        samples.insert((point, time), at: index)
        // Keep one sample from before the window, so a lone sample after a pause measures against it.
        let newest = samples[samples.count - 1].time
        while samples.count > 2, samples[1].time <= newest - Self.window { samples.removeFirst() }
        return speed
    }

    mutating func reset() { samples = [] }

    var speed: CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        var distance: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) { distance += hypot(b.point.x - a.point.x, b.point.y - a.point.y) }
        return distance / CGFloat(last.time - first.time)
    }
}
