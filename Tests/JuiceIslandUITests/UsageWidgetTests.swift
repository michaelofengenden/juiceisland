import AppKit
import Foundation
import JuiceCore
import SwiftUI
import Testing
import WidgetKit
@testable import JuiceIslandUI

/// The Usage widget (wave A5, P1220 to P1229): its kind, its snapshot, its reloads, its timeline and countdowns, how
/// long it trusts a snapshot, what each face holds, its ink, and the panel it replaces. Every store is a temporary
/// folder; no real App Group container and no real defaults are touched.
@MainActor
@Suite(.serialized)
struct UsageWidgetTests {
    static let now = DemoClock.now

    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-widget-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: The kinds (P1220)

    /// The Usage widget keeps the only widget's kind, so one already on the owner's desktop becomes it; the sessions
    /// widget has a new one; the bundle lists the Usage widget first, the gallery's order.
    @Test func theUsageWidgetTakesTheOldKindAndComesFirst() throws {
        #expect(JuiceIslandUsageWidget.kind == "JuiceIslandWidget" && WidgetKind.usage.rawValue == "JuiceIslandWidget")
        #expect(JuiceIslandWidget.kind == "JuiceIslandSessionsWidget" && WidgetKind.allCases == [.usage, .sessions])
        let bundle = try String(contentsOf: RenderHarness.root.appendingPathComponent("Widget/JuiceIslandWidgetBundle.swift"), encoding: .utf8)
        let usage = try #require(bundle.range(of: "JuiceIslandUsageWidget()")), sessions = try #require(bundle.range(of: "JuiceIslandWidget()"))
        #expect(usage.lowerBound < sessions.lowerBound)
    }

    // MARK: The snapshot (P1221)

    /// The money the panel shows rides in the snapshot, in its order, each row's name, amount, suffix or word and colour;
    /// a row switched off in Settings › Money stays out. No key, email or path.
    @Test func theSnapshotCarriesThePanelsMoney() throws {
        let env = AppEnvironment.demo()
        let snapshot = WidgetSnapshot.make(env, at: Self.now)
        let shown = env.usage.shownMoney(env.settings)
        #expect(!shown.isEmpty && snapshot.moneyRows.map(\.id) == shown.map(\.id))
        #expect(snapshot.moneyRows == shown.map(WidgetSnapshot.Money.init))
        let first = try #require(MoneyAccount(rawValue: shown[0].id))
        env.settings.moneyShown[first] = false
        #expect(!WidgetSnapshot.make(env, at: Self.now).moneyRows.contains { $0.id == shown[0].id })
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        try store.write(snapshot)
        let text = try String(contentsOf: store.file, encoding: .utf8)
        #expect(!text.contains("@") && !text.contains(NSHomeDirectory()) && !text.contains("sk-"))
        #expect(store.read()?.moneyRows == snapshot.moneyRows)
    }

    /// A file an older build wrote has no money: none, and it still reads.
    @Test func aFileWithNoMoneyReadsAsNone() throws {
        var snapshot = WidgetSnapshot.make(.demo(), at: Self.now)
        snapshot.money = nil
        let data = try JSONEncoder().encode(snapshot)
        #expect(String(data: data, encoding: .utf8)?.contains("money") == false)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data).moneyRows.isEmpty)
    }

    // MARK: Reloads (P1222)

