import Foundation
import JuiceCore
import Observation

/// Runs the updater this build carries, `Contents/Resources/update-app.sh <pid> <app> <repo>` (build-app.sh puts it
/// there), detached (stdin closed, output appended to the update log, so it outlives the app), follows its status file
/// (`UpdateStatusLine`), and quits the app on `ready` so the script can swap the bundle and open the new one. The
/// script builds origin/main in a checkout of its own and never a checkout's file, which git may rewrite while it runs
/// (P134); it hands over to origin/main's own copy by exec, so the process followed stays the same. `done` before
/// `ready` (already up to date) ends the run and checks again. A failure keeps the current app and shows the reason,
/// the log one click away; never an alert.
///
/// Past ready the app goes whatever it is doing (P98): it asks to quit through the main run loop (`quit`, `AppQuit` in
/// the app) and asks again after `quitRetry`, following the script all the while, so a script that fails or stops
/// while it waits ends the wait with its reason. Still running after `quitPatience`, it asks the owner (Restart to
/// update). The script asks once more by `UpdateQuitSignal`; nothing ends the app from outside. The new build, opened
/// by the script, says "Updated to <commit>" once; a build at another path (a dev build beside the release one, which
/// shares the status file) leaves another run's notice alone.
///
/// The Update control is the progress (P800 to P809): `progress` follows the run's states, and inside the build the
/// time it has run against the estimate update-app.sh puts in the log before `building` (read once, off the main
/// actor). At ready the control completes and says Updated for `finishHold` before the first ask to quit, so the end
/// shows; the script's own signal quits at once.
///
/// Prepared ahead (P710 to P715): with Settings › About's "Prepare updates in the background" on, a check that finds
/// origin/main ahead starts the same updater as a prepare (`JI_RUN_MODE=prepare`, its own status file and log), on AC
/// power out of Low Power Mode only, one at a time; it builds and verifies at low priority and leaves the app in the
/// updater's checkout, swapping nothing. Its `prepared:<commit>` turns the Update control into "Restart to update" while
/// that commit is still origin/main's as last checked, and that click runs the updater as an install
/// (`JI_RUN_MODE=install`), which verifies the prepared app the same way and goes on from ready as an update does. An
/// Update while a prepare runs stops the prepare first; a quit stops it; a failed prepare leaves today's Update. Then
/// What's new (P716): the build an update opened shows what changed once, as a small card, and About keeps it.
///
/// The public flavor (P823 to P826) runs no script: its feed (`feed`, Sparkle) downloads, unpacks and installs, and
/// reports its run here (`feedFollow`), so the same control shows it; the clicks go to the feed.
@MainActor
@Observable
final class UpdateController {
    struct Paths: Sendable {
        var statusFile: URL
        var logFile: URL
        /// The background prepare's status file and log (P710): never the update's, so a prepare never reads as an
        /// update and never pushes an update's log out.
        var prepareStatusFile: URL
        var prepareLogFile: URL

        /// What changed (P716): update-app.sh writes it beside the status file.
        var whatsNewFile: URL { statusFile.deletingLastPathComponent().appendingPathComponent("whats-new") }

        /// The prepare's files default to `update-prepare` beside the status file and `prepare.log` beside the log.
        init(statusFile: URL, logFile: URL, prepareStatusFile: URL? = nil, prepareLogFile: URL? = nil) {
            self.statusFile = statusFile
            self.logFile = logFile
            self.prepareStatusFile = prepareStatusFile ?? statusFile.deletingLastPathComponent().appendingPathComponent("update-prepare")
            self.prepareLogFile = prepareLogFile ?? logFile.deletingLastPathComponent().appendingPathComponent("prepare.log")
        }

