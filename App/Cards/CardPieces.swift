import IslandEngine
import SwiftUI

/// The pieces every card shares. Owner: stream C.

/// A card's box: #121214 with a 1 pt #232326 edge (none for a message), r8. As tall as its content up to
/// `maxHeight`; content taller than that scrolls, with a fade at its foot while more is below: what the owner approves
/// is never cut. Content that fits is drawn plain, without a scroll view, so every renderer draws it (`ImageRenderer`
/// leaves AppKit-backed views blank).
struct CardScrollBox<Content: View>: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    var maxHeight: CGFloat
    var bordered = true
    var insets = EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11)
    @ViewBuilder var content: Content
    /// The content is taller than the box: it scrolls.
    @State private var overflows = false
    @State private var moreBelow = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        Group {
            if overflows {
                ScrollView(.vertical) { padded }
                    .scrollBounceBehavior(.basedOnSize)
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
                    } action: { _, more in
                        moreBelow = more
                    }
                    .frame(height: maxHeight)
            } else {
                CappedHeight(maxHeight: maxHeight) { padded }.clipped()
            }
        }
        .overlay(alignment: .bottom) {
            if overflows, moreBelow {
                LinearGradient(colors: [palette.codeBg.opacity(0), palette.codeBg], startPoint: .top, endPoint: .bottom)
                    .frame(height: 18)
                    .allowsHitTesting(false)
            }
        }
        .background(palette.codeBg, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(bordered ? palette.codeBorder : .clear, lineWidth: 1))
    }

    private var padded: some View {
        // The cap alone goes into the geometry closure, not the view (its content's type is not Sendable).
        let cap = maxHeight
        return content
            .padding(insets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: Bool.self) { $0.size.height > cap + 0.5 } action: { overflows = $0 }
    }

    /// The box's height for `lines` lines `lineHeight` apart, with its insets.
    static func height(lines: Int, lineHeight: CGFloat, insets: EdgeInsets = EdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11)) -> CGFloat {
        CGFloat(lines) * lineHeight + insets.top + insets.bottom
    }
}

