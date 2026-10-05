import Foundation
import Testing
@testable import JuiceIslandUI

/// The Update control's progress (P800 to P802): the estimate update-app.sh writes in the run's log, read from logs
/// recorded the way the script writes them; the fill each stage gives and the build's share against the estimate, the
/// percent gone and the fill held past it; the time left in plain words; and a run followed by the controller, whose
/// fill follows the states and the build's time, and which completes and says Updated before the first ask to quit.
@MainActor
@Suite(.serialized)
struct UpdateProgressTests {
    /// A run's log as update-app.sh writes it: an incremental build after an estimate, and a warning of the build's.
    static let updateLog = """
    == update-app: pid 4242, /Applications/Juice Island.app (2026-10-01T12:00:00Z)
    12:00:00 -- pulling
    12:00:02 origin/main is 5d6e7f8
    12:00:02 updating 1a2b3c4 to 5d6e7f8: Give the Update button its progress
    12:00:02 estimate: the last incremental build here took 143 s
    12:00:02 -- building
    /tmp/ji/App/Update/UpdateViews.swift:12:5: warning: variable 'x' was never mutated; consider changing to 'let' constant
    12:02:25 -- verifying
    12:02:27 -- ready
    12:02:29 waiting for the app (pid 4242) to quit

    """

    /// The first build after the updater's checkout was made: no estimate.
    static let firstBuildLog = """
    == update-app: pid 4242, /Applications/Juice Island.app (2026-10-01T12:00:00Z)
    12:00:00 -- pulling
    12:00:01 making the updater's checkout at /tmp/ji/update-build
    12:00:09 origin/main is 5d6e7f8
    12:00:09 updating 1a2b3c4 to 5d6e7f8: Read the estimate: the last clean build here took 9 s
    12:00:09 -- building

    """

    /// A clean build's estimate, and a line that only looks like one.
    static let cleanLog = """
    == update-app: pid 4242, /Applications/Juice Island Dev.app (2026-10-01T23:59:58Z)
    23:59:58 -- pulling
    estimate: the last clean build here took 12 s
    23:59:59 estimate: the last clean build here took 0 s
    23:59:59 estimate: the last warm build here took 30 s
    23:59:59 estimate: the last clean build here took 410 s
    23:59:59 -- building

    """

