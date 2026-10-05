import SwiftUI

/// The question · its options (⌃1-⌃4) · an answer field. The header's status line says "Question · <topic>", and
/// "1/3" when Claude asks several at once: the card shows one at a time, a pick moves on to the next, and the last
/// sends every answer together. A multi-select question's options toggle, and Next (Send on the last) moves on once
/// one is picked; Back returns to the question before. The field is upstream's "Other": what is typed answers the
/// question on show. Options stack, one per row: the title, then one line of description (its whole text in the
/// tooltip). Answers that could not be sent keep the card as it was, with "Not sent · Retry" under the field (P129).
/// Read-only (a question the island cannot answer: a Codex question, a subagent's, one Claude asks where the island
/// holds no hook): every question at once with its options as plain lines, then Open and ✕; nothing to pick or type.
/// Owner: stream C.
struct QuestionCardView: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let card: QuestionCardModel
    var style: CardStyle = .window
    var highlightedOption: Int?
    @Environment(AppEnvironment.self) private var env
    /// Settings › Island › Text size (P402); the standard size in the window.
    @Environment(\.islandSize) private var islandSize
    @State private var hoveredOption: Int?

    var body: some View {
        if card.isAnswerable { answerable } else { readOnly }
    }

    private var readOnly: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(card.shown.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 0) {
                    questionText(item.question)
                    if !item.options.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(item.options.enumerated()), id: \.offset) { number, option in
                                QuestionOptionLine(index: number, option: option)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.top, index == 0 ? 0 : 10)
            }
            ReadOnlyActions(sessionID: card.sessionID, request: card.request, style: style,
                            top: card.shown.isEmpty ? 0 : 8)
        }
    }

    private func questionText(_ text: String) -> some View {
        let size = islandSize.text(style.questionSize)
        return Text(text)
            .font(Fonts.sys(size, .semibold))
            .foregroundStyle(palette.ink)
            .cssLines(size: size, lineHeight: islandSize.line(style.questionLine, for: style.questionSize))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var answerable: some View {
        VStack(alignment: .leading, spacing: 0) {
            questionText(card.question)
            if !card.options.isEmpty {
                VStack(spacing: 4) { optionButtons }
                    .cardGlassGroup()
                    .padding(.top, 8)
            }
            AnswerFieldView(placeholder: "Type your answer…") { answer(.text($0)) }
                .id(card.step)
                .padding(.top, 8)
            if let send = card.send {
                CardSendLine(state: send) { env.sessions.retry(card.sessionID) }.padding(.top, 6)
            }
            let next = card.multiSelect && !card.picked.isEmpty
            if card.step > 0 || next {
                CardActionsRow(fills: style.buttonsFill && card.step > 0 && next) {
                    if card.step > 0 {
                        CardActionButton(title: "Back", fills: style.buttonsFill && next) { answer(.back) }
                    }
                    if next {
                        CardActionButton(title: card.isLastStep ? "Send" : "Next", primary: true, fills: style.buttonsFill && card.step > 0) {
                            answer(.next)
                        }
                    }
                }
            }
        }
    }

    private var optionButtons: some View {
        ForEach(Array(card.options.enumerated()), id: \.offset) { index, option in
            QuestionOptionButton(index: index, option: option,
                                 selected: card.picked.contains(index) || (hoveredOption ?? highlightedOption) == index,
                                 checked: card.multiSelect && card.picked.contains(index)) {
                answer(.option(index))
            }
            .onHover { inside in
                if inside { hoveredOption = index } else if hoveredOption == index { hoveredOption = nil }
            }
        }
    }
}

/// A step on the question the card shows, only while its request is the one waiting (P170).
extension QuestionCardView {
    fileprivate func answer(_ input: QuestionInput) { env.sessions.answerQuestion(card.sessionID, input, request: card.request?.id) }
}