        /// The release app's files; a dev build's prepare has its own (`update-prepare-dev`, `prepare-dev.log`, P717),
        /// since both run beside each other and each keeps its prepared app until its own Restart to update.
        static func standard(for identity: AppIdentity) -> Paths {
            let support = Product.supportFolder(), logs = Product.logsFolder()
            let suffix = identity == .production ? "" : "-dev"
            return Paths(statusFile: support.appendingPathComponent("update-status"), logFile: logs.appendingPathComponent("update.log"),
                         prepareStatusFile: support.appendingPathComponent("update-prepare" + suffix),
                         prepareLogFile: logs.appendingPathComponent("prepare\(suffix).log"))
        }

        static var standard: Paths { standard(for: .current) }
    }

    /// What the updater is asked to do (`JI_RUN_MODE`): an update, a background prepare, or Restart to update.
    enum RunMode: String, Sendable { case update, prepare, install }

    /// What the prepare and What's new read from the app; the defaults never prepare and keep nothing.
    struct Context {
        /// Settings › About › Prepare updates in the background.
        var prepareEnabled: @MainActor () -> Bool = { false }
        /// On AC power and out of Low Power Mode.
        var powerAllows: @MainActor () -> Bool = { PowerSource.allowsBackgroundWork }
        /// The update the last check offered (`UpdateChecker.available`).
        var latest: @MainActor () -> UpdateInfo? = { nil }
        /// The build whose What's new card showed already, and the setter that records one.
        var shownWhatsNew: @MainActor () -> String? = { nil }
        var markWhatsNewShown: @MainActor (String) -> Void = { _ in }
    }

    /// The updater in the app's bundle.
    nonisolated static let scriptPath = "Contents/Resources/update-app.sh"
    /// The script gives the run up to ready 15 minutes; this is the app's backstop for that part. Past ready the
    /// script's own end (its quit timeout) ends the wait.
    static let timeout: TimeInterval = 16 * 60
    /// On launch, a failure this recent (a swap that was undone) still shows.
    static let recentFailure: TimeInterval = 30 * 60
    /// On launch, a swap this recent opened this build: "Updated to <commit>" shows.
    static let recentUpdate: TimeInterval = 10 * 60

    private(set) var phase: UpdatePhase = .idle
    /// How far the run has come: the Update control's fill, the build's percent and the time left.
    private(set) var progress: UpdateProgress = .none
    /// The commit a background prepare left built and verified, while it waits for Restart to update; nil otherwise.
    private(set) var prepared: String?
    /// A background prepare runs.
    private(set) var preparing = false
    /// What changed in this build (P716), for Settings › About; nil when no update opened it or nothing was new.
    private(set) var whatsNew: WhatsNewNote?
    /// The What's new card shows: from the first launch of the build it names until the owner closes it.
    var showsWhatsNewCard = false
    /// About's What's new list is open.
    var showsWhatsNewList = false

