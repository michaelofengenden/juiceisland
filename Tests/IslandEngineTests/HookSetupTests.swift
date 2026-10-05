import Foundation
import Testing
@testable import IslandEngine
import JuiceCore
import OpenIslandCore

/// Setup's engine half (spec §3.5): stat-only discovery, the button's choice, drift checks and when they run. Every
/// test works in its own temporary folder with the fixture names; nothing touches a real profile, the managed helper
/// or a hook socket.
@MainActor
struct HookSetupTests {
    final class Sandbox {
        let root: URL
        let bundledHelper: URL
        let managedHelper: URL
        let defaults: UserDefaults
        private let suite = "HookSetupTests-\(UUID().uuidString)"

        init(helper: Bool = true) throws {
            root = URL(fileURLWithPath: ProfileHookTargets.normalized(
                FileManager.default.temporaryDirectory.appendingPathComponent("ji-setup-\(UUID().uuidString)").path))
            bundledHelper = root.appendingPathComponent("bundle/Contents/Helpers/OpenIslandHooks")
            managedHelper = root.appendingPathComponent("managed/bin/OpenIslandHooks")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if helper {
                try FileManager.default.createDirectory(at: bundledHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bundledHelper)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundledHelper.path)
            }
            defaults = UserDefaults(suiteName: suite)!
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
        }

        func profile(_ provider: Provider, _ name: String, files: [String: String] = [:]) throws -> ProfileHookTarget {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (file, contents) in files { try Data(contents.utf8).write(to: folder.appendingPathComponent(file)) }
            return ProfileHookTarget(provider: provider, folder: folder.path, alias: String(name.split(separator: "-").last ?? ""),
                                     isDefaultFolder: false, accountID: nil, isMonitored: true)
        }

        @MainActor func manager(openIslandRunning: Bool = false) -> ProfileHookManager {
            ProfileHookManager(bundledHelperURL: bundledHelper, managedHelperURL: managedHelper,
                               intents: ProfileHookIntentStore(defaults: defaults), codexFeatureKey: { .current },
                               isOpenIslandAppRunning: { openIslandRunning })
        }

        var intents: ProfileHookIntentStore { ProfileHookIntentStore(defaults: defaults) }

        func url(_ target: ProfileHookTarget, _ file: String) -> URL {
            URL(fileURLWithPath: target.folder).appendingPathComponent(file)
        }