/// One option of a read-only question, as a plain line (nothing to click): its number, its label and, dimmer, its
/// description, 11.5/18; the whole of it in the tooltip.
struct QuestionOptionLine: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    let index: Int
    let option: QuestionCardModel.Option
    @Environment(\.islandSize) private var islandSize

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index + 1)").font(Fonts.num(islandSize.text(10.5), .semibold)).foregroundStyle(palette.optionBadgeText)
                .frame(width: 12, alignment: .trailing)
            HStack(spacing: 0) {
                Text(option.label).foregroundStyle(palette.ink2)
                if !option.description.isEmpty { Text(" — " + option.description).foregroundStyle(palette.optionSub) }
            }
            .font(Fonts.sys(islandSize.text(11.5)))
            .lineLimit(1).truncationMode(.tail)
        }
        .lineBox(islandSize.line(18, for: 11.5))
        .help(option.description.isEmpty ? option.label : "\(option.label) — \(option.description)")
    }
}

/// One option: a 16 pt number badge (grey; the needs-you colour when selected), the title 600 12/16 and one line of description
/// 10.5/14, on #121214 r7, padding 6 10. The key ⌃n shows on the right only while ⌃ is held (the first four); on a
/// hovered island card a chevron takes its place.
struct QuestionOptionButton: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(\.needsYouColour) private var needsYou
    let index: Int
    let option: QuestionCardModel.Option
    var selected = false
    /// A multi-select question's picked option: a check on the right.
    var checked = false
    let action: () -> Void
    @Environment(\.cardHovered) private var cardHovered
    @Environment(\.showsShortcutHints) private var showsHints
    @Environment(\.cardKeys) private var keys
    /// Settings › Island › Text size (P402): the title and the description; the badge and the key hint keep theirs.
    @Environment(\.islandSize) private var islandSize

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 9) {
                Text("\(index + 1)")
                    .font(Fonts.num(10.5, .bold))
                    .foregroundStyle(selected ? palette.optionBadgeSelectedText : palette.optionBadgeText)
                    .frame(width: 16, height: 16)
                    .background(selected ? palette.optionBadgeSelected(needsYou) : palette.optionBadge, in: RoundedRectangle(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 0) {
                    Text(option.label)
                        .font(Fonts.sys(islandSize.text(12), .semibold))
                        .foregroundStyle(palette.optionTitle)
                        .lineLimit(1).truncationMode(.tail)
                        .lineBox(islandSize.line(16, for: 12))
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(Fonts.sys(islandSize.text(10.5)))
                            .foregroundStyle(palette.optionSub)
                            .lineLimit(1).truncationMode(.tail)
                            .lineBox(islandSize.line(14, for: 10.5))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if checked {
                    CheckIcon(colour: palette.tone(needsYou.wait))
                } else if cardHovered {
                    ChevronRightIcon(colour: palette.optionChevron)
                } else if showsHints, let hint = keys.optionHint(index) {
                    Text(hint).font(Fonts.sys(10.5)).foregroundStyle(palette.cardKbd).fixedSize()
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardControlGround(RoundedRectangle(cornerRadius: 7), fill: background, glassFill: glassFill)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected && !cardHovered ? palette.optionSelectedBorder(needsYou) : .clear,
                                                                     lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        // Glass: each option the regular interactive glass, the picked or hovered one a veil on it (P640).
        .cardControlGlass(RoundedRectangle(cornerRadius: 7), role: .regular)
        .help(Self.tooltip(option, index: index, keys: keys))
        .accessibilityLabel("\(index + 1). \(option.label)")
    }

    /// The whole option and its key: "Juice Island — Reads like a place; matches the repo juice-island.  ⌃1".
    static func tooltip(_ option: QuestionCardModel.Option, index: Int, keys: CardKeys = .standard) -> String {
        let text = option.description.isEmpty ? option.label : "\(option.label) — \(option.description)"
        return keys.optionHint(index).map { "\(text)  \($0)" } ?? text
    }

    private var background: Color {
        if cardHovered { return selected ? palette.optionHover : palette.optionBg }
        return selected ? palette.optionSelected : palette.optionBg
    }

    /// On Glass: the selected (or hovered) option's veil on its glass; the glass alone otherwise.
    private var glassFill: Color? {
        if cardHovered { return selected ? palette.optionHover : nil }
        return selected ? palette.optionSelected : nil
    }
}