    @ObservationIgnored let paths: Paths
    /// The public flavor's feed (`FeedUpdates.join`); nil in the private app, whose updates run update-app.sh.
    @ObservationIgnored var feed: FeedUpdates?
    @ObservationIgnored private let repoPath: String?
    /// This build's short commit, for "Updated to <commit>".
    @ObservationIgnored private let build: String?
    /// This build's full commit: what a prepare or a note is matched against.
    @ObservationIgnored private let commit: String?
    @ObservationIgnored private let context: Context
    @ObservationIgnored private let pid: Int32
    @ObservationIgnored private let bundlePath: String
    @ObservationIgnored private let quit: @MainActor () -> Void
    @ObservationIgnored private let openFile: @MainActor (URL) -> Void
    @ObservationIgnored private let recheck: @MainActor () -> Void
    @ObservationIgnored private let quitSignal: @MainActor () -> String?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let quitRetry: TimeInterval
    @ObservationIgnored private let quitPatience: TimeInterval
    @ObservationIgnored private let updatedLife: Duration
    @ObservationIgnored private let finishHold: Duration
    /// The run's mode: an install's check is most of its way (`UpdateProgress`).
    @ObservationIgnored private var runMode: RunMode = .update
    /// The script has written a state this run: until then an install does not know whether it fetches and builds.
    @ObservationIgnored private var begun = false
    /// When this app saw `building`, the fill then, and the build's estimate from the log (looked for once a run).
    @ObservationIgnored private var buildStartedAt: Date?
    @ObservationIgnored private var buildFrom = UpdateProgress.fetchEnd
    @ObservationIgnored private var estimate: BuildEstimate?
    @ObservationIgnored private var estimateLooked = false
    @ObservationIgnored private var finishing: Task<Void, Never>?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var updatedExpiry: Task<Void, Never>?
    @ObservationIgnored private var startedAt: Date?
    /// When this run saw ready; nil before.
    @ObservationIgnored private var readyAt: Date?
    /// How often this run asked to quit (tests read it).
    @ObservationIgnored private(set) var quitAsks = 0
    @ObservationIgnored private var prepareProcess: Process?
    /// The commit the running prepare builds.
    @ObservationIgnored private var preparingTip: String?
    /// An Update clicked while a prepare ran: it starts once the prepare has stopped.
    @ObservationIgnored private var updateAfterPrepare = false
    /// A commit whose prepare failed for a reason of its own (the build, the checks): not prepared again while the app
    /// runs, so a broken commit is not built every hour.
    @ObservationIgnored private var failedTip: String?

    /// `quitRetry` and `quitPatience` count from ready; `updatedLife` is how long "Updated to <commit>" shows;
    /// `finishHold` how long the control says Updated before the first ask to quit. `phase`, `progress`, `prepared` and
    /// `preparing` are for renders, which draw a state with no run behind it.
    init(repoPath: String?, build: String? = nil, commit: String? = nil, paths: Paths = .standard,
         pid: Int32 = ProcessInfo.processInfo.processIdentifier, bundlePath: String = Bundle.main.bundlePath,
         phase: UpdatePhase = .idle, progress: UpdateProgress? = nil, prepared: String? = nil, preparing: Bool = false,
         pollInterval: Duration = .milliseconds(500), quitRetry: TimeInterval = 5,
         quitPatience: TimeInterval = 12, updatedLife: Duration = .seconds(10 * 60), finishHold: Duration = .milliseconds(1400),
         now: @escaping @MainActor () -> Date = { Date() },
         quitSignal: @escaping @MainActor () -> String? = { UpdateQuitSignal.installedName },
         quit: @escaping @MainActor () -> Void = {}, openFile: @escaping @MainActor (URL) -> Void = { _ in },
         recheck: @escaping @MainActor () -> Void = {}, context: Context = Context()) {
        self.repoPath = repoPath
        self.build = build
        self.commit = commit
        self.context = context
        self.paths = paths
        self.pid = pid
        self.bundlePath = bundlePath
        self.phase = phase
        self.progress = progress ?? UpdateProgress.of(phase: phase, install: false, buildStarted: nil, estimate: nil, now: Date())
        self.prepared = prepared
        self.preparing = preparing
        self.pollInterval = pollInterval
        self.quitRetry = quitRetry
        self.quitPatience = quitPatience
        self.updatedLife = updatedLife
        self.finishHold = finishHold
        self.now = now
        self.quitSignal = quitSignal
        self.quit = quit
        self.openFile = openFile
        self.recheck = recheck
    }

    /// Starts the update unless one runs. The old status file goes first, so a stale `ready` can never quit the app. A
    /// prepare that runs holds the updater's checkout and its lock: it is stopped first, and the update starts as it
    /// ends (Fetching… shows meanwhile).
    func start() {
        guard !phase.isRunning else { return }
        if let feed { return feed.retry() }
        if let prepareProcess {
            updateAfterPrepare = true
            phase = .pulling
            refreshProgress()
            JuiceLog.update.notice("update asked while a prepare runs: the prepare stops first")
            prepareProcess.terminate()
            return
        }
        launch(.update)
    }

