import Foundation
import JuiceCore
import Testing
@testable import JuiceIslandUI

/// The live readers' rules outside JuiceCore, on `LiveFakes` with a temp home folder: fictional folders and example.com
/// emails, no CLI, no login shell and no real login file.
@MainActor
@Suite(.serialized)
struct ReaderRulesTests {
    typealias F = LiveFakes

    /// A model on the fakes whose discovery is the real one, over `home`.
    private static func model(_ fakes: LiveFakes, home: String) -> LiveUsageModel {
        var readers = fakes.readers
        readers.discover = { LiveReaders.discoverProfiles(home: home) }
        let clock = fakes.clock
        return LiveUsageModel(directory: fakes.directory, readers: readers, juiceGuard: fakes.juiceGuard, clock: { clock.now },
                              makeScheduler: { fakes.scheduler() })
    }

    /// P66: Settings › Accounts finds folders by which files exist and opens none. A `.claude.json` nobody may read still
    /// marks its folder, and one anyone may read, holding an email, gives none: the alias is the folder's, and a folder
    /// added from the list carries no email until its CLI answers.
    /// P110: the live model's Codex pool is JuiceCore's with its release values (servers stop after 2 min asked
    /// nothing, four at most), never one that keeps every home's server.
    @Test func theAppsCodexPoolStopsIdleServers() {
        let pool = CodexBackend.readerPool(executable: URL(fileURLWithPath: "/tmp/juice-test-cli/codex"))
        #expect(pool.idleTimeout == .seconds(120))
        #expect(pool.maxServers == 4)
    }

    @Test func settingsFindsFoldersWithoutOpeningALoginFile() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        let home = try fakes.tempHome()
        let fm = FileManager.default
        func make(_ name: String, _ file: String, _ text: String = "{}") throws {
            try fm.createDirectory(atPath: home + "/" + name, withIntermediateDirectories: false)
            try text.write(toFile: home + "/" + name + "/" + file, atomically: true, encoding: .utf8)
        }
        try make(".claude", ".claude.json", #"{"oauthAccount":{"emailAddress":"someone@example.com","organizationName":"Example"}}"#)
        try make(".claude-work", ".claude.json")
        try make(".codex", "config.toml")
        try make(".codex-side", "auth.json")
        let locked = [home + "/.claude-work/.claude.json", home + "/.codex-side/auth.json"]
        for path in locked { try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path) }
        defer { for path in locked { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) } }

        let found = LiveReaders.discoverProfiles(home: home)
        #expect(found.map(\.folder) == [".claude", ".claude-work", ".codex", ".codex-side"].map { home + "/" + $0 })
        #expect(found.map(\.suggestedAlias) == ["Claude", "work", "Codex", "side"])
        #expect(found.allSatisfy { $0.knownEmail == nil && $0.knownPlan == nil })

        try fakes.writeStore(accounts: [])
        let model = Self.model(fakes, home: home)
        defer { model.stop() }
        model.start()
        await model.settle()
        model.refreshDiscovery()
        await model.discovery?.value
        #expect(model.discovered.map(\.folder) == found.map(\.folder))
        model.add(try #require(model.discovered.first))
        #expect(model.account(id: found[0].id)?.alias == "Claude")
        #expect(model.account(id: found[0].id)?.knownEmail == nil)
        let saved = try String(contentsOf: fakes.directory.appendingPathComponent("accounts.json"), encoding: .utf8)
        #expect(!saved.contains("someone@example.com") && !saved.contains("Example"))
    }

    /// P107: a read that finds no CLI (a reinstall moved it, or it was removed) has the CLI looked for again. Found
    /// elsewhere, it is wired afresh: the old Codex backend's app-servers stop, and the login that failed is read at once
    /// through the new one, not an hour later. Not found, the provider is missing, as at launch, and Refresh all looks.
    @Test func aReadThatFindsNoCLILooksForItAgain() async throws {
        let fakes = try LiveFakes()
        defer { fakes.cleanUp() }
        try fakes.writeStore(accounts: [F.side])
        let located = LockedBox<[Provider: URL]>([.claude: URL(fileURLWithPath: "/fake/bin/claude"),
                                                  .codex: URL(fileURLWithPath: "/fake/bin/codex")])
        let log = fakes.log
        var readers = fakes.readers
        let codex = readers.codex
        readers.locate = { provider in
            log.withValue { $0.append("locate \(provider.rawValue)") }
            return located.withValue { $0[provider] }
        }
        readers.codex = { url in
            log.withValue { $0.append("backend \(url.path)") }
            return codex(url)
        }
        let clock = fakes.clock
        let model = LiveUsageModel(directory: fakes.directory, readers: readers, juiceGuard: fakes.juiceGuard, clock: { clock.now },
                                   makeScheduler: { fakes.scheduler() })
        defer { model.stop() }
        model.start()
        await model.settle()
        let login = try #require(model.loginID(of: F.side))
        #expect(fakes.reads == ["read \(F.side.id)"])
        #expect(fakes.entries.filter { $0.hasPrefix("backend") } == ["backend /fake/bin/codex"])

        // The CLI moved: the next read finds none, and the search finds it elsewhere.
        fakes.clock.now += 60
        fakes.codexFailure.withValue { $0 = .cliNotFound }
        located.withValue { $0[.codex] = URL(fileURLWithPath: "/fake/other/codex") }
        let before = fakes.entries.count
        await model.settle()
        fakes.codexFailure.withValue { $0 = nil }
        await model.relocation?.value
        await model.stopping?.value
        let after = Array(fakes.entries[before...])
        #expect(after == ["read \(F.side.id)", "locate codex", "backend /fake/other/codex", "shutdownAll"])
        #expect(model.codexExecutable?.path == "/fake/other/codex" && model.scheduler.nextDue(for: login) == fakes.clock.now)
        await model.settle()
        #expect(fakes.reads.count == 3 && model.records[login]?.lastError == nil)

        // Gone for good: the provider is missing, its logins' reads launch nothing, and Refresh all looks again.
        fakes.clock.now += 60
        fakes.codexFailure.withValue { $0 = .cliNotFound }
        located.withValue { $0[.codex] = nil }
        await model.settle()
        fakes.codexFailure.withValue { $0 = nil }
        await model.relocation?.value
        await model.stopping?.value
        #expect(model.codexExecutable == nil && model.missingCLIs == [.codex] && model.cliNotFound == [.codex])
        #expect(model.records[login]?.lastError == .cliNotFound)
        let reads = fakes.reads.count
        fakes.clock.now += 3_600
        await model.settle()
        await model.relocation?.value
        #expect(fakes.reads.count == reads)                                  // no backend: nothing launched
        located.withValue { $0[.codex] = URL(fileURLWithPath: "/fake/bin/codex") }
        model.refreshAll()
        await model.settle()
        #expect(model.codexExecutable?.path == "/fake/bin/codex" && fakes.reads.count == reads + 1)
    }
}
