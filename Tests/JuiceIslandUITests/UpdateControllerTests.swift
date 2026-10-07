import Foundation
import Testing
@testable import JuiceIslandUI

/// The controller over stub updaters in a temporary app bundle (`Contents/Resources/update-app.sh`, where build-app.sh
/// puts the real one) that write the status file the way the real script does (one state appended per line,
/// `failed:<reason>`): it runs the bundle's copy with the pid, the bundle path and the repository, follows
/// the file, quits on ready, asks again and then asks the owner while the script waits (P98), keeps the app on a
/// failure with the log's last lines, ends quietly when already up to date, never trusts a stale status, and says
/// "Updated to <commit>" once after the relaunch. Nothing is built, pulled or installed.
@MainActor
@Suite(.serialized)
struct UpdateControllerTests {
    /// A scratch app bundle holding only the stub updater, a repository folder, and the status file and log paths.
    private struct Sandbox {
        let root: URL
        let paths: UpdateController.Paths
        var repo: URL { root.appendingPathComponent("repo", isDirectory: true) }
        var bundle: URL { root.appendingPathComponent("Juice Island.app", isDirectory: true) }
        var script: URL { bundle.appendingPathComponent(UpdateController.scriptPath) }
        var log: String { (try? String(contentsOf: paths.logFile, encoding: .utf8)) ?? "" }

