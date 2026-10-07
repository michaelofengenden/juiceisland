import IslandEngine
import JuiceCore
import SwiftUI

/// A row's background on hover: a faint white fill, no stroke (the island's only fill). `hovered` hears the pointer come
/// and go too. `lifted`: drawn as hovered whatever the pointer does (a render of a row's peek, P311). With `selection`
/// (the island's state and the row's session), the row the keys are on takes the same fill and a thin ring
/// (`SelectionMark`, P321); the selection is read here, so a key press re-evaluates these small modifiers and never the
/// list.
private struct RowHover: ViewModifier {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    var radius: CGFloat
    var lifted = false
    var selection: (ui: IslandUIState, id: String)?
    var hovered: (@MainActor (Bool) -> Void)?
    @State private var hovering = false
    func body(content: Content) -> some View {
        let selected = selection.map { $0.ui.selectedRow == $0.id } ?? false
        content
            .background {
                if hovering || lifted || selected { RoundedRectangle(cornerRadius: radius).fill(palette.islandHover) }
                if selected {
                    RoundedRectangle(cornerRadius: radius).strokeBorder(palette.selectionRing, lineWidth: SelectionMark.ringWidth)
                }
            }
            .onHover { inside in
                hovering = inside
                hovered?(inside)
            }
    }
}

extension View {
    func islandRowHover(radius: CGFloat, lifted: Bool = false, selection: (ui: IslandUIState, id: String)? = nil,
                        hovered: (@MainActor (Bool) -> Void)? = nil) -> some View {
        modifier(RowHover(radius: radius, lifted: lifted, selection: selection, hovered: hovered))
    }
}

/// The row glyph in a 16 pt column: Pixel at 14 pt (pixel 2); Liquid and Sand at 20 pt, so their fine marks read at a
/// row's size, laid out as the column's 16 pt square they centre on, so the row keeps its height and layout.
struct RowGlyph: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    let row: SessionRow
    var animated: Bool
    var body: some View {
        let side = StateGlyphView.side(style: env.settings.glyphStyle, pixel: IslandTheme.Metrics.rowGlyphPixel,
                                       engineSide: IslandTheme.Metrics.rowGlyphEngine)
        // A stalled row's glyph holds still (P312).
        StateGlyphView(glyph: row.glyph, colour: GlyphPalette.glyph(agent: row.agent, state: row.glyphState, mode: env.settings.glyphColour,
                                                                    needsYou: needsYou, idle: palette.idleMark),
                       pixel: IslandTheme.Metrics.rowGlyphPixel, animated: animated && !row.isStalled,
                       engineSide: IslandTheme.Metrics.rowGlyphEngine)
            .frame(width: IslandTheme.Metrics.rowGlyphColumn, height: min(side, IslandTheme.Metrics.rowGlyphColumn))
    }
}

/// What a compact Clean row says: the chat's title alone (the repo is in its mark's tooltip, and is the title only
/// before any prompt), and one short status line. The glyph already says Needs approval, Question or Done, so the status
/// drops that word when it has text of its own and takes the word's colour instead.
enum IslandRowText {
    static func title(_ row: SessionRow) -> String { SessionRowText.cleanTitle(row).task }

    static func status(_ row: SessionRow, now: Date? = nil) -> SessionRowText.Status {
        var status = SessionRowText.cleanStatus(row, now: now)
        // Stalled keeps its word: the glyph, held still, does not say it (P312). So does a limit: "×" or the check says the
        // turn ended, not that a limit or the API ended it ("Limit reached · resets 15:00", P700).
        if status.word != nil, status.text != nil, status.tone != .stalled, row.limit == nil { status.word = nil }
        return status
    }
}

