import IslandEngine
import SwiftUI

/// Session peek (P311): the pointer resting on a row for `dwell` shows, under the row and inside the island, what the row
/// does not already say (`SessionPeek`). The peek lies over the rows below it and moves none of them; it takes no clicks,
/// so the pointer going on down reaches the row under it, whose own peek follows sooner (`warmDwell`). Where the rows
/// below leave too little room (one row, the last rows) the list grows by what it lacks (`IslandUIState.peekRoom`), so
/// it is never drawn beyond the island; it never flips above its row, where it would read as the row above's. Only on
/// the list, never on a row whose card waits (a click opens that card), and only with Settings › Island › Peek on hover.
@MainActor
final class IslandPeeker {
    private let ui: IslandUIState
    private let sessions: @MainActor () -> any SessionsModel
    private let settings: AppSettings
    private let dwell: Duration
    private let warmDwell: Duration
    private let clock: @MainActor () -> TimeInterval
    private var task: Task<Void, Never>?
    /// The row whose dwell or read is under way.
    private(set) var pending: String?
    /// When a peek last went: the next one within `warmWindow` comes after `warmDwell`.
    private var lastHiddenAt: TimeInterval?
    /// Bumped whenever the peek that shows goes or another takes its place: a follow left from it never runs again.
    private var followed = 0

    static let dwell: Duration = .milliseconds(500)
    static let warmDwell: Duration = .milliseconds(150)
    static let warmWindow: TimeInterval = 0.6

    init(ui: IslandUIState, settings: AppSettings, sessions: @escaping @MainActor () -> any SessionsModel,
         dwell: Duration = IslandPeeker.dwell, warmDwell: Duration = IslandPeeker.warmDwell,
         clock: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.ui = ui
        self.settings = settings
        self.sessions = sessions
        self.dwell = dwell
        self.warmDwell = warmDwell
        self.clock = clock
    }

    /// The pointer came onto a row or left it.
    func hovered(_ row: SessionRow, inside: Bool) {
        guard inside else {
            if pending == row.id { cancel() }
            if ui.peek?.sessionID == row.id { hide() }
            return
        }
        cancel()
        guard settings.sessionPeek, ui.isOpen, ui.presentation == .list, !row.hasCard else { return }
        let warm = lastHiddenAt.map { clock() - $0 <= Self.warmWindow } ?? false
        let wait = warm ? warmDwell : dwell
        let id = row.id
        pending = id
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self else { return }
            let clean = self.settings.islandStyle == .clean
            // What a Clean row says itself with Show model or Show branch on, its peek leaves out (P1015).
            let peek = await self.sessions().peek(id, clean: clean)?
                .leaving(model: clean && self.settings.rowShowsModel, branch: clean && self.settings.rowShowsBranch)
            guard !Task.isCancelled, self.pending == id else { return }
            self.pending = nil
            guard self.ui.isOpen, self.ui.presentation == .list else { return }
            if self.ui.peek != peek { self.ui.peek = peek }
            self.followed &+= 1
            if peek != nil { self.followWork(id) }
        }
    }

    /// Follows the shown peek's work while it shows (P720, P721): Codex's thought and the agent's checklist as the
    /// sessions say them now, updated in place with no read at each change; nothing is followed once the peek goes.
    private func followWork(_ id: String) {
        guard ui.peek?.sessionID == id else { return }
        let generation = followed
        let work = withObservationTracking { sessions().work(id) } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.followed == generation else { return }
                self.followWork(id)
            }
        }
        guard var peek = ui.peek, peek.sessionID == id else { return }
        peek.take(work: work, running: sessions().row(id: id)?.bucket == .running)
        if ui.peek != peek { ui.peek = peek }
    }

    /// The rows changed: a peeked row that went, or now waits on the owner (its card is one click away), loses its peek.
    func rowsChanged(_ rows: [SessionRow]) {
        ui.rowFrames.keep(Set(rows.map(\.id)))
        guard let id = ui.peek?.sessionID else { return }
        if rows.first(where: { $0.id == id }).map({ $0.hasCard }) ?? true { hide() }
    }

    /// The island folded or shows a card: no peek, none on its way.
    func reset() {
        cancel()
        hide()
    }

    private func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }

    private func hide() {
        followed &+= 1
        if ui.peek != nil {
            ui.peek = nil
            lastHiddenAt = clock()
        }
        if ui.peekRoom != 0 { ui.peekRoom = 0 }
        if ui.peekCover != nil { ui.peekCover = nil }
    }

    /// The dwell or read under way (tests await it).
    var work: Task<Void, Never>? { task }
}

