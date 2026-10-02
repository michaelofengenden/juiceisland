import AppKit
import JuiceCore
import SwiftUI

/// One account battery as the prototype draws it (`bat()`, prototype L979-1006): Juice's `BatteryView` geometry
/// (`Theme.Battery`: body 42 × 18, r5.5, outline 1.5, nub 2.5 × 6.5, inset 2) restyled with the prototype's red key,
/// dashed outline, stale band and slash, and Next bar. Pure drawing: callers add the button, hover and menu.
/// The cell is 45 × 18; the Next bar hangs below it (top at 20.5) and is not part of the layout size.
struct UsageBatteryView: View {
    let battery: BatteryModel
    var now: Date
    /// Its parent's theme, passed down (`BatteryView.theme`, P559).
    var theme = JuiceTheme.black

    private typealias M = Theme.Battery
    private var palette: PanelPalette { theme.panel }
    private static let bodySize = CGSize(width: M.width, height: M.height)

    var body: some View {
        cell
        .opacity(battery.state.isPlanless ? BatteryView.noPlanOpacity : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(battery.hoverLabel.replacingOccurrences(of: " · ", with: ", "))
    }

    /// On glass in a group of its own, its cuts showing the glass behind it (`BatteryCut`).
    @ViewBuilder private var cell: some View {
        if theme.knocksOut {
            layers(cut: BatteryKnockOut(), track: palette.track).batteryCutGroup()
        } else {
            layers(cut: EmptyModifier(), track: palette.track)
        }
    }

    private func layers<Cut: BatteryCutting>(cut: Cut, track: Color) -> some View {
        ZStack(alignment: .topLeading) {
            bodyLayer(cut: cut, track: track)
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 1.5, topTrailingRadius: 1.5)
                .fill(palette.line)
                .frame(width: 2.5, height: M.nubHeight)
                .offset(x: 42.5, y: 5.75)
            if case .stale = battery.state { staleMarks(cut: cut) }
            if battery.isNext {
                RoundedRectangle(cornerRadius: 1)
                    .fill(palette.ink)
                    .frame(width: M.nextBarSize.width, height: M.nextBarSize.height)
                    .offset(x: 14, y: 20.5)
            }
        }
        .frame(width: M.cellWidth, height: M.height, alignment: .topLeading)
    }

    // MARK: body

    @ViewBuilder private func bodyLayer<Cut: BatteryCutting>(cut: Cut, track: Color) -> some View {
        switch battery.state {
        case let .available(left, isLow):
            let fill = isLow ? palette.tone(Theme.warn) : palette.ink
            filled(percent: left, colour: fill, track: track) { BatteryDigitRow(percent: left, fill: fill, ink: palette.ink, cut: cut) }
        case let .usedUp(refill):
            RoundedRectangle(cornerRadius: M.radius)
                .strokeBorder(palette.line, lineWidth: M.outline)
                .frame(width: M.width, height: M.height)
                .overlay {
                    Text(Formatting.refillLabel(refill, now: now))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(palette.ink2)
                }
        case .signInNeeded:
            dashed { BatteryKeyGlyph(colour: palette.tone(Theme.attention)).frame(width: 13, height: 8) }
        case .signingIn:
            dashed {
                HStack(spacing: 2.5) {
                    ForEach(0..<3, id: \.self) { _ in Circle().fill(palette.ink2).frame(width: 2.5, height: 2.5) }
                }
            }
        case let .stale(last):
            filled(percent: last ?? 0, colour: palette.ink.opacity(0.35), track: track) { EmptyView() }
        case .unknown:
            filled(percent: 0, colour: palette.ink, track: track) {
                Text(verbatim: "?").font(Self.digitFont).foregroundStyle(palette.ink2)
            }
        case .noPlan, .noLimits:
            RoundedRectangle(cornerRadius: M.radius)
                .strokeBorder(palette.line, lineWidth: M.outline)
                .frame(width: M.width, height: M.height)
                .overlay { BatteryView.planlessWords(battery.state, palette.ink2) }
        }
    }

