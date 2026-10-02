import SwiftUI

/// The island's, the rows' and the cards' theme-dependent tokens: its surface, ink, separators and fills. The state and
/// agent colours (`IslandTheme.run`, `.done`, `.delegate`, `.agentClaude`, `.agentCodex` and the rest, and what needs
/// you, `NeedsYouColour`) and the
/// metrics and type are the same in every theme and stay on `IslandTheme`; Glass draws each through `tone(_:)`, its hue
/// kept and its lightness nudged for the glass's light or dark look only where a pair fails (P562). A view migrates by reading
/// `@Environment(\.juiceTheme)`, taking `private var palette: IslandPalette { theme.island }` and writing `palette.ink`
/// for `IslandTheme.ink` (P559); a token it needs that is not here is
/// added with its Black value taken from `IslandTheme`, so Black stays exactly as it was (`ThemeTests.blackIsTodaysTokensExactly`).
struct IslandPalette: Equatable, Sendable {
    // MARK: Surface
    /// What a view paints where it paints the surface itself (a fade into the edge, a peek's cover). Black: the pure
    /// black. Smoke: the glass's floor, the dark it lays over the glass (`GlassStyle.floor`). Glass: nothing (clear); a
    /// view that must hide what is under it on either glass knocks it out or leaves it undrawn (P558).
    var bg: Color
    /// A card, a key tag or a panel inside the surface.
    var card: Color

    // MARK: Ink
    var ink: Color
    var ink2: Color
    var ink3: Color
    /// Marks, not text (3:1 is enough): the idle glyph, hollow dots, rails.
    var idleMark: Color
    var headerIcon: Color
    var headerIconRest: Color
    var statusClean: Color
    var statusDetailed: Color
    var you: Color
    var rowAge: Color
    var toolVerb: Color
    var toolLine: Color
    var jump: Color
    var footer: Color
    var footerHover: Color
    var message: Color
    var groupCount: Color
    var kbd: Color
    var fieldPlaceholder: Color
    var codeText: Color
    var codeComment: Color
    var sendText: Color
    var tagHost: IslandTheme.TagColours
    var tagTime: IslandTheme.TagColours
    var tagJump: IslandTheme.TagColours

    // MARK: Separators
    var line: Color
    var usageHairline: Color
    var rowHoverStroke: Color
    var codeBorder: Color
    var fieldBorder: Color
    var fieldHoverBorder: Color

    // MARK: Fills
    var islandHover: Color
    var rowHover: Color
    var button: Color
    var codeBg: Color
    var fieldBg: Color
    var fieldHoverBg: Color
    var groupBg: Color
    var send: Color

    // MARK: Cards (the island lane: `CardTheme`'s and the cards' own greys, Black's values as the cards drew them)
    /// A card button under the pointer, the send button while the card is hovered.
    var buttonHover: Color
    var sendHover: Color
    /// A question's options: their ground, under the pointer, selected, the number's badge and its ink, the option's
    /// description; a card's key hint, reason and send line; a diff's unchanged lines.
    var optionBg: Color
    var optionHover: Color
    var optionSelected: Color
    var optionBadge: Color
    var optionBadgeText: Color
    var optionSub: Color
    var cardKbd: Color
    var reason: Color
    var diffContext: Color
    /// The chevron that takes an option's key's place on a hovered card (a mark).
    var optionChevron: Color

    // MARK: A Done card's message (wave 6, P430, P556)
    /// Fenced code's own box, a step above the message's ground (`codeBg`), and the table's rule under its header.
    var messageCodeBox: Color
    var messageRule: Color

    // MARK: Ink and fills Black drew straight from its statics (Glass, P563)
    /// The closed pill's count, and the top bar's idle brand glyph.
    var pillCount: Color
    var topBarIdle: Color
    /// A card's primary button (light on Black), under the pointer, its title and key hint; the send button once the
    /// field has text, and its arrow.
    var primary: Color
    var primaryHover: Color
    var primaryText: Color
    var kbdOnPrimary: Color
    var sendActive: Color
    var sendActiveInk: Color
    /// A question's option title, and its selected option's number (`optionBadgeSelected(_:)` is its badge).
    var optionTitle: Color
    var optionBadgeSelectedText: Color
    /// A diff's added and removed lines and their fills.
    var diffAdded: Color
    var diffRemoved: Color
    var diffAddedFill: Color
    var diffRemovedFill: Color
    /// A Done card's link and table header.
    var link: Color
    var messageHeader: Color
    /// The keys' row: its ring (`SelectionMark.ring`).
    var selectionRing: Color
    /// A hold's countdown along a light (Yes) and a dark (the reason field) ground.
    var holdOnPrimary: Color
    var holdOnField: Color
    /// The ring on a hovered battery or amount in the usage block.
    var hoverRing: Color

