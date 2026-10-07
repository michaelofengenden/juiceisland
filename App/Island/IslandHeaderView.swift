import JuiceCore
import SwiftUI

/// What the island's buttons and rows ask for; the panel controller fills these in, renders keep the no-ops.
struct IslandViewActions {
    var openRow: @MainActor (SessionRow) -> Void = { _ in }
    /// The pointer came onto a row or left it (a card can be built ahead of the click, P133).
    var hoverRow: @MainActor (SessionRow, Bool) -> Void = { _, _ in }
    var showAll: @MainActor () -> Void = {}
    var toggleStrip: @MainActor () -> Void = {}
    var gear: @MainActor () -> Void = {}
    var showAsWindow: @MainActor () -> Void = {}
    var toggleSound: @MainActor () -> Void = {}
}

/// The header: the notch's own row, so it costs no height of its own. Two wings beside the notch and nothing over it:
/// the brand glyph at the outer left (over the rows' glyph column) and the gear at the outer right (over the rows'
/// ages; sound and Show as Window live in the gear's menu). In Header strip placement the Claude pair (mark + the
/// account in use, else the Next battery, P812) and the Codex pair hug the notch, one each side, mirrored; either opens
/// the usage block, which then takes their place (so no battery shows twice). A hover label (Clean and Detailed alike)
/// spans the wings while it shows: the name ends at the notch, the details start after it. A right-click on it offers
/// Snooze's choices (P724).
struct IslandHeaderView: View {
    @Environment(AppEnvironment.self) private var env
    /// The brand glyph's finish: on Glass the session glyphs' (`GlyphFinish`, P596), the brand's own orange at full
    /// strength with its edge and bloom, never Glass's twin with a coloured-shadow glow.
    @Environment(\.juiceTheme) private var theme
    var layout: IslandHeaderLayout
    /// The header strip shows (Header strip placement, list, usage on, the block folded).
    var strip: Bool
    var hover: HoverTargetID?
    /// `hover` came from U (P461): its label shows even with Hover details off.
    var hoverByKey = false
    var animated: Bool
    var actions: IslandViewActions
    /// The live island: the brand glyph and the gear ride out with its surface's shoulders (`IslandShoulderGate`); nil
    /// shows them as they are (renders).
    var gate: IslandUIState?
    /// Reduce Motion: the strip's pairs only fade.
    var reduceMotion = false
    /// The accounts in use as the island took them at its open (`IslandUIState.inUse`, P812).
    var inUse = AccountsInUse.none

    /// The hover label fitted to the wings: the short one in both styles (the wings are the only room for it; Detailed's
    /// long caption band under the usage block is gone, so no empty band waits there).
    static func label(_ target: HoverTargetID, usage: any UsageModel, layout: IslandHeaderLayout) -> (label: HoverLabel, size: CGFloat)? {
        HoverLabelText.short(target, usage: usage).map {
            IslandSlotText.fitSplit($0, left: layout.leftSlot.width, right: layout.rightSlot.width)
        }
    }

    /// The brand glyph sits in a column as wide as the rows' glyph column and right above it (the rows are inset 8 pt,
    /// the left wing 4).
    static let brandInset: CGFloat = 4

