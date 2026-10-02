import SwiftUI

/// A Done card's message (P430 to P432): the agent's Markdown as `MessageMarkup.blocks` reads it, in the card's box
/// (12/1.45 #C9C9CE on #121214, r8, padding 8 10). Lines of text as the plan's box draws them (bold 600, italic, code and
/// cited files in 11 pt mono), and in their place:
/// - a table as a compact grid: its header in 600 over a hairline, each column aligned as its delimiter row says, a cell
///   on one line; a grid wider than the card scrolls sideways, a fade at the edge while more is there;
/// - fenced code in a box of its own (#1A1A1D, r6): 11 pt mono as written, no highlighting, a line wider than the box
///   scrolled to sideways;
/// - an `http` or `https` link underlined, opened in the default browser on a click (`SafeLink`); any other target,
///   and an image, is its text.
/// Under a line limit (the island's brief card, a failed turn's six lines) it holds no more lines than plain text would.
/// Settings › Island › Text size steps its text, its grids and its boxes with their line boxes, as it steps the plan and
/// the command (P402, P491); the window draws the standard size.
struct DoneMessageView: View {
    let text: String
    var lineLimit: Int? = nil
    @Environment(\.islandSize) private var islandSize
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }

    var body: some View {
        let groups = Self.groups(MessageMarkup.blocks(text, rows: lineLimit))
        let size = islandSize.text(12)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                switch group {
                case let .text(lines, rows):
                    Text(Self.styled(lines, size: size, palette: palette))
                        .font(Fonts.sys(size))
                        .foregroundStyle(palette.message)
                        .lineLimit(rows)
                        .cssLines(size: size, lineHeight: MessageTheme.lineHeight(size))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case let .table(table):
                    MessageTableView(table: table)
                case let .code(lines):
                    MessageCodeView(lines: lines)
                }
            }
        }
        .tint(palette.link)
        .environment(\.openURL, OpenURLAction { url in
            MainActor.assumeIsolated { SafeLink.open(url) } ? .handled : .discarded
        })
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(palette.codeBg, in: RoundedRectangle(cornerRadius: 8))
    }

    /// What the view draws, in order: runs of lines as one text (the lines the card gives them, nil for all), tables and
    /// boxes.
    enum Group: Equatable {
        case text([[MessageMarkup.Span]], rows: Int?)
        case table(MessageMarkup.Table)
        case code([String])
    }

    static func groups(_ blocks: [MessageMarkup.Block]) -> [Group] {
        var groups: [Group] = []
        for block in blocks {
            switch block {
            case let .line(spans, rows):
                if case let .text(lines, total)? = groups.last {
                    groups[groups.count - 1] = .text(lines + [spans], rows: total.flatMap { total in rows.map { total + $0 } })
                } else {
                    groups.append(.text([spans], rows: rows))
                }
            case let .table(table): groups.append(.table(table))
            case let .code(lines): groups.append(.code(lines))
            }
        }
        return groups
    }

    /// Lines as one attributed string; unstyled runs take the view's font and colour, a link's runs are underlined and
    /// carry their address (the only runs that do).
    static func styled(_ lines: [[MessageMarkup.Span]], size: CGFloat = 12, palette: IslandPalette = .black) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            for span in line { result += run(span, size: size, palette: palette) }
        }
        return result
    }

    static func run(_ span: MessageMarkup.Span, size: CGFloat = 12, weight base: Font.Weight = .regular,
                    palette: IslandPalette = .black) -> AttributedString {
        var run = AttributedString(span.text)
        let weight: Font.Weight = span.style.contains(.bold) ? .semibold : base
        if span.style.contains(.mono) {
            run.font = Fonts.mono(size - 1, weight)
            run.foregroundColor = palette.codeText
        } else if !span.style.isEmpty || base != .regular {
            run.font = span.style.contains(.italic) ? Fonts.sys(size, weight).italic() : Fonts.sys(size, weight)
        }
        if let link = span.link {
            run.link = link
            run.underlineStyle = .single
            run.foregroundColor = palette.link
        }
        return run
    }
}