    /// Glass draws a state's or an agent's colour as its adaptive twin (`GlassTone`); Black and Smoke as it is.
    let adapts: Bool

    /// `colour` (a state's, an agent's) as this theme draws it as a mark (a glyph, a dot, a line): on Glass the same hue,
    /// a little lighter where the glass is dark and darker where it is light, only as far as a mark's 3:1 needs (P562).
    func tone(_ colour: Color) -> Color { adapts ? GlassTone.adapted(colour) : colour }

    /// `colour` as this theme draws it as a word (a status word, the Codex group's name): on Glass as `tone`, as far as
    /// text's 4.5:1 needs.
    func toneText(_ colour: Color) -> Color { adapts ? GlassTone.adapted(colour, .text) : colour }

    /// A question's selected option's edge, in the needs-you colour: at 40 %; on Glass's light look its mark twin at
    /// 50 %.
    func optionSelectedBorder(_ needsYou: NeedsYouColour) -> Color {
        adapts ? Self.adaptedOptionEdges[needsYou, default: needsYou.wait.opacity(0.4)] : needsYou.wait.opacity(0.4)
    }

    /// `optionSelectedBorder(_:)` on Glass and Solid for each choice, worked out once (`GlassTone.nudged` bisects).
    private static let adaptedOptionEdges = Dictionary(uniqueKeysWithValues: NeedsYouColour.allCases.map {
        ($0, Color.adaptive(light: GlassTone.nudged($0.wait, .light).opacity(0.5), dark: $0.wait.opacity(0.4)))
    })

    /// A question's selected option's number badge: the needs-you colour as a mark (`tone`).
    func optionBadgeSelected(_ needsYou: NeedsYouColour) -> Color { tone(needsYou.wait) }

    /// Today's island: `IslandTheme`'s own values, one for one.
    static let black = IslandPalette(
        bg: IslandTheme.bg, card: IslandTheme.card,
        ink: IslandTheme.ink, ink2: IslandTheme.ink2, ink3: IslandTheme.ink3, idleMark: IslandTheme.idleMark,
        headerIcon: IslandTheme.headerIcon, headerIconRest: IslandTheme.headerIconRest,
        statusClean: IslandTheme.statusClean, statusDetailed: IslandTheme.statusDetailed, you: IslandTheme.you,
        rowAge: IslandTheme.rowAge, toolVerb: IslandTheme.toolVerb, toolLine: IslandTheme.toolLine, jump: IslandTheme.jump,
        footer: IslandTheme.footer, footerHover: IslandTheme.footerHover, message: IslandTheme.message,
        groupCount: IslandTheme.groupCount, kbd: IslandTheme.kbd, fieldPlaceholder: IslandTheme.fieldPlaceholder,
        codeText: IslandTheme.codeText, codeComment: IslandTheme.codeComment, sendText: IslandTheme.sendText,
        tagHost: IslandTheme.tagHost, tagTime: IslandTheme.tagTime, tagJump: IslandTheme.tagJump,
        line: IslandTheme.line, usageHairline: IslandTheme.usageHairline, rowHoverStroke: IslandTheme.rowHoverStroke,
        codeBorder: IslandTheme.codeBorder, fieldBorder: IslandTheme.fieldBorder, fieldHoverBorder: IslandTheme.fieldHoverBorder,
        islandHover: IslandTheme.islandHover, rowHover: IslandTheme.rowHover, button: IslandTheme.button,
        codeBg: IslandTheme.codeBg, fieldBg: IslandTheme.fieldBg, fieldHoverBg: IslandTheme.fieldHoverBg,
        groupBg: IslandTheme.groupBg, send: IslandTheme.send,
        buttonHover: Color(hex: 0x2A2A2D), sendHover: Color(hex: 0x222222),
        optionBg: CardTheme.optionBg, optionHover: CardTheme.optionHover, optionSelected: CardTheme.optionSelected,
        optionBadge: CardTheme.optionBadge, optionBadgeText: CardTheme.optionBadgeText, optionSub: CardTheme.optionSub,
        cardKbd: CardTheme.kbd, reason: CardTheme.reason, diffContext: CardTheme.diffContext, optionChevron: IslandTheme.optionChevron,
        messageCodeBox: MessageTheme.codeBox, messageRule: MessageTheme.rule,
        pillCount: .white, topBarIdle: Color(hex: 0xE9EAEE),
        primary: IslandTheme.primary, primaryHover: Color.white, primaryText: IslandTheme.primaryText,
        kbdOnPrimary: IslandTheme.kbdOnPrimary, sendActive: IslandTheme.sendActive, sendActiveInk: .black,
        optionTitle: CardTheme.optionTitle, optionBadgeSelectedText: .black,
        diffAdded: CardTheme.diffAdded, diffRemoved: CardTheme.diffRemoved, diffAddedFill: CardTheme.diffAddedFill,
        diffRemovedFill: CardTheme.diffRemovedFill, link: MessageTheme.link, messageHeader: MessageTheme.header,
        selectionRing: SelectionMark.ring,
        holdOnPrimary: Color.black.opacity(0.24), holdOnField: Color.white.opacity(0.3), hoverRing: Color.white(0.35), adapts: false)

