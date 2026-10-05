import IslandEngine
import SwiftUI

/// Where a card is drawn: the window's Needs you grid (Detailed row header, body indented under the title), the Clean
/// island (two-line Clean header) or the Detailed island (full row). Owner: stream C.
enum CardStyle: Sendable { case window, islandClean, islandDetailed }

extension CardStyle {
    var isIsland: Bool { self != .window }

    /// The card's own padding: the window card lines its glyph up with the Running and Done rows (12 from the edge);
    /// the island's lift keeps Clean 6 8 and Detailed 8.
    var padding: EdgeInsets {
        switch self {
        case .window: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12)
        case .islandClean: EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        case .islandDetailed: EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        }
    }

    var radius: CGFloat { self == .islandClean ? 12 : 14 }

    /// The body under the header: the window indents it under the title; the island runs it full width.
    var bodyInsets: EdgeInsets {
        self == .window
            ? EdgeInsets(top: 8, leading: DetailedRowMetrics.window.leading, bottom: 0, trailing: 0)
            : EdgeInsets(top: 6, leading: 0, bottom: 2, trailing: 0)
    }

    /// The question text: 600 12.5/17 in the window, 600 11.5/15 in the island.
    var questionSize: CGFloat { self == .window ? 12.5 : 11.5 }
    var questionLine: CGFloat { self == .window ? 17 : 15 }

    /// Buttons keep their natural width in the window and share the width in the island.
    var buttonsFill: Bool { self != .window }

    /// The lines a command or a change shows before its box scrolls.
    var codeLines: Int { self == .window ? 10 : 6 }
    /// The lines a plan shows before its box scrolls.
    var planLines: Int { self == .window ? 16 : 10 }
}

/// The cards' own colours: pure black cards with the faintest edge, neutral option rows, colour only on what waits
/// for you (the status word, the selected option: `NeedsYouColour`, `IslandPalette.optionSelectedBorder(_:)`).
enum CardTheme {
    static let windowFill = Color.black
    static let windowStroke = Color.white(0.075)
    static let optionBg = Color(hex: 0x121214)
    static let optionHover = Color(hex: 0x1B1B1E)
    static let optionSelected = Color(hex: 0x1B1B1E)
    static let optionBadge = Color(hex: 0x26262A)
    static let optionBadgeText = Color(hex: 0x9A9A9F)
    static let optionTitle = IslandTheme.ink
    static let optionSub = Color(hex: 0x86868B)
    /// Key hints on the dark buttons and options: at least 4.5:1 on them.
    static let kbd = Color(hex: 0x8A8A8F)
    /// The dim line under an approval's box: quieter than the command, still readable on black.
    static let reason = Color(hex: 0x86868B)
    static let diffAdded = Color(hex: 0x7CC58E)
    static let diffAddedFill = Color(hex: 0x6FB982).opacity(0.10)
    static let diffRemoved = Color(hex: 0xF08A80)
    static let diffRemovedFill = Color(hex: 0xF08A80).opacity(0.10)
    static let diffContext = Color(hex: 0x8E8E93)
    /// A diff's gaps ("⋯") and "N more lines": small text, so 4.5:1 on black too.
    static let diffGap = IslandTheme.ink3
}

/// The one short status line a card's header carries, so the body never repeats it: "Needs approval · Bash",
/// "Plan ready · 4 steps", "Question · App name" ("Question · App name · 1/3" when Claude asks several), "Done",
/// "Turn failed · Signed out", "Limit reached · resets 15:00" (P700). A subagent's request names it before the tool ("Needs approval · worker · Bash"); a
/// read-only card says where it is answered ("Needs approval · Bash · in Codex", the needs-you design §3.5). A card
/// that waits adds how many others wait after it ("· 2 more", P130): in the island every other request, in the window
/// (which shows every session's card) those queued behind it in its own session.
enum CardText {
    /// `host`: the row's terminal, which a read-only card in a terminal names ("in Ghostty").
    static func status(_ card: SessionCard, more: Int = 0, host: String? = nil) -> SessionRowText.DetailedStatus {
        var status = base(card)
        var parts = [status.text]
        if let request = card.request, !request.answerable { parts.append(place(request.place, host: host)) }
        if more > 0, card.waits { parts.append("\(more) more") }
        let text = parts.compactMap { $0 }.joined(separator: " · ")
        status.text = text.isEmpty ? nil : text
        return status
    }