    var body: some View {
        let settings = env.settings
        let label = settings.hoverDetails || hoverByKey
            ? hover.flatMap { Self.label($0, usage: env.usage, layout: layout) } : nil
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    PixelGlyphView(glyph: .brand, colour: IslandTheme.brand, pixel: 2, animated: animated, finish: GlyphFinish(theme))
                        .frame(width: IslandTheme.Metrics.rowGlyphColumn)
                        .shoulderGate(gate, outward: -1)
                        .padding(.leading, Self.brandInset)
                    Spacer(minLength: 8)
                    if strip {
                        HeaderStripPair(row: env.usage.claudeRow, inUse: inUse, action: actions.toggleStrip)
                            .transition(.focus(blur: 4, drift: 0, reduceMotion: reduceMotion))
                    }
                }
                .frame(width: layout.leftSlot.width)
                .padding(.leading, layout.leftSlot.minX)
                Color.clear.frame(width: layout.rightSlot.minX - layout.leftSlot.maxX)
                HStack(spacing: 0) {
                    if strip {
                        HeaderStripPair(row: env.usage.codexRow, inUse: inUse, action: actions.toggleStrip)
                            .transition(.focus(blur: 4, drift: 0, reduceMotion: reduceMotion))
                    }
                    Spacer(minLength: 8)
                    // The gear's dot while an update waits (P403): the gear's menu starts with Update.
                    IslandGearButton(dot: UpdateText.menuEnabled(available: env.updateChecker.available, phase: env.updateController.phase),
                                     action: actions.gear)
                        .shoulderGate(gate, outward: 1)
                }
                .frame(width: layout.rightSlot.width)
            }
            .frame(width: layout.contentWidth, height: layout.height, alignment: .leading)
            // The pairs come and go on their own curves whatever changed them (a card coming in, the block folding), so
            // they cross the usage block as it leaves or comes, never showing its batteries twice at full. As the strip
            // unfolds they stay until the block starts to come in (`stripPairHold`), so usage never leaves the island
            // while the rows slide down.
            .animation(reduceMotion ? IslandMotion.reduced.animation
                       : strip ? IslandMotion.focusIn.animation : IslandMotion.focusOut.animation.delay(IslandMotion.stripPairHold),
                       value: strip)
            .opacity(label == nil ? 1 : 0)

            if let label {
                HeaderSplitLabel(label: label.label, size: label.size, layout: layout)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: layout.contentWidth, height: layout.height, alignment: .topLeading)
        // Snooze (P724): a right-click on the island's header, the pill's own row, mutes for a while.
        .contentShape(Rectangle())
        .contextMenu { SnoozeMenuItems() }
    }
}

