import IslandEngine
import SwiftUI

/// A session sent to the island (P1300 to P1324): its conversation, kept on the island while it is folded. One line
/// says who (its glyph, which says what it is at; its mark, project and title) with ✕, which lets it go without opening
/// it; then the agent's last answer, a few lines that scroll, a long one ending with Open in terminal; Continue and what
/// it sends, while the session stopped mid-turn (P1419); the reply field, where Return sends; and one quiet line, what
/// it is at or where the reply stands on the left, Open in terminal on the right. Each new answer takes the old one's
/// place. An approval or a question shows as its own card, as ever; the line says it waits, and Show brings that card.
struct FoldedCardView: View {
    let card: FoldedCardModel
    var row: SessionRow { card.row }
    var animated = true
    /// Show on a waiting session's line: the island presents its own card (`IslandViewActions.openRow`).
    var showCard: @MainActor (SessionRow) -> Void = { _ in }
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.islandSize) private var size

    /// The message box's lines before it scrolls.
    nonisolated static let messageLines = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let message = card.message { messageBox(message) }
            if let prompt = card.continuePrompt { continueRow(prompt) }
            if Self.showsField(card) {
                // A reply that did not go comes back into the field (P1356, P1359): only a new Return sends it.
                AnswerFieldView(placeholder: "Reply to \(card.agent.displayName)…", refill: card.returned) {
                    env.sessions.replyFolded(card.sessionID, text: $0)
                }
            }
            FoldedCardLine(card: card, showCard: showCard)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12)
            shape.fill(palette.rowHover).overlay(shape.strokeBorder(palette.rowHoverStroke, lineWidth: 0.5))
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.task), in the island")
    }

    /// The field shows while a reply can go somewhere (its tab, or the agent's own resume) and none is on its way; never
    /// while an app holds the conversation, is about to, or waits to (P1515).
    nonisolated static func showsField(_ card: FoldedCardModel) -> Bool {
        card.reach != .openOnly && card.send != .sending && card.app?.hidesField != true
    }

    private var header: some View {
        HStack(spacing: IslandTheme.Metrics.rowGlyphGap) {
            RowGlyph(row: row, animated: animated)
            RowTitleLine(row: row, size: size.text(12), markSize: Theme.Mark.sessionRow)
                .frame(maxWidth: .infinity, alignment: .leading)
            FoldedCardButton(help: "Let it go, without opening it", label: "Dismiss") {
                CrossIcon(colour: palette.rowAge).frame(width: 8, height: 8)
            } action: {
                env.sessions.unfold(card.sessionID)
            }
        }
        .frame(height: size.rowTitleHeight)
        .sessionMenu(row)
    }

    /// Continue, and the words it sends, before the click (P1419); Codex's note under them, as it runs without asking.
    private func continueRow(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                CardActionButton(title: "Continue", help: "Carry on the turn, in the background", primary: true, compact: true) {
                    env.sessions.continueFolded(card.sessionID)
                }
                .fixedSize()
                Text("“\(prompt)”").font(Fonts.sys(size.text(11))).foregroundStyle(palette.statusClean)
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            if let note = card.note {
                Text(note).font(Fonts.sys(size.text(11))).foregroundStyle(palette.reason).lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func messageBox(_ message: String) -> some View {
        let lineHeight = MessageTheme.lineHeight(size.text(12))
        return CardScrollBox(maxHeight: CGFloat(Self.messageLines) * lineHeight + 16, bordered: false, insets: EdgeInsets()) {
            VStack(alignment: .leading, spacing: 0) {
                DoneMessageView(text: message)
                if card.isLong {
                    // The rest is the terminal's to show.
                    Button { env.sessions.openFolded(card.sessionID) } label: {
                        HStack(spacing: 4) {
                            Text(card.continuesInTerminal ? "Continue in terminal" : "Open in terminal")
                            OpenOutIcon(colour: palette.jump, side: 8)
                        }
                        .font(Fonts.sys(size.text(11), .medium))
                        .foregroundStyle(palette.jump)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.codeBg)
                }
            }
        }
    }
}

/// The card's one quiet line: on the left what it is at (Working and its tool, Needs approval and Show) or where the
/// reply stands (held, its text and Cancel; Sending…, Sent, Not sent with Retry, or why it came back to the field), the
/// resume's note, where Open in <App> stands, where Claude Code's or Codex's background has it, or "Open in terminal to
/// reply"; on the right at most two: Stop while a run the island or a background copy holds is under way, else Open in
/// <App> where its app can take it and nothing else on the card asks for a click (P1510, P1535), then Open in terminal.
struct FoldedCardLine: View {
    let card: FoldedCardModel
    var row: SessionRow { card.row }
    var showCard: @MainActor (SessionRow) -> Void = { _ in }
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @Environment(\.islandSize) private var size

    /// What the left of the line says, in order of what matters most.
    enum Left: Equatable {
        /// The held reply's own text (P1358).
        case held(String)
        case send(CardSend)
        /// The resume's problem; `retry` while the reply that met it did not go.
        case problem(String, retry: Bool)
        case note(String)
        /// Why a held reply came back to the field (P1356, P1359); the resume's note goes first (Codex's line).
        case unsent(String)
        case waits
        /// Its agent ended while its turn ran (P1415).
        case stopped(String)
        /// In Claude Code's own background, or on its way there (wave 8, P1450 on); `working` while a turn runs there.
        case background(FoldedBackgroundModel, working: Bool)
        /// Continue or a reply met a turn Codex's background service goes on with (P1488).
        case finishing
        /// Working, and the terminal its window sits in the Dock of, while it does (P1417).
        case working(inTerminal: String?)
        /// Where Open in <App> stands (P1513): its words, whether they warn, and Cancel while it waits for the turn's end.
        case app(String, warns: Bool, cancel: Bool)
        case none
    }

    nonisolated static func left(_ card: FoldedCardModel, row: SessionRow) -> Left {
        if let held = card.held { return .held(held) }
        if let problem = card.problem, card.send == nil || card.send == .notSent {
            return .problem(problem, retry: card.send == .notSent)
        }
        if let send = card.send { return .send(send) }
        if row.hasCard { return .waits }
        if let app = card.app, let words = app.words { return .app(words, warns: app.warns, cancel: app.state == .pending) }
        if card.finishing { return .finishing }
        // Codex's note then shows under Continue.
        if let stopped = card.stopped, !card.working { return .stopped(stopped) }
        // "Not opened" (its Open in terminal did not open a window) says so first.
        if let background = card.background { return card.note.map(Left.note) ?? .background(background, working: card.working) }
        if let note = card.note { return .note(note) }
        if let unsent = card.unsent { return .unsent(unsent) }
        if card.working { return .working(inTerminal: card.inTerminal) }
        return .none
    }

    /// Open in terminal's words: "Continue in terminal" on a stopped card its resume carries on in the new window
    /// (P1439); "Open in terminal to reply" where a reply can go nowhere from the island, "to continue" for a session
    /// that stopped mid-turn there (P1419).
    nonisolated static func openTitle(_ card: FoldedCardModel) -> String {
        if case .inApp? = card.app?.state { return "Open in terminal" }
        if card.continuesInTerminal { return "Continue in terminal" }
        guard card.reach == .openOnly else { return "Open in terminal" }
        return card.stopped != nil ? "Open in terminal to continue" : "Open in terminal to reply"
    }

    /// Its tooltip: on a stopped card, the words the new window sends, as Continue shows them.
    nonisolated static func openHelp(_ card: FoldedCardModel) -> String {
        if let app = card.app, case .inApp = app.state { return "Back to a terminal once the app has quit" }
        if card.continuesInTerminal { return "Open it in a new window and send “\(SessionEngine.continuePrompt)”" }
        if card.reach == .background { return "Open it in a new window; closing that window leaves it running" }
        return card.reach == .tab ? "Back to its tab" : "Open the conversation in a terminal"
    }

    /// Open in <App> shows on the line only where nothing else on the card asks for a click: no Stop, no Continue, and no
    /// link in the line's words (a held reply's Cancel, Retry, Show). So at most two of Continue, Stop, Open in <App> and
    /// Open in terminal show at once, and the header's menu has Open in <App> otherwise (P1513, P1535). Refused, the line
    /// says why in its place, whole, and the menu offers it again.
    nonisolated static func showsAppLink(_ card: FoldedCardModel) -> Bool {
        guard let app = card.app, app.offered, app.state == .offered, !card.stoppable, card.continuePrompt == nil else { return false }
        switch left(card, row: card.row) {
        case .held, .problem(_, retry: true), .send(.notSent), .waits: return false
        default: return true
        }
    }

    /// Open in terminal shows but while the hand-over is under way, and on a card whose app the owner picks it in: no
    /// terminal copy is left there.
    nonisolated static func showsOpen(_ card: FoldedCardModel) -> Bool {
        switch card.app?.state {
        case .opening?, .pick?: false
        default: true
        }
    }

    var body: some View {
        let font = Fonts.sys(size.text(11))
        HStack(spacing: 10) {
            left.font(font).lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
            if card.stoppable {
                FoldedLink(title: "Stop", help: card.reach == .background ? "Stop the background session; its conversation is kept"
                                                                            : "End the reply's run") {
                    env.sessions.stopFolded(card.sessionID)
                }
            }
            if Self.showsAppLink(card), let app = card.app {
                FoldedLink(title: app.title, help: "Go on with it in \(app.name)", icon: true) { env.sessions.openInApp(card.sessionID) }
            }
            if Self.showsOpen(card) {
                FoldedLink(title: Self.openTitle(card), help: Self.openHelp(card), icon: true) { env.sessions.openFolded(card.sessionID) }
            }
        }
        .frame(height: size.line(15, for: 11))
    }

    @ViewBuilder private var left: some View {
        let agent = card.agent.displayName
        switch Self.left(card, row: row) {
        case let .held(text):
            // The text itself, cut to the line, so a second reply joining it is seen (P1358); Cancel always shows.
            HStack(spacing: 0) {
                Text("Held · ").foregroundStyle(palette.reason).fixedSize()
                Text(text).foregroundStyle(palette.statusClean).lineLimit(1).truncationMode(.tail)
                Text(" · ").foregroundStyle(palette.reason).fixedSize()
                FoldedLink(title: "Cancel", help: "Keep it from going") { env.sessions.cancelHeld(card.sessionID) }
            }
            .help("Sends when \(agent) finishes: \(text)")
        case let .send(state):
            CardSendLine(state: state) { env.sessions.retryFolded(card.sessionID) }
        case let .problem(problem, retry):
            HStack(spacing: 0) {
                Text(problem).foregroundStyle(palette.toneText(needsYou.wait)).help(problem)
                if retry {
                    Text(" · ").foregroundStyle(palette.reason)
                    FoldedLink(title: "Retry", help: "Send it again") { env.sessions.retryFolded(card.sessionID) }
                }
            }
        case let .note(note):
            Text(note).foregroundStyle(palette.reason)
        case let .unsent(words):
            Text(words).foregroundStyle(palette.toneText(needsYou.wait)).help(words)
        case .waits:
            let status = IslandRowText.status(row)
            HStack(spacing: 0) {
                Text(status.word ?? SessionRowText.cleanStatus(row).word ?? "Waits on you")
                    .foregroundStyle(palette.toneText(needsYou.wait))
                Text(" · ").foregroundStyle(palette.reason)
                FoldedLink(title: "Show", help: "Its card") { showCard(row) }
            }
        case let .stopped(words):
            Text(words).foregroundStyle(palette.toneText(needsYou.wait)).help(words)
        case let .background(model, working):
            backgroundLine(model, working: working)
        case .finishing:
            Text(SessionResumer.finishingWords).foregroundStyle(palette.you).help("Its window can close; Codex goes on with it")
        case let .working(host):
            let status = IslandRowText.status(row)
            HStack(spacing: 0) {
                // Its window, in the Dock, still holds the run (P1417).
                Text(host.map { "Working in \($0)" } ?? "Working").foregroundStyle(palette.you).fixedSize()
                if let verb = status.toolVerb {
                    Text(" · ").foregroundStyle(palette.reason)
                    Text(verb).font(Fonts.mono(size.text(11))).foregroundStyle(palette.toolVerb).padding(.trailing, 5)
                    if let text = status.text { Text(text).foregroundStyle(palette.statusClean) }
                }
            }
        case let .app(words, warns, cancel):
            HStack(spacing: 0) {
                Text(words).foregroundStyle(warns ? palette.toneText(needsYou.wait) : palette.reason).help(words)
                if cancel {
                    Text(" · ").foregroundStyle(palette.reason).fixedSize()
                    FoldedLink(title: "Cancel", help: "Keep it here") { env.sessions.cancelPendingApp(card.sessionID) }
                }
            }
        case .none:
            Color.clear.frame(height: 1)
        }
    }
}

extension FoldedCardLine {
    /// A background session's line (P1450 on): "Background", "Background · Working · <tool>", "Background · attached in
    /// Terminal", "Background · stopped", "Moves to the background when this turn ends", "Moving to the background…", or
    /// why it did not move.
    @ViewBuilder func backgroundLine(_ model: FoldedBackgroundModel, working: Bool) -> some View {
        switch model.stage {
        case .notMoved:
            Text(model.words).foregroundStyle(palette.toneText(needsYou.wait)).help(model.help)
        case .moved where working:
            let status = IslandRowText.status(row)
            HStack(spacing: 0) {
                Text("Background").foregroundStyle(palette.reason).fixedSize()
                Text(" · ").foregroundStyle(palette.reason)
                Text("Working").foregroundStyle(palette.you).fixedSize()
                if let verb = status.toolVerb {
                    Text(" · ").foregroundStyle(palette.reason)
                    Text(verb).font(Fonts.mono(size.text(11))).foregroundStyle(palette.toolVerb).padding(.trailing, 5)
                    if let text = status.text { Text(text).foregroundStyle(palette.statusClean) }
                }
            }
            .help(model.help)
        default:
            Text(model.words).foregroundStyle(palette.reason).help(model.help)
        }
    }
}

/// A quiet text button on the card's line: 11 pt semibold in the ink, underlined under the pointer, the jump's blue for
/// Open in terminal with its arrow.
struct FoldedLink: View {
    let title: String
    var help: String
    var icon = false
    let action: () -> Void
    @Environment(\.juiceTheme) private var theme
    @Environment(\.islandSize) private var size
    @State private var hovered = false

    var body: some View {
        let colour = icon ? theme.island.jump : theme.island.ink
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).fontWeight(.semibold).underline(hovered && !icon)
                if icon { OpenOutIcon(colour: colour, side: 8) }
            }
            .font(Fonts.sys(size.text(11)))
            .foregroundStyle(hovered && icon ? theme.island.ink : colour)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(title)
    }
}