/// The message's own colours and sizes: a link a step brighter than the text, the code box a step above the message's
/// ground, the table's rule between them.
enum MessageTheme {
    /// A line of text of `size` pt (12/1.45 at the standard size).
    static func lineHeight(_ size: CGFloat) -> CGFloat { size * 1.45 }
    static let link = Color(hex: 0xE8E8EC)
    static let codeBox = Color(hex: 0x1A1A1D)
    static let rule = Color(hex: 0x2C2C30)
    static let header = Color(hex: 0xE8E8EC)
    /// A code line's pitch: 16 for 11 pt mono, grown with the text (`IslandSize.line`).
    static let codeLineHeight: CGFloat = 16
}

/// A table as a compact grid (P430): the header's cells in 600 over a hairline, then the rows, each column aligned as
/// the delimiter row says, 14 pt between columns, a cell on one line. Wider than the card, it scrolls sideways.
struct MessageTableView: View {
    let table: MessageMarkup.Table
    @Environment(\.islandSize) private var islandSize
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }

    var body: some View {
        SidewaysScroll(fade: palette.codeBg) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        cell(table.header[column], header: true)
                            .gridColumnAlignment(Self.alignment(table.alignments[safe: column]))
                    }
                }
                Rectangle().fill(palette.messageRule).frame(height: 1).padding(.vertical, 2)
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in cell(table.rows[row][column], header: false) }
                    }
                }
            }
            .fixedSize()
        }
    }

    private func cell(_ spans: [MessageMarkup.Span], header: Bool) -> some View {
        let size = islandSize.text(12)
        var text = AttributedString()
        for span in spans { text += DoneMessageView.run(span, size: size, weight: header ? .semibold : .regular, palette: palette) }
        return Text(text)
            .font(Fonts.sys(size, header ? .semibold : .regular))
            .foregroundStyle(header ? palette.messageHeader : palette.message)
            .lineLimit(1)
            .frame(height: MessageTheme.lineHeight(size))
    }

    static func alignment(_ alignment: MessageMarkup.Table.Alignment?) -> HorizontalAlignment {
        switch alignment {
        case .center: .center
        case .trailing: .trailing
        case .leading, nil: .leading
        }
    }
}

/// Fenced code in a box of its own (P430): 11 pt mono as written, its blank lines kept, no highlighting; a line wider
/// than the box is scrolled to sideways, never wrapped or cut.
struct MessageCodeView: View {
    let lines: [String]
    @Environment(\.islandSize) private var islandSize
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }

    var body: some View {
        let size = islandSize.text(11)
        SidewaysScroll(fade: palette.messageCodeBox) {
            Text(lines.joined(separator: "\n"))
                .font(Fonts.mono(size))
                .foregroundStyle(palette.codeText)
                .cssLines(size: size, lineHeight: islandSize.line(MessageTheme.codeLineHeight, for: 11), mono: true)
                .fixedSize()
                .padding(.vertical, 5).padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.messageCodeBox, in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Its content as it is when it fits the width offered; wider, in a sideways scroll view with no scroller, a fade at the
/// trailing edge while more is to that side. Content that fits is drawn plain, without a scroll view, so every renderer
/// draws it (`ImageRenderer` leaves AppKit-backed views blank). The fade lays `fade` (the box's ground) over the edge;
/// on glass, where the ground is a veil and the same veil over the content would only dim it, the content itself fades
/// out there (a mask, only on a grid or code line wider than its box, P556).
struct SidewaysScroll<Content: View>: View {
    let fade: Color
    @ViewBuilder var content: Content
    @State private var moreAhead = true
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            content
            ScrollView(.horizontal) { content }
                .scrollIndicators(.never)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
                } action: { _, more in
                    moreAhead = more
                }
                .modifier(SidewaysFade(fade: fade, moreAhead: moreAhead, glass: theme.knocksOut))
        }
    }
}

/// `SidewaysScroll`'s fade at its trailing edge while more is to that side: `fade` laid over the edge (Black's opaque
/// ground), or on glass the content faded out under a mask.
private struct SidewaysFade: ViewModifier {
    let fade: Color
    let moreAhead: Bool
    let glass: Bool
    static let width: CGFloat = 18

    @ViewBuilder func body(content: Content) -> some View {
        if glass {
            content.mask {
                HStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .black.opacity(moreAhead ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.width)
                }
            }
        } else {
            content.overlay(alignment: .trailing) {
                if moreAhead {
                    LinearGradient(colors: [fade.opacity(0), fade], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.width)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