    /// Smoke: smoked glass (Glass until 2026-09-29). Its worst backdrop is a white window behind the island, which its floor turns #2E2E2E
    /// (`GlassStyle.floor` 0.82): every text token keeps 4.5:1 there and 4:1 on a hover fill, every mark 3:1, and
    /// every state and agent colour 3.6:1 or more (`GlassContrast`, `ThemeContrastTests`). The greys are lifted for
    /// that, in the same order as Black's, so the hierarchy reads the same; the fills are white or black veils, never
    /// opaque greys, so the glass shows through them.
    static let smoke = IslandPalette(
        bg: Color.black.opacity(GlassStyle.island.floor), card: Color.white.opacity(0.06),
        ink: IslandTheme.ink, ink2: Color(hex: 0xAAAAAF), ink3: Color(hex: 0xA0A0A5), idleMark: Color(hex: 0x87878C),
        headerIcon: IslandTheme.headerIcon, headerIconRest: Color(hex: 0x87878C),
        statusClean: Color(hex: 0xAEAEAE), statusDetailed: Color(hex: 0xBDBDBD), you: Color(hex: 0xA4A4A4),
        rowAge: Color(hex: 0xA2A2A6), toolVerb: Color(hex: 0x7299F6), toolLine: Color(hex: 0xA2A2A2), jump: Color(hex: 0x64ACCA),
        footer: Color(hex: 0xA2A2A2), footerHover: Color(hex: 0xBCBCBC), message: Color(hex: 0xD0D0D5),
        groupCount: Color(hex: 0xA0A0A5), kbd: Color(hex: 0xA2A2A6), fieldPlaceholder: Color(hex: 0xA4A4A9),
        codeText: IslandTheme.codeText, codeComment: Color(hex: 0xA0A0A5), sendText: Color(hex: 0xA0A0A5),
        tagHost: IslandTheme.TagColours(bg: Color.white.opacity(0.06), fg: Color(hex: 0xA8A8A8)),
        tagTime: IslandTheme.TagColours(bg: Color.white.opacity(0.04), fg: Color(hex: 0xA2A2A6)),
        tagJump: IslandTheme.TagColours(bg: Color(hex: 0x64ACCA, alpha: 0.12), fg: Color(hex: 0x64ACCA)),
        line: Color.white.opacity(0.12), usageHairline: Color.white.opacity(0.11), rowHoverStroke: Color.white.opacity(0.14),
        codeBorder: Color.white.opacity(0.10), fieldBorder: Color.white.opacity(0.14), fieldHoverBorder: Color.white.opacity(0.22),
        islandHover: Color.white.opacity(0.06), rowHover: Color.white.opacity(0.06), button: Color.white.opacity(0.09),
        codeBg: Color.black.opacity(0.35), fieldBg: Color.black.opacity(0.30), fieldHoverBg: Color.white.opacity(0.06),
        groupBg: Color.black.opacity(0.22), send: Color.black.opacity(0.30),
        // The cards' veils (the options a white one, the buttons' hover lighter than `button`) and greys lifted as the
        // island's: each text 4:1 or more on its fill over a white window (`IslandGlassContrastTests`).
        buttonHover: Color.white.opacity(0.15), sendHover: Color.white.opacity(0.10),
        optionBg: Color.white.opacity(0.05), optionHover: Color.white.opacity(0.08), optionSelected: Color.white.opacity(0.08),
        optionBadge: Color.white.opacity(0.10), optionBadgeText: Color(hex: 0xB4B4B9), optionSub: Color(hex: 0xB8B8BD),
        cardKbd: Color(hex: 0xAAAAAF), reason: Color(hex: 0xA4A4A9), diffContext: Color(hex: 0xAAAAAF), optionChevron: Color(hex: 0x9D938B),
        // A Done card's code box a white veil over the message's black one, its rule a veil as the island's lines are.
        messageCodeBox: Color.white.opacity(0.05), messageRule: Color.white.opacity(0.12),
        // What Black drew straight from its statics, as Black draws it (Smoke's floor keeps them legible).
        pillCount: .white, topBarIdle: Color(hex: 0xE9EAEE),
        primary: IslandTheme.primary, primaryHover: Color.white, primaryText: IslandTheme.primaryText,
        kbdOnPrimary: IslandTheme.kbdOnPrimary, sendActive: IslandTheme.sendActive, sendActiveInk: .black,
        optionTitle: CardTheme.optionTitle, optionBadgeSelectedText: .black,
        diffAdded: CardTheme.diffAdded, diffRemoved: CardTheme.diffRemoved, diffAddedFill: CardTheme.diffAddedFill,
        diffRemovedFill: CardTheme.diffRemovedFill, link: MessageTheme.link, messageHeader: MessageTheme.header,
        selectionRing: SelectionMark.ring,
        holdOnPrimary: Color.black.opacity(0.24), holdOnField: Color.white.opacity(0.3), hoverRing: Color.white(0.35), adapts: false)