        init(script: String?) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-update-\(UUID().uuidString)", isDirectory: true)
            paths = UpdateController.Paths(statusFile: root.appendingPathComponent("support/update-status"),
                                           logFile: root.appendingPathComponent("logs/update.log"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("repo"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            if let script {
                // status_to appends a state as update-app.sh does; step waits for the test's go file however long the
                // test takes to send it, so no step depends on timing: a step that gave up after 90 s ran on to ready
                // unseen while a full run held the main actor for minutes, and the app quit before its time (P1253).
                // It ends the stub once the test removed the sandbox, or once the test process is gone.
                let body = "#!/bin/zsh\nset -u\nstatus_to() { print -r -- \"$1\" >> \"$JI_STATUS_FILE\" }\n"
                    + "self=\"$0\" go_file=\"$0.go\" runner=$PPID\n"
                    + "step() { until [[ -e \"$go_file\" ]]; do [[ -e \"$self\" ]] && kill -0 $runner 2>/dev/null || exit 0; "
                    + "sleep 0.02; done; rm -f \"$go_file\" }\n"
                    + "print -r -- \"stub args: $*\"\nprint -r -- \"stub cwd: $PWD\"\n"
                    + "print -r -- \"stub stage: ${JI_UPDATE_STAGE-none}\"\n" + script + "\n"
                try body.write(to: self.script, atomically: true, encoding: .utf8)
            }
        }

        /// `clock` stands in for the time past ready (the polls read it); without one the time is real.
        /// `finishHold`: how long the control says Updated before the first ask to quit; none unless a test says.
        @MainActor func controller(build: String? = nil, clock: TestClock? = nil, updatedLife: Duration = .seconds(600),
                                   pollInterval: Duration = .milliseconds(30), bundlePath: String? = nil, finishHold: Duration = .zero,
                                   quit: @escaping @MainActor () -> Void = {}, recheck: @escaping @MainActor () -> Void = {}) -> UpdateController {
            UpdateController(repoPath: repo.path, build: build, paths: paths, pid: 4242, bundlePath: bundlePath ?? bundle.path,
                             pollInterval: pollInterval, quitRetry: 5, quitPatience: 12, updatedLife: updatedLife, finishHold: finishHold,
                             now: { clock?.now ?? Date() }, quitSignal: { nil }, quit: quit, recheck: recheck)
        }

        /// Writes the status file as a run left it, `age` seconds ago.
        func writeStatus(_ text: String, age: TimeInterval = 0) throws {
            try FileManager.default.createDirectory(at: paths.statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: paths.statusFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: paths.statusFile.path)
        }

        var statusExists: Bool { FileManager.default.fileExists(atPath: paths.statusFile.path) }

        /// Lets the stub past its next `step`.
        func go() { FileManager.default.createFile(atPath: script.path + ".go", contents: nil) }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @MainActor final class TestClock {
        var now = Date(timeIntervalSince1970: 1_790_000_000)
    }

    /// How many seconds' worth of looks a wait on the zsh stub may take (`Looks`): it answers in well under a second,
    /// but a machine building several branches at once has made it take over 10 s. The looks are counted, not the clock:
    /// a whole parallel run has held the main actor, and with it every look and the controller's polls, for minutes, so a
    /// wall-clock patience ran out with a handful of looks taken (P1253). A wait ends as soon as its condition holds.
    nonisolated static let patience: TimeInterval = 60

    /// Samples `phase` until `done` holds or `patience`'s looks find it false; returns every distinct phase seen.
    private func follow(_ controller: UpdateController, until done: () -> Bool) async -> [UpdatePhase] {
        var seen: [UpdatePhase] = [controller.phase]
        _ = await Looks.until(Self.patience) {
            if seen.last != controller.phase { seen.append(controller.phase) }
            return done()
        }
        return seen
    }

    /// Waits (`patience`'s looks at most) until `done` holds.
    private func wait(until done: () -> Bool) async -> Bool {
        await Looks.until(Self.patience, done)
    }

    /// The time past ready is the test's clock (P293): with the real one, a main actor held 5 s between the ask and the
    /// look at it (a loaded full run) let the second ask (`quitRetry`) in first, and the count read 2.
    @Test func readyQuitsTheAppAfterEachStepShows() async throws {
        let box = try Sandbox(script: "status_to pulling; step; status_to building; step; status_to verifying; step; status_to ready; step")
        defer { box.remove() }
        var quits = 0
        let controller = box.controller(clock: TestClock()) { quits += 1 }
        controller.start()
        #expect(controller.phase == .pulling)
        #expect(await wait { box.log.contains("stub args:") })
        box.go()
        #expect(await wait { controller.phase == .building })
        #expect(quits == 0)
        box.go()
        #expect(await wait { controller.phase == .installing })
        #expect(quits == 0)
        box.go()
        #expect(await wait { quits > 0 })
        #expect(quits == 1)
        #expect(controller.phase == .restarting)
        // The bundle's own updater, with the repository, from /, and never as the build stage.
        #expect(box.log.contains("stub args: 4242 \(box.bundle.path) \(box.repo.path)\n"))
        #expect(box.log.contains("stub cwd: /\n") && box.log.contains("stub stage: none\n"))
    }

    /// P98: past ready the app asks to quit at once and again at `quitRetry`, asks the owner at `quitPatience`, and
    /// Restart Now asks again; the script's end while the app is still here is a failure, and no ask follows it.
    @Test func pastReadyItAsksAgainThenAsksTheOwner() async throws {
        let box = try Sandbox(script: "status_to pulling; status_to building; status_to verifying; status_to ready; step; exit 0")
        defer { box.remove() }
        var quits = 0
        let clock = TestClock()
        let controller = box.controller(clock: clock) { quits += 1 }
        controller.start()
        #expect(await wait { quits == 1 })
        #expect(controller.phase == .restarting)
        clock.now += 4.9
        controller.poll()
        #expect(quits == 1 && controller.phase == .restarting)
        clock.now += 0.1
        controller.poll()
        #expect(quits == 2 && controller.phase == .restarting)
        clock.now += 6.9
        controller.poll()
        #expect(quits == 2 && controller.phase == .restarting)
        clock.now += 0.1
        controller.poll()
        #expect(quits == 2 && controller.phase == .restartNeeded)
        #expect(controller.phase.text == "Restart to update" && controller.phase.isRunning)
        controller.restartNow()
        #expect(quits == 3)
        controller.act()
        #expect(quits == 4)
        clock.now += 600
        controller.poll()
        #expect(quits == 4 && controller.phase == .restartNeeded)
        // The script stopping while this app still runs: it swapped nothing.
        box.go()
        _ = await follow(controller) { !controller.phase.isRunning }
        #expect(controller.phase.text == "Update failed: update-app.sh stopped (exit 0)")
        controller.restartNow()
        #expect(quits == 4)
    }

    /// The script's quit timeout (or any failure) past ready ends the wait with its reason, and the app stays.
    @Test func aFailureWhileWaitingToQuitEndsTheWait() async throws {
        let box = try Sandbox(script: "status_to ready; step; status_to 'failed:the app did not quit within 10 min'; exit 1")
        defer { box.remove() }
        var quits = 0
        let clock = TestClock()
        let controller = box.controller(clock: clock) { quits += 1 }
        controller.start()
        #expect(await wait { quits == 1 })
        box.go()
        _ = await follow(controller) { !controller.phase.isRunning }
        #expect(controller.phase.text == "Update failed: the app did not quit within 10 min")
        clock.now += 60
        controller.poll()
        #expect(quits == 1)
    }

    /// The script's signal quits only while this app's own script runs and says ready; before ready, with no run, or
    /// after the run, it does nothing.
    @Test func theScriptsSignalQuitsOnlyWhileItsRunSaysReady() async throws {
        let box = try Sandbox(script: "status_to building; step; status_to ready; step; exit 0")
        defer { box.remove() }
        try box.writeStatus("ready\n")
        var quits = 0
        // The test's clock: no second ask of the controller's own comes between the ones counted here (P293).
        let controller = box.controller(clock: TestClock()) { quits += 1 }
        controller.scriptAskedToQuit()
        #expect(quits == 0 && controller.phase == .idle)
        controller.start()
        #expect(await wait { controller.phase == .building })
        controller.scriptAskedToQuit()
        #expect(quits == 0)
        box.go()
        #expect(await wait { quits == 1 })
        controller.scriptAskedToQuit()
        #expect(quits == 2 && controller.phase == .restarting)
        box.go()
        _ = await follow(controller) { !controller.phase.isRunning }
        controller.scriptAskedToQuit()
        #expect(quits == 2)
    }

    @Test func aFailureKeepsTheAppAndSaysWhy() async throws {
        let box = try Sandbox(script: "status_to building; print 'step one'; print 'error: the repository is not on main'; "
                              + "status_to 'failed:Not on main'; exit 1")
        defer { box.remove() }
        var quits = 0
        let controller = box.controller { quits += 1 }
        controller.start()
        _ = await follow(controller) { if case .failed = controller.phase { true } else { false } }
        guard case let .failed(reason) = controller.phase else { Issue.record("no failure: \(controller.phase)"); return }
        #expect(reason == "Not on main")
        #expect(controller.phase.text == "Update failed: Not on main")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(quits == 0)
    }

    @Test func aStaleReadyIsClearedBeforeTheScriptStarts() async throws {
        let box = try Sandbox(script: "step; status_to 'failed:stopped by the test'")
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.paths.statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "ready\n".write(to: box.paths.statusFile, atomically: true, encoding: .utf8)
        var quits = 0
        let controller = box.controller { quits += 1 }
        controller.start()
        #expect(!FileManager.default.fileExists(atPath: box.paths.statusFile.path))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(quits == 0)
        #expect(controller.phase == .pulling)
        box.go()
        _ = await follow(controller) { !controller.phase.isRunning }
        #expect(controller.phase.text == "Update failed: stopped by the test")
        #expect(quits == 0)
    }

    @Test func doneBeforeReadyEndsQuietlyAndChecksAgain() async throws {
        let box = try Sandbox(script: "status_to pulling; status_to done; exit 0")
        defer { box.remove() }
        var quits = 0, rechecks = 0
        let controller = box.controller(quit: { quits += 1 }, recheck: { rechecks += 1 })
        controller.start()
        let seen = await follow(controller) { !controller.phase.isRunning }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(seen == [.pulling, .idle])
        #expect(controller.phase == .idle)
        #expect(quits == 0 && rechecks == 1)
    }

    /// A script that dies past ready (killed, or ended without its failed line) before the polls saw ready: the app
    /// never quits for it, since no script is left to swap the bundle or open the new build.
    @Test func aScriptGonePastReadyNeverQuitsTheApp() async throws {
        let box = try Sandbox(script: "status_to pulling; status_to building; status_to verifying; status_to ready; exit 9")
        defer { box.remove() }
        var quits = 0
        let controller = box.controller(pollInterval: .seconds(3_600)) { quits += 1 }
        controller.start()
        _ = await follow(controller) { !controller.phase.isRunning }
        #expect(controller.phase.text == "Update failed: update-app.sh stopped (exit 9)")
        controller.poll()
        controller.restartNow()
        controller.scriptAskedToQuit()
        #expect(quits == 0)
    }

    @Test func aScriptThatStopsWithoutAStatusIsAFailure() async throws {
        let box = try Sandbox(script: "status_to building; exit 3")
        defer { box.remove() }
        let controller = box.controller()
        controller.start()
        _ = await follow(controller) { !controller.phase.isRunning }
        #expect(controller.phase.text == "Update failed: update-app.sh stopped (exit 3)")
    }

    /// A build without the bundled updater never runs a checkout's copy instead.
    @Test func aMissingScriptOrRepositoryFailsWithoutStarting() throws {
        let box = try Sandbox(script: nil)
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.repo.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "#!/bin/zsh\nprint -r -- 'the checkout ran' >> \"$JI_STATUS_FILE\"\n"
            .write(to: box.repo.appendingPathComponent("scripts/update-app.sh"), atomically: true, encoding: .utf8)
        let controller = box.controller()
        controller.start()
        #expect(controller.phase.text == "Update failed: This build carries no update-app.sh")
        #expect(!box.statusExists)
        let unknown = UpdateController(repoPath: nil, paths: box.paths)
        unknown.start()
        #expect(unknown.phase.text == "Update failed: Unknown build: no repository to update from")
    }

    /// The build the script opened says "Updated to <commit>" once: the status file goes with it. The script writes
    /// done once the new build runs, so restarting counts too; done right after pulling swapped nothing.
    @Test func theNewBuildSaysUpdatedOnce() async throws {
        let box = try Sandbox(script: nil)
        defer { box.remove() }
        let swapped = "pulling\nbuilding\nverifying\nready\ninstalling\nrestarting\n"
        for text in [swapped, swapped + "done\n"] {
            try box.writeStatus(text)
            let relaunched = box.controller(build: "0d92e4b")
            relaunched.restoreAfterLaunch()
            #expect(relaunched.phase == .updated("0d92e4b") && relaunched.phase.text == "Updated to 0d92e4b")
            #expect(!relaunched.phase.isRunning && !box.statusExists)
            let again = box.controller(build: "0d92e4b")
            again.restoreAfterLaunch()
            #expect(again.phase == .idle)
        }
        for (text, age) in [("pulling\ndone\n", 0.0), (swapped + "done\n", 11 * 60.0), ("pulling\nbuilding\nverifying\nready\n", 0)] {
            try box.writeStatus(text, age: age)
            let other = box.controller(build: "0d92e4b")
            other.restoreAfterLaunch()
            #expect(other.phase == .idle, "\(text)")
        }
        try box.writeStatus(swapped)
        let unstamped = box.controller()
        unstamped.restoreAfterLaunch()
        #expect(unstamped.phase == .idle)

        try box.writeStatus(swapped)
        let shown = box.controller(build: "0d92e4b", updatedLife: .milliseconds(50))
        shown.restoreAfterLaunch()
        #expect(shown.phase == .updated("0d92e4b"))
        #expect(await wait { shown.phase == .idle })
        try box.writeStatus(swapped)
        let cleared = box.controller(build: "0d92e4b")
        cleared.restoreAfterLaunch()
        cleared.clearNotice()
        #expect(cleared.phase == .idle)
    }

    /// A dev build beside the release one shares the status file: a run that updated another bundle shows nothing in
    /// this build and stays for the build it opened; one that names this bundle, or no bundle (an older script), shows.
    @Test func anotherBundlesRunIsNotThisBuildsToShowOrClear() throws {
        let box = try Sandbox(script: nil)
        defer { box.remove() }
        let swapped = "pulling\nbuilding\nverifying\nready\ninstalling\nrestarting\ndone\n"
        let failed = "pulling\nbuilding\nfailed:the build failed\n"
        for text in [swapped, failed] {
            try box.writeStatus("app:/Applications/Juice Island.app\n" + text)
            let other = box.controller(build: "0d92e4b")
            other.restoreAfterLaunch()
            #expect(other.phase == .idle && box.statusExists, "\(text)")
        }
        try box.writeStatus("app:/tmp/ji-fake/../ji-fake/Juice Island.app\n" + swapped)
        let this = box.controller(build: "0d92e4b", bundlePath: "/tmp/ji-fake/Juice Island.app")
        this.restoreAfterLaunch()
        #expect(this.phase == .updated("0d92e4b") && !box.statusExists)
        try box.writeStatus("app:/tmp/ji-fake/Juice Island.app\n" + failed)
        let failure = box.controller(build: "0d92e4b", bundlePath: "/tmp/ji-fake/Juice Island.app")
        failure.restoreAfterLaunch()
        #expect(failure.phase.text == "Update failed: the build failed")
    }

    @Test func aRecentFailureShowsAfterRelaunchAndAnOldOneDoesNot() throws {
        let box = try Sandbox(script: nil)
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.paths.statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "pulling\nbuilding\nverifying\nready\ninstalling\nrestarting\nfailed:could not open the new app; the previous app is back\n"
            .write(to: box.paths.statusFile, atomically: true, encoding: .utf8)
        let recent = box.controller()
        recent.restoreAfterLaunch()
        #expect(recent.phase.text == "Update failed: could not open the new app; the previous app is back")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: box.paths.statusFile.path)
        let old = box.controller()
        old.restoreAfterLaunch()
        #expect(old.phase == .idle)
        try "pulling\nbuilding\nverifying\nready\ninstalling\nrestarting\ndone\n".write(to: box.paths.statusFile, atomically: true, encoding: .utf8)
        let done = box.controller()
        done.restoreAfterLaunch()
        #expect(done.phase == .idle)
    }

    // MARK: Protocol and words

    @Test func statusLinesParse() {
        let words = ["pulling", "waiting", "checkout", "building", "verifying", "ready", "installing", "restarting", "done"]
        #expect(words.compactMap { UpdateStatusLine(line: $0) }
            == [.pulling, .waiting, .checkout, .building, .verifying, .ready, .installing, .restarting, .done])
        #expect(UpdateStatusLine(line: "failed:the repo is on side, not main") == .failed("the repo is on side, not main"))
        #expect(UpdateStatusLine(line: "failed:main and origin/main have diverged; pull by hand") == .failed("main and origin/main have diverged; pull by hand"))
        #expect(UpdateStatusLine(line: "failed:") == .failed("see the log"))
        #expect(UpdateStatusLine(line: "failed") == .failed("see the log"))
        #expect(UpdateStatusLine(line: "readyish") == nil)
        // The bundle's line is no state; it is read on its own.
        #expect(UpdateStatusLine(line: "app:/Applications/Juice Island.app") == nil)
        #expect(UpdateStatusLine.current(in: "app:/Applications/Juice Island.app\n") == nil)
        #expect(UpdateStatusLine.current(in: "app:/Applications/Juice Island.app\npulling\n") == .pulling)
        #expect(UpdateStatusLine.app(in: "app:/Applications/Juice Island.app\npulling\n") == "/Applications/Juice Island.app")
        #expect(UpdateStatusLine.app(in: "pulling\ndone\n") == nil)
        #expect(UpdateStatusLine(line: "") == nil)
        // The last complete line counts; a line still being written does not.
        #expect(UpdateStatusLine.current(in: "pulling\nbuilding\n") == .building)
        #expect(UpdateStatusLine.current(in: "pulling\nbuilding\nverif") == .building)
        #expect(UpdateStatusLine.current(in: "pulling\ndone\n") == .done)
        #expect(UpdateStatusLine.current(in: "failed:the repo has uncommitted changes\n") == .failed("the repo has uncommitted changes"))
        // A rollback whose app did not reopen adds a second failed line, which is the one shown on the next launch.
        #expect(UpdateStatusLine.current(in: "restarting\nfailed:x; the previous app is back\nfailed:x; the previous app is back, but it did not reopen: open Juice Island from /Applications\n")
            == .failed("x; the previous app is back, but it did not reopen: open Juice Island from /Applications"))
        #expect(UpdateStatusLine.current(in: "ready") == nil)
        #expect(UpdateStatusLine.current(in: "") == nil)
    }

