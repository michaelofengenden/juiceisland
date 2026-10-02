import Foundation
import JuiceCore
import Observation

/// Batteries read by Juice Island itself (the release identity only, `UsageModelKind`): JuiceCore's readers, and
/// standalone Juice's own store (`~/Library/Application Support/Juice`), so every wait and reading carries over in both
/// directions.
///
/// - The unit is the login, not the folder (P93). A login is what a CLI reports signed in (`LoginsStore`): its email, and
///   for Claude the organization it is in (P580: one email in a personal plan and in a Team organization is two logins,
///   two batteries, each read on its own floor; a login from before organizations were named takes its organization's
///   id, with its record, waits, switch and history, from the first answer that names one). Several
///   folders can hold one login at once, a folder can change login over time, and a folder can be signed out. Each
///   login is read once per floor window, through the one of its folders whose login file changed last (a `stat`, so
///   the freshest token is used); a folder found signed out or holding another login is left for the next one. Its
///   waits, 429 pause, backoff and readings are its own (`RefreshScheduler` schedules logins), and so is its Monitor
///   switch. A folder that is enabled but not placed yet gets one question (`identify`, no usage read).
/// - Floors, pauses and backoff are `RefreshScheduler`'s (Claude 300 s, 120 s boosted; Codex 60/30/15 s;
///   Retry-After + 900 s). A start seeds a fresh scheduler from logins.json, which restores a saved 429 pause, the
///   sign-in delay and the backoff (§7 amendment 3), and counts each floor from the last reading, whoever made it.
/// - Every CLI starts through JuiceCore (`CLIEnvironment.make`, so the island skip variables are set). Claude: the
///   `get_usage` control request and `claude auth status`. Codex: one app-server per login read, in the folder it is
///   read through; a folder only asked who is signed in has its app-server stopped again, and so does one asked nothing
///   for 2 min, with at most four up at once (P110). `account/read {refreshToken:false}` and `account/rateLimits/read`
///   only, every read through its provider's identity watch (§7 amendment 8).
/// - Every enabled folder is looked at on the clock (`checkFolders`): a `stat` of its login file, and a question when it
///   changed, on the watches' terms. A folder that changes login joins the other one.
/// - readings.json keeps each folder's login's record (`LoginsStore.projection`), so standalone Juice and dev builds read
///   what they always read, and what they wrote is folded back in (`LoginsStore.fold`).
/// - Each login's readings also go into usage-history.json (`UsageHistoryStore`, P125), which gives the batteries their
///   run-outs and sparklines and raises the island's quota notices, from the readings already made.
/// - Never two Juice readers at once (spec §5.3): while standalone Juice runs nothing is started, the store is only
///   mirrored, edits wait, and `refreshUnavailableReason` says so. Readers start by themselves once Juice quits, and
///   stop (recording nothing) if Juice starts.
/// - Money has no readers here yet: every source is not connected (rails).
@MainActor
@Observable
final class LiveUsageModel: UsageModel {
    enum Phase: Equatable, Sendable {
        /// Not started, or stopped (another usage source, or quitting).
        case idle
        /// Standalone Juice runs: its files are mirrored, nothing is read here.
        case waitingForJuice
        /// The readers run (or are being wired).
        case reading
    }

    static let juiceRunningText = "Juice is running — quit it to read here"

    // MARK: UsageModel

    /// A battery per monitored login (`LoginList.panelEntries`), whose ids are login ids.
    private(set) var panel: PanelModel
    private(set) var now: Date
    /// Every profile folder in the user's order (accounts.json), enabled or not.
    var accounts: [Account] { accountsStore.accounts }
    /// Each login's record by login id, and readings.json's by folder id (each folder's login's record, as standalone
    /// Juice reads it).
    private(set) var records: [String: AccountRecord] = [:]
    let moneyDetails: [String: MoneyDetail] = JuiceReadingsUsageModel.notConnectedDetails
    /// Ids of the folders signing in.
    var signingIn: Set<String> { signInCoordinator.activeAccount.map { [$0.id] } ?? [] }
    /// "Refreshing n of m…": the read the batch is on, while a Refresh all runs.
    var refreshProgress: Int? {
        guard phase == .reading, scheduler.isBatchRunning else { return nil }
        return min(scheduler.batchDone + 1, scheduler.batchTotal)
    }
    /// Only the logins this Refresh all reads: one read too recently stays out of the batch (P68).
    var refreshTotal: Int { scheduler.batchTotal }
    var refreshUnavailableReason: String? { phase == .waitingForJuice ? Self.juiceRunningText : nil }

    // MARK: Accounts (Settings › Accounts)

    /// One part per provider: its logins (label, plan, battery, Monitor switch, folders), then its enabled folders that
    /// are signed out or not asked yet (`LoginList`).
    private(set) var logins: [ProviderLogins] = []
    /// Folders not placed yet that are being asked who is signed in, or will be on the clock's next look: their CLI was
    /// found (or is still being looked for), and no question of theirs has failed. Settings shows "…" for these only.
    private(set) var asking: Set<String> = []
    /// Folders not placed yet whose question failed or named no email; they are asked again after the read backoff, and
    /// Settings offers Sign In.
    private(set) var unanswered: Set<String> = []
    /// Providers with an enabled folder whose CLI the last search did not find: nothing of theirs can be asked or read.
    private(set) var missingCLIs: [Provider] = []
    /// Every provider whose CLI the last search did not find, folders or not: "+" has nothing to sign in with.
    private(set) var cliNotFound: [Provider] = []
    /// The "+" row: its provider and the name typed so far; nil while it is closed.
    var newAccount: NewAccountDraft?
    /// Folders "+" made in this run: their rows offer Setup's Install for session hooks while Setup would (a click; nothing
    /// installs by itself), until that line is closed.
    private(set) var added: Set<String> = []

    // MARK: State

    private(set) var phase: Phase = .idle
    let accountsStore: AccountsStore
    let readingsStore: ReadingsStore
    /// `logins.json`: every login, its record and Monitor switch, and which login each folder holds.
    let loginsStore: LoginsStore
    /// `forgotten.json`: the folders Forget took out, never offered with Add again until "+" names one.
    let forgottenStore: ForgottenFoldersStore
    /// A fresh one on every start, seeded from logins.json. It schedules logins (`ReadTarget` ids are login ids).
    private(set) var scheduler: RefreshScheduler
    /// `usage-history.json`: each login's recent readings and the quota notices given (P125).
    let historyStore: UsageHistoryStore
    /// Juice spec §7: one flow at a time, the vendor's own login in the folder.
    let signInCoordinator: SignInCoordinator
    private(set) var claudeExecutable: URL?
    private(set) var codexExecutable: URL?
    /// Profile folders found on this Mac (the last `refreshDiscovery()`).
    private(set) var found: [DiscoveredProfile] = []

