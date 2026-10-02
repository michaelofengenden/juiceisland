import Foundation
import IslandEngine
import JuiceCore
import Observation

/// The profiles the app works with: Juice's accounts (its accounts file, only ever read) plus every profile folder
/// in the home folder (stat-only discovery, `ProfileFolderDiscovery`). Setup's rows, the drift checks and the live
/// engine's account tags all come from here (spec §3.5, §3.6). It reloads when the accounts file or the home folder
/// changes, 2 s after the last change, and tells `onChange` when the list is different. P119: the home folder changes
/// all the time (every Claude session rewrites `~/.claude.json` there), so a reload after a change runs off the main
/// thread and looks only at profile folders (`~/.claude*`, `~/.codex*`) and the accounts file; the main thread only
/// takes a list that differs.
@MainActor
@Observable
final class ProfileDirectory {
    private(set) var profiles = LiveProfiles(accounts: [], discovered: [])
    private(set) var targets: [ProfileHookTarget] = []

    @ObservationIgnored private let load: @Sendable () -> LiveProfiles
    @ObservationIgnored private let home: String
    @ObservationIgnored private let watchedFolders: [(folder: String, files: [String])]
    @ObservationIgnored private let watch: @MainActor (String, [String], @escaping @MainActor @Sendable () -> Void) -> (any HookWatchToken)?
    @ObservationIgnored private let schedule: HookDriftMonitor.Schedule
    @ObservationIgnored private var tokens: [any HookWatchToken] = []
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var generation = 0
    /// The reload a change started, off the main thread; tests await it.
    @ObservationIgnored private(set) var reloading: Task<Void, Never>?
    /// Called with the new targets whenever a reload finds a different list.
    @ObservationIgnored var onChange: [@MainActor ([ProfileHookTarget]) -> Void] = []

    init(load: @escaping @Sendable () -> LiveProfiles, home: String = NSHomeDirectory(),
         watchedFolders: [(folder: String, files: [String])] = [],
         watch: @escaping @MainActor (String, [String], @escaping @MainActor @Sendable () -> Void) -> (any HookWatchToken)? = { _, _, _ in nil },
         schedule: @escaping HookDriftMonitor.Schedule = HookDriftMonitor.sleepThenRun) {
        self.load = load
        self.home = home
        self.watchedFolders = watchedFolders
        self.watch = watch
        self.schedule = schedule
    }

    /// The app's: Juice's accounts file and the home folder, watched for new or removed profiles.
    static func app() -> ProfileDirectory {
        let accounts = AccountsStore.defaultFileURL
        return ProfileDirectory(load: { LiveProfiles.load() },
                                watchedFolders: [(accounts.deletingLastPathComponent().path, [accounts.lastPathComponent]),
                                                 (NSHomeDirectory(), [])],
                                watch: { folder, files, onChange in ConfigFolderWatcher(folder: folder, files: files, onChange: onChange) })
    }

    /// The profiles now, read on first use.
    var current: LiveProfiles {
        if !loaded { reload() }
        return profiles
    }

    /// Starts watching the accounts file and the home folder.
    func activate() {
        if !loaded { reload() }
        guard tokens.isEmpty else { return }
        tokens = watchedFolders.compactMap { folder, files in
            watch(folder, files) { [weak self] in self?.folderChanged() }
        }
    }

    func stop() {
        for token in tokens { token.cancel() }
        tokens = []
        generation += 1
        reloading?.cancel()
        reloading = nil
    }

    /// Reads the profiles again, here; returns whether the list of profile folders changed. The first read tells no
    /// one: launch checks every profile anyway.
    @discardableResult
    func reload() -> Bool {
        take(load())
    }

    /// A change in a watched folder: reload once it has been quiet for 2 s, off the main thread.
    func folderChanged() {
        generation += 1
        let mine = generation
        schedule(HookDriftSchedule.quietPeriod) { [weak self] in
            guard let self, self.generation == mine else { return }
            let load = self.load
            self.reloading = Task { [weak self] in
                let fresh = await Task.detached(priority: .utility) { load() }.value
                guard let self, self.generation == mine else { return }
                self.reloading = nil
                self.take(fresh)
            }
        }
    }

    /// Takes a fresh read: nothing happens unless it differs from the list held.
    @discardableResult
    private func take(_ fresh: LiveProfiles) -> Bool {
        let wasLoaded = loaded
        loaded = true
        guard !wasLoaded || fresh != profiles else { return false }
        let freshTargets = ProfileHookTargets.make(accounts: fresh.accounts, discovered: fresh.discovered, home: home)
        let changed = freshTargets != targets
        profiles = fresh
        targets = freshTargets
        if changed, wasLoaded {
            JuiceLog.profiles.notice("""
                profiles changed: \(fresh.accounts.count, privacy: .public) accounts, \(freshTargets.count, privacy: .public) \
                profile folders
                """)
            for handler in onChange { handler(freshTargets) }
        }
        return changed
    }
}