    /// Where a read-only request is answered: the agent's own prompt.
    static func place(_ place: AttentionRequest.Place, host: String?) -> String {
        switch place {
        case .codexApp: "in Codex"
        case .claudeApp: "in Claude"
        case .ide: "in " + (host ?? "the editor")
        case .terminal: "in " + (host ?? "the terminal")
        }
    }

    private static func base(_ card: SessionCard) -> SessionRowText.DetailedStatus {
        switch card {
        case let .approval(model):
            let tool = model.tool.trimmingCharacters(in: .whitespaces)
            let parts = [model.request?.agentType, tool.isEmpty ? nil : tool].compactMap { $0 }
            return .init(word: "Needs approval", tone: .approval, isPrompt: false, text: parts.isEmpty ? nil : parts.joined(separator: " · "))
        case let .plan(model):
            return .init(word: "Plan ready", tone: .approval, isPrompt: false, text: model.steps.map(SessionRowText.stepsText))
        case let .question(model):
            let topic = model.topic?.trimmingCharacters(in: .whitespaces)
            // A read-only card shows every question at once: no step.
            let step = model.count > 1 && model.isAnswerable ? "\(model.step + 1)/\(model.count)" : nil
            let parts = [model.request?.agentType, topic?.isEmpty == false ? topic : nil, step].compactMap { $0 }
            return .init(word: "Question", tone: .approval, isPrompt: false, text: parts.isEmpty ? nil : parts.joined(separator: " · "))
        case let .done(model):
            if model.stalled { return .init(word: "Stalled", tone: .stalled, isPrompt: false, text: nil) }
            // "Limit reached · resets 15:00", "API error · overloaded" (P700).
            if let limit = model.limit { return SessionRowText.limitStatus(limit) }
            // A failed turn is never "Done": it needs you, and says why when that fits the line (P132).
            if model.failed {
                return .init(word: "Turn failed", tone: .approval, isPrompt: false,
                             text: TurnFailure.fitsStatusLine(model.message) ? model.message : nil)
            }
            return model.interrupted
                ? .init(word: "Interrupted", tone: .muted, isPrompt: false, text: nil)
                : .init(word: "Done", tone: .done, isPrompt: false, text: nil)
        case .quota:
            // Its header is its own (`QuotaNoticeHeader`), which says it with the battery.
            return .init(word: nil, tone: .muted, isPrompt: false, text: nil)
        }
    }
}

extension SessionCard {
    /// An approval, a plan or a question: its agent waits until the owner answers. A quota notice waits for no one.
    var waits: Bool {
        switch self {
        case .question, .approval, .plan: true
        case .done, .quota: false
        }
    }

    /// The engine request a waiting card shows; nil for the others.
    var request: CardRequest? {
        switch self {
        case let .question(model): model.request
        case let .approval(model): model.request
        case let .plan(model): model.request
        case .done, .quota: nil
        }
    }

    /// The island can answer it (a card with no engine request behind it too); false for a read-only card.
    var isAnswerable: Bool { request?.answerable ?? true }
}

/// True while the pointer is over an island card (`.sess.lift:hover`): options darken and show a chevron, the answer
/// field lightens. The window's cards have no such state.
private struct CardHoveredKey: EnvironmentKey { static let defaultValue = false }

/// False in renders: glyphs hold still (the equalizer's first frame, no pulse).
private struct SessionGlyphsAnimatedKey: EnvironmentKey { static let defaultValue = true }

/// Renders only: the question option drawn as selected (as under the pointer) before anything is hovered.
private struct PreviewSelectedOptionKey: EnvironmentKey { static let defaultValue: Int? = nil }

/// Renders only: an island card drawn as under the pointer (its lift, a brief Done card's reply field).
private struct PreviewCardHoveredKey: EnvironmentKey { static let defaultValue = false }