    /// Restart to update (P711): installs the prepared app; with nothing prepared, an update.
    func installPrepared() {
        guard !phase.isRunning else { return }
        if let feed { return feed.install() }
        guard prepareProcess == nil, prepared != nil else { return start() }
        launch(.install)
    }

    /// Runs the bundle's updater as an update or an install, and follows its status file.
    private func launch(_ mode: RunMode) {
        guard let repoPath else { return fail("Unknown build: no repository to update from") }
        let script = URL(fileURLWithPath: bundlePath).appendingPathComponent(Self.scriptPath)
        guard FileManager.default.isReadableFile(atPath: script.path) else {
            return fail("This build carries no update-app.sh")
        }
        let files = FileManager.default
        do {
            try files.createDirectory(at: paths.statusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createDirectory(at: paths.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.fileExists(atPath: paths.statusFile.path) { try files.removeItem(at: paths.statusFile) }
        } catch {
            return fail("Could not prepare the status file: \(error.localizedDescription)")
        }

        // Appending: the script starts its own log (the previous one becomes update.log.1); only what it prints before
        // that, such as another update running, lands here.
        let process: Process, log: FileHandle
        do {
            (process, log) = try Self.updater(script: script, arguments: [String(pid), bundlePath, repoPath], log: paths.logFile,
                                              environment: Self.environment(paths: paths, quitSignal: quitSignal(), mode: mode))
        } catch {
            return fail(error.localizedDescription)
        }
        defer { try? log.close() }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.scriptExited(status) }
        }
        do {
            try process.run()
        } catch {
            return fail("Could not start \(Self.scriptPath): \(error.localizedDescription)")
        }
        self.process = process
        startedAt = now()
        readyAt = nil
        quitAsks = 0
        runMode = mode
        begun = false
        buildStartedAt = nil
        buildFrom = UpdateProgress.fetchEnd
        estimate = nil
        estimateLooked = false
        updatedExpiry?.cancel()
        // The run takes the prepared app, or leaves it of no use: it is not offered again (a dev build's beside the release
        // one stays theirs).
        prepared = nil
        if prepareFileIsThisBundles() { try? files.removeItem(at: paths.prepareStatusFile) }
        phase = mode == .install ? .installing : .pulling
        refreshProgress()
        JuiceLog.update.notice("update started (\(mode.rawValue, privacy: .public))")
        startPolling()
    }

