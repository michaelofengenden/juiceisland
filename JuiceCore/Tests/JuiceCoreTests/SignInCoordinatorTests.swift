import Foundation
import Testing
@testable import JuiceCore

private struct FakeIdentity: IdentityChecker {
    var result: Result<SignInIdentity, ReadError>
    let calls = LockedBox(0)
    func identity(for account: Account) async -> Result<SignInIdentity, ReadError> {
        calls.withValue { $0 += 1 }
        return result
    }
}

/// An identity check that does not answer until it is released, so a Cancel can land while one is in flight.
private struct BlockingIdentity: IdentityChecker {
    var result: Result<SignInIdentity, ReadError>
    let calls = LockedBox(0)
    private let released = LockedBox(false)

    func release() { released.withValue { $0 = true } }

    func identity(for account: Account) async -> Result<SignInIdentity, ReadError> {
        calls.withValue { $0 += 1 }
        while !released.withValue({ $0 }) { try? await Task.sleep(for: .milliseconds(10)) }
        return result
    }
}

/// Waits for `condition`, returning as soon as it holds. The default is long: in the full JuiceCore run every sign-in
/// test starts its fake CLIs at once, and a flow that takes 0.1 s alone took 4 to 5 s there, past a 5 s wait. A wait
/// that expects nothing to happen passes its own short limit.
@MainActor
private func waitUntil(_ timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@MainActor
private func makeCoordinator(login: String, identity: any IdentityChecker, extra: [String: String] = [:]) throws -> SignInCoordinator {
    let exe = try fixtureURL(login, "sh")
    var config = SignInCoordinator.Configuration(claudeExecutable: exe, codexExecutable: exe)
    config.extraEnvironment = extra
    // Longer than any wait here, so a slow start under load is never read as the CLI timing out.
    config.timeout = .seconds(60)
    return SignInCoordinator(configuration: config, identity: identity)
}

private let claude = Account(provider: .claude, folder: "/tmp/juice-signin", alias: "a", knownEmail: "a@example.com")

@MainActor
@Test func happyPathEndsInDoneWithTheURLCaptured() async throws {
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: "max")))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity)
    coordinator.signIn(claude)
    #expect(coordinator.activeAccount?.id == claude.id)
    #expect(await waitUntil { coordinator.phase == .done(email: "a@example.com") })
    #expect(coordinator.lastURL?.absoluteString == "https://example.com/login/abc123")
    #expect(identity.calls.withValue { $0 } == 1)
    #expect(coordinator.activeAccount == nil)
}

@MainActor
@Test func differentIdentityIsReportedNotFiled() async throws {
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "b@example.com", plan: "pro")))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity)
    var finished: [SignInPhase] = []
    coordinator.onFinished = { _, phase in finished.append(phase) }
    coordinator.signIn(claude)
    #expect(await waitUntil { coordinator.phase == .wrongIdentity(found: "b@example.com", expected: "a@example.com") })
    #expect(finished.isEmpty)   // not finished until the user chooses
    #expect(coordinator.useThisAccount() == "b@example.com")
    #expect(coordinator.phase == .done(email: "b@example.com"))
    #expect(finished == [.done(email: "b@example.com")])
}

@MainActor
@Test func unknownEmailIsAcceptedAsIs() async throws {
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "new@example.com", plan: nil)))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity)
    coordinator.signIn(Account(provider: .codex, folder: "/tmp/juice-signin-codex", alias: "c"))
    #expect(await waitUntil { coordinator.phase == .done(email: "new@example.com") })
}

/// P93: a check that names no email finishes with none, never the account's remembered one, so the folder is placed
/// only by what a CLI reported.
@MainActor
@Test func aCheckWithoutAnEmailFinishesWithNone() async throws {
    let identity = FakeIdentity(result: .success(SignInIdentity(email: nil, plan: "max")))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity)
    coordinator.signIn(claude)
    #expect(await waitUntil { coordinator.phase == .done(email: nil) })
}

