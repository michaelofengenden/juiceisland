import AppKit
import Foundation
import IslandEngine
import Testing
@testable import JuiceIslandUI

/// Settings › Island › Quiet (P330 to P333): Hide in full screen (the pill hides, or shows only what needs you, and
/// nothing opens the island by itself) and Quiet hours (no sounds, nothing opens the island by itself, the pill as ever).
/// Clocks are fake (dates on a calendar of a fixed time zone), full screen is fake (window lists and notices of the
/// tests' own), and nothing reads the real window list, plays a sound or shows a window.
@MainActor
@Suite(.serialized)
struct QuietModeTests {
    static let berlin: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    /// `hour`:`minute` on `day` September 2026 (or another month), on Berlin's wall clock.
    static func at(_ hour: Int, _ minute: Int = 0, day: Int = 27, month: Int = 9, calendar: Calendar = berlin) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    static func settings(quietHours: Bool = false, from: Int = QuietHours.defaultFrom, to: Int = QuietHours.defaultTo,
                         hideInFullScreen: Bool = false, showsNeedsYou: Bool = false) -> AppSettings {
        let settings = AppSettings.ephemeral()
        settings.quietHours = quietHours
        settings.quietFrom = from
        settings.quietTo = to
        settings.hideInFullScreen = hideInFullScreen
        settings.fullScreenShowsNeedsYou = showsNeedsYou
        return settings
    }

    // MARK: Quiet hours (P332)

    @Test func quietHoursRunOverMidnightFromTheirStartToJustBeforeTheirEnd() {
        let night = QuietHours(from: 22 * 60, to: 8 * 60)
        for (hour, minute, quiet) in [(22, 0, true), (23, 59, true), (0, 0, true), (3, 30, true), (7, 59, true),
                                      (8, 0, false), (12, 0, false), (21, 59, false)] {
            #expect(night.contains(Self.at(hour, minute), calendar: Self.berlin) == quiet, "\(hour):\(minute)")
        }
        let lunch = QuietHours(from: 13 * 60, to: 14 * 60 + 30)
        for (hour, minute, quiet) in [(12, 59, false), (13, 0, true), (14, 29, true), (14, 30, false), (23, 0, false)] {
            #expect(lunch.contains(Self.at(hour, minute), calendar: Self.berlin) == quiet, "\(hour):\(minute)")
        }
        // The same time twice is the whole day: the switch on always quiets something.
        let allDay = QuietHours(from: 9 * 60, to: 9 * 60)
        #expect([(0, 0), (8, 59), (9, 0), (17, 30)].allSatisfy { allDay.contains(Self.at($0.0, $0.1), calendar: Self.berlin) })
    }

    /// Read on the wall clock of the owner's time zone: the same instant is night in Berlin and afternoon in Los Angeles,
    /// and daylight saving's change of hour (25 October 2026) moves nothing.
    @Test func quietHoursFollowTheLocalWallClock() {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let night = QuietHours(from: 22 * 60, to: 8 * 60)
        let instant = Self.at(23, 30)
        #expect(night.contains(instant, calendar: Self.berlin))
        #expect(!night.contains(instant, calendar: losAngeles))
        #expect(night.contains(Self.at(2, 30, day: 25, month: 10), calendar: Self.berlin))
        #expect(!night.contains(Self.at(8, 0, day: 25, month: 10), calendar: Self.berlin))
        #expect(QuietHours.minute(of: Self.at(7, 45, day: 26, month: 10), calendar: Self.berlin) == 7 * 60 + 45)
    }

    @Test func aStoredTimeIsAMinuteOfTheDay() {
        #expect(QuietHours.stored(-30) == 23 * 60 + 30)
        #expect(QuietHours.stored(24 * 60) == 0 && QuietHours.stored(25 * 60) == 60)
        #expect(QuietHours(from: 24 * 60 + 60, to: -60) == QuietHours(from: 60, to: 23 * 60))
        #expect(QuietHours.choices.count == 48 && QuietHours.choices.first == 0 && QuietHours.choices.last == 23 * 60 + 30)
    }