/// Each list row's frame in the peek layer's space (`IslandPeekLayer.space`), by session, for the peek to hang from and
/// to end on (a row's bottom, `IslandPeekPlacement.ground`); the list's other parts (the footer, the Codex group) under
/// `part:` keys; and a finished row's line width, for its peek to take the reply up where the line stops
/// (`SessionPeek.rest`). Written as the rows lay out, read only by `IslandPeekOverlay` while a peek shows. Not anchor
/// preferences: read over the live list, which is always in its scroll view (E6), those left the island's first row
/// undrawn in some updates under Refined (`MotionRoundCTests.theSoftEdgeFadesTheListInItsScrollView`, one run in three
/// beside other suites).
@MainActor @Observable
final class IslandRowFrames {
    var frames: [String: CGRect] = [:]
    var lines: [String: CGFloat] = [:]

    static let part = "part:"

    /// Only the rows still listed (the peeker prunes at each batch); the parts go when they leave the list.
    func keep(_ ids: Set<String>) {
        if frames.keys.contains(where: { !ids.contains($0) && !$0.hasPrefix(Self.part) }) {
            frames = frames.filter { ids.contains($0.key) || $0.key.hasPrefix(Self.part) }
        }
        if lines.keys.contains(where: { !ids.contains($0) }) { lines = lines.filter { ids.contains($0.key) } }
    }
}

extension View {
    /// A list row the peek can hang from.
    func islandPeekAnchor(_ id: String, frames: IslandRowFrames) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .named(IslandPeekLayer.space)) } action: { frames.frames[id] = $0 }
    }

    /// A part of the list below the rows (the footer, the Codex group) that a peek ends on rather than cuts.
    func islandPeekPart(_ name: String, frames: IslandRowFrames?) -> some View {
        modifier(IslandPeekPartFrame(key: IslandRowFrames.part + name, frames: frames))
    }

    /// A finished row's line: its width, for the peek to take its reply up where the line stops (P311). Nothing for any
    /// other row, or outside the island's list.
    func islandPeekLine(_ row: SessionRow, frames: IslandRowFrames?) -> some View {
        modifier(IslandPeekLineWidth(id: row.id, frames: row.bucket == .done ? frames : nil))
    }
}

private struct IslandPeekPartFrame: ViewModifier {
    let key: String
    let frames: IslandRowFrames?

    func body(content: Content) -> some View {
        if let frames {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(IslandPeekLayer.space)) } action: { frames.frames[key] = $0 }
                .onDisappear { frames.frames[key] = nil }
        } else {
            content
        }
    }
}

private struct IslandPeekLineWidth: ViewModifier {
    let id: String
    let frames: IslandRowFrames?

    func body(content: Content) -> some View {
        if let frames {
            content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { frames.lines[id] = $0 }
        } else {
            content
        }
    }
}

/// The list's peek layer: the peek over the rows, placed from its row's frame, and the room it may need under the list.
/// Only `IslandPeekOverlay` and `IslandPeekRoom` read the peek, so one that comes or goes re-evaluates them alone,
/// never the list (P102).
struct IslandPeekLayer: ViewModifier {
    let ui: IslandUIState
    var reduceMotion = false

    nonisolated static let space = "IslandPeekLayer"

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            content
            IslandPeekRoom(ui: ui)
        }
        .coordinateSpace(.named(Self.space))
        .overlay(alignment: .topLeading) { IslandPeekOverlay(ui: ui, reduceMotion: reduceMotion) }
    }
}

/// The room the list lacks for a peek: no height at all but while a peek needs it.
private struct IslandPeekRoom: View {
    let ui: IslandUIState

    var body: some View {
        Color.clear.frame(height: ui.peekRoom).accessibilityHidden(true)
    }
}