    /// Glass: the system's glass with no black of ours (P560 to P563). Every token has a twin for each look the glass
    /// takes (`Color.adaptive`): light ink where it is dark, dark ink where it is light. Each holds its ratio on its look's
    /// worst surface (`GlassContrast.worstAdapted`: the dark glass at its brightest, the light glass at its darkest) and
    /// on a hover or card veil over it: text 4.5:1 (4:1 on a veil), marks 3:1 (`GlassThemeTests`). The greys
    /// keep Black's order, mirrored in the light look. The fills are veils (`GlassVeil`): the dark ink at a little
    /// opacity where the glass is light, white where it is dark, as the system's own fills on glass are: a card, a hover
    /// or a peek's ground is a lift of the glass, never a dark plate. What a view painted to hide something (`bg`) is
    /// nothing: on glass it knocks out, or is not drawn under (P558). The state and agent colours keep their hue
    /// (`tone`, `toneText`). Each ink and mark has a third twin for Glass look Widget's glass (`Color.glassInk`,
    /// `GlassTone.widget`, P879), held on the glass's dark face over a white window under Widget's least Frost: the ink
    /// white, the greys near white.
    static let glass = IslandPalette(
        bg: .clear, card: veil(0.04, 0.06),
        ink: .adaptive(light: Color(hex: 0x1C1C1E), dark: Color(hex: 0xF2F2F2), widget: .white),
        ink2: .glassInk(0x434347, 0xB8B8BD), ink3: .glassInk(0x4A4A4E, 0xB0B0B5),
        idleMark: .glassInk(0x5E5E62, 0x96969B, .mark),
        headerIcon: .glassInk(0x3C3C3C, 0xC0C0C0), headerIconRest: .glassInk(0x5E5E62, 0x96969B, .mark),
        statusClean: .glassInk(0x404040, 0xBCBCBC), statusDetailed: .glassInk(0x383838, 0xC6C6C6), you: .glassInk(0x474747, 0xB4B4B4),
        rowAge: .glassInk(0x48484C, 0xB2B2B6), toolVerb: GlassTone.adapted(IslandTheme.toolVerb, .text), toolLine: .glassInk(0x484848, 0xB2B2B2),
        jump: GlassTone.adapted(IslandTheme.jump, .text),
        footer: .glassInk(0x484848, 0xB2B2B2), footerHover: .glassInk(0x3A3A3A, 0xC4C4C4), message: .glassInk(0x2E2E32, 0xD4D4D9),
        groupCount: .glassInk(0x4A4A4E, 0xB0B0B5), kbd: .glassInk(0x48484C, 0xB2B2B6), fieldPlaceholder: .glassInk(0x48484C, 0xB8B8BD),
        codeText: .glassInk(0x232326, 0xE8E8EC), codeComment: .glassInk(0x4A4A4E, 0xB0B0B5), sendText: .glassInk(0x4A4A4E, 0xB0B0B5),
        tagHost: IslandTheme.TagColours(bg: veil(0.05, 0.06), fg: .glassInk(0x464646, 0xB6B6B6)),
        tagTime: IslandTheme.TagColours(bg: veil(0.04, 0.04), fg: .glassInk(0x48484C, 0xB2B2B6)),
        tagJump: IslandTheme.TagColours(bg: .adaptive(light: GlassTone.nudged(IslandTheme.jump, .light, .text).opacity(0.06),
                                                      dark: GlassTone.nudged(IslandTheme.jump, .dark, .text).opacity(0.08)),
                                        fg: GlassTone.adapted(IslandTheme.jump, .text)),
        line: veil(0.10, 0.12), usageHairline: veil(0.09, 0.10), rowHoverStroke: veil(0.12, 0.14),
        codeBorder: veil(0.10, 0.12), fieldBorder: veil(0.14, 0.16), fieldHoverBorder: veil(0.22, 0.24),
        islandHover: veil(GlassVeil.hover.light, GlassVeil.hover.dark), rowHover: veil(GlassVeil.hover.light, GlassVeil.hover.dark),
        button: veil(0.07, 0.09),
        codeBg: veil(0.04, 0.05), fieldBg: veil(0.03, 0.04), fieldHoverBg: veil(0.06, 0.07),
        groupBg: veil(0.03, 0.04), send: veil(0.05, 0.06),
        buttonHover: veil(0.11, 0.14), sendHover: veil(0.08, 0.10),
        optionBg: veil(GlassVeil.card.light, GlassVeil.card.dark), optionHover: veil(0.07, 0.07), optionSelected: veil(0.07, 0.07),
        optionBadge: veil(0.08, 0.08), optionBadgeText: .glassInk(0x434347, 0xC4C4C9), optionSub: .glassInk(0x414145, 0xC4C4C9),
        cardKbd: .glassInk(0x46464A, 0xBEBEC3), reason: .glassInk(0x47474B, 0xB4B4B9), diffContext: .glassInk(0x46464A, 0xB6B6BB),
        optionChevron: .glassInk(0x645D57, 0xA0968E, .mark),
        messageCodeBox: veil(0.04, 0.06), messageRule: veil(0.10, 0.12),
        // The pill's count and dots are the ink. The primary button and the send button are the one key that stands
        // out: Black's light grey on the dark glass, and on the light glass (where a light key would vanish and a dark
        // one would be the black plate Glass has none of) the running blue, as a Mac's default button is its accent.
        pillCount: .adaptive(0x1C1C1E, 0xFFFFFF), topBarIdle: .glassInk(0x222226, 0xE9EAEE, .mark),
        primary: .adaptive(light: Self.lightKey, dark: Color(hex: 0xF2F2F2)),
        primaryHover: .adaptive(light: Self.lightKeyHover, dark: Color(hex: 0xFFFFFF)), primaryText: .adaptive(0xFFFFFF, 0x000000),
        kbdOnPrimary: .adaptive(light: Color.white.opacity(0.72), dark: Color(hex: 0x555555)),
        sendActive: .adaptive(light: Self.lightKey, dark: Color(hex: 0xE5E5E5)), sendActiveInk: .adaptive(0xFFFFFF, 0x000000),
        optionTitle: .glassInk(0x242423, 0xE9E8E7), optionBadgeSelectedText: .adaptive(0xFFFFFF, 0x000000),
        diffAdded: GlassTone.adapted(CardTheme.diffAdded, .text), diffRemoved: GlassTone.adapted(CardTheme.diffRemoved, .text),
        diffAddedFill: .adaptive(light: GlassTone.nudged(CardTheme.diffAdded, .light, .text).opacity(0.07), dark: Color(hex: 0x6FB982, alpha: 0.08)),
        diffRemovedFill: .adaptive(light: GlassTone.nudged(CardTheme.diffRemoved, .light, .text).opacity(0.07), dark: Color(hex: 0xF08A80, alpha: 0.08)),
        link: .glassInk(0x232326, 0xE8E8EC), messageHeader: .glassInk(0x232326, 0xE8E8EC),
        selectionRing: veil(0.24, 0.22),
        holdOnPrimary: GlassVeil.lightInk.opacity(0.24), holdOnField: veil(0.18, 0.3),
        hoverRing: veil(0.35, 0.35), adapts: true)