    @ObservationIgnored let directory: URL
    @ObservationIgnored let storeWriter: StoreWriter?
    @ObservationIgnored private let readers: LiveReaders
    @ObservationIgnored private let juiceGuard: StandaloneJuiceGuard
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let makeScheduler: @MainActor () -> RefreshScheduler
    @ObservationIgnored private var codex: CodexBackend?
    @ObservationIgnored private var codexWatch: CodexIdentityWatch?
    @ObservationIgnored private var claudeWatch: ClaudeIdentityWatch?
    /// The folder checks and questions started by the last tick (`checkFolders`); tests await it.
    @ObservationIgnored private(set) var loginCheck: Task<Void, Never>?
    /// The Codex app-servers being stopped (`pruneCodexServers`), one after another; tests await it.
    @ObservationIgnored private(set) var stopping: Task<Void, Never>?
    /// Folders whose CLI answered in this run (a question, a read's own question, a reading that named its login): the
    /// login they hold is known, not just remembered.
    @ObservationIgnored private var answered: Set<String> = []
    /// When a folder whose question failed may be asked again, and how many times it failed.
    @ObservationIgnored private var askAgainAt: [String: Date] = [:]
    @ObservationIgnored private var askFailures: [String: Int] = [:]
    /// When each folder was last found signed out in this run: after the sign-in delay it is asked again, since a read's
    /// sign-in failure can pass without its login file changing.
    @ObservationIgnored private var signedOutAt: [String: Date] = [:]
    /// The folder each login was last read through (folder ids by login id).
    @ObservationIgnored private var readThrough: [String: String] = [:]
    /// Logins that took their organization's id (P580) while a read of them ran, by the id they had: that read is the
    /// login's under its new one. Taken when the read ends.
    @ObservationIgnored private var renamedLogins: [String: String] = [:]
    /// Reads running, by folder id: the login each is for.
    @ObservationIgnored private var readingNow: [String: String] = [:]
    /// Codex homes that may have an app-server running: read or asked in this run and not stopped since.
    @ObservationIgnored private var codexServing: Set<String> = []
    /// Bumped by every start and stop, so a CLI search that finishes late wires nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isActive = false
    /// The history is read from its file at the first start only: after that, memory is newer.
    @ObservationIgnored private var historyLoaded = false
    /// When each login's activity boost was last renewed (`sessionsAtWork`).
    @ObservationIgnored private var boostRenewed: [String: Date] = [:]
    /// Between `willSleep` and `didWake`: a scheduler made in between starts paused too.
    @ObservationIgnored private var isAsleep = false
    /// When `willSleep` came, and the clock's ticks since: the clock does not tick while the Mac sleeps, so ticks that
    /// go on long after it are a wake nobody announced (`missedWakeAfter`).
    @ObservationIgnored private var asleepSince: Date?
    @ObservationIgnored private var ticksAsleep = 0
    /// P118: a sleep whose wake never came (a sleep that was called off, a lost `didWakeNotification`) is taken as over
    /// once the clock has ticked twice since `willSleep` and this long has passed, so reads never stay paused for good.
    static let missedWakeAfter: TimeInterval = 60
    /// What `NSWorkspace`'s notifications said before its list of running apps caught up (P69): a standalone Juice that
    /// just launched counts as running until the list shows it or it quits (at most `launchGrace`); one that just quit
    /// counts as gone while the list still shows it.
    @ObservationIgnored private var launchedJuice: [pid_t: Date] = [:]
    @ObservationIgnored private var terminatedJuice: Set<pid_t> = []
    static let launchGrace: TimeInterval = 30
    @ObservationIgnored private var timer: Timer?
    /// The CLI search of the current start or refresh; tests await it.
    @ObservationIgnored private(set) var wiring: Task<Void, Never>?
    /// The search for a CLI a read found missing (`relocate`); tests await it.
    @ObservationIgnored private(set) var relocation: Task<Void, Never>?
    @ObservationIgnored private var relocating: Set<Provider> = []
    @ObservationIgnored private(set) var discovery: Task<Void, Never>?

    /// `makeScheduler` builds each start's scheduler (the app's reads real time; tests pass a clock). `storeWriter`
    /// writes accounts.json, readings.json and logins.json off the main thread, a file's changes within a second as one
    /// write, and only a file that changed (nil writes each save at once, as tests do).
    init(directory: URL = JuiceReadingsUsageModel.defaultDirectory, readers: LiveReaders,
         juiceGuard: StandaloneJuiceGuard = .system, clock: @escaping () -> Date = { Date() },
         makeScheduler: @escaping @MainActor () -> RefreshScheduler = { RefreshScheduler() },
         storeWriter: StoreWriter? = StoreWriter()) {
        self.directory = directory
        self.readers = readers
        self.juiceGuard = juiceGuard
        self.clock = clock
        self.makeScheduler = makeScheduler
        self.storeWriter = storeWriter
        accountsStore = AccountsStore(fileURL: directory.appendingPathComponent("accounts.json"))
        readingsStore = ReadingsStore(fileURL: directory.appendingPathComponent("readings.json"))
        loginsStore = LoginsStore(fileURL: directory.appendingPathComponent("logins.json"))
        accountsStore.writer = storeWriter
        readingsStore.writer = storeWriter
        loginsStore.writer = storeWriter
        forgottenStore = ForgottenFoldersStore(fileURL: directory.appendingPathComponent("forgotten.json"))
        historyStore = UsageHistoryStore(fileURL: UsageHistoryStore.file(in: directory), clock: clock)
        scheduler = makeScheduler()
        signInCoordinator = SignInCoordinator(configuration: .init(claudeExecutable: nil, codexExecutable: nil),
                                              identity: LiveIdentityChecker(claude: readers.claudeIdentity(nil), codex: nil))
        let start = clock()
        now = start
        panel = PanelModelBuilder.build(accounts: [], records: [:], signingIn: [], money: MoneyRowModel.notConnected, now: start)
        signInCoordinator.onFinished = { [weak self] account, phase in self?.signInFinished(account, phase) }
    }

    // MARK: Start and stop