/// Its one view at its full height for the width offered, reported at most `maxHeight` tall (the rest is clipped by
/// the caller): a box as tall as its content, up to a cap, that still measures the whole content.
struct CappedHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: min(size.height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

/// The command: mono 12/1.45, whole and as written, wrapping; past `maxLines` lines it scrolls (`CardScrollBox`). A
/// one-line command's trailing `# comment` is grey.
struct CodeBlockView: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let code: String
    var maxLines = 8
    /// Settings › Island › Text size (P402); the standard size in the window.
    @Environment(\.islandSize) private var islandSize

    static let lineHeight: CGFloat = 12 * 1.45

    var body: some View {
        let (command, comment) = Self.split(code)
        var runs = TextRuns()
        runs.add(command, palette.codeText)
        if let comment { runs.add(" " + comment, palette.codeComment) }
        let size = islandSize.text(12), line = size * 1.45
        return CardScrollBox(maxHeight: CardScrollBox<EmptyView>.height(lines: maxLines, lineHeight: line)) {
            runs.text
                .font(Fonts.mono(size))
                .cssLines(size: size, lineHeight: line, mono: true)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `git push … # why` → the command and the comment; a command of several lines is kept whole.
    static func split(_ code: String) -> (String, String?) {
        guard !code.contains(where: \.isNewline), let range = code.range(of: " # ") else { return (code, nil) }
        return (String(code[..<range.lowerBound]), String(code[code.index(after: range.lowerBound)...]))
    }
}

/// A change, file by file: the path (mono 600) with "+3 −1" on the right, then the lines, added green, removed red,
/// one unchanged line either side in grey, a longer unchanged run as "⋯". Past `maxLines` lines it scrolls; lines the
/// card left out are counted at the end.
struct DiffBlockView: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let files: [FileDiff]
    var maxLines = 8
    /// Settings › Island › Text size (P402); the standard size in the window.
    @Environment(\.islandSize) private var islandSize

    static let size: CGFloat = 11.5
    static let lineHeight: CGFloat = 16

    private var size: CGFloat { islandSize.text(Self.size) }
    private var lineHeight: CGFloat { islandSize.line(Self.lineHeight, for: Self.size) }
    private var small: CGFloat { islandSize.text(10.5) }

    var body: some View {
        CardScrollBox(maxHeight: CardScrollBox<EmptyView>.height(lines: maxLines, lineHeight: lineHeight)) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(files.enumerated()), id: \.offset) { index, file in
                    header(file).padding(.top, index == 0 ? 0 : 8)
                    ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in row(line) }
                    if file.omitted > 0 {
                        Text("\(file.omitted) more \(file.omitted == 1 ? "line" : "lines")")
                            .font(Fonts.sys(small)).foregroundStyle(palette.ink3).lineBox(lineHeight)
                    }
                }
            }
        }
    }

    private func header(_ file: FileDiff) -> some View {
        HStack(spacing: 8) {
            Text(file.path).font(Fonts.mono(size, .semibold)).foregroundStyle(palette.codeText)
                .lineLimit(1).truncationMode(.head).help(file.path)
            Spacer(minLength: 0)
            if file.deleted {
                Text("deleted").font(Fonts.sys(small)).foregroundStyle(palette.diffRemoved)
            } else {
                HStack(spacing: 5) {
                    if file.added > 0 { Text("+\(file.added)").foregroundStyle(palette.diffAdded) }
                    if file.removed > 0 { Text("\u{2212}\(file.removed)").foregroundStyle(palette.diffRemoved) }
                }
                .font(Fonts.num(small, .medium)).fixedSize()
            }
        }
        .lineBox(lineHeight + 2)
    }

    @ViewBuilder private func row(_ line: FileDiff.Line) -> some View {
        switch line.kind {
        case .gap:
            Text("\u{22EF}").font(Fonts.mono(size)).foregroundStyle(palette.ink3).lineBox(lineHeight)
        case .added, .removed, .context:
            let (mark, colour, fill): (String, Color, Color) = switch line.kind {
            case .added: ("+", palette.diffAdded, palette.diffAddedFill)
            case .removed: ("\u{2212}", palette.diffRemoved, palette.diffRemovedFill)
            default: (" ", palette.diffContext, .clear)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(mark).font(Fonts.mono(size)).foregroundStyle(colour).frame(width: 8)
                Text(line.text.isEmpty ? " " : line.text)
                    .font(Fonts.mono(size)).foregroundStyle(line.kind == .context ? palette.diffContext : palette.codeText)
                    .cssLines(size: size, lineHeight: lineHeight, mono: true)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4)
            .background(fill)
            .padding(.horizontal, -4)
        }
    }
}

/// An approval's box: the command, the change or the text (`ApprovalBody`).
struct ApprovalBodyView: View {
    let content: ApprovalBody
    var maxLines: Int

    var body: some View {
        switch content {
        case let .command(code), let .text(code): CodeBlockView(code: code, maxLines: maxLines)
        case let .diff(files): DiffBlockView(files: files, maxLines: maxLines + 2)
        }
    }
}