    /// A Glass veil (`GlassVeil`).
    private static func veil(_ light: Double, _ dark: Double) -> Color { GlassVeil.colour(light: light, dark: dark) }

    /// The light glass's key: the running blue as a mark on the light look (its hue kept), and a step darker under the
    /// pointer; white titles hold 4.5:1 on either.
    static let lightKey = GlassTone.nudged(IslandTheme.run, .light)
    static let lightKeyHover = GlassTone.nudged(IslandTheme.run, .light).mix(with: .black, by: 0.12)
}

/// Juice's own theme-dependent tokens (`Theme`): the desktop panel, the batteries and the money rows, wherever they show.
struct PanelPalette: Equatable, Sendable {
    /// What a view paints where it paints the surface (a battery's cut, a digit's halo). Smoke and Glass: see
    /// `IslandPalette.bg`.
    var surface: Color
    var ink: Color
    var ink2: Color
    /// A battery's empty body.
    var track: Color
    var line: Color
    var divider: Color
    /// The panel's own outline (Black's 0.5 pt edge; on glass the glass's rim draws it, `GlassStyle.panel`).
    var edge: Color
    /// Glass draws the amber and red amounts, the key and the battery's low fill as their adaptive twins (`tone`).
    let adapts: Bool

    /// `colour` (the amber, the red) as this theme draws it as a mark (`IslandPalette.tone`).
    func tone(_ colour: Color) -> Color { adapts ? GlassTone.adapted(colour) : colour }