        /// Every file under the sandbox (helper folders included) with its bytes and mode: proof nothing was written.
        func snapshot() throws -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(atPath: root.path)
            while let relative = enumerator?.nextObject() as? String {
                let path = root.appendingPathComponent(relative).path
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let mode = (attributes[.posixPermissions] as? Int).map { Data("\($0)".utf8) } ?? Data()
                if attributes[.type] as? FileAttributeType == .typeRegular {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
                    result[relative] = (try Data(contentsOf: URL(fileURLWithPath: path))) + mode
                    try FileManager.default.setAttributes([.posixPermissions: attributes[.posixPermissions] ?? 0o644], ofItemAtPath: path)
                } else {
                    result[relative] = mode
                }
            }
            return result
        }
    }

    // MARK: Discovery

    /// Only names and existence decide; a `.claude.json` nobody may read still marks a profile, so it was never opened.
    @Test
    func discoveryFindsProfilesByWhichFilesExistAndOpensNone() throws {
        let box = try Sandbox()
        let home = box.root.path
        func make(_ name: String, _ files: [String]) throws {
            let folder = box.root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files { try Data("{}".utf8).write(to: folder.appendingPathComponent(file)) }
        }
        try make(".claude", [".claude.json"])
        try make(".claude-work", [".claude.json"])
        try make(".claude-lab", [])
        try make(".claude-db", [".claude.json"])
        try make(".codex", ["config.toml"])
        try make(".codex-side", ["config.toml"])
        try make(".codex-fresh", ["auth.json"])
        try make(".codex-preset", [])
        try make(".config", [".claude.json"])
        try Data().write(to: box.root.appendingPathComponent(".codex-file"))
        let locked = box.root.appendingPathComponent(".claude-work/.claude.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let found = ProfileFolderDiscovery.discover(home: home)
        #expect(found.map(\.folder) == [".claude", ".claude-work", ".codex", ".codex-fresh", ".codex-side"].map { home + "/" + $0 })
        #expect(found.map(\.suggestedAlias) == ["Claude", "work", "Codex", "fresh", "side"])
        #expect(found.map(\.provider) == [.claude, .claude, .codex, .codex, .codex])
        #expect(found.first { $0.suggestedAlias == "fresh" }?.hasAuthFile == true)
        #expect(found.allSatisfy { $0.knownEmail == nil })
        #expect(ProfileFolderDiscovery.discover(home: box.root.appendingPathComponent("none").path).isEmpty)
        // The public flavor passes over no Claude folder by name (P858): `.claude-db` is a profile there.
        let flavor = AppFlavor(info: ["JIFlavor": "public", "CFBundleIdentifier": "io.github.example.juice"])
        #expect(ProfileFolderDiscovery.discover(home: home, flavor: flavor).map(\.suggestedAlias) == ["Claude", "db", "work", "Codex", "fresh", "side"])
    }

    // MARK: The button

    private static let work = ProfileHookTarget(provider: .claude, folder: "/tmp/ji-fixture/.claude-work", alias: "work",
                                                isDefaultFolder: false, accountID: nil, isMonitored: true)

    private static func status(_ state: ProfileHookStatus.State, vibe: Int = 0) -> ProfileHookStatus {
        ProfileHookStatus(target: work, state: state, intent: .untouched, managedEventCount: 0, expectedEventCount: 14,
                          vibeEntryCount: vibe, otherHookCount: 0, helperMatchesBundle: true, codexFeatureEnabled: nil,
                          checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test
    func theButtonFollowsTheStateAndItsRefusalsFollowThePreflightOrder() {
        func choice(_ state: ProfileHookStatus.State, vibe: Int = 0, running: Bool = false, helper: Bool = true) -> ProfileHookChoice {
            ProfileHookChoice.of(Self.status(state, vibe: vibe), setupState: state, openIslandRunning: running, helperPresent: helper)
        }
        #expect(choice(.notInstalled) == ProfileHookChoice(action: .install, refusal: nil))
        #expect(choice(.partial(installed: 13, expected: 14)) == ProfileHookChoice(action: .repair, refusal: nil))
        #expect(choice(.codexFeatureOff) == ProfileHookChoice(action: .repair, refusal: nil))
        #expect(choice(.broken([.binaryNotFound])) == ProfileHookChoice(action: .repair, refusal: nil))
        #expect(choice(.installed) == ProfileHookChoice(action: .remove, refusal: nil))
        #expect(choice(.codexNeedsTrust(untrustedEvents: ["Stop"])) == ProfileHookChoice(action: .remove, refusal: nil))

        // Open Island running refuses nothing: Juice's hooks name its own helper (P900).
        #expect(choice(.hasComments(file: "settings.json"), running: true).refusal == .hasComments(file: "settings.json"))
        #expect(choice(.installed, running: true) == ProfileHookChoice(action: .remove, refusal: nil))
        // Hooks that still call Open Island's helper offer Repair, which Agents calls Move (P903).
        #expect(choice(.oldHelper(entries: 14)) == ProfileHookChoice(action: .repair, refusal: nil))
        #expect(choice(.folderMissing) == ProfileHookChoice(action: nil, refusal: .folderMissing))
        #expect(choice(.linkedConfig(file: "config.toml")) == ProfileHookChoice(action: nil, refusal: .linkedConfig(file: "config.toml")))
        #expect(choice(.hasComments(file: "hooks.json")).refusal == .hasComments(file: "hooks.json"))
        #expect(choice(.unreadable(file: "settings.json")).refusal == .unreadable(file: "settings.json"))
        #expect(choice(.blockedByOtherIsland(vibeEntries: 14), vibe: 14) == ProfileHookChoice(action: .install, refusal: .otherIslandHooks(count: 14)))
        // Ours complete next to Vibe Island's: Remove takes Juice's own entries only, so it goes ahead (P904).
        #expect(choice(.installed, vibe: 14) == ProfileHookChoice(action: .remove, refusal: nil))
        // No helper in this build: Install and Repair wait, Remove does not need it.
        #expect(choice(.notInstalled, helper: false).refusal == .helperMissing)
        #expect(choice(.partial(installed: 3, expected: 4), helper: false).refusal == .helperMissing)
        #expect(choice(.installed, helper: false).refusal == nil)
        #expect(!choice(.folderMissing).isAvailable && choice(.notInstalled).isAvailable)

        #expect(ProfileHookRefusal(.otherIslandHooksPresent(count: 2)) == .otherIslandHooks(count: 2))
        #expect(ProfileHookRefusal(.invalidConfig(file: "config.toml")) == .unreadable(file: "config.toml"))
        #expect(ProfileHookRefusal(.bundledHelperMissing) == .helperMissing)
        #expect(ProfileHookRefusal(.writeFailed("x")) == .writeFailed)
    }

    /// The button never offers what a click would refuse: for each refusal fixture, the click throws the same reason,
    /// and every file in the sandbox (the helpers included) stays byte-identical.
    @Test
    func everyRefusalMatchesTheClickAndLeavesEveryFileByteIdentical() async throws {
        let vibe = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/sh -c '$HOME/.vibe-island/bin/vibe-island-bridge --source claude'"}]}]}}"#
        let cases: [(Sandbox) throws -> ProfileHookTarget] = [
            { try $0.profile(.claude, ".claude-vibe", files: ["settings.json": vibe]) },
            { try $0.profile(.claude, ".claude-lab", files: ["settings.json": "{ // mine\n \"model\": \"opus\" }"]) },
            { try $0.profile(.codex, ".codex-side", files: ["hooks.json": "[1, 2]"]) },
            { box in
                let target = try box.profile(.codex, ".codex-preset", files: ["config.toml": "model = \"gpt-5\"\n"])
                let elsewhere = box.root.appendingPathComponent("dotfiles-hooks.json")
                try Data("{}".utf8).write(to: elsewhere)
                try FileManager.default.createSymbolicLink(at: box.url(target, "hooks.json"), withDestinationURL: elsewhere)
                return target
            },
            // P23: a settings.json nobody may read, and a config.toml with a byte that isn't UTF-8.
            { box in
                let target = try box.profile(.claude, ".claude-work", files: ["settings.json": #"{"model":"opus"}"#])
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: box.url(target, "settings.json").path)
                return target
            },
            { box in
                let target = try box.profile(.codex, ".codex-fresh")
                try (Data("model = \"gpt-5\"\n".utf8) + [0xFF]).write(to: box.url(target, "config.toml"))
                return target
            },
            // A folder that is gone: nothing may create it.
            { box in
                ProfileHookTarget(provider: .codex, folder: box.root.appendingPathComponent(".codex-gone").path, alias: "gone",
                                  isDefaultFolder: false, accountID: nil, isMonitored: true)
            },
        ]
        for (make, openIslandRunning) in cases.map({ ($0, false) }) {
            let box = try Sandbox()
            let target = try make(box)
            let manager = box.manager(openIslandRunning: openIslandRunning)
            await manager.refresh([target])
            await manager.checkDrift([target])
            let choice = try #require(manager.choice(for: target.id))
            let refusal = try #require(choice.refusal)
            let before = try box.snapshot()
            // Vibe Island's hooks hold Install and Repair only: Remove takes Juice's own entries, none here, and writes
            // nothing (P904).
            if case .otherIslandHooks = refusal { try await manager.remove(target) }
            let clicks: [ProfileHookAction] = if case .otherIslandHooks = refusal { [.install, .repair] } else { [.install, .repair, .remove] }
            for click in clicks {
                do {
                    switch click {
                    case .install: try await manager.install(target)
                    case .repair: try await manager.repair(target)
                    case .remove: try await manager.remove(target)
                    }
                    Issue.record("\(click) went ahead in \(target.alias)")
                } catch let error as ProfileHookError {
                    #expect(ProfileHookRefusal(error) == refusal)
                }
            }
            #expect(try box.snapshot() == before)
            #expect(!FileManager.default.fileExists(atPath: box.managedHelper.path))
        }
    }

    @Test
    func withoutTheBundledHelperInstallAndRepairAreRefusedAndNothingIsWritten() async throws {
        let box = try Sandbox(helper: false)
        let claude = try box.profile(.claude, ".claude-work", files: ["settings.json": #"{"model":"opus"}"#])
        let codex = try box.profile(.codex, ".codex-fresh", files: ["auth.json": "{}"])
        let manager = box.manager()
        await manager.refresh([claude, codex])
        #expect(!manager.hasBundledHelper)
        #expect(manager.choice(for: claude.id) == ProfileHookChoice(action: .install, refusal: .helperMissing))
        let before = try box.snapshot()
        for target in [claude, codex] {
            await #expect(throws: ProfileHookError.bundledHelperMissing) { try await manager.install(target) }
            await #expect(throws: ProfileHookError.bundledHelperMissing) { try await manager.repair(target) }
        }
        #expect(try box.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: box.managedHelper.path))
        #expect(box.intents.intent(for: claude.id) == .untouched)
    }

    // MARK: Drift

    @Test
    func aDriftCheckRaisesTheRowShowsPartialAndIgnoresAFileBeingEdited() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work")
        let manager = box.manager()
        await manager.refresh([target])
        try await manager.install(target)
        #expect(manager.driftAlerts.isEmpty)
        #expect(manager.driftReadings[target.id] == .complete)

        // Someone deletes our PreToolUse entry.
        let settings = box.url(target, "settings.json")
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["PreToolUse"] = nil
        root["hooks"] = hooks
        let drifted = try JSONSerialization.data(withJSONObject: root)
        try drifted.write(to: settings)
        await manager.refresh(only: [target])
        await manager.checkDrift([target])
        let alert = try #require(manager.driftAlerts[target.id])
        #expect(alert.text == "Hooks missing in work · Repair")
        #expect(manager.missingEntries(for: target.id) == [HookEntrySpec(event: "PreToolUse", matcher: "*", timeout: nil)])
        #expect(manager.setupState(for: target.id) == .partial(installed: 13, expected: 14))
        #expect(manager.choice(for: target.id) == ProfileHookChoice(action: .repair, refusal: nil))

        // Half-written, then empty: being edited, nothing changes.
        for data in [drifted.prefix(drifted.count / 2), Data()] {
            try Data(data).write(to: settings)
            await manager.checkDrift([target])
            #expect(manager.driftAlerts[target.id] == alert)
        }

        // Repair, on a click, clears it.
        try drifted.write(to: settings)
        try await manager.repair(target)
        #expect(manager.driftAlerts.isEmpty)
        #expect(manager.setupState(for: target.id) == .installed)

        // The owner's own Remove raises nothing.
        try await manager.remove(target)
        #expect(manager.driftAlerts.isEmpty)
        #expect(manager.setupState(for: target.id) == .notInstalled)
    }

    /// A default profile Open Island hooked: its first complete reading records it as installed, so a later loss of
    /// every entry raises the row, after a relaunch (a new manager) too.
    @Test
    func aProfileHookedElsewhereAlertsWhenItsHooksGoEvenAfterARelaunch() async throws {
        let box = try Sandbox()
        let command = ClaudeHookInstaller.hookCommand(for: box.managedHelper.path, source: "claude")
        let contents = try #require(try ClaudeHookInstaller.installSettingsJSON(existingData: nil, hookCommand: command).contents)
        let target = try box.profile(.claude, ".claude-lab")
        try contents.write(to: box.url(target, "settings.json"))
        let first = box.manager()
        await first.refresh([target])
        await first.checkDrift([target])
        #expect(first.driftAlerts.isEmpty)
        #expect(box.intents.intent(for: target.id) == .installed)

        try Data(#"{"model":"opus"}"#.utf8).write(to: box.url(target, "settings.json"))
        let relaunched = box.manager()
        await relaunched.refresh([target])
        await relaunched.checkDrift([target])
        #expect(relaunched.driftAlerts[target.id]?.missing.count == 14)
        #expect(relaunched.choice(for: target.id)?.action == .install)
    }

    /// Checking, refreshing and every trigger only read: a drifted profile stays drifted, and no file changes.
    @Test
    func checksNeverWriteOrRepair() async throws {
        let box = try Sandbox()
        let target = try box.profile(.codex, ".codex-side", files: ["config.toml": "model = \"gpt-5\"\n"])
        let manager = box.manager()
        await manager.refresh([target])
        try await manager.install(target)
        var root = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: box.url(target, "hooks.json"))) as? [String: Any])
        var hooks = try #require(root["hooks"] as? [String: Any])
        hooks["Stop"] = nil
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: box.url(target, "hooks.json"))
        let before = try box.snapshot()

        let clock = ManualClock()
        var finished = 0
        let monitor = HookDriftMonitor(watch: { _, _ in nil }, schedule: clock.schedule, now: clock.now) { targets, _ in
            await manager.refresh(only: targets)
            await manager.checkDrift(targets)
            finished += 1
        }
        await monitor.launch([target])
        await monitor.wake()
        await monitor.profilesChanged([target])
        monitor.fileChanged(target.id)
        await clock.advance(by: 3)
        for _ in 0..<300 where finished < 4 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(finished == 4)
        #expect(monitor.recentChecks.map(\.reason) == [.launch, .wake, .profileChange, .fileEvent])
        #expect(manager.driftAlerts[target.id]?.missing.map(\.event) == ["Stop"])
        #expect(manager.setupState(for: target.id) == .partial(installed: 3, expected: 4))
        #expect(try box.snapshot() == before)
    }

    // MARK: When checks run

    final class FakeWatch: HookWatchToken {
        let target: ProfileHookTarget
        let fire: @MainActor @Sendable () -> Void
        var cancelled = false
        init(_ target: ProfileHookTarget, _ fire: @escaping @MainActor @Sendable () -> Void) {
            self.target = target
            self.fire = fire
        }
        func cancel() { cancelled = true }
    }

    /// A clock the test moves by hand; scheduled work runs when its time comes.
    @MainActor
    final class ManualClock: @unchecked Sendable {
        private(set) var current = Date(timeIntervalSince1970: 1_800_000_000)
        private var pending: [(at: Date, work: @MainActor @Sendable () -> Void)] = []

        nonisolated var now: @Sendable () -> Date { { [unowned self] in MainActor.assumeIsolated { self.current } } }

        var schedule: HookDriftMonitor.Schedule {
            { [unowned self] delay, work in self.pending.append((self.current.addingTimeInterval(delay), work)) }
        }

        func advance(by seconds: TimeInterval) async {
            let end = current.addingTimeInterval(seconds)
            while let next = pending.enumerated().filter({ $0.element.at <= end }).min(by: { $0.element.at < $1.element.at }) {
                pending.remove(at: next.offset)
                current = next.element.at
                next.element.work()
                for _ in 0..<20 { await Task.yield() }
            }
            current = end
            for _ in 0..<20 { await Task.yield() }
        }
    }

    /// The sleep and the wall clock are different clocks: a wake-up that comes when the file has been quiet for a hair
    /// under 2 s by `now` checks again shortly instead of dropping the burst.
    @Test
    func aWakeUpThatComesAHairEarlyStillChecks() async {
        final class Wall: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }
        let wall = Wall()
        let target = ProfileHookTarget(provider: .claude, folder: "/tmp/ji-fixture/.claude-work", alias: "work",
                                       isDefaultFolder: false, accountID: nil, isMonitored: true)
        var scheduled: [(delay: TimeInterval, work: @MainActor @Sendable () -> Void)] = []
        var checks: [HookDriftMonitor.Reason] = []
        let monitor = HookDriftMonitor(watch: { _, _ in nil }, schedule: { delay, work in scheduled.append((delay, work)) },
                                       now: { wall.now }) { _, reason in checks.append(reason) }
        await monitor.launch([target])
        let start = wall.now
        monitor.fileChanged(target.id)
        #expect(scheduled.map(\.delay) == [2])

        wall.now = start.addingTimeInterval(1.99)
        scheduled.removeFirst().work()
        for _ in 0..<20 { await Task.yield() }
        #expect(checks == [.launch])
        #expect(scheduled.count == 1)
        guard !scheduled.isEmpty else { return }

        wall.now = start.addingTimeInterval(2.05)
        scheduled.removeFirst().work()
        for _ in 0..<20 { await Task.yield() }
        #expect(checks == [.launch, .fileEvent])
        #expect(scheduled.isEmpty)
    }

    @Test
    func fileEventsCheckOnlyThatProfileTwoSecondsAfterTheLastEvent() async throws {
        let claude = ProfileHookTarget(provider: .claude, folder: "/tmp/ji-fixture/.claude-work", alias: "work",
                                       isDefaultFolder: false, accountID: nil, isMonitored: true)
        let codex = ProfileHookTarget(provider: .codex, folder: "/tmp/ji-fixture/.codex-side", alias: "side",
                                      isDefaultFolder: false, accountID: nil, isMonitored: true)
        let clock = ManualClock()
        var watches: [FakeWatch] = []
        var checks: [(HookDriftMonitor.Reason, [String])] = []
        let monitor = HookDriftMonitor(watch: { target, fire in
            let watch = FakeWatch(target, fire)
            watches.append(watch)
            return watch
        }, schedule: clock.schedule, now: clock.now) { targets, reason in checks.append((reason, targets.map(\.alias))) }

        await monitor.launch([claude, codex])
        #expect(watches.map(\.target.alias) == ["work", "side"])
        #expect(checks.map(\.1) == [["work", "side"]])

        // Truncated JSON at 0, the valid file 0.5 s later, and one event in the other profile at 0.2 s.
        watches[0].fire()
        await clock.advance(by: 0.2)
        watches[1].fire()
        await clock.advance(by: 0.3)
        watches[0].fire()
        await clock.advance(by: 1.9)
        #expect(checks.count == 2)
        #expect(checks.last?.1 == ["side"])
        await clock.advance(by: 0.2)
        #expect(checks.count == 3)
        #expect(checks.last?.0 == .fileEvent)
        #expect(checks.last?.1 == ["work"])
        await clock.advance(by: 10)
        #expect(checks.count == 3)

        await monitor.wake()
        #expect(checks.last?.0 == .wake)
        #expect(checks.last?.1 == ["work", "side"])

        // A profile goes: its watch stops, its late events are ignored, and the new list is checked.
        await monitor.profilesChanged([claude])
        #expect(watches[1].cancelled && !watches[0].cancelled)
        #expect(checks.last?.0 == .profileChange)
        #expect(checks.last?.1 == ["work"])
        monitor.fileChanged(codex.id)
        await clock.advance(by: 5)
        #expect(checks.last?.0 == .profileChange)
        monitor.stop()
        #expect(watches[0].cancelled)
    }

    /// The real watcher, in a temporary folder: an atomic save and a write in place both call back; a cancelled watch
    /// stays quiet. It opens nothing but the folder and the three config names, for events only.
    @Test
    func theFolderWatcherSeesAtomicSavesAndWritesInPlace() async throws {
        let box = try Sandbox()
        let target = try box.profile(.claude, ".claude-work", files: ["settings.json": "{}"])
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let counter = Counter()
        let watcher = try #require(ConfigFolderWatcher.watch(target) { counter.bump() })
        func waitForMore(than count: Int) async {
            for _ in 0..<300 where counter.count <= count { try? await Task.sleep(for: .milliseconds(10)) }
        }

        try Data(#"{"model":"opus"}"#.utf8).write(to: box.url(target, "settings.json"), options: .atomic)
        await waitForMore(than: 0)
        #expect(counter.count > 0)

        let afterAtomic = counter.count
        let handle = try FileHandle(forWritingTo: box.url(target, "settings.json"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(" ".utf8))
        try handle.close()
        await waitForMore(than: afterAtomic)
        #expect(counter.count > afterAtomic)

        watcher.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        let afterCancel = counter.count
        try Data("{}".utf8).write(to: box.url(target, "settings.json"), options: .atomic)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == afterCancel)
        #expect(ConfigFolderWatcher(folder: box.root.appendingPathComponent(".claude-gone").path, files: ["settings.json"]) {} == nil)
    }
}
