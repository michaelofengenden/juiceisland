import AppKit
import IslandEngine
import JuiceCore
import SwiftUI

/// Settings › Island (spec §4.5): look and screen, usage, sessions, quiet, mute rules. Labels only, except Glance, Quota
/// alerts, Questions open the island (off), Stalled after, Archive idle sessions after, Show scripted runs, Answer
/// subagents and Answer Codex in Juice, Quiet while locked, Quiet while presenting, Quiet during Focus and Quiet
/// hours, whose effects are not obvious. Owner: stream A.
struct IslandPane: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Bumped when a display comes, goes or changes, so Display lists the screens connected now.
    @State private var screensChanged = 0

    var body: some View {
        @Bindable var settings = env.settings
        FormPane {
            FormSection {
                // One group, so no separator comes between the choice and its preview (as Glyph style's).
                VStack(spacing: 0) {
                    FormRow("Theme", subtitle: IslandPaneText.themeNote(settings.juiceTheme)) {
                        SettingsSegmented(selection: $settings.juiceTheme, options: JuiceTheme.allCases.map { ($0, $0.title) }, label: "Theme")
                    }
                    // Glass's look, under its choice: the desktop widgets' or the Appearance's (`GlassLookChoice`).
                    if IslandPaneText.showsGlassLookRow(settings.juiceTheme) {
                        FormRow("Glass look") {
                            SettingsSegmented(selection: $settings.glassLook, options: GlassLookChoice.allCases.map { ($0, $0.title) },
                                              label: "Glass look")
                        }
                    }
                    // Glass's Frost, under its choice: today's Glass at the left, frosted at the right (`GlassFrost`).
                    if IslandPaneText.showsFrostRow(settings.juiceTheme) {
                        FormRow("Frost") {
                            FrostSlider(value: $settings.glassFrost)
                        }
                    }
                    ThemePreview(theme: settings.juiceTheme)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
                }
                if IslandPaneText.showsStateTintRow(settings.juiceTheme) {
                    FormRow("State tint") {
                        SettingsSwitch(isOn: $settings.islandStateTint, label: "State tint")
                    }
                }
                FormRow("Style") {
                    SettingsSegmented(selection: $settings.islandStyle, options: [(.clean, "Clean"), (.detailed, "Detailed")], label: "Island style")
                }
                // Clean only: Detailed rows always say both (P1015).
                if IslandPaneText.showsRowFactRows(settings.islandStyle) {
                    FormRow("Show model") {
                        SettingsSwitch(isOn: $settings.rowShowsModel, label: "Show the model on rows")
                    }
                    FormRow("Show branch") {
                        SettingsSwitch(isOn: $settings.rowShowsBranch, label: "Show the branch on rows")
                    }
                }
                // The connected screens (P940): Automatic, Follow focus, or one screen, listed again when a display comes or goes.
                let displays = IslandDisplays.connected()
                if IslandDisplays.showsRow(displays, stored: settings.islandDisplay) {
                    FormRow("Display", subtitle: IslandDisplays.subtitle(displays, stored: settings.islandDisplay)) {
                        SettingsPopup(selection: $settings.islandDisplay, options: IslandDisplays.choices(displays, stored: settings.islandDisplay),
                                      label: "Island display")
                    }
                    .id(screensChanged)
                }
                FormRow("Width") {
                    SettingsSegmented(selection: $settings.islandWidth, options: IslandPaneText.widths, label: "Island width")
                }
                FormRow("Text size") {
                    SettingsSegmented(selection: $settings.islandTextSize, options: IslandPaneText.textSizes, label: "Island text size")
                }
                // Under Reduce Motion the island only fades and snaps, the same in either feel.
                if IslandPaneText.showsMotionRow(reduceMotion: reduceMotion, flavor: env.flavor) {
                    FormRow("Motion") {
                        SettingsSegmented(selection: $settings.islandMotion, options: IslandPaneText.motions, label: "Island motion")
                    }
                }
                FormRow("Hover") {
                    SettingsSegmented(selection: $settings.islandHover, options: [(.calm, "Calm"), (.quick, "Quick")], label: "Hover")
                }
                FormRow("Haptic feedback on hover") {
                    SettingsSwitch(isOn: $settings.hapticOnHover, label: "Haptic feedback on hover")
                }
            }
            FormSection("Usage") {
                FormRow("Show usage") {
                    SettingsSwitch(isOn: $settings.islandShowsUsage, label: "Show usage in the island")
                }
                // Placement means nothing while usage is hidden, so the row shows only with it.
                if settings.islandShowsUsage {
                    FormRow("Placement") {
                        SettingsSegmented(selection: $settings.islandUsagePlacement,
                                          options: [(.section, "Section"), (.headerStrip, "Strip")], label: "Usage placement in the island")
                    }
                    // The accounts your sessions use, or the Next one, first in the strip and the block (P813).
                    FormRow("Shows first") {
                        SettingsSegmented(selection: $settings.usageFirst, options: [(.inUse, "In use"), (.next, "Next")],
                                          label: "Usage shows first")
                    }
                }
                FormRow("Show money") {
                    SettingsSwitch(isOn: $settings.islandShowsMoney, label: "Show money in the island")
                }
                FormRow("Hover details") {
                    SettingsSwitch(isOn: $settings.hoverDetails, label: "Hover details")
                }
                FormRow("Quota alerts", subtitle: "At 90 %, running out, and back.") {
                    SettingsSwitch(isOn: $settings.quotaAlerts, label: "Quota alerts")
                }
            }
            FormSection("Sessions") {
                // One group, so no separator comes between the choice and its preview.
                VStack(spacing: 0) {
                    FormRow("Glyph style") {
                        SettingsSegmented(selection: $settings.glyphStyle, options: [(.pixel, "Pixel"), (.liquid, "Liquid"), (.sand, "Sand")],
                                          label: "Glyph style")
                    }
                    GlyphStylePreview(style: settings.glyphStyle)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(EdgeInsets(top: 0, leading: 12, bottom: 10, trailing: 12))
                }
                // Liquid's running look; the preview above shows the choice.
                if IslandPaneText.showsRunningRow(settings.glyphStyle) {
                    FormRow("Running") {
                        SettingsSegmented(selection: $settings.liquidRunning, options: [(.slim, "Slim"), (.full, "Full")], label: "Running glyph")
                    }
                }
                if IslandPaneText.showsEdgeLineRow(settings.glyphStyle) {
                    FormRow("Pill edge line") {
                        SettingsSwitch(isOn: $settings.glyphEdgeLine, label: "Pill edge line")
                    }
                }
                FormRow("Glyph colour") {
                    SettingsSegmented(selection: $settings.glyphColour, options: [(.byState, "By state"), (.byAgent, "By agent")], label: "Glyph colour")
                }
                FormRow("Needs you colour") {
                    SettingsSegmented(selection: $settings.needsYouColour, options: NeedsYouColour.allCases.map { ($0, $0.title) },
                                      label: "Needs you colour")
                }
                FormRow("Pill count") {
                    SettingsSegmented(selection: $settings.closedPillCount,
                                      options: [(.active, "Active"), (.needsYou, "Needs you")], label: "Closed-pill count")
                }
                FormRow("When a session finishes", subtitle: IslandPaneText.finish(settings.whenSessionFinishes)) {
                    SettingsSegmented(selection: $settings.whenSessionFinishes, options: [(.card, "Card"), (.glance, "Glance")],
                                      label: "When a session finishes")
                }
                FormRow("Questions open the island", subtitle: IslandPaneText.questions(settings.questionsOpenIsland)) {
                    SettingsSwitch(isOn: $settings.questionsOpenIsland, label: "Questions open the island")
                }
                FormRow("Peek on hover") {
                    SettingsSwitch(isOn: $settings.sessionPeek, label: "Peek on hover")
                }
                FormRow("Stalled after", subtitle: IslandPaneText.stalled) {
                    SettingsSegmented(selection: $settings.stalledAfter,
                                      options: [(.off, "Off"), (.fiveMinutes, "5 min"), (.tenMinutes, "10 min"), (.thirtyMinutes, "30 min")],
                                      label: "Stalled after")
                }
                FormRow("Archive idle sessions after", subtitle: IslandPaneText.archiveIdle) {
                    SettingsSegmented(selection: $settings.archiveIdleAfter, options: ArchiveAfter.allCases.map { ($0, $0.label) },
                                      label: "Archive idle sessions after")
                }
                FormRow("Hide the pill when idle") {
                    SettingsSwitch(isOn: $settings.hidePillWhenIdle, label: "Hide the pill when no session is active")
                }
                FormRow("Update dot on the pill") {
                    SettingsSwitch(isOn: $settings.pillUpdateDot, label: "Update dot on the pill")
                }
                FormRow("Show scripted runs", subtitle: IslandPaneText.scriptedRuns) {
                    SettingsSwitch(isOn: $settings.showScriptedRuns, label: "Show scripted runs")
                }
                FormRow("Answer subagents on the island", subtitle: IslandPaneText.answerSubagents) {
                    SettingsSwitch(isOn: $settings.answerSubagentsOnIsland, label: "Answer subagents on the island")
                }
                FormRow(IslandPaneText.answerCodexTitle, subtitle: IslandPaneText.answerCodex) {
                    SettingsSwitch(isOn: $settings.answerCodexOnIsland, label: IslandPaneText.answerCodexTitle)
                }
            }
            FormSection("Quiet") {
                FormRow("Hide in full screen") {
                    SettingsSwitch(isOn: $settings.hideInFullScreen, label: "Hide in full screen")
                }
                // What full screen still shows means nothing while the pill shows there, so the row shows only with it.
                if settings.hideInFullScreen {
                    FormRow("Show needs you") {
                        SettingsSwitch(isOn: $settings.fullScreenShowsNeedsYou, label: "Show what needs you in full screen")
                    }
                }
                FormRow("Quiet while locked", subtitle: IslandPaneText.quietWhileLocked) {
                    SettingsSwitch(isOn: $settings.quietWhileLocked, label: "Quiet while locked")
                }
                FormRow("Quiet while presenting", subtitle: IslandPaneText.quietWhilePresenting) {
                    SettingsSwitch(isOn: $settings.quietWhilePresenting, label: "Quiet while presenting")
                }
                // A Focus is heard through the app's Focus filter, set in System Settings (P1006).
                FormRow("Quiet during Focus", subtitle: IslandPaneText.focus(quietNow: env.quietScenes?.focusQuiet == true,
                                                                                 product: env.flavor.productName)) {
                    PushButton(title: "Open", small: true) { FocusSettings.open() }
                        .help("Open System Settings › Focus")
                        .accessibilityLabel("Open Focus settings")
                }
                FormRow("Quiet hours", subtitle: IslandPaneText.quietHours) {
                    SettingsSwitch(isOn: $settings.quietHours, label: "Quiet hours")
                }
                if settings.quietHours {
                    FormRow("From") {
                        QuietHoursRange(from: $settings.quietFrom, to: $settings.quietTo)
                    }
                }
            }
            MuteRulesSection(rules: $settings.muteRules)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screensChanged &+= 1
        }
    }
}