@MainActor
@Test func cancelStopsTheCLIAndNeverChecksIdentity() async throws {
    let gate = FileManager.default.temporaryDirectory.appendingPathComponent("juice-gate-\(UUID().uuidString)")
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: nil)))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity, extra: ["FAKE_LOGIN_WAIT": gate.path])
    coordinator.signIn(claude)
    #expect(await waitUntil { if case .inBrowser = coordinator.phase { return true } else { return false } })
    coordinator.signIn(Account(provider: .claude, folder: "/tmp/other", alias: "other"))   // joins, does not start another
    #expect(coordinator.activeAccount?.id == claude.id)
    let child = try #require(coordinator.runningProcess)   // the login CLI is still waiting on the gate file
    #expect(child.isRunning)
    coordinator.cancel()
    #expect(await waitUntil { coordinator.phase == .cancelled })
    #expect(await waitUntil { !child.isRunning })          // Cancel terminates the CLI, it is not left behind
    #expect(identity.calls.withValue { $0 } == 0)
    #expect(coordinator.activeAccount == nil)
    #expect(!FileManager.default.fileExists(atPath: gate.path))
}

@MainActor
@Test func cancelBeforeTheFlowsFirstTickNeverStartsTheCLI() async throws {
    // A login CLI that did start hands its URL to $BROWSER, and the helper fixture writes this file: the child's
    // own side effect, not one of Juice's own properties. The gate nobody creates keeps such a child alive.
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("juice-browser-\(UUID().uuidString)")
    let gate = FileManager.default.temporaryDirectory.appendingPathComponent("juice-gate-\(UUID().uuidString)")
    defer {
        // Releases the gate, so a child that should not exist cannot outlive the run either.
        FileManager.default.createFile(atPath: gate.path, contents: nil)
        try? FileManager.default.removeItem(at: marker)
    }
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: nil)))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity,
                                          extra: ["FAKE_LOGIN_WAIT": gate.path, "FAKE_BROWSER_TARGET": marker.path])
    coordinator.configuration.browserHelper = try fixtureURL("fake-browser", "sh")
    coordinator.signIn(claude)
    coordinator.cancel()                                  // lands before the flow task has had its first tick
    #expect(coordinator.phase == .cancelled)
    #expect(await waitUntil(.milliseconds(300)) { FileManager.default.fileExists(atPath: marker.path) } == false)
    #expect(coordinator.phase == .cancelled)              // and the flow never reports itself into the browser
    #expect(identity.calls.withValue { $0 } == 0)
    #expect(coordinator.activeAccount == nil)
}

@MainActor
@Test func theBrowserHelperIsHandedTheLoginURL() async throws {
    // The helper is a fixture that writes the URL to a file; no browser is opened.
    let target = FileManager.default.temporaryDirectory.appendingPathComponent("juice-browser-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: target) }
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: nil)))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity,
                                          extra: ["FAKE_BROWSER_TARGET": target.path])
    coordinator.configuration.browserHelper = try fixtureURL("fake-browser", "sh")
    coordinator.signIn(claude)
    #expect(await waitUntil { coordinator.phase == .done(email: "a@example.com") })
    #expect(await waitUntil { FileManager.default.fileExists(atPath: target.path) })
    #expect(try String(contentsOf: target, encoding: .utf8) == "https://example.com/login/abc123")
}

@MainActor
@Test func cancelDuringTheIdentityCheckWins() async throws {
    let identity = BlockingIdentity(result: .success(SignInIdentity(email: "b@example.com", plan: "pro")))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity)
    var finished: [SignInPhase] = []
    coordinator.onFinished = { _, phase in finished.append(phase) }
    coordinator.signIn(claude)
    #expect(await waitUntil { identity.calls.withValue { $0 } == 1 })   // the check is in flight
    #expect(coordinator.phase == .checking)
    let child = try #require(coordinator.runningProcess)                // the login CLI already exited on its own
    coordinator.cancel()
    identity.release()                                                  // the answer lands after Cancel
    #expect(coordinator.phase == .cancelled)
    // The late answer is discarded: no done, no `Signed in as …`, and one onFinished for the flow.
    #expect(await waitUntil(.milliseconds(300)) { coordinator.phase != .cancelled } == false)
    #expect(finished == [.cancelled])
    #expect(coordinator.activeAccount == nil)
    #expect(!child.isRunning)
}

@MainActor
@Test func failedLoginReportsTheOutput() async throws {
    let identity = FakeIdentity(result: .success(SignInIdentity(email: nil, plan: nil)))
    let coordinator = try makeCoordinator(login: "fake-login-fail", identity: identity)
    coordinator.signIn(claude)
    #expect(await waitUntil { if case .failed = coordinator.phase { return true } else { return false } })
    if case .failed(let text) = coordinator.phase { #expect(text.contains("network error")) }
}

@MainActor
@Test func identityFailureAfterLoginIsAFailure() async throws {
    let identity = FakeIdentity(result: .failure(.signInRequired))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity)
    coordinator.signIn(claude)
    #expect(await waitUntil { coordinator.phase == .failed("The CLI finished but reports no login.") })
}