/// The plan: the agent's Markdown (`MessageText.styled`) in a box that scrolls past `maxLines` lines.
struct PlanBlockView: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let plan: String
    var maxLines = 10
    /// Settings › Island › Text size (P402); the standard size in the window.
    @Environment(\.islandSize) private var islandSize

    var body: some View {
        let insets = EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
        let size = islandSize.text(12)
        CardScrollBox(maxHeight: CardScrollBox<EmptyView>.height(lines: maxLines, lineHeight: size * 1.45, insets: insets),
                      bordered: false, insets: insets) {
            Text(MessageText.styled(plan, size: size, codeText: palette.codeText))
                .font(Fonts.sys(size))
                .foregroundStyle(palette.message)
                .cssLines(size: size, lineHeight: size * 1.45)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The agent's Markdown and Codex's directives through `MessageMarkup.lines`, as the plan's box draws them: bold 600,
/// italic, code and cited files in mono #E8E8EC a point smaller; links stay text. A Done card's message is
/// `DoneMessageView` (tables, boxes, links, P430).
enum MessageText {
    /// The message's lines as one attributed string; unstyled runs take the view's font and colour. Under a line limit
    /// only what the lines can show is read: 100 characters a line, more than a card's line holds. `size`: the text's
    /// (12, or Settings › Island › Text size's step of it); code runs are a point smaller.
    static func styled(_ text: String, lineLimit: Int? = nil, size: CGFloat = 12, codeText: Color = IslandTheme.codeText) -> AttributedString {
        var result = AttributedString()
        for (index, line) in MessageMarkup.lines(text, budget: lineLimit.map { $0 * 100 } ?? .max).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            for span in line {
                var run = AttributedString(span.text)
                let weight: Font.Weight = span.style.contains(.bold) ? .semibold : .regular
                if span.style.contains(.mono) {
                    run.font = Fonts.mono(size - 1, weight)
                    run.foregroundColor = codeText
                } else if !span.style.isEmpty {
                    run.font = span.style.contains(.italic) ? Fonts.sys(size, weight).italic() : Fonts.sys(size, weight)
                }
                result += run
            }
        }
        return result
    }
}

/// A card button: h28, r7, 600 12. Its key (⌃A…) shows after the title only while ⌃ is held (`showsShortcutHints`);
/// otherwise it is in the tooltip, after `help` (the full wording when the title is a short form).
/// `fills`: the island's shared-width button (placed by `FlexRowLayout`). On Glass it is the system's interactive glass
/// (`CardGlass`): the primary one prominent, one that refuses clear, the rest regular, at the same size (P640).
struct CardActionButton: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let title: String
    var key: String?
    var help: String?
    /// More in the tooltip, after `help` and before the key, but not what VoiceOver reads (another way to use it).
    var tip: String?
    var primary = false
    /// The answer that refuses (No, Keep planning): Glass's clear glass.
    var refuses = false
    var fills = false
    let action: () -> Void
    @Environment(\.showsShortcutHints) private var showsHints
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7)
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Fonts.sys(12, .semibold)).lineLimit(1).truncationMode(.middle)
                if showsHints, let key {
                    Text(key).font(Fonts.sys(10.5)).foregroundStyle(primary ? palette.kbdOnPrimary : palette.cardKbd).fixedSize()
                }
            }
            .foregroundStyle(primary ? palette.primaryText : palette.ink)
            .padding(.horizontal, fills ? 6 : 12)
            .frame(maxWidth: fills ? .infinity : nil)
            .frame(height: 28)
            .cardControlGround(shape, fill: background, glassFill: glassFill, key: primary)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .cardControlGlass(shape, role: Self.glassRole(primary: primary, refuses: refuses), tint: primary ? palette.primary : nil)
        .onHover { hovered = $0 }
        .help(Self.tooltip(help: help, tip: tip, key: key))
        .accessibilityLabel(help ?? title)
    }

    /// "Yes, allow running git push:* from this project  ⌃⇧A", "⌃A", "⌥-click to say why  ⌃D", or nothing.
    static func tooltip(help: String?, tip: String? = nil, key: String?) -> String {
        [help, tip, key].compactMap { $0 }.joined(separator: "  ")
    }

    /// The glass a card button takes on Glass: the primary answer prominent, the one that refuses clear, any other regular.
    static func glassRole(primary: Bool, refuses: Bool) -> CardGlass.Role {
        primary ? .prominent : refuses ? .clear : .regular
    }

    private var background: Color {
        if primary { return hovered ? palette.primaryHover : palette.primary }
        return hovered ? palette.buttonHover : palette.button
    }

    /// On Glass: the key's face (it keeps its title's contrast whatever the glass under it does); under the pointer the
    /// button's own veil (`button`, the lighter of Glass's two, so a key hint keeps 4:1 on the dark look, P645); or
    /// nothing, so the glass shows.
    private var glassFill: Color? {
        if primary { return hovered ? palette.primaryHover : palette.primary }
        return hovered ? palette.button : nil
    }
}

