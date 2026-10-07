import Foundation
import IslandEngine
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// The public flavor, Juice (P820 to P826): its settings from its own Info.plist, the private app's names unchanged
/// wherever that key is missing (this test process, the renders, the private app), and its Sparkle updater's run on the
/// Update control, driven here by a fake.
@MainActor
@Suite(.serialized)
struct PublicFlavorTests {
    static let publicID = "io.github.michaelofengenden.juice"
    static let publicInfo: [String: Any] = ["JIFlavor": "public", "CFBundleIdentifier": publicID, "JIProductName": "Juice",
                                            "JIPublicRepo": "michaelofengenden/juiceisland"]
    static let publicFlavor = AppFlavor(info: publicInfo)

    // MARK: Flavor settings (P820)

    @Test func aBundleWithoutTheKeyIsThePrivateAppWithItsNamesAsTheyWere() {
        for info in [nil, [:], ["CFBundleIdentifier": "com.ofengenden.juice"], ["JIFlavor": "private"]] as [[String: Any]?] {
            let flavor = AppFlavor(info: info)
            #expect(flavor == .private && !flavor.isPublic)
            #expect(flavor.productName == "Juice Island" && flavor.dataFolderName == "Juice")
            #expect(flavor.supportFolderName == "Juice Island" && flavor.logsFolderName == "Juice Island")
            #expect(flavor.logSubsystem == "com.ofengenden.juice" && flavor.publicRepo == nil && flavor.sourceURL == nil)
        }
        // This process has no such key: every name the tests and renders see is the private app's.
        #expect(AppFlavor.current == .private && Product.name == "Juice Island")
    }

    @Test func thePublicFlavorNamesItsProductAndKeepsItsOwnFolders() {
        let flavor = Self.publicFlavor
        #expect(flavor.isPublic && flavor.productName == "Juice" && flavor.bundleIdentifier == Self.publicID)
        #expect(flavor.dataFolderName == Self.publicID && flavor.supportFolderName == Self.publicID)
        #expect(flavor.logsFolderName == Self.publicID && flavor.logSubsystem == Self.publicID)
        #expect(flavor.sourceURL?.absoluteString == "https://github.com/michaelofengenden/juiceisland")
        // Never the private app's folders or log.
        for name in [flavor.dataFolderName, flavor.supportFolderName, flavor.logsFolderName, flavor.logSubsystem] {
            #expect(!["Juice", "Juice Island", "com.ofengenden.juice"].contains(name))
        }
        #expect(Product.supportFolder(flavor).path.hasSuffix("Library/Application Support/\(Self.publicID)"))
        #expect(Product.logsFolder(flavor).path.hasSuffix("Library/Logs/\(Self.publicID)"))
    }

    @Test func aPublicInfoPlistMissingAValueFallsBackSafely() {
        // No bundle id, or one Xcode never expanded: not the public flavor.
        #expect(AppFlavor(info: ["JIFlavor": "public"]) == .private)
        #expect(AppFlavor(info: ["JIFlavor": "public", "CFBundleIdentifier": "$(JI_BUNDLE_ID)"]) == .private)
        // No name: Juice. No repository, or one that is not owner/name: no source link.
        var info = Self.publicInfo
        info["JIProductName"] = nil
        info["JIPublicRepo"] = "$(JI_PUBLIC_REPO)"
        #expect(AppFlavor(info: info).productName == "Juice" && AppFlavor(info: info).publicRepo == nil)
        for repo in ["a/b/c", "owner", "/name", "owner/na me", "owner/name?x=1"] {
            info["JIPublicRepo"] = repo
            #expect(AppFlavor(info: info).publicRepo == nil, "\(repo)")
        }
    }

    @Test func thePublicBundleIDIsTheReleaseBuildOnlyInThePublicFlavor() {
        // The private app's ids keep their meaning in either flavor.
        for flavor in [AppFlavor.private, Self.publicFlavor] {
            #expect(AppIdentity(bundleIdentifier: "com.ofengenden.juice", flavor: flavor) == .production)
            #expect(AppIdentity(bundleIdentifier: "com.ofengenden.juice.dev", flavor: flavor) == .development)
            #expect(AppIdentity(bundleIdentifier: "com.example.other", flavor: flavor) == .other)
        }
        #expect(AppIdentity(bundleIdentifier: Self.publicID, flavor: .private) == .other)
        #expect(AppIdentity(bundleIdentifier: Self.publicID, flavor: Self.publicFlavor) == .production)
        #expect(AppIdentity(bundleIdentifier: Self.publicID + ".widget", flavor: Self.publicFlavor) == .other)
    }