/// Quiet hours' span: two pop-ups of half hours, "22:00 to 08:00", in the owner's clock (12 or 24 hours).
struct QuietHoursRange: View {
    @Binding var from: Int
    @Binding var to: Int
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 8) {
            SettingsPopup(selection: $from, options: QuietHours.options(around: from, locale: locale), label: "Quiet hours start")
            Text("to").font(SettingsTheme.TypeScale.row).foregroundStyle(SettingsTheme.ink2)
            SettingsPopup(selection: $to, options: QuietHours.options(around: to, locale: locale), label: "Quiet hours end")
        }
    }
}

/// The Island pane's subtitles: Glance says what it does (Card needs no words), and Show scripted runs and Stalled after
/// say what counts, which their names alone do not.
enum IslandPaneText {
    static func finish(_ behaviour: FinishBehaviour) -> String? {
        behaviour == .glance ? "A green dot on the pill; the island stays closed." : nil
    }

    static let scriptedRuns = "Headless and plugin runs."

    /// Questions open the island, off: where a question shows instead (P411). On needs no words.
    static func questions(_ open: Bool) -> String? { open ? nil : "A ? on the pill until you hover." }

    /// What Answer subagents on the island costs, which its name alone does not say (P350).
    static let answerSubagents = "Claude's own prompt waits up to \(Int(SubagentHold.limit)) s."