/// A text field (h30, r7, #141414 with a 1 pt #2B2B2B edge, 12 pt, placeholder #85858A) and a 30 pt send button that
/// turns light while the field has text. Return sends. The typed text lives in this view (and the live island's card
/// drafts) only, so it is dropped with the card when the question resolves elsewhere (P42). In the live island the
/// field says whether it holds text, so a finish never replaces its card (P96), and keeps it in the card's drafts, so
/// a fold (the owner went to another app, P270) never takes it: the field has it again when the card shows next (P273).
struct AnswerFieldView: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let placeholder: String
    /// Takes the keys when it appears (a field the owner asked for, as No's reason).
    var focused = false
    /// Esc in the field (the window's; the island's Esc closes the island).
    var cancel: (() -> Void)?
    /// A subagent's request the island holds (P350): the time left runs along the field's foot, as along Yes's.
    var holdEnds: Date? = nil
    let send: (String) -> Void
    @Environment(\.cardHovered) private var cardHovered
    @Environment(\.cardDraftReporter) private var reportDraft
    @Environment(\.cardDraftSlot) private var draftSlot
    /// Settings › Island › Text size (P402); the standard size in the window.
    @Environment(\.islandSize) private var islandSize
    @State private var text = ""
    @FocusState private var hasFocus: Bool

    var body: some View {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 6) {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder).font(Fonts.sys(islandSize.text(12))).foregroundStyle(palette.fieldPlaceholder).lineLimit(1)
                        .allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(Fonts.sys(islandSize.text(12)))
                    .foregroundStyle(palette.ink)
                    .focused($hasFocus)
                    .onSubmit(submit)
                    .onExitCommand { cancel?() }
                    .accessibilityLabel(placeholder)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
            .background(cardHovered ? palette.fieldHoverBg : palette.fieldBg, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(cardHovered ? palette.fieldHoverBorder : palette.fieldBorder, lineWidth: 1))
            .overlay { if let holdEnds { HoldCountdown(ends: holdEnds, onField: true).id(holdEnds) } }

            Button(action: submit) {
                SendIcon(colour: hasText ? palette.sendActiveInk : palette.sendText)
                    .frame(width: 30, height: 30)
                    // Glass: the send key's face once the field has text; the glass alone (a veil on a hovered card) until.
                    .cardControlGround(RoundedRectangle(cornerRadius: 7),
                                       fill: hasText ? palette.sendActive : (cardHovered ? palette.sendHover : palette.send),
                                       glassFill: hasText ? palette.sendActive : (cardHovered ? palette.sendHover : nil), key: hasText)
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            // An empty field's key is off: its glass holds still under a press (P641).
            .cardControlGlass(RoundedRectangle(cornerRadius: 7), role: hasText ? .prominent : .regular,
                              tint: hasText ? palette.sendActive : nil, interactive: hasText)
            .disabled(!hasText)
            .accessibilityLabel("Send")
            .help("Send")
        }
        .onChange(of: text.isEmpty) { _, empty in reportDraft?(!empty) }
        .onChange(of: text) { _, text in draftSlot?.keep(text, for: placeholder) }
        // A card built ahead gets its drafts once it shows (`IslandCardLayer`: only the live layer has them). Another
        // request in this card's place (the same session's next, P172) brings its own draft or none, never the text
        // typed for the one before (P273).
        .onChange(of: draftSlot?.key) { old, new in
            if let old, let new, old != new { text = draftSlot?.text(for: placeholder) ?? "" } else { restoreDraft() }
        }
        .onDisappear { if !text.isEmpty { reportDraft?(false) } }
        .onAppear {
            restoreDraft()
            if focused { hasFocus = true }
        }
    }

    /// What the owner typed here before the card last went (P273).
    private func restoreDraft() {
        guard text.isEmpty, let draft = draftSlot?.text(for: placeholder) else { return }
        text = draft
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        send(trimmed)
        text = ""
    }
}

/// Where a card's send stands, in one 11/15 line (P128, P129): "Not sent · Retry" (the word in the needs-you colour,
/// Retry a button that sends it again), or a reply's quiet "Sending…" and "Sent". Nothing before anything was sent.
struct CardSendLine: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    let state: CardSend
    let retry: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            switch state {
            case .sending: Text("Sending…").foregroundStyle(palette.reason)
            case .sent: Text("Sent").foregroundStyle(palette.reason)
            case .notSent:
                Text("Not sent").foregroundStyle(palette.toneText(needsYou.wait))
                Text(" · ").foregroundStyle(palette.reason)
                Button(action: retry) {
                    Text("Retry").fontWeight(.semibold).foregroundStyle(palette.ink).underline(hovered)
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help("Send it again")
            }
            Spacer(minLength: 0)
        }
        .font(Fonts.sys(11))
        .lineBox(15)
    }
}

