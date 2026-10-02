import Foundation
import JuiceCore
import Observation

/// Every persisted option of spec §4.5 and prototype.md §7.1, with its default. Keys are `ji.<group>.<name>`.
/// Views read and write these properties directly; each write goes straight to `UserDefaults`.
/// Renders and tests use `AppSettings.ephemeral()`, which keeps everything in memory and writes no defaults at all.
@MainActor
@Observable
final class AppSettings {
    enum Key {
        static let showAs = "ji.general.showAs"
        static let appearance = "ji.general.appearance"
        static let launchAtLogin = "ji.general.launchAtLogin"
        static let loginItemRegistered = "ji.general.loginItemRegistered"
        static let dockIconInIslandMode = "ji.general.dockIconInIslandMode"
        static let menuBarItem = "ji.general.menuBarItem"
        static let windowHeader = "ji.window.header"
        static let windowShowsMoney = "ji.window.showsMoney"
        static let accountNamesUnderBatteries = "ji.window.accountNames"
        static let keepOpenUntilDecision = "ji.behavior.keepOpenUntilDecision"
        static let replyFromCompletionCard = "ji.behavior.replyFromCompletionCard"
        static let modeChoicesOnCards = "ji.behavior.modeChoicesOnCards"
        static let suppressForFocusedSessions = "ji.behavior.suppressForFocusedSessions"
        static let notificationBanners = "ji.behavior.notificationBanners"
        static let followUpAfter = "ji.behavior.followUpAfter"
        static let showCodexAppThreads = "ji.general.showCodexAppThreads"
        static let liveSessions = "ji.general.liveSessions"
        static let islandStyle = "ji.island.style"
        static let islandShowsUsage = "ji.island.showsUsage"
        static let islandUsagePlacement = "ji.island.usagePlacement"
        static let usageFirst = "ji.island.usageFirst"
        static let islandShowsMoney = "ji.island.showsMoney"
        static let hoverDetails = "ji.island.hoverDetails"
        static let glyphColour = "ji.island.glyphColour"
        static let needsYouColour = "ji.island.needsYouColour"
        static let glyphStyle = "ji.island.glyphStyle"
        static let glyphEdgeLine = "ji.island.glyphEdgeLine"
        static let liquidRunning = "ji.island.liquidRunning"
        static let closedPillCount = "ji.island.closedPillCount"
        static let whenSessionFinishes = "ji.island.whenSessionFinishes"
        static let questionsOpenIsland = "ji.island.questionsOpenIsland"
        static let hidePillWhenIdle = "ji.island.hidePillWhenIdle"
        static let showScriptedRuns = "ji.island.showScriptedRuns"
        static let answerSubagents = "ji.island.answerSubagents"
        static let answerCodex = "ji.island.answerCodex"
        static let sessionPeek = "ji.island.sessionPeek"
        static let stalledAfter = "ji.island.stalledAfter"
        static let islandDisplay = "ji.island.display"
        static let hapticOnHover = "ji.island.hapticOnHover"
        static let quotaAlerts = "ji.island.quotaAlerts"
        static let islandMotion = "ji.island.motion"
        static let islandHover = "ji.island.hover"
        static let islandWidth = "ji.island.width"
        static let islandTextSize = "ji.island.textSize"
        static let pillUpdateDot = "ji.island.pillUpdateDot"
        static let hideInFullScreen = "ji.island.hideInFullScreen"
        static let fullScreenShowsNeedsYou = "ji.island.fullScreenShowsNeedsYou"
        static let quietHours = "ji.island.quietHours"
        static let quietFrom = "ji.island.quietFrom"
        static let quietTo = "ji.island.quietTo"
        static let quietWhileLocked = "ji.island.quietWhileLocked"
        static let muteRules = "ji.island.muteRules"
        static let snoozedUntil = "ji.island.snoozedUntil"
        static let archiveIdleAfter = "ji.island.archiveIdleAfter"
        static let soundsMuted = "ji.sound.muted"
        static let needsYouSound = "ji.sound.needsYou"
        static let doneSound = "ji.sound.done"
        static let questionSound = "ji.sound.question"
        static let soundVolume = "ji.sound.volume"
        static let globalJumpEnabled = "ji.shortcuts.globalJumpEnabled"
        static let globalJumpKey = "ji.shortcuts.globalJumpKey"
        static let globalKeyAction = "ji.shortcuts.globalKeyAction"
        static let panelShowOnDesktop = "ji.panel.showOnDesktop"
        static let panelLocked = "ji.panel.locked"
        static let panelDisplay = "ji.panel.display"
        static let panelCorner = "ji.panel.corner"
        static let runwayAmberHours = "ji.money.runwayAmberHours"
        static let runwayRedHours = "ji.money.runwayRedHours"
        static func moneyShown(_ id: MoneyAccount) -> String { "ji.money.shown.\(id.rawValue)" }
        static let usageSource = "ji.usage.source"
        static let recordIslandMotion = "ji.diagnostics.recordIslandMotion"
        static let paceIslandMotion = "ji.diagnostics.paceIslandMotion"
        static let islandOutline = "ji.diagnostics.islandOutline"
        static let juiceTheme = "ji.island.theme"
        static let islandStateTint = "ji.island.stateTint"
        static let glassFrost = "ji.island.glassFrost"
        static let glassLook = "ji.island.glassLook"
        static let prepareUpdates = "ji.update.prepare"
        static let whatsNewShown = "ji.update.whatsNewShown"
    }