    /// Loads the store and starts reading, unless standalone Juice runs; then waits for it to quit. Safe to call twice.
    func start() {
        guard !isActive else { return }
        isActive = true
        accountsStore.load()
        readingsStore.load()
        loginsStore.load()
        forgottenStore.load()
        if !historyLoaded {
            historyLoaded = true
            historyStore.load()
        }
        readers.systemEvents?.install(.init(
            appLaunched: { [weak self] app in self?.appLaunched(app) },
            appTerminated: { [weak self] app in self?.appTerminated(app) },
            willSleep: { [weak self] in self?.willSleep() },
            didWake: { [weak self] in self?.didWake() }))
        if let interval = readers.tickInterval {
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
                guard let self else { return timer.invalidate() }
                MainActor.assumeIsolated { self.tick() }
            }
        }
        evaluateGuard()
    }

    /// Stops reading (another usage source was chosen). Reads in flight record nothing; the app-servers stop.
    func stop() {
        guard let backend = deactivate() else { return }
        Task { await backend.shutdownAll() }
    }

    /// Quitting: `stop()`, waiting for the app-servers to go.
    func shutdown() async {
        await stopForQuit()?()
    }

    /// Quitting, from `applicationShouldTerminate`: the readers stop now, and the app-servers' shutdown comes back for
    /// the quit to wait on off the main actor (nil when nothing reads, P98).
    func stopForQuit() -> (@Sendable () async -> Void)? {
        deactivate()?.shutdownAll
    }

    private func deactivate() -> CodexBackend? {
        guard isActive else { return nil }
        isActive = false
        readers.systemEvents?.uninstall()
        timer?.invalidate()
        timer = nil
        let backend = stopReaders()
        phase = .idle
        rebuild()
        // What waits to be written goes now: the app may be quitting.
        storeWriter?.flush()
        historyStore.flush()
        return backend
    }

    /// Standalone Juice started or quit: re-check, and switch between reading and waiting. The notification counts
    /// before `NSWorkspace`'s list shows the change, so a list that lags never lets both apps read.
    func appLaunched(_ app: RunningAppInfo) {
        guard juiceGuard.isStandaloneJuice(app) else { return }
        terminatedJuice.remove(app.processIdentifier)
        launchedJuice[app.processIdentifier] = clock()
        evaluateGuard()
    }

    func appTerminated(_ app: RunningAppInfo) {
        guard juiceGuard.isStandaloneJuice(app) else { return }
        launchedJuice[app.processIdentifier] = nil
        terminatedJuice.insert(app.processIdentifier)
        evaluateGuard()
    }

    /// Sleep: reads pause (spec §9.5), and stay paused in a scheduler started before the wake.
    func willSleep() {
        if !isAsleep { JuiceLog.reads.info("sleep: reads pause") }
        isAsleep = true
        asleepSince = clock()
        ticksAsleep = 0
        scheduler.pause()
    }

    func didWake() {
        if isAsleep { JuiceLog.reads.info("wake: reads go on") }
        isAsleep = false
        asleepSince = nil
        scheduler.resume()
        if phase == .reading { checkFolders() }
    }

    /// The clock (every 5 s in the app): ages move on, the mirror follows Juice's files while it runs, the guard is
    /// checked again in case a launch or quit notification was missed, and every enabled folder is looked at. A wake
    /// that never came is taken as come (`missedWakeAfter`).
    func tick() {
        guard isActive else { return }
        if isAsleep, let since = asleepSince {
            ticksAsleep += 1
            let asleep = clock().timeIntervalSince(since)
            if ticksAsleep >= 2, asleep >= Self.missedWakeAfter {
                JuiceLog.reads.notice("no wake came \(Int(asleep), privacy: .public) s after sleep: reads go on")
                didWake()
            }
        }
        evaluateGuard()
        if phase == .waitingForJuice { reloadStore() }
        if phase == .reading { checkFolders() }
        rebuild()
    }

    private func evaluateGuard() {
        guard isActive else { return }
        if standaloneJuiceIsRunning() {
            if phase == .reading, let backend = stopReaders() { Task { await backend.shutdownAll() } }
            if phase != .waitingForJuice {
                JuiceLog.reads.notice("standalone Juice runs: reads wait for it to quit")
                phase = .waitingForJuice
                // What waits to be written goes first (P113), so Juice, starting now, finds this run's last readings
                // and pauses on disk, a 429's included.
                storeWriter?.flush()
                historyStore.flush()
                reloadStore()
            }
        } else if phase != .reading {
            JuiceLog.reads.notice("reads start")
            // What Juice saved before it quit is the store now: its reads set this run's floors.
            reloadStore()
            startReaders()
        }
        rebuild()
    }

    /// `NSWorkspace`'s list, corrected by the launch and quit notifications it has not caught up with yet.
    private func standaloneJuiceIsRunning() -> Bool {
        let listed = juiceGuard.runningApps()
        let pids = Set(listed.map(\.processIdentifier))
        terminatedJuice.formIntersection(pids)
        let current = clock()
        launchedJuice = launchedJuice.filter { pid, at in !pids.contains(pid) && current.timeIntervalSince(at) < Self.launchGrace }
        return !launchedJuice.isEmpty || juiceGuard.standaloneJuice(in: listed, excluding: terminatedJuice)
    }

    /// Juice's files, and what they say folded into the logins (in memory: nothing is saved while Juice runs).
    /// logins.json is only this app's, so `start` loads it once.
    private func reloadStore() {
        accountsStore.load()
        readingsStore.load()
        loginsStore.fold(readingsStore.records, accounts: accountsStore.accounts, now: clock())
    }

    /// A fresh scheduler, seeded from logins.json, then the CLI search off the main actor, then the loop. Nothing is
    /// read before the readers are wired (a read with no reader would record "CLI not found").
    private func startReaders() {
        generation += 1
        let current = generation
        scheduler = makeScheduler()
        if isAsleep { scheduler.pause() }
        scheduler.onResult = { [weak self] target, result, at in self?.record(result, for: target, at: at) }
        answered = []
        askAgainAt = [:]
        askFailures = [:]
        signedOutAt = [:]
        readThrough = [:]
        renamedLogins = [:]
        readingNow = [:]
        codexServing = []
        relocating = []
        boostRenewed = [:]
        phase = .reading
        loginsChanged()
        let locate = readers.locate
        wiring = Task { [weak self] in
            let found = await Self.locate(Provider.allCases, with: locate)
            guard let self, self.generation == current, self.phase == .reading else { return }
            self.wiring = nil
            self.wire(found)
            self.scheduler.start()
            // Folders not placed yet are asked at once, not on the clock's first tick.
            self.checkFolders()
            self.rebuild()
        }
    }

    /// Stops the loop (reads in flight record nothing) and any sign-in, and hands back the app-servers to stop.
    private func stopReaders() -> CodexBackend? {
        generation += 1
        wiring?.cancel()
        wiring = nil
        scheduler.stop()
        if signInCoordinator.activeAccount != nil { signInCoordinator.cancel() }
        let backend = codex
        codex = nil
        codexWatch = nil
        claudeWatch = nil
        loginCheck?.cancel()
        loginCheck = nil
        signInCoordinator.identity = LiveIdentityChecker(claude: readers.claudeIdentity(claudeExecutable), codex: nil)
        return backend
    }

    private static func locate(_ providers: [Provider], with locate: @escaping @Sendable (Provider) -> URL?) async -> [Provider: URL] {
        await Task.detached { Dictionary(uniqueKeysWithValues: providers.compactMap { p in locate(p).map { (p, $0) } }) }.value
    }

    /// Hands the scheduler a reader for each CLI found: a login's read goes through its folders' identity watch. A Codex
    /// CLI found again replaces the backend, whose app-servers stop.
    private func wire(_ found: [Provider: URL]) {
        for provider in Provider.allCases where found[provider] == nil && (provider == .claude ? claudeExecutable : codexExecutable) == nil {
            JuiceLog.reads.error("the \(provider.rawValue, privacy: .public) CLI was not found")
        }
        // A folder that is signing in is only read: the sign-in flow checks who signed in and reports it here.
        let isSigningIn: @Sendable (Account) async -> Bool = { [weak self] account in await self?.signingIn.contains(account.id) ?? false }
        let login: CodexIdentityWatch.Login = { [weak self] folder, who in await self?.folderAnswered(who, folder: folder) ?? true }
        if let executable = found[.claude] {
            claudeExecutable = executable
            let identity = readers.claudeIdentity(executable)
            let watch = ClaudeIdentityWatch(stat: readers.claudeStamp, identity: { await identity.identity(for: $0) },
                                            read: readers.claude(executable), isSigningIn: isSigningIn, login: login)
            claudeWatch = watch
            scheduler.setReader({ [weak self] target, now in
                await self?.read(target, now: now) { await watch.read($0, now: $1) } ?? .failure(RefreshScheduler.skipped)
            }, for: .claude)
        }
        if let executable = found[.codex] {
            codexExecutable = executable
            if let old = codex { retire(old) }
            let backend = readers.codex(executable)
            codex = backend
            let watch = CodexIdentityWatch(stat: backend.stat, restart: backend.shutdown, identity: backend.identity, read: backend.read,
                                           isSigningIn: isSigningIn, login: login)
            codexWatch = watch
            scheduler.setReader({ [weak self] target, now in
                await self?.read(target, now: now) { await watch.read($0, now: $1) } ?? .failure(RefreshScheduler.skipped)
            }, for: .codex)
        }
        signInCoordinator.identity = LiveIdentityChecker(claude: readers.claudeIdentity(claudeExecutable), codex: codex)
    }

    /// The provider's CLI is gone: nothing of it is read or asked, and Settings says it is missing, as when launch finds
    /// none. Its logins' reads fail at once, launching nothing, and each such failure looks for the CLI again.
    private func unwire(_ provider: Provider) {
        switch provider {
        case .claude:
            claudeExecutable = nil
            claudeWatch = nil
        case .codex:
            codexExecutable = nil
            codexWatch = nil
            if let old = codex { retire(old) }
            codex = nil
        }
        scheduler.removeReader(for: provider)
        signInCoordinator.identity = LiveIdentityChecker(claude: readers.claudeIdentity(claudeExecutable), codex: codex)
    }

    /// A Codex backend replaced or dropped: its app-servers stop, after any stop already under way.
    private func retire(_ backend: CodexBackend) {
        codexServing = []
        let before = stopping
        stopping = Task {
            await before?.value
            await backend.shutdownAll()
        }
    }

    /// A read found no CLI to run: the one the search found is gone (uninstalled, or moved by a reinstall), or none was
    /// found. The CLI is looked for again, off the main actor (P107). One found at the same path is read through again;
    /// one found elsewhere is wired afresh. Either way the logins that failed for want of it are read now, not in an hour
    /// (`RefreshScheduler.cliFound`): those reads launched nothing. None found leaves the provider missing, as at launch.
    private func relocate(_ provider: Provider) {
        guard wiring == nil, relocating.insert(provider).inserted else { return }
        let current = generation
        let locate = readers.locate
        let before = relocation
        relocation = Task { [weak self] in
            await before?.value
            let found = await Self.locate([provider], with: locate)
            guard let self, self.generation == current, self.phase == .reading else { return }
            self.relocating.remove(provider)
            if let executable = found[provider] {
                if executable != (provider == .claude ? self.claudeExecutable : self.codexExecutable) { self.wire(found) }
                self.scheduler.cliFound(for: provider)
            } else {
                self.unwire(provider)
            }
            self.rebuild()
        }
    }

    // MARK: Reads

    /// One read of a login, through the preferred of its folders (`preferredFolder`). A folder found signed out, or
    /// holding another login, is left for the next one; a reading that names another login goes to that login. Returns
    /// `RefreshScheduler.skipped` when no folder was left to read the login through.
    private func read(_ target: ReadTarget, now: Date,
                      through watch: @escaping @Sendable (Account, Date) async -> Result<AccountReading, ReadError>) async
        -> Result<AccountReading, ReadError> {
        let current = generation
        var tried: Set<String> = []
        while let folder = preferredFolder(for: target.id, excluding: tried) {
            tried.insert(folder.id)
            readingNow[folder.id] = target.id
            if folder.provider == .codex { codexServing.insert(folder.folder) }
            let result = await watch(folder, now)
            readingNow[folder.id] = nil
            guard generation == current, !Task.isCancelled else { return result }
            switch result {
            case .failure(CodexIdentityWatch.held):
                continue
            case .failure(.signInRequired):
                folderSignedOut(folder)
                continue
            case .success(let reading):
                if let who = reading.login, place(who, in: folder).login != target.id {
                    // The folder answered for another login between its question and its read: that login's reading.
                    if let other = loginsStore.login(holding: folder.id)?.id {
                        loginsStore.apply(.success(reading), to: other, at: clock())
                        scheduler.seed(reading: reading, for: other)
                        writeProjection()
                        saveStores()
                        rebuild()
                    }
                    continue
                }
                readThrough(folder, for: target.id)
                return result
            case .failure:
                readThrough(folder, for: target.id)
                return result
            }
        }
        // Nothing was read, so nothing is recorded (`record` is not called): a rename while it ran has nothing to redirect.
        renamedLogins[target.id] = nil
        return .failure(RefreshScheduler.skipped)
    }

    /// The folder a login's next read goes through: of the enabled folders that hold it and are not signing in, the one
    /// whose login file changed last (`stat` only: Codex `auth.json`, Claude `.claude.json`), so the freshest token is
    /// used; then the one it was last read through, then the provider's default folder, then the account list's order.
    private func preferredFolder(for loginID: String, excluding tried: Set<String> = []) -> Account? {
        let folders = loginsStore.folders(of: loginID, in: accountsStore.accounts)
        let candidates = folders.enumerated().filter { !tried.contains($0.element.id) && !signingIn.contains($0.element.id) }
        return candidates.max { a, b in preference(a.element, a.offset, loginID) < preference(b.element, b.offset, loginID) }?.element
    }

    private func preference(_ folder: Account, _ index: Int, _ loginID: String) -> (Int, Int, Int, Int, Int) {
        let stamp = folder.provider == .codex ? codex?.stat(folder.folder) : readers.claudeStamp(folder.folder)
        return (stamp?.modifiedSeconds ?? .min, stamp?.modifiedNanoseconds ?? 0, readThrough[loginID] == folder.id ? 1 : 0,
                CLIEnvironment.isDefaultFolder(folder.folder, for: folder.provider, home: readers.home) ? 1 : 0, -index)
    }

    /// The login was read through `folder`: a Codex home it was read through before stops its app-server.
    private func readThrough(_ folder: Account, for loginID: String) {
        guard readThrough.updateValue(folder.id, forKey: loginID) != folder.id else { return }
        pruneCodexServers()
    }

    /// A read's outcome is its login's, whichever folder it went through: under the login's new id when an answer named
    /// its organization while it read (P580), and the floor then counts from it there too.
    private func record(_ result: Result<AccountReading, ReadError>, for target: ReadTarget, at: Date) {
        guard phase == .reading else { return }
        var target = target
        let renamed = renamedLogins.removeValue(forKey: target.id)
        if let renamed { target.id = renamed }
        noteOutcome(result, for: target)
        loginsStore.apply(result, to: target.id, at: at)
        // The scheduler read it under its old id: the new one's floor and waits count from this outcome.
        if renamed != nil, let record = loginsStore.logins[target.id]?.record { scheduler.seed(record: record, for: target.id) }
        writeProjection()
        saveStores()
        if case .failure(.cliNotFound) = result { relocate(target.provider) }
        rebuild()
    }

    /// Logs a login's reads starting to fail, a different failure, and the first good read after failures; nothing for
    /// the reads in between. The login is named by the folder it was read through (`JuiceLog.folder`).
    private func noteOutcome(_ result: Result<AccountReading, ReadError>, for target: ReadTarget) {
        let before = loginsStore.logins[target.id]?.record
        let failing = (before?.consecutiveFailures ?? 0) > 0 ? before?.lastError : nil
        let through = readThrough[target.id].flatMap { id in accountsStore.accounts.first { $0.id == id } }.map { JuiceLog.folder($0.folder) }
            ?? target.provider.rawValue
        switch result {
        case .success:
            guard let failing else { return }
            JuiceLog.reads.notice("\(through, privacy: .public): read again after \(failing.logName, privacy: .public)")
        case .failure(let error):
            guard error != RefreshScheduler.skipped, failing.map({ $0.logName != error.logName }) ?? true else { return }
            JuiceLog.reads.error("\(through, privacy: .public): read failed, \(error.logName, privacy: .public)")
        }
    }

    // MARK: Folders

    /// Who is signed in to a folder, from its identity watch (a read's question, a question between reads, `identify`)
    /// or a reading; nil is a sign-out. The folder joins that login. Returns whether a read of the folder running now
    /// may go on: only when it is for that login under the id it was started with. A read whose own question renamed its
    /// login (P580) reads nothing: the login's schedule, seeded from its record under the new id, reads it next.
    private func folderAnswered(_ who: LoginIdentity?, folder: Account) -> Bool {
        guard phase == .reading, let current = accountsStore.accounts.first(where: { $0.id == folder.id }) else { return true }
        guard let who else {
            folderSignedOut(current)
            return true
        }
        let login = place(who, in: current).login
        return readingNow[folder.id].map { $0 == login } ?? true
    }

    /// The folder is signed in to `who`: it joins that login (new ones are read at once), and a known email follows. A
    /// folder placed for the first time brings its readings.json record to that login, unless its known email says the
    /// record was another account's. A login that took its organization's id (P580) keeps what this run knows of it too.
    @discardableResult
    private func place(_ who: LoginIdentity, in folder: Account) -> Placement {
        let email = who.email
        let before = loginsStore.state(of: folder.id)
        let sameAccount = folder.knownEmail.map { LoginsStore.normalized($0) == LoginsStore.normalized(email) } ?? true
        let record = before == .unknown && sameAccount ? readingsStore.records[folder.id] : nil
        let placement = loginsStore.place(who, in: folder, record: record, now: clock())
        if let old = placement.renamed { loginRenamed(old, to: placement.login) }
        answered.insert(folder.id)
        askAgainAt[folder.id] = nil
        askFailures[folder.id] = nil
        signedOutAt[folder.id] = nil
        if placement.moved {
            if let known = folder.knownEmail, LoginsStore.normalized(known) != LoginsStore.normalized(email) {
                accountsStore.setKnownEmail(id: folder.id, email)
            }
            loginsChanged()
        }
        // The folder's old record, or the email's old login merged into this one (P585), may hold a later reading or a
        // stricter wait than the login's schedule knew: both only push its next read later.
        if record != nil || placement.renamed != nil, phase == .reading, let merged = loginsStore.logins[placement.login]?.record {
            scheduler.seed(record: merged, for: placement.login)
        }
        return placement
    }

    /// The login `old` is `new` from now on (P580), or was merged into it (P585): which folder it was read through (unless
    /// `new` has its own), its boost and its history follow it; `loginsChanged` then schedules it under its new id, and
    /// `place` seeds it from its record.
    private func loginRenamed(_ old: String, to new: String) {
        if scheduler.isInFlight(old) { renamedLogins[old] = new }
        if let folder = readThrough.removeValue(forKey: old), readThrough[new] == nil { readThrough[new] = folder }
        if let renewed = boostRenewed.removeValue(forKey: old) { boostRenewed[new] = max(boostRenewed[new] ?? renewed, renewed) }
        historyStore.rename(old, to: new)
        JuiceLog.reads.notice("a login's organization was named: it is read under its own id")
    }

    private func folderSignedOut(_ folder: Account) {
        answered.insert(folder.id)
        askAgainAt[folder.id] = nil
        askFailures[folder.id] = nil
        signedOutAt[folder.id] = clock()
        if loginsStore.signOut(folder.id) != .signedOut { loginsChanged() }
    }

    /// Which folders hold which login changed, or the account list, or a Monitor switch: the scheduler reads the logins
    /// that have a folder (one first seen is due now), and the files follow.
    private func loginsChanged() {
        let lists = LoginList.build(accounts: accountsStore.accounts, logins: loginsStore.logins, folders: loginsStore.folders,
                                    signingIn: [], now: clock(), home: readers.home)
        let targets = lists.flatMap(\.logins).map { ReadTarget(id: $0.id, provider: $0.provider, monitored: $0.monitored) }
        if phase == .reading {
            scheduler.setTargets(targets)
            scheduler.seed(from: loginRecords)
            writeProjection()
            saveStores()
            pruneCodexServers()
        }
        rebuild()
    }

    private var loginRecords: [String: AccountRecord] {
        loginsStore.logins.compactMapValues(\.record)
    }

    /// readings.json follows the logins: each folder's record is its login's.
    private func writeProjection() {
        readingsStore.replace(loginsStore.projection(of: accountsStore.accounts, onto: readingsStore.records, now: clock()))
    }

    private func saveStores() {
        try? accountsStore.save()
        try? readingsStore.save()
        try? loginsStore.save()
    }

    /// Every enabled folder, on the clock: one not answered in this run is asked who is signed in (`identify`, no usage
    /// read; a question that failed waits its backoff), unless its login's read, due now, goes through it and asks
    /// itself, and so is one found signed out a sign-in delay ago; every other one is looked at (`check`: a `stat` of its
    /// login file, and a question when it changed, on the watch's terms). A Codex home only asked stops its app-server
    /// again.
    private func checkFolders() {
        guard loginCheck == nil, !isAsleep, codexWatch != nil || claudeWatch != nil else { return }
        let current = clock()
        var asks: [Account] = []
        var checks: [Account] = []
        for folder in accountsStore.accounts where folder.monitored && !signingIn.contains(folder.id) && readingNow[folder.id] == nil {
            guard (folder.provider == .codex ? codexWatch != nil : claudeWatch != nil) else { continue }
            let mayAsk = (askAgainAt[folder.id] ?? .distantPast) <= current
            if answered.contains(folder.id) {
                let outSince = loginsStore.state(of: folder.id) == .signedOut ? signedOutAt[folder.id] : nil
                if let outSince, mayAsk, current >= outSince.addingTimeInterval(scheduler.policy.userFixableDelay) {
                    asks.append(folder)
                } else {
                    checks.append(folder)
                }
                continue
            }
            if !mayAsk { continue }
            if let login = loginsStore.login(holding: folder.id), login.monitored,
               scheduler.isInFlight(login.id) || (scheduler.nextDue(for: login.id) ?? .distantFuture) <= current,
               preferredFolder(for: login.id)?.id == folder.id { continue }
            asks.append(folder)
        }
        guard !asks.isEmpty || !checks.isEmpty else { return }
        let codex = codexWatch, claude = claudeWatch, generation = generation
        loginCheck = Task { [weak self] in
            for folder in asks {
                let answer = switch folder.provider {
                case .codex: await codex?.identify(folder)
                case .claude: await claude?.identify(folder, now: current)
                }
                guard let self, self.generation == generation else { return }
                self.asked(folder, answer)
            }
            for folder in checks {
                let started = switch folder.provider {
                case .codex: await codex?.check(folder) ?? false
                case .claude: await { await claude?.check(folder, now: current); return false }()
                }
                guard let self, self.generation == generation else { return }
                if started { self.codexServing.insert(folder.folder) }
            }
            guard let self, self.generation == generation else { return }
            self.loginCheck = nil
            self.pruneCodexServers()
            self.rebuild()
        }
    }

    /// A folder's question ended: an answer placed it (through `folderAnswered`); a failure asks again after its backoff.
    private func asked(_ folder: Account, _ answer: Result<SignInIdentity, ReadError>?) {
        if folder.provider == .codex { codexServing.insert(folder.folder) }
        switch answer {
        case .success(let who):
            if who.email == nil { retryAsk(folder, after: .incomplete("signed in without an email")) }
        case .failure(.signInRequired), nil:
            return
        case .failure(let error):
            retryAsk(folder, after: error)
        }
    }

    private func retryAsk(_ folder: Account, after error: ReadError) {
        let count = (askFailures[folder.id] ?? 0) + 1
        askFailures[folder.id] = count
        askAgainAt[folder.id] = clock().addingTimeInterval(scheduler.policy.questionDelay(after: error, consecutiveFailures: count))
    }

    /// Codex app-servers run only where a login is read: in the home each monitored login was last read through (or, not
    /// read yet in this run, will be), and in homes being read or signing in now. Every other home that may have one
    /// stops it. Waits while the clock's checks run, which end by calling it.
    private func pruneCodexServers() {
        guard let codex, loginCheck == nil else { return }
        let enabled = accountsStore.accounts
        let busy = Set(readingNow.keys).union(signingIn)
        var keep = Set(busy.compactMap { id in enabled.first { $0.id == id }?.folder })
        for login in loginsStore.logins.values where login.provider == .codex && login.monitored {
            let folders = loginsStore.folders(of: login.id, in: enabled)
            if let last = readThrough[login.id], let folder = folders.first(where: { $0.id == last }) {
                keep.insert(folder.folder)
            } else if let next = preferredFolder(for: login.id) {
                keep.insert(next.folder)
            }
        }
        let idle = codexServing.subtracting(keep).sorted()
        guard !idle.isEmpty else { return }
        codexServing.subtract(idle)
        let before = stopping
        stopping = Task {
            await before?.value
            for folder in idle { await codex.shutdown(folder) }
        }
    }

    private func rebuild() {
        let tick = clock()
        let lists = LoginList.build(accounts: accountsStore.accounts, logins: loginsStore.logins, folders: loginsStore.folders,
                                    signingIn: [], now: tick, home: readers.home)
        let loginRecords = loginRecords
        // Only this app's reads: nothing is saved while standalone Juice runs.
        if phase == .reading { historyStore.observe(loginRecords, providers: loginsStore.logins.mapValues(\.provider)) }
        let built = PanelModelBuilder.build(entries: LoginList.panelEntries(lists), records: loginRecords, signingIn: [],
                                            attention: LoginList.needsSignIn(lists), money: MoneyRowModel.notConnected, now: tick,
                                            history: historyStore.history)
        let all = loginRecords.merging(readingsStore.records) { login, _ in login }
        if all != records { records = all }
        if built != panel || lists != logins || tick.timeIntervalSince(now) >= 60 {
            now = tick
            panel = built
            logins = lists
        }
        let questions = questions()
        if questions.asking != asking { asking = questions.asking }
        if questions.unanswered != unanswered { unanswered = questions.unanswered }
        if questions.missing != missingCLIs { missingCLIs = questions.missing }
        let notFound = phase != .reading || wiring != nil ? [] : Provider.allCases.filter {
            ($0 == .claude ? claudeExecutable : codexExecutable) == nil
        }
        if notFound != cliNotFound { cliNotFound = notFound }
    }

    /// Where each folder not placed yet stands (`asking`, `unanswered`), and which CLIs are missing, while reading.
    private func questions() -> (asking: Set<String>, unanswered: Set<String>, missing: [Provider]) {
        guard phase == .reading else { return ([], [], []) }
        let searching = wiring != nil
        let found = Set(Provider.allCases.filter { $0 == .claude ? claudeWatch != nil : codexWatch != nil })
        let enabled = accountsStore.accounts.filter(\.monitored)
        var asking: Set<String> = [], unanswered: Set<String> = []
        for folder in enabled where !answered.contains(folder.id) && loginsStore.state(of: folder.id) == .unknown {
            if askAgainAt[folder.id] != nil {
                unanswered.insert(folder.id)
            } else if searching || found.contains(folder.provider) {
                asking.insert(folder.id)
            }
        }
        let missing = searching ? [] : Provider.allCases.filter { provider in
            !found.contains(provider) && enabled.contains { $0.provider == provider }
        }
        return (asking, unanswered, missing)
    }

    // MARK: Refresh

    /// Refresh all within the floors: a login read less than its boosted interval ago only gets the boost, and a folder
    /// not placed yet is asked (within its own backoff). A CLI that was missing is looked for again first, off the main
    /// actor, and one found reads the logins that failed for want of it at once.
    func refreshAll() {
        guard phase == .reading else { return }
        let missing = Provider.allCases.filter { ($0 == .claude ? claudeExecutable : codexExecutable) == nil }
        guard !missing.isEmpty, wiring == nil else {
            scheduler.refreshAllWithinFloors()
            checkFolders()
            return
        }
        let current = generation
        let locate = readers.locate
        wiring = Task { [weak self] in
            let found = await Self.locate(missing, with: locate)
            guard let self, self.generation == current, self.phase == .reading else { return }
            self.wiring = nil
            self.wire(found)
            for provider in found.keys { self.scheduler.cliFound(for: provider) }
            if !self.scheduler.isRunning { self.scheduler.start() }
            self.scheduler.refreshAllWithinFloors()
            self.checkFolders()
            self.rebuild()
        }
    }

    /// Refresh account (#12): the login is read now if its floor and any 429 pause allow, else its next read moves up to
    /// where they end (`RefreshScheduler.refreshWithinFloors`).
    func refreshAccount(_ id: String) {
        guard manualRead(id) != .unavailable else { return }
        scheduler.refreshWithinFloors(id: id)
    }

    /// Unavailable while standalone Juice reads, while the CLIs are looked for, or with the login's CLI missing.
    func manualRead(_ id: String) -> RefreshScheduler.ManualRead {
        guard phase == .reading, wiring == nil, let provider = loginsStore.logins[id]?.provider,
              (provider == .claude ? claudeExecutable : codexExecutable) != nil else { return .unavailable }
        return scheduler.manualRead(for: id)
    }

    var history: UsageHistory { historyStore.history }
    var quotaNotice: QuotaNotice? { historyStore.notice }

    /// The scheduler's own due time for the login, and whether its read runs now; nil while nothing is read here.
    func schedule(of loginID: String) -> ReadSchedule? {
        guard phase == .reading else { return nil }
        return ReadSchedule(next: scheduler.nextDue(for: loginID), reading: scheduler.isInFlight(loginID))
    }

    func question(forFolder id: String) -> FolderQuestion {
        if unanswered.contains(id) { return .unanswered }
        if asking.contains(id) { return .asking }
        if let folder = account(id: id), missingCLIs.contains(folder.provider) { return .cliMissing }
        return .none
    }

    /// #12: the accounts (folder ids, `Account.id`) whose sessions are at work now. Their logins are read at the boosted
    /// floor (Claude 120 s; Codex's floor by use) until `boostDuration` after the last such call, never sooner, and a 429
    /// pause still holds (`RefreshScheduler.boost`). Renewed at most once a minute per login.
    func sessionsAtWork(inFolders ids: Set<String>) {
        guard phase == .reading, !ids.isEmpty else { return }
        let now = clock()
        for login in Set(ids.compactMap { loginsStore.login(holding: $0) }.filter(\.monitored).map(\.id)) {
            if let renewed = boostRenewed[login], now.timeIntervalSince(renewed) < 60, now >= renewed { continue }
            boostRenewed[login] = now
            scheduler.boost(id: login, until: now.addingTimeInterval(scheduler.policy.boostDuration))
        }
    }

    // MARK: Editing (Settings › Accounts)

    /// Edits wait while standalone Juice runs: it keeps its own copy of the account list and would write over them.
    var canEdit: Bool { phase == .reading }

    /// The home folder the list shortens folders against (`~/.codex`).
    var home: String { readers.home }

    /// Folders the app does not read, each with Add: the ones found on this Mac that are not in the account list or are
    /// switched off there, then any other folder switched off there (one "+" made that never signed in has nothing for
    /// discovery to find). A forgotten folder is never among them, unless "+" could not name it back (one forgotten
    /// before Forget was kept to folders "+" can name): nothing is hidden for good.
    var discovered: [DiscoveredProfile] {
        let accounts = accountsStore.accounts
        let listed = found.filter { profile in !accounts.contains { $0.id == profile.id && $0.monitored } }
        let off = accounts.filter { account in !account.monitored && !found.contains { $0.id == account.id } }
            .map { DiscoveredProfile(provider: $0.provider, folder: $0.folder, suggestedAlias: $0.alias, knownEmail: $0.knownEmail) }
        return (listed + off).filter { !(forgottenStore.contains($0.id) && canForget(provider: $0.provider, folder: $0.folder)) }
    }

    /// Looks for profile folders again, off the main actor (Settings › Accounts opening).
    func refreshDiscovery() {
        let discover = readers.discover
        discovery = Task { [weak self] in
            let profiles = await Task.detached { discover() }.value
            self?.found = profiles
        }
    }

    /// The folder joins the app (or is switched on again): it is asked who is signed in on the next tick.
    func add(_ profile: DiscoveredProfile) {
        guard canEdit else { return }
        editAccounts {
            if account(id: profile.id) != nil {
                accountsStore.setMonitored(id: profile.id, true)
            } else {
                accountsStore.add(profile.account())
            }
        }
    }

    /// A login's Monitor switch: one switched off is read through none of its folders.
    func setMonitored(login loginID: String, _ monitored: Bool) {
        guard canEdit, loginsStore.logins[loginID] != nil else { return }
        loginsStore.setMonitored(loginID, monitored)
        loginsChanged()
    }

    /// A folder's own switch (the account list's `monitored`): a folder switched off is never read or asked.
    func setMonitored(_ id: String, _ monitored: Bool) {
        guard canEdit else { return }
        editAccounts { accountsStore.setMonitored(id: id, monitored) }
    }

    func rename(_ id: String, to alias: String) {
        let trimmed = alias.trimmingCharacters(in: .whitespaces)
        guard canEdit, !trimmed.isEmpty, account(id: id)?.alias != trimmed else { return }
        editAccounts { accountsStore.rename(id: id, alias: trimmed) }
    }

    /// Removes the folder from the app only: nothing is signed out and no folder is touched. Its login keeps its record.
    func remove(_ id: String) {
        guard canEdit, account(id: id) != nil else { return }
        if signInCoordinator.activeAccount?.id == id { signInCoordinator.cancel() }
        added.remove(id)
        editAccounts {
            accountsStore.remove(id: id)
            readingsStore.forget(id: id)
            loginsStore.forget(folder: id)
        }
    }

    /// Stop Monitoring: the folder stays in the account list, switched off, so it is neither read nor asked, and is
    /// offered with Add. Its login is read through its other folders, if it has any.
    func stopMonitoring(_ id: String) {
        guard canEdit, account(id: id)?.monitored == true else { return }
        if signInCoordinator.activeAccount?.id == id { signInCoordinator.cancel() }
        added.remove(id)
        setMonitored(id, false)
    }

    /// Forget: the folder leaves the account list, if it is there, and is not offered with Add again, after a relaunch
    /// too (`forgotten.json`). It only hides: nothing is signed out, the folder and every file in it stay as they are, and
    /// its login keeps its record. Naming it again under "+" brings it back, so only a folder "+" can name is forgotten
    /// (`canForget`).
    func forget(_ id: String) {
        guard canEdit else { return }
        let listed = account(id: id)
        guard let folder = listed.map({ ($0.provider, $0.folder) }) ?? found.first(where: { $0.id == id }).map({ ($0.provider, $0.folder) }),
              canForget(provider: folder.0, folder: folder.1) else { return }
        forgottenStore.forget(id)
        try? forgottenStore.save()
        if listed != nil { remove(id) }
    }

    /// Whether Forget is offered for a folder: only for one "+" can name again (`NewProfileFolder.name(of:)`), so a
    /// forgotten folder can always come back. The provider's own folder (`~/.claude`, `~/.codex`) and a folder no name
    /// makes are only ever stopped (Stop Monitoring), which Add undoes.
    func canForget(provider: Provider, folder: String) -> Bool {
        NewProfileFolder.name(of: folder, provider: provider, home: home) != nil
    }

    /// Remove account (P362): the login leaves the app. Every folder of its provider that holds it, switched on or off, is
    /// forgotten where `canForget` allows (it comes back by naming it under "+") and switched off otherwise (the
    /// provider's own folder, which Add brings back), in one edit. It only hides: nothing is signed out, no folder or
    /// file is touched, and the login keeps its record in logins.json, so its waits come back with it. No folder holds
    /// it afterwards, so it has no row, no battery and no read. A sign-in running in one of its folders is cancelled.
    func removeAccount(login loginID: String) {
        guard canEdit, let login = loginsStore.logins[loginID] else { return }
        let held = accountsStore.accounts.filter { $0.provider == login.provider && loginsStore.state(of: $0.id) == .signedIn(login: loginID) }
        guard !held.isEmpty else { return }
        if let active = signInCoordinator.activeAccount, held.contains(where: { $0.id == active.id }) { signInCoordinator.cancel() }
        let forgotten = held.filter { canForget(provider: $0.provider, folder: $0.folder) }
        editAccounts {
            for folder in held {
                added.remove(folder.id)
                if forgotten.contains(folder) {
                    forgottenStore.forget(folder.id)
                    accountsStore.remove(id: folder.id)
                    readingsStore.forget(id: folder.id)
                    loginsStore.forget(folder: folder.id)
                } else {
                    accountsStore.setMonitored(id: folder.id, false)
                }
            }
        }
        if !forgotten.isEmpty { try? forgottenStore.save() }
    }

    // MARK: New accounts (Settings › Accounts › +)

    /// What a name typed under "+" would do.
    enum NewAccountCheck: Equatable {
        /// Make this folder and sign in there.
        case new(folder: String)
        /// Bring back this forgotten folder.
        case forgotten(folder: String)
        case problem(NewProfileFolder.Problem)
    }

    /// "+" can act: edits are allowed (standalone Juice is not running), the provider's CLI was found, and no sign-in
    /// runs (one flow at a time).
    func canAddAccount(_ provider: Provider) -> Bool { addUnavailableReason(provider) == nil }

    /// Why "+" cannot act now, in a few words; nil when it can.
    func addUnavailableReason(_ provider: Provider) -> String? {
        guard canEdit else { return Self.juiceRunningText }
        if isMissingCLI(provider) { return LiveAccountsText.missing([provider]) }
        if (provider == .claude ? claudeExecutable : codexExecutable) == nil { return "Looking for the \(provider.displayName) CLI…" }
        if signInCoordinator.activeAccount != nil { return "A sign-in is running" }
        return nil
    }

    /// The last CLI search did not find the provider's CLI, whether or not a folder of it is enabled (`missingCLIs`).
    func isMissingCLI(_ provider: Provider) -> Bool { cliNotFound.contains(provider) }

    /// The folder a name makes (`NewProfileFolder`), or the forgotten folder it names, which comes back as it was.
    func checkNewAccount(_ name: String, provider: Provider) -> NewAccountCheck {
        let name = NewProfileFolder.normalized(name)
        if let problem = NewProfileFolder.validate(name, provider: provider) { return .problem(problem) }
        let folder = NewProfileFolder.folder(for: name, provider: provider, home: home)
        if let id = forgottenStore.forgotten(provider: provider, folder: folder) {
            let path = String(id.dropFirst(provider.rawValue.count + 1))
            // One gone from the disk since is made again instead.
            if (try? FileManager.default.attributesOfItem(atPath: path)) != nil { return .forgotten(folder: path) }
        }
        switch NewProfileFolder.check(name, provider: provider, home: home, known: accountsStore.accounts.map(\.folder)) {
        case .success(let folder): return .new(folder: folder)
        case .failure(let problem): return .problem(problem)
        }
    }

    /// "+": makes `~/.claude-<name>` or `~/.codex-<name>`, empty, and starts the CLI's own sign-in in it, or brings back
    /// the forgotten folder the name names. The folder joins the account list at once, so a sign-in that is cancelled or
    /// fails leaves it listed, with Sign In; once signed in it joins its login's row, beside the login's other folders
    /// when it is an account the app already reads (P93). The sign-in starts before the clock looks at the new folder, so
    /// no question races it. No hook is installed: its row offers Setup's Install (`added`).
    @discardableResult
    func addAccount(_ name: String, provider: Provider) -> Result<Account, NewProfileFolder.Problem> {
        guard canAddAccount(provider) else { return .failure(.failed) }
        switch checkNewAccount(name, provider: provider) {
        case .problem(let problem):
            newAccount?.failure = problem
            return .failure(problem)
        case .forgotten(let folder):
            let id = Account.id(provider: provider, folder: folder)
            forgottenStore.restore(id)
            try? forgottenStore.save()
            newAccount = nil
            let alias = String((folder as NSString).lastPathComponent.dropFirst(provider.defaultFolderName.count + 1))
            add(DiscoveredProfile(provider: provider, folder: folder, suggestedAlias: alias))
            return account(id: id).map { .success($0) } ?? .failure(.failed)
        case .new(let folder):
            do {
                try NewProfileFolder.create(folder)
            } catch {
                let problem = error as? NewProfileFolder.Problem ?? .failed
                newAccount?.failure = problem
                return .failure(problem)
            }
            let account = Account(provider: provider, folder: folder, alias: NewProfileFolder.normalized(name))
            if let stale = forgottenStore.forgotten(provider: provider, folder: folder) {
                forgottenStore.restore(stale)
                try? forgottenStore.save()
            }
            accountsStore.add(account)
            try? accountsStore.save()
            added.insert(account.id)
            newAccount = nil
            signIn(id: account.id)
            loginsChanged()
            checkFolders()
            return .success(account)
        }
    }

    /// Closes a folder's Setup line under its row.
    func dismissHooksOffer(_ id: String) { added.remove(id) }

    /// Saves the list and reschedules. A folder added or switched on is asked who is signed in at once (one switched off
    /// or removed is asked again when it comes back), and a Codex home no login is read through any more stops its
    /// app-server.
    private func editAccounts(_ change: () -> Void) {
        change()
        let enabled = Set(accountsStore.accounts.filter(\.monitored).map(\.id))
        answered.formIntersection(enabled)
        try? accountsStore.save()
        loginsChanged()
        checkFolders()
    }

    /// The login a folder holds, if it is signed in.
    func login(forFolder id: String) -> Login? { loginsStore.login(holding: id) }

    /// The plan of a login's last reading (by login id, or by the id of a folder that holds it), capitalised ("Max",
    /// "Pro", "Plus"); nil before a reading.
    func plan(for id: String) -> String? {
        (loginsStore.logins[id] ?? loginsStore.login(holding: id))?.record?.planWord
    }

    // MARK: Sign-in (Juice spec §7)

    /// The Chrome profile folder sign-in pages open in; nil opens the default browser.
    var browserProfile: String? {
        get { _ = browserProfileChanged; return readers.browserProfile() }
        set { readers.setBrowserProfile(newValue); browserProfileChanged += 1 }
    }
    /// Bumped on every choice so the pop-up redraws (the choice itself lives in `UserDefaults`).
    private(set) var browserProfileChanged = 0
    func browserProfiles() -> [ChromeProfile] { readers.browserProfiles() }

    /// One click: the vendor's own login for that folder. False when nothing started: the folder is gone, Juice is
    /// running, or a flow is already running.
    @discardableResult
    func signIn(id: String) -> Bool {
        guard phase == .reading, let account = account(id: id), signInCoordinator.activeAccount == nil else { return false }
        signInCoordinator.configuration.claudeExecutable = claudeExecutable
        signInCoordinator.configuration.codexExecutable = codexExecutable
        signInCoordinator.configuration.browserHelper = readers.browserHelper(directory)
        signInCoordinator.configuration.browserProfile = readers.browserProfile()
        signInCoordinator.signIn(account)
        rebuild()
        return true
    }

    /// The flow for this folder, while it runs or when it just failed (so its row can say so).
    func signInPhase(for id: String) -> SignInPhase? {
        if signInCoordinator.activeAccount?.id == id { return signInCoordinator.phase }
        if signInCoordinator.activeAccount == nil, signInCoordinator.lastAccount?.id == id, case .failed = signInCoordinator.phase {
            return signInCoordinator.phase
        }
        return nil
    }

    /// The flow asked who signed in: the folder joins that login, which is read at once if it is new to the app (a login
    /// it already had keeps its floors: only a real reading makes it available, Juice spec §7 step 4). A flow that found
    /// no email leaves the folder to be asked on the clock.
    private func signInFinished(_ account: Account, _ phase: SignInPhase) {
        if case .done(let email) = phase, self.phase == .reading {
            // The flow asked who signed in: its answer is the Claude watch's latest, so the folder's next read is made.
            if account.provider == .claude {
                claudeWatch?.signedIn(account, at: clock(), usageBilled: signInCoordinator.checkedIdentity?.usageBilled == true)
            }
            // Its check started the home's app-server, which stops unless a login is read there.
            if account.provider == .codex { codexServing.insert(account.folder) }
            if let email, let folder = self.account(id: account.id) {
                // The organization the flow's check found, when it named the same email (P580): the one the owner picked
                // on the sign-in page. Nothing here picks one.
                let checked = signInCoordinator.checkedIdentity?.login.flatMap {
                    LoginsStore.normalized($0.email) == LoginsStore.normalized(email) ? $0 : nil
                }
                place(checked ?? LoginIdentity(email: email), in: folder)
                accountsStore.setKnownEmail(id: account.id, email)
            } else {
                answered.remove(account.id)
                askAgainAt[account.id] = nil
            }
            try? accountsStore.save()
        }
        rebuild()
    }
}

/// The "+" row of Settings › Accounts: which provider it adds to, the name typed so far, and why the last Add did not
/// go through (the folder could not be made), until the name changes.
struct NewAccountDraft: Equatable {
    var provider: Provider
    var name = ""
    var failure: NewProfileFolder.Problem?
}