    /// The Usage widget reloads at once for a battery's kind, the account in use or next moving, a money row gaining or
    /// losing its amount, or the app quitting; a percent or an amount waits a quarter of an hour; a session reloads none
    /// of it.
    @Test func theUsageWidgetReloadsAtOnceOnlyForWhatChangesItsKind() {
        var policy = WidgetReloadPolicy(kind: .usage)
        let base = UsageWidgetRenders.owner()
        #expect(policy.decide(base, at: Self.now) == .now)
        policy.reloaded(base, at: Self.now)
        #expect(WidgetKind.usage.floor == 900 && WidgetKind.sessions.floor == 300 && WidgetReloadPolicy.floor == 300)
        var percent = base
        percent.claude[0].state = .available(left: 70, low: false)
        #expect(policy.decide(percent, at: Self.now + 60) == .at(Self.now + 900))
        var amount = base
        amount.money?[0].amount = "$6,400"
        #expect(policy.decide(amount, at: Self.now + 60) == .at(Self.now + 900))
        var low = base
        low.claude[0].state = .available(left: 9, low: true)
        var inUse = base
        inUse.codex[0].inUse = nil
        inUse.codex[1].inUse = true
        var next = base
        next.claude[0].isNext = false
        next.claude[2].isNext = true
        var offline = base
        offline.money?[0] = .init(id: "OpenRouter", name: "OpenRouter", amount: nil, word: "Offline")
        var closed = base
        closed.appRunning = false
        for urgent in [low, inUse, next, offline, closed] { #expect(policy.decide(urgent, at: Self.now + 1) == .now) }
        // A session is not the Usage widget's: the same content, nothing to reload.
        var session = base
        session.rows = [WidgetSnapshot.Row(id: "s", agent: "claude", kind: .running, title: "T", glyph: "eq")]
        #expect(WidgetKind.usage.drawsSame(session, base) && !WidgetKind.sessions.drawsSame(session, base))
    }

    /// The feed reloads each kind by its own policy: money switched off reloads the Usage widget at once and leaves the
    /// sessions one; and while nothing changes it writes the file again once a heartbeat old, reloading nothing.
    @Test func theFeedReloadsEachKindAndBeatsWithoutReloading() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: Self.now),
                                 sessions: DStub(rows: [DStub.row("run", .codex, .running)]))
        var clock = Self.now
        let reloads = ReloadCounter()
        let feed = WidgetFeed(env: env, store: store, clock: { clock }, reload: { reloads.bump($0) })
        feed.start()
        feed.drain()
        #expect(reloads.of(.usage) == 1 && reloads.of(.sessions) == 1)

        let shown = env.usage.shownMoney(env.settings)
        let account = try #require(shown.first.flatMap { MoneyAccount(rawValue: $0.id) })
        env.settings.moneyShown[account] = false
        clock += 30
        feed.changed()
        feed.drain()
        #expect(reloads.of(.usage) == 2 && reloads.of(.sessions) == 1, "money is the Usage widget's alone")
        #expect(store.read()?.moneyRows.count == shown.count - 1)

        // Nothing changes: nothing written until the heartbeat, then the same content newly dated, and no reload.
        let written = try #require(store.read()?.written)
        clock += UsageFreshness.heartbeat - 60
        feed.changed()
        feed.drain()
        #expect(store.read()?.written == written)
        clock += 61
        feed.changed()
        feed.drain()
        #expect(store.read()?.written == clock && reloads.count == 3)
        feed.stop()
        #expect(reloads.of(.usage) == 3 && reloads.of(.sessions) == 2)
    }

    // MARK: Freshness and the timeline (P1223, P1225)

    /// An hour after the app last wrote, WidgetKit is asked for a new timeline; five minutes later, if none came, the
    /// widget is stale: "Not updated", every battery not read lately, no number.
    @Test func aSnapshotIsTrustedForAnHourAfterItsLastWrite() {
        let snapshot = UsageWidgetRenders.owner()
        #expect(UsageFreshness.reloadAt(snapshot) == Self.now + 3_600 && UsageFreshness.staleAt(snapshot) == Self.now + 3_900)
        #expect(!UsageFreshness.isStale(snapshot, at: Self.now + 3_899) && UsageFreshness.isStale(snapshot, at: Self.now + 3_900))
        #expect(!UsageFreshness.isStale(.closed(at: Self.now), at: Self.now + 10_000), "the app quit: Not running, not stale")
        #expect(UsageFreshness.heartbeat * 6 == UsageFreshness.staleAfter)
        let battery = UsageBattery(battery: snapshot.claude[0], date: Self.now, stale: true)
        #expect(battery.shown == .stale(last: 83))
        #expect(UsageBattery(battery: snapshot.claude[1], date: Self.now, stale: true).shown == .stale(last: 0))
        #expect(UsageBattery(battery: snapshot.claude[0], date: Self.now).shown == snapshot.claude[0].state)
    }

    /// The timeline: now, each countdown's boundaries and refill still ahead, and the stale moment, nothing past it; then
    /// a new timeline an hour after the write. Closed or missing: one entry, nothing asked. Past the hour: asked again a
    /// heartbeat on (P1282).
    @Test func theTimelineHoldsTheCountdownsBoundariesAndTheStaleMoment() {
        let snapshot = UsageWidgetRenders.owner()
        let refill = Self.now + 2 * 3_600 + 4 * 60 + 30
        let timeline = UsageWidgetProvider.timeline(snapshot, now: Self.now)
        let expected = ([Self.now, UsageFreshness.staleAt(snapshot)]
            + Countdown.boundaries(refill: refill).filter { $0 > Self.now && $0 <= UsageFreshness.staleAt(snapshot) }).sorted()
        #expect(timeline.entries.map(\.date) == Array(Set(expected)).sorted())
        #expect(timeline.entries.map(\.date).contains(refill - 3_600 + 1))
        #expect(timeline.policy == .after(Self.now + 3_600))
        #expect(UsageWidgetProvider.timeline(.closed(at: Self.now), now: Self.now).entries.count == 1)
        #expect(UsageWidgetProvider.timeline(.closed(at: Self.now), now: Self.now).policy == .never)
        #expect(UsageWidgetProvider.timeline(nil, now: Self.now).policy == .never)
        // Already stale while the app runs: asked again a heartbeat on, for the app's next write.
        #expect(UsageWidgetProvider.timeline(snapshot, now: Self.now + 4_000).policy == .after(Self.now + 4_000 + UsageFreshness.heartbeat))
    }

    /// A countdown reads as the panel's label at every moment: fixed where it holds, and where it ticks the timer's
    /// leading part, whose shape changes only at the boundaries.
    @Test func countdownsReadAsThePanelsLabel() {
        let refill = Self.now + 3 * 86_400
        var checked = 0
        for seconds in stride(from: 0.0, through: 3 * 86_400, by: 37) {
            let date = refill - seconds
            let countdown = Countdown.at(date, refill: refill)
            #expect(countdown.text(at: date) == Formatting.refillLabel(refill, now: date), "\(seconds)")
            if case let .ticking(_, prefix, suffix) = countdown {
                let label = Formatting.refillLabel(refill, now: date)
                #expect(label.count == prefix.count + suffix.count, "\(seconds): \(label) \(prefix)")
                checked += 1
            }
        }
        #expect(checked > 1_000)
        #expect(Countdown.at(Self.now, refill: nil) == .fixed("?") && Countdown.at(refill, refill: refill) == .fixed("due"))
        #expect(Countdown.at(refill - 30, refill: refill) == .fixed("1m"))
        #expect(Countdown.boundaries(refill: refill).last == refill)
    }

    // MARK: The faces (P1228)

    /// Small: two batteries a line, the account in use first, "+N" for the rest, never more lines than fit; medium: the
    /// panel's rows and as much money as fits its height; large: the batteries grown, never past the width.
    @Test func eachFaceHoldsWhatFits() {
        let small = CGSize(width: 142, height: 142), medium = CGSize(width: 336, height: 142), large = CGSize(width: 336, height: 354)
        let owner = UsageWidgetRenders.owner(), crowded = UsageWidgetRenders.crowded()
        #expect(UsageWidgetLayout.make(owner, face: .small, size: small).slots == [.claude: 4, .codex: 4])
        let crowdedSmall = UsageWidgetLayout.make(crowded, face: .small, size: small)
        #expect(crowdedSmall.slots == [.claude: 4, .codex: 4])
        let (shown, more) = UsageWidgetLayout.smallOrder(crowded.claude, slots: 4)
        #expect(shown.first?.0 == 2 && shown.count == 3 && more == 3, "the account in use first, then the panel's order")
        #expect(UsageWidgetLayout.make(crowded, face: .small, size: small, stale: true).slots.values.reduce(0, +) < 8)
        for snapshot in [owner, crowded] {
            let layout = UsageWidgetLayout.make(snapshot, face: .medium, size: medium)
            let rows = UsageWidgetLayout.rowsHeight(2, scale: layout.scale, large: false)
            let money = UsageWidgetLayout.dividerAbove + 1 + UsageWidgetLayout.dividerBelow + CGFloat(layout.moneyLines) * layout.moneyLineHeight
            #expect(layout.scale <= 1 && rows + money <= medium.height + 0.5, "\(layout)")
            #expect(layout.moneyLines * layout.moneyColumns >= snapshot.moneyRows.count)
        }
        let big = UsageWidgetLayout.make(owner, face: .large, size: large)
        #expect(big.scale == UsageWidgetLayout.maxScale)
        #expect(UsageWidgetLayout.make(crowded, face: .large, size: large).scale * UsageWidgetLayout.runWidth(6) <= large.width + 0.5)
        #expect(UsageWidgetView.readyText(owner.claude) == "2 of 3 ready" && UsageWidgetView.readyText(owner.codex) == "4 of 4 ready")
    }

    /// The one-colour looks draw white alone: no mark's colour, no amber, no red (P1224).
    @Test func theSystemsLooksDrawWhiteAlone() {
        let mono = UsageInk(mono: true), full = UsageInk(mono: false)
        #expect(mono.warn == .white && mono.attention == .white && mono.markTint == .white)
        #expect(full.warn == Theme.warn && full.attention == Theme.attention && full.markTint == nil)
        for row in UsageWidgetRenders.crowded().moneyRows {
            #expect([Color.white, UsageInk.ink2].contains(mono.amount(row)), "\(row.id)")
        }
    }

    /// The widget's full colour is the same in a light and a dark macOS: white ink on Glass and on Black (P1401).
    @Test func fullColourIsTheSameInEitherMode() throws {
        for mode in [UsageWidgetRenders.Mode.glass, .opaque, .black] {
            let scene = UsageWidgetRenders.scene(UsageWidgetRenders.owner(), .medium, wallpaper: .sunset, mode: mode)
            let size = UsageWidgetRenders.sceneSize(.medium)
            let light = try AppearanceRenders.bitmap(scene, size: size, env: .demo(), scheme: .light)
            let dark = try AppearanceRenders.bitmap(scene, size: size, env: .demo(), scheme: .dark)
            #expect(WidgetGlassRenders.alike(light, dark), "\(mode)")
        }
    }

    // MARK: The panel it replaces (P1226, P1227)

    /// Use the widget instead, on in a build that feeds the widget: the panel shows only when Show on desktop says so and
    /// the widget does not take its place; the menus' toggle gives the panel its place back; the pane's switch, turned
    /// off, shows the panel. Off until set, with a store or without (P1281).
    @Test func theWidgetTakesThePanelsPlace() throws {
        let suite = "usage-widget-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = AppSettings(defaults: defaults, identity: .development)
        #expect(!stored.panelUseWidget && stored.panelShown)
        stored.widgetFed = true
        stored.panelUseWidget = true
        #expect(stored.panelUseWidget && stored.panelShowOnDesktop && !stored.panelShown)
        stored.togglePanelShown()
        #expect(!stored.panelUseWidget && stored.panelShowOnDesktop && stored.panelShown)
        #expect(AppSettings(defaults: defaults, identity: .development).panelShown, "kept")
        #expect(AppSettings(defaults: defaults, identity: .development).panelUseWidgetSet)
        stored.togglePanelShown()
        #expect(!stored.panelShowOnDesktop && !stored.panelUseWidget && !stored.panelShown)
        DesktopPanelText.useWidget(true, stored)
        #expect(stored.panelUseWidget && !stored.panelShown)
        DesktopPanelText.useWidget(false, stored)
        #expect(!stored.panelUseWidget && stored.panelShowOnDesktop && stored.panelShown)
        #expect(!AppSettings.ephemeral().panelUseWidget)
        #expect(DesktopPanelText.widgetHint.contains("Edit Widgets") && DesktopPanelText.widgetHint.contains("Usage"))
    }

    /// The controller keeps the panel hidden while the widget takes its place, and shows it the moment it does not.
    @Test func thePanelStaysHiddenWhileTheWidgetTakesItsPlace() {
        let env = AppEnvironment.demo()
        let surface = FakePanelSurface()
        let screen = PanelScreen(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
        let controller = DesktopPanelController(env: env, store: PanelPositionStore(defaults: nil), screens: { [screen] },
                                                makeSurface: { surface })
        env.settings.widgetFed = true
        env.settings.panelUseWidget = true
        controller.apply()
        #expect(!surface.isShown)
        env.settings.panelUseWidget = false
        controller.apply()
        #expect(surface.isShown)
        env.settings.togglePanelShown()
        controller.apply()
        #expect(!surface.isShown)
    }

    /// Dimmed, the panel's inks and marks resolve white, at their own strength; in full colour and over the apps they
    /// keep their Widget twins (P1227).
    @Test func theDimmedPanelDrawsItsInkAndMarksWhite() {
        let mark = GlassTone.adapted(Theme.claudeMark), warn = GlassTone.adapted(Theme.warn, .text)
        func resolve(_ colour: Color, mono: Bool) -> Color.Resolved {
            var environment = EnvironmentValues()
            environment.colorScheme = .dark
            environment.glassWidgetInk = true
            environment.glassWidgetMono = mono
            return colour.resolve(in: environment)
        }
        for colour in [mark, warn, PanelPalette.glass.ink, PanelPalette.glass.ink2] {
            let white = resolve(colour, mono: true), twin = resolve(colour, mono: false)
            #expect(white.red == 1 && white.green == 1 && white.blue == 1 && white.opacity == twin.opacity)
        }
        #expect(resolve(mark, mono: false).blue < 0.9, "full colour keeps Claude's colour")
    }

    // MARK: Where the widget can take the panel's place (P1280, P1281)

    /// A build that does not feed its widgets (ad hoc: every dev build, a --prod one with no signing identity, a copy
    /// built from source) keeps the panel whatever Use the widget instead says: its widget can only say "Not running".
    /// The menus' toggle there hides and shows the panel and leaves the switch as the owner set it.
    @Test func aBuildThatCannotFeedTheWidgetKeepsThePanel() {
        let env = AppEnvironment.demo()
        let surface = FakePanelSurface()
        let screen = PanelScreen(id: "main", name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                 visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 879))
        let controller = DesktopPanelController(env: env, store: PanelPositionStore(defaults: nil), screens: { [screen] },
                                                makeSurface: { surface })
        env.settings.panelUseWidget = true
        env.settings.widgetFed = false
        controller.apply()
        #expect(surface.isShown && env.settings.panelShown, "no feed: the panel stays")
        env.settings.widgetFed = true
        controller.apply()
        #expect(!surface.isShown && !env.settings.panelShown, "fed: the widget takes its place")
        env.settings.widgetFed = false
        env.settings.togglePanelShown()
        #expect(!env.settings.panelShown && env.settings.panelUseWidget)
        env.settings.togglePanelShown()
        #expect(env.settings.panelShown && env.settings.panelUseWidget, "the switch is the owner's")
    }

    /// Use the widget instead is never on by default: the first launch that feeds the widget asks WidgetKit which widgets
    /// are placed and turns it on only for a placed Usage widget (the owner's, which kept its kind, P1220), so an update
    /// never hides the panel of someone who never added the widget. The answer is kept and never asked again; no answer
    /// leaves it unset for the next launch; a build that cannot feed the widget never asks. The panel starts once, after
    /// the answer, or after the patience if none comes.
    @Test func theFirstLaunchTurnsTheWidgetOnOnlyWhereOneIsPlaced() async throws {
        final class Count { var started = 0, asked = 0 }
        for (placed, on) in [([String](), false), (["JuiceIslandSessionsWidget"], false), (["JuiceIslandWidget"], true),
                             (["JuiceIslandSessionsWidget", "JuiceIslandWidget"], true)] {
            let suite = "usage-widget-tests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettings(defaults: defaults, identity: .development)
            #expect(!settings.panelUseWidget && !settings.panelUseWidgetSet && settings.panelShown, "\(placed): off until decided")
            settings.widgetFed = true
            let count = Count()
            await PanelWidgetChoice.settle(settings, placed: { count.asked += 1; return placed }, then: { count.started += 1 })?.value
            #expect(count.asked == 1 && count.started == 1, "\(placed)")
            #expect(settings.panelUseWidget == on && settings.panelUseWidgetSet && settings.panelShown == !on, "\(placed)")
            let later = AppSettings(defaults: defaults, identity: .development)
            later.widgetFed = true
            #expect(later.panelUseWidget == on, "\(placed): kept")
            await PanelWidgetChoice.settle(later, placed: { count.asked += 1; return ["JuiceIslandWidget"] }, then: { count.started += 1 })?.value
            #expect(count.asked == 1 && count.started == 2 && later.panelUseWidget == on, "\(placed): asked once")
        }
        let suite = "usage-widget-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // WidgetKit cannot say: unset, the panel shows, and the next launch asks again.
        let settings = AppSettings(defaults: defaults, identity: .development)
        settings.widgetFed = true
        let count = Count()
        await PanelWidgetChoice.settle(settings, placed: { count.asked += 1; return nil }, then: { count.started += 1 })?.value
        #expect(count.started == 1 && !settings.panelUseWidgetSet && settings.panelShown)
        // A build that cannot feed the widget: never asked, started at once.
        settings.widgetFed = false
        await PanelWidgetChoice.settle(settings, placed: { count.asked += 1; return ["JuiceIslandWidget"] }, then: { count.started += 1 })?.value
        #expect(count.asked == 1 && count.started == 2 && !settings.panelUseWidgetSet)
        // An answer that does not come: the panel starts after the patience, and a late answer still decides.
        settings.widgetFed = true
        let late = PanelWidgetChoice.settle(settings, placed: {
            await Looks.until(60) { count.started == 3 }
            return ["JuiceIslandWidget"]
        }, patience: .milliseconds(20), then: { count.started += 1 })
        #expect(await Looks.until(30) { count.started == 3 }, "the panel waits no longer than the patience")
        await late?.value
        #expect(count.started == 3 && settings.panelUseWidget && !settings.panelShown)
    }

    // MARK: Reloads that keep the widget fresh (P1282)

    /// A file more than an hour old while the app runs (a reload WidgetKit refused or put off, a Mac that slept before the
    /// app wrote again): the widget asks again a heartbeat on, never `.never`, so it reads the app's next write.
    @Test func aStaleSnapshotFromARunningAppAsksAgainSoon() {
        let snapshot = UsageWidgetRenders.owner()
        for late in [3_600.0, 4_000, 86_400] {
            #expect(UsageWidgetProvider.timeline(snapshot, now: Self.now + late).policy == .after(Self.now + late + UsageFreshness.heartbeat),
                    "\(late)")
        }
        #expect(UsageWidgetProvider.timeline(.closed(at: Self.now), now: Self.now + 4_000).policy == .never, "quit: the launch reloads")
    }

    /// While nothing changes the app reloads the Usage widget itself once its last reload is `appReloadAfter` old, ahead
    /// of the widget's own request at the hour and the stale moment after it, so a request WidgetKit put off never leaves
    /// the widget saying "Not updated" while the app runs. Sessions changing all the while do not keep it from that.
    @Test func theAppReloadsTheUsageWidgetBeforeItGoesStale() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WidgetStore(directory: folder)
        let stub = DStub(rows: [DStub.row("run", .codex, .running)])
        let env = AppEnvironment(settings: .ephemeral(), usage: DemoUsageModel(now: Self.now), sessions: stub)
        var clock = Self.now
        let reloads = ReloadCounter()
        let feed = WidgetFeed(env: env, store: store, clock: { clock }, reload: { reloads.bump($0) })
        feed.start()
        feed.drain()
        #expect(reloads.of(.usage) == 1)
        #expect(UsageFreshness.appReloadAfter < UsageFreshness.staleAfter && UsageFreshness.appReloadAfter >= UsageFreshness.heartbeat)
        // Quiet: heartbeats, no reload, until the last reload is `appReloadAfter` old.
        while clock < Self.now + UsageFreshness.appReloadAfter - 5 {
            clock += 5
            feed.changed()
        }
        feed.drain()
        #expect(reloads.of(.usage) == 1)
        clock += 5
        feed.changed()
        feed.drain()
        #expect(reloads.of(.usage) == 2, "the app's own reload before the widget goes stale")
        let read = try #require(store.read())
        #expect(!UsageFreshness.isStale(read, at: clock) && UsageFreshness.reloadAt(read) > clock + UsageFreshness.heartbeat)
        // Busy sessions write the file every few seconds; the Usage widget still gets its reload.
        let start = clock
        var n = 0
        while clock < start + UsageFreshness.appReloadAfter + 5 {
            clock += 5
            n += 1
            stub.rows[0].project = "Turn \(n)"
            feed.changed()
        }
        feed.drain()
        #expect(reloads.of(.usage) == 3)
        feed.stop()
    }

    /// The day's routine reloads (neither urgent nor the app's freshness one) stop at `routinePerDay`; past it a percent
    /// waits for the freshness reload, which is not counted, and a reload a day old no longer counts.
    @Test func routineReloadsStopAtTheDaysCap() throws {
        var policy = WidgetReloadPolicy(kind: .usage)
        let cap = try #require(WidgetKind.usage.routinePerDay)
        #expect(WidgetKind.sessions.routinePerDay == nil && cap <= 24)
        var snapshot = UsageWidgetRenders.owner()
        var clock = Self.now
        policy.reloaded(snapshot, at: clock)
        func percent(_ left: Int) {
            snapshot.claude[0].state = .available(left: left, low: false)
        }
        for i in 0..<cap {
            percent(80 - i)
            clock += WidgetKind.usage.floor
            #expect(policy.decide(snapshot, at: clock) == .now, "\(i)")
            policy.reloaded(snapshot, at: clock)
        }
        percent(50)
        #expect(policy.decide(snapshot, at: clock + WidgetKind.usage.floor) == .at(clock + UsageFreshness.appReloadAfter), "capped")
        // The freshness reload is not one of the day's routine ones.
        clock += UsageFreshness.appReloadAfter
        #expect(policy.decide(snapshot, at: clock) == .now)
        policy.reloaded(snapshot, at: clock)
        percent(49)
        #expect(policy.decide(snapshot, at: clock + WidgetKind.usage.floor) == .at(clock + UsageFreshness.appReloadAfter), "still capped")
        // Urgent changes are never capped.
        var low = snapshot
        low.claude[0].state = .available(left: 9, low: true)
        #expect(policy.decide(low, at: clock + 1) == .now)
        // A day after the first routine reload, the cap frees up again.
        #expect(policy.decide(snapshot, at: Self.now + 86_400 + WidgetKind.usage.floor) == .now)
    }
}