    /// Diagnostics › Motion › Outline until the owner picks (`IslandOutline`): Core Animation, as every fail-closed check
    /// holds (P240) and its edge keeps moving through a stalled main thread (`CoreAnimationOutlineLiveTests`).
    static let defaultOutline = IslandOutline.coreAnimation

    /// The Needs you sound until the owner picks one (spec §4.5: "a system sound").
    static let defaultNeedsYouSound = SoundChoice.system("Glass")

    @ObservationIgnored private let defaults: UserDefaults?

    // MARK: General
    var showAs: ShowAs { didSet { save(showAs.rawValue, Key.showAs) } }
    /// Settings › General › Appearance (`AppearanceChoice`): System follows macOS's light or dark mode live, Light and
    /// Dark pin it (`AppAppearance`). Settings follows it in every theme; the window, the island, the panel and its chip on
    /// Glass and Solid only (Black and Smoke stay dark, P760). System; an unknown stored word reads as System (P761).
    var appearance: AppearanceChoice { didSet { save(appearance.rawValue, Key.appearance) } }
    var launchAtLogin: Bool { didSet { save(launchAtLogin, Key.launchAtLogin) } }
    /// The app has registered its login item once: from then on only the switch registers it, never a launch, so an
    /// item the owner removed in System Settings stays removed (P140).
    var loginItemRegistered: Bool { didSet { save(loginItemRegistered, Key.loginItemRegistered) } }
    /// Island mode only: Window mode always shows the Dock icon.
    var dockIconInIslandMode: Bool { didSet { save(dockIconInIslandMode, Key.dockIconInIslandMode) } }
    /// Juice's status item (C16). Off by default; nothing is created while it is off.
    var menuBarItem: Bool { didSet { save(menuBarItem, Key.menuBarItem) } }
    var windowHeader: HeaderLayout { didSet { save(windowHeader.rawValue, Key.windowHeader) } }
    var windowShowsMoney: Bool { didSet { save(windowShowsMoney, Key.windowShowsMoney) } }
    var accountNamesUnderBatteries: Bool { didSet { save(accountNamesUnderBatteries, Key.accountNamesUnderBatteries) } }
    var keepOpenUntilDecision: Bool { didSet { save(keepOpenUntilDecision, Key.keepOpenUntilDecision) } }
    /// C6: the Done card's reply field shows only while this is on.
    var replyFromCompletionCard: Bool { didSet { save(replyFromCompletionCard, Key.replyFromCompletionCard) } }
    /// A Claude plan or approval the island answers offers a button per permission mode it can switch the session to
    /// with the Allow (Accept edits, Manual, Bypass permissions where Claude takes it; P450). On. Off: no mode button,
    /// and no mode is ever sent.
    var modeChoicesOnCards: Bool { didSet { save(modeChoicesOnCards, Key.modeChoicesOnCards) } }
    var suppressForFocusedSessions: Bool { didSet { save(suppressForFocusedSessions, Key.suppressForFocusedSessions) } }
    /// macOS notification banners for what needs you and a finished turn of the owner's, when the island does not show
    /// it itself (`Banners`, P412). Off; macOS is asked for permission only when the owner turns it on.
    var notificationBanners: Bool { didSet { save(notificationBanners, Key.notificationBanners) } }
    /// One reminder, this long after a request began to wait or a turn finished, for what the owner has not looked at
    /// (`FollowUps`, P410). Off.
    var followUpAfter: FollowUpDelay { didSet { save(followUpAfter.rawValue, Key.followUpAfter) } }
    var showCodexAppThreads: Bool { didSet { save(showCodexAppThreads, Key.showCodexAppThreads) } }
    /// Spec §5.3, §8 decision 11: the bridge on Open Island's hook socket, only while Open Island is quit. On by
    /// default in the production app; off by default in development builds, where the demo sessions show.
    var liveSessions: Bool { didSet { save(liveSessions, Key.liveSessions) } }