    @Test func phasesMapToTheirWords() {
        #expect(UpdatePhase.idle.text == nil)
        #expect([UpdatePhase.pulling, .waiting, .settingUp, .building, .installing, .restarting, .restartNeeded].map(\.text)
            == ["Fetching…", "Waiting for the background build…", "Setting up…", "Building…", "Installing…", "Restarting…",
                "Restart to update"])
        #expect(UpdatePhase.waiting.isRunning && UpdatePhase.settingUp.isRunning)
        #expect(UpdatePhase.updated("0d92e4b").text == "Updated to 0d92e4b")
        #expect(!UpdatePhase.failed(reason: "x").isRunning && UpdatePhase.installing.isRunning)
        #expect(UpdatePhase.restartNeeded.isRunning && !UpdatePhase.updated("0d92e4b").isRunning)
        let info = UpdateInfo(newer: 3, subjects: [])
        let failed = UpdatePhase.failed(reason: "x")
        #expect(UpdateText.menuTitle(available: info, phase: .idle) == "Update Juice Island (3 changes)")
        #expect(UpdateText.menuTitle(available: info, phase: .building) == "Updating: Building")
        #expect(UpdateText.menuTitle(available: info, phase: .building, progress: UpdateProgress(fraction: 0.5, buildPercent: 63))
            == "Updating: Building 63%")
        #expect(UpdateText.menuTitle(available: info, phase: .pulling) == "Updating: Fetching")
        #expect(UpdateText.menuTitle(available: info, phase: .waiting) == "Updating: Waiting for the background build")
        #expect(UpdateText.menuTitle(available: info, phase: .settingUp) == "Updating: Setting up")
        #expect(UpdateText.menuTitle(available: info, phase: .restartNeeded) == "Restart to Update")
        #expect(UpdateText.menuTitle(available: nil, phase: .updated("0d92e4b")) == "Updated to 0d92e4b")
        #expect(UpdateText.menuTitle(available: info, phase: .updated("0d92e4b")) == "Update Juice Island (3 changes)")
        #expect(UpdateText.menuTitle(available: nil, phase: .idle) == nil)
        // The line acts when it starts an update (a retry after a failure too) or restarts for one.
        #expect(UpdateText.menuEnabled(available: info, phase: .idle) && UpdateText.menuEnabled(available: info, phase: failed))
        #expect(UpdateText.menuEnabled(available: info, phase: .updated("0d92e4b")) && UpdateText.menuEnabled(available: nil, phase: .restartNeeded))
        #expect(!UpdateText.menuEnabled(available: info, phase: .building) && !UpdateText.menuEnabled(available: nil, phase: .updated("0d92e4b")))
        #expect(UpdateText.toolbarHelp(info) == "3 changes · click to update")
        #expect(UpdateText.changes(1) == "1 change")
    }

    @Test func theScriptGetsTheStatusAndLogPathsAndHomebrewOnPath() {
        let paths = UpdateController.Paths(statusFile: URL(fileURLWithPath: "/tmp/s/update-status"), logFile: URL(fileURLWithPath: "/tmp/l/update.log"))
        let environment = UpdateController.environment(paths: paths, base: ["PATH": "/usr/bin:/bin", "HOME": "/tmp/h", "JI_APP_QUIT_SIGNAL": "TERM",
                                                                           "JI_UPDATE_STAGE": "build", "JI_UPDATE_CHECKOUT": "/tmp/x/update-build"])
        // The script's own hand-over and its tests' overrides never come from the app.
        #expect(environment.keys.allSatisfy { !$0.hasPrefix("JI_UPDATE_") })
        // No quit signal unless this app handles one, whatever it inherited.
        #expect(environment["JI_APP_QUIT_SIGNAL"] == nil)
        #expect(UpdateController.environment(paths: paths, quitSignal: "USR2", base: [:])["JI_APP_QUIT_SIGNAL"] == "USR2")
        #expect(environment["JI_STATUS_FILE"] == "/tmp/s/update-status")
        #expect(environment["JI_LOG_FILE"] == "/tmp/l/update.log")
        #expect(environment["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        #expect(environment["HOME"] == "/tmp/h")
        let standard = UpdateController.Paths.standard
        #expect(standard.statusFile.path.hasSuffix("/Library/Application Support/Juice Island/update-status"))
        #expect(standard.logFile.path.hasSuffix("/Library/Logs/Juice Island/update.log"))
    }
}
