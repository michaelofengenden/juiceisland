import Foundation
import Testing
@testable import JuiceCore

/// P107: a CLI installed one folder per version, the way Codex's standalone installer and Claude's native one lay it
/// out: `<root>/bin/<name>` links to `<root>/current/bin/<name>`, and `current` links to `releases/<version>`. An update
/// points `current` at the new version and may prune the old one. Everything lives in a temp folder; the versions are
/// wrappers around the CLI fakes.
private struct VersionedInstall {
    let root: URL
    let name: String

    init(_ name: String) throws {
        self.name = name
        root = FileManager.default.temporaryDirectory.appendingPathComponent("juice-install-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("releases"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: entry.path, withDestinationPath: root.appendingPathComponent("current/bin/\(name)").path)
    }

    /// The PATH entry, `<root>/bin/<name>`.
    var entry: URL { root.appendingPathComponent("bin/\(name)") }

    /// `releases/<version>/bin/<name>`: a script that runs `fake` with `variables` set.
    func install(_ version: String, running fake: URL, with variables: [String: String]) throws {
        let folder = root.appendingPathComponent("releases/\(version)/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let assignments = variables.sorted { $0.key < $1.key }.map { "\($0.key)='\($0.value)'" }.joined(separator: " ")
        let script = folder.appendingPathComponent(name)
        try "#!/bin/sh\n\(assignments) exec '\(fake.path)' \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    /// Points `current` at a version, as an update does.
    func switchTo(_ version: String) throws {
        let current = root.appendingPathComponent("current")
        try? FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(atPath: current.path, withDestinationPath: root.appendingPathComponent("releases/\(version)").path)
    }

    func prune(_ version: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("releases/\(version)"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The locator hands back the PATH entry, never the version it leads to, keeps it while it is still an executable file
/// (an update and a prune change nothing), and looks again once it is not.
@Test func theLocatorKeepsThePathEntryAndLooksAgainWhenItIsGone() throws {
    let install = try VersionedInstall("codex")
    defer { install.remove() }
    let fake = try fixtureURL("fake-codex", "sh")
    try install.install("1.0", running: fake, with: [:])
    try install.install("2.0", running: fake, with: [:])
    try install.switchTo("1.0")
    let other = install.root.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: other.appendingPathComponent("codex").path, withDestinationPath: fake.path)

    let dirs = [install.root.appendingPathComponent("bin").path, other.path]
    #expect(ToolLocator.find("codex", in: dirs) == install.entry)
    let cache = LockedBox<[String: URL]>([:])
    let searches = LockedBox(0)
    let locate = { ToolLocator.locate("codex", cache: cache) { searches.withValue { $0 += 1 }; return ToolLocator.find("codex", in: dirs) } }
    #expect(locate() == install.entry && searches.withValue { $0 } == 1)

    try install.switchTo("2.0")
    try install.prune("1.0")
    #expect(locate() == install.entry && searches.withValue { $0 } == 1)
    #expect(install.entry.resolvingSymlinksInPath().path.contains("releases/2.0"))

    try FileManager.default.removeItem(at: install.entry)
    #expect(locate() == other.appendingPathComponent("codex") && searches.withValue { $0 } == 2)
    try FileManager.default.removeItem(at: other.appendingPathComponent("codex"))
    #expect(locate() == nil && searches.withValue { $0 } == 3)
}

/// A Codex home's app-server started through the PATH entry keeps running while the version stays, and the first read
/// after an update starts the new version, even once the old one is pruned under the running server.
@Test func aCodexServerMovesToTheCurrentVersionAfterAnUpdate() async throws {
    let install = try VersionedInstall("codex")
    defer { install.remove() }
    let fake = try fixtureURL("fake-codex", "sh")
    try install.install("1.0", running: fake, with: ["FAKE_LIMITS": try fixtureURL("codex-ratelimits", "json").path])
    try install.install("2.0", running: fake, with: ["FAKE_LIMITS": try fixtureURL("codex-ratelimits-exhausted", "json").path])
    try install.switchTo("1.0")
    let account = Account(provider: .codex, folder: "/tmp/juice-test-codex-update", alias: "update")
    let reader = CodexAppServerReader(executable: install.entry, folder: account.folder, timeout: .seconds(10),
                                      extraEnvironment: ["FAKE_ACCOUNT": try fixtureURL("codex-account", "json").path])
    let first = try await reader.read(account, now: Date()).get()
    #expect(first.ordinaryUsageAllowed && first.windows.map(\.usedPercent) == [99])
    let pid = await reader.processIdentifier
    _ = try await reader.read(account, now: Date()).get()
    #expect(await reader.processIdentifier == pid)

    try install.switchTo("2.0")
    try install.prune("1.0")
    let updated = try await reader.read(account, now: Date()).get()
    #expect(!updated.ordinaryUsageAllowed)
    let newPID = await reader.processIdentifier
    #expect(newPID != nil && newPID != pid)
    _ = try await reader.read(account, now: Date()).get()
    #expect(await reader.processIdentifier == newPID)
    await reader.shutdown()
}

/// A Claude read launches through the PATH entry, so each read runs the version that is current then, and one whose
/// entry is gone finds no CLI instead of running a pruned version.
@Test func aClaudeReadRunsTheCurrentVersion() async throws {
    let install = try VersionedInstall("claude")
    defer { install.remove() }
    let fake = try fixtureURL("fake-claude", "sh")
    let usage = try String(contentsOf: try fixtureURL("claude-get-usage", "json"), encoding: .utf8)
    let newer = install.root.appendingPathComponent("usage-2.json")
    try usage.replacingOccurrences(of: #""utilization":5,"#, with: #""utilization":55,"#).write(to: newer, atomically: true, encoding: .utf8)
    try install.install("1.0", running: fake, with: ["FAKE_FIXTURE": try fixtureURL("claude-get-usage", "json").path])
    try install.install("2.0", running: fake, with: ["FAKE_FIXTURE": newer.path])
    try install.switchTo("1.0")
    let account = Account(provider: .claude, folder: "/tmp/juice-test-claude-update", alias: "update")
    let reader = ClaudeCLIReader(executable: install.entry, timeout: .seconds(10))
    #expect(try await reader.read(account, now: Date()).get().windows.map(\.usedPercent) == [5, 13])
    try install.switchTo("2.0")
    try install.prune("1.0")
    #expect(try await reader.read(account, now: Date()).get().windows.map(\.usedPercent) == [55, 13])
    try FileManager.default.removeItem(at: install.entry)
    #expect(await reader.read(account, now: Date()) == .failure(.cliNotFound))
}

/// A CLI found again after reads found none: the logins that failed for want of it are read now, not after the hour a
/// missing CLI waits, and a 429 pause still holds.
@MainActor
@Test func aCLIFoundAgainIsReadAtOnce() async {
    let now = LockedBox(Date(timeIntervalSince1970: 1_900_000_000))
    let missing = LockedBox(true)
    let reads = LockedBox(0)
    let scheduler = RefreshScheduler(policy: RefreshPolicy(), now: { now.withValue { $0 } }, sleep: { _ in })
    let a = Account(provider: .codex, folder: "/h/.codex", alias: "a"), b = Account(provider: .codex, folder: "/h/.codex-side", alias: "b")
    scheduler.setReader({ account, at in
        reads.withValue { $0 += 1 }
        if missing.withValue({ $0 }) { return .failure(.cliNotFound) }
        return .success(AccountReading(accountID: account.id, readAt: at, windows: [UsageWindow(seconds: 18_000, usedPercent: 5, resetsAt: nil)]))
    }, for: .codex)
    scheduler.setAccounts([a, b])
    scheduler.seed(from: [b.id: AccountRecord(lastError: .rateLimited(retryAfter: nil), lastErrorAt: now.withValue { $0 } - 100,
                                               lastAttemptAt: now.withValue { $0 } - 100, consecutiveFailures: 1)])
    let start = now.withValue { $0 }
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(reads.withValue { $0 } == 1 && scheduler.nextDue(for: a.id) == start + 3_600)

    missing.withValue { $0 = false }
    now.withValue { $0 += 10 }
    scheduler.cliFound(for: .claude)
    #expect(scheduler.nextDue(for: a.id) == start + 3_600)
    scheduler.cliFound(for: .codex)
    #expect(scheduler.nextDue(for: a.id) == start + 10)
    #expect(scheduler.nextDue(for: b.id) == start - 100 + 1 + 900)
    await scheduler.tick(); await scheduler.waitForInFlight()
    #expect(reads.withValue { $0 } == 2 && scheduler.nextDue(for: a.id) == start + 10 + 60)
    scheduler.cliFound(for: .codex)                                       // nothing is missing any more
    #expect(scheduler.nextDue(for: a.id) == start + 10 + 60)
}