/// A small square button with an icon: the header's ✕.
struct FoldedCardButton<Label: View>: View {
    let help: String
    let label: String
    @ViewBuilder let icon: Label
    let action: () -> Void
    @Environment(\.juiceTheme) private var theme
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: 18, height: 18)
                .background(Circle().fill(hovered ? theme.island.button : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(label)
    }
}

/// A folded session that is not the one open, in the stack: one line, its glyph, mark and title, and what it is at;
/// a click opens its card in the stack (P1307).
struct FoldedStackRow: View {
    let card: FoldedCardModel
    var row: SessionRow { card.row }
    var animated = true
    let open: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    @Environment(\.islandSize) private var size
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: IslandTheme.Metrics.rowGlyphGap) {
                RowGlyph(row: row, animated: animated)
                RowTitleLine(row: row, size: size.text(12), markSize: Theme.Mark.sessionRow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(word.text).font(Fonts.sys(size.text(11))).foregroundStyle(word.colour).lineLimit(1).fixedSize()
            }
            .frame(height: size.rowTitleHeight)
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10)
                shape.fill(palette.rowHover.opacity(hovered ? 1 : 0.6))
                    .overlay(shape.strokeBorder(palette.rowHoverStroke, lineWidth: 0.5))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .sessionMenu(row)
        .accessibilityLabel("\(row.task), in the island")
    }

    /// What the line says it is at: a held reply, Working, Waits on you, or nothing new (its age).
    private var word: (text: String, colour: Color) {
        if card.held != nil { return ("Reply held", palette.reason) }
        if row.hasCard { return (IslandRowText.status(row).word ?? "Waits", palette.toneText(needsYou.wait)) }
        if card.working { return ("Working", palette.you) }
        if card.stopped != nil { return ("Stopped", palette.toneText(needsYou.wait)) }
        if let app = card.app {
            switch app.state {
            case .inApp, .pick: return ("In \(app.name)", palette.reason)
            case .pending, .opening: return ("Opens in \(app.name)", palette.reason)
            case .offered, .blocked: break
            }
        }
        if card.background?.stage == .moved { return ("Background", palette.reason) }
        if card.send == .notSent || card.unsent != nil { return ("Not sent", palette.toneText(needsYou.wait)) }
        return (SessionRowText.age(row.updatedAt, now: env.sessions.now), palette.rowAge)
    }
}

