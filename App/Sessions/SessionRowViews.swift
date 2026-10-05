import JuiceCore
import SwiftUI

/// Session rows (prototype L178-215, L497-500): the Detailed row the window and the Detailed island draw, and the
/// Clean row whose one-line form heads Clean island cards. Owner: stream C.

/// A row's glyph: 21 pt (7 × 7 at 3 pt a pixel) in Island › Glyph style, coloured by state or agent (Island › Glyph
/// colour), needs-you glyphs pulse. Liquid and Sand draw a pixel larger each way (24 pt), centred on Pixel's square and
/// laid out as it, so a row keeps its height and layout in every style. Out of view in the window's list, from the
/// start or scrolled away, it holds still until it scrolls back (P89).
struct RowGlyphView: View {
    let row: SessionRow
    var pixel: CGFloat = 3
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @Environment(\.sessionGlyphsAnimated) private var animated
    @State private var scrolledAway = false

    var body: some View {
        StateGlyphView(glyph: row.glyph,
                       colour: GlyphPalette.glyph(agent: row.agent, state: row.glyphState, mode: env.settings.glyphColour,
                                                  needsYou: needsYou, idle: palette.idleMark),
                       pixel: pixel, animated: animated && !row.isStalled, engineSide: pixel * 8)
            .transformEnvironment(\.glyphMotionPaused) { $0 = Self.paused(surfaceHidden: $0, scrolledAway: scrolledAway) }
            .frame(width: pixel * 7, height: pixel * 7)
            .onScrollVisibilityChange(threshold: 0.01) { visible in scrolledAway = !visible }
            .accessibilityHidden(true)
    }

    /// A row's glyph moves only while its surface shows and the row is in the scroll view's visible part.
    nonisolated static func paused(surfaceHidden: Bool, scrolledAway: Bool) -> Bool { surfaceHidden || scrolledAway }
}

/// Sizes of a Detailed row: the window's are a step up from the Detailed island's. `glyphBox` holds the 21 pt glyph,
/// `leading` is the column before the title (the window's is tighter than the prototype's 49).
struct DetailedRowMetrics: Sendable {
    var title: (size: CGFloat, line: CGFloat)
    var status: (size: CGFloat, line: CGFloat)
    var tool: (size: CGFloat, line: CGFloat)
    var glyphBox: CGFloat
    var leading: CGFloat
    /// The agent mark and the age on the right.
    var mark: CGFloat
    var age: CGFloat
    /// The tool line's verb (mono).
    var verb: CGFloat = 11

    static let window = DetailedRowMetrics(title: (13, 19), status: (12, 17), tool: (11.5, 17), glyphBox: 22, leading: 34, mark: 11, age: 11.5)
    static let island = DetailedRowMetrics(title: (12, 18), status: (11, 16), tool: (11, 16), glyphBox: 40, leading: 49, mark: 10, age: 11)

    /// These metrics at Settings › Island › Text size (P402): each line's text and box step with it.
    func scaled(_ size: IslandSize) -> DetailedRowMetrics {
        guard size.delta != 0 else { return self }
        var m = self
        m.title = (size.text(title.size), size.line(title.line, for: title.size))
        m.status = (size.text(status.size), size.line(status.line, for: status.size))
        m.tool = (size.text(tool.size), size.line(tool.line, for: tool.size))
        m.age = size.text(age)
        m.verb = size.text(verb)
        return m
    }
}

/// Glyph, then the agent's mark and the title / status / tool line, then on the right only the age, as the island's
/// rows. Where the session runs (terminal, account) is in the tooltip; the jump key's tag shows on hover or while ⌃ is
/// held.
struct DetailedRowView: View {
    let row: SessionRow
    var metrics: DetailedRowMetrics = .window
    /// Line 2 and the tool line (a card header in the window keeps them; the prototype always does). Without them (a
    /// brief Done card's header) the glyph centres on the title, as the Clean row's one-line form.
    var showsStatus = true
    var jumpHint: String?
    /// Line 2 in place of the row's own (a card's header reads "Needs approval · Bash": its content is right below).
    var status: SessionRowText.DetailedStatus?
    /// The branch before the age (P434): the window's list rows only; a card's header leaves it to the card (an
    /// approval's reason line names it).
    var showsBranch = false
    @Environment(AppEnvironment.self) private var env
    @Environment(\.showsShortcutHints) private var showsHints
    /// An island card's header draws the theme's greys (P557); the window sets no theme and stays Black.
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @State private var hovered = false

