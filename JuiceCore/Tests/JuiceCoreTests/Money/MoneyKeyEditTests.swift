import Darwin
import Foundation
import Synchronization
import Testing
@testable import JuiceCore

/// Settings › Money's Add key, Replace and Remove (Juice Island spec §8 decision 13): the key the owner types becomes
/// the source's own key file, 0600 in a 0700 folder, and is refused before anything is written when a source may not
/// send it; Remove deletes that file and nothing else; the scheduler drops the old key's figures and reads once, soon,
/// within its floors. Temporary homes and fake keys only.
@Suite struct MoneyKeyEditTests {
    private func mode(_ path: String) -> mode_t? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return info.st_mode
    }

    private func exists(_ path: String) -> Bool { mode(path) != nil }

    private func text(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }

    /// Waits up to 3 s for `condition`.
    private func until(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func eachSourceWritesItsOwnFileFirstInTheLookup() {
        #expect(MoneySource.allCases.map(\.defaultKeyPath) == [
            "~/.config/openrouter/key", "~/.config/anthropic/admin-key", "~/.config/openai/admin-key", "~/.config/runpod/key",
            "~/.config/hetzner/token", "~/.config/deepseek/key", "~/.config/moonshot/key", "~/.config/xai/management-key",
            "~/.config/fireworks/key", "~/.config/fal/admin-key", "~/.config/elevenlabs/key", "~/.config/vastai/key",
            "~/.config/digitalocean/token",
        ])
        // A source's first key is its own account; a further key sits beside it, and is its only place.
        #expect(MoneyAccount.firsts.map(\.defaultKeyPath) == MoneySource.allCases.map(\.defaultKeyPath))
        #expect(MoneyAccount(.openRouter, slot: 2).lookupPaths == ["~/.config/openrouter/key-2"])
        #expect(MoneyAccount(.anthropic, slot: 4).defaultKeyPath == "~/.config/anthropic/admin-key-4")
        #expect(MoneySource.hetzner.lookupPaths.contains("~/.config/hcloud/api-key"))
        // xAI and fal.ai take a management or admin key only, never another tool's inference key beside it; Vast.ai's
        // CLI keeps its full-access key under a name the lookup never tries.
        #expect(MoneySource.xAI.lookupPaths == ["~/.config/xai/management-key", "~/.config/xai/management_key"])
        #expect(MoneySource.fal.lookupPaths == ["~/.config/fal/admin-key", "~/.config/fal/admin_key"])
        #expect(!MoneySource.vastAI.lookupPaths.contains { $0.hasSuffix("vast_api_key") })
        #expect(MoneySource.allCases.allSatisfy { $0.lookupPaths.count == $0.configFolders.count * $0.keyFileNames.count })
    }

    @Test func addKeyWritesTheFile0600InNew0700Folders() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        let path = try MoneyKeyFile.write("  \(FakeKeys.openRouter)\n", for: .openRouter, guard: fence)
        #expect(path == "~/.config/openrouter/key")
        let file = home.path + "/.config/openrouter/key"
        #expect(mode(file).map { $0 & S_IFMT } == S_IFREG)
        #expect(mode(file).map { $0 & 0o777 } == 0o600)
        #expect(mode(home.path + "/.config").map { $0 & 0o777 } == 0o700)
        #expect(mode(home.path + "/.config/openrouter").map { $0 & 0o777 } == 0o700)
        #expect(try text(file) == FakeKeys.openRouter + "\n")
        // The reads find it and read it back; no temporary file is left beside it.
        #expect(MoneyKeyFile.path(for: .openRouter, picked: nil, guard: fence) == path)
        #expect(try MoneyKeyFile.read(path, guard: fence).value == FakeKeys.openRouter)
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path + "/.config/openrouter") == ["key"])
        // Every source, with a key it may send.
        let keys: [MoneySource: String] = [.anthropic: FakeKeys.anthropicAdmin, .openAI: FakeKeys.openAIAdmin, .runPod: FakeKeys.runPod,
                                           .hetzner: FakeKeys.hetzner]
        for (source, key) in keys {
            let written = try MoneyKeyFile.write(key, for: MoneyAccount(source), guard: fence)
            #expect(written == source.defaultKeyPath)
            #expect(try MoneyKeyFile.read(written, guard: fence).value == key)
            #expect(mode(MoneyKeyFile.expand(written, home: home.path)).map { $0 & 0o777 } == 0o600)
        }
    }

    @Test func aFolderThatExistsKeepsItsModeAndAnOldKeyIsReplacedWhole() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        let old = try home.write(".config/runpod/key", "rpa_OLDOLDOLDOLDOLD")
        chmod(home.path + "/.config/runpod", 0o755)
        chmod(old, 0o644)
        // A second name for the old key file elsewhere: the new key never goes into it.
        let other = home.path + "/other-name"
        try FileManager.default.linkItem(atPath: old, toPath: other)
        try MoneyKeyFile.write(FakeKeys.runPod, for: .runPod, guard: fence)
        #expect(mode(home.path + "/.config/runpod").map { $0 & 0o777 } == 0o755)
        #expect(mode(old).map { $0 & 0o777 } == 0o600)
        #expect(try text(old) == FakeKeys.runPod + "\n")
        #expect(try text(other) == "rpa_OLDOLDOLDOLDOLD")
        #expect(try MoneyKeyFile.read(old, guard: fence).value == FakeKeys.runPod)
    }

    /// A key file in a later place may be another tool's (a plain `api_key` beside the admin key): Replace writes the
    /// source's own file before it, which the reads then use, and never writes over it. Remove names it as the file read
    /// next.
    @Test func replaceNeverWritesOverAKeyFileInALaterPlace() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        let other = try home.write(".config/openai/api_key", "sk-proj-FAKEFAKEOTHERTOOL")
        #expect(MoneyKeyFile.path(for: .openAI, picked: nil, guard: fence) == "~/.config/openai/api_key")
        let path = try MoneyKeyFile.write(FakeKeys.openAIAdmin, for: .openAI, guard: fence)
        #expect(path == "~/.config/openai/admin-key")
        #expect(try text(other) == "sk-proj-FAKEFAKEOTHERTOOL")
        #expect(MoneyKeyFile.path(for: .openAI, picked: nil, guard: fence) == path)
        #expect(try MoneyKeyFile.read(path, guard: fence).value == FakeKeys.openAIAdmin)
        #expect(MoneyKeyFile.removal(for: .openAI, picked: nil, guard: fence) == .delete(path))
        #expect(MoneyKeyFile.next(after: path, for: .openAI, guard: fence) == "~/.config/openai/api_key")
        // Hetzner's key goes to the hetzner folder; the one in hcloud stays, and is read next.
        let hcloud = try home.write(".config/hcloud/token", "FAKEOLDOLDOLD")
        #expect(try MoneyKeyFile.write(FakeKeys.hetzner, for: .hetzner, guard: fence) == "~/.config/hetzner/token")
        #expect(try text(hcloud) == "FAKEOLDOLDOLD")
        #expect(MoneyKeyFile.next(after: "~/.config/hetzner/token", for: .hetzner, guard: fence) == "~/.config/hcloud/token")
        try MoneyKeyFile.delete("~/.config/hcloud/token", for: .hetzner, guard: fence)
        #expect(MoneyKeyFile.next(after: "~/.config/hetzner/token", for: .hetzner, guard: fence) == nil)
        // A file picked elsewhere gives way to the lookup's first file.
        let picked = try home.write("keys/hetzner.txt", "FAKEPICKED")
        #expect(MoneyKeyFile.next(after: picked, for: .hetzner, guard: fence) == "~/.config/hetzner/token")
    }

    @Test func aLinkWhereTheKeyWasIsReplacedNeverFollowed() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        let target = try home.write("elsewhere/target", "untouched")
        try FileManager.default.createDirectory(atPath: home.path + "/.config/openrouter", withIntermediateDirectories: true)
        let key = home.path + "/.config/openrouter/key"
        try FileManager.default.createSymbolicLink(atPath: key, withDestinationPath: target)
        try MoneyKeyFile.write(FakeKeys.openRouter, for: .openRouter, guard: fence)
        #expect(mode(key).map { $0 & S_IFMT } == S_IFREG)
        #expect(try text(target) == "untouched")
        // A link from the key's place to a Claude credential file is replaced too; the credential file is left alone.
        let credential = try home.write(".claude-work/.credentials.json", "{}")
        try FileManager.default.createDirectory(atPath: home.path + "/.config/runpod", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.path + "/.config/runpod/key", withDestinationPath: credential)
        try MoneyKeyFile.write(FakeKeys.runPod, for: .runPod, guard: fence)
        #expect(try text(credential) == "{}")
        #expect(mode(home.path + "/.config/runpod/key").map { $0 & S_IFMT } == S_IFREG)
    }

    @Test func aKeyASourceMayNotSendIsNeverWritten() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        let refused: [(MoneySource, String, MoneyKeyEditError)] = [
            (.openRouter, FakeKeys.claudeOAuth, .signInToken),
            (.anthropic, FakeKeys.claudeRefresh, .signInToken),
            (.openAI, #"{"t":"\#(FakeKeys.claudeOAuth)"}"#, .signInToken),
            (.openAI, FakeKeys.signInJWT, .signInToken),
            (.hetzner, "Bearer:" + FakeKeys.signInJWT, .signInToken),
            (.anthropic, FakeKeys.anthropicAPI, .notAnAdminKey),
            (.anthropic, FakeKeys.openRouter, .notAnAdminKey),
            (.runPod, FakeKeys.anthropicAdmin, .anthropicKey),
            (.hetzner, FakeKeys.anthropicAPI, .anthropicKey),
            (.openRouter, "", .notAKey),
            (.openRouter, " \n ", .notAKey),
            (.openRouter, "two\nlines", .notAKey),
            (.openRouter, "has space", .notAKey),
            (.hetzner, "ünicode", .notAKey),
            (.runPod, String(repeating: "a", count: 1_025), .notAKey),
        ]
        for (source, key, error) in refused {
            #expect(throws: error, "\(source)") { try MoneyKeyFile.write(key, for: MoneyAccount(source), guard: fence) }
        }
        // Nothing was made: not the file, not even a folder.
        #expect(!exists(home.path + "/.config"))
        // Save refuses exactly what a read refuses before sending.
        let keys = [FakeKeys.openRouter, FakeKeys.anthropicAdmin, FakeKeys.anthropicAPI, FakeKeys.claudeOAuth, FakeKeys.claudeRefresh,
                    FakeKeys.openAIAdmin, FakeKeys.runPod, FakeKeys.hetzner, FakeKeys.signInJWT]
        for source in MoneySource.allCases {
            for key in keys {
                let readRefuses = MoneyHostPolicy.keyRefusal(MoneyKey(key), for: source) != nil
                #expect((MoneyKeyFile.editRefusal(MoneyKey(key), for: source) != nil) == readRefuses, "\(source)")
            }
        }
        // The messages never hold the key.
        for (_, key, error) in refused where !key.isEmpty {
            #expect(!error.message.contains(key))
        }
    }

    @Test func aFolderLinkedIntoARefusedPlaceIsRefused() throws {
        let home = try MoneyTempDir()
        let account = home.path + "/accounts/lab"
        try FileManager.default.createDirectory(atPath: account, withIntermediateDirectories: true)
        let fence = home.fence(accountFolders: [account])
        try FileManager.default.createDirectory(atPath: home.path + "/.claude-work", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: home.path + "/.config", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.path + "/.config/openrouter", withDestinationPath: home.path + "/.claude-work")
        try FileManager.default.createSymbolicLink(atPath: home.path + "/.config/runpod", withDestinationPath: account)
        #expect(throws: MoneyKeyEditError.refused("inside a Claude or Codex folder")) {
            try MoneyKeyFile.write(FakeKeys.openRouter, for: .openRouter, guard: fence)
        }
        #expect(throws: MoneyKeyEditError.refused("inside a monitored account's folder")) {
            try MoneyKeyFile.write(FakeKeys.runPod, for: .runPod, guard: fence)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: home.path + "/.claude-work").isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: account).isEmpty)
        // Remove refuses the same places, and deletes nothing there.
        try home.write(".claude-work/key", "keep")
        #expect(throws: MoneyKeyEditError.refused("inside a Claude or Codex folder")) {
            try MoneyKeyFile.delete("~/.config/openrouter/key", for: .openRouter, guard: fence)
        }
        #expect(try text(home.path + "/.claude-work/key") == "keep")
    }

    @Test func removeDeletesOnlyTheSourcesOwnFile() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        #expect(MoneyKeyFile.removal(for: .hetzner, picked: nil, guard: fence) == nil)
        try MoneyKeyFile.write(FakeKeys.hetzner, for: .hetzner, guard: fence)
        let notes = try home.write(".config/hetzner/notes", "keep")
        let second = try home.write(".config/hcloud/token", FakeKeys.hetzner)
        #expect(MoneyKeyFile.removal(for: .hetzner, picked: nil, guard: fence) == .delete("~/.config/hetzner/token"))
        try MoneyKeyFile.delete("~/.config/hetzner/token", for: .hetzner, guard: fence)
        #expect(!exists(home.path + "/.config/hetzner/token"))
        #expect(exists(notes) && exists(second))
        // The next file the lookup finds is the next one Remove offers; gone twice is no error.
        #expect(MoneyKeyFile.removal(for: .hetzner, picked: nil, guard: fence) == .delete("~/.config/hcloud/token"))
        try MoneyKeyFile.delete("~/.config/hetzner/token", for: .hetzner, guard: fence)
        // A file that is not one of the source's places is never deleted, nor another source's.
        #expect(throws: MoneyKeyEditError.refused("not this source's key file")) {
            try MoneyKeyFile.delete("~/.config/hetzner/notes", for: .hetzner, guard: fence)
        }
        try MoneyKeyFile.write(FakeKeys.runPod, for: .runPod, guard: fence)
        #expect(throws: MoneyKeyEditError.refused("not this source's key file")) {
            try MoneyKeyFile.delete("~/.config/runpod/key", for: .openRouter, guard: fence)
        }
        #expect(exists(notes) && exists(home.path + "/.config/runpod/key"))
    }

    @Test func removeTakesALinkAwayNotItsTarget() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        let target = try home.write("keys/openrouter.txt", FakeKeys.openRouter)
        try FileManager.default.createDirectory(atPath: home.path + "/.config/openrouter", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: home.path + "/.config/openrouter/key", withDestinationPath: target)
        try MoneyKeyFile.delete("~/.config/openrouter/key", for: .openRouter, guard: fence)
        #expect(!exists(home.path + "/.config/openrouter/key"))
        #expect(try text(target) == FakeKeys.openRouter)
    }

    @Test func aFilePickedElsewhereIsForgottenNeverDeleted() throws {
        let home = try MoneyTempDir()
        let fence = home.fence()
        let picked = try home.write("keys/runpod.txt", FakeKeys.runPod)
        #expect(MoneyKeyFile.removal(for: .runPod, picked: picked, guard: fence) == .forget(picked))
        #expect(throws: MoneyKeyEditError.refused("not this source's key file")) {
            try MoneyKeyFile.delete(picked, for: .runPod, guard: fence)
        }
        #expect(exists(picked))
        // A pick that is the source's own place is deleted like any file there.
        try MoneyKeyFile.write(FakeKeys.runPod, for: .runPod, guard: fence)
        #expect(MoneyKeyFile.removal(for: .runPod, picked: "~/.config/runpod/key", guard: fence) == .delete("~/.config/runpod/key"))
    }

    // MARK: The scheduler after a key change

    @Test func readersForgetWhatTheyKept() async throws {
        let server = MoneyStubServer()
        try server.on(.openAICosts, fixture: "openai-costs")
        let reader = CostReportReader(format: OpenAICostFormat())
        let client = server.client()
        let key = MoneyKey(FakeKeys.openAIAdmin)
        _ = try await reader.read(key: key, context: MoneyReadContext(now: MoneyReaderTests.now), client: client)
        _ = try await reader.read(key: key, context: MoneyReadContext(now: MoneyReaderTests.now + 300), client: client)
        await reader.forget()
        _ = try await reader.read(key: key, context: MoneyReadContext(now: MoneyReaderTests.now + 600), client: client)
        let limits = server.received.compactMap { $0.url?.query(percentEncoded: false) }.map { $0.contains("limit=31") }
        // Back to the first of the month, then two days, then back to the first of the month again.
        #expect(limits == [true, false, true])
    }

    @Test func aKeyChangeDropsTheOldFiguresAndReadsSoonWithinTheFloors() async throws {
        let server = MoneyStubServer()
        try server.on(.runPodGraphQL, fixture: "runpod-myself")
        let home = try MoneyTempDir()
        let clock = MoneySchedulerTests.Clock()
        let now = clock.now
        let old = MoneyReading(source: .openAI, readAt: now - 10, figures: .spend(CostFigures(daily: [:], coveredFrom: now)))
        let records: [MoneyAccount: MoneySourceRecord] = [
            // Read 10 s ago: the next read waits out the rest of the 30 s floor.
            .openAI: MoneySourceRecord(lastGood: old, lastAttemptAt: now - 10, keyFileName: "admin-key"),
            // Paused by a 429: the pause holds.
            .openRouter: MoneySourceRecord(lastError: .rateLimited(retryAfter: 60), lastErrorAt: now - 60, lastAttemptAt: now - 60,
                                           pausedUntil: now + 900, consecutiveFailures: 1),
            // Looked 5 s ago and found no key, which sent nothing: read at once.
            .runPod: MoneySourceRecord(lastError: .notConfigured, lastErrorAt: now - 5, lastAttemptAt: now - 5),
            // Hetzner and Anthropic wait out their launch stagger, then stop.
            .hetzner: MoneySourceRecord(pausedUntil: now + 5_000), .anthropic: MoneySourceRecord(pausedUntil: now + 5_000),
        ]
        let waits = Mutex<[TimeInterval]>([])
        let updates = Mutex<[(MoneyAccount, MoneySourceRecord)]>([])
        let money = MoneyScheduler(client: server.client(clock: { clock.now }), records: records, clock: { clock.now },
                                   sleep: { seconds in
                                       waits.withLock { $0.append(seconds) }
                                       throw CancellationError()
                                   },
                                   fence: { home.fence() },
                                   onUpdate: { source, record in updates.withLock { $0.append((source, record)) } })
        await money.start(settings: [:])
        // Every source's loop has taken its first wait (the stagger or a pause) before the key changes.
        try await until { waits.withLock { $0.count } >= MoneySource.allCases.count }
        waits.withLock { $0 = [] }

        try MoneyKeyFile.write(FakeKeys.openAIAdmin, for: .openAI, guard: home.fence())
        await money.keyChanged(.openAI, settings: MoneySourceSettings())
        let reset = try #require(await money.records[.openAI])
        #expect(reset.lastGood == nil && reset.lastError == nil && reset.lastAttemptAt == now - 10)
        #expect(updates.withLock { $0.contains { $0.0 == .openAI && $0.1 == reset } })
        await money.keyChanged(.openRouter, settings: MoneySourceSettings())
        // Still paused, and still saying why.
        let paused = try #require(await money.records[.openRouter])
        #expect(paused.pausedUntil == now + 900 && paused.lastError == .rateLimited(retryAfter: 60) && paused.lastGood == nil)
        try MoneyKeyFile.write(FakeKeys.runPod, for: .runPod, guard: home.fence())
        await money.keyChanged(.runPod, settings: MoneySourceSettings())
        try await until { await money.records[.runPod]?.lastGood != nil }
        try await until { waits.withLock { $0.count } >= 3 }
        await money.stop()

        let seen = waits.withLock { $0 }
        #expect(seen.contains(20))
        #expect(seen.contains(900))
        // RunPod read at once with its new key, then waited its cadence.
        #expect(await money.records[.runPod]?.lastGood != nil)
        #expect(server.count(.runPodGraphQL) == 1)
        #expect(server.received.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(FakeKeys.runPod)")
        #expect(seen.contains(120))
        // Nothing went to OpenAI or OpenRouter while they wait.
        #expect(server.count(.openAICosts) == 0 && server.count(.openRouterKey) == 0)
    }

    @Test func settingsThatAgreeWithTheNewKeyMoveNothing() async throws {
        let server = MoneyStubServer()
        let home = try MoneyTempDir()
        let clock = MoneySchedulerTests.Clock()
        let paused = Dictionary(uniqueKeysWithValues: MoneyAccount.firsts.map { ($0, MoneySourceRecord(pausedUntil: clock.now + 5_000)) })
        let waits = Mutex<[TimeInterval]>([])
        let money = MoneyScheduler(client: server.client(clock: { clock.now }), records: paused, clock: { clock.now },
                                   sleep: { seconds in
                                       waits.withLock { $0.append(seconds) }
                                       throw CancellationError()
                                   },
                                   fence: { home.fence() })
        await money.start(settings: [.runPod: MoneySourceSettings(keyPath: "~/keys/runpod.txt", topUp: 50)])
        try await until { waits.withLock { $0.count } >= MoneySource.allCases.count }
        waits.withLock { $0 = [] }
        // Save drops the pick and restarts the source once; the settings the app sends after it agree, so they restart
        // nothing more. Another key file would.
        await money.keyChanged(.runPod, settings: MoneySourceSettings(topUp: 50))
        await money.update(settings: [.runPod: MoneySourceSettings(topUp: 50)])
        try await until { waits.withLock { $0.count } >= 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(waits.withLock { $0 } == [5_000])
        await money.update(settings: [.runPod: MoneySourceSettings(keyPath: "~/keys/other.txt", topUp: 50)])
        try await until { waits.withLock { $0.count } >= 2 }
        #expect(waits.withLock { $0 } == [5_000, 5_000])
        await money.stop()
        #expect(server.received.isEmpty)
    }
}