/// The folded sessions over the island's rows (P1307): one opens into its card, the newest unless another was chosen,
/// and the rest stay one line each above it; a click on one opens it in the other's place.
struct FoldedStackView: View {
    let cards: [FoldedCardModel]
    var animated = true
    var showCard: @MainActor (SessionRow) -> Void = { _ in }
    /// The card open in the stack, as the owner chose it; nil or gone: the newest.
    @Binding var chosen: String?

    static func open(_ cards: [FoldedCardModel], chosen: String?) -> String? {
        if let chosen, cards.contains(where: { $0.sessionID == chosen }) { return chosen }
        return cards.first?.sessionID
    }

    var body: some View {
        let open = Self.open(cards, chosen: chosen)
        VStack(spacing: 4) {
            ForEach(cards) { card in
                if card.sessionID == open {
                    FoldedCardView(card: card, animated: animated, showCard: showCard)
                } else {
                    FoldedStackRow(card: card, animated: animated) { chosen = card.sessionID }
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: open)
    }
}

/// Renders only: an island row drawn as under the pointer (its Send to island and its jump arrow).
private struct PreviewRowHoveredKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var previewRowHovered: Bool {
        get { self[PreviewRowHoveredKey.self] }
        set { self[PreviewRowHoveredKey.self] = newValue }
    }
}
