import Foundation
import Observation

/// The public flavor's updater (P823 to P826): Sparkle 2, which only the public app target links (`PublicApp/`), seen
/// here through this protocol so this library, its tests and the private app never name it. The private app never has
/// one: it updates by building origin/main (`UpdateChecker`, `UpdateController`).
///
/// It reports what it does as `FeedUpdateEvent`s, on the main actor, from `start` on, and never shows a window of its
/// own: the Update control and Settings › About are its only face.
@MainActor
public protocol FeedUpdating: AnyObject {
    /// Starts it: from here it checks once a day by itself and reports through `report`.
    func start(report: @escaping @MainActor (FeedUpdateEvent) -> Void)
    /// Check now: a check the owner asked for (`checking`, then `found`, `upToDate` or `failed`). False when no check
    /// could start (one of the updater's own sessions runs): nothing will answer.
    @discardableResult
    func checkNow() -> Bool
    /// Update, on the update the last check found: download, check and unpack it, or go on with one already downloaded.
    /// False when no found update is held (the session it belonged to ended): the caller checks again.
    func install() -> Bool
    /// After `readyToInstall`: quit, install and open the new version.
    func relaunch()
    /// Settings › About › Install automatically (P1074): on, the updater downloads a new version in the background and
    /// installs it when the app quits (Sparkle's automatic install); off, nothing downloads before the click. Kept until
    /// changed, applied when it starts.
    func setAutomaticInstall(_ on: Bool)
}

extension FeedUpdating {
    func setAutomaticInstall(_ on: Bool) {}
}

/// What the feed's updater says, in the order a run goes.
public enum FeedUpdateEvent: Equatable, Sendable {
    /// When it last checked, at start, from its own record.
    case lastChecked(Date)
    /// A check the owner asked for has started.
    case checking
    /// A newer version: `downloaded` when it is downloaded already (the click then installs at once); `informational`
    /// when the feed only points at a page (the click opens it).
    case found(version: String, downloaded: Bool, informational: Bool)
    case upToDate
    case failed(String)
    case downloadStarted
    case expectedLength(UInt64)
    case received(UInt64)
    /// Unpacking, 0 to 1; at 1 the updater checks the new version's signatures before it says ready.
    case extracting(Double)
    case readyToInstall
    /// The app is asked to quit for the install.
    case installing
    /// The update's session ended: finished, cancelled, or after a failure.
    case ended
    /// Install automatically downloaded this version in the background: it installs when the app quits, and Restart to
    /// update installs it now (P1074).
    case installsOnQuit(version: String)
}

/// The feed's run as the Update control draws it (P825): the updater's stages on the control's own phases, with words
/// of their own ("Downloading 45%", "Extracting", "Installing"), and a fill that never goes back within a run. Ready is
/// the control's end: the fill completes and says Updated, as an update of the private app does at ready.
struct FeedRun: Equatable, Sendable {
    private(set) var phase: UpdatePhase = .idle
    private(set) var progress: UpdateProgress = .none
    private(set) var expected: UInt64 = 0
    private(set) var received: UInt64 = 0

    /// The fill each stage reaches: the download is most of the way, then unpacking, then the signature check.
    static let downloadStart = 0.02
    static let downloadEnd = 0.80
    static let extractEnd = 0.92
    static let checking = 0.95

    var isRunning: Bool { phase.isRunning }

    mutating func apply(_ event: FeedUpdateEvent) {
        switch event {
        case .downloadStarted:
            self = FeedRun()
            set(.pulling, fraction: Self.downloadStart, words: "Downloading")
        case let .expectedLength(length):
            guard phase == .pulling else { return }
            expected = length
            download()
        case let .received(length):
            guard phase == .pulling else { return }
            received += length
            download()
        case let .extracting(share):
            // A download made earlier (the click went on with it) starts here.
            guard phase != .restarting, phase != .restartNeeded else { return }
            if share >= 1 {
                set(.installing, fraction: Self.checking, words: "Installing")
            } else {
                set(.building, fraction: Self.downloadEnd + (Self.extractEnd - Self.downloadEnd) * min(1, max(0, share)),
                    words: "Extracting")
            }
        case .readyToInstall, .installing:
            guard phase != .restartNeeded else { return }
            set(.restarting, fraction: 1, words: nil)
        case .ended:
            // The session ended before ready (a failure says why first): nothing runs. Past ready the app is quitting.
            guard phase != .restarting, phase != .restartNeeded else { return }
            self = FeedRun()
        case .lastChecked, .checking, .found, .upToDate, .failed, .installsOnQuit:
            break
        }
    }