/// The part of the list a peek lies over, in `IslandPeekLayer.space`: from under its row to its ground's end.
struct IslandPeekCover: Equatable, Sendable {
    var minY: CGFloat
    var maxY: CGFloat

    /// A row (or part) that reaches into the ground, whole or in part.
    func covers(_ frame: CGRect) -> Bool { frame.maxY > minY + 0.5 && frame.minY < maxY - 0.5 }
}

/// On glass, a row (or part) the shown peek lies over is not drawn: the peek's cover lays only a veil there (P558), so
/// its ground is the island's own glass. It fades as the peek comes and goes. In Black the cover's black hides it, as
/// ever, and this reads nothing: only on glass does a peek that comes or goes re-evaluate the rows' fades (P102).
struct IslandPeekCovered: ViewModifier {
    let ui: IslandUIState
    /// The row's id, or a part's key (`IslandRowFrames.part`).
    let key: String
    @Environment(\.juiceTheme) private var theme

    static func hides(theme: JuiceTheme, cover: IslandPeekCover?, frame: CGRect?) -> Bool {
        guard theme.knocksOut, let cover, let frame else { return false }
        return cover.covers(frame)
    }

    func body(content: Content) -> some View {
        if theme.knocksOut {
            content.modifier(IslandPeekHide(ui: ui, key: key))
        } else {
            content
        }
    }
}

private struct IslandPeekHide: ViewModifier {
    let ui: IslandUIState
    let key: String

    func body(content: Content) -> some View {
        // The frames are read only while a peek shows (`IslandRowFrames`).
        let cover = ui.peekCover
        let hidden = cover != nil && IslandPeekCovered.hides(theme: .glass, cover: cover, frame: ui.rowFrames.frames[key])
        content
            .opacity(hidden ? 0 : 1)
            // On the peek's own curve, or at once as the peek comes under Reduce Motion (`IslandPeekOverlay`).
            .animation(ui.reduceMotion ? nil : IslandMotion.focusIn.animation, value: hidden)
    }
}

extension View {
    /// A list row (or part, under `IslandRowFrames.part`) a peek can lie over: not drawn there on glass (P558).
    func islandPeekCovered(_ key: String, ui: IslandUIState) -> some View {
        modifier(IslandPeekCovered(ui: ui, key: key))
    }

    /// A part below the rows (`islandPeekPart`) that a peek can lie over.
    func islandPeekCoveredPart(_ name: String, ui: IslandUIState) -> some View {
        islandPeekPart(name, frames: ui.rowFrames).islandPeekCovered(IslandRowFrames.part + name, ui: ui)
    }
}

/// Where a peek goes (`IslandPeekOverlay`): always under its row, `gap` below it, and the room the list lacks for it
/// under the row, added to the list. Pure: `below` is the list's height under the row without any room already added.
enum IslandPeekPlacement {
    static let gap: CGFloat = 2

    static func room(height: CGFloat, below: CGFloat) -> CGFloat {
        max(0, ceil(height + gap - below))
    }

    /// How tall the peek's ground is, from `top`, for text `height` tall: down to the bottom of a row (or part) it would
    /// end inside, so no row shows only in part under it and none of its lines reads as the peek's, and never past the
    /// list's end (`limit`).
    static func ground(top: CGFloat, height: CGFloat, rows: [CGRect], limit: CGFloat) -> CGFloat {
        var bottom = top + height
        for row in rows.sorted(by: { $0.minY < $1.minY }) where row.minY < bottom - 0.5 && row.maxY > bottom + 0.5 {
            bottom = row.maxY
        }
        return max(height, min(bottom, limit) - top)
    }
}