    /// The updater started detached: stdin closed, its output appended to `log` (it starts its own log there, the
    /// previous one kept as `.1`; only what it prints before that lands here), from /. The caller closes the log's
    /// handle once the process runs (the process keeps its own).
    private static func updater(script: URL, arguments: [String], log: URL,
                                environment: [String: String]) throws -> (Process, FileHandle) {
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw UpdateFailure(text: "Could not open the update log: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        return (process, handle)
    }

    private struct UpdateFailure: LocalizedError {
        let text: String
        var errorDescription: String? { text }
    }

    // MARK: Prepared ahead (P710 to P715)

    /// "Restart to update": the setting is on, no run, and a verified app waits for origin/main's commit as `info`
    /// (the last check) has it. A commit that moved on is an Update again until the new one is prepared.
    func restartOffered(for info: UpdateInfo?) -> Bool {
        // The feed's update is downloaded already: the click installs it at once.
        if feed != nil { return !phase.isRunning && info?.downloaded == true }
        guard context.prepareEnabled(), !phase.isRunning, let prepared, let tip = info?.tip else { return false }
        return prepared == tip
    }

    /// Builds origin/main's commit ahead, after each check and when the setting turns on: only with the setting on, an
    /// update offered at a known commit that is not this build's, none running or preparing, that commit not prepared
    /// already nor failed before for a reason of its own, and on AC power out of Low Power Mode.
    func considerPreparing() {
        guard feed == nil, context.prepareEnabled(), !phase.isRunning, prepareProcess == nil, let info = context.latest(),
              let tip = info.tip, tip != commit, prepared != tip, failedTip != tip, context.powerAllows() else { return }
        startPrepare(tip)
    }

    /// The setting changed: on, a prepare may start now (a commit that failed before is tried again); off, a running
    /// one stops.
    func prepareSettingChanged() {
        if context.prepareEnabled() {
            failedTip = nil
            considerPreparing()
        } else {
            prepareProcess?.terminate()
        }
    }

    /// On quit: a running prepare stops with its build (the script ends it and keeps nothing half made).
    func stopForQuit() {
        prepareProcess?.terminate()
    }

    private func startPrepare(_ tip: String) {
        guard let repoPath else { return }
        let script = URL(fileURLWithPath: bundlePath).appendingPathComponent(Self.scriptPath)
        let files = FileManager.default
        guard files.isReadableFile(atPath: script.path) else { return }
        do {
            try files.createDirectory(at: paths.prepareStatusFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.createDirectory(at: paths.prepareLogFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            if files.fileExists(atPath: paths.prepareStatusFile.path) { try files.removeItem(at: paths.prepareStatusFile) }
            let (process, log) = try Self.updater(script: script, arguments: [String(pid), bundlePath, repoPath],
                                                  log: paths.prepareLogFile, environment: Self.environment(paths: paths, mode: .prepare))
            defer { try? log.close() }
            process.terminationHandler = { [weak self] _ in
                Task { @MainActor in self?.prepareEnded() }
            }
            try process.run()
            prepareProcess = process
        } catch {
            JuiceLog.update.error("could not start a prepare")
            return
        }
        preparingTip = tip
        preparing = true
        // The prepare replaces what an earlier one left.
        prepared = nil
        JuiceLog.update.notice("preparing an update in the background")
    }

    private func prepareEnded() {
        prepareProcess = nil
        preparing = false
        // A prepare that found the update lock taken wrote nothing: what the file holds then is another bundle's run.
        let outcome = prepareFileIsThisBundles() ? readPrepare() : nil
        switch outcome {
        case let .prepared(built)?:
            prepared = built == commit ? nil : built
            JuiceLog.update.notice("an update is prepared")
        case .failed?:
            if outcome?.isPassing == false { failedTip = preparingTip }
            // The reason may name a path: it stays in prepare.log.
            JuiceLog.update.notice("the prepare ended without an app (see prepare.log)")
        case .done?, nil:
            break
        }
        let started = preparingTip
        preparingTip = nil
        if updateAfterPrepare {
            updateAfterPrepare = false
            launch(.update)
        } else if case let .prepared(built)? = outcome {
            // The commit it was started for: a check meanwhile may have seen a newer one, which is prepared next. Another
            // commit: origin/main moved before the prepare's own fetch, so the check is stale (Restart to update needs
            // its commit); it checks again rather than preparing again, which would only fetch the same commit.
            if built == started { considerPreparing() } else { recheck() }
        }
    }

    private func readPrepare() -> PrepareOutcome? {
        guard let data = FileManager.default.contents(atPath: paths.prepareStatusFile.path) else { return nil }
        return PrepareOutcome(text: String(decoding: data, as: UTF8.self))
    }

    // MARK: What's new (P716)

    /// ✕ on the card: it goes until the next build with something new.
    func dismissWhatsNew() {
        showsWhatsNewCard = false
    }

    /// On launch: a recent failure (the script undid a swap and reopened this app) still shows. After a recent swap
    /// that opened this build, "Updated to <commit>" shows, once: the status file goes with it. A run that updated
    /// another bundle is not this build's to show or clear.
    func restoreAfterLaunch(now: Date = Date()) {
        // The feed's "Updated to <version>" is its own (`FeedUpdates.start`).
        guard feed == nil else { return }
        restorePrepared()
        restoreWhatsNew()
        guard phase == .idle,
              let attributes = try? FileManager.default.attributesOfItem(atPath: paths.statusFile.path),
              let modified = attributes[.modificationDate] as? Date,
              let data = FileManager.default.contents(atPath: paths.statusFile.path) else { return }
        let text = String(decoding: data, as: UTF8.self), age = now.timeIntervalSince(modified)
        if let app = UpdateStatusLine.app(in: text), Self.standardized(app) != Self.standardized(bundlePath) { return }
        if case let .failed(reason)? = UpdateStatusLine.current(in: text) {
            guard age < Self.recentFailure else { return }
            phase = .failed(reason: reason)
        } else if UpdateStatusLine.opensNewBuild(text), age < Self.recentUpdate, let build {
            try? FileManager.default.removeItem(at: paths.statusFile)
            showUpdated(build)
        }
    }

    /// A prepare that ended before this launch: its app still waits, unless it is this build or another bundle's.
    private func restorePrepared() {
        guard prepareFileIsThisBundles(), let data = FileManager.default.contents(atPath: paths.prepareStatusFile.path) else { return }
        if case let .prepared(built)? = PrepareOutcome(text: String(decoding: data, as: UTF8.self)), built != commit { prepared = built }
    }

    /// The prepare's status file names this bundle (a dev build beside the release one shares the folder).
    private func prepareFileIsThisBundles() -> Bool {
        guard let data = FileManager.default.contents(atPath: paths.prepareStatusFile.path) else { return false }
        guard let app = UpdateStatusLine.app(in: String(decoding: data, as: UTF8.self)) else { return false }
        return Self.standardized(app) == Self.standardized(bundlePath)
    }

    /// The note the update that opened this build left: kept for About, and its card shown on this build's first
    /// launch only.
    private func restoreWhatsNew() {
        guard let data = FileManager.default.contents(atPath: paths.whatsNewFile.path),
              let note = WhatsNewNote(text: String(decoding: data, as: UTF8.self)), note.belongs(to: commit) else { return }
        whatsNew = note
        guard context.shownWhatsNew() != note.to else { return }
        context.markWhatsNewShown(note.to)
        showsWhatsNewCard = true
    }

    func openLog() { openFile(paths.logFile) }

    /// Reads the status file once and follows it.
    func poll() {
        guard phase.isRunning else { return }
        let status = readStatus()
        if status != nil { begun = true }
        switch status {
        // Past ready the script swaps the bundle once this app is gone, so the app goes whatever it last saw.
        case .ready?, .installing?, .restarting?: sawReady()
        case let .failed(reason)?: return fail(reason)
        case .done?: if readyAt == nil { return finishUpToDate() }
        case .pulling?: if readyAt == nil { phase = .pulling }
        case .building?: if readyAt == nil { phase = .building }
        // Verifying is the last step before the swap; it shows as Installing….
        case .verifying?: if readyAt == nil { phase = .installing }
        case nil: break
        }
        if let readyAt {
            followQuit(since: readyAt)
        } else if let startedAt, now().timeIntervalSince(startedAt) > Self.timeout {
            fail("Timed out after \(Int(Self.timeout / 60)) minutes")
        }
        refreshProgress()
    }

    /// `progress` from the phase; the build's start is when this app first saw it, from the fill it had then, and its
    /// estimate is looked for in the log once, off the main actor, as soon as the build starts (the script writes it
    /// before `building`).
    private func refreshProgress() {
        if phase == .building {
            if buildStartedAt == nil {
                buildStartedAt = now()
                buildFrom = progress.fraction
            }
            if !estimateLooked { lookForEstimate() }
        }
        let next = UpdateProgress.of(phase: phase, install: runMode == .install, begun: begun, buildStarted: buildStartedAt,
                                     buildFrom: buildFrom, estimate: estimate, now: now())
        if next != progress { progress = next }
    }

    private func lookForEstimate() {
        estimateLooked = true
        let log = paths.logFile, run = startedAt
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { BuildEstimate.read(logAt: log) }.value
            // Still this run's build: a run started since reads its own.
            guard let self, let found, self.phase == .building, self.startedAt == run else { return }
            self.estimate = found
            self.refreshProgress()
        }
    }

    /// Restart Now: the owner's click once asked (or any time past ready) quits, so the waiting script can swap.
    func restartNow() {
        if let feed {
            if phase == .restarting || phase == .restartNeeded { feed.relaunch() }
            return
        }
        guard readyAt != nil, phase.isRunning else { return }
        askToQuit()
    }

    /// The toolbar's and the island menu's update item: Restart to update quits, or installs the prepared app; anything
    /// else starts an update.
    func act() {
        if let feed {
            if phase == .restartNeeded { feed.relaunch() } else { feed.install() }
            return
        }
        if phase == .restartNeeded {
            restartNow()
        } else if restartOffered(for: context.latest()) {
            installPrepared()
        } else {
            start()
        }
    }

    /// The script's `UpdateQuitSignal`: quits when this app's own update script still runs and the status file says
    /// ready (this app's own asks may not have gone through); any other signal does nothing.
    func scriptAskedToQuit() {
        guard process?.isRunning == true, readStatus() == .ready else { return }
        if readyAt == nil { sawReady(hold: false) } else { askToQuit() }
        startPolling()
    }

    /// Check now clears a shown failure and "Updated to <commit>".
    func clearNotice() {
        switch phase {
        case .failed, .updated: phase = .idle
        default: break
        }
    }

    // MARK: The feed (P825, P826)

    /// The feed's run, as the control shows it. At ready the control completes and says Updated for `finishHold`, then
    /// the feed quits the app, installs and opens the new version; still here after `quitPatience`, the owner is asked
    /// (Restart to update), as in an update of the private app.
    func feedFollow(_ run: FeedRun) {
        let wasReady = phase == .restarting || phase == .restartNeeded
        phase = run.phase
        progress = run.progress
        guard run.phase == .restarting, !wasReady else { return }
        finishing?.cancel()
        let hold = finishHold, patience = quitPatience
        finishing = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, let self, self.phase == .restarting else { return }
            self.feed?.relaunch()
            try? await Task.sleep(for: .seconds(patience))
            guard !Task.isCancelled, self.phase == .restarting else { return }
            self.feed?.askOwner()
        }
    }

    /// The feed's run failed: the app stays as it is, and About says why (no log of ours: the feed's is its own).
    func feedFailed(_ reason: String) {
        finishing?.cancel()
        phase = .failed(reason: reason)
        progress = .none
    }

    /// This launch is the version the feed installed: "Updated to <version>", once.
    func feedUpdated(_ version: String) {
        showUpdated(version)
    }

    // MARK: Private

    private func startPolling() {
        polling?.cancel()
        let interval = pollInterval
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.phase.isRunning else { return }
                self.poll()
            }
        }
    }

    /// Ready: the control completes and says Updated (`hold`: for `finishHold`, so the end shows), then the app asks
    /// to quit. The second ask (`quitRetry`) and the owner's (`quitPatience`) count from ready as before; an ask that
    /// came first, a failure or the owner's click meanwhile leave nothing for the held one to do.
    private func sawReady(hold: Bool = true) {
        guard readyAt == nil else { return }
        let ready = now()
        readyAt = ready
        phase = .restarting
        refreshProgress()
        JuiceLog.update.notice("update ready: the app quits for it")
        finishing?.cancel()
        guard hold, finishHold > .zero else { return askToQuit() }
        let wait = finishHold
        finishing = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.readyAt == ready, self.phase.isRunning, self.quitAsks == 0 else { return }
            self.askToQuit()
        }
    }

    /// Past ready: the second ask at `quitRetry`; the owner's at `quitPatience`.
    private func followQuit(since ready: Date) {
        let waited = now().timeIntervalSince(ready)
        if quitAsks < 2, waited >= quitRetry { askToQuit() }
        if phase == .restarting, waited >= quitPatience {
            JuiceLog.update.error("the app did not quit \(Int(waited), privacy: .public) s after ready: the owner is asked")
            phase = .restartNeeded
        }
    }

    private func askToQuit() {
        quitAsks += 1
        let asks = quitAsks
        JuiceLog.update.notice("asking the app to quit (\(asks, privacy: .public))")
        quit()
    }

    /// `done` before `ready`: the running build is already origin/main's commit, so nothing was built; the check runs
    /// again.
    private func finishUpToDate() {
        polling?.cancel()
        phase = .idle
        refreshProgress()
        recheck()
    }

    /// The script ended while this app runs: it never swapped the bundle (past ready it ends only after the app quit),
    /// so the run failed, with the status file's reason when it wrote one. A script gone past ready (killed, or ended
    /// without its failed line) is a failure before the file is followed: only it swaps the bundle and opens the new
    /// build, so quitting for it would leave no app running.
    private func scriptExited(_ status: Int32) {
        process = nil
        guard phase.isRunning else { return }
        switch readStatus() {
        case .ready?, .installing?, .restarting?: break
        default: poll()
        }
        guard phase.isRunning else { return }
        JuiceLog.update.error("update-app.sh ended with exit \(status, privacy: .public) while the update ran")
        fail("update-app.sh stopped (exit \(status))")
    }

    /// The reason stays in the UI and update.log; the log says only that it failed.
    private func fail(_ reason: String) {
        polling?.cancel()
        finishing?.cancel()
        readyAt = nil
        JuiceLog.update.error("the update failed (see update.log)")
        phase = .failed(reason: reason)
        refreshProgress()
    }

    private func showUpdated(_ commit: String) {
        JuiceLog.update.notice("updated to \(commit, privacy: .public)")
        phase = .updated(commit)
        updatedExpiry?.cancel()
        let life = updatedLife
        updatedExpiry = Task { [weak self] in
            try? await Task.sleep(for: life)
            guard !Task.isCancelled, let self, case .updated = self.phase else { return }
            self.phase = .idle
        }
    }

    private func readStatus() -> UpdateStatusLine? {
        guard let data = FileManager.default.contents(atPath: paths.statusFile.path) else { return nil }
        return UpdateStatusLine.current(in: String(decoding: data, as: UTF8.self))
    }

    private static func standardized(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.path }

    /// The app's environment plus the status and log paths (the script's `JI_STATUS_FILE` and `JI_LOG_FILE`: the
    /// prepare's own for a prepare), the run's mode (`JI_RUN_MODE`, for a prepare or an install), the quit signal this
    /// app handles (`JI_APP_QUIT_SIGNAL`, only once `UpdateQuitSignal` is installed, never for a prepare, which never
    /// waits for the app to quit), and Homebrew's folders on PATH (a Finder launch has only the system's, and the build
    /// needs xcodegen). Nothing named `JI_UPDATE_…` passes, nor a `JI_RUN_MODE` the app inherited: those are the
    /// script's hand-over to its build stage and its tests' overrides.
    static func environment(paths: Paths, quitSignal: String? = nil, mode: RunMode = .update,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base.filter { !$0.key.hasPrefix("JI_UPDATE_") && $0.key != "JI_RUN_MODE" }
        let prepare = mode == .prepare
        environment["JI_STATUS_FILE"] = (prepare ? paths.prepareStatusFile : paths.statusFile).path
        environment["JI_LOG_FILE"] = (prepare ? paths.prepareLogFile : paths.logFile).path
        environment["JI_APP_QUIT_SIGNAL"] = prepare ? nil : quitSignal
        if mode != .update { environment["JI_RUN_MODE"] = mode.rawValue }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let missing = ["/opt/homebrew/bin", "/usr/local/bin"].filter { !path.split(separator: ":").contains(Substring($0)) }
        environment["PATH"] = (missing + [path]).joined(separator: ":")
        return environment
    }
}