// MARK: - Codes

private func temporaryFile(_ stem: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(stem)-\(UUID().uuidString)")
}

@MainActor
private func waitsForACode(_ coordinator: SignInCoordinator) -> Bool {
    if case .inBrowser(let url, true) = coordinator.phase { return url != nil } else { return false }
}

/// Everything the coordinator shows or keeps as text, and every phase it finished with: a code must be in none of it.
@MainActor
private func everythingSaid(_ coordinator: SignInCoordinator, _ finished: [SignInPhase]) -> String {
    var said = [String(describing: coordinator.phase), coordinator.lastURL?.absoluteString ?? "", coordinator.deviceCode ?? ""]
    said += finished.map { String(describing: $0) }
    said += Mirror(reflecting: coordinator).children.map { String(describing: $0.value) }
    return said.joined(separator: "\n")
}

@MainActor
@Test func aPastedCodeReachesTheCLIAndSignsIn() async throws {
    let received = temporaryFile("juice-code")
    defer { try? FileManager.default.removeItem(at: received) }
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: "max")))
    let coordinator = try makeCoordinator(login: "fake-login-code", identity: identity,
                                          extra: ["FAKE_LOGIN_CODE": "k3y-Good#st4te", "FAKE_LOGIN_RECEIVED": received.path])
    coordinator.signIn(claude)
    #expect(await waitUntil { waitsForACode(coordinator) })
    #expect(coordinator.lastURL?.absoluteString == "https://example.com/oauth/authorize?code=true&state=abc123")
    coordinator.submitCode(" \n\t ")                            // blanks are no code: nothing is written
    #expect(waitsForACode(coordinator))
    coordinator.submitCode("  k3y-Good#st4te \n")
    #expect(coordinator.phase == .checking)
    coordinator.submitCode("k3y-Good#st4te")                   // once: nothing more is written while it checks
    #expect(await waitUntil { coordinator.phase == .done(email: "a@example.com") })
    #expect(try String(contentsOf: received, encoding: .utf8) == "k3y-Good#st4te\n")   // trimmed, one line
}

@MainActor
@Test func aWrongCodeFailsWithoutRepeatingIt() async throws {
    let received = temporaryFile("juice-code")
    defer { try? FileManager.default.removeItem(at: received) }
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: "max")))
    let coordinator = try makeCoordinator(login: "fake-login-code", identity: identity,
                                          extra: ["FAKE_LOGIN_CODE": "k3y-Good#st4te", "FAKE_LOGIN_RECEIVED": received.path])
    var finished: [SignInPhase] = []
    coordinator.onFinished = { _, phase in finished.append(phase) }
    coordinator.signIn(claude)
    #expect(await waitUntil { waitsForACode(coordinator) })
    coordinator.submitCode("Wr0ng-7Q2X#st4te")
    #expect(await waitUntil { coordinator.phase == .failed(SignInCoordinator.codeNotAccepted) })
    #expect(try String(contentsOf: received, encoding: .utf8) == "Wr0ng-7Q2X#st4te\n")   // it did reach the CLI
    #expect(identity.calls.withValue { $0 } == 0)
    // The CLI repeated the code on stdout and stderr; none of it is in the error, the phase or anything kept.
    let said = everythingSaid(coordinator, finished)
    #expect(!said.contains("Wr0ng") && !said.contains("7Q2X"))
    #expect(finished == [.failed(SignInCoordinator.codeNotAccepted)])
}