/// Why the agent asks (Bash's description, Codex's justification) and the worktree's branch: one quiet 11/15 line
/// under the box, up to three when long, the whole of it in the tooltip.
struct CardReasonLine: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let text: String
    /// Settings › Island › Text size (P402); the standard size in the window.
    @Environment(\.islandSize) private var islandSize

    var body: some View {
        Text(text).font(Fonts.sys(islandSize.text(11))).foregroundStyle(palette.reason).lineLimit(3).truncationMode(.tail)
            .cssLines(size: islandSize.text(11), lineHeight: islandSize.line(15, for: 11))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
    }
}

/// A read-only card's two controls (the needs-you design §3.5): Open, the jump to where the agent asks, whose own
/// prompt is where it is answered; and ✕, which lets this notice go while the agent keeps its prompt (never on a
/// request the island holds, `CardRequest.dismissable`). No answer field and no answer buttons: nothing here could
/// answer. Open fills the island's width; ✕ is a 28 pt square beside it. Both act on the request the card shows, by id,
/// never on one that took its place in the session's queue meanwhile (P174).
struct ReadOnlyActions: View {
    let sessionID: String
    let request: CardRequest?
    let style: CardStyle
    /// Space over the buttons (none when they are all the card holds).
    var top: CGFloat = 8
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        HStack(spacing: 6) {
            CardActionButton(title: "Open", help: "Answer it where it asks", primary: true, fills: style.buttonsFill) {
                env.sessions.openRequest(sessionID, request: request?.id)
            }
            if request?.dismissable == true {
                CardDismissButton { env.sessions.dismissRequest(sessionID, request: request?.id) }
            }
            if !style.buttonsFill { Spacer(minLength: 0) }
        }
        .padding(.top, top)
    }
}

/// The time left on a subagent's hold (Answer subagents on the island, P350): a 2 pt line along the foot of the Yes
/// button, or of No's reason field once ⌥-click opened it, that runs out as the hold does, when the card turns read-only
/// and Claude shows its own prompt. One linear animation from the time left as it appears (the sessions' clock: real
/// time live, the fixture's in renders) to none, drawn as a scale, so no layout runs and nothing ticks; it is there only
/// while such a card shows, and the pointer goes through it.
struct HoldCountdown: View {
    let ends: Date
    var total: TimeInterval = SubagentHold.limit
    /// Dark on Yes's light fill; light on the reason field's ground (`onField`): the theme's (`IslandPalette.holdOnPrimary`,
    /// `holdOnField`).
    var onField = false
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    @State private var runningOut = false

    var body: some View {
        let left = Self.left(until: ends, now: env.sessions.now, total: total)
        Rectangle()
            .fill(onField ? theme.island.holdOnField : theme.island.holdOnPrimary)
            .frame(height: 2)
            .scaleEffect(x: runningOut ? 0 : left / total, y: 1, anchor: .leading)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard left > 0 else { return }
                withAnimation(.linear(duration: left)) { runningOut = true }
            }
    }

    /// The seconds left, within 0 and `total`.
    static func left(until ends: Date, now: Date, total: TimeInterval) -> TimeInterval {
        min(total, max(0, ends.timeIntervalSince(now)))
    }
}

/// ✕: 28 pt, r7, the card buttons' grey; on Glass the regular interactive glass (P640).
struct CardDismissButton: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            CrossIcon(colour: palette.ink)
                .frame(width: 28, height: 28)
                .cardControlGround(RoundedRectangle(cornerRadius: 7), fill: hovered ? palette.buttonHover : palette.button,
                                   glassFill: hovered ? palette.button : nil)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .cardControlGlass(RoundedRectangle(cornerRadius: 7), role: .regular)
        .onHover { hovered = $0 }
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }
}

/// The row of card buttons: natural widths from the left in the window, shared width in the island.
struct CardActionsRow<Content: View>: View {
    let fills: Bool
    var top: CGFloat = 8
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if fills {
                FlexRowLayout(spacing: 6) { content }
            } else {
                HStack(spacing: 6) {
                    content
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, top)
    }
}

/// CSS `flex: 1` (a zero basis) with `min-width: auto`: every item gets an equal share, except one whose own width
/// is larger keeps it and the rest share what is left (the island's `.acts`). A row wider than the card's lane never
/// widens the card (P490): the items that give way (a negative layout priority: the mode buttons) take a line of
/// their own under the answers, and a line still too wide cuts its widest items first (Always allow's rule, in the
/// middle) until it fits.
struct FlexRowLayout: Layout {
    var spacing: CGFloat = 8
    /// Between the answers' line and the line the mode buttons wrap to.
    var lineSpacing: CGFloat = 6

