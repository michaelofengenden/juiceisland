import Foundation
import Observation

/// What a check found against origin/main, fetched just before: the commits of origin/main the running build lacks
/// (`<build>..origin/main`: never a commit that is only in the local repository), their subjects (newest first, up to
/// 10), whether the build is origin/main's own at all, and origin/main's commit then (what a background prepare
/// builds and Restart to update must match, P711).
struct UpdateInfo: Equatable, Sendable {
    var newer: Int
    var subjects: [String]
    /// The running build had uncommitted changes on top of its commit.
    var dirty = false
    /// The build's commit is not on origin/main: another branch, or commits that were never pushed.
    var offMain = false
    /// origin/main's commit, as the check fetched it; nil where no check made it (renders).
    var tip: String?
    /// The public flavor's feed (P823): the newer version it offers, and whether it is downloaded already (the click
    /// then installs it at once: Restart to update). Never set by the private app's check.
    var version: String?
    var downloaded = false

    /// Update is offered: origin/main has commits the build lacks, or the build is not one origin/main made; in the public
    /// flavor, the feed has a newer version.
    var isAvailable: Bool { newer > 0 || dirty || offMain || version != nil }
}

enum UpdateCheckState: Equatable, Sendable {
    case idle
    case checking
    case checked(UpdateInfo, at: Date)
    /// A short reason (no repository, git missing, unknown build); never an alert.
    case failed(String, at: Date)
}

/// Compares the running build's commit with origin/main of the owner's repository (P134): fetches origin's main into
/// origin/main first (`git fetch --quiet --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main`, ssh in
/// BatchMode, P117), then counts and lists `<build>..origin/main`. The local main is never read: a fetch that fails
/// is "Can't reach GitHub", with no count. Only reads the repository (and the fetch moves origin/main); never checks
/// out, merges, writes the working tree or the index, or writes FETCH_HEAD. Runs at launch, every hour and on Check now.
///
/// The public flavor (P823, P824) never runs git: its checks are the feed's (`feed`, Sparkle's daily check and Check now,
/// reported through `report`), and a public build made without the feed's key checks nothing (`off`).
@MainActor
@Observable
final class UpdateChecker {
    static let interval: TimeInterval = 3_600
    static let maxSubjects = 10

    let stamp: BuildStamp
    private(set) var state: UpdateCheckState
    /// About's list of the new changes shows (its disclosure; collapsed until the owner opens it).
    var showsChanges = false
    /// While this holds (an update runs), no check starts: its fetch would race the script's, which then has to try
    /// again to lock origin/main. The app's controller sets it.
    @ObservationIgnored var holds: @MainActor () -> Bool = { false }
    /// After each check that ends with a result (the app's controller may then prepare the update, P710).
    @ObservationIgnored var checked: @MainActor () -> Void = {}
    /// The public flavor's feed: Check now and the daily check are its own (`FeedUpdates.join`).
    @ObservationIgnored var feed: FeedUpdates?
    /// The version the feed downloaded by itself, which installs when the app quits whatever Install automatically says
    /// by then (Sparkle's rule, P1074); nil while none waits. About's line names it (W3R-6).
    var installsOnQuit: String?
    /// A public build made without the feed's key: updates are off, and About says so.
    let off: Bool

    @ObservationIgnored private let git: any GitRunning
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var running: Task<Void, Never>?

    init(stamp: BuildStamp, git: any GitRunning = ProcessGitRunner(), state: UpdateCheckState = .idle, off: Bool = false,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.stamp = stamp
        self.off = off
        self.git = git
        self.state = state
        self.now = now
    }

    /// The newer commits, when there are any.
    var available: UpdateInfo? {
        if case let .checked(info, _) = state, info.isAvailable { return info }
        return nil
    }

    /// Where updates come from: the owner's repository, the public flavor's feed, or nowhere.
    enum Source: Equatable { case git, feed, off }

    var source: Source { off ? .off : feed != nil ? .feed : .git }

    /// The feed's result (`FeedUpdates`).
    func report(_ state: UpdateCheckState) {
        self.state = state
    }

