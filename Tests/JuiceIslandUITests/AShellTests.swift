import AppKit
import Foundation
import JuiceCore
import SwiftUI
import Testing
@testable import JuiceIslandUI

/// Stream A's logic: the key recorder's combos, Diagnostics wording, toolbar words, the fold's geometry.
@MainActor
struct AShellTests {
    // MARK: KeyCombo

    @Test func keyComboRoundTripsItsStorage() throws {
        let combo = try #require(KeyCombo(storage: "ctrl+shift+g"))
        #expect(combo.control && combo.shift && !combo.option && !combo.command && combo.key == "g")
        #expect(combo.storage == "ctrl+shift+g")
        #expect(combo.display == "⌃⇧G")
        #expect(KeyCombo(storage: "") == nil)
        #expect(KeyCombo(storage: "hyper+g") == nil)
    }

    @Test func keyComboDisplaysModifiersInSystemOrder() {
        let combo = KeyCombo(control: true, option: true, shift: true, command: true, key: "J")
        #expect(combo.display == "⌃⌥⇧⌘J")
        #expect(combo.storage == "ctrl+opt+shift+cmd+j")
    }

    @Test func ctrlGIsAllowedWithTheWarning() {
        let ctrlG = KeyCombo(control: true, key: "g")
        #expect(ctrlG.isAcceptable)
        #expect(ctrlG.warning == KeyCombo.ctrlGWarning)
        #expect(KeyCombo(control: true, shift: true, key: "g").warning == nil)
        #expect(KeyCombo(command: true, key: "g").warning == nil)
    }

    @Test func aPlainOrShiftedKeyIsRefused() {
        #expect(!KeyCombo(key: "g").isAcceptable)
        #expect(!KeyCombo(shift: true, key: "g").isAcceptable)
        #expect(KeyCombo(option: true, key: "g").isAcceptable)
    }

    @Test func keyComboComesFromCharactersNotKeyCodes() throws {
        // Dvorak's "G" arrives as the character g whatever its key code (P40).
        let combo = try #require(KeyCombo.from(characters: "G", modifiers: [.control, .shift]))
        #expect(combo.key == "g" && combo.control && combo.shift)
        #expect(KeyCombo.from(characters: " ", modifiers: [.option])?.key == "space")
        #expect(KeyCombo.from(characters: String(UnicodeScalar(UInt16(NSF5FunctionKey))!), modifiers: [.command])?.display == "⌘F5")
        #expect(KeyCombo.from(characters: "", modifiers: [.control]) == nil)
        #expect(KeyCombo.from(characters: nil, modifiers: [.control]) == nil)
    }

    // MARK: Diagnostics

    @Test func agesAndDueTimes() {
        #expect(DiagnosticsText.age(20) == "20s ago")
        #expect(DiagnosticsText.age(125) == "2m ago")
        #expect(DiagnosticsText.age(3 * 3_600 + 5) == "3h ago")
        #expect(DiagnosticsText.age(2 * 86_400) == "2d ago")
        #expect(DiagnosticsText.age(-5) == "0s ago")
        #expect(DiagnosticsText.due(40) == "in 40s")
        #expect(DiagnosticsText.due(240) == "in 4m")
        #expect(DiagnosticsText.due(21_600) == "in 6h")
    }

    @Test func accountLinesFollowTheDemoReadings() throws {
        let usage = DemoUsageModel()
        let entries = DiagnosticsText.accounts(usage.logins, records: usage.records, now: usage.now)
        func line(_ label: String) throws -> DiagnosticsText.AccountLine { try #require(entries.first { $0.label == label }).line }
        // One row per login (the demo's folders each hold their own), then the folders no login row lists.
        #expect(entries.map(\.label) == ["Main", "Work", "Research", "Lab", "Studio", "Alt", "Home", "Team", "Night", "Spare", "Edge"])
        #expect(try line("Main") == .init(lastRead: "1m ago", next: "in 4m", status: "OK", tone: .normal))
        #expect(try line("Home") == .init(lastRead: "20s ago", next: "in 40s", status: "OK", tone: .normal))
        #expect(try line("Studio") == .init(lastRead: "2d ago", next: "paused", status: "Sign-in required", tone: .red))
        #expect(try line("Spare").status == "Stale · retrying")
        #expect(try line("Spare").tone == .amber)
        #expect(try line("Alt") == .init(lastRead: "never", next: "now", status: "New · first read due", tone: .normal))
    }

    static func loginRow(_ folders: [Account], state: AccountState, monitored: Bool = true) -> LoginRow {
        let id = LoginsStore.id(provider: folders[0].provider, email: "person@example.com")
        return LoginRow(id: id, provider: folders[0].provider, email: "person@example.com", plan: "Max",
                        battery: BatteryModel(id: id, alias: "person", state: state, isNext: false, hoverLabel: "person"),
                        monitored: monitored, folders: folders)
    }

    @Test func aRateLimitedAccountRetriesAfterRetryAfterPlus900Seconds() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = Self.loginRow([Account(provider: .claude, folder: "~/.claude-lab", alias: "Lab")], state: .available(percentLeft: 37, isLow: false))
        let record = AccountRecord(lastError: .rateLimited(retryAfter: 60), lastErrorAt: now - 100, lastAttemptAt: now - 100)
        let clock: (Date) -> String = { "t+\(Int($0.timeIntervalSince(now)))" }
        let line = DiagnosticsText.login(row, record: record, schedule: nil, now: now, clock: clock)
        // The retry time once, in Next; the status is the word alone (every fact once).
        #expect(line.status == "Rate limited" && line.next == "t+860")
        #expect(line.tone == .amber)
        // The scheduler's own time wins where there is one.
        #expect(DiagnosticsText.login(row, record: record, schedule: ReadSchedule(next: now + 900), now: now, clock: clock).next == "t+900")
    }