    /// The items of each line, in order: one line while every item fits at its own width; otherwise the items that give
    /// way on a second line, when there are some and something stays on the first.
    static func lines(mins: [CGFloat], priorities: [Double], total: CGFloat, spacing: CGFloat) -> [[Int]] {
        let all = Array(mins.indices)
        guard natural(all.map { mins[$0] }, spacing: spacing) > total else { return [all] }
        let first = all.filter { priorities[$0] >= 0 }, second = all.filter { priorities[$0] < 0 }
        return first.isEmpty || second.isEmpty ? [all] : [first, second]
    }

    static func natural(_ mins: [CGFloat], spacing: CGFloat) -> CGFloat {
        mins.reduce(0, +) + spacing * CGFloat(max(0, mins.count - 1))
    }

    static func widths(mins: [CGFloat], total: CGFloat, spacing: CGFloat) -> [CGFloat] {
        guard !mins.isEmpty else { return [] }
        var room = max(0, total - spacing * CGFloat(mins.count - 1))
        guard mins.reduce(0, +) <= room else { return mins.map { min($0, cap(mins, room: room)) } }
        var widths = [CGFloat?](repeating: nil, count: mins.count)
        // Freeze the items too wide for an equal share until the share holds for everyone left.
        while true {
            let open = widths.indices.filter { widths[$0] == nil }
            guard !open.isEmpty else { break }
            let share = room / CGFloat(open.count)
            let frozen = open.filter { mins[$0] > share }
            if frozen.isEmpty {
                for index in open { widths[index] = share }
                break
            }
            for index in frozen { widths[index] = mins[index]; room -= mins[index] }
        }
        return widths.map { $0 ?? 0 }
    }

    /// The width the widest items are cut to so the row fills `room` exactly: the narrow ones keep theirs.
    private static func cap(_ mins: [CGFloat], room: CGFloat) -> CGFloat {
        let sorted = mins.sorted()
        var below: CGFloat = 0
        for (index, width) in sorted.enumerated() {
            let rest = CGFloat(sorted.count - index)
            if below + rest * width >= room { return max(0, (room - below) / rest) }
            below += width
        }
        return sorted.last ?? 0
    }

    private func measure(_ subviews: Subviews, total: CGFloat) -> (lines: [[Int]], widths: [CGFloat]) {
        let mins = subviews.map { $0.sizeThatFits(.unspecified).width }
        let lines = Self.lines(mins: mins, priorities: subviews.map(\.priority), total: total, spacing: spacing)
        var widths = mins
        for line in lines {
            for (index, width) in zip(line, Self.widths(mins: line.map { mins[$0] }, total: total, spacing: spacing)) {
                widths[index] = width
            }
        }
        return (lines, widths)
    }

    private func heights(_ subviews: Subviews, _ lines: [[Int]], _ widths: [CGFloat], height: CGFloat?) -> [CGFloat] {
        lines.map { line in
            line.map { subviews[$0].sizeThatFits(ProposedViewSize(width: widths[$0], height: height)).height }.max() ?? 0
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let mins = subviews.map { $0.sizeThatFits(.unspecified).width }
        let width = proposal.width ?? Self.natural(mins, spacing: spacing)
        let (lines, widths) = measure(subviews, total: width)
        let heights = heights(subviews, lines, widths, height: lines.count == 1 ? proposal.height : nil)
        return CGSize(width: width, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (lines, widths) = measure(subviews, total: bounds.width)
        let heights = heights(subviews, lines, widths, height: lines.count == 1 ? bounds.height : nil)
        var y = bounds.minY
        for (line, height) in zip(lines, heights) {
            var x = bounds.minX
            for index in line {
                subviews[index].place(at: CGPoint(x: x, y: y + height / 2), anchor: .leading,
                                      proposal: ProposedViewSize(width: widths[index], height: height))
                x += widths[index] + spacing
            }
            y += height + lineSpacing
        }
    }
}

extension GlyphPalette.Agent {
    /// "Claude", "Codex", "Gemini", "Kimi", …: `AgentLook`'s name.
    var displayName: String { AgentLook.of(self).name }
}