    /// The owner's click, before the updater says anything: a sliver at once, as the private app's "Fetching" shows; an
    /// update downloaded already goes straight to unpacking.
    mutating func begin(downloaded: Bool) {
        apply(downloaded ? .extracting(0) : .downloadStarted)
    }

    /// A check the click started (Retry, or Update with no found update held): a sliver at once that says Checking, so
    /// the control stays under the pointer while the feed looks (P864).
    mutating func beginCheck() {
        self = FeedRun()
        set(.pulling, fraction: Self.checkStart, words: "Checking")
    }

    static let checkStart = 0.01

    /// Past ready, still running after the controller's patience: the owner is asked to restart.
    mutating func askOwner() {
        guard phase == .restarting else { return }
        phase = .restartNeeded
    }

    /// "Downloading 45%" from the bytes so far against the length the feed gave; "Downloading" without one. The
    /// percent stops at 99 until the download ends, since a length can be wrong.
    private mutating func download() {
        guard expected > 0 else { return set(.pulling, fraction: Self.downloadStart, words: "Downloading") }
        let share = min(1, Double(received) / Double(expected))
        set(.pulling, fraction: Self.downloadStart + (Self.downloadEnd - Self.downloadStart) * share,
            words: "Downloading \(min(99, Int(share * 100)))%")
    }

    private mutating func set(_ phase: UpdatePhase, fraction: Double, words: String?) {
        self.phase = phase
        progress = UpdateProgress(fraction: max(progress.fraction, fraction), words: words)
    }
}

/// What the feed keeps across launches, in the app's defaults (tests keep it in memory): the version it was installing
/// when the app quit for it, so the new version says "Updated to <version>" once (P826); and the version its last check
/// found, offered again after a relaunch until a check says otherwise (P863).
struct FeedMemory {
    var load: @MainActor () -> String?
    var save: @MainActor (String?) -> Void
    var loadOffered: @MainActor () -> String?
    var saveOffered: @MainActor (String?) -> Void

    static let key = "ji.update.feedInstalling"
    static let offeredKey = "ji.update.feedOffered"

    static var standard: FeedMemory {
        FeedMemory(load: { UserDefaults.standard.string(forKey: key) },
                   save: { UserDefaults.standard.set($0, forKey: key) },
                   loadOffered: { UserDefaults.standard.string(forKey: offeredKey) },
                   saveOffered: { UserDefaults.standard.set($0, forKey: offeredKey) })
    }

    @MainActor
    static func inMemory() -> FeedMemory {
        final class Box { var value: String?; var offered: String? }
        let box = Box()
        return FeedMemory(load: { box.value }, save: { box.value = $0 },
                          loadOffered: { box.offered }, saveOffered: { box.offered = $0 })
    }
}

/// Joins the feed's updater to the checker and the controller the Update control and About read (P823 to P826): its
/// checks become the checker's state, its run the controller's phase and progress, and the control's clicks (Check now,
/// Update, Retry, Restart to update) its calls. Nothing here runs git or reads the private app's status files.
@MainActor
final class FeedUpdates {
    let updater: any FeedUpdating
    weak var checker: UpdateChecker?
    weak var controller: UpdateController?
    private(set) var run = FeedRun()
    /// The version the last check found.
    private(set) var offered: String?
    /// That version is only a page to read (the click opens it): nothing downloads.
    private var informational = false
    /// Retry after a failure, or an Update whose found update is no longer held: install once the check finds it. While
    /// it holds, the run is that check's sliver ("Checking").
    private var installWhenFound = false
    private var started = false
    private let runningVersion: String?
    private let memory: FeedMemory
    private let now: @MainActor () -> Date

    init(updater: any FeedUpdating, runningVersion: String?, memory: FeedMemory = .standard,
         now: @escaping @MainActor () -> Date = { Date() }) {
        self.updater = updater
        self.runningVersion = runningVersion
        self.memory = memory
        self.now = now
    }