    private func filled<Content: View>(percent: Int, colour: Color, track: Color, @ViewBuilder content: () -> Content) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: M.radius).fill(track)
            if percent > 0 {
                UnevenRoundedRectangle(topLeadingRadius: 3.5, bottomLeadingRadius: 3.5,
                                       bottomTrailingRadius: percent >= 100 ? 3.5 : 1, topTrailingRadius: percent >= 100 ? 3.5 : 1)
                    .fill(colour)
                    .frame(width: Self.fillWidth(percent), height: M.height - 2 * M.inset)
                    .offset(x: M.inset, y: M.inset)
            }
            RoundedRectangle(cornerRadius: M.radius).strokeBorder(palette.line, lineWidth: M.outline)
            content().frame(width: M.width, height: M.height)
        }
        .frame(width: M.width, height: M.height)
    }

    private func dashed<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        // The prototype's SVG: rect x .75 y .75, 40.5 × 16.5, rx 4.75, stroke 1.5, dash 2 2.
        RoundedRectangle(cornerRadius: 4.75)
            .stroke(palette.line, style: StrokeStyle(lineWidth: M.outline, dash: [2, 2]))
            .frame(width: M.width - 1.5, height: M.height - 1.5)
            .frame(width: M.width, height: M.height)
            .overlay { content() }
    }

    /// A black band and an ink slash, both 22 tall, rotated 25° about the body's centre (x 21, y 9).
    private func staleMarks<Cut: BatteryCutting>(cut: Cut) -> some View {
        ZStack {
            Rectangle().fill(Theme.surface).frame(width: 5, height: 22).rotationEffect(.degrees(25)).modifier(cut)
            Rectangle().fill(palette.ink).frame(width: 1.5, height: 22).rotationEffect(.degrees(25))
        }
        .frame(width: 5, height: 22)
        .offset(x: 21 - 2.5, y: -2)
    }

    static let digitFont = Font.system(size: 11, weight: .semibold).monospacedDigit()

    /// `p ≤ 0 ? 0 : max(2, 38 · p / 100)` (prototype `fillW`).
    static func fillWidth(_ percent: Int) -> CGFloat {
        guard percent > 0 else { return 0 }
        return max(2, (M.width - 2 * M.inset) * CGFloat(min(percent, 100)) / 100)
    }
}

/// A battery's percent, each digit whole in one colour: black where the fill holds the digit's middle, ink where the
/// empty track does, so the fill edge never cuts a digit in two ("3|7"). A digit the edge runs through keeps a 1 pt
/// halo in the other side's colour (the fill's, or black), so its part across the edge still reads. Shared by the
/// prototype's battery (`UsageBatteryView`) and Juice's (`BatteryView`), which draw `BatteryDigitRow` with their cut:
/// on glass, inside the battery's group, the black shows the glass (`BatteryCut`). On its own it draws the black.
struct BatteryDigits: View {
    let percent: Int
    /// The fill's colour (ink, or amber when low).
    var fill: Color = Theme.ink

    private typealias M = Theme.Battery

    var body: some View {
        BatteryDigitRow(percent: percent, fill: fill, cut: EmptyModifier())
    }

    /// Which side holds a digit's middle, and whether the edge runs through it.
    static func side(_ span: ClosedRange<CGFloat>, edge: CGFloat) -> (onFill: Bool, cut: Bool) {
        ((span.lowerBound + span.upperBound) / 2 < edge, span.lowerBound < edge && edge < span.upperBound)
    }

    /// Where each of `count` digits sits across the body (tabular figures, centred): x from the body's left edge.
    static func spans(count: Int) -> [ClosedRange<CGFloat>] {
        let start = (M.width - CGFloat(count) * advance) / 2
        return (0..<count).map { start + CGFloat($0) * advance...start + CGFloat($0 + 1) * advance }
    }

    /// One tabular digit's advance in the battery's digit font (11 pt semibold).
    static let advance: CGFloat = {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        return NSAttributedString(string: "0", attributes: [.font: font]).size().width
    }()
}

/// `BatteryDigits` with its black drawn by `cut`: the black (`EmptyModifier`), or knocked out (`BatteryKnockOut`).
struct BatteryDigitRow<Cut: BatteryCutting>: View {
    let percent: Int
    var fill: Color = Theme.ink
    /// A digit over the empty track (the ink; Glass's adapts).
    var ink: Color = Theme.ink
    var cut: Cut