    // MARK: Island
    var islandStyle: IslandStyle { didSet { save(islandStyle.rawValue, Key.islandStyle) } }
    var islandShowsUsage: Bool { didSet { save(islandShowsUsage, Key.islandShowsUsage) } }
    var islandUsagePlacement: UsagePlacement { didSet { save(islandUsagePlacement.rawValue, Key.islandUsagePlacement) } }
    /// What the island's usage puts first: the accounts in use, then the rest, the strip showing the first of them; or
    /// the Next one, in the account list's order (P813).
    var usageFirst: UsageFirst { didSet { save(usageFirst.rawValue, Key.usageFirst) } }
    var islandShowsMoney: Bool { didSet { save(islandShowsMoney, Key.islandShowsMoney) } }
    /// Shared by the island, the window and (ignored by) the desktop panel.
    var hoverDetails: Bool { didSet { save(hoverDetails, Key.hoverDetails) } }
    var glyphColour: GlyphColourMode { didSet { save(glyphColour.rawValue, Key.glyphColour) } }
    /// What needs you, in every glyph style and on every surface: Pink, Violet or Orange (`NeedsYouColour`, P780).
    var needsYouColour: NeedsYouColour { didSet { save(needsYouColour.rawValue, Key.needsYouColour) } }
    /// What draws every session glyph: Pixel's 7 × 7 pixels, or the Liquid or Sand engine. The brand glyph stays Pixel.
    var glyphStyle: GlyphStyle { didSet { save(glyphStyle.rawValue, Key.glyphStyle) } }
    /// Liquid and Sand only: a line along the closed pill's bottom edge while a session runs.
    var glyphEdgeLine: Bool { didSet { save(glyphEdgeLine, Key.glyphEdgeLine) } }
    /// Liquid only: how a running session's glyph looks, slim (a band a crest runs along) or full (the round body).
    var liquidRunning: LiquidRunningLook { didSet { save(liquidRunning.rawValue, Key.liquidRunning) } }
    var closedPillCount: PillCount { didSet { save(closedPillCount.rawValue, Key.closedPillCount) } }
    var whenSessionFinishes: FinishBehaviour { didSet { save(whenSessionFinishes.rawValue, Key.whenSessionFinishes) } }
    /// A question (or a form) opens the island by itself, as an approval does. Off: it shows only as "?" on the pill
    /// until the owner hovers or clicks (`QuestionsOpen`, P411). On.
    var questionsOpenIsland: Bool { didSet { save(questionsOpenIsland, Key.questionsOpenIsland) } }
    var hidePillWhenIdle: Bool { didSet { save(hidePillWhenIdle, Key.hidePillWhenIdle) } }
    /// Headless and plugin runs (`claude -p`, `codex exec`, Codex SDK apps, the codex plugin's tasks) in the lists.
    /// Off: they show only while they wait on the owner. Either way they never give a Done or count in the pill (P251).
    var showScriptedRuns: Bool { didSet { save(showScriptedRuns, Key.showScriptedRuns) } }
    /// A Claude subagent's approval is held for the island while its card shows, at most `SubagentHold.limit`, so the
    /// island's Yes and No answer it; Claude's own prompt waits that long (P350). Off: every subagent's card is read-only
    /// (P280). Island mode only.
    var answerSubagentsOnIsland: Bool { didSet { save(answerSubagentsOnIsland, Key.answerSubagents) } }
    /// A Codex shell command or patch is held for the island while its card shows, at most `CodexHold.limit`, so the
    /// island's Yes and No answer it; Codex's own prompt waits that long, and never while the owner looks at its tab or an
    /// auto reviewer takes it (P470). Off: every Codex card is read-only (decision 15). Island mode only.
    var answerCodexOnIsland: Bool { didSet { save(answerCodexOnIsland, Key.answerCodex) } }
    /// A row the pointer rests on shows its last prompt, its reply and, in Clean, its model, mode and progress in the
    /// island (P311). On.
    var sessionPeek: Bool { didSet { save(sessionPeek, Key.sessionPeek) } }
    /// A running session with no sign of life this long reads Stalled, with one quiet notice (P312). 10 minutes.
    var stalledAfter: StallLimit { didSet { save(stalledAfter.rawValue, Key.stalledAfter) } }
    /// A session done or idle this long is archived on its own, as its Archive would (`AutoTidy`, P727). 3 days.
    var archiveIdleAfter: ArchiveAfter { didSet { save(archiveIdleAfter.rawValue, Key.archiveIdleAfter) } }
    /// nil: the display with the notch (or the main display when none has one). Otherwise a display UUID string.
    var islandDisplay: String? { didSet { save(islandDisplay, Key.islandDisplay) } }
    var hapticOnHover: Bool { didSet { save(hapticOnHover, Key.hapticOnHover) } }
    /// P125: a brief island notice when an account crosses 90 % of a window, will run out within 30 minutes, or is back.
    var quotaAlerts: Bool { didSet { save(quotaAlerts, Key.quotaAlerts) } }
    /// How the island moves and how its hover answers (`MotionTuning`): the owner's A/B, Refined and Quick by default
    /// (motion round B1, the owner's "even faster and smoother"); a choice the owner made stays.
    var islandMotion: MotionFeel { didSet { save(islandMotion.rawValue, Key.islandMotion) } }
    var islandHover: HoverFeel { didSet { save(islandHover.rawValue, Key.islandHover) } }
    /// The opened island's width, shoulders included, one of `IslandSize.widths` (P401). 480.
    var islandWidth: Int { didSet { save(islandWidth, Key.islandWidth) } }
    /// Its session text's size, one of `IslandSize.textSizes` (P402). 12.
    var islandTextSize: Int { didSet { save(islandTextSize, Key.islandTextSize) } }
    /// A dot beside the closed pill's count while an update waits (P403); never on a pill with nothing else to show. On.
    var pillUpdateDot: Bool { didSet { save(pillUpdateDot, Key.pillUpdateDot) } }