/// A Clean row (padding 5 8, radius 10): the agent's mark and the title over one short status, the glyph centred beside
/// both lines, the age at the right ("↗" while hovered, in one fixed column). `oneLine` is a card's header row: the
/// title only.
struct CleanSessionRow: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @Environment(AppEnvironment.self) private var env
    /// Settings › Island › Text size (P402): both lines, the age and their boxes step with it.
    @Environment(\.islandSize) private var size
    let row: SessionRow
    var oneLine = false
    var animated = true
    /// The island list's frames: a finished row reports its line's width for its peek (P311).
    var lineFrames: IslandRowFrames?
    @State private var hoveringRow = false
    @Environment(\.previewRowHovered) private var previewHovered
    private var hovering: Bool { hoveringRow || previewHovered }

    private typealias M = IslandTheme.Metrics

    var body: some View {
        HStack(alignment: .top, spacing: M.rowGlyphGap) {
            RowGlyph(row: row, animated: animated)
                .frame(height: oneLine ? size.rowTitleHeight : size.rowTitleHeight + size.rowStatusHeight)
            VStack(alignment: .leading, spacing: 0) {
                title.frame(height: size.rowTitleHeight)
                if !oneLine { status.frame(height: size.rowStatusHeight) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing.frame(height: size.rowTitleHeight)
        }
        .onHover { hoveringRow = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(SessionRowText.cleanStatus(row).word ?? "")
    }

    private var title: some View {
        RowTitleLine(row: row, size: size.text(12), markSize: Theme.Mark.sessionRow, showsProject: false)
    }

    /// Line 2, its compaction's time moving while it compacts (P433); at its end the branch and the model when Show
    /// branch and Show model are on (P1015), the line cut first, then the branch, its state word never (P1078).
    private var status: some View {
        let shown = CleanRowShown(row, settings: env.settings)
        return HStack(spacing: 12) {
            CompactionClock(since: row.status == .compacting ? row.compactingSince : nil) { now in
                statusLine(IslandRowText.status(row, now: now))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .keepsWhole(shown.isEmpty ? nil : IslandRowText.status(row).word, font: Fonts.sys(size.text(11)))
            if !shown.isEmpty { CleanRowTags(shown: shown).layoutPriority(1) }
        }
    }

    private func statusLine(_ status: SessionRowText.Status) -> some View {
        let tone = status.tone == .approval || status.tone == .question ? IslandRowColours.word(status.tone, palette: palette, needsYou: needsYou) : palette.statusClean
        return HStack(spacing: 0) {
            if let word = status.word { Text(word).foregroundStyle(IslandRowColours.word(status.tone, palette: palette, needsYou: needsYou)) }
            if status.word != nil, status.toolVerb != nil || status.text != nil { Text(" · ") }
            if let verb = status.toolVerb {
                Text(verb).font(Fonts.mono(size.text(11))).foregroundStyle(palette.toolVerb).padding(.trailing, 5)
            }
            if let text = status.text { Text(text).foregroundStyle(tone).islandPeekLine(row, frames: lineFrames) }
        }
        .font(Fonts.sys(size.text(11)))
        .foregroundStyle(palette.statusClean)
        .lineLimit(1)
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            // Send to island, under the pointer, where the session's tab is known (P1300).
            if hovering, env.offersSendToIsland(row) { SendToIslandButton(sessionID: row.id) }
            // A remote session's host (P745), before the age column.
            if let host = row.remoteHost { Text(host).font(Fonts.sys(size.text(11))) }
            Group {
                if hovering {
                    Text("↗").foregroundStyle(palette.jump).accessibilityLabel("Jump")
                } else {
                    Text(SessionRowText.age(row.updatedAt, now: env.sessions.now))
                }
            }
            // A fixed column ("59m" wide), so hover never moves the title's room.
            .frame(minWidth: size.scaled(IslandTheme.Metrics.rowAgeWidth, for: 11), alignment: .trailing)
            .font(Fonts.num(size.text(11), .regular))
        }
        .foregroundStyle(palette.rowAge)
        .fixedSize()
    }
}

/// A row's Send to island, under the pointer (P1300): the pill-and-arrow mark, in the jump's ink, its hit box the row's
/// title line. The row's own click still opens or jumps; this click only sends.
struct SendToIslandButton: View {
    let sessionID: String
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    @State private var hovered = false

    var body: some View {
        Button { env.sendToIsland(sessionID) } label: {
            FoldIcon(colour: hovered ? theme.island.ink : theme.island.jump, side: 12)
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Send to island")
        .accessibilityLabel("Send to island")
    }
}

enum IslandRowColours {
    /// A status word's colour: the state's (what needs you in `needsYou`), or `palette`'s grey for a plain word.
    static func word(_ tone: SessionRowText.Status.Tone, palette: IslandPalette = .black, needsYou: NeedsYouColour) -> Color {
        switch tone {
        case .approval, .question: palette.toneText(needsYou.wait)
        case .done: palette.toneText(IslandTheme.done)
        case .plain: palette.you
        case .stalled: palette.toneText(IslandTheme.stalled)
        }
    }
}

/// Detailed status and tool lines (the island's wording; the Clean line is stream C's `SessionRowText`).
enum DetailedRowText {
    /// Before the owner's prompt, in grey (the peek writes it the same way).
    static let youLabel = "You: "

    struct Status: Equatable {
        var word: String?
        var tone: SessionRowText.Status.Tone
        /// The owner's prompt, drawn after a grey "You:".
        var prompt: String?
        var text: String?
    }

    /// `now`: the clock a compacting row's time reads (P433).
    static func status(_ row: SessionRow, now: Date? = nil) -> Status {
        // Stalled, then the prompt; the tool line under it says what it was on (P312).
        if row.isStalled { return Status(word: "Stalled", tone: .stalled, prompt: SessionRowText.shownPrompt(row)) }
        // The limit or API error the turn stopped on, in place of "Turn failed" or "Done" (P700).
        if let limit = row.limit { return Status(word: limit.word, tone: limit.warns ? .approval : .plain, text: limit.text) }
        switch row.status {
        case let .needsApproval(tool):
            if SessionRowText.isPlan(tool) {
                return Status(word: "Plan ready", tone: .approval, text: SessionRowText.planSteps(row.detail).map(SessionRowText.stepsText))
            }
            return Status(word: "Needs approval", tone: .approval, text: SessionRowText.approvalText(row, tool: tool))
        case .question:
            let prompt = SessionRowText.shownPrompt(row)
            return Status(word: "Question", tone: .question, prompt: prompt, text: prompt == nil ? row.detail : nil)
        case .done:
            return Status(word: "Done", tone: .done, text: row.detail)
        case .interrupted:
            return Status(word: "Interrupted", tone: .plain, prompt: SessionRowText.shownPrompt(row))
        case .failed:
            return Status(word: "Turn failed", tone: .approval, text: row.detail)
        case .thinking:
            return Status(word: "Thinking", tone: .plain, prompt: SessionRowText.shownPrompt(row))
        case .compacting:
            return Status(word: CompactionText.word(since: row.compactingSince, now: now), tone: .plain, prompt: SessionRowText.shownPrompt(row))
        case let .subagents(count, workflows):
            return Status(word: StatusWord.subagentsText(count, workflows: workflows), tone: .plain, prompt: SessionRowText.shownPrompt(row))
        case .reviewing:
            return Status(word: "Reviewing", tone: .plain, prompt: SessionRowText.shownPrompt(row))
        case let .denied(tool):
            return Status(word: nil, tone: .plain, text: StatusWord.deniedSummary(tool: tool))
        case .tool, .working:
            let prompt = SessionRowText.shownPrompt(row)
            return Status(word: nil, tone: .plain, prompt: prompt, text: prompt == nil ? "Working" : nil)
        }
    }

    /// The running tool with its full argument.
    static func toolLine(_ row: SessionRow) -> (verb: String, text: String)? {
        guard case let .tool(name, detail) = row.status else { return nil }
        return (name, detail ?? "")
    }

    /// The host most of `rows` share, when two or more share it: every fact once, so it is said by leaving it off and
    /// only a row elsewhere keeps its tag ("Terminal" on every row said nothing). A tie goes to the host met first.
    /// "Codex.app" always shows: it tells a desktop app thread from a terminal session; so does an SSH host's name, which
    /// says the row runs off this Mac (P745).
    static func sharedHost(_ rows: [SessionRow]) -> String? {
        var counts: [String: (count: Int, first: Int)] = [:]
        for (index, host) in rows.filter({ $0.remoteHost == nil }).compactMap(\.host).enumerated() where host != codexApp {
            counts[host, default: (0, index)].count += 1
        }
        guard let best = counts.max(by: { ($0.value.count, -$0.value.first) < ($1.value.count, -$1.value.first) }),
              best.value.count >= 2 else { return nil }
        return best.key
    }

    static let codexApp = "Codex.app"
}

/// A Detailed row (padding 8, radius 14): the agent's mark and `repo · title`, status, tool line, and tags (host,
/// account, time). Each line carries its own tags at its trailing edge, so line 2's branch and model never take line 1's
/// room; on line 2 the state word keeps its whole width (a compaction's time with it), the prompt is cut first, then the
/// branch (P492).
struct DetailedSessionRow: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @Environment(AppEnvironment.self) private var env
    /// Settings › Island › Text size (P402).
    @Environment(\.islandSize) private var size
    let row: SessionRow
    var animated = true
    /// The host the list's rows share (`DetailedRowText.sharedHost`): left off, so it is not said on every row.
    var sharedHost: String?
    /// The island list's frames: a finished row reports its line's width for its peek (P311).
    var lineFrames: IslandRowFrames?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: IslandTheme.Metrics.rowGlyphGap) {
            RowGlyph(row: row, animated: animated).padding(.top, 2)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    RowTitleLine(row: row, size: size.text(12), markSize: Theme.Mark.sessionRow)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // Send to island, under the pointer, where the session's tab is known (P1300).
                    if hovering, env.offersSendToIsland(row) { SendToIslandButton(sessionID: row.id) }
                    firstTags
                }
                .frame(height: size.line(19, for: 12))
                status.frame(height: size.line(18, for: 11))
                if let tool = DetailedRowText.toolLine(row) {
                    HStack(spacing: 0) {
                        Text(tool.verb).font(Fonts.mono(size.text(11))).foregroundStyle(palette.toolVerb).padding(.trailing, 4)
                        Text(tool.text)
                    }
                    .font(Fonts.sys(size.text(11)))
                    .foregroundStyle(palette.toolLine)
                    .lineLimit(1)
                    .frame(height: size.line(18, for: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }

    /// Line 2, its compaction's time moving while it compacts (P433).
    private var status: some View {
        CompactionClock(since: row.status == .compacting ? row.compactingSince : nil) { now in
            statusLine(DetailedRowText.status(row, now: now))
        }
    }

    /// Line 2: the state word whole, then the prompt or the detail, cut first; at its end the branch when it is not the
    /// repo's default (P434), which gives way next, and the model, the mode and the task progress when the agent said
    /// them (P310).
    private func statusLine(_ status: DetailedRowText.Status) -> some View {
        let separator = status.word != nil && (status.prompt != nil || status.text != nil)
        return HStack(spacing: 12) {
            HStack(spacing: 0) {
                if let word = status.word { Text(word).foregroundStyle(IslandRowColours.word(status.tone, palette: palette, needsYou: needsYou)).fixedSize() }
                if separator { Text(" · ").fixedSize() }
                if let prompt = status.prompt {
                    Text(DetailedRowText.youLabel).foregroundStyle(palette.you)
                    Text(prompt)
                }
                if let text = status.text { Text(text).islandPeekLine(row, frames: lineFrames) }
            }
            .font(Fonts.sys(size.text(11)))
            .foregroundStyle(palette.statusDetailed)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.branch != nil || !row.facts.isEmpty {
                HStack(spacing: 8) {
                    if let branch = row.branch { IslandBranchTag(branch: branch, yields: true) }
                    if !row.facts.isEmpty { RowFactTags(facts: row.facts) }
                }
                .layoutPriority(1)
            }
        }
    }

    /// Line 1's tags: host, account and age as dim text (the agent's mark is before the title).
    private var firstTags: some View {
        HStack(spacing: 8) {
            if let host = row.host, host != sharedHost || row.remoteHost != nil { IslandTag(text: host, colours: palette.tagHost) }
            if let alias = row.accountAlias { IslandTag(text: alias, colours: palette.tagHost) }
            IslandTag(text: SessionRowText.age(row.updatedAt, now: env.sessions.now), colours: palette.tagTime)
                .frame(minWidth: size.scaled(IslandTheme.Metrics.tagAgeWidth, for: 9.5), alignment: .trailing)
        }
        .fixedSize()
    }
}

/// What a Clean row and its Clean card's header say at the end of their second line (P1015): the branch with Show branch
/// on, the model and its effort with Show model on, each only when the session reports it (`SessionRow.branch`,
/// `RowFacts`: nothing is read for them). Both off, the row is as it was; its peek then says them, and otherwise leaves
/// them to the row (`SessionPeek.leaving`).
struct CleanRowShown: Equatable, Sendable {
    var branch: String?
    var model: RowFacts?

    init(_ row: SessionRow, branch: Bool, model: Bool) {
        self.branch = branch ? row.branch : nil
        self.model = model && row.facts.model != nil ? RowFacts(model: row.facts.model, effort: row.facts.effort) : nil
    }

    @MainActor init(_ row: SessionRow, settings: AppSettings) {
        self.init(row, branch: settings.rowShowsBranch, model: settings.rowShowsModel)
    }

    var isEmpty: Bool { branch == nil && model == nil }
}

extension View {
    /// Never narrower than `word` and an ellipsis at `font` (nil: as it is): a Clean line's state word ("Needs
    /// approval…") stays whole while the branch and the model beside it take the room, the rest of the line and then the
    /// branch cut first (P1015, P1078). A hidden copy sets the width the stack keeps for it; what shows is drawn as before.
    func keepsWhole(_ word: String?, font: Font) -> some View {
        ZStack(alignment: .leading) {
            if let word { Text(word + "…").font(font).lineLimit(1).fixedSize().hidden().accessibilityHidden(true) }
            self
        }
    }
}

/// `CleanRowShown` as tags: the branch (which yields first, cut in its middle) and the model, in the Detailed tags' look.
struct CleanRowTags: View {
    let shown: CleanRowShown

    var body: some View {
        HStack(spacing: 8) {
            if let branch = shown.branch { IslandBranchTag(branch: branch, yields: true) }
            if let model = shown.model { RowFactTags(facts: model) }
        }
    }
}

/// The model, the mode and the task progress as one dim tag (P310), "Opus 5.5 · plan · 2/5", as a Detailed row and a
/// Clean row's peek say them: the dots keep a mode ("plan") from reading as the progress's name.
struct RowFactTags: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let facts: RowFacts

    var body: some View {
        IslandTag(text: facts.items.joined(separator: " · "), colours: palette.tagTime)
    }
}

/// A Detailed tag in the island: 500 9.5/15 pt in the tag's own colour, on the island's black (no chip behind it);
/// Settings › Island › Text size steps it as the rows (P402).
struct IslandTag: View {
    let text: String
    let colours: IslandTheme.TagColours
    @Environment(\.islandSize) private var size
    var body: some View {
        Text(text)
            .font(Fonts.sys(size.text(9.5), .medium))
            .foregroundStyle(colours.fg)
            .lineLimit(1)
            .frame(height: size.line(15, for: 9.5))
            .fixedSize()
    }
}

/// The branch as a Detailed tag and in a Clean row's peek (P434): the tags' 500 9.5/15 pt, stepped with Settings › Island ›
/// Text size as the other tags are (P402).
struct IslandBranchTag: View {
    let branch: String
    /// A Detailed row's line 2: short of room, it is cut further (in the middle) before the state word is (P492).
    var yields = false
    @Environment(\.islandSize) private var size
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        // The tags' dim colour in the theme (Black's #7C7C80 is 3.3:1 on glass over a white window, P556).
        RowBranchTag(branch: branch, font: Fonts.sys(size.text(9.5), .medium), colour: theme.island.tagTime.fg,
                     height: size.line(15, for: 9.5), maxWidth: size.scaled(90, for: 9.5), yields: yields)
    }
}

/// Detailed's Codex group: the Codex sessions the four rows leave out (no card behind it: spacing sets it apart).
/// Read like the window's group: the label "Codex N" (in Codex's colour: every row of it is Codex's) and the titles on
/// the rows' title column, each dot in the rows' glyph column.
struct IslandCodexGroup: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @Environment(AppEnvironment.self) private var env
    @Environment(\.islandSize) private var size
    let rows: [SessionRow]

    private static let titleLeading = IslandTheme.Metrics.rowGlyphColumn + IslandTheme.Metrics.rowGlyphGap

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("Codex").foregroundStyle(palette.toneText(IslandTheme.agentCodex))
                Text("\(rows.count)").monospacedDigit().foregroundStyle(palette.groupCount)
            }
            .font(Fonts.sys(size.text(11), .semibold))
            .frame(height: size.line(22, for: 11))
            .padding(.leading, Self.titleLeading)
            .accessibilityElement(children: .combine)
            ForEach(rows) { row in
                HStack(spacing: 0) {
                    dot(row).frame(width: IslandTheme.Metrics.rowGlyphColumn, alignment: .center)
                        .frame(width: Self.titleLeading, alignment: .leading)
                    // A title can be a first prompt of up to 200 characters: it is cut at the tail inside the island
                    // (its whole text on hover), and the short status keeps its place (P209).
                    RowTitleLine.text(row, size: size.text(11), palette: palette).lineLimit(1).truncationMode(.tail)
                        .help(SessionRowText.titleHelp(row))
                    Text(SessionListLayout.groupStatus(row, now: env.sessions.now))
                        .foregroundStyle(palette.ink2).lineLimit(1).fixedSize()
                        .padding(.leading, 6)
                }
                .font(Fonts.sys(size.text(11)))
                .frame(height: size.line(24, for: 11))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    @ViewBuilder private func dot(_ row: SessionRow) -> some View {
        if row.bucket == .done {
            Circle().strokeBorder(palette.idleMark, lineWidth: 1.5).frame(width: 7, height: 7)
        } else {
            Circle().fill(GlyphPalette.colour(agent: row.agent, state: row.glyphState, mode: env.settings.glyphColour, needsYou: needsYou,
                                              idle: palette.idleMark, palette: palette))
                .frame(width: 7, height: 7)
        }
    }
}