/// True while ⌃ is held in the focused window (or a render asks for it): buttons, options and the jump tag show their
/// keys. Otherwise the keys live only in the tooltips. The keys themselves work the same either way.
private struct ShowsShortcutHintsKey: EnvironmentKey { static let defaultValue = false }

/// Renders only: an approval or plan card drawn with its No reason field open (as after ⌥-click on No).
private struct PreviewReasonFieldKey: EnvironmentKey { static let defaultValue = false }

/// True while ⌥ is held in the focused window (or a render asks for it): No reads "No…", as ⌥-click opens its reason.
private struct OptionKeyHeldKey: EnvironmentKey { static let defaultValue = false }

/// Settings › Shortcuts as the buttons' hints read it (P1025): set from the settings by `ControlKeyHints`; today's keys
/// elsewhere.
private struct CardKeysKey: EnvironmentKey { static let defaultValue = CardKeys.standard }

/// The live island only: where a card's field says whether it holds text, so a finish never replaces it (P96).
private struct CardDraftReporterKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable (Bool) -> Void)? = nil
}

extension EnvironmentValues {
    var cardHovered: Bool {
        get { self[CardHoveredKey.self] }
        set { self[CardHoveredKey.self] = newValue }
    }

    var sessionGlyphsAnimated: Bool {
        get { self[SessionGlyphsAnimatedKey.self] }
        set { self[SessionGlyphsAnimatedKey.self] = newValue }
    }

    var previewSelectedOption: Int? {
        get { self[PreviewSelectedOptionKey.self] }
        set { self[PreviewSelectedOptionKey.self] = newValue }
    }

    var previewCardHovered: Bool {
        get { self[PreviewCardHoveredKey.self] }
        set { self[PreviewCardHoveredKey.self] = newValue }
    }

    var showsShortcutHints: Bool {
        get { self[ShowsShortcutHintsKey.self] }
        set { self[ShowsShortcutHintsKey.self] = newValue }
    }

    var previewReasonField: Bool {
        get { self[PreviewReasonFieldKey.self] }
        set { self[PreviewReasonFieldKey.self] = newValue }
    }

    var optionKeyHeld: Bool {
        get { self[OptionKeyHeldKey.self] }
        set { self[OptionKeyHeldKey.self] = newValue }
    }

    var cardKeys: CardKeys {
        get { self[CardKeysKey.self] }
        set { self[CardKeysKey.self] = newValue }
    }

    var cardDraftReporter: (@MainActor @Sendable (Bool) -> Void)? {
        get { self[CardDraftReporterKey.self] }
        set { self[CardDraftReporterKey.self] = newValue }
    }
}

/// Shows the shortcut hints below this view while the card keys' modifier (Settings › Shortcuts, ⌃ unless Option was
/// picked) is held, and No's "No…" while ⌥ is: SwiftUI's own modifier-key tracking for the focused window, no event
/// monitor or tap. With Keyboard shortcuts off no hint shows. A hint already asked for above (a render) stays on. It hands
/// the keys below it (`cardKeys`) from the settings, so every button names the key that works.
struct ControlKeyHints: ViewModifier {
    @Environment(\.showsShortcutHints) private var inherited
    @Environment(\.optionKeyHeld) private var inheritedOption
    @Environment(AppEnvironment.self) private var env: AppEnvironment?
    @State private var controlHeld = false
    @State private var optionHeld = false

    func body(content: Content) -> some View {
        let keys = env?.settings.cardKeys ?? .standard
        let held = keys.modifier == .control ? controlHeld : optionHeld
        content
            .onModifierKeysChanged(mask: [.control, .option], initial: true) { _, keys in
                controlHeld = keys.contains(.control)
                optionHeld = keys.contains(.option)
            }
            .environment(\.showsShortcutHints, inherited || (held && keys.enabled))
            .environment(\.optionKeyHeld, inheritedOption || optionHeld)
            .environment(\.cardKeys, keys)
    }
}

extension View {
    func shortcutHintsWhileControlHeld() -> some View { modifier(ControlKeyHints()) }
}