    // MARK: Quiet (`QuietMode`)
    /// While the frontmost app is in full screen on the island's display, the closed pill hides and nothing opens the
    /// island by itself (`FullScreenWatch`). Off.
    var hideInFullScreen: Bool { didSet { save(hideInFullScreen, Key.hideInFullScreen) } }
    /// Hide in full screen: the pill still shows what needs you ("!", "?", "×" and their count). Off.
    var fullScreenShowsNeedsYou: Bool { didSet { save(fullScreenShowsNeedsYou, Key.fullScreenShowsNeedsYou) } }
    /// Between `quietFrom` and `quietTo`: no sounds and nothing opens the island by itself; the pill shows as ever. Off.
    var quietHours: Bool { didSet { save(quietHours, Key.quietHours) } }
    /// Quiet hours' start and end, in minutes after local midnight (`QuietHours`): 22:00 to 08:00 until the owner picks.
    var quietFrom: Int { didSet { save(quietFrom, Key.quietFrom) } }
    var quietTo: Int { didSet { save(quietTo, Key.quietTo) } }
    /// While the screen is locked or the owner's session switched out: no sounds and nothing opens the island by itself;
    /// back, the island opens on what came meanwhile (`ScreenLockWatch`, P422, P423). On: the owner asked for it, and the
    /// island opening under a lock screen is seen by no one.
    var quietWhileLocked: Bool { didSet { save(quietWhileLocked, Key.quietWhileLocked) } }
    /// Sessions that list but never sound, open the island by themselves or nudge (`MuteRule`, P420, P421). None.
    var muteRules: [MuteRule] { didSet { save(MuteRules.encode(muteRules), Key.muteRules) } }
    /// Snooze's end (`Snooze`, P724): until then no sounds, pop-ups, reminders or banners. A moment on the wall clock, so it
    /// survives a relaunch; `SnoozeEnd` clears it when it comes. nil: not muted.
    var snoozedUntil: Date? { didSet { save(snoozedUntil, Key.snoozedUntil) } }