    /// The pop-ups speak the owner's clock, and name a time set off the half-hour grid.
    @Test func thePopUpsNameTimesAsTheOwnersClockDoes() {
        let britain = Locale(identifier: "en_GB"), states = Locale(identifier: "en_US")
        #expect(QuietHours.label(22 * 60, locale: britain) == "22:00")
        #expect(QuietHours.label(8 * 60 + 30, locale: britain) == "08:30")
        #expect(QuietHours.label(22 * 60, locale: states).hasPrefix("10:00") && QuietHours.label(22 * 60, locale: states).hasSuffix("PM"))
        #expect(QuietHours.options(around: 22 * 60, locale: britain).count == 48)
        let odd = QuietHours.options(around: 7 * 60 + 45, locale: britain)
        #expect(odd.count == 49 && odd.contains { $0.0 == 7 * 60 + 45 && $0.1 == "07:45" })
        #expect(odd.map(\.0) == odd.map(\.0).sorted())
    }

    @Test func theSettingsKeepTheirValuesAndStartOff() throws {
        let name = "ji.test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let fresh = AppSettings(defaults: defaults)
        #expect(!fresh.hideInFullScreen && !fresh.fullScreenShowsNeedsYou && !fresh.quietHours)
        #expect(fresh.quietFrom == 22 * 60 && fresh.quietTo == 8 * 60)
        fresh.hideInFullScreen = true
        fresh.fullScreenShowsNeedsYou = true
        fresh.quietHours = true
        fresh.quietFrom = 23 * 60 + 30
        fresh.quietTo = 7 * 60
        let again = AppSettings(defaults: defaults)
        #expect(again.hideInFullScreen && again.fullScreenShowsNeedsYou && again.quietHours)
        #expect(again.quietFrom == 23 * 60 + 30 && again.quietTo == 7 * 60)
        #expect(defaults.integer(forKey: AppSettings.Key.quietFrom) == 23 * 60 + 30)
        // A time written by hand outside the day wraps onto it.
        defaults.set(24 * 60 + 90, forKey: AppSettings.Key.quietTo)
        #expect(AppSettings(defaults: defaults).quietTo == 90)
    }

    @Test func quietHoursHoldBackOnlyWhileOnAndInside() {
        let night = Self.at(23), noon = Self.at(12)
        #expect(!QuietMode.inQuietHours(Self.settings(quietHours: false), now: night, calendar: Self.berlin))
        #expect(QuietMode.inQuietHours(Self.settings(quietHours: true), now: night, calendar: Self.berlin))
        #expect(!QuietMode.inQuietHours(Self.settings(quietHours: true), now: noon, calendar: Self.berlin))
        // Full screen holds attention only with Hide in full screen on.
        #expect(!QuietMode.holdsAttention(Self.settings(), fullScreen: true, now: noon, calendar: Self.berlin))
        #expect(QuietMode.holdsAttention(Self.settings(hideInFullScreen: true), fullScreen: true, now: noon, calendar: Self.berlin))
        #expect(!QuietMode.holdsAttention(Self.settings(hideInFullScreen: true), fullScreen: false, now: noon, calendar: Self.berlin))
        #expect(QuietMode.holdsAttention(Self.settings(quietHours: true), fullScreen: false, now: night, calendar: Self.berlin))
    }

    // MARK: Sounds (P331)

    /// Quiet hours silence both sounds; outside them, or with the switch off, they play as chosen. Mute still wins.
    @Test func quietHoursSilenceTheSounds() {
        let settings = Self.settings(quietHours: true)
        settings.doneSound = .system("Hero")
        func sounds(at now: Date) -> [String?] {
            [SignalSounds.sound(for: .needsYou(sessionID: "s"), isCodexAppThread: false, settings: settings, now: now, calendar: Self.berlin),
             SignalSounds.sound(for: .done(sessionID: "s"), isCodexAppThread: false, settings: settings, now: now, calendar: Self.berlin)]
        }
        #expect(sounds(at: Self.at(23, 15)) == [nil, nil])
        #expect(sounds(at: Self.at(6, 0)) == [nil, nil])
        #expect(sounds(at: Self.at(8, 0)) == ["Glass", "Hero"])
        settings.quietHours = false
        #expect(sounds(at: Self.at(23, 15)) == ["Glass", "Hero"])
        settings.soundsMuted = true
        #expect(sounds(at: Self.at(12, 0)) == [nil, nil])
    }

    // MARK: What opens the island (P331)