    /// The switch's name: Juice, as it answers on the island and in the window (P1050); "Answer Codex on the island"
    /// until the owner's 2026-10-05, its stored key and default unchanged (P1250).
    static let answerCodexTitle = "Answer Codex in Juice"

    /// What Answer Codex in Juice costs, which its name alone does not say (P470).
    static let answerCodex = "Codex's own prompt waits up to \(Int(CodexHold.limit)) s."

    /// What Stalled after measures, which its name alone does not say.
    static let stalled = "A running session with no activity."

    /// What Archive idle sessions after takes, which its name alone does not say (P727): never one at work or waiting.
    static let archiveIdle = "Done sessions only, as Archive does."

    /// What Quiet hours holds back, which its name alone does not say: the pill still shows.
    static let quietHours = "No sounds or pop-ups."

    /// What Quiet while locked does once the owner is back, which its name alone does not say (P423).
    static let quietWhileLocked = "What waits shows on unlock."

    /// What Quiet while presenting hears (P1005): mirroring only, as no app may see a screen being shared (P1004).
    static let quietWhilePresenting = "While the screen is mirrored."

    /// Quiet during Focus: where it is set (the app's Focus filter, P1006), or, while a Focus quiets the island, that it
    /// does. `product`: the flavor's name, as System Settings lists the app.
    static func focus(quietNow: Bool, product: String = Product.name) -> String {
        quietNow ? "Quiet now, for a Focus." : "Add \(product) as a filter in System Settings › Focus."
    }

    /// Show model and Show branch show only under Clean: Detailed rows always say both (P1015).
    static func showsRowFactRows(_ style: IslandStyle) -> Bool { style == .clean }