    // MARK: Sound
    var soundsMuted: Bool { didSet { save(soundsMuted, Key.soundsMuted) } }
    var needsYouSound: SoundChoice { didSet { save(needsYouSound.storageValue, Key.needsYouSound) } }
    var doneSound: SoundChoice { didSet { save(doneSound.storageValue, Key.doneSound) } }
    /// A question's sound; nil plays the Needs you sound, as every question did before it had its own (P425).
    var questionSound: SoundChoice? { didSet { save(questionSound?.storageValue, Key.questionSound) } }
    /// Every sound's volume, 0.1 to 1 (`NSSound.volume`; Mute is the silence); 1, the system sound as it was, until the
    /// owner moves it (P426).
    var soundVolume: Double { didSet { save(SignalSounds.stored(soundVolume), Key.soundVolume) } }

    // MARK: Shortcuts
    /// The one system-wide key, "jump to what needs you". Off, and no key, by default: nothing is registered.
    var globalJumpEnabled: Bool { didSet { save(globalJumpEnabled, Key.globalJumpEnabled) } }
    /// A recorded key, for example "ctrl+g". nil until the owner records one.
    var globalJumpKey: String? { didSet { save(globalJumpKey, Key.globalJumpKey) } }
    /// What that key does: Jump to what needs you (default) or Open Juice Island with the keys (P323).
    var globalKeyAction: GlobalKeyAction { didSet { save(globalKeyAction.rawValue, Key.globalKeyAction) } }

    // MARK: Desktop panel
    var panelShowOnDesktop: Bool { didSet { save(panelShowOnDesktop, Key.panelShowOnDesktop) } }
    var panelLocked: Bool { didSet { save(panelLocked, Key.panelLocked) } }
    var panelDisplay: String? { didSet { save(panelDisplay, Key.panelDisplay) } }
    /// Where the panel starts and where Reset Position puts it (Juice spec §2.6: bottom right).
    var panelCorner: PanelCorner { didSet { save(panelCorner.rawValue, Key.panelCorner) } }

    // MARK: Money
    /// Settings › Money › Show, per account (`OpenRouter`, `OpenRouter 2`); on unless switched off.
    var moneyShown: [MoneyAccount: Bool] {
        didSet {
            for id in MoneyAccount.allCases where oldValue[id] != moneyShown[id] {
                save(moneyShown[id] ?? true, Key.moneyShown(id))
            }
        }
    }
    var runwayAmberHours: Int { didSet { save(runwayAmberHours, Key.runwayAmberHours) } }
    var runwayRedHours: Int { didSet { save(runwayRedHours, Key.runwayRedHours) } }
    /// Key files, credits and top-ups (`MoneySettings`).
    let money: MoneySettings

    /// Everything kept for a further money key whose key file is gone, its Show switch with the rest
    /// (`MoneySettings.forget`), so a key added in its place later starts clean and shows (P146).
    func forgetMoney(_ account: MoneyAccount) {
        guard !account.isFirst else { return }
        money.forget(account)
        if moneyShown[account] == false { moneyShown[account] = true }
    }

    // MARK: Usage
    /// Juice's readings in the app; Demo in renders and tests (`ephemeral()`), which never read the real files.
    var usageSource: UsageSource { didSet { save(usageSource.rawValue, Key.usageSource) } }

    // MARK: Diagnostics
    /// Diagnostics › Motion: a JSON per island motion in ~/Library/Logs/Juice Island/motion (`MotionRecorder`). Off.
    var recordIslandMotion: Bool { didSet { save(recordIslandMotion, Key.recordIslandMotion) } }
    /// The panel's display link asks for 80 to 120 Hz while the island moves (`IslandFramePacing.motion`). Off.
    var paceIslandMotion: Bool { didSet { save(paceIslandMotion, Key.paceIslandMotion) } }
    /// Diagnostics › Motion › Outline: who draws the island's black outline (`IslandOutline`); the owner's A/B.
    var islandOutline: IslandOutline { didSet { save(islandOutline.rawValue, Key.islandOutline) } }