@MainActor
@Test func aRefusedCodeAsksAgainAndTheNextOneSignsIn() async throws {
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: "max")))
    let coordinator = try makeCoordinator(login: "fake-login-code", identity: identity,
                                          extra: ["FAKE_LOGIN_CODE": "k3y-Good#st4te"])
    var finished: [SignInPhase] = []
    coordinator.onFinished = { _, phase in finished.append(phase) }
    coordinator.signIn(claude)
    #expect(await waitUntil { waitsForACode(coordinator) })
    coordinator.submitCode("Half-C0de-9ZK")                  // no `#`: the CLI says it is invalid and keeps waiting
    #expect(await waitUntil { coordinator.codeRefused })
    #expect(waitsForACode(coordinator))
    let child = try #require(coordinator.runningProcess)
    #expect(child.isRunning)
    #expect(!everythingSaid(coordinator, finished).contains("C0de"))
    coordinator.submitCode("k3y-Good#st4te")
    #expect(coordinator.phase == .checking && !coordinator.codeRefused)
    #expect(await waitUntil { coordinator.phase == .done(email: "a@example.com") })
    #expect(!everythingSaid(coordinator, finished).contains("C0de"))
}

/// A code the CLI can no longer take (it stopped reading: the browser's redirect finished the login) is not sent, so
/// the flow keeps waiting on the browser and keeps reading what the CLI says next.
@MainActor
@Test func aCodeTheCLINoLongerReadsIsNotSent() async throws {
    let gate = temporaryFile("juice-gate")
    defer { try? FileManager.default.removeItem(at: gate) }
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: "max")))
    let coordinator = try makeCoordinator(login: "fake-login-code", identity: identity, extra: ["FAKE_LOGIN_DEAF": gate.path])
    coordinator.signIn(claude)
    #expect(await waitUntil { waitsForACode(coordinator) })
    coordinator.submitCode("k3y-Good#st4te")
    #expect(waitsForACode(coordinator) && !coordinator.codeRefused)
    FileManager.default.createFile(atPath: gate.path, contents: nil)
    #expect(await waitUntil { coordinator.lastURL?.absoluteString == "https://example.com/after" })
    #expect(await waitUntil { coordinator.phase == .done(email: "a@example.com") })
}

@MainActor
@Test func cancelWhileTheCLIWaitsForACodeStopsIt() async throws {
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: nil)))
    let coordinator = try makeCoordinator(login: "fake-login-code", identity: identity, extra: ["FAKE_LOGIN_CODE": "k3y-Good#st4te"])
    coordinator.signIn(claude)
    #expect(await waitUntil { waitsForACode(coordinator) })
    let child = try #require(coordinator.runningProcess)
    coordinator.cancel()
    #expect(coordinator.phase == .cancelled)
    #expect(await waitUntil { !child.isRunning })
    coordinator.submitCode("k3y-Good#st4te")                  // too late: nothing is written, nothing changes
    #expect(coordinator.phase == .cancelled)
    #expect(identity.calls.withValue { $0 } == 0)
}

@MainActor
@Test func aCodeIsOnlySentWhenTheCLIAsksForOne() async throws {
    let gate = temporaryFile("juice-gate")
    defer { try? FileManager.default.removeItem(at: gate) }
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "a@example.com", plan: nil)))
    let coordinator = try makeCoordinator(login: "fake-login", identity: identity, extra: ["FAKE_LOGIN_WAIT": gate.path])
    coordinator.signIn(claude)
    #expect(await waitUntil { coordinator.phase == .inBrowser(url: URL(string: "https://example.com/login/abc123")) })
    coordinator.submitCode("k3y-Good#st4te")
    #expect(coordinator.phase == .inBrowser(url: URL(string: "https://example.com/login/abc123"), wantsCode: false))
    FileManager.default.createFile(atPath: gate.path, contents: nil)
    #expect(await waitUntil { coordinator.phase == .done(email: "a@example.com") })
}

@MainActor
@Test func aDeviceCodeIsShownWhileTheFlowWaits() async throws {
    let gate = temporaryFile("juice-gate")
    defer { try? FileManager.default.removeItem(at: gate) }
    let identity = FakeIdentity(result: .success(SignInIdentity(email: "c@example.com", plan: "pro")))
    let coordinator = try makeCoordinator(login: "fake-login-device", identity: identity, extra: ["FAKE_LOGIN_WAIT": gate.path])
    coordinator.signIn(Account(provider: .codex, folder: "/tmp/juice-signin-codex", alias: "c"))
    #expect(await waitUntil { coordinator.deviceCode == "ABCD-EFGH" })
    #expect(coordinator.phase == .inBrowser(url: URL(string: "https://example.com/codex/device"), wantsCode: false))
    FileManager.default.createFile(atPath: gate.path, contents: nil)
    #expect(await waitUntil { coordinator.phase == .done(email: "c@example.com") })
    #expect(coordinator.deviceCode == nil)                    // not kept past the flow
}