    /// Settings › About › Install automatically, handed to the updater now and whenever it changes (P1074).
    func followAutomaticInstall(_ settings: AppSettings) {
        withObservationTracking { updater.setAutomaticInstall(settings.installAutomatically) } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.followAutomaticInstall(settings) }
        }
    }

    /// Joins the two and the updater; the app calls this once, from `UpdateChecker.start`.
    static func join(_ updates: FeedUpdates, checker: UpdateChecker, controller: UpdateController) {
        updates.checker = checker
        updates.controller = controller
        checker.feed = updates
        controller.feed = updates
    }

    /// Starts the updater (its daily check is its own), and says "Updated to <version>" once when this launch is the
    /// version it was installing.
    func start() {
        guard !started else { return }
        started = true
        if let installing = memory.load() {
            memory.save(nil)
            if installing == runningVersion { controller?.feedUpdated(installing) }
        }
        updater.start { [weak self] event in self?.handle(event) }
    }

    func checkNow() {
        controller?.clearNotice()
        updater.checkNow()
    }

    /// Update (or Restart to update, with the update downloaded already).
    func install() {
        guard !run.isRunning else { return }
        let held = updater.install()
        guard !informational else { return }
        if held { return begin() }
        checkThenInstall()
    }

    /// A check whose update installs as it is found; the control says Checking meanwhile (P864).
    private func checkThenInstall() {
        installWhenFound = true
        run.beginCheck()
        controller?.feedFollow(run)
        guard updater.checkNow() else { return endCheck() }
    }

    /// The click's check is over without an update to install: the control goes back to what the checker says.
    private func endCheck() {
        guard installWhenFound else { return }
        installWhenFound = false
        run = FeedRun()
        controller?.feedFollow(run)
    }

    private func begin() {
        run.begin(downloaded: checker?.available?.downloaded ?? false)
        controller?.feedFollow(run)
    }

    /// Retry: a new check, which installs what it finds.
    func retry() {
        guard !run.isRunning else { return }
        controller?.clearNotice()
        checkThenInstall()
    }

    /// Past ready: quit and install.
    func relaunch() {
        updater.relaunch()
    }

    /// The owner was asked to restart (the app did not quit for the install).
    func askOwner() {
        run.askOwner()
        controller?.feedFollow(run)
    }

    func handle(_ event: FeedUpdateEvent) {
        switch event {
        case let .lastChecked(date):
            guard checker?.state == .idle else { return }
            // The date is of the last check, whatever it found: what it found is the memory's (P863).
            if let remembered = memory.loadOffered(), Self.isNewer(remembered, than: runningVersion) {
                offered = remembered
                checker?.report(.checked(UpdateInfo(newer: 0, subjects: [], version: remembered), at: date))
            } else {
                memory.saveOffered(nil)
                checker?.report(.checked(UpdateInfo(newer: 0, subjects: []), at: date))
            }
        case .checking:
            if !run.isRunning { checker?.report(.checking) }
        case let .found(version, downloaded, page):
            offered = version
            informational = page
            memory.saveOffered(page ? nil : version)
            checker?.report(.checked(UpdateInfo(newer: 0, subjects: [], version: version, downloaded: downloaded), at: now()))
            // Retry, or an Update whose session had ended: this check's update installs now (never a second check).
            if installWhenFound {
                if !page, updater.install() {
                    installWhenFound = false
                    begin()
                } else {
                    endCheck()
                }
            }
        case .upToDate:
            endCheck()
            memory.saveOffered(nil)
            guard !run.isRunning else { return }
            offered = nil
            informational = false
            checker?.report(.checked(UpdateInfo(newer: 0, subjects: []), at: now()))
        case let .failed(reason):
            installWhenFound = false
            if run.isRunning, run.phase != .restarting, run.phase != .restartNeeded {
                run = FeedRun()
                controller?.feedFailed(reason)
            } else if !run.isRunning {
                checker?.report(.failed(reason, at: now()))
            }
        case .readyToInstall:
            run.apply(event)
            if let offered { memory.save(offered) }
            controller?.feedFollow(run)
        case let .installsOnQuit(version):
            // Downloaded by itself: Restart to update installs it now; a quit installs it, and the next launch says so.
            checker?.installsOnQuit = version
            offered = version
            informational = false
            memory.saveOffered(version)
            memory.save(version)
            guard !run.isRunning else { return }
            checker?.report(.checked(UpdateInfo(newer: 0, subjects: [], version: version, downloaded: true), at: now()))
        default:
            let before = run
            run.apply(event)
            // A session that ended with no answer to the click's check: nothing installs on a later find.
            if !run.isRunning { installWhenFound = false }
            if run != before { controller?.feedFollow(run) }
        }
    }

    /// `version` is above `running` (nil: unknown, so any version is), comparing numbers part by part ("1.10" is above
    /// "1.9", "1.3" is "1.3.0"); versions that are not numbers count as newer only when they differ.
    static func isNewer(_ version: String, than running: String?) -> Bool {
        guard let running else { return true }
        let parts = { (text: String) in text.split(separator: ".").map { Int($0) } }
        let a = parts(version), b = parts(running)
        guard !a.contains(nil), !b.contains(nil) else { return version != running }
        for i in 0 ..< max(a.count, b.count) {
            let x = i < a.count ? a[i]! : 0, y = i < b.count ? b[i]! : 0
            if x != y { return x > y }
        }
        return false
    }
}
