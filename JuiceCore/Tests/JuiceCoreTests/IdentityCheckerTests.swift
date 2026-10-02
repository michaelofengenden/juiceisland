import Foundation
import Testing
@testable import JuiceCore

private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

private func byteCount(of url: URL) -> Int {
    (try? Data(contentsOf: url).count) ?? 0
}

private func codexEnvironment() throws -> [String: String] {
    ["FAKE_ACCOUNT": try fixtureURL("codex-account", "json").path,
     "FAKE_LIMITS": try fixtureURL("codex-ratelimits", "json").path]
}

@Test func cancellingTheClaudeCheckStopsTheCLI() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("juice-auth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let ticks = folder.appendingPathComponent("ticks")
    let account = Account(provider: .claude, folder: folder.path, alias: "hang")
    let checker = CLIIdentityChecker(claudeExecutable: try fixtureURL("fake-claude-hang", "sh"), codexPool: nil)

    let check = Task { await checker.identity(for: account) }
    #expect(await waitUntil { byteCount(of: ticks) > 0 })   // the fake `claude auth status` is running
    check.cancel()
    _ = await check.value

    // Cancelling ends the line stream; a check that just returned then would leave the CLI ticking behind it.
    let atCancel = byteCount(of: ticks)
    try await Task.sleep(for: .milliseconds(300))
    #expect(byteCount(of: ticks) == atCancel)
}

@Test func codexIdentityIsCheckedThroughAFreshAppServer() async throws {
    let account = Account(provider: .codex, folder: "/tmp/juice-identity-codex", alias: "default")
    let pool = CodexReaderPool(executable: try fixtureURL("fake-codex", "sh"), timeout: .seconds(10),
                               extraEnvironment: try codexEnvironment())
    _ = try await pool.read(account, now: Date()).get()
    let beforeLogin = try #require(await pool.processIdentifier(folder: account.folder))

    // A login just happened in this folder: the app-server that was already up can still answer from the session
    // it had before, so the check has to read through a new one.
    let checker = CLIIdentityChecker(claudeExecutable: nil, codexPool: pool)
    let identity = try await checker.identity(for: account).get()
    #expect(identity.email == "someone@example.com")
    #expect(identity.plan == "pro")
    let afterLogin = try #require(await pool.processIdentifier(folder: account.folder))
    #expect(afterLogin != beforeLogin)
    await pool.shutdownAll()
}