    /// `colour` as this theme draws it as a word, an amount (`IslandPalette.toneText`).
    func toneText(_ colour: Color) -> Color { adapts ? GlassTone.adapted(colour, .text) : colour }

    /// Today's panel: `Theme`'s own values.
    static let black = PanelPalette(surface: Theme.surface, ink: Theme.ink, ink2: Theme.ink2, track: Theme.track,
                                    line: Theme.line, divider: Theme.divider, edge: Theme.edge, adapts: false)

    /// Smoke, on the panel's smoked glass (`GlassStyle.panel`, the same floor as the island's): its ink and ink2 already
    /// hold 12:1 and 6:1 over a white desktop; the track is a white veil (over a black desktop it is Black's #272725
    /// again, over a white one a lighter well) and the divider a little brighter.
    static let smoke = PanelPalette(surface: Color.black.opacity(GlassStyle.panel.floor), ink: Theme.ink, ink2: Theme.ink2,
                                    track: Color.white.opacity(0.14), line: Theme.line, divider: Color.white.opacity(0.16),
                                    edge: Color.white.opacity(0.24), adapts: false)

    /// Glass: the island's Glass inks (`IslandPalette.glass`, their Widget twins too), the track, the divider and the edge
    /// veils of the ink (`GlassVeil`), the outline a mark's grey. `surface` is nothing: a battery's cut on glass knocks out
    /// (`BatteryCut`), and Glass never paints the black.
    static let glass = PanelPalette(surface: .clear, ink: .adaptive(light: Color(hex: 0x1B1B19), dark: Color(hex: 0xF4F4F0), widget: .white),
                                    ink2: .glassInk(0x4B4B48, 0xB1B1AB),
                                    track: GlassVeil.colour(light: 0.10, dark: 0.14), line: .glassInk(0x5F5F5C, 0x979793, .mark),
                                    divider: GlassVeil.colour(light: 0.12, dark: 0.16), edge: GlassVeil.colour(light: 0.14, dark: 0.24),
                                    adapts: true)
}