    /// Motion's three feels, as its segments name them.
    static let motions: [(MotionFeel, String)] = [(.original, "Original"), (.refined, "Refined"), (.liquid, "Liquid")]

    /// Pill edge line shows only under Liquid and Sand: Pixel draws no line.
    static func showsEdgeLineRow(_ style: GlyphStyle) -> Bool { style != .pixel }

    /// Running (Slim or Full) shows only under Liquid: Pixel's equalizer and Sand's pour have one look each.
    static func showsRunningRow(_ style: GlyphStyle) -> Bool { style == .liquid }

    /// Solid's one line under Theme: what it follows, which its name alone does not say (P770).
    static func themeNote(_ theme: JuiceTheme) -> String? { theme == .solid ? "Follows Appearance. Dark takes the wallpaper's tint." : nil }

    /// Glass look shows only under Glass: the other themes have no glass whose face to choose (P870).
    static func showsGlassLookRow(_ theme: JuiceTheme) -> Bool { theme == .glass }

    /// Frost shows only under Glass: Black, Smoke and Solid have no glass of their own to frost.
    static func showsFrostRow(_ theme: JuiceTheme) -> Bool { theme == .glass }

    /// State tint shows under Black (an edge), Glass and Solid (a veil); Smoke takes none.
    static func showsStateTintRow(_ theme: JuiceTheme) -> Bool { theme != .smoke }

    /// Motion shows only while macOS Reduce Motion is off: with it on, the island only fades and snaps in either feel. It
    /// is the owner's A/B, so the public flavor never shows it and runs on its default (P1060); Hover stays in both.
    static func showsMotionRow(reduceMotion: Bool, flavor: AppFlavor = .current) -> Bool { !reduceMotion && !flavor.isPublic }

    /// Width's and Text size's steps (`IslandSize`), in points: the numbers alone.
    static let widths: [(Int, String)] = IslandSize.widths.map { ($0, "\($0)") }
    static let textSizes: [(Int, String)] = IslandSize.textSizes.map { ($0, "\($0)") }
}

/// Glyph style's live preview, under its choice: running (in Liquid, in the Running look chosen under it), delegating,
/// an approval, a question and done at 21 pt, as the window's rows draw them, in the Glyph colour and the Needs you
/// colour, on the island's
/// ground: Black's and Smoke's black; on Glass and Solid the ground of the look they take now (Settings' own), the
/// glyphs in Glass's finish for it (P779). No labels: the glyphs say it.
struct GlyphStylePreview: View {
    var style: GlyphStyle
    @Environment(AppEnvironment.self) private var env
    @Environment(\.sessionGlyphsAnimated) private var animated

    /// The ground on Glass and Solid: Frost's light ground where Settings is light (it stands apart from a white group),
    /// Black's black where it is dark.
    static let adaptedGround = Color.adaptive(light: GlassFrost.light, dark: IslandTheme.bg)

    static let glyphs: [PixelGlyph] = [.eq, .agents, .bang, .ques, .check]

    /// The state each preview glyph stands for, for its colour.
    static func state(_ glyph: PixelGlyph) -> GlyphPalette.State {
        switch glyph {
        case .eq: .running
        case .agents: .delegating
        case .check: .done
        default: .waiting
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Self.glyphs, id: \.self) { glyph in
                StateGlyphView(glyph: glyph, colour: GlyphPalette.colour(agent: .claude, state: Self.state(glyph), mode: env.settings.glyphColour,
                                                                    needsYou: env.settings.needsYouColour),
                               pixel: 3, animated: animated, style: style, liquidRunning: env.settings.liquidRunning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .modifier(GlyphPreviewGround(theme: env.settings.juiceTheme))
        .accessibilityHidden(true)
    }
}

/// `GlyphStylePreview`'s ground and finish: on Black and Smoke Black's black and plain glyphs as they always were, in
/// either look of Settings; on Glass and Solid the adapted ground with the glyphs' Glass finish.
private struct GlyphPreviewGround: ViewModifier {
    let theme: JuiceTheme

    func body(content: Content) -> some View {
        if theme.adapts {
            content
                .background(RoundedRectangle(cornerRadius: 8).fill(GlyphStylePreview.adaptedGround))
                .environment(\.juiceTheme, theme)
        } else {
            content
                .background(RoundedRectangle(cornerRadius: 8).fill(IslandTheme.bg))
                .environment(\.juiceTheme, .black)
        }
    }
}

/// The desktop panel's Display choices in renders and tests: nil is the primary display. The app lists the connected
/// screens (`PanelDisplays.provider`); the island's list is `IslandDisplays`.
enum DisplayChoices {
    static let panel: [(String?, String)] = [(nil, "Built-in Retina Display"), ("studio", "Studio Display")]
}
