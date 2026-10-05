import IslandHookNotes
import JuiceCore
import OpenIslandCore
import SwiftUI
import WidgetKit

/// The widget's three sizes (WidgetKit's system small, medium and large).
enum WidgetFace: String, CaseIterable, Sendable {
    case small, medium, large
}

/// What a face holds in its content size: the batteries' height (and, large, their scale), and how many rows fit above
/// them; the rest are counted ("2 more"). Rows are cut, never squeezed: a row that needs you is its title and its
/// card's line, a running row its title.
struct WidgetLayout: Equatable, Sendable {
    var rows: Int
    var hidden: Int
    var batteries: Batteries

    enum Batteries: Equatable, Sendable {
        case none
        /// Bare shapes: both providers on one line, or one line each when one line is too narrow.
        case mini(oneLine: Bool)
        /// The panel's batteries, shrunk to the width when needed (never grown).
        case full(scale: CGFloat)
    }

    static func make(_ snapshot: WidgetSnapshot, face: WidgetFace, size: CGSize) -> WidgetLayout {
        typealias M = WidgetMetrics
        let providers = [snapshot.claude, snapshot.codex].filter { !$0.isEmpty }
        let batteries: Batteries
        if providers.isEmpty {
            batteries = .none
        } else if face == .large {
            batteries = .full(scale: min(1, size.width / WidgetBatteryBlock.naturalWidth))
        } else {
            let oneLine = face == .medium
                && MiniBatteryRow.width(snapshot.claude.count) + M.miniProviderGap + MiniBatteryRow.width(snapshot.codex.count) <= size.width
            batteries = .mini(oneLine: oneLine || providers.count == 1)
        }
        let batteryHeight: CGFloat = switch batteries {
        case .none: 0
        case let .mini(oneLine): (oneLine ? 1 : CGFloat(providers.count)) * MiniBatteryRow.height
            + (oneLine ? 0 : CGFloat(providers.count - 1) * M.miniRowGap)
        case let .full(scale): WidgetBatteryBlock.height(providers.count) * scale
        }
        let room = size.height - (batteryHeight > 0 ? batteryHeight + M.batteryGap : 0)
        let total = snapshot.rows.count + snapshot.more
        var shown = 0
        var used: CGFloat = 0
        for row in snapshot.rows {
            let next = used + (shown > 0 ? M.rowGap : 0) + M.height(row)
            let rest = total - shown - 1
            guard next + (rest > 0 ? M.moreHeight : 0) <= room else { break }
            used = next
            shown += 1
        }
        return WidgetLayout(rows: shown, hidden: total - shown, batteries: batteries)
    }
}

/// The widget's measures: the island's row type and heights, its battery rows.
enum WidgetMetrics {
    static let rowGap: CGFloat = 6
    static let moreHeight: CGFloat = 18
    static let batteryGap: CGFloat = 8
    static let miniRowGap: CGFloat = 5
    static let miniProviderGap: CGFloat = 16
    static let glyphColumn = IslandTheme.Metrics.rowGlyphColumn
    static let glyphGap: CGFloat = 8
    /// The small face's glyph column and gap.
    static let compactColumn: CGFloat = 12
    static let compactGap: CGFloat = 6

    static func height(_ row: WidgetSnapshot.Row) -> CGFloat {
        IslandTheme.Metrics.rowTitleHeight + (row.kind == .needsYou && row.word != nil ? IslandTheme.Metrics.rowStatusHeight : 0)
    }

    /// Where a row's text starts: the "N more" line lines up with the titles.
    static func textInset(compact: Bool) -> CGFloat { compact ? compactColumn + compactGap : glyphColumn + glyphGap }
}