    /// Checks now and then every hour. The app calls this once, at launch. The feed checks once a day by itself.
    func start() {
        guard !off else { return }
        if let feed { return feed.start() }
        checkNow()
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Starts a check unless one is running or an update holds it off; returns the check it started (tests await it).
    @discardableResult
    func checkNow() -> Task<Void, Never>? {
        guard !off else { return nil }
        if let feed {
            feed.checkNow()
            return nil
        }
        guard running == nil, !holds() else { return nil }
        let task = Task { [weak self] in
            await self?.check()
            self?.running = nil
        }
        running = task
        return task
    }

    /// One check, start to end (tests await this).
    func check() async {
        state = .checking
        let result = await Self.compare(stamp: stamp, git: git)
        switch result {
        case let .success(info): state = .checked(info, at: now())
        case let .failure(reason): state = .failed(reason.text, at: now())
        }
        checked()
    }

    struct Reason: Error, Equatable { let text: String }

    nonisolated static let unreachable = "Can't reach GitHub"
    /// What the check fetches: origin's main into origin/main, forced (origin/main may have been force-moved), with no
    /// FETCH_HEAD, which belongs to whoever works in the checkout.
    nonisolated static let fetch = ["fetch", "--quiet", "--no-write-fetch-head", "origin", "+refs/heads/main:refs/remotes/origin/main"]

    /// The comparison itself, over any git runner. `retryDelay`: the wait before the fetch's second try (P718).
    nonisolated static func compare(stamp: BuildStamp, git: any GitRunning,
                                    retryDelay: Duration = .seconds(2)) async -> Result<UpdateInfo, Reason> {
        guard let commit = stamp.commit, let repo = stamp.repoPath else {
            return .failure(Reason(text: "Unknown build: no commit stamp to compare"))
        }
        func run(_ arguments: [String], timeout: TimeInterval = 20) async -> GitOutput {
            await git.run(["-C", repo] + arguments, timeout: timeout)
        }
        let gitDir = await run(["rev-parse", "--git-dir"])
        if gitDir.launchFailed { return .failure(Reason(text: "git not found")) }
        guard gitDir.ok else { return .failure(Reason(text: "No git repository at \(Self.abbreviate(repo))")) }

        var fetched = await run(fetch, timeout: 45)
        // A background prepare's fetch at the same moment holds origin/main's lock (P718): one more try after 2 s, as
        // the updater's own fetch does, before a lock is taken for one a stopped git left.
        if !fetched.ok, fetched.stderr.contains("Unable to create '") {
            try? await Task.sleep(for: retryDelay)
            fetched = await run(fetch, timeout: 45)
        }
        guard fetched.ok else { return .failure(Reason(text: fetchFailure(fetched.stderr))) }
        let origin = await run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/main^{commit}"])
        guard origin.ok, !origin.firstLine.isEmpty else { return .failure(Reason(text: "origin has no main")) }
        let tip = origin.firstLine
        guard await run(["cat-file", "-e", "\(commit)^{commit}"]).ok else {
            return .failure(Reason(text: "Build \(commit.prefix(7)) is not in the repository"))
        }

        let range = [tip, "^\(commit)"]
        let count = await run(["rev-list", "--count"] + range)
        guard count.ok, let newer = Int(count.firstLine.trimmingCharacters(in: .whitespaces)) else {
            return .failure(Reason(text: "Could not count the new changes"))
        }
        // Exit 1: the build's commit is not in origin/main's history.
        let offMain = await run(["merge-base", "--is-ancestor", commit, tip]).status == 1
        var subjects: [String] = []
        if newer > 0 {
            let log = await run(["log", "--format=%s", "-n", "\(maxSubjects)"] + range)
            subjects = log.ok ? log.stdout.split(whereSeparator: \.isNewline).map(String.init) : []
        }
        return .success(UpdateInfo(newer: newer, subjects: subjects, dirty: stamp.dirty, offMain: offMain, tip: tip))
    }

    /// Why a fetch failed: a ref lock git left in the repository that is still there (a git stopped mid-fetch; every
    /// fetch fails, the updater's too, until it is deleted) is named, never taken for GitHub out of reach.
    nonisolated static func fetchFailure(_ stderr: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                                         home: String = NSHomeDirectory()) -> String {
        guard let range = stderr.range(of: #"Unable to create '[^']*\.lock'"#, options: .regularExpression) else { return unreachable }
        let lock = String(stderr[range].dropFirst("Unable to create '".count).dropLast())
        return exists(lock) ? "Git's lock \(abbreviate(lock, home: home)) is left over; delete it" : unreachable
    }

    nonisolated static func abbreviate(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
