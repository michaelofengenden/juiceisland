import Foundation
import Testing
@testable import JuiceCore

func fixtureURL(_ name: String, _ ext: String) throws -> URL {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures"))
    _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private let account = Account(provider: .claude, folder: "/tmp/juice-test-claude", alias: "test")

@Test func readsAReadingFromTheFakeCLI() async throws {
    let reader = ClaudeCLIReader(executable: try fixtureURL("fake-claude", "sh"), timeout: .seconds(10),
                                 extraEnvironment: ["FAKE_FIXTURE": try fixtureURL("claude-get-usage", "json").path])
    let result = await reader.read(account, now: Date())
    let reading = try result.get()
    #expect(reading.accountID == account.id)
    #expect(reading.plan == "max")
    #expect(reading.windows.map(\.usedPercent) == [5, 13])
}

@Test func loggedOutBecomesSignInRequired() async throws {
    let reader = ClaudeCLIReader(executable: try fixtureURL("fake-claude-loggedout", "sh"), timeout: .seconds(10))
    let result = await reader.read(account, now: Date())
    #expect(result == .failure(.signInRequired))
}

@Test func slowCLITimesOutAndIsKilled() async throws {
    let reader = ClaudeCLIReader(executable: try fixtureURL("fake-slow", "sh"), timeout: .milliseconds(300))
    let started = Date()
    let result = await reader.read(account, now: Date())
    #expect(result == .failure(.timeout))
    #expect(Date().timeIntervalSince(started) < 5)
}

@Test func missingExecutableIsCLINotFound() async {
    let reader = ClaudeCLIReader(executable: URL(fileURLWithPath: "/nonexistent/claude"), timeout: .seconds(1))
    let result = await reader.read(account, now: Date())
    #expect(result == .failure(.cliNotFound))
}

@Test func errorControlResponseIsClassified() async throws {
    let reader = ClaudeCLIReader(executable: try fixtureURL("fake-claude-error", "sh"), timeout: .seconds(10))
    let result = await reader.read(account, now: Date())
    #expect(result == .failure(.signInRequired))
}

@Test func classifyRecognisesTheUsualFailures() {
    #expect(ReadError.classify(exitStatus: 1, stdout: "", stderr: "Not logged in") == .signInRequired)
    #expect(ReadError.classify(exitStatus: 1, stdout: "", stderr: "Invalid API key · Please run /login") == .signInRequired)
    #expect(ReadError.classify(exitStatus: 1, stdout: "", stderr: "429 rate_limit_error retry-after: 120") == .rateLimited(retryAfter: 120))
    #expect(ReadError.classify(exitStatus: 1, stdout: "", stderr: "error: unknown option '--frobnicate'") == .cliUpdateNeeded("error: unknown option '--frobnicate'"))
    #expect(ReadError.classify(exitStatus: 1, stdout: "", stderr: "getaddrinfo ENOTFOUND api.anthropic.com") == .offline)
    #expect(ReadError.classify(exitStatus: 2, stdout: "", stderr: "something else") == .failed("something else"))
}

@Test func classifyDoesNotMistakeDigitsForRateLimits() {
    #expect(ReadError.classify(exitStatus: 2, stdout: #"{"duration_ms":1429,"session_id":"7a4290b1-2222-3333-4444-555555555555"}"#, stderr: "")
            == .failed("exit 2"))
    #expect(ReadError.classify(exitStatus: 1, stdout: "", stderr: "HTTP 429 Too Many Requests") == .rateLimited(retryAfter: nil))
    #expect(ReadError.classify(exitStatus: 1, stdout: "", stderr: "status: 429\nretry-after: 120") == .rateLimited(retryAfter: 120))
}

/// P108: a read starts no MCP server. `--strict-mcp-config` with no `--mcp-config` loads none, and nothing else about
/// the read changes: the same control request, the same folder variable, no settings or login flags.
@Test func aReadStartsNoMCPServer() async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("juice-args-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    let reader = ClaudeCLIReader(executable: try fixtureURL("fake-claude", "sh"), timeout: .seconds(10),
                                 extraEnvironment: ["FAKE_FIXTURE": try fixtureURL("claude-get-usage", "json").path, "FAKE_ARGS_LOG": log.path])
    #expect(try await reader.read(account, now: Date()).get().windows.map(\.usedPercent) == [5, 13])
    let launches = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(launches == [(ClaudeCLIReader.defaultArguments).joined(separator: " ")])
    #expect(launches[0].hasSuffix("--disable-slash-commands --strict-mcp-config"))
    #expect(!launches[0].contains("--mcp-config ") && !launches[0].contains("--settings") && !launches[0].contains("--bare"))
}

/// A CLI that refuses `--strict-mcp-config` (too old to know it, or forbidden by a managed MCP config) stops before it
/// reads anything: the same read is made again at once without the flag, and the reader leaves it out from then on.
@Test(arguments: ["unknown", "enterprise"])
func aCLIThatRefusesTheFlagIsReadWithoutIt(refusal: String) async throws {
    let log = FileManager.default.temporaryDirectory.appendingPathComponent("juice-args-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: log) }
    let reader = ClaudeCLIReader(executable: try fixtureURL("fake-claude-strict", "sh"), timeout: .seconds(10),
                                 extraEnvironment: ["FAKE_FIXTURE": try fixtureURL("claude-get-usage", "json").path,
                                                    "FAKE_ARGS_LOG": log.path, "FAKE_REFUSAL": refusal])
    #expect(try await reader.read(account, now: Date()).get().windows.map(\.usedPercent) == [5, 13])
    #expect(try await reader.read(account, now: Date()).get().windows.map(\.usedPercent) == [5, 13])
    let launches = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
    #expect(launches.map { $0.contains("--strict-mcp-config") } == [true, false, false])
}

/// Only a refusal of the flag drops it: another failure that mentions it is an ordinary failure, read again only after
/// its backoff.
@Test func onlyARefusalOfTheFlagDropsIt() {
    #expect(ClaudeCLIReader.refusedStrictMCP("error: unknown option '--strict-mcp-config'"))
    #expect(ClaudeCLIReader.refusedStrictMCP("You cannot use --strict-mcp-config when an enterprise MCP config is present"))
    #expect(!ClaudeCLIReader.refusedStrictMCP("error: unknown option '--frobnicate'"))
    #expect(!ClaudeCLIReader.refusedStrictMCP("MCP server 'x' skipped: string specs resolve from disk config, which --strict-mcp-config ignores"))
    #expect(!ClaudeCLIReader.refusedStrictMCP(""))
}
