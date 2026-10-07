import Foundation
import Testing
@testable import JuiceIslandUI

/// Updates prepared ahead (P710 to P715), over a stub updater in a temporary app bundle that answers each mode the way
/// update-app.sh does: a prepare writes its own status file (`prepared:<commit>` or `failed:<reason>`, and
/// `failed:stopped` when it is stopped), an install and an update write the update's. A check's result starts a
/// prepare only with the setting on, on power, for a commit that is not this build's; Restart to update installs what
/// it left while origin/main is still that commit; an Update while a prepare runs starts at once and leaves the
/// prepare to the updater (P891); a quit stops it; a failed prepare for the same commit is not tried again only when the
/// failure was the commit's own. Nothing is built.
@MainActor
@Suite(.serialized)
struct UpdatePrepareTests {
    static let build = String(repeating: "a", count: 40)
    static let tip = String(repeating: "c", count: 40)
    static let newer = String(repeating: "d", count: 40)
    nonisolated static let patience: TimeInterval = 60

    /// A scratch bundle with the stub updater; `calls` is what the stub saw, a line per run.
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
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ji-prepare-\(UUID().uuidString)", isDirectory: true)
            paths = UpdateController.Paths(statusFile: root.appendingPathComponent("support/update-status"),
                                           logFile: root.appendingPathComponent("logs/update.log"))
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
            // A step waits for its go file however long the test takes (a step that gave up after 90 s ran on unseen
            // while a full run held the main actor, P1253), until the sandbox or the test process is gone.
            // A prepare ends with the line in <script>.result, after <script>.prepare-go when <script>.hold is there;
            // TERM ends it as stopped. With <script>.busy it finds the update lock taken: it writes nothing of its own and exits,
            // while the run that holds the lock (another bundle's) writes the lines in that file. An install and an
            // update wait at ready (or building) for <script>.go.
            let body = """
            #!/bin/zsh
            set -u
            self="$0"
            print -r -- "mode:${JI_RUN_MODE:-update} status:${JI_STATUS_FILE##*/} log:${JI_LOG_FILE##*/} signal:${JI_APP_QUIT_SIGNAL:-none}" >> "$self.calls"
            status_to() { print -r -- "$1" >> "$JI_STATUS_FILE" }
            runner=$PPID
            step() { local go="$self.${1:-go}"
              until [[ -e "$go" ]]; do [[ -e "$self" ]] && kill -0 $runner 2>/dev/null || exit 0; sleep 0.02; done; rm -f "$go" }
            case ${JI_RUN_MODE:-update} in
              (prepare)
                [[ ! -e "$self.busy" ]] || { cat "$self.busy" >> "$JI_STATUS_FILE"; exit 1 }
                trap 'status_to "failed:stopped"; print -r -- "prepare stopped" >> "$self.calls"; exit 1' TERM
                status_to "app:$2"; status_to pulling; status_to building
                [[ ! -e "$self.hold" ]] || step prepare-go
                status_to "$(<"$self.result")"
                exit 0 ;;
              (install) status_to "app:$2"; status_to verifying; status_to ready; step; exit 0 ;;
              (*) status_to "app:$2"; status_to pulling; status_to building; step; exit 0 ;;
            esac
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
        }

        func result(_ line: String) throws { try line.write(toFile: script.path + ".result", atomically: true, encoding: .utf8) }
        func hold() { FileManager.default.createFile(atPath: script.path + ".hold", contents: nil) }
        func busy(_ lines: String?) throws {
            let path = script.path + ".busy"
            if let lines { try lines.write(toFile: path, atomically: true, encoding: .utf8) } else { try? FileManager.default.removeItem(atPath: path) }
        }
        func go() { FileManager.default.createFile(atPath: script.path + ".go", contents: nil) }
        /// Lets a held prepare end.
        func goPrepare() { FileManager.default.createFile(atPath: script.path + ".prepare-go", contents: nil) }
        func remove() { try? FileManager.default.removeItem(at: root) }

        func writePrepare(_ text: String) throws {
            try FileManager.default.createDirectory(at: paths.prepareStatusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: paths.prepareStatusFile, atomically: true, encoding: .utf8)
        }
    }

    /// The app's surroundings, as the tests set them.
    @MainActor final class World {
        var enabled = true
        var power = true
        var latest: UpdateInfo? = UpdateInfo(newer: 2, subjects: ["Two", "One"], tip: UpdatePrepareTests.tip)

        var context: UpdateController.Context {
            UpdateController.Context(prepareEnabled: { [unowned self] in self.enabled }, powerAllows: { [unowned self] in self.power },
                                     latest: { [unowned self] in self.latest })
        }
    }

    /// No hold at ready (P803 has its own tests): a first look at ready after a busy main actor held the wait past its
    /// deadline still quits, as before the hold (P293).
    private func controller(_ box: Sandbox, _ world: World, quit: @escaping @MainActor () -> Void = {}) -> UpdateController {
        UpdateController(repoPath: box.repo.path, build: "aaaaaaa", commit: Self.build, paths: box.paths, pid: 4242,
                         bundlePath: box.bundle.path, pollInterval: .milliseconds(30), finishHold: .zero, now: { Date() },
                         quitSignal: { "USR2" }, quit: quit, context: world.context)
    }

    /// Waits until `done` holds, for `patience`'s worth of looks at most (`Looks`): counted looks, not the clock, as a
    /// full run has held the main actor for minutes (P1253).
    private func wait(until done: () -> Bool) async -> Bool {
        await Looks.until(Self.patience, done)
    }

    /// A check that finds origin/main ahead prepares it, at the prepare's own files and with no quit signal; its
    /// commit turns Update into Restart to update, which installs it as an install run that quits at ready.
    @Test func aCheckThatFindsNewCommitsPreparesThemAndRestartInstallsThem() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.result("prepared:\(Self.tip)")
        let world = World()
        var quits = 0
        let controller = controller(box, world) { quits += 1 }
        controller.considerPreparing()
        #expect(controller.preparing)
        #expect(await wait { !controller.preparing })
        #expect(controller.prepared == Self.tip)
        #expect(box.calls == ["mode:prepare status:update-prepare log:prepare.log signal:none"])
        #expect(controller.restartOffered(for: world.latest))
        #expect(UpdateText.menuTitle(available: world.latest, phase: controller.phase, prepared: true) == "Restart to Update (2 changes)")
        // The same commit again: nothing to do.
        controller.considerPreparing()
        #expect(!controller.preparing && box.calls.count == 1)

        controller.act()
        #expect(controller.phase == .installing)
        #expect(controller.prepared == nil && !controller.restartOffered(for: world.latest))
        #expect(!FileManager.default.fileExists(atPath: box.paths.prepareStatusFile.path))
        // The test reads the status itself: a full run's busy main actor has held the controller's own polls past the
        // wait (P293).
        #expect(await wait { controller.poll(); return quits > 0 })
        #expect(controller.phase == .restarting)
        #expect(box.calls.last == "mode:install status:update-status log:update.log signal:USR2")
        box.go()
    }

    /// Nothing prepares with the setting off, on battery or in Low Power Mode, with no update offered, for this
    /// build's own commit, or while an update runs.
    @Test func nothingPreparesUnlessEveryConditionHolds() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.result("prepared:\(Self.tip)")
        let world = World()
        let controller = controller(box, world)
        world.enabled = false
        controller.considerPreparing()
        world.enabled = true
        world.power = false
        controller.considerPreparing()
        world.power = true
        world.latest = nil
        controller.considerPreparing()
        world.latest = UpdateInfo(newer: 0, subjects: [], dirty: true, tip: Self.build)
        controller.considerPreparing()
        world.latest = UpdateInfo(newer: 1, subjects: ["One"])
        controller.considerPreparing()
        #expect(!controller.preparing && box.calls.isEmpty)

        world.latest = UpdateInfo(newer: 1, subjects: ["One"], tip: Self.tip)
        controller.start()
        #expect(controller.phase == .pulling)
        controller.considerPreparing()
        #expect(!controller.preparing && box.calls.allSatisfy { $0.hasPrefix("mode:update") })
        box.go()
    }

    /// An Update while a prepare runs starts at once (P891): the app neither stops the prepare nor waits for it (the
    /// updater takes it over, or stops it within seconds), and the prepare's status file stays for the updater to
    /// follow. A quit or the setting turned off while the update runs leaves the prepare to it too; and when the
    /// prepare ends meanwhile, nothing is offered, prepared or started again.
    @Test func anUpdateWhilePreparingStartsAtOnceAndLeavesThePrepareToTheUpdater() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.result("prepared:\(Self.tip)")
        box.hold()
        let world = World()
        let controller = controller(box, world)
        controller.considerPreparing()
        #expect(await wait { box.calls.count == 1 })
        controller.start()
        #expect(controller.phase == .pulling)
        #expect(await wait { box.calls.count == 2 })
        #expect(box.calls == ["mode:prepare status:update-prepare log:prepare.log signal:none",
                              "mode:update status:update-status log:update.log signal:USR2"])
        #expect(controller.preparing && FileManager.default.fileExists(atPath: box.paths.prepareStatusFile.path))
        controller.stopForQuit()
        world.enabled = false
        controller.prepareSettingChanged()
        world.enabled = true
        try? await Task.sleep(for: .milliseconds(200))
        #expect(controller.preparing && !box.calls.contains("prepare stopped"))
        // The prepare ends (the updater installs what it left): nothing offered, no prepare, no second update.
        box.goPrepare()
        #expect(await wait { !controller.preparing })
        controller.considerPreparing()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(controller.prepared == nil && !controller.restartOffered(for: world.latest))
        #expect(box.calls.count == 2 && controller.phase.isRunning)
        box.go()
    }

    /// A quit stops the prepare; so does the setting turned off, which also takes Restart to update away.
    @Test func aQuitOrTheSettingOffStopsThePrepare() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.result("prepared:\(Self.tip)")
        box.hold()
        let world = World()
        let controller = controller(box, world)
        controller.considerPreparing()
        #expect(await wait { box.calls.count == 1 })
        controller.stopForQuit()
        #expect(await wait { !controller.preparing })
        #expect(box.calls.last == "prepare stopped" && controller.prepared == nil)

        controller.considerPreparing()
        #expect(await wait { box.calls.count == 3 })
        world.enabled = false
        controller.prepareSettingChanged()
        #expect(await wait { !controller.preparing })
        #expect(box.calls.last == "prepare stopped")

        try box.writePrepare("app:\(box.bundle.path)\npulling\nprepared:\(Self.tip)\n")
        let relaunched = self.controller(box, world)
        relaunched.restoreAfterLaunch()
        #expect(relaunched.prepared == Self.tip && !relaunched.restartOffered(for: world.latest))
        world.enabled = true
        #expect(relaunched.restartOffered(for: world.latest))
    }

    /// A prepare that failed for a reason of its own is not tried again for that commit; one the power, the quit, a
    /// stop or the time ended is, at the next check; a new commit is tried whatever came before.
    @Test func aFailedPrepareIsTriedAgainOnlyWhenTheFailureWasNotTheCommits() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World()
        let controller = controller(box, world)
        try box.result("failed:the build failed")
        controller.considerPreparing()
        #expect(await wait { !controller.preparing })
        controller.considerPreparing()
        #expect(!controller.preparing && box.calls.count == 1 && controller.prepared == nil)

        world.latest = UpdateInfo(newer: 3, subjects: [], tip: Self.newer)
        try box.result("failed:on battery power")
        controller.considerPreparing()
        #expect(await wait { box.calls.count == 2 && !controller.preparing })
        // A busy machine's build that ran out of time: the next check goes on from where the build got to (P715).
        try box.result("failed:timed out after 60 min")
        controller.considerPreparing()
        #expect(await wait { box.calls.count == 3 && !controller.preparing })
        try box.result("prepared:\(Self.newer)")
        controller.considerPreparing()
        #expect(await wait { box.calls.count == 4 && !controller.preparing })
        #expect(controller.prepared == Self.newer)
        // Turned off and on, the failed commit is tried again.
        world.latest = UpdateInfo(newer: 2, subjects: [], tip: Self.tip)
        try box.result("prepared:\(Self.tip)")
        controller.prepareSettingChanged()
        #expect(await wait { box.calls.count == 5 && !controller.preparing })
        #expect(controller.prepared == Self.tip)
    }

    /// A prepare that built another commit than the check saw (origin/main moved before its fetch) checks again, and
    /// never prepares again on the stale check, which would fetch and find the same commit over and over.
    @Test func aPrepareOfAnotherCommitChecksAgainInsteadOfPreparingAgain() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        try box.result("prepared:\(Self.newer)")
        let world = World()
        var rechecks = 0
        let controller = UpdateController(repoPath: box.repo.path, commit: Self.build, paths: box.paths, pid: 4242,
                                          bundlePath: box.bundle.path, recheck: { rechecks += 1 }, context: world.context)
        controller.considerPreparing()
        #expect(await wait { !controller.preparing && rechecks == 1 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(box.calls.count == 1 && controller.prepared == Self.newer && !controller.restartOffered(for: world.latest))
        world.latest = UpdateInfo(newer: 3, subjects: [], tip: Self.newer)
        controller.considerPreparing()
        #expect(controller.restartOffered(for: world.latest) && box.calls.count == 1)
    }

    /// Restart to update needs origin/main's commit as last checked: a prepared commit that origin/main moved past is
    /// an Update again, and the click updates.
    @Test func aPreparedCommitOriginMovedPastIsAnUpdateAgain() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World()
        world.latest = UpdateInfo(newer: 3, subjects: [], tip: Self.newer)
        let controller = UpdateController(repoPath: box.repo.path, commit: Self.build, paths: box.paths, pid: 4242,
                                          bundlePath: box.bundle.path, prepared: Self.tip, quitSignal: { "USR2" },
                                          context: world.context)
        #expect(!controller.restartOffered(for: world.latest))
        #expect(UpdateText.menuTitle(available: world.latest, phase: .idle, prepared: false) == "Update Juice Island (3 changes)")
        controller.act()
        #expect(controller.phase == .pulling)
        #expect(await wait { box.calls.count == 1 })
        #expect(box.calls == ["mode:update status:update-status log:update.log signal:USR2"])
        box.go()
    }

    /// At launch: a prepare that ended before is offered again; one for another bundle, for this very build, or one
    /// that failed or did not end is not.
    @Test func aPrepareFromBeforeTheLaunchIsKeptOnlyWhenItIsThisBundlesAndNewer() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World()
        for (text, want) in [("app:\(box.bundle.path)\nprepared:\(Self.tip)\n", Self.tip),
                             ("app:/Applications/Juice Island.app\nprepared:\(Self.tip)\n", nil),
                             ("app:\(box.bundle.path)\nprepared:\(Self.build)\n", nil),
                             ("app:\(box.bundle.path)\nbuilding\nfailed:the build failed\n", nil),
                             ("app:\(box.bundle.path)\nbuilding\n", nil)] as [(String, String?)] {
            try box.writePrepare(text)
            let relaunched = controller(box, world)
            relaunched.restoreAfterLaunch()
            #expect(relaunched.prepared == want, "\(text)")
        }
    }

    /// A prepare that wrote nothing (the update lock was another bundle's run) never takes that run's outcome for its
    /// own: neither its prepared commit nor its failure (P717).
    @Test func aPrepareThatWroteNothingTakesNoOtherBundlesOutcome() async throws {
        let box = try Sandbox()
        defer { box.remove() }
        let world = World()
        let controller = controller(box, world)
        let other = "app:/Applications/Juice Island Dev.app\npulling\nbuilding\nverifying\n"
        try box.busy(other + "prepared:\(Self.tip)\n")
        controller.considerPreparing()
        #expect(await wait { !controller.preparing })
        #expect(controller.prepared == nil && !controller.restartOffered(for: world.latest))

        try box.busy(other + "failed:the build failed\n")
        controller.considerPreparing()
        #expect(await wait { box.calls.count == 2 && !controller.preparing })
        // Its own run, at the next check: the other run's failure held nothing back.
        try box.busy(nil)
        try box.result("prepared:\(Self.tip)")
        controller.considerPreparing()
        #expect(await wait { box.calls.count == 3 && !controller.preparing })
        #expect(controller.prepared == Self.tip)
    }

    @Test func prepareOutcomesParse() {
        #expect(PrepareOutcome(text: "app:/x\npulling\nprepared:\(Self.tip)\n") == .prepared(Self.tip))
        #expect(PrepareOutcome(text: "app:/x\npulling\nprepared:\(Self.tip.uppercased())\n") == .prepared(Self.tip))
        #expect(PrepareOutcome(text: "app:/x\npulling\ndone\n") == .done)
        #expect(PrepareOutcome(text: "app:/x\nfailed:on battery power\n") == .failed("on battery power"))
        #expect(PrepareOutcome(text: "app:/x\nfailed:on battery power\n")?.isPassing == true)
        #expect(PrepareOutcome(text: "app:/x\nfailed:stopped\n")?.isPassing == true)
        #expect(PrepareOutcome(text: "app:/x\nfailed:the build failed\n")?.isPassing == false)
        // Only the commit's own failures hold it back (P715): its build, its checks, its updater. The time, the
        // network, git's locks and the checkout say nothing about it.
        for reason in ["timed out after 60 min", "can't reach GitHub", "git's lock /r/.git/refs/remotes/origin/main.lock is left over; delete it",
                       "could not set up the updater's checkout at /c/update-build", "origin has no main",
                       "the updater's checkout is not at ccccccc", "could not keep the prepared app", "something new"] {
            #expect(PrepareOutcome.failed(reason).isPassing, "\(reason)")
        }
        for reason in ["the build failed", "the build left no single app in the staging folder",
                       "the new build's signature does not verify", "the new build is stamped with no commit, not \(Self.tip)",
                       "the new build's bundle id is missing, not com.ofengenden.juice",
                       "the new build does not meet the installed app's designated requirement (macOS would drop its permissions)",
                       "origin/main has no scripts/update-app.sh", "origin/main's update-app.sh cannot prepare an update",
                       "origin/main's update-app.sh is too old to build it; install that commit by hand"] {
            #expect(!PrepareOutcome.failed(reason).isPassing, "\(reason)")
        }
        #expect(PrepareOutcome(text: "app:/x\npulling\nbuilding\n") == nil)
        #expect(PrepareOutcome(text: "app:/x\nprepared:abc\n") == nil)
        #expect(PrepareOutcome(text: "app:/x\nprepared:\(Self.tip)") == nil)
        #expect(PrepareOutcome(text: "") == nil)
    }

    /// The prepare's environment: its own files, the mode, and never the quit signal; an install's: the update's files
    /// and the mode; an update names no mode; a mode the app inherited never passes.
    @Test func eachRunGetsItsModeAndFiles() {
        let paths = UpdateController.Paths(statusFile: URL(fileURLWithPath: "/tmp/s/update-status"), logFile: URL(fileURLWithPath: "/tmp/l/update.log"))
        let base = ["PATH": "/usr/bin:/bin", "JI_RUN_MODE": "install"]
        let prepare = UpdateController.environment(paths: paths, quitSignal: "USR2", mode: .prepare, base: base)
        #expect(prepare["JI_RUN_MODE"] == "prepare" && prepare["JI_APP_QUIT_SIGNAL"] == nil)
        #expect(prepare["JI_STATUS_FILE"] == "/tmp/s/update-prepare" && prepare["JI_LOG_FILE"] == "/tmp/l/prepare.log")
        let install = UpdateController.environment(paths: paths, quitSignal: "USR2", mode: .install, base: base)
        #expect(install["JI_RUN_MODE"] == "install" && install["JI_APP_QUIT_SIGNAL"] == "USR2")
        #expect(install["JI_STATUS_FILE"] == "/tmp/s/update-status" && install["JI_LOG_FILE"] == "/tmp/l/update.log")
        #expect(UpdateController.environment(paths: paths, base: base)["JI_RUN_MODE"] == nil)
        #expect(paths.whatsNewFile.path == "/tmp/s/whats-new")
        // A dev build beside the release app has its own prepare files (the update's are shared, and say whose run
        // it is).
        let release = UpdateController.Paths.standard(for: .production)
        #expect(release.statusFile.path.hasSuffix("/Library/Application Support/Juice Island/update-status"))
        #expect(release.prepareStatusFile.path.hasSuffix("/Library/Application Support/Juice Island/update-prepare"))
        #expect(release.prepareLogFile.path.hasSuffix("/Library/Logs/Juice Island/prepare.log"))
        for identity in [AppIdentity.development, .other] {
            let dev = UpdateController.Paths.standard(for: identity)
            #expect(dev.statusFile == release.statusFile && dev.logFile == release.logFile)
            #expect(dev.prepareStatusFile.path.hasSuffix("/Library/Application Support/Juice Island/update-prepare-dev"))
            #expect(dev.prepareLogFile.path.hasSuffix("/Library/Logs/Juice Island/prepare-dev.log"))
        }
    }

    @Test func theUpdateControlsWordsWhenPrepared() {
        let info = UpdateInfo(newer: 3, subjects: [], tip: Self.tip)
        #expect(UpdateText.toolbarHelp(info, prepared: true) == "3 changes · click to restart")
        #expect(UpdateText.toolbarHelp(info) == "3 changes · click to update")
        #expect(UpdateText.menuTitle(available: info, phase: .idle, prepared: true) == "Restart to Update (3 changes)")
        #expect(UpdateText.menuTitle(available: UpdateInfo(newer: 0, subjects: [], dirty: true), phase: .idle, prepared: true)
            == "Restart to Update")
        #expect(UpdateText.menuTitle(available: info, phase: .building, prepared: true) == "Updating: Building")
        #expect(UpdateText.restartToUpdate == UpdatePhase.restartNeeded.text)
    }
}