private struct IslandPeekOverlay: View {
    let ui: IslandUIState
    let reduceMotion: Bool
    @State private var height: CGFloat?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.islandSize) private var size

    var body: some View {
        GeometryReader { proxy in
            if let peek = ui.peek, let row = ui.rowFrames.frames[peek.sessionID],
               case let reply = Self.reply(peek, frames: ui.rowFrames, fontSize: size.text(IslandPeekView.lineFontSize)),
               reply != nil || !peek.saysOnlyItsReply {
                let below = proxy.size.height - ui.peekRoom - row.maxY
                let top = row.maxY + IslandPeekPlacement.gap
                let ground = height.map { IslandPeekPlacement.ground(top: top, height: $0, rows: Array(ui.rowFrames.frames.values),
                                                                     limit: proxy.size.height) }
                let cover = ground.map { IslandPeekCover(minY: top, maxY: top + $0) }
                IslandPeekView(peek: peek, clean: env.settings.islandStyle == .clean, reply: reply, ground: ground)
                    // What it lies over, for the rows under it (`IslandPeekCovered`).
                    .onChange(of: cover, initial: true) { _, cover in if ui.peekCover != cover { ui.peekCover = cover } }
                    .onDisappear { if ui.peekCover != nil { ui.peekCover = nil } }
                    .frame(width: row.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                        height = measured
                        let room = IslandPeekPlacement.room(height: measured, below: below)
                        if ui.peekRoom != room { ui.peekRoom = room }
                    }
                    // Drawn once it is measured and placed, never a frame where it does not belong.
                    .opacity(height == nil ? 0 : 1)
                    .offset(x: row.minX, y: row.maxY + IslandPeekPlacement.gap)
                    .id(peek.sessionID)
                    .transition(.opacity.animation(reduceMotion ? nil : IslandMotion.focusIn.animation))
            }
        }
        .allowsHitTesting(false)
        .onChange(of: ui.peek?.sessionID) {
            height = nil
            if ui.peekCover != nil { ui.peekCover = nil }
        }
    }

    /// The reply the peek shows: a finished row's taken up where its line stops (`SessionPeek.rest`, nil when the line
    /// shows it whole), any other as it is.
    static func reply(_ peek: SessionPeek, frames: IslandRowFrames, fontSize: CGFloat = IslandPeekView.lineFontSize) -> String? {
        guard peek.replyContinuesLine, let reply = peek.reply, let width = frames.lines[peek.sessionID] else { return peek.reply }
        return SessionPeek.rest(of: reply, lineWidth: width, fontSize: fontSize)
    }
}

/// A peek's lines (P311): "You:" and the owner's last prompt, as the rows write it (two lines at most), the agent's
/// latest reply (three; a finished row's taken up where its line stops), Codex's reasoning summary while it thinks
/// (two, P720), the tool it waits on, the agent's checklist (P721), and, in Clean, the branch (P434), model, mode and
/// progress (the progress only while no checklist shows). On the island's black under the hovered row's own faint
/// fill, so the row and its peek read as one, lifted over the rows it covers; its ground reaches `ground` (a row's
/// bottom) when that is below its text.
struct IslandPeekView: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let peek: SessionPeek
    let clean: Bool
    /// The reply it shows (`IslandPeekOverlay.reply`).
    let reply: String?
    /// How tall its ground is (`IslandPeekPlacement.ground`); nil: its text's height.
    var ground: CGFloat?
    /// Settings › Island › Text size (P402): the peek reads as the rows do.
    @Environment(\.islandSize) private var size

    private typealias M = IslandTheme.Metrics

    /// The rows' own prompt label and colour (Detailed's status line: "You: " in grey, the prompt in its status colour).
    static let youLabel = DetailedRowText.youLabel
    /// Claude Code's own word for its summary, as the "You: " label is the rows' (P446).
    static let recapLabel = "Recap: "
    static let promptColour = IslandTheme.statusDetailed
    /// The row lines' type size (Clean's and Detailed's alike): a finished row's line is measured at it.
    static let lineFontSize: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let prompt = peek.prompt {
                let you = Text(Self.youLabel).foregroundStyle(palette.you)
                // `promptColour` on the theme's surface.
                Text("\(you)\(Text(prompt).foregroundStyle(palette.statusDetailed))").lineLimit(2)
            }
            if let recap = peek.recap {
                let label = Text(Self.recapLabel).foregroundStyle(palette.you)
                Text("\(label)\(Text(recap).foregroundStyle(palette.message))").lineLimit(SessionPeek.recapLines)
            }
            if let reply {
                Text(reply).foregroundStyle(palette.message).lineLimit(SessionPeek.replyLines)
            }
            if let thinking = peek.thinking {
                PeekThinking(thinking: thinking)
            }
            if let tool = peek.tool {
                HStack(spacing: 4) {
                    Text(tool.verb).font(Fonts.mono(size.text(11))).foregroundStyle(palette.toolVerb)
                    if let text = tool.text { Text(text).foregroundStyle(palette.toolLine) }
                }
                .lineLimit(1)
            }
            if !peek.steps.isEmpty {
                PeekChecklist(steps: peek.steps)
            }
            if clean, peek.branch != nil || !peek.facts.isEmpty {
                HStack(spacing: 8) {
                    if let branch = peek.branch { IslandBranchTag(branch: branch) }
                    if !peek.facts.isEmpty { RowFactTags(facts: peek.facts) }
                }
            }
        }
        .font(Fonts.sys(size.text(Self.lineFontSize)))
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.leading, 8 + M.rowGlyphColumn + M.rowGlyphGap)
        .padding(.trailing, 8)
        .background(alignment: .top) {
            let shape = RoundedRectangle(cornerRadius: clean ? 10 : 12)
            // Hangs from its top: a taller ground reaches down past its text (the measure is the text's alone). On glass
            // a glass of its own, never a black patch (P526).
            IslandCover(shape: shape, fill: palette.islandHover)
                .frame(height: ground)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Codex's reasoning summary in a peek (P720): its bold title in the reply's colour, what follows in the dimmer ink, two
/// lines at most. It changes as Codex thinks, while the peek shows (`IslandPeeker`).
struct PeekThinking: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let thinking: SessionWork.Thinking

    static let lines = 2

    var body: some View {
        let title = thinking.title.map { Text($0).fontWeight(.medium).foregroundStyle(palette.message) }
        let text = thinking.text.map { Text($0).foregroundStyle(palette.ink2) }
        Group {
            if let title, let text {
                Text("\(title) \(text)")
            } else if let title {
                title
            } else if let text {
                text
            }
        }
        .lineLimit(Self.lines)
    }
}

