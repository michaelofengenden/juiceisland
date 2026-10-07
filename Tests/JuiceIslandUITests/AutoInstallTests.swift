import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// Settings › About › Install automatically (P1070 to P1074). The private app: a build prepared in the background is
/// installed through Restart to update at the first quiet moment (no card waiting on the owner, no key for a minute),
/// never quits for it while a card waits, and the build it opens says so. The public flavor: Sparkle's own automatic
/// install, handed the setting, its download offered as Restart to update and named after the restart. Over a stub
/// updater in a temporary bundle, fake clocks and timers, a fake feed; nothing is built, installed or quit.
@MainActor
@Suite(.serialized)
struct AutoInstallTests {
    static let build = String(repeating: "a", count: 40)
    static let tip = String(repeating: "c", count: 40)
    /// How many seconds' worth of looks a wait may take (`Looks`): counted looks, not the clock, as a full run has held
    /// the main actor for minutes (P1253).
    nonisolated static let patience: TimeInterval = 60

    /// A scratch bundle whose updater answers an install as update-app.sh does: `ready`, then it waits for `<script>.go`
    /// or for the sandbox to be removed, however long a loaded run takes to get there (W3R-9); a test process that died
    /// before either ends it too, so it is never left behind.
    private struct Sandbox {
        let root: URL
        let paths: UpdateController.Paths
        var repo: URL { root.appendingPathComponent("repo", isDirectory: true) }
        var bundle: URL { root.appendingPathComponent("Juice Island.app", isDirectory: true) }
        var script: URL { bundle.appendingPathComponent(UpdateController.scriptPath) }
        var calls: [String] {
            ((try? String(contentsOf: URL(fileURLWithPath: script.path + ".calls"), encoding: .utf8)) ?? "")
                .split(separator: "\n").map(String.init)
        }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-auto-\(UUID().uuidString)", isDirectory: true)
            paths = UpdateController.Paths(statusFile: root.appendingPathComponent("support/update-status"),
                                           logFile: root.appendingPathComponent("logs/update.log"))
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let body = """
            #!/bin/zsh
            set -u
            self="$0"
            print -r -- "mode:${JI_RUN_MODE:-update}" >> "$self.calls"
            print -r -- "app:$2" >> "$JI_STATUS_FILE"; print -r -- verifying >> "$JI_STATUS_FILE"; print -r -- ready >> "$JI_STATUS_FILE"
            runner=$PPID
            until [[ -e "$self.go" ]]; do [[ -e "$self" ]] && kill -0 $runner 2>/dev/null || exit 0; sleep 0.02; done
            exit 0
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
        }

        func go() { FileManager.default.createFile(atPath: script.path + ".go", contents: nil) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// The private app's pieces, with a build prepared for origin/main's tip as the last check has it.
    @MainActor private final class World {
        let settings = AppSettings.ephemeral()
        let checker = UpdateChecker(stamp: BuildStamp(commit: AutoInstallTests.build, repoPath: nil), git: NoGitRunner())
        let sessions = LaneSessions()
        let scheduler = FakeWallScheduler()
        let clock = LaneClock(Date(timeIntervalSinceReferenceDate: 800_000_000))
        var sinceKey: TimeInterval = 600
        /// When the app's last sound ends (`SystemSoundPlayer.playingUntil`): none has played.
        var soundUntil: Date?
        var marker: String?
        var quits = 0
        var controller: UpdateController!
        var auto: AutoInstall!

        init(_ box: Sandbox, prepared: String? = AutoInstallTests.tip, commit: String = AutoInstallTests.build) {
            checker.report(.checked(UpdateInfo(newer: 2, subjects: ["Two", "One"], tip: AutoInstallTests.tip), at: clock.now))
            let context = UpdateController.Context(prepareEnabled: { [settings] in settings.prepareUpdates || settings.installAutomatically },
                                                   powerAllows: { false }, latest: { [checker] in checker.available },
                                                   automaticCommit: { [unowned self] in self.marker },
                                                   markAutomatic: { [unowned self] in self.marker = $0 })
            controller = UpdateController(repoPath: box.repo.path, build: String(commit.prefix(7)), commit: commit, paths: box.paths,
                                          pid: 4242, bundlePath: box.bundle.path, prepared: prepared, pollInterval: .milliseconds(30),
                                          quitRetry: 0.05, finishHold: .zero, now: { Date() }, quitSignal: { "USR2" },
                                          quit: { [unowned self] in self.quits += 1 }, context: context)
            let sessions = sessions
            controller.quitWaits = { !sessions.waiting.isEmpty }
            auto = AutoInstall(settings: settings, controller: controller, checker: checker, sessions: sessions, scheduler: scheduler,
                               clock: { [clock] in clock.now }, sinceKey: { [unowned self] in self.sinceKey },
                               soundUntil: { [unowned self] in self.soundUntil })
        }

        func card(_ id: String = "s1") -> SessionRow {
            var row = DStub.row(id, .claude, .needsYou)
            row.hasCard = true
            return row
        }
    }

    private func wait(until done: () -> Bool) async -> Bool {
        await Looks.until(Self.patience, done)
    }

    @Test func aQuietMomentIsNoCardWaitingAndNoKeyForAMinute() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        #expect(QuietMoment.verdict(waiting: 0, sinceKey: 60, now: now) == .now)
        #expect(QuietMoment.verdict(waiting: 1, sinceKey: 600, now: now) == .sessionsWait)
        #expect(QuietMoment.verdict(waiting: 1, sinceKey: 5, now: now) == .sessionsWait)
        #expect(QuietMoment.verdict(waiting: 0, sinceKey: 15, now: now) == .typing(until: now.addingTimeInterval(45)))
        // A sound of the app's that still plays waits first; one that ended, or none yet, waits for nothing (P1075).
        let end = now.addingTimeInterval(3)
        #expect(QuietMoment.verdict(waiting: 0, sinceKey: 600, soundUntil: end, now: now) == .sound(until: end))
        #expect(QuietMoment.verdict(waiting: 1, sinceKey: 600, soundUntil: end, now: now) == .sessionsWait)
        #expect(QuietMoment.verdict(waiting: 0, sinceKey: 15, soundUntil: end, now: now) == .sound(until: end))
        #expect(QuietMoment.verdict(waiting: 0, sinceKey: 600, soundUntil: now, now: now) == .now)
        #expect(QuietMoment.verdict(waiting: 0, sinceKey: 600, soundUntil: nil, now: now) == .now)
        // Off by default, in plain words in both flavors.
        #expect(!AppSettings.ephemeral().installAutomatically)
        #expect(UpdateText.installAutomatically(feed: false) == "At a quiet moment: nothing waits on you, no typing for a minute.")
        #expect(UpdateText.installAutomatically(feed: true) == "Downloads in the background and installs when you quit.")
        #expect(UpdateText.prepare(installsAutomatically: false) == "On power only. Installing waits for your click.")
        #expect(UpdateText.prepare(installsAutomatically: true) == "On power only.")
    }

    /// A card waits, then a key went down 10 s ago, then again at the minute's end: nothing installs, one timer at a time.
    /// Quiet at last: Restart to update's install, marked automatic. A card that comes at ready holds the quit until it
    /// is answered; then the app is asked to quit.
    @Test func aPreparedBuildInstallsAtTheFirstQuietMomentAndNeverQuitsWhileACardWaits() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World(box)
        world.settings.installAutomatically = true
        world.sessions.rows = [world.card()]
        world.sinceKey = 10
        world.auto.start()
        #expect(world.controller.phase == .idle && box.calls.isEmpty && !world.auto.isWaitingForTyping)

        world.sessions.rows = []
        await laneSettle { world.auto.isWaitingForTyping }
        #expect(world.auto.isWaitingForTyping && world.controller.phase == .idle)
        #expect(world.scheduler.pending.map(\.at) == [world.clock.now.addingTimeInterval(50)])

        world.clock.now = world.clock.now.addingTimeInterval(50)
        world.sinceKey = 5
        world.scheduler.advance(to: world.clock.now)
        #expect(world.controller.phase == .idle && world.scheduler.pending.count == 1)

        world.clock.now = world.clock.now.addingTimeInterval(56)
        world.sinceKey = 61
        world.scheduler.advance(to: world.clock.now)
        #expect(world.controller.phase == .installing && world.controller.runIsAutomatic && world.marker == Self.tip)
        #expect(world.scheduler.pending.isEmpty)
        // A card comes while it installs, before the controller has looked at the status file again (nothing yields
        // between the start and here, so no poll of its own has run).
        world.sessions.rows = [world.card("s2")]
        #expect(await wait { box.calls == ["mode:install"] })
        #expect(await wait { world.controller.poll(); return world.controller.phase == .restarting })
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(30))
            world.controller.poll()
        }
        world.controller.scriptAskedToQuit()
        #expect(world.quits == 0 && world.controller.phase == .restarting)

        world.sessions.rows = []
        #expect(await wait { world.controller.poll(); return world.quits > 0 })
        box.go()
    }

    /// A sound that plays as the moment comes holds the install until it ends: one timer, for its end (P1075). The app's
    /// quit at ready waits for one too: `AutoInstall.app` reads `SystemSoundPlayer`, which a played sound sets (here
    /// without a sound: tests play none).
    @Test func aSoundThatPlaysHoldsTheInstallAndTheQuitUntilItEnds() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World(box)
        world.settings.installAutomatically = true
        world.soundUntil = world.clock.now.addingTimeInterval(4)
        world.auto.start()
        #expect(world.controller.phase == .idle && box.calls.isEmpty && world.auto.isWaitingForTyping)
        #expect(world.scheduler.pending.map(\.at) == [world.clock.now.addingTimeInterval(4)])

        world.clock.now = world.clock.now.addingTimeInterval(4)
        world.scheduler.advance(to: world.clock.now)
        #expect(world.controller.phase == .installing && world.controller.runIsAutomatic && world.scheduler.pending.isEmpty)
        #expect(await wait { box.calls == ["mode:install"] })
        box.go()

        let env = AppEnvironment.demo(sessions: .empty)
        env.flavor = .private
        _ = try #require(AutoInstall.app(env: env))
        let quiet = Date()
        SystemSoundPlayer.heard(for: 0.3, now: quiet)
        #expect(SystemSoundPlayer.isPlaying(at: quiet.addingTimeInterval(0.5)))
        #expect(!SystemSoundPlayer.isPlaying(at: quiet.addingTimeInterval(0.6)))
        #expect(env.sessions.waiting.isEmpty && env.updateController.quitWaits())
        #expect(await wait { !env.updateController.quitWaits() })
    }

    /// Nothing installs with the setting off, with nothing prepared, while an update runs, or for a tip origin/main moved
    /// past; turning it on prepares too, and turning Prepare off turns it off (About's switches).
    @Test func nothingInstallsUnlessABuildWaitsAndTheSettingIsOn() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World(box)
        world.auto.start()
        #expect(world.controller.phase == .idle && box.calls.isEmpty)

        let unprepared = World(box, prepared: nil)
        unprepared.settings.installAutomatically = true
        unprepared.auto.start()
        #expect(unprepared.controller.phase == .idle)

        let moved = World(box)
        moved.settings.installAutomatically = true
        moved.checker.report(.checked(UpdateInfo(newer: 3, subjects: [], tip: String(repeating: "d", count: 40)), at: moved.clock.now))
        moved.auto.start()
        #expect(moved.controller.phase == .idle && box.calls.isEmpty)

        // A run that fails at once (no updater in the bundle) is not tried again for the same build: no loop.
        let broken = try Sandbox()
        defer { broken.remove() }
        try FileManager.default.removeItem(at: broken.script)
        let failing = World(broken)
        failing.settings.installAutomatically = true
        failing.auto.start()
        if case .failed = failing.controller.phase {} else { Issue.record("the run did not fail: \(failing.controller.phase)") }
        #expect(failing.marker == nil && failing.controller.prepared == Self.tip)
        await laneSettle()
        #expect(!failing.controller.phase.isRunning && failing.marker == nil && failing.auto.attempts == 1)

        // About's switches: Install automatically turns Prepare on (a build must be ready first), Prepare off turns it
        // off; the feed has no Prepare to turn on.
        let settings = AppSettings.ephemeral()
        UpdateSwitches.setPrepare(false, settings: settings)
        UpdateSwitches.setInstallAutomatically(true, settings: settings, git: true)
        #expect(settings.installAutomatically && settings.prepareUpdates)
        UpdateSwitches.setPrepare(false, settings: settings)
        #expect(!settings.installAutomatically && !settings.prepareUpdates)
        UpdateSwitches.setInstallAutomatically(true, settings: settings, git: false)
        #expect(settings.installAutomatically && !settings.prepareUpdates)
        // With Prepare off but Install automatically on (an older stored pair), it still prepares: the world's context
        // reads either.
        let either = World(box, prepared: Self.tip)
        either.settings.prepareUpdates = false
        either.settings.installAutomatically = true
        #expect(either.controller.restartOffered(for: either.checker.available))
    }

    /// The build an automatic install opened says so once: its What's new card is "Updated automatically"; any other
    /// build (the install failed, a manual update since) says What's new, and the record is read once.
    @Test func theBuildItOpenedSaysSo() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let opened = World(box, prepared: nil, commit: Self.tip)
        opened.marker = Self.tip
        opened.controller.restoreAfterLaunch()
        #expect(opened.controller.installedAutomatically && opened.marker == nil)
        #expect(UpdateText.whatsNewTitle(automatic: true) == "Updated automatically")

        let other = World(box, prepared: nil)
        other.marker = Self.tip
        other.controller.restoreAfterLaunch()
        #expect(!other.controller.installedAutomatically && other.marker == nil)
        #expect(UpdateText.whatsNewTitle(automatic: false) == "What's new")
    }

    /// The public flavor has no AutoInstall: its feed is handed the setting now and as it changes, and a version Sparkle
    /// downloaded by itself is Restart to update, named after the restart.
    @Test func thePublicFlavorHandsTheSettingToTheFeed() async throws {
        let env = AppEnvironment.demo()
        env.flavor = PublicFlavorTests.publicFlavor
        #expect(AutoInstall.app(env: env) == nil)
        let privateEnv = AppEnvironment.demo()
        privateEnv.flavor = .private
        #expect(AutoInstall.app(env: privateEnv) != nil)

        let settings = AppSettings.ephemeral()
        let feed = AutomaticFeed()
        let memory = FeedMemory.inMemory()
        let (checker, controller) = AppEnvironment.updates(stamp: BuildStamp(commit: nil, repoPath: nil), settings: settings,
                                                           flavor: PublicFlavorTests.publicFlavor, feed: feed, version: "1.2.0",
                                                           memory: memory)
        #expect(feed.automatic == [false])
        settings.installAutomatically = true
        for _ in 0..<100 where feed.automatic.last != true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(feed.automatic == [false, true])

        checker.feed?.start()
        #expect(checker.installsOnQuit == nil)
        #expect(UpdateText.installAutomatically(feed: true, installsOnQuit: checker.installsOnQuit)
            == "Downloads in the background and installs when you quit.")
        feed.send(.installsOnQuit(version: "1.3.0"))
        #expect(checker.available?.version == "1.3.0" && checker.available?.downloaded == true)
        #expect(controller.restartOffered(for: checker.available) && memory.load() == "1.3.0")
        // W3R-6: Sparkle installs a version it downloaded at quit even once the switch is off (its rule, P1074), so the
        // switch's line says so while one waits, on or off.
        #expect(checker.installsOnQuit == "1.3.0")
        #expect(UpdateText.installAutomatically(feed: true, installsOnQuit: checker.installsOnQuit)
            == "1.3.0 is downloaded and installs when you quit.")
        settings.installAutomatically = false
        for _ in 0..<100 where feed.automatic.last != false { try await Task.sleep(for: .milliseconds(5)) }
        #expect(feed.automatic == [false, true, false] && checker.installsOnQuit == "1.3.0")
        // The private app's line never names one: its install waits for a quiet moment, not a quit.
        #expect(UpdateText.installAutomatically(feed: false, installsOnQuit: "1.3.0")
            == "At a quiet moment: nothing waits on you, no typing for a minute.")
    }
}

/// The feed's updater as the app sees it: records the automatic install it is handed, sends what a test says Sparkle
/// would.
@MainActor
private final class AutomaticFeed: FeedUpdating {
    private(set) var automatic: [Bool] = []
    private var report: (@MainActor (FeedUpdateEvent) -> Void)?

    func start(report: @escaping @MainActor (FeedUpdateEvent) -> Void) { self.report = report }
    func checkNow() -> Bool { true }
    func install() -> Bool { false }
    func relaunch() {}
    func setAutomaticInstall(_ on: Bool) { automatic.append(on) }
    func send(_ event: FeedUpdateEvent) { report?(event) }
}
