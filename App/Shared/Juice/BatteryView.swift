import AppKit
import JuiceCore
import SwiftUI

/// One account as an iPhone-style battery (Juice spec §2.2), copied from standalone Juice; its percent is
/// `BatteryDigits`, whose digits are never cut at the fill edge.
/// Every state is a shape, so it survives a tinted widget.
struct BatteryView: View {
    let battery: BatteryModel
    /// The clock the used-up label counts against; injected so the label can tick without re-reading.
    var now: Date = Date()
    /// Its parent's theme, passed down rather than read here, so Black's battery is today's, node for node (P559): on
    /// glass (Glass, Smoke) its cuts knock out, and on Glass its ink adapts (`PanelPalette.glass`).
    var theme = JuiceTheme.black
    /// The account the owner's sessions run in (`AccountsInUse`, P811): a small dot over the body, no words.
    var inUse = false
    @Environment(\.panelActions) private var actions
    /// Drawing the copy that casts Widget's full-colour ink shadow (P1206): the track and a stale fill, veils, cast none.
    @Environment(\.inkShadowPass) private var shadowPass

    private typealias M = Theme.Battery
    private var palette: PanelPalette { theme.panel }
    private var track: Color { shadowPass ? .clear : palette.track }

    var body: some View {
        cell
        .overlay(alignment: .trailing) {
            UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 1.5, topTrailingRadius: 1.5)
                .fill(palette.line)
                .frame(width: M.nubWidth - 0.5, height: M.nubHeight)
                .offset(x: M.nubWidth)
        }
        .padding(.trailing, M.nubWidth)
        // A No plan or No limits login (P360, P581) dims, body and nub, with its words inside.
        .opacity(battery.state.isPlanless ? Self.noPlanOpacity : 1)
        .overlay(alignment: .bottom) {
            if battery.isNext {
                Capsule()
                    .fill(palette.ink)
                    .frame(width: M.nextBarSize.width, height: M.nextBarSize.height)
                    .offset(x: -M.nubWidth / 2, y: M.nextBarBelow + M.nextBarSize.height / 2)
            }
        }
        .overlay(alignment: .top) {
            if inUse { Self.inUseMark(palette.ink) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(inUse ? battery.hoverLabel + ", in use" : battery.hoverLabel)
        .hoverTarget(id: battery.id, label: battery.hoverLabel)
        .contextMenu {
            let refresh = actions.refreshAccountItem(battery.id)
            Button(refresh.title) { actions.refreshAccount(battery.id) }
                .disabled(!refresh.isEnabled)
            if let email = actions.email(battery.id) {
                Button("Copy email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(email, forType: .string)
                }
            }
            if battery.state == .signInNeeded {
                Button("Sign in") { actions.signIn(battery.id) }
            }
            Button("Manage account…") { actions.manageAccount(battery.id) }
        }
    }

    // MARK: body

    /// The body and its content: on glass in a group of its own, its cuts showing the glass behind it (`BatteryCut`).
    @ViewBuilder private var cell: some View {
        if theme.knocksOut {
            layers(cut: BatteryKnockOut(), track: track).batteryCutGroup()
        } else {
            layers(cut: EmptyModifier(), track: track)
        }
    }

    private func layers<Cut: BatteryCutting>(cut: Cut, track: Color) -> some View {
        ZStack {
            bodyShape(cut: cut, track: track)
            content(cut: cut)
        }
        .frame(width: M.width, height: M.height)
    }

    @ViewBuilder private func bodyShape<Cut: BatteryCutting>(cut: Cut, track: Color) -> some View {
        switch battery.state {
        case .signInNeeded, .signingIn:
            RoundedRectangle(cornerRadius: M.radius)
                .strokeBorder(palette.line, style: StrokeStyle(lineWidth: M.outline, dash: [2, 2]))
        case .usedUp, .noPlan, .noLimits:
            RoundedRectangle(cornerRadius: M.radius).strokeBorder(palette.line, lineWidth: M.outline)
        case .stale(let last):
            // The band is the surface's black on Black, knocked out on glass (its colour then only its shape).
            filledBody(percent: last ?? 0, colour: shadowPass ? .clear : palette.ink.opacity(0.35), track: track)
                .overlay { Rectangle().fill(Theme.surface).frame(width: 5, height: M.height + 6).rotationEffect(.degrees(25)).modifier(cut) }
                .overlay { Rectangle().fill(palette.ink).frame(width: 1.5, height: M.height + 4).rotationEffect(.degrees(25)) }
        case .available(let left, let isLow):
            filledBody(percent: left, colour: isLow ? palette.tone(Theme.warn) : palette.ink, track: track)
        case .unknown:
            filledBody(percent: 0, colour: palette.ink, track: track)
        }
    }

    private func filledBody(percent: Int, colour: Color, track: Color) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: M.radius).fill(track)
            fillShape(percent: percent).fill(colour)
                .frame(width: fillWidth(percent), height: M.height - 2 * M.inset)
                .padding(.leading, M.inset)
            RoundedRectangle(cornerRadius: M.radius).strokeBorder(palette.line, lineWidth: M.outline)
        }
    }

    private func fillWidth(_ percent: Int) -> CGFloat {
        guard percent > 0 else { return 0 }
        return max(2, (M.width - 2 * M.inset) * CGFloat(min(percent, 100)) / 100)
    }

    private func fillShape(percent: Int) -> UnevenRoundedRectangle {
        let inner = M.radius - M.inset
        let right: CGFloat = percent >= 100 ? inner : 1
        return UnevenRoundedRectangle(topLeadingRadius: inner, bottomLeadingRadius: inner, bottomTrailingRadius: right, topTrailingRadius: right)
    }

    // MARK: content

    @ViewBuilder private func content<Cut: BatteryCutting>(cut: Cut) -> some View {
        switch battery.state {
        case .available(let left, let isLow):
            BatteryDigitRow(percent: left, fill: isLow ? palette.tone(Theme.warn) : palette.ink, ink: palette.ink, cut: cut)
        case .usedUp(let refill):
            Text(Formatting.refillLabel(refill, now: now))
                .font(Theme.refillFont)
                .foregroundStyle(palette.ink2)
        case .signInNeeded:
            // The prototype's key (ring left, bit right), as the window draws it; the SF Symbol points the other way.
            BatteryKeyGlyph(colour: palette.tone(Theme.attention)).frame(width: 13, height: 8)
        case .signingIn:
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(palette.ink2).frame(width: 2.5, height: 2.5) }
            }
        case .stale:
            EmptyView()
        case .unknown:
            Text("?").font(Theme.digitFont).foregroundStyle(palette.ink2)
        case .noPlan, .noLimits:
            Self.planlessWords(battery.state, palette.ink2)
        }
    }

    /// How far a No plan battery dims (P360).
    static let noPlanOpacity: Double = 0.5

    /// The in-use dot (P811), centred over the body (not the nub), as the Next bar is under it.
    static func inUseMark(_ colour: Color) -> some View {
        Circle().fill(colour)
            .frame(width: M.inUseDot, height: M.inUseDot)
            .offset(x: -M.nubWidth / 2, y: -(M.inUseDotAbove + M.inUseDot))
            .allowsHitTesting(false)
    }

    /// "No plan" inside a No plan battery's outline (P360), "No limits" inside a No limits one's (P581), in the theme's
    /// second ink; shared with the window's battery (`UsageBatteryView`).
    static func planlessWords(_ state: AccountState, _ ink: Color = Theme.ink2) -> some View {
        Text(verbatim: state == .noLimits ? "No limits" : "No plan")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, M.inset)
    }
}