    /// The login's own Monitor switch, not its folders': a login switched off reads nothing and says so (P360).
    @Test func anUnmonitoredLoginSaysSo() {
        let row = Self.loginRow([Account(provider: .codex, folder: "~/.codex-side", alias: "Side")], state: .available(percentLeft: 50, isLow: false),
                                monitored: false)
        let line = DiagnosticsText.login(row, record: nil, schedule: ReadSchedule(next: .now + 30), now: .now)
        #expect(line.status == "Not monitored" && line.next == "off")
    }

    /// A No plan login (P360): the word, its 6-hour wait from the schedule, and no amber.
    @Test func aNoPlanLoginSaysNoPlanWithItsWait() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = Self.loginRow([Account(provider: .claude, folder: "~/.claude-work", alias: "Work")], state: .noPlan)
        let streak = NoPlanStreak(since: now - 2_400, last: now - 60, reads: 3)
        let record = AccountRecord(lastError: .noPlanLimits, lastErrorAt: now - 60, lastAttemptAt: now - 60, consecutiveFailures: 3, noPlan: streak)
        let line = DiagnosticsText.login(row, record: record, schedule: ReadSchedule(next: now - 60 + NoPlanStreak.interval), now: now)
        #expect(line == .init(lastRead: "1m ago", next: "in 6h", status: "No plan", tone: .normal))
        // Without a schedule the wait is counted from the last such answer.
        #expect(DiagnosticsText.login(row, record: record, schedule: nil, now: now).next == "in 6h")
        #expect(DiagnosticsText.login(row, record: record, schedule: ReadSchedule(next: now, reading: true), now: now).next == "reading")
    }

    @Test func moneyStatusesAndTheFiveMinuteOpenAIRead() {
        #expect(DiagnosticsText.money(id: "OpenAI", readable: true) == ("in 5m", "OK · usage API, every 5 min"))
        #expect(DiagnosticsText.money(id: "OpenRouter", readable: true).status == "OK")
        #expect(DiagnosticsText.money(id: "Hetzner", readable: false).status == "No token · add in Money")
        #expect(DiagnosticsText.money(id: "RunPod", readable: false).status == "Not connected · no key file")
    }

    @Test func theReportCarriesNoFoldersOrEmails() {
        let usage = DemoUsageModel()
        let entries = DiagnosticsText.accounts(usage.logins, records: usage.records, now: usage.now)
        let report = DiagnosticsText.report(lines: entries.map { ($0.label, $0.provider, $0.line) }, money: [("OpenRouter", "OK")])
        #expect(report.contains("Claude Main: OK"))
        #expect(!report.contains("~/"))
        #expect(!report.contains("@"))
        // An alias that looks like an email is cut at its "@".
        #expect(DiagnosticsText.label([Account(provider: .codex, folder: "~/.codex", alias: "person@example.com"),
                                       Account(provider: .codex, folder: "~/.codex-side", alias: "Side")]) == "person + Side")
    }

    /// A read that failed before any good one: the row and the report say "Read failed", never the CLI's own text, which
    /// can carry a path or an email (spec §4.5, P364).
    @Test func aFailedReadSaysReadFailedAndNoMore() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = Self.loginRow([Account(provider: .claude, folder: "~/.claude-lab", alias: "Lab")], state: .unknown)
        let text = "Error: EACCES: permission denied, open '/Users/someone/.claude-lab/x.json' for person@example.com"
        let record = AccountRecord(lastError: .failed(text), lastErrorAt: now - 60, lastAttemptAt: now - 60, consecutiveFailures: 1)
        let line = DiagnosticsText.login(row, record: record, schedule: nil, now: now)
        #expect(line == .init(lastRead: "1m ago", next: "now", status: "Read failed", tone: .amber))
        let report = DiagnosticsText.report(lines: [("Lab", .claude, line)], money: [])
        #expect(report.contains("  Claude Lab: Read failed (read 1m ago, next now)"))
        #expect(!report.contains("/Users") && !report.contains("@") && !report.contains("EACCES"))
        // The other kinds keep their fixed words.
        let incomplete = AccountRecord(lastError: .incomplete("plan limits missing"), lastErrorAt: now - 60, lastAttemptAt: now - 60)
        #expect(DiagnosticsText.login(row, record: incomplete, schedule: nil, now: now).status == "Reading incomplete: plan limits missing")
        let update = AccountRecord(lastError: .cliUpdateNeeded("claude 2.0.1 at /Users/someone/bin"), lastErrorAt: now - 60, lastAttemptAt: now - 60)
        #expect(DiagnosticsText.login(row, record: update, schedule: nil, now: now).status == "CLI update needed")
    }

    @Test func tableColumnsSplitByTheirWeights() {
        let widths = DiagnosticsTable.columnWidths(total: 420)
        #expect(widths.map { Int($0.rounded()) } == [120, 80, 70, 150])
    }

    // MARK: Toolbar and fold

    @Test func toolbarTooltipsNameTheShortcut() {
        #expect(ToolbarText.showAsIsland == "Show as island  ⌘⇧I")
        #expect(ToolbarText.gear == "Settings")
    }

    @Test func theTitleLineCentresOnTheTrafficLights() {
        // macOS 26's compact title bar: close at x 12, zoom ending at 72, both centred 20 pt from the top of 760.
        let metrics = WindowChromeMetrics.from(close: CGRect(x: 12, y: 733, width: 14, height: 14),
                                               zoom: CGRect(x: 58, y: 733, width: 14, height: 14), frameHeight: 760)
        #expect(metrics == .standard)
        #expect(metrics.lineHeight == 40 && metrics.contentLeading == 86)
    }

    @Test func theMainWindowPutsItsContentUnderTheTitleBar() throws {
        let controller = MainWindowController(env: .demo(sessions: .prototype))
        let window = controller.window
        #expect(window.styleMask.contains(.fullSizeContentView) && window.titlebarAppearsTransparent)
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
        let hosting = try #require(window.contentView as? NSHostingView<AnyView>)
        #expect(hosting.safeAreaRegions.isEmpty)
        #expect(hosting.frame.height == window.contentView?.superview?.bounds.height)
        // The measured line is the lights' line: 2 × their centre, content after the zoom button.
        let metrics = WindowChromeMetrics.measure(window)
        let zoom = try #require(window.standardWindowButton(.zoomButton))
        let frameView = try #require(window.contentView?.superview)
        let zoomFrame = zoom.convert(zoom.bounds, to: frameView)
        #expect(abs(metrics.lineHeight / 2 - (frameView.bounds.height - zoomFrame.midY)) <= 0.5)
        #expect(metrics.contentLeading > zoomFrame.maxX)
        // The title bar is no taller than the line and its hairline, so the list never runs under it.
        #expect(window.frame.height - window.contentLayoutRect.height <= metrics.lineHeight + 1)
        // The title bar lets clicks through to the content (the line's buttons and drag area).
        let hit = frameView.hitTest(NSPoint(x: 300, y: frameView.bounds.height - metrics.lineHeight / 2))
        #expect(hit === hosting || hit?.isDescendant(of: hosting) == true)
    }

    /// The header's height at `width` (the toolbar line, the usage on it or under it).
    static func headerHeight(width: CGFloat, env: AppEnvironment) -> CGFloat {
        let view = WindowHeaderView().frame(width: width).fixedSize(horizontal: false, vertical: true)
        return NSHostingView(rootView: view.environment(env).environment(\.colorScheme, .dark)).fittingSize.height
    }

    static func demoEnv(_ configure: (AppSettings) -> Void) -> AppEnvironment {
        let settings = AppSettings.ephemeral()
        configure(settings)
        return .demo(settings: settings)
    }

    @Test func theStripKeepsTheBatteriesOnTheTitleLineWhenOnlyTheyFit() {
        let line = WindowChromeMetrics.standard.lineHeight
        // 1200: the eleven batteries fit on the lights' line; the money is the one 22 pt line under it (+ 8 below).
        let strip = Self.demoEnv { $0.windowHeader = .strip }
        #expect(Self.headerHeight(width: 1200, env: strip) == line + UsageMoneyGrid.rowHeight + UsageLayout.bottomPadding)
        // With no room for them next to the toolbar, the batteries get their own line under it.
        #expect(Self.headerHeight(width: 760, env: strip) > line + UsageMoneyGrid.rowHeight + UsageLayout.bottomPadding)
        // Section keeps its band (the batteries' two rows beside the money grid).
        #expect(Self.headerHeight(width: 1200, env: Self.demoEnv { $0.windowHeader = .section }) > line + 2 * UsageLayout.rowHeight)
        // No money: everything on the one line.
        #expect(Self.headerHeight(width: 1200, env: Self.demoEnv { $0.windowShowsMoney = false }) == line)
    }

    @Test func accountNamesHangUnderTheTitleLineWithoutLiftingTheBatteries() {
        let line = WindowChromeMetrics.standard.lineHeight
        let env = Self.demoEnv { $0.windowShowsMoney = false; $0.accountNamesUnderBatteries = true }
        // Battery centred on the lights (line / 2), then its name: 10 + 20 + 5 + 13, and half the band's bottom gap.
        let expected = (line - Theme.Mark.row) / 2 + UsageLayout.batteryLineHeight(names: true) + UsageLayout.bottomPadding / 2
        #expect(Self.headerHeight(width: 1200, env: env) == expected)
    }

    @Test func theFoldEndsAtThePillAtTheTopCentreOfItsScreen() {
        let target = WindowFold.target(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(target == CGRect(x: 634, y: 949, width: 244, height: 33))
        let second = WindowFold.target(screenFrame: CGRect(x: 1512, y: -200, width: 2560, height: 1440))
        #expect(second.midX == 1512 + 1280 && second.maxY == 1240)
    }

    @Test func theFoldStaysOpaqueUntil55Percent() {
        #expect(WindowFold.opacity(at: 0) == 1)
        #expect(WindowFold.opacity(at: 0.55) == 1)
        #expect(abs(WindowFold.opacity(at: 0.775) - 0.5) < 0.0001)
        #expect(WindowFold.opacity(at: 1) == 0)
        #expect(WindowFold.opacity(at: 2) == 0)
    }

    /// The ghost never resizes: one window over the window, the pill and the shadow's room, the snapshot's path in it.
    @Test func theFoldPlaysInOneStillWindowOverItsWholePath() {
        let window = CGRect(x: 100, y: 80, width: 1200, height: 760)
        let pill = WindowFold.target(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let stage = WindowFold.stage(window: window, pill: pill)
        let room = WindowFold.shadowRoom
        #expect(stage.frame == CGRect(x: 100 - room, y: 80 - room, width: 1200 + 2 * room, height: 982 - 80 + 2 * room))
        #expect(stage.from == window.offsetBy(dx: room - 100, dy: room - 80))
        #expect(stage.to == pill.offsetBy(dx: room - 100, dy: room - 80))
        #expect(stage.from.size == window.size && stage.to.size == pill.size)
    }

    /// The snapshot starts exactly over the window, the right way up, and is left at the pill, faded out, with its
    /// shadow: the fold's animations take both there on its curve, the fade holds until 55 %, and each asks the display
    /// for 80 to 120 Hz while it plays (E2).
    @Test func theGhostStartsOverTheWindowUprightAndEndsAtThePill() throws {
        let window = CGRect(x: 0, y: 0, width: 120, height: 80)
        let stage = WindowFold.stage(window: window, pill: CGRect(x: 40, y: 150, width: 40, height: 10))
        // The snapshot: red on its top half, blue under it.
        let context = try #require(Self.bitmap(width: 120, height: 80))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 120, height: 40))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 40, width: 120, height: 40))
        let snapshot = try #require(context.makeImage())
        let ghost = WindowFold.layers(snapshot, stage: stage)
        #expect(ghost.sublayers?.map(\.frame) == [stage.from, stage.from])
        let start = try Self.render(ghost)
        #expect(start.pixel(x: stage.from.midX, y: stage.from.maxY - 10) == .red)
        #expect(start.pixel(x: stage.from.midX, y: stage.from.minY + 10) == .blue)
        #expect(start.pixel(x: stage.from.midX, y: stage.to.midY) == .clear)

        // Held in a transaction of the test's own until the checks are done: a layer on no display drops a finished or
        // unstarted animation at the main thread's next commit, and a full run has had one come between the play and the
        // look (the bounds animation found gone). Nested, the play's own commit waits for this one (P1255).
        CATransaction.begin()
        defer { CATransaction.commit() }
        WindowFold.play(ghost, stage: stage)
        #expect(ghost.sublayers?.map(\.frame) == [stage.to, stage.to])
        #expect(ghost.opacity == 0)
        for layer in ghost.sublayers ?? [] {
            let bounds = try #require(layer.animation(forKey: "bounds") as? CABasicAnimation)
            let position = try #require(layer.animation(forKey: "position") as? CABasicAnimation)
            for animation in [bounds, position] {
                #expect(animation.duration == WindowFold.duration && animation.timingFunction == WindowFold.curve)
                #expect(animation.preferredFrameRateRange == IslandFramePacing.motion)
            }
            #expect((bounds.fromValue as? NSValue)?.rectValue.size == stage.from.size)
            #expect((position.fromValue as? NSValue)?.pointValue == CGPoint(x: stage.from.midX, y: stage.from.midY))
            #expect((position.toValue as? NSValue)?.pointValue == CGPoint(x: stage.to.midX, y: stage.to.midY))
        }
        let fade = try #require(ghost.animation(forKey: "opacity") as? CAKeyframeAnimation)
        #expect(fade.keyTimes == [0, 0.55, 1] && fade.values as? [Double] == [1, 1, 0] && fade.duration == WindowFold.duration)
        #expect(fade.preferredFrameRateRange == IslandFramePacing.motion)
    }

    enum Pixel { case red, blue, clear, other }

    struct Rendered {
        let data: [UInt8]
        let width: Int, height: Int

        /// The pixel at `(x, y)` in the layer's coordinates (y up).
        func pixel(x: CGFloat, y: CGFloat) -> Pixel {
            let row = height - 1 - Int(y), i = (row * width + Int(x)) * 4
            // Colour matching moves the pure colours a little (red draws about 255, 38, 0).
            let (r, g, b, a) = (data[i], data[i + 1], data[i + 2], data[i + 3])
            if a == 0 { return .clear }
            if a > 250, r > 200, g < 80, b < 60 { return .red }
            if a > 250, r < 60, g < 80, b > 200 { return .blue }
            return .other
        }
    }

    static func bitmap(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func render(_ layer: CALayer) throws -> Rendered {
        let width = Int(layer.bounds.width), height = Int(layer.bounds.height)
        let context = try #require(bitmap(width: width, height: height))
        layer.render(in: context)
        let data = try #require(context.data)
        return Rendered(data: Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4)),
                        width: width, height: height)
    }

    @Test func islandPaneExplainsOnlyGlance() {
        #expect(IslandPaneText.finish(.glance)?.contains("green dot") == true)
        #expect(IslandPaneText.finish(.card) == nil)
    }

    /// Motion (Original · Refined) changes nothing while macOS Reduce Motion is on (the island then only fades and
    /// snaps), so the row shows only with it off; Hover keeps its rest either way.
    @Test func islandPaneShowsMotionOnlyWhereItChangesSomething() {
        #expect(IslandPaneText.showsMotionRow(reduceMotion: false))
        #expect(!IslandPaneText.showsMotionRow(reduceMotion: true))
    }

    @Test func sidebarListsTenPanesWithoutWatch() {
        let panes = SettingsSidebar.groups.flatMap { $0 }
        #expect(panes.count == 10)
        #expect(Set(panes) == Set(SettingsPane.allCases))
    }

    @MainActor @Test func setupSaysMissingOnce() {
        let lab = DemoHooksModel.fixture.first { $0.alias == "Lab" }
        #expect(lab?.word == "Partial 12/14")
        #expect(lab?.detail == "Missing Notification, PreCompact")
        // A refused profile shows its reason and offers no button.
        let night = DemoHooksModel.fixture.first { $0.alias == "Night" }
        #expect(night?.buttonTitle == nil)
        #expect(night?.refusal == "Edit hooks.json by hand")
    }

    @Test func ctrlGWarningFitsOneLine() {
        #expect(KeyCombo.ctrlGWarning.count <= 40)
        #expect(KeyCombo.ctrlGWarning.contains("⌃G"))
    }

    @Test func soundChoicesHashByName() {
        let set: Set<SoundChoice> = [.none, .system("Glass"), .system("Glass")]
        #expect(set.count == 2)
        #expect(SoundChoices.options.first?.0 == SoundChoice.none)
    }
}