    /// While quiet a needs-you opens no card (the pill shows it) and is put away; a finish lights Glance's dot instead of
    /// its Done card. Not quiet, the batch is as it came.
    @Test func whileQuietNothingOpensTheIslandByItself() {
        let signals: [IslandSignal] = [.needsYou("a"), .finished("d")]
        #expect(QuietMode.quieted(signals, finish: .card, quiet: false) == QuietMode.Batch(signals: signals, finish: .card))
        let quiet = QuietMode.quieted(signals, finish: .card, quiet: true)
        #expect(quiet == QuietMode.Batch(signals: [.finished("d")], finish: .glance, putsAway: true))
        #expect(QuietMode.quieted([.finished("d")], finish: .card, quiet: true).putsAway == false)
        // A stall's notice is a brief card the island would open by itself: quiet drops it, and puts nothing away.
        #expect(QuietMode.quieted([.stalled("s")], finish: .card, quiet: false).signals == [.stalled("s")])
        #expect(QuietMode.quieted([.stalled("s"), .finished("d")], finish: .card, quiet: true)
            == QuietMode.Batch(signals: [.finished("d")], finish: .glance))

        let rows = [DStub.row("a", .claude, .needsYou), DStub.row("d", .codex, .done)]
        let loud = IslandAttention.respond(to: signals, rows: rows, finish: .card, cardInUse: false)
        #expect(loud.card == "a")
        let hushed = IslandAttention.respond(to: quiet.signals, rows: rows, finish: quiet.finish, cardInUse: false)
        #expect(hushed.card == nil && !hushed.brief && hushed.glance == "d")
        let finishOnly = QuietMode.quieted([.finished("d")], finish: .card, quiet: true)
        let done = IslandAttention.respond(to: finishOnly.signals, rows: rows, finish: finishOnly.finish, cardInUse: false)
        #expect(done.card == nil && done.glance == "d")
    }

    /// A request that came while quiet stays on the pill after quiet ends: its row dropping out of a batch and coming
    /// back (a Live restart) opens nothing, as a request the island folded away from (P272); a new request does.
    @Test func aRequestThatCameWhileQuietNeverOpensTheIslandLater() {
        let a = DStub.row("a", .claude, .needsYou), b = DStub.row("b", .claude, .needsYou), c = DStub.row("c", .codex, .running)
        var island = Island(cards: ["a": FocusYieldTests.approval("a", request: "A1"), "b": FocusYieldTests.approval("b", request: "B1")])
        #expect(island.hear([c], quiet: true) == nil)
        #expect(island.hear([a, c], quiet: true) == nil)
        #expect(island.putAway.keys == ["a": "request:A1"])
        // Quiet ends: A's return after a restart opens nothing; B, new, opens the island.
        #expect(island.hear([], quiet: false) == nil)
        #expect(island.hear([a, c], quiet: false) == nil)
        #expect(island.hear([a, b, c], quiet: false) == "b")
        // The pill showed A's "!" all along.
        let lead = HideWhenIdleTests.pill([a, c], hide: false).lead
        #expect(lead?.glyph == .bang && lead?.state == .waiting)
    }

    /// The island's side of the rows as the panel runs it (`IslandPanelController.sessionsChanged`): heard, quieted,
    /// put away while quiet, and the card a batch opens.
    struct Island {
        var putAway = IslandPutAway()
        var last: [SessionRow] = []
        var cards: [String: SessionCard] = [:]

        mutating func hear(_ rows: [SessionRow], quiet: Bool) -> String? {
            let heard = putAway.hear(IslandAttention.signals(old: last, new: rows), rows: rows,
                                     pending: IslandAttention.pendingKeys(rows) { cards[$0] })
            last = rows
            let batch = QuietMode.quieted(heard, finish: .card, quiet: quiet)
            if batch.putsAway { putAway.folded() }
            return IslandAttention.respond(to: batch.signals, rows: rows, finish: batch.finish, cardInUse: false).card
        }
    }

    // MARK: The pill in full screen (P330)

    static func pill(_ rows: [SessionRow], settings: AppSettings, fullScreen: Bool, glance: Bool = false,
                     notch: CGSize? = IslandTheme.Metrics.referenceNotch) -> PillContent {
        PillContent.make(rows: rows, settings: settings, glance: glance, recentlyFinished: nil, now: ActiveCountTests.now,
                         notch: notch, menuBar: 33, fullScreen: fullScreen)
    }

    /// Hidden in full screen with the switch on: nothing, or with Show needs you only what needs you (its glyph and how
    /// many wait: no running glyph, no count of the rest, no Glance dot). Out of full screen, or with the switch off,
    /// the pill as ever.
    @Test func inFullScreenThePillHidesOrShowsOnlyWhatNeedsYou() {
        let asking = ActiveCountTests.row("q", .claude, .needsYou, ago: 60)
        let asking2 = ActiveCountTests.row("q2", .codex, .needsYou, ago: 30, status: .question)
        let running = ActiveCountTests.row("r", .codex, .running, ago: 10)
        let rows = [running, asking, asking2]
        let normal = Self.pill(rows, settings: Self.settings(), fullScreen: false)
        #expect(normal.lead?.state == .waiting && normal.count == 3)
        #expect(Self.pill(rows, settings: Self.settings(), fullScreen: true) == normal)
        #expect(Self.pill(rows, settings: Self.settings(hideInFullScreen: true), fullScreen: false) == normal)

        let hidden = Self.pill(rows, settings: Self.settings(hideInFullScreen: true), fullScreen: true, glance: true)
        #expect(hidden.isEmpty && hidden.extent == IslandExtent(width: IslandTheme.Metrics.referenceNotch.width,
                                                                 height: IslandTheme.Metrics.referenceNotch.height))

        let badge = Self.pill(rows, settings: Self.settings(hideInFullScreen: true, showsNeedsYou: true), fullScreen: true, glance: true)
        #expect(badge.lead?.glyph == .bang && badge.lead?.state == .waiting && badge.count == 2 && !badge.glance && !badge.edgeRuns)
        // Nothing waits: nothing shows, a running session included.
        let calm = Self.pill([running], settings: Self.settings(hideInFullScreen: true, showsNeedsYou: true), fullScreen: true)
        #expect(calm.isEmpty)
        // The no-notch bar the same.
        #expect(Self.pill(rows, settings: Self.settings(hideInFullScreen: true), fullScreen: true, notch: nil).isEmpty)
        #expect(Self.pill([asking], settings: Self.settings(hideInFullScreen: true, showsNeedsYou: true), fullScreen: true,
                          notch: nil).count == 1)
    }

    /// Under a notch the hidden pill tucks behind the notch and the panel stays: the idle surface is the notch itself,
    /// black on black, and a rest or a click there still opens the island (P56). Hide the pill when idle still orders it
    /// out, full screen or not.
    @Test func underANotchTheHiddenPillIsTheNotchAndStillOpensTheIsland() {
        let running = ActiveCountTests.row("r", .codex, .running, ago: 10)
        let settings = Self.settings(hideInFullScreen: true)
        #expect(!IslandPanelController.hidesIdlePill(settings: settings, fullScreen: true, on: Self.builtIn))
        #expect(!IslandPanelController.hidesIdlePill(settings: settings, fullScreen: false, on: Self.external))
        #expect(IslandPanelController.hidesIdlePill(settings: settings, fullScreen: true, on: Self.external))
        #expect(!IslandPanelController.hidesIdlePill(settings: Self.settings(), fullScreen: true, on: Self.external))
        settings.hidePillWhenIdle = true
        #expect(IslandPanelController.hidesIdlePill(settings: settings, fullScreen: false, on: Self.builtIn))
        settings.hidePillWhenIdle = false

        let notch = IslandTheme.Metrics.referenceNotch
        let before = Self.pill([running], settings: settings, fullScreen: false)
        let hidden = Self.pill([running], settings: settings, fullScreen: true)
        let start = IslandChoreography(metrics: .init(targets: SurfaceTargets(notch: notch, pill: before, hideWhenIdle: false),
                                                      layout: DIslandPanelSizingTests.layout()), ordered: true)
        let (tucked, out) = IslandChoreography.replay(start, [(0, .pill(hidden))], until: 2)
        #expect(!out.contains { if case .effect(.orderOut) = $0 { true } else { false } })
        #expect(tucked.ordered && tucked.shownPill.isEmpty && tucked.targets.closed == tucked.targets.idle)
        #expect(tucked.targets.idle.width == notch.width && tucked.targets.idle.height == notch.height)
        // A click on the notch opens the island.
        var opened = tucked
        _ = opened.handle(.open(.click, .list), at: 3)
        #expect(opened.isOpen)
    }

    /// Without a notch the hidden bar folds into the top edge and the panel orders out; something that needs you (Show
    /// needs you) brings it back, ordered in, showing only that.
    @Test func withoutANotchTheHiddenBarFoldsAwayAndComesBackWithWhatNeedsYou() {
        let asking = ActiveCountTests.row("q", .claude, .needsYou, ago: 60)
        let running = ActiveCountTests.row("r", .codex, .running, ago: 10)
        let settings = Self.settings(hideInFullScreen: true, showsNeedsYou: true)
        let before = Self.pill([running], settings: settings, fullScreen: false, notch: nil)
        let hidden = Self.pill([running], settings: settings, fullScreen: true, notch: nil)
        let badge = Self.pill([running, asking], settings: settings, fullScreen: true, notch: nil)
        #expect(!before.isEmpty && hidden.isEmpty && badge.count == 1)
        let start = IslandChoreography(metrics: .init(targets: SurfaceTargets(notch: nil, pill: before, hideWhenIdle: true),
                                                      layout: DIslandPanelSizingTests.layout()), ordered: true)
        let (gone, out) = IslandChoreography.replay(start, [(0, .pill(hidden))], until: 2)
        #expect(out.last { if case .effect(.orderOut) = $0 { true } else { false } } != nil)
        #expect(!gone.ordered && gone.shownPill.isEmpty && gone.targets.idle.height == 0)
        let (back, ins) = IslandChoreography.replay(gone, [(3, .pill(badge))], until: 5)
        #expect(ins.first { if case .effect(.orderIn) = $0 { true } else { false } } != nil)
        #expect(back.ordered && back.shownPill == badge)
    }

    // MARK: Full screen, from the window list (P330)

    static let builtIn = IslandScreen(id: "built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), safeAreaTop: 32,
                                      auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664, menuBarHeight: 33)
    static let external = IslandScreen(id: "external", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                                       menuBarHeight: 25)
    static let front: pid_t = 4242, other: pid_t = 777

    static func window(_ rect: CGRect, pid: pid_t = front, layer: Int = 0, alpha: Double = 1) -> FullScreenProbe.Window {
        FullScreenProbe.Window(pid: pid, layer: layer, bounds: rect, alpha: alpha)
    }

    static func fullScreen(_ windows: [FullScreenProbe.Window], on screen: IslandScreen = builtIn, frontmost: pid_t? = front) -> Bool {
        FullScreenProbe.isFullScreen(frontmost: frontmost, windows: windows, screen: screen, primaryHeight: builtIn.frame.height)
    }

    /// On a display with a notch: a full-screen app below the camera housing, or over it, counts; a zoomed window (up to
    /// the menu bar's lower edge, with the Dock shown or hidden) and any window of another app, of another level, see-through
    /// or smaller do not.
    @Test func fullScreenIsTheFrontmostAppAcrossTheWholeDisplay() {
        #expect(Self.fullScreen([Self.window(CGRect(x: 0, y: 32, width: 1512, height: 950))]))
        #expect(Self.fullScreen([Self.window(CGRect(x: 0, y: 0, width: 1512, height: 982))]))
        #expect(!Self.fullScreen([Self.window(CGRect(x: 0, y: 33, width: 1512, height: 949))]))
        #expect(!Self.fullScreen([Self.window(CGRect(x: 0, y: 33, width: 1512, height: 880))]))
        #expect(!Self.fullScreen([Self.window(CGRect(x: 0, y: 32, width: 1512, height: 950), pid: Self.other)]))
        #expect(!Self.fullScreen([Self.window(CGRect(x: 0, y: 0, width: 1512, height: 982), layer: 3)]))
        #expect(!Self.fullScreen([Self.window(CGRect(x: 0, y: 0, width: 1512, height: 982), alpha: 0)]))
        #expect(!Self.fullScreen([Self.window(CGRect(x: 100, y: 32, width: 1300, height: 950))]))
        #expect(!Self.fullScreen([Self.window(CGRect(x: 0, y: 0, width: 1512, height: 982))], frontmost: nil))
        #expect(!Self.fullScreen([]))
        // Among other windows, front to back.
        #expect(Self.fullScreen([Self.window(CGRect(x: 600, y: 0, width: 300, height: 33), pid: Self.other, layer: 25),
                                 Self.window(CGRect(x: 0, y: 32, width: 1512, height: 950))]))
    }

    /// Where the menu bar is no taller than the notch, a window stopping at the notch's lower edge may be a zoomed one:
    /// left out, so the pill shows rather than hides when in doubt. With the menu bar hidden it is full screen.
    @Test func inDoubtThePillShows() {
        var even = Self.builtIn
        even.menuBarHeight = 32
        #expect(!Self.fullScreen([Self.window(CGRect(x: 0, y: 32, width: 1512, height: 950))], on: even))
        #expect(Self.fullScreen([Self.window(CGRect(x: 0, y: 0, width: 1512, height: 982))], on: even))
        var hiddenBar = Self.builtIn
        hiddenBar.menuBarHeight = nil
        #expect(Self.fullScreen([Self.window(CGRect(x: 0, y: 32, width: 1512, height: 950))], on: hiddenBar))
    }

    /// Two displays (P56): full screen on the external display never hides the island on the built-in one, and the
    /// reverse; the external display has no notch, so there only a window over its menu bar's row counts.
    @Test func fullScreenIsJudgedOnTheIslandsOwnDisplay() {
        let primaryHeight = Self.builtIn.frame.height
        let externalCG = FullScreenProbe.cgFrame(of: Self.external, primaryHeight: primaryHeight)
        #expect(externalCG == CGRect(x: 1512, y: -458, width: 2560, height: 1440))
        let onExternal = Self.window(externalCG)
        #expect(!Self.fullScreen([onExternal], on: Self.builtIn))
        #expect(Self.fullScreen([onExternal], on: Self.external))
        let zoomedExternal = Self.window(CGRect(x: 1512, y: -458 + 25, width: 2560, height: 1415))
        #expect(!Self.fullScreen([zoomedExternal], on: Self.external))
        #expect(!Self.fullScreen([Self.window(CGRect(x: 0, y: 32, width: 1512, height: 950))], on: Self.external))
    }

    // MARK: The watch (P330)

    final class Heard {
        var fullScreen = false
        var probes = 0
        var changes: [Bool] = []
    }

    static func settle(until done: () -> Bool) async {
        for _ in 0..<200 where !done() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    /// Each notice (an app activated, the Space changed, the displays changed) reads the probe; a change is told once, and
    /// nothing after `stop()`. Fake notices on centers of the test's own; the probe is a fake window list.
    @Test func theWatchHearsActivationsSpacesAndDisplays() async {
        _ = NSApplication.shared
        let heard = Heard()
        let workspace = NotificationCenter(), local = NotificationCenter()
        let watch = FullScreenWatch(workspace: workspace, local: local, settle: nil, probe: {
            heard.probes += 1
            return heard.fullScreen
        }, changed: { heard.changes.append($0) })
        defer { watch.stop() }
        #expect(!watch.isFullScreen && heard.probes == 1 && heard.changes.isEmpty)

        heard.fullScreen = true
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await Self.settle { heard.changes.count == 1 }
        #expect(heard.changes == [true] && watch.isFullScreen)

        // The same answer again tells nothing.
        workspace.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        await Self.settle { heard.probes >= 3 }
        #expect(heard.probes == 3 && heard.changes == [true])

        heard.fullScreen = false
        local.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        await Self.settle { heard.changes.count == 2 }
        #expect(heard.changes == [true, false])

        watch.stop()
        heard.fullScreen = true
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(heard.changes == [true, false] && heard.probes == 4)
    }

    /// The window server lists a new Space's windows once its slide has ended: a notice reads the probe again `settle`
    /// later, so a full screen that was not yet listed at the notice is still heard. No notice, no read: nothing polls.
    @Test func aNoticeIsReadAgainOnceTheSpaceHasSettled() async {
        _ = NSApplication.shared
        let heard = Heard()
        let workspace = NotificationCenter(), local = NotificationCenter()
        let watch = FullScreenWatch(workspace: workspace, local: local, settle: 0.05, probe: {
            heard.probes += 1
            return heard.fullScreen
        }, changed: { heard.changes.append($0) })
        defer { watch.stop() }
        workspace.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        await Self.settle { heard.probes == 2 }
        #expect(heard.changes.isEmpty)
        // Listed only now, after the notice's own read.
        heard.fullScreen = true
        await Self.settle { heard.changes == [true] }
        #expect(heard.changes == [true] && heard.probes == 3)
        try? await Task.sleep(for: .milliseconds(150))
        #expect(heard.probes == 3)
    }
}