    private typealias M = Theme.Battery

    var body: some View {
        let text = Array("\(percent)")
        let edge = M.inset + UsageBatteryView.fillWidth(percent)
        let spans = BatteryDigits.spans(count: text.count)
        HStack(spacing: 0) {
            ForEach(text.indices, id: \.self) { index in
                let span = spans[index], side = BatteryDigits.side(span, edge: edge)
                HaloDigit(digit: String(text[index]), colour: side.onFill ? Theme.surface : ink,
                          halo: side.cut ? (side.onFill ? fill : Theme.surface) : nil,
                          width: span.upperBound - span.lowerBound, edge: edge - span.lowerBound, haloBeforeEdge: !side.onFill,
                          digitCut: cut.cutting(side.onFill), haloCut: cut.cutting(!side.onFill))
            }
        }
        .font(UsageBatteryView.digitFont)
        .frame(width: M.width, height: M.height)
    }
}

/// Where a halo's eight copies of a digit sit (a generic type keeps no stored static).
private let haloDigitOffsets: [CGSize] = [(-1, 0), (1, 0), (0, -1), (0, 1), (-0.7, -0.7), (0.7, -0.7), (-0.7, 0.7), (0.7, 0.7)]
    .map { CGSize(width: $0.0, height: $0.1) }

/// One digit of a battery's percent in its `width` column. With a `halo`, a 1 pt outline in that colour is drawn under
/// it on the far side of the fill edge only (`edge`, from the column's left), where the digit crosses onto the other
/// colour; on its own side the digit needs none.
private struct HaloDigit<Cut: BatteryCutting>: View {
    let digit: String
    let colour: Color
    var halo: Color?
    var width: CGFloat
    var edge: CGFloat = 0
    /// The halo shows left of the edge (a light digit over the fill), else right of it (a dark digit over the track).
    var haloBeforeEdge = true
    /// How the digit and its halo draw the surface's black (`BatteryCutting`).
    var digitCut: Cut
    var haloCut: Cut

    private static var offsets: [CGSize] { haloDigitOffsets }

    var body: some View {
        ZStack {
            if let halo {
                ZStack {
                    ForEach(Self.offsets.indices, id: \.self) { index in
                        Text(verbatim: digit).foregroundStyle(halo).offset(Self.offsets[index])
                    }
                }
                .frame(width: width)
                .mask(alignment: .leading) {
                    let edge = min(max(0, edge), width)
                    Rectangle().frame(width: haloBeforeEdge ? edge : width - edge).offset(x: haloBeforeEdge ? 0 : edge)
                }
                .modifier(haloCut)
            }
            Text(verbatim: digit).foregroundStyle(colour).modifier(digitCut)
        }
        .frame(width: width)
    }
}

/// The prototype's red key (13 × 8, viewBox 14 × 8): a ring and a bit.
struct BatteryKeyGlyph: View {
    /// `Theme.attention` (Glass: its adaptive twin).
    var colour: Color = Theme.attention

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 14, size.height / 8)
            let dy = (size.height - 8 * scale) / 2
            let dx = (size.width - 14 * scale) / 2
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: dx + x * scale, y: dy + y * scale) }
            let ring = Path(ellipseIn: CGRect(x: dx + (3.6 - 2.4) * scale, y: dy + (4 - 2.4) * scale, width: 4.8 * scale, height: 4.8 * scale))
            context.stroke(ring, with: .color(colour), lineWidth: 1.8 * scale)
            var bit = Path()
            bit.move(to: p(6, 3.1))
            for (x, y) in [(13.2, 3.1), (13.2, 4.9), (12, 4.9), (12, 6.5), (10.4, 6.5), (10.4, 4.9), (9, 4.9), (9, 6.1),
                           (7.5, 6.1), (7.5, 4.9), (6, 4.9)] as [(CGFloat, CGFloat)] {
                bit.addLine(to: p(x, y))
            }
            bit.closeSubpath()
            context.fill(bit, with: .color(colour))
        }
    }
}