    @Test func theEstimateComesFromItsOwnLineInTheLog() {
        #expect(BuildEstimate.parse(Self.updateLog) == BuildEstimate(seconds: 143))
        // A commit subject with the same words is no estimate.
        #expect(BuildEstimate.parse(Self.firstBuildLog) == nil)
        // A line with no time, no seconds or another kind is skipped; the first real one counts.
        #expect(BuildEstimate.parse(Self.cleanLog) == BuildEstimate(seconds: 410))
        #expect(BuildEstimate.parse("") == nil)
        #expect(BuildEstimate.parse("12:00:02 estimate: the last incremental build here took 143 s\n12:00:03 estimate: the last clean build here took 9 s\n")
            == BuildEstimate(seconds: 143))
    }

    @Test func theEstimateIsReadFromTheLogFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ji-progress-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(BuildEstimate.read(logAt: url) == nil)
        try Self.updateLog.write(to: url, atomically: true, encoding: .utf8)
        #expect(BuildEstimate.read(logAt: url) == BuildEstimate(seconds: 143))
        // Only the head of the log is read: the line comes before the build's output.
        try (Self.firstBuildLog + String(repeating: "x", count: 70_000) + "\n12:30:00 estimate: the last clean build here took 9 s\n")
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(BuildEstimate.read(logAt: url) == nil)
    }

    @Test func eachStageFillsItsShare() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        func at(_ phase: UpdatePhase, install: Bool = false) -> UpdateProgress {
            UpdateProgress.of(phase: phase, install: install, buildStarted: now, estimate: BuildEstimate(seconds: 100), now: now)
        }
        #expect(at(.idle) == .none && at(.failed(reason: "x")) == .none && at(.updated("3d74159")) == .none)
        #expect(at(.pulling).fraction == UpdateProgress.fetching && at(.pulling).buildPercent == nil)
        #expect(at(.building).fraction == UpdateProgress.fetchEnd && at(.building).buildPercent == 0)
        // The new build's check before the swap.
        #expect(at(.installing).fraction == UpdateProgress.checking)
        // Restart to update: a sliver until the script says what it does, then the prepared app's check; once it has
        // built after all, the new build's check.
        func install(begun: Bool, built: Bool) -> Double {
            UpdateProgress.of(phase: .installing, install: true, begun: begun, buildStarted: built ? now : nil, estimate: nil, now: now).fraction
        }
        #expect(install(begun: false, built: false) == UpdateProgress.fetching)
        #expect(install(begun: true, built: false) == UpdateProgress.installing)
        #expect(install(begun: true, built: true) == UpdateProgress.checking)
        // A build after the prepared app's check sweeps on from that check's share, never from behind it.
        func build(from: Double, after seconds: TimeInterval, estimate: Int?) -> Double {
            UpdateProgress.of(phase: .building, install: true, buildStarted: now, buildFrom: from, estimate: estimate.map(BuildEstimate.init),
                              now: now.addingTimeInterval(seconds)).fraction
        }
        #expect(build(from: UpdateProgress.installing, after: 0, estimate: 100) == UpdateProgress.installing)
        #expect(abs(build(from: UpdateProgress.installing, after: 50, estimate: 100) - 0.76) < 0.0001)
        #expect(build(from: UpdateProgress.installing, after: 50, estimate: nil) == UpdateProgress.installing)
        #expect(build(from: UpdateProgress.fetching, after: 0, estimate: 100) == UpdateProgress.fetchEnd)
        #expect(at(.restarting).fraction == 1 && at(.restartNeeded).fraction == 1)
        // Every stage fills more than the one before it.
        let order = [at(.pulling), at(.building), at(.installing), at(.restarting)].map(\.fraction)
        #expect(order == order.sorted() && Set(order).count == order.count)
    }

    @Test func theBuildFillsByTheEstimateAndHoldsPastIt() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func building(after seconds: TimeInterval, estimate: Int? = 143) -> UpdateProgress {
            UpdateProgress.of(phase: .building, install: false, buildStarted: start, estimate: estimate.map(BuildEstimate.init),
                              now: start.addingTimeInterval(seconds))
        }
        let half = building(after: 71.5)
        #expect(half.buildPercent == 50 && half.secondsLeft == 72 && !half.overran)
        #expect(abs(half.fraction - (UpdateProgress.fetchEnd + (UpdateProgress.buildEnd - UpdateProgress.fetchEnd) / 2)) < 0.0001)
        #expect(building(after: 90).buildPercent == 62 && building(after: 142.9).buildPercent == 99)
        // Past the last such build: no percent, no time left, the fill at the build's end until the build ends.
        let past = building(after: 143)
        #expect(past.overran && past.buildPercent == nil && past.secondsLeft == nil && past.fraction == UpdateProgress.buildEnd)
        #expect(building(after: 600) == past)
        // No estimate (a first build, another kind): no percent; the fill waits at the build's start.
        let unknown = building(after: 90, estimate: nil)
        #expect(unknown == UpdateProgress(fraction: UpdateProgress.fetchEnd))
        // A clock that went back reads as the build's start.
        #expect(building(after: -5).buildPercent == 0)
        // The fill only grows while the estimate holds.
        let fills = stride(from: 0.0, through: 200, by: 5).map { building(after: $0).fraction }
        #expect(fills == fills.sorted())
    }

    @Test func theTimeLeftInPlainWords() {
        func left(_ seconds: Int) -> String? { UpdateText.timeLeft(UpdateProgress(fraction: 0.5, buildPercent: 40, secondsLeft: seconds)) }
        #expect(left(200) == "About 3 min left" && left(90) == "About 2 min left" && left(89) == "About a minute left")
        #expect(left(45) == "About a minute left" && left(44) == "Less than a minute left" && left(1) == "Less than a minute left")
        #expect(UpdateText.timeLeft(UpdateProgress(fraction: UpdateProgress.buildEnd, overran: true)) == "Taking longer than last time")
        #expect(UpdateText.timeLeft(.none) == nil && UpdateText.timeLeft(UpdateProgress(fraction: UpdateProgress.fetchEnd)) == nil)
    }

    /// Past its estimate a build says so (P897): "Still building" in the control; why, when the Mac is busy ("Still
    /// building, the Mac is busy" in the menus and the tooltip, "The Mac is busy" under it in About), and "Taking longer
    /// than last time" when it is not. Inside the estimate the percent, and with none just "Building", as before.
    @Test func aBuildPastItsEstimateSaysItIsStillBuildingAndWhy() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func building(after seconds: TimeInterval, busy: Bool, estimate: Int? = 100) -> UpdateProgress {
            UpdateProgress.of(phase: .building, install: false, buildStarted: start, estimate: estimate.map(BuildEstimate.init), busy: busy,
                              now: start.addingTimeInterval(seconds))
        }
        let busy = building(after: 150, busy: true), calm = building(after: 150, busy: false)
        #expect(busy.overran && busy.busy && busy.fraction == UpdateProgress.buildEnd && !calm.busy)
        #expect(UpdateText.controlWords(.building, progress: busy) == "Still building")
        #expect(UpdateText.controlWords(.building, progress: calm) == "Still building")
        #expect(UpdateText.runWords(.building, progress: busy) == "Still building, the Mac is busy")
        #expect(UpdateText.runWords(.building, progress: calm) == "Still building")
        #expect(UpdateText.detail(.building, progress: busy) == "The Mac is busy")
        #expect(UpdateText.detail(.building, progress: calm) == "Taking longer than last time")
        #expect(UpdateText.menuTitle(available: nil, phase: .building, progress: busy) == "Updating: Still building, the Mac is busy")
        // Inside the estimate, a busy Mac changes nothing: the percent and the time left.
        let inside = building(after: 50, busy: true)
        #expect(!inside.busy && UpdateText.controlWords(.building, progress: inside) == "Building 50%")
        #expect(UpdateText.detail(.building, progress: inside) == "About a minute left")
        #expect(UpdateText.controlWords(.building, progress: building(after: 500, busy: true, estimate: nil)) == "Building")
    }

    /// Waiting for a background prepare (P895): the run's own step, never "Fetching", with the fill held where the build
    /// starts; once the wait is over the checkout moves ("Setting up", the fill where it was), and the build then sweeps
    /// on from there, and past its estimate on a busy Mac says so.
    @Test func aRunThatWaitsForTheBackgroundBuildSaysSo() async throws {
        let box = try Sandbox(script: "status_to pulling; step; status_to waiting; step; status_to checkout; step; "
                              + "print -r -- '12:00:02 estimate: the last incremental build here took 100 s'; status_to building; step; "
                              + "status_to verifying; step; status_to ready; step")
        defer { box.remove() }
        let clock = TestClock()
        let controller = box.controller(clock: clock, finishHold: .seconds(3_600), busy: true) {}
        controller.start()
        var fills = [controller.progress.fraction]
        #expect(await wait { box.log.contains("stub started") })
        #expect(UpdateText.controlWords(controller.phase, progress: controller.progress) == "Fetching")
        box.go()
        #expect(await wait { controller.phase == .waiting })
        fills.append(controller.progress.fraction)
        #expect(controller.progress.fraction == UpdateProgress.fetchEnd)
        #expect(UpdateText.controlWords(controller.phase, progress: controller.progress) == "Waiting for build")
        #expect(UpdateText.menuTitle(available: nil, phase: controller.phase, progress: controller.progress)
            == "Updating: Waiting for the background build")
        #expect(UpdateText.detail(controller.phase, progress: controller.progress) == "Waiting for the background build")
        box.go()
        #expect(await wait { controller.phase == .settingUp })
        fills.append(controller.progress.fraction)
        #expect(UpdateText.controlWords(controller.phase, progress: controller.progress) == "Setting up")
        #expect(UpdateText.menuTitle(available: nil, phase: controller.phase, progress: controller.progress) == "Updating: Setting up")
        #expect(UpdateText.detail(controller.phase, progress: controller.progress) == nil)
        box.go()
        #expect(await wait { controller.progress.buildPercent == 0 })
        fills.append(controller.progress.fraction)
        clock.now += 150
        #expect(await wait { controller.progress.overran })
        #expect(controller.progress.busy && UpdateText.runWords(controller.phase, progress: controller.progress) == "Still building, the Mac is busy")
        fills.append(controller.progress.fraction)
        box.go()
        #expect(await wait { controller.phase == .installing })
        fills.append(controller.progress.fraction)
        #expect(fills == fills.sorted(), "the fill went back: \(fills)")
        box.go()
        #expect(await wait { controller.phase == .restarting })
        box.go()
    }

    // MARK: A run, followed

    /// A stub updater in a scratch bundle: the status as update-app.sh appends it, its output into the log (the app
    /// starts it so), and `step` waiting for the test's go file.
    private struct Sandbox {
        let root: URL
        let paths: UpdateController.Paths
        var bundle: URL { root.appendingPathComponent("Juice Island.app", isDirectory: true) }
        var script: URL { bundle.appendingPathComponent(UpdateController.scriptPath) }
        var log: String { (try? String(contentsOf: paths.logFile, encoding: .utf8)) ?? "" }

        init(script: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-progress-\(UUID().uuidString)", isDirectory: true)
            paths = UpdateController.Paths(statusFile: root.appendingPathComponent("support/update-status"),
                                           logFile: root.appendingPathComponent("logs/update.log"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            let body = "#!/bin/zsh\nset -u\nstatus_to() { print -r -- \"$1\" >> \"$JI_STATUS_FILE\" }\nself=\"$0\" go_file=\"$0.go\"\n"
                + "step() { local end=$(( SECONDS + 90 )); until [[ -e \"$go_file\" ]] || (( SECONDS > end )); do "
                + "[[ -e \"$self\" ]] || exit 0; sleep 0.02; done; rm -f \"$go_file\" }\nprint -r -- \"stub started\"\n" + script + "\n"
            try body.write(to: self.script, atomically: true, encoding: .utf8)
        }

        @MainActor func controller(clock: TestClock, finishHold: Duration, prepared: String? = nil, busy: Bool = false,
                                   quit: @escaping @MainActor () -> Void) -> UpdateController {
            UpdateController(repoPath: root.appendingPathComponent("repo").path, paths: paths, pid: 4242, bundlePath: bundle.path,
                             prepared: prepared, pollInterval: .milliseconds(30), quitRetry: 5, quitPatience: 12, finishHold: finishHold,
                             now: { clock.now }, machineBusy: { busy }, quitSignal: { nil }, quit: quit)
        }

        /// The status file's current state.
        var status: UpdateStatusLine? {
            (try? String(contentsOf: paths.statusFile, encoding: .utf8)).flatMap(UpdateStatusLine.current(in:))
        }

        func go() { FileManager.default.createFile(atPath: script.path + ".go", contents: nil) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor final class TestClock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    private func wait(until done: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !done() { try? await Task.sleep(for: .milliseconds(10)) }
        return done()
    }

    /// The fill follows the states; inside the build, the time on the test's clock against the log's estimate; past
    /// ready the control is whole, and the first ask to quit waits for the hold, which the owner's click or the
    /// script's own signal does not.
    @Test func aRunFillsByItsStatesAndTheBuildsTime() async throws {
        let box = try Sandbox(script: "status_to pulling; step; print -r -- '12:00:02 estimate: the last incremental build here took 100 s'; "
                              + "status_to building; step; status_to verifying; step; status_to ready; step")
        defer { box.remove() }
        var quits = 0
        let clock = TestClock()
        let controller = box.controller(clock: clock, finishHold: .seconds(3_600)) { quits += 1 }
        controller.start()
        #expect(controller.phase == .pulling && controller.progress.fraction == UpdateProgress.fetching)
        #expect(await wait { box.log.contains("stub started") })
        box.go()
        #expect(await wait { controller.phase == .building })
        #expect(await wait { controller.progress.buildPercent == 0 })
        #expect(UpdateText.menuTitle(available: nil, phase: controller.phase, progress: controller.progress) == "Updating: Building 0%")
        clock.now += 63
        #expect(await wait { controller.progress.buildPercent == 63 })
        #expect(UpdateText.timeLeft(controller.progress) == "Less than a minute left")
        clock.now += 37
        #expect(await wait { controller.progress.overran })
        #expect(controller.progress.buildPercent == nil && controller.progress.fraction == UpdateProgress.buildEnd)
        box.go()
        #expect(await wait { controller.phase == .installing })
        #expect(controller.progress.fraction == UpdateProgress.checking)
        box.go()
        #expect(await wait { controller.phase == .restarting })
        #expect(controller.progress.fraction == 1)
        // Held: Updated shows before the app goes.
        #expect(quits == 0)
        // The script's own signal past ready goes at once, and the owner's click too; the held ask has nothing left.
        controller.scriptAskedToQuit()
        #expect(quits == 1)
        controller.restartNow()
        #expect(quits == 2)
        box.go()
    }

    /// A short hold: the first ask comes once it ends, once.
    @Test func theHeldAskComesOnce() async throws {
        let box = try Sandbox(script: "status_to pulling; status_to building; status_to verifying; status_to ready; step")
        defer { box.remove() }
        var quits = 0
        let controller = box.controller(clock: TestClock(), finishHold: .milliseconds(50)) { quits += 1 }
        controller.start()
        #expect(await wait { controller.phase == .restarting })
        #expect(await wait { quits == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(quits == 1)
        box.go()
    }

    /// A build with no estimate in the log: "Building", the fill at the build's start, nothing about the time.
    @Test func aBuildWithNoEstimateSaysNoPercent() async throws {
        let box = try Sandbox(script: "status_to pulling; status_to building; step")
        defer { box.remove() }
        let clock = TestClock()
        let controller = box.controller(clock: clock, finishHold: .zero) {}
        controller.start()
        #expect(await wait { controller.phase == .building })
        clock.now += 60
        try? await Task.sleep(for: .milliseconds(150))
        #expect(controller.progress == UpdateProgress(fraction: UpdateProgress.fetchEnd))
        #expect(UpdateText.runWords(controller.phase, progress: controller.progress) == "Building")
        #expect(UpdateText.timeLeft(controller.progress) == nil)
        box.go()
    }

    /// Restart to update that builds after all (P800): update-app.sh updates the usual way when the prepared app is gone
    /// before the fetch, and builds it again when it is gone from the build stage or fails its check. The fill starts
    /// at the fetching sliver until the script says what it does, takes the install's share only while no build ran,
    /// and a build after that share sweeps on from it: it never goes back.
    @Test func aRestartToUpdateThatBuildsAfterAllNeverGoesBack() async throws {
        let estimate = "print -r -- '12:00:02 estimate: the last incremental build here took 100 s'"
        // The prepared app gone before the fetch: pulling, building, verifying, ready.
        let fetched = try await installFills("step; status_to pulling; step; \(estimate); status_to building; step; "
                                             + "status_to verifying; step; status_to ready; step",
                                             states: [.pulling, .building, .verifying, .ready])
        #expect(fetched.first == UpdateProgress.fetching)
        #expect(fetched == fetched.sorted(), "the fill went back: \(fetched)")
        #expect(fetched.dropLast().last == UpdateProgress.checking)
        // The prepared app failing its check: verifying, then building, verifying, ready.
        let rebuilt = try await installFills("step; status_to verifying; step; \(estimate); status_to building; step; "
                                             + "status_to verifying; step; status_to ready; step",
                                             states: [.verifying, .building, .verifying, .ready])
        #expect(rebuilt.first == UpdateProgress.fetching && rebuilt.dropFirst().first == UpdateProgress.installing)
        #expect(rebuilt == rebuilt.sorted(), "the fill went back: \(rebuilt)")
        #expect(rebuilt.dropLast().last == UpdateProgress.checking)
        // The prepared app installed: the sliver, the install's share, whole.
        let installed = try await installFills("step; status_to verifying; step; status_to ready; step", states: [.verifying, .ready])
        #expect(installed == [UpdateProgress.fetching, UpdateProgress.installing, 1])
    }

    /// The fills a Restart to update shows: at the click, then at each of `states` the stub writes in turn, and in a
    /// build at 0 % and at 90 % of the estimate.
    private func installFills(_ script: String, states: [UpdateStatusLine]) async throws -> [Double] {
        let box = try Sandbox(script: script)
        defer { box.remove() }
        let clock = TestClock()
        let controller = box.controller(clock: clock, finishHold: .seconds(3_600), prepared: String(repeating: "5", count: 40)) {}
        controller.installPrepared()
        var fills = [controller.progress.fraction]
        #expect(await wait { box.log.contains("stub started") })
        for state in states {
            box.go()
            #expect(await wait { box.status == state })
            // Four polls, so the controller has read it.
            try? await Task.sleep(for: .milliseconds(150))
            if state == .building {
                #expect(await wait { controller.progress.buildPercent == 0 })
                fills.append(controller.progress.fraction)
                clock.now += 90
                #expect(await wait { controller.progress.buildPercent == 90 })
            }
            fills.append(controller.progress.fraction)
        }
        box.go()
        return fills
    }
}