/// A hover label across the notch: the name right-aligned in the left wing, the details left-aligned in the right.
struct HeaderSplitLabel: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    var label: HoverLabel
    var size: CGFloat
    var layout: IslandHeaderLayout

    var body: some View {
        HStack(spacing: 0) {
            Text(label.name).fontWeight(.medium).foregroundStyle(theme.panel.ink)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: layout.leftSlot.width, alignment: .trailing)
                .padding(.leading, layout.leftSlot.minX)
            Color.clear.frame(width: layout.rightSlot.minX - layout.leftSlot.maxX)
            HStack(spacing: 0) {
                ForEach(Array(label.parts.enumerated()), id: \.offset) { index, part in
                    if index > 0 { Text("·").foregroundStyle(palette.ink3).padding(.horizontal, 5) }
                    Text(part).foregroundStyle(theme.panel.ink2)
                }
            }
            .lineLimit(1)
            .frame(width: layout.rightSlot.width, alignment: .leading)
            .clipped()
        }
        .font(Fonts.sys(size))
        .frame(width: layout.contentWidth, height: layout.height, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// The gear: 13 pt, dim at rest, brighter under the pointer; no fill behind it. While an update waits (P403) a small
/// white dot sits on its top right, inside its click: the menu it opens starts with Update.
struct IslandGearButton: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    var dot = false
    var action: @MainActor () -> Void
    @State private var hovering = false

    nonisolated static let dotSize: CGFloat = 5
    /// The ring round the dot, each side of it.
    nonisolated static let ringWidth: CGFloat = 1.5
    /// Where the dot sits: its top right corner this far past the cog's.
    nonisolated static let dotOffset = CGSize(width: 2, height: -2)

    var body: some View {
        Button(action: action) {
            cog
                .overlay(alignment: .topTrailing) {
                    if dot {
                        if theme.knocksOut {
                            Circle().fill(palette.ink).frame(width: Self.dotSize, height: Self.dotSize)
                                .offset(x: Self.dotOffset.width, y: Self.dotOffset.height)
                        } else {
                            Circle().fill(IslandTheme.ink).frame(width: Self.dotSize, height: Self.dotSize)
                                // Ringed in the island's black, so it reads apart from the cog's teeth.
                                .background(Circle().fill(IslandTheme.bg).padding(-1.5))
                                .offset(x: 2, y: -2)
                        }
                    }
                }
                .padding(3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(dot ? "Settings · Update ready" : "Settings")
        .accessibilityLabel(dot ? "Settings, update ready" : "Settings")
        .onHover { hovering = $0 }
    }

    /// On glass the dot's ring is cut out of the cog (`DotRingCut`): the island's black there would be a black disc on
    /// the glass (P526, P556). Black draws the cog whole and rings the dot in its black, as it always did.
    @ViewBuilder private var cog: some View {
        let colour = hovering ? palette.headerIcon : palette.headerIconRest
        if dot, theme.knocksOut {
            CogIcon(size: 13, colour: colour).mask(DotRingCut().fill(style: FillStyle(eoFill: true)))
        } else {
            CogIcon(size: 13, colour: colour)
        }
    }
}

/// The cog's frame and more around it, less the update dot's ring (the dot and `IslandGearButton.ringWidth` round it),
/// even-odd: a mask that cuts the ring out of the cog.
struct DotRingCut: Shape {
    func path(in rect: CGRect) -> Path {
        let size = IslandGearButton.dotSize, ring = IslandGearButton.ringWidth, offset = IslandGearButton.dotOffset
        let dot = CGRect(x: rect.maxX - size + offset.width, y: rect.minY + offset.height, width: size, height: size)
        var path = Path(rect.insetBy(dx: -4, dy: -4))
        path.addEllipse(in: dot.insetBy(dx: -ring, dy: -ring))
        return path
    }
}

/// One half of the header strip: a provider's mark and the account its sessions use (Usage shows first In use, P812),
/// else its Next battery (the first when none is next). Opens the usage block; a faint highlight while hovered. Its
/// battery reports no hover (the label would cover it) and draws neither the Next bar nor the in-use dot (it is the only
/// battery shown, so neither would say anything; the dot would also sit against the screen's top edge).
struct HeaderStripPair: View {
    @Environment(\.juiceTheme) private var theme
    private var palette: IslandPalette { theme.island }
    @Environment(AppEnvironment.self) private var env
    var row: ProviderRowModel?
    var inUse = AccountsInUse.none
    var action: @MainActor () -> Void
    @State private var hovering = false

    static let markSize: CGFloat = Theme.Mark.strip
    static let gap: CGFloat = 6
    static let padding: CGFloat = 4
    /// Mark, gap, one battery cell, and the padding each side.
    static var width: CGFloat { markSize + gap + Theme.Battery.cellWidth + 2 * padding }

    /// What its battery's menu acts on: the island's (Refresh login on a lapsed login, P1551).
    @MainActor static func batteryActions(env: AppEnvironment) -> PanelActions { .island(env: env) }

    /// The battery the strip shows: under In use the first account in use (P812), else the Next one (else the first that
    /// is not No plan or No limits, P360, P581, else the first), without its Next bar.
    static func battery(_ row: ProviderRowModel, inUse: AccountsInUse = .none, first: UsageFirst = .next) -> BatteryModel? {
        let used = first == .inUse ? inUse.ids(row.provider).lazy.compactMap { id in row.batteries.first { $0.id == id } }.first : nil
        guard var battery = used ?? row.batteries.first(where: \.isNext) ?? row.batteries.first(where: { !$0.state.isPlanless })
            ?? row.batteries.first else { return nil }
        battery.isNext = false
        return battery
    }

    var body: some View {
        if let row, let battery = Self.battery(row, inUse: inUse, first: env.settings.usageFirst) {
            Button(action: action) {
                HStack(spacing: Self.gap) {
                    ProviderMarkView(provider: row.provider, size: Self.markSize, theme: theme)
                    BatteryView(battery: battery, now: env.usage.now, theme: theme)
                        .environment(\.hoverReporter) { _ in }
                        .environment(\.panelActions, Self.batteryActions(env: env))
                }
                .padding(.horizontal, Self.padding)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? palette.islandHover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("Usage, click to open")
        }
    }
}