    // MARK: Theme
    /// Settings › Island › Theme: Black (the default, the pure black as ever), Glass (the system's glass, no black), Smoke
    /// (the dark smoked glass) or Solid (the window material, light or dark with the Appearance, P770), for the island,
    /// the desktop panel and the widget (`JuiceTheme`, P520, P560). An unknown stored value reads as Black; "glass",
    /// written by the smoked glass's build, reads as today's Glass (P564).
    var juiceTheme: JuiceTheme { didSet { save(juiceTheme.rawValue, Key.juiceTheme) } }
    /// Settings › Island › State tint (`StateTint`): the island takes a faint colour of its lead state, a veil in Glass's
    /// glass (and over Solid's ground) and an edge along Black's outline; none in Smoke. On.
    var islandStateTint: Bool { didSet { save(islandStateTint, Key.islandStateTint) } }
    /// Settings › Island › Frost, under Theme while Glass is chosen (`GlassFrost`): 0, today's Glass, to 1, frosted. 0.
    var glassFrost: Double { didSet { save(GlassFrost.stored(glassFrost), Key.glassFrost) } }
    /// Settings › Island › Glass look, under Theme while Glass is chosen (`GlassLookChoice`, P870): Widget, the desktop
    /// widgets' look (the glass's dark face and white ink in either macOS mode), or Light and dark, the Appearance's, as
    /// Glass always was. Widget; an unknown stored word reads as Widget. Settings and the window follow the Appearance in
    /// both.
    var glassLook: GlassLookChoice { didSet { save(glassLook.rawValue, Key.glassLook) } }

    // MARK: Updates
    /// Settings › About › Prepare updates in the background (P710): a check that finds new commits builds them ahead, on
    /// AC power out of Low Power Mode, so Update is a restart. On. Installing still waits for the owner's click.
    var prepareUpdates: Bool { didSet { save(prepareUpdates, Key.prepareUpdates) } }
    /// The build whose What's new card showed (P716): it shows on that build's first launch only.
    var whatsNewShown: String? { didSet { save(whatsNewShown, Key.whatsNewShown) } }