/// The widget (spec §4.7): the island's opened card on the desktop. Needs you first (the glyph, the agent's mark in its
/// colour, the chat's title, and the card's status line: "Needs approval · Bash", "Question"), then what runs (glyph,
/// mark, title), then the Claude and Codex batteries. On the island's surface, Black or Glass (`WidgetBackground`), in
/// that theme's greys; nothing moves (glyphs are still).
/// With the desktop's tinted or vibrant look (`tinted`), the system takes the surface away and draws in one colour, so
/// every state is also a shape: "!", "?" and "×" for what needs you, the equalizer for what runs, and the battery's own
/// shapes (P346). Each row of the medium and large faces is a link to its session (`WidgetLink`); the small face is one
/// tap target (`IslandWidgetEntryView.tapLink`).
struct IslandWidgetView: View {
    let snapshot: WidgetSnapshot?
    let face: WidgetFace
    /// The content's size (the widget less its margins): what fits is measured against it (`WidgetLayout`).
    var size: CGSize
    /// The timeline entry's date: a used-up battery's refill counts against it.
    var date: Date
    var tinted = false
    /// nil (renders, the gallery's placeholder): rows are not links.
    var scheme: String?
    /// The greys in full colour: Black's own, or Glass's lifted ones (the snapshot's theme, P543).
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }

    private typealias M = WidgetMetrics

    /// Nothing runs or waits: what the island's finished rows do not contradict.
    static let idleText = "Nothing running"

    var body: some View {
        Group {
            if let snapshot, snapshot.appRunning {
                running(snapshot, WidgetLayout.make(snapshot, face: face, size: size))
            } else {
                notRunning
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.sessionGlyphsAnimated, false)
    }

    // MARK: Faces

    private func running(_ snapshot: WidgetSnapshot, _ layout: WidgetLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if snapshot.rows.isEmpty {
                Text(Self.idleText)
                    .font(Fonts.sys(11))
                    .foregroundStyle(tone(palette.ink3, 0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: M.rowGap) {
                    ForEach(snapshot.rows.prefix(layout.rows)) { row in
                        link(row) { WidgetRowView(row: row, snapshot: snapshot, compact: face == .small, tinted: tinted) }
                    }
                }
                if layout.hidden > 0 {
                    Text("\(layout.hidden) more")
                        .font(Fonts.sys(11))
                        .foregroundStyle(tone(palette.footer, 0.6))
                        .padding(.leading, M.textInset(compact: face == .small))
                        .frame(height: M.moreHeight, alignment: .bottom)
                }
                Spacer(minLength: 0)
            }
            batteries(snapshot, layout.batteries)
        }
    }

    private var notRunning: some View {
        VStack(spacing: 8) {
            PixelGlyphView(glyph: .brand, colour: tinted ? .white : palette.tone(IslandTheme.brand), pixel: face == .small ? 3 : 4,
                           dimmed: true, glow: false, animated: false)
            Text("Not running")
                .font(Fonts.sys(11))
                .foregroundStyle(tone(palette.ink3, 0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func batteries(_ snapshot: WidgetSnapshot, _ batteries: WidgetLayout.Batteries) -> some View {
        switch batteries {
        case .none:
            EmptyView()
        case let .mini(oneLine):
            let rows = Group {
                if !snapshot.claude.isEmpty { MiniBatteryRow(provider: .claude, batteries: snapshot.claude, tinted: tinted) }
                if !snapshot.codex.isEmpty { MiniBatteryRow(provider: .codex, batteries: snapshot.codex, tinted: tinted) }
            }
            Group {
                if oneLine { HStack(spacing: M.miniProviderGap) { rows } } else { VStack(alignment: .leading, spacing: M.miniRowGap) { rows } }
            }
            .padding(.top, M.batteryGap)
        case let .full(scale):
            WidgetBatteryBlock(snapshot: snapshot, date: date, tinted: tinted)
                // The panel's battery draws in its own colours; one colour in the tinted look, as the rest.
                .grayscale(tinted ? 1 : 0)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: WidgetBatteryBlock.naturalWidth * scale,
                       height: WidgetBatteryBlock.height([snapshot.claude, snapshot.codex].filter { !$0.isEmpty }.count) * scale,
                       alignment: .topLeading)
                .padding(.top, M.batteryGap)
        }
    }

    @ViewBuilder private func link(_ row: WidgetSnapshot.Row, @ViewBuilder content: () -> some View) -> some View {
        if face != .small, let scheme, let url = WidgetLink.session(row.id).url(scheme: scheme) {
            Link(destination: url) { content() }
        } else {
            content()
        }
    }

    private func tone(_ colour: Color, _ opacity: Double) -> Color { tinted ? .white.opacity(opacity) : colour }
}

/// One row: the glyph (still), then the agent's mark and the chat's title, and for a row that needs you the card's
/// status line under it, its word in the needs-you colour the app wrote (`WidgetSnapshot.needsYou`).
struct WidgetRowView: View {
    let row: WidgetSnapshot.Row
    let snapshot: WidgetSnapshot
    var compact = false
    var tinted = false
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }

    private typealias M = WidgetMetrics

    var body: some View {
        HStack(alignment: .top, spacing: compact ? M.compactGap : M.glyphGap) {
            glyph.frame(height: M.height(row))
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 5) {
                    if let agent = Self.agent(row.agent) { mark(agent) }
                    Text(row.title)
                        .font(Fonts.sys(12, .semibold))
                        .foregroundStyle(tinted ? .white : palette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(height: IslandTheme.Metrics.rowTitleHeight)
                if row.kind == .needsYou, let word = row.word {
                    status(word: word, detail: row.detail).frame(height: IslandTheme.Metrics.rowStatusHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: M.height(row))
        .accessibilityElement(children: .combine)
    }

    /// The island row's glyph, still: Pixel at 2 pt pixels in its 16 pt column (1.5 pt in the small face's 12 pt one),
    /// Liquid and Sand at the island's engine size, centred on the column.
    @ViewBuilder private var glyph: some View {
        let pixel: CGFloat = compact ? 1.5 : IslandTheme.Metrics.rowGlyphPixel
        let engine: CGFloat = compact ? 15 : IslandTheme.Metrics.rowGlyphEngine
        let column = compact ? M.compactColumn : M.glyphColumn
        let style = GlyphStyle(rawValue: snapshot.glyphStyle) ?? .pixel
        let side = StateGlyphView.side(style: style, pixel: pixel, engineSide: engine)
        StateGlyphView(glyph: PixelGlyph(rawValue: row.glyph) ?? (row.kind == .needsYou ? .bang : .eq),
                       colour: glyphColour, pixel: pixel, glow: false, animated: false, style: style, engineSide: engine,
                       liquidRunning: snapshot.runningLook)
            .frame(width: side, height: side)
            .frame(width: column, height: min(side, column))
            .widgetAccentable(row.kind == .needsYou)
            // The system's looks draw the glyph in one tint: plain in either theme, so no edge joins it (P597).
            .transformEnvironment(\.juiceTheme) { if tinted { $0 = .black } }
    }

    private var glyphColour: Color {
        if tinted { return .white }
        let mode = GlyphColourMode(rawValue: snapshot.glyphColour) ?? .byState
        // A running row whose main agent waits on its subagents carries the delegate's glyph, and its teal (P370).
        let state: GlyphPalette.State = row.kind == .needsYou ? .waiting : row.glyph == PixelGlyph.agents.rawValue ? .delegating : .running
        guard let agent = Self.agent(row.agent) else {
            return GlyphPalette.glyph(agent: .claude, state: state, mode: .byState, needsYou: snapshot.needsYou)
        }
        return GlyphPalette.glyph(agent: agent, state: state, mode: mode, needsYou: snapshot.needsYou)
    }

    /// The agent's mark in its colour; one colour in the tinted look, where its shape says whose it is.
    @ViewBuilder private func mark(_ agent: GlyphPalette.Agent) -> some View {
        let size = Theme.Mark.sessionRow
        if tinted {
            switch AgentLook.of(agent).mark {
            case .claude: ProviderMarkView(provider: .claude, size: size, tint: .white)
            case .openAI: ProviderMarkView(provider: .codex, size: size, tint: .white)
            case let mark: AgentShapeMark(mark: mark, side: size, ink: .white)
            }
        } else {
            AgentMarkView(agent: agent, size: size, theme: theme)
        }
    }

    private func status(word: String, detail: String?) -> some View {
        HStack(spacing: 0) {
            // The word stays whole; what follows it gives way.
            Text(word)
                .foregroundStyle(tinted ? .white : palette.toneText(snapshot.needsYou.wait))
                .widgetAccentable()
                .layoutPriority(1)
            if let detail {
                Text(" · " + detail).foregroundStyle(tinted ? .white.opacity(0.6) : palette.statusClean)
            }
        }
        .font(IslandTheme.TypeScale.cleanLine2)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// The row's agent from its snapshot key; nil for one this build's engine does not know (no mark then).
    static func agent(_ key: String) -> GlyphPalette.Agent? {
        switch key {
        case "claude": return .claude
        case "codex": return .codex
        default:
            if key.hasPrefix("kind:") { return AgentKind(rawValue: String(key.dropFirst(5))).map { GlyphPalette.Agent.kind($0) } }
            return AgentTool(rawValue: key).map { GlyphPalette.Agent.other($0) }
        }
    }
}

/// The large face's batteries: the island's own rows (a provider's mark, then its batteries as the panel draws them,
/// digits and all), at their natural size; the face shrinks them to its width (`WidgetLayout.Batteries.full`).
struct WidgetBatteryBlock: View {
    let snapshot: WidgetSnapshot
    var date: Date
    var tinted = false
    @Environment(\.juiceTheme) private var theme

    static let markSize = Theme.Mark.strip
    static let markGap: CGFloat = 8
    /// A battery and the "next" bar under it.
    static let rowHeight: CGFloat = 24
    /// Room for the in-use dot over the Codex row's battery, nearer its own battery than the Claude one above (P815).
    static let rowGap: CGFloat = 10

    /// A row's natural width: the mark, then six batteries (the most a row holds on the owner's Mac).
    static var naturalWidth: CGFloat { markSize + markGap + 6 * Theme.Battery.cellWidth + 5 * Theme.Battery.gap }

    static func height(_ rows: Int) -> CGFloat { CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * rowGap }

    var body: some View {
        let rows = [(Provider.claude, snapshot.claude), (Provider.codex, snapshot.codex)].filter { !$0.1.isEmpty }
        VStack(alignment: .leading, spacing: Self.rowGap) {
            ForEach(rows, id: \.0) { provider, batteries in
                HStack(spacing: Self.markGap) {
                    ProviderMarkView(provider: provider, size: Self.markSize, tint: tinted ? .white : nil, theme: theme)
                    HStack(spacing: Theme.Battery.gap) {
                        ForEach(Array(batteries.enumerated()), id: \.offset) { index, battery in
                            BatteryView(battery: battery.model(index, provider: provider), now: date, theme: tinted ? .black : theme,
                                        inUse: battery.showsInUse)
                        }
                    }
                }
                .frame(height: Self.rowHeight, alignment: .top)
            }
        }
        .frame(width: Self.naturalWidth, alignment: .leading)
        // The system's looks draw Black's batteries in either theme: no glass well or knocked-out cut under the one
        // colour (P542, P545).
        .transformEnvironment(\.juiceTheme) { if tinted { $0 = .black } }
    }
}

/// The small and medium faces' batteries: a provider's mark and its batteries as bare shapes, too small for digits.
/// Each state is still its own shape (Juice spec §2.2): a fill for what is left (amber when low), an empty body when
/// used up, a dashed one to sign in, a faint fill when not read lately, and a dotted edge round the empty track when
/// not known (the panel's "?" has no room here).
struct MiniBatteryRow: View {
    let provider: Provider
    let batteries: [WidgetSnapshot.Battery]
    var tinted = false
    @Environment(\.juiceTheme) private var theme

    static let size = CGSize(width: 15, height: 8)
    static let nub: CGFloat = 1.5
    static let gap: CGFloat = 3.5
    static let markGap: CGFloat = 5
    static let height: CGFloat = Theme.Mark.sessionRow
    /// The in-use dot over a battery (P815), and how far over its top.
    static let inUseDot: CGFloat = 2
    static let inUseDotAbove: CGFloat = 1

    static func width(_ count: Int) -> CGFloat {
        guard count > 0 else { return 0 }
        return Theme.Mark.sessionRow + markGap + CGFloat(count) * (size.width + nub) + CGFloat(count - 1) * gap
    }

    var body: some View {
        HStack(spacing: Self.markGap) {
            ProviderMarkView(provider: provider, size: Theme.Mark.sessionRow, tint: tinted ? .white : nil, theme: theme)
            HStack(spacing: Self.gap) {
                ForEach(Array(batteries.enumerated()), id: \.offset) { _, battery in
                    MiniBattery(battery: battery, tinted: tinted)
                }
            }
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.displayName + ": "
            + batteries.map { $0.showsInUse ? $0.accessibilityText + ", in use" : $0.accessibilityText }.joined(separator: ", "))
    }
}

struct MiniBattery: View {
    let battery: WidgetSnapshot.Battery
    var tinted = false
    /// Full colour's ink, outline and empty body: Black's own, or Glass's (its track a white veil, P543).
    @Environment(\.juiceTheme) private var theme
    private var panel: PanelPalette { theme.panel }

    private var size: CGSize { MiniBatteryRow.size }
    private var line: Color { tinted ? .white.opacity(0.8) : panel.line }
    private var ink: Color { tinted ? .white : panel.ink }
    private var track: Color { tinted ? Color.white.opacity(0.12) : panel.track }

    var body: some View {
        ZStack(alignment: .leading) {
            switch battery.state {
            case let .available(left, low):
                filled(left, colour: low && !tinted ? panel.tone(Theme.warn) : ink)
            case let .stale(last):
                filled(last ?? 0, colour: ink.opacity(0.35))
            case .usedUp:
                RoundedRectangle(cornerRadius: 2.5).strokeBorder(line, lineWidth: 1)
            case .noPlan, .noLimits:
                RoundedRectangle(cornerRadius: 2.5).strokeBorder(line.opacity(BatteryView.noPlanOpacity), lineWidth: 1)
            case .unknown:
                RoundedRectangle(cornerRadius: 2.5).fill(track)
                    .overlay(RoundedRectangle(cornerRadius: 2.5)
                        .strokeBorder(line, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [0.01, 2.2])))
            case .signIn, .signingIn:
                RoundedRectangle(cornerRadius: 2.5).strokeBorder(line, style: StrokeStyle(lineWidth: 1, dash: [1.5, 1.5]))
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .trailing) {
            Rectangle().fill(line).frame(width: MiniBatteryRow.nub, height: 3.5).offset(x: MiniBatteryRow.nub)
        }
        .padding(.trailing, MiniBatteryRow.nub)
        // The account in use (P815): the panel's dot, to this battery's scale.
        .overlay(alignment: .top) {
            if battery.showsInUse {
                Circle().fill(ink)
                    .frame(width: MiniBatteryRow.inUseDot, height: MiniBatteryRow.inUseDot)
                    .offset(x: -MiniBatteryRow.nub / 2, y: -(MiniBatteryRow.inUseDotAbove + MiniBatteryRow.inUseDot))
            }
        }
    }

    private func filled(_ percent: Int, colour: Color) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2.5).fill(track)
            RoundedRectangle(cornerRadius: 1.2)
                .fill(colour)
                .frame(width: max(percent > 0 ? 1.5 : 0, (size.width - 3) * CGFloat(min(max(percent, 0), 100)) / 100),
                       height: size.height - 3)
                .padding(.leading, 1.5)
            RoundedRectangle(cornerRadius: 2.5).strokeBorder(line, lineWidth: 1)
        }
    }
}