/// Clean footer (11/20 `#7A7A7A`): marks for the active rows the four rows hide, then "Show N more", or "Earlier" alone
/// when it hides only older finished ones (`IslandFooterLabel`).
struct CleanFooter: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @Environment(AppEnvironment.self) private var env
    let layout: IslandListLayout
    var action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                ForEach(Array(layout.footerMarks.enumerated()), id: \.offset) { _, mark in
                    switch mark {
                    case let .running(agent):
                        // Liquid and Sand draw at 14 pt, the smallest they read at (the 20 pt footer has room).
                        StateGlyphView(glyph: .eq, colour: GlyphPalette.glyph(agent: agent, state: .running, mode: env.settings.glyphColour,
                                                                              needsYou: needsYou),
                                       pixel: 1.5, glow: false, animated: false, frameOffset: 3, engineSide: 14)
                    case let .delegating(agent):
                        StateGlyphView(glyph: .agents, colour: GlyphPalette.glyph(agent: agent, state: .delegating, mode: env.settings.glyphColour,
                                                                                 needsYou: needsYou),
                                       pixel: 1.5, glow: false, animated: false, engineSide: 14)
                    case .idle:
                        Circle().strokeBorder(palette.idleMark, lineWidth: 1.5).frame(width: 6, height: 6)
                    }
                }
                Text(verbatim: layout.footer.text)
            }
            .font(Fonts.num(11, .regular))
            .foregroundStyle(hovering ? palette.footerHover : palette.footer)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(layout.footer.spoken)
    }
}

/// Detailed footer: a full-width 500 11/28 button, worded like Clean's ("Show N more", "Earlier").
struct DetailedFooter: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let label: IslandFooterLabel
    var action: @MainActor () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: label.text)
                .font(Fonts.sys(11, .medium))
                .foregroundStyle(hovering ? palette.footerHover : palette.footer)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(label.spoken)
    }
}