/// The agent's checklist in a peek (P721): one line a step, a mark before it (done ✓ in the done green, current ● in the
/// running blue, pending ○), the current step in the reply's ink, the rest dimmer, done dimmest. At most
/// `SessionPeek.stepLines` lines: a longer list shows a window around the current step, and says how many it leaves out
/// above ("3 done") and below ("2 more").
struct PeekChecklist: View {
    @Environment(\.juiceTheme) private var theme
    @Environment(\.islandSize) private var size
    private var palette: IslandPalette { theme.island }
    let steps: [SessionWork.Step]

    /// The marks' column, so every step's text starts at one edge.
    static let markColumn: CGFloat = 10

    var body: some View {
        let window = SessionPeek.window(steps)
        VStack(alignment: .leading, spacing: 1) {
            if window.above > 0 { left(SessionPeek.aboveLine(steps, above: window.above)) }
            ForEach(Array(window.shown.enumerated()), id: \.offset) { _, step in
                HStack(spacing: 5) {
                    mark(step.state).frame(width: Self.markColumn)
                    Text(step.text).foregroundStyle(ink(step.state)).lineLimit(1)
                }
            }
            if window.below > 0 { left("\(window.below) more") }
        }
        .accessibilityElement(children: .combine)
    }

    private func left(_ text: String) -> some View {
        Text(text).foregroundStyle(palette.ink3).padding(.leading, Self.markColumn + 5)
    }

    private func ink(_ state: SessionWork.Step.State) -> Color {
        switch state {
        case .current: palette.message
        case .pending: palette.ink2
        case .done: palette.ink3
        }
    }

    @ViewBuilder private func mark(_ state: SessionWork.Step.State) -> some View {
        switch state {
        case .done:
            Image(systemName: "checkmark").font(.system(size: size.text(7.5), weight: .bold)).foregroundStyle(palette.tone(IslandTheme.done))
                .accessibilityLabel("Done")
        case .current:
            Circle().fill(palette.tone(IslandTheme.run)).frame(width: 5, height: 5).accessibilityLabel("Now")
        case .pending:
            Circle().strokeBorder(palette.idleMark, lineWidth: 1).frame(width: 6, height: 6).accessibilityLabel("To do")
        }
    }
}