    var body: some View {
        HStack(alignment: showsStatus ? .top : .center, spacing: 0) {
            RowGlyphView(row: row)
                .frame(width: metrics.glyphBox)
                .padding(.top, showsStatus ? 3 : 0)
                .frame(width: metrics.leading, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    RowTitleLine(row: row, size: metrics.title.size, markSize: metrics.mark)
                    // The branch on the title's line only, at its end, so the status and tool lines keep their room.
                    if showsBranch, let branch = row.branch {
                        Spacer(minLength: 0)
                        RowBranchTag(branch: branch, font: Fonts.sys(metrics.age - 0.5), colour: palette.rowAge,
                                     height: metrics.title.line, maxWidth: 120)
                    }
                }
                .lineBox(metrics.title.line)
                if showsStatus {
                    statusLine
                    toolLine
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }

    /// Line 2 and the tool line, a compacting row's time moving while it compacts (P433).
    @ViewBuilder private var statusLine: some View {
        // The time is on line 2 without a prompt, else on the tool line (`SessionRowText.toolLine`).
        let prompted = SessionRowText.shownPrompt(row) != nil
        CompactionClock(since: row.status == .compacting && status == nil && !prompted ? row.compactingSince : nil) { now in
            statusLine(now: now)
        }
    }

    @ViewBuilder private func statusLine(now: Date?) -> some View {
        let status = self.status ?? SessionRowText.detailedStatus(row, now: now)
        if status.word != nil || status.text != nil {
            Self.statusText(status, palette: palette, needsYou: needsYou)
                .font(Fonts.sys(metrics.status.size))
                .lineLimit(1).truncationMode(.tail)
                .lineBox(metrics.status.line)
                .help(Self.statusHelp(status))
        }
    }

    /// The whole of line 2 as a tooltip when it may be cut ("Done · Wrote docs/release-checklist.md with 12 steps.
    /// The signing step…"); nothing for a short line.
    static func statusHelp(_ status: SessionRowText.DetailedStatus, limit: Int = 48) -> String {
        let text = [status.word, status.text.map { (status.isPrompt ? "You: " : "") + $0 }].compactMap { $0 }.joined(separator: " · ")
        return text.count > limit ? text : ""
    }

    static func statusText(_ status: SessionRowText.DetailedStatus, palette: IslandPalette = .black, needsYou: NeedsYouColour) -> Text {
        var runs = TextRuns()
        if let word = status.word {
            let colour: Color = switch status.tone {
            case .approval: palette.toneText(needsYou.wait)
            case .done: palette.toneText(IslandTheme.done)
            case .muted: palette.you
            case .stalled: palette.toneText(IslandTheme.stalled)
            }
            runs.add(word, colour)
            if status.text != nil { runs.add(" · ", palette.statusDetailed) }
        }
        if let text = status.text {
            if status.isPrompt { runs.add("You: ", palette.you) }
            runs.add(text, palette.statusDetailed)
        }
        return runs.text
    }

    @ViewBuilder private var toolLine: some View {
        let prompted = SessionRowText.shownPrompt(row) != nil
        CompactionClock(since: row.status == .compacting && prompted ? row.compactingSince : nil) { now in
            toolLine(now: now)
        }
    }

    @ViewBuilder private func toolLine(now: Date?) -> some View {
        if let line = SessionRowText.toolLine(row, now: now) {
            HStack(spacing: 4) {
                if let verb = line.verb {
                    Text(verb).font(Fonts.mono(metrics.verb)).foregroundStyle(palette.toolVerb).fixedSize()
                }
                Text(line.text).font(Fonts.sys(metrics.tool.size)).foregroundStyle(palette.toolLine)
                    .lineLimit(1).truncationMode(.tail)
            }
            .lineBox(metrics.tool.line)
        }
    }

    /// The jump tag (on hover or while ⌃ is held, only on the row the key targets) and the age, which becomes the
    /// archive button on hover, on a finished row only: archiving a session that waits on an approval or a question
    /// would hide it while its agent waits, and a card's header never offers it (P131).
    private var trailing: some View {
        HStack(spacing: 5) {
            if let jumpHint, hovered || showsHints {
                Text("\(jumpHint) ↗").foregroundStyle(palette.jump)
            }
            if hovered, row.canArchive {
                Button { env.sessions.dismiss(row.id) } label: { ArchiveIcon(colour: theme.adapts ? palette.idleMark : ArchiveIcon.grey) }
                    .buttonStyle(.plain)
                    .help("Archive")
                    .accessibilityLabel("Archive")
            } else {
                // A remote session's host (P745), before its age.
                if let host = row.remoteHost { Text(host).font(Fonts.sys(metrics.age)).foregroundStyle(palette.rowAge).padding(.trailing, 3) }
                Text(SessionRowText.age(row.updatedAt, now: env.sessions.now)).foregroundStyle(palette.rowAge)
                    .help(SessionListLayout.rowHelp(row))
            }
        }
        .font(Fonts.num(metrics.age, .regular))
        .lineBox(metrics.title.line)
        .padding(.leading, 12)
        .fixedSize()
    }
}

/// The Clean row (`.sr.c`): the agent's mark, then `repo · title` (12/18, the repo grey, the title 600), one short
/// status (11/17 #9A9A9A), and on the right the age. `oneLine`: the title only, centred on the glyph. `cardStatus`: a
/// card header's own short line 2 ("Needs approval · Bash") in place of the row's.
struct CleanRowView: View {
    let row: SessionRow
    var oneLine = false
    var jumpHint: String?
    var cardStatus: SessionRowText.DetailedStatus?
    @Environment(AppEnvironment.self) private var env
    /// Settings › Island › Text size (P402): as the list's rows, so a tapped row and its card's header match.
    @Environment(\.islandSize) private var size
    /// An island card's header draws the theme's greys (P557).
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @State private var hovered = false

    var body: some View {
        HStack(alignment: oneLine ? .center : .top, spacing: 0) {
            RowGlyphView(row: row)
                .frame(width: 40)
                .padding(.top, oneLine ? 0 : 7)
                .frame(width: 49, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                RowTitleLine(row: row, size: size.text(12), markSize: Theme.Mark.sessionRow).lineBox(size.line(18, for: 12))
                if !oneLine {
                    // The list row's Show branch and Show model tags too (P1015), so a tapped row and its header match.
                    let shown = CleanRowShown(row, settings: env.settings)
                    HStack(spacing: 12) {
                        Group {
                            if let cardStatus { DetailedRowView.statusText(cardStatus, palette: palette, needsYou: needsYou).font(Fonts.sys(size.text(11))) } else { status }
                        }
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .keepsWhole(shown.isEmpty ? nil : cardStatus?.word ?? SessionRowText.cleanStatus(row).word,
                                    font: Fonts.sys(size.text(11)))
                        if !shown.isEmpty { CleanRowTags(shown: shown).layoutPriority(1) }
                    }
                    .lineBox(size.line(17, for: 11))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 5) {
                if hovered, let jumpHint {
                    Text("\(jumpHint) ↗").foregroundStyle(palette.jump)
                } else {
                    if let host = row.remoteHost { Text(host).font(Fonts.sys(size.text(11))).foregroundStyle(palette.rowAge).padding(.trailing, 3) }
                    Text(SessionRowText.age(row.updatedAt, now: env.sessions.now)).foregroundStyle(palette.rowAge)
                }
            }
            .font(Fonts.num(size.text(11), .regular))
            .padding(.leading, 12)
            .lineBox(size.line(18, for: 12))
            .fixedSize()
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }

    private var status: Text {
        let status = SessionRowText.cleanStatus(row)
        let type = size.text(11)
        var runs = TextRuns()
        if let word = status.word {
            runs.add(word, status.tone == .plain ? palette.you : palette.toneText(status.tone == .stalled ? IslandTheme.stalled : needsYou.wait),
                     size: type)
            if status.text != nil || status.toolVerb != nil { runs.add(" · ", palette.statusClean, size: type) }
        }
        if let verb = status.toolVerb { runs.add(verb + " ", palette.toolVerb, size: type, mono: true) }
        if let text = status.text { runs.add(text, palette.statusClean, size: type) }
        return runs.text
    }
}

/// A row's line 1: the agent's mark in its colour (its tooltip whose session it is and where it runs), then the title,
/// after the repo in grey when `showsProject` (`SessionRowText.cleanTitle`: never when the title is the repo). The
/// mark is the row's one word on whose it is (P204, P208); a long title's whole text is its tooltip.
struct RowTitleLine: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let row: SessionRow
    var size: CGFloat
    var markSize: CGFloat
    var showsProject = true

    var body: some View {
        HStack(spacing: 5) {
            AgentMarkView(agent: row.agent, size: markSize, theme: theme)
                .help(SessionListLayout.rowHelp(row, naming: !showsProject))
            Self.text(row, size: size, showsProject: showsProject, palette: palette)
                .lineLimit(1).truncationMode(.tail)
                .help(SessionRowText.titleHelp(row, showsProject: showsProject))
        }
    }

    static func text(_ row: SessionRow, size: CGFloat, showsProject: Bool = true, palette: IslandPalette = .black) -> Text {
        let parts = SessionRowText.cleanTitle(row)
        var runs = TextRuns()
        if showsProject, let project = parts.project { runs.add(project + " · ", palette.ink2, size: size) }
        runs.add(parts.task, palette.ink, weight: .semibold, size: size)
        return runs.text
    }
}