    @Test func eachFlavorCountsTheOtherReaders() {
        #expect(StandaloneJuiceGuard.readerBundleIdentifiers(.private) == ["com.ofengenden.juice"])
        #expect(StandaloneJuiceGuard.readerBundleIdentifiers(Self.publicFlavor) == ["com.ofengenden.juice", Self.publicID])
        var guardian = StandaloneJuiceGuard(ownProcessIdentifier: 1, runningApps: { [] })
        let copy = RunningAppInfo(processIdentifier: 2, bundleIdentifier: Self.publicID, bundleURL: URL(fileURLWithPath: "/tmp/x/Copy.app"))
        #expect(!guardian.isStandaloneJuice(copy))
        guardian.readerBundleIdentifiers = StandaloneJuiceGuard.readerBundleIdentifiers(Self.publicFlavor)
        #expect(guardian.isStandaloneJuice(copy))
        // The public flavor's own process is never the other reader.
        #expect(!guardian.isStandaloneJuice(RunningAppInfo(processIdentifier: 1, bundleIdentifier: Self.publicID, bundleURL: nil)))
    }

    @Test func thePrivateAppsNamesAndPathsAreUnchanged() {
        #expect(JuiceLog.subsystem == "com.ofengenden.juice")
        #expect(AccountsStore.defaultFileURL.path.hasSuffix("Library/Application Support/Juice/accounts.json"))
        #expect(ApprovalChoices.denyMessage == "Denied from Juice Island.")
        #expect(LaunchAtLogin.installedPath == "/Applications/Juice Island.app")
        #expect(LaunchAtLogin.approvalLine == "Allow Juice Island in Login Items.")
        #expect(DiagnosticsText.motionFolder == "One JSON per motion in ~/Library/Logs/Juice Island/motion.")
        #expect(GlobalKeyAction.open.title == "Open Juice Island")
        let paths = UpdateController.Paths.standard(for: .production)
        #expect(paths.statusFile.path.hasSuffix("Library/Application Support/Juice Island/update-status"))
        #expect(paths.logFile.path.hasSuffix("Library/Logs/Juice Island/update.log"))
        #expect(UpdateController.Paths.standard(for: .development).prepareStatusFile.lastPathComponent == "update-prepare-dev")
        #expect(UpdateText.menuTitle(available: UpdateInfo(newer: 3, subjects: []), phase: .idle) == "Update Juice Island (3 changes)")
        // Either flavor shows the VERSION file's version, which its build puts in the bundle (P1251).
        #expect(AboutPane.buildLine(BuildStamp(commit: nil, repoPath: nil), version: "0.5.0") == "Version 0.5.0 · unknown build")
        #expect(AboutPane.buildLine(BuildStamp(commit: nil, repoPath: nil), version: nil) == "unknown build")
        #expect(AboutPane.buildLine(BuildStamp(commit: nil, repoPath: nil), version: "1.2.0")
            == "Version 1.2.0 · unknown build")
    }

    @Test func thePrivateAppKeepsItsUpdaterWhateverItIsHanded() {
        // A version (the bundle's, VERSION's since P1251) changes nothing: the private app compares commits only.
        for version in [nil, "0.1.0", "99.0.0"] as [String?] {
            let feed = FakeFeed()
            let (checker, controller) = AppEnvironment.updates(stamp: BuildStamp(commit: nil, repoPath: nil), settings: .ephemeral(),
                                                               flavor: .private, feed: feed, version: version, memory: .inMemory())
            #expect(checker.source == .git && checker.feed == nil && controller.feed == nil)
            #expect(!checker.off)
        }
    }

    // MARK: The feed's run on the Update control (P825)

    @Test func theFeedsStagesAreTheControlsWordsAndFill() {
        var run = FeedRun()
        run.apply(.downloadStarted)
        #expect(run.phase == .pulling && run.progress.words == "Downloading" && run.progress.fraction == FeedRun.downloadStart)
        run.apply(.expectedLength(1_000))
        run.apply(.received(450))
        #expect(run.progress.words == "Downloading 45%")
        #expect(abs(run.progress.fraction - (0.02 + 0.78 * 0.45)) < 0.000_1)
        #expect(UpdateControlState.of(available: nil, phase: run.phase, prepared: false, progress: run.progress)
            == .running(words: "Downloading 45%", fraction: run.progress.fraction))
        #expect(UpdateText.menuTitle(available: nil, phase: run.phase, progress: run.progress) == "Updating: Downloading 45%")
        // A length that was wrong: the percent stops at 99 and the fill at the download's end.
        run.apply(.received(900))
        #expect(run.progress.words == "Downloading 99%" && run.progress.fraction == FeedRun.downloadEnd)
        run.apply(.extracting(0.5))
        #expect(run.phase == .building && run.progress.words == "Extracting" && abs(run.progress.fraction - 0.86) < 0.000_1)
        run.apply(.extracting(1))
        #expect(run.phase == .installing && run.progress.words == "Installing" && run.progress.fraction == FeedRun.checking)
        run.apply(.readyToInstall)
        #expect(run.phase == .restarting && run.progress.fraction == 1)
        #expect(UpdateControlState.of(available: nil, phase: run.phase, prepared: false, progress: run.progress) == .finished)
        // Past ready the session's end changes nothing: the app is quitting.
        run.apply(.ended)
        #expect(run.phase == .restarting)
    }

    @Test func theFillNeverGoesBackAndAnEndBeforeReadyStopsTheRun() {
        var run = FeedRun()
        run.apply(.downloadStarted)
        run.apply(.expectedLength(100))
        run.apply(.received(100))
        let downloaded = run.progress.fraction
        run.apply(.extracting(0))
        #expect(run.progress.fraction >= downloaded)
        run.apply(.ended)
        #expect(run == FeedRun() && !run.isRunning)
        // Events that belong to no run do nothing.
        run.apply(.received(10))
        run.apply(.expectedLength(10))
        #expect(run == FeedRun())
        // An update downloaded before the click starts at unpacking.
        run.begin(downloaded: true)
        #expect(run.phase == .building && run.progress.words == "Extracting")
    }

    @Test func checkNowAndTheDailyCheckAreTheFeedsAndNeverRunGit() async {
        let (feed, checker, controller, git, _) = make()
        checker.start()
        #expect(feed.started == 1)
        #expect(checker.checkNow() == nil && feed.checks == 1)
        feed.send(.checking)
        #expect(checker.state == .checking)
        feed.send(.upToDate)
        guard case let .checked(info, _) = checker.state else { Issue.record("not checked"); return }
        #expect(!info.isAvailable && checker.available == nil)
        #expect(UpdateText.status(checker.state, timeZone: .gmt).hasPrefix("Up to date · checked "))
        #expect(git.calls == 0 && controller.phase == .idle)
    }

    @Test func aFoundVersionIsOfferedAndTheClickDownloadsInstallsAndRelaunches() async throws {
        let (feed, checker, controller, _, memory) = make()
        checker.start()
        feed.send(.found(version: "1.3.0", downloaded: false, informational: false))
        let info = try #require(checker.available)
        #expect(info.version == "1.3.0" && UpdateText.offer(info) == "Version 1.3.0")
        #expect(UpdateText.menuTitle(available: info, phase: .idle) == "Update Juice Island")
        #expect(state(checker, controller) == .offer(restart: false))
        // The click: the feed installs, and a sliver shows at once.
        controller.act()
        #expect(feed.installs == 1 && controller.phase == .pulling && controller.progress.words == "Downloading")
        feed.send(.downloadStarted)
        feed.send(.expectedLength(200))
        feed.send(.received(100))
        #expect(state(checker, controller) == .running(words: "Downloading 50%", fraction: controller.progress.fraction))
        feed.send(.extracting(0.2))
        feed.send(.extracting(1))
        #expect(state(checker, controller).words == "Installing")
        // Ready: Updated with the glow, the version kept for after the relaunch, then the feed relaunches.
        feed.send(.readyToInstall)
        #expect(state(checker, controller) == .finished && memory.load() == "1.3.0")
        try await waitFor { feed.relaunches == 1 }
        // Still here: the owner is asked, and Restart to update tries again.
        try await waitFor { controller.phase == .restartNeeded }
        #expect(state(checker, controller) == .restartNeeded)
        controller.act()
        #expect(feed.relaunches == 2)
    }

    @Test func aDownloadedUpdateIsRestartToUpdate() {
        let (feed, checker, controller, _, _) = make()
        checker.start()
        feed.send(.found(version: "1.3.0", downloaded: true, informational: false))
        #expect(state(checker, controller) == .offer(restart: true))
        controller.act()
        #expect(feed.installs == 1 && controller.phase == .building && controller.progress.words == "Extracting")
    }

    @Test func aFailureInARunShowsAndRetryChecksAndInstallsWhatItFinds() {
        let (feed, checker, controller, _, _) = make()
        checker.start()
        feed.send(.found(version: "1.3.0", downloaded: false, informational: false))
        controller.act()
        feed.send(.downloadStarted)
        feed.send(.failed("The download failed"))
        feed.send(.ended)
        #expect(controller.phase == .failed(reason: "The download failed"))
        #expect(state(checker, controller) == .failed(reason: "The download failed"))
        // Retry (About's control, the toolbar's own half): a new check, which installs what it finds without a second click.
        // The control stays under the pointer meanwhile, saying Checking (P864).
        controller.start()
        #expect(feed.checks == 1 && controller.phase == .pulling && controller.progress.words == "Checking")
        feed.send(.checking)
        #expect(state(checker, controller) == .running(words: "Checking", fraction: FeedRun.checkStart))
        #expect(checker.available?.version == "1.3.0")
        feed.send(.found(version: "1.3.0", downloaded: false, informational: false))
        #expect(feed.installs == 2 && controller.phase == .pulling && controller.progress.words == "Downloading")
    }

    @Test func aRetryThatFindsNothingOrFailsEndsItsCheck() {
        let (feed, checker, controller, _, _) = make()
        checker.start()
        feed.send(.found(version: "1.3.0", downloaded: false, informational: false))
        controller.act()
        feed.send(.downloadStarted)
        feed.send(.failed("The download failed"))
        controller.start()
        feed.send(.checking)
        feed.send(.upToDate)
        #expect(controller.phase == .idle && checker.available == nil && state(checker, controller) == .hidden)
        // A later check's find waits for the click: the Retry was answered.
        feed.send(.found(version: "1.3.1", downloaded: false, informational: false))
        #expect(feed.installs == 1 && state(checker, controller) == .offer(restart: false))
        // A Retry whose check fails says so, with the check's reason.
        controller.act()
        feed.send(.failed("The download failed"))
        controller.start()
        feed.send(.failed("You're offline"))
        #expect(state(checker, controller) == .failed(reason: "You're offline"))
        // The feed could not start a check (one of its own runs): no Checking that never ends.
        feed.canCheck = false
        controller.start()
        #expect(controller.phase == .idle && state(checker, controller) == .offer(restart: false))
        // A check whose session ended with no answer: nothing installs on a later find.
        feed.canCheck = true
        controller.act()
        feed.send(.failed("The download failed"))
        controller.start()
        feed.send(.ended)
        #expect(controller.phase == .idle)
        let installs = feed.installs
        feed.send(.found(version: "1.3.1", downloaded: false, informational: false))
        #expect(feed.installs == installs)
    }

    @Test func aFailedCheckIsTheCheckersAndAHeldUpdateThatWentIsFoundAgain() {
        let (feed, checker, controller, _, _) = make()
        checker.start()
        feed.send(.failed("You're offline"))
        guard case .failed("You're offline", _) = checker.state else { Issue.record("\(checker.state)"); return }
        #expect(controller.phase == .idle)
        // The feed no longer holds the update it found: the click checks again, and that check's update installs.
        feed.send(.found(version: "1.3.0", downloaded: false, informational: false))
        feed.holds = false
        controller.act()
        #expect(feed.installs == 1 && feed.checks == 1 && controller.phase == .pulling && controller.progress.words == "Checking")
        feed.holds = true
        feed.send(.found(version: "1.3.0", downloaded: false, informational: false))
        #expect(feed.installs == 2 && controller.phase == .pulling)
    }

    @Test func anInformationalUpdateOpensItsPageAndDownloadsNothing() {
        let (feed, checker, controller, _, _) = make()
        checker.start()
        feed.send(.found(version: "2.0", downloaded: false, informational: true))
        feed.holds = false
        controller.act()
        #expect(feed.installs == 1 && feed.checks == 0 && controller.phase == .idle)
    }

    @Test func theInstalledVersionSaysUpdatedOnceAfterTheRelaunch() {
        let memory = FeedMemory.inMemory()
        memory.save("1.3.0")
        let (_, _, controller, _, _) = make(memory: memory, version: "1.3.0")
        controller.restoreAfterLaunch()
        controller.feed?.start()
        #expect(controller.phase == .updated("1.3.0") && memory.load() == nil)
        // Another version (the install did not happen): nothing, and the record goes.
        let other = FeedMemory.inMemory()
        other.save("1.4.0")
        let (_, _, second, _, _) = make(memory: other, version: "1.3.0")
        second.feed?.start()
        #expect(second.phase == .idle && other.load() == nil)
    }

    @Test func theLastCheckShowsWithItsDayWhenItWasNotToday() {
        let (feed, checker, _, _, _) = make()
        checker.start()
        let then = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21
        feed.send(.lastChecked(then))
        #expect(checker.state == .checked(UpdateInfo(newer: 0, subjects: []), at: then))
        let today = then.addingTimeInterval(3 * 86_400)
        #expect(UpdateText.status(checker.state, timeZone: .gmt, today: today) == "Up to date · checked Sep 21")
        #expect(UpdateText.status(checker.state, timeZone: .gmt, today: then) == "Up to date · checked 14:13")
        // The private app's hourly check keeps the time.
        #expect(UpdateText.status(checker.state, timeZone: .gmt) == "Up to date · checked 14:13")
        // A record that comes after a check of this run changes nothing.
        feed.send(.upToDate)
        feed.send(.lastChecked(then))
        guard case let .checked(_, at) = checker.state else { Issue.record("not checked"); return }
        #expect(at != then)
    }

    /// Sparkle stamps its date on every check, one that found an update too, and waits a day before the next: after a
    /// relaunch the version the last check found is offered again, until a check says otherwise (P863).
    @Test func aFoundVersionIsStillOfferedAfterARelaunch() {
        let memory = FeedMemory.inMemory()
        let nine = Date(timeIntervalSince1970: 1_790_000_000)
        do {
            let (feed, checker, _, _, _) = make(memory: memory)
            checker.start()
            feed.send(.found(version: "1.3.0", downloaded: false, informational: false))
        }
        // The relaunch: Sparkle says only when it last checked.
        let (feed, checker, controller, _, _) = make(memory: memory)
        checker.start()
        feed.send(.lastChecked(nine))
        #expect(checker.available?.version == "1.3.0" && state(checker, controller) == .offer(restart: false))
        #expect(UpdateText.status(checker.state, timeZone: .gmt, today: nine) == "Checked 14:13")
        // The click: no reply of Sparkle's is held, so it checks, and that check's update installs.
        feed.holds = false
        controller.act()
        #expect(feed.checks == 1 && controller.phase == .pulling)
        feed.holds = true
        feed.send(.found(version: "1.3.0", downloaded: false, informational: false))
        #expect(feed.installs == 2 && controller.progress.words == "Downloading")
        // A check that finds nothing forgets it.
        let (_, upToDateChecker, _, _, _) = make(memory: memory)
        upToDateChecker.feed?.handle(.upToDate)
        let (later, laterChecker, _, _, _) = make(memory: memory)
        laterChecker.start()
        later.send(.lastChecked(nine))
        #expect(laterChecker.available == nil)
    }

    @Test func aRememberedVersionThisBuildHasIsNotOffered() {
        for (remembered, running) in [("1.3.0", "1.3.0"), ("1.3.0", "1.3.1"), ("1.9.0", "1.10.0"), ("1.3", "1.3.0")] {
            let memory = FeedMemory.inMemory()
            memory.saveOffered(remembered)
            let (feed, checker, _, _, _) = make(memory: memory, version: running)
            checker.start()
            feed.send(.lastChecked(Date(timeIntervalSince1970: 1_790_000_000)))
            #expect(checker.available == nil, "\(remembered) with \(running) running")
            #expect(memory.loadOffered() == nil)
        }
        // An informational update (a page to read) is not remembered.
        let memory = FeedMemory.inMemory()
        let (feed, checker, _, _, _) = make(memory: memory)
        checker.start()
        feed.send(.found(version: "2.0", downloaded: false, informational: true))
        #expect(memory.loadOffered() == nil)
        #expect(FeedUpdates.isNewer("1.10.0", than: "1.9.9") && !FeedUpdates.isNewer("1.2", than: "1.2.0"))
        #expect(FeedUpdates.isNewer("1.2.1", than: nil))
    }

    // MARK: The licence in About (P857)

    @Test func thePublicFlavorSaysItIsFreeSoftwareWithNoWarranty() {
        #expect(AboutPane.licenceLine(flavor: .private) == nil)
        #expect(AboutPane.licenceLine(flavor: Self.publicFlavor) == "Free software under GPL-3.0, with no warranty")
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("ji-about-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bundle) }
        #expect(AboutPane.licenceURL(resources: bundle) == nil)
        try? FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try? Data("GPL".utf8).write(to: bundle.appendingPathComponent("LICENSE.txt"))
        #expect(AboutPane.licenceURL(resources: bundle)?.lastPathComponent == "LICENSE.txt")
    }

    @Test func aPublicBuildWithoutTheFeedsKeyChecksNothing() {
        let (checker, controller) = AppEnvironment.updates(stamp: BuildStamp(commit: nil, repoPath: nil), settings: .ephemeral(),
                                                           flavor: Self.publicFlavor, feed: nil, memory: .inMemory())
        #expect(checker.source == .off && controller.feed == nil)
        checker.start()
        #expect(checker.checkNow() == nil && checker.state == .idle)
        #expect(UpdateText.updatesOff == "Updates are off in this build")
        let joined = AppEnvironment.updates(stamp: BuildStamp(commit: nil, repoPath: nil), settings: .ephemeral(),
                                            flavor: Self.publicFlavor, feed: FakeFeed(), memory: .inMemory())
        #expect(joined.0.source == .feed && joined.1.feed != nil)
    }

    // MARK: Helpers

    private func state(_ checker: UpdateChecker, _ controller: UpdateController) -> UpdateControlState {
        UpdateControlState.of(available: checker.available, phase: controller.phase,
                              prepared: controller.restartOffered(for: checker.available), progress: controller.progress)
    }

    private func make(memory: FeedMemory = .inMemory(), version: String? = "1.2.0")
        -> (FakeFeed, UpdateChecker, UpdateController, CountingGit, FeedMemory) {
        let feed = FakeFeed(), git = CountingGit()
        let checker = UpdateChecker(stamp: BuildStamp(commit: nil, repoPath: nil), git: git)
        let controller = UpdateController(repoPath: nil, quitPatience: 0.05, finishHold: .milliseconds(20))
        FeedUpdates.join(FeedUpdates(updater: feed, runningVersion: version, memory: memory), checker: checker, controller: controller)
        return (feed, checker, controller, git, memory)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0 ..< 200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}

/// The feed's updater as the app sees it: counts the calls and sends what a test says Sparkle would.
@MainActor
private final class FakeFeed: FeedUpdating {
    var started = 0, checks = 0, installs = 0, relaunches = 0
    /// Whether a found update is held for the click (Sparkle's reply).
    var holds = true
    private var report: (@MainActor (FeedUpdateEvent) -> Void)?

    func start(report: @escaping @MainActor (FeedUpdateEvent) -> Void) {
        started += 1
        self.report = report
    }

    /// Whether a check can start (Sparkle refuses one while a session of its own runs).
    var canCheck = true

    func checkNow() -> Bool {
        checks += 1
        return canCheck
    }

    func install() -> Bool {
        installs += 1
        return holds
    }

    func relaunch() { relaunches += 1 }

    func send(_ event: FeedUpdateEvent) { report?(event) }
}

private final class CountingGit: GitRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func run(_ arguments: [String], timeout: TimeInterval) async -> GitOutput {
        lock.withLock { count += 1 }
        return .notLaunched
    }
}