    init(defaults: UserDefaults? = .standard, identity: AppIdentity = .current) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults?.object(forKey: key) as? Bool ?? fallback }
        func int(_ key: String, _ fallback: Int) -> Int { defaults?.object(forKey: key) as? Int ?? fallback }
        func string(_ key: String) -> String? { defaults?.string(forKey: key) }
        func choice<E: RawRepresentable>(_ key: String, _ fallback: E) -> E where E.RawValue == String {
            string(key).flatMap(E.init(rawValue:)) ?? fallback
        }
        showAs = choice(Key.showAs, ShowAs.window)
        appearance = choice(Key.appearance, AppearanceChoice.system)
        launchAtLogin = bool(Key.launchAtLogin, true)
        loginItemRegistered = bool(Key.loginItemRegistered, false)
        dockIconInIslandMode = bool(Key.dockIconInIslandMode, false)
        menuBarItem = bool(Key.menuBarItem, false)
        windowHeader = choice(Key.windowHeader, HeaderLayout.strip)
        windowShowsMoney = bool(Key.windowShowsMoney, true)
        accountNamesUnderBatteries = bool(Key.accountNamesUnderBatteries, false)
        keepOpenUntilDecision = bool(Key.keepOpenUntilDecision, false)
        replyFromCompletionCard = bool(Key.replyFromCompletionCard, false)
        modeChoicesOnCards = bool(Key.modeChoicesOnCards, true)
        suppressForFocusedSessions = bool(Key.suppressForFocusedSessions, true)
        notificationBanners = bool(Key.notificationBanners, false)
        followUpAfter = choice(Key.followUpAfter, FollowUpDelay.off)
        showCodexAppThreads = bool(Key.showCodexAppThreads, true)
        liveSessions = bool(Key.liveSessions, identity.liveSessionsByDefault)
        islandStyle = choice(Key.islandStyle, IslandStyle.clean)
        islandShowsUsage = bool(Key.islandShowsUsage, true)
        islandUsagePlacement = choice(Key.islandUsagePlacement, UsagePlacement.headerStrip)
        usageFirst = choice(Key.usageFirst, UsageFirst.inUse)
        islandShowsMoney = bool(Key.islandShowsMoney, true)
        hoverDetails = bool(Key.hoverDetails, true)
        glyphColour = choice(Key.glyphColour, GlyphColourMode.byState)
        needsYouColour = NeedsYouColour(stored: string(Key.needsYouColour))
        glyphStyle = choice(Key.glyphStyle, GlyphStyle.pixel)
        glyphEdgeLine = bool(Key.glyphEdgeLine, true)
        liquidRunning = choice(Key.liquidRunning, LiquidRunningLook.slim)
        closedPillCount = string(Key.closedPillCount).flatMap(PillCount.init(stored:)) ?? .active
        whenSessionFinishes = choice(Key.whenSessionFinishes, FinishBehaviour.card)
        questionsOpenIsland = bool(Key.questionsOpenIsland, true)
        hidePillWhenIdle = bool(Key.hidePillWhenIdle, false)
        showScriptedRuns = bool(Key.showScriptedRuns, false)
        answerSubagentsOnIsland = bool(Key.answerSubagents, false)
        answerCodexOnIsland = bool(Key.answerCodex, false)
        sessionPeek = bool(Key.sessionPeek, true)
        stalledAfter = choice(Key.stalledAfter, StallLimit.tenMinutes)
        archiveIdleAfter = choice(Key.archiveIdleAfter, ArchiveAfter.threeDays)
        islandDisplay = string(Key.islandDisplay)
        hapticOnHover = bool(Key.hapticOnHover, false)
        quotaAlerts = bool(Key.quotaAlerts, true)
        islandMotion = choice(Key.islandMotion, MotionFeel.refined)
        islandHover = choice(Key.islandHover, HoverFeel.quick)
        islandWidth = IslandSize.snapped(int(Key.islandWidth, Int(IslandSize.standard.outer)), to: IslandSize.widths)
        islandTextSize = IslandSize.snapped(int(Key.islandTextSize, Int(IslandSize.standard.text)), to: IslandSize.textSizes)
        pillUpdateDot = bool(Key.pillUpdateDot, true)
        hideInFullScreen = bool(Key.hideInFullScreen, false)
        fullScreenShowsNeedsYou = bool(Key.fullScreenShowsNeedsYou, false)
        quietHours = bool(Key.quietHours, false)
        quietFrom = QuietHours.stored(int(Key.quietFrom, QuietHours.defaultFrom))
        quietTo = QuietHours.stored(int(Key.quietTo, QuietHours.defaultTo))
        quietWhileLocked = bool(Key.quietWhileLocked, true)
        muteRules = MuteRules.decode(string(Key.muteRules))
        snoozedUntil = defaults?.object(forKey: Key.snoozedUntil) as? Date
        soundsMuted = bool(Key.soundsMuted, false)
        needsYouSound = string(Key.needsYouSound).map(SoundChoice.init(storageValue:)) ?? Self.defaultNeedsYouSound
        doneSound = string(Key.doneSound).map(SoundChoice.init(storageValue:)) ?? .none
        questionSound = string(Key.questionSound).map(SoundChoice.init(storageValue:))
        soundVolume = SignalSounds.stored(defaults?.object(forKey: Key.soundVolume) as? Double ?? 1)
        globalJumpEnabled = bool(Key.globalJumpEnabled, false)
        globalJumpKey = string(Key.globalJumpKey)
        globalKeyAction = choice(Key.globalKeyAction, GlobalKeyAction.jump)
        panelShowOnDesktop = bool(Key.panelShowOnDesktop, true)
        panelLocked = bool(Key.panelLocked, true)
        panelDisplay = string(Key.panelDisplay)
        panelCorner = choice(Key.panelCorner, PanelCorner.bottomRight)
        moneyShown = Dictionary(uniqueKeysWithValues: MoneyAccount.allCases.map { ($0, bool(Key.moneyShown($0), true)) })
        runwayAmberHours = int(Key.runwayAmberHours, 72)
        runwayRedHours = int(Key.runwayRedHours, 24)
        money = MoneySettings(defaults: defaults)
        usageSource = choice(Key.usageSource, defaults == nil ? UsageSource.demo : .juiceReadings)
        recordIslandMotion = bool(Key.recordIslandMotion, false)
        paceIslandMotion = bool(Key.paceIslandMotion, false)
        islandOutline = choice(Key.islandOutline, AppSettings.defaultOutline)
        juiceTheme = JuiceTheme(stored: string(Key.juiceTheme))
        islandStateTint = bool(Key.islandStateTint, true)
        glassFrost = GlassFrost.stored(defaults?.object(forKey: Key.glassFrost) as? Double ?? 0)
        glassLook = choice(Key.glassLook, GlassLookChoice.widget)
        prepareUpdates = bool(Key.prepareUpdates, true)
        whatsNewShown = string(Key.whatsNewShown)
    }

    /// Defaults only, kept in memory: for renders, previews and tests. Nothing is read or written.
    static func ephemeral() -> AppSettings { AppSettings(defaults: nil, identity: .development) }

    private func save(_ value: Any?, _ key: String) {
        guard let defaults else { return }
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
