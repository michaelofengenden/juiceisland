import Foundation

/// Reads plan limits through the installed `claude` binary with one control request and no prompt (spec §8.1).
///
/// `--strict-mcp-config` with no `--mcp-config` starts no MCP server for the read: none of the profile's own, its
/// plugins' or its claude.ai connectors, and the MCP registry is not fetched (P108). The read is otherwise the same
/// (`get_usage` does not touch MCP), and the flag changes nothing about the login. A CLI that refuses the flag (one too
/// old to know it, or a Mac whose managed MCP config forbids it) exits before it reads anything; the read is made again
/// at once without it, and this reader leaves it out from then on. Hooks and settings are left as the profile has them:
/// the island's own hooks skip these reads (`CLIEnvironment.make`).
public struct ClaudeCLIReader: AccountReader {
    public static let strictMCPFlag = "--strict-mcp-config"
    public static let defaultArguments = [
        "--output-format", "stream-json", "--input-format", "stream-json", "--verbose", "-p",
        "--no-session-persistence", "--disable-slash-commands", strictMCPFlag,
    ]

    public var executable: URL
    public var timeout: Duration
    public var arguments: [String]
    public var extraEnvironment: [String: String]
    /// False once the CLI refused `--strict-mcp-config`.
    private let strictMCP = LockedBox(true)

    public init(executable: URL, timeout: Duration = .seconds(45), arguments: [String] = ClaudeCLIReader.defaultArguments,
                extraEnvironment: [String: String] = [:]) {
        self.executable = executable
        self.timeout = timeout
        self.arguments = arguments
        self.extraEnvironment = extraEnvironment
    }

    private struct ControlLine: Decodable {
        struct Response: Decodable {
            var subtype: String?
            var request_id: String?
            var response: ClaudeUsageResponse?
            var error: String?
        }
        var type: String
        var response: Response?
    }

    public func read(_ account: Account, now: Date) async -> Result<AccountReading, ReadError> {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return .failure(.cliNotFound) }
        let strict = arguments.contains(Self.strictMCPFlag) && strictMCP.withValue { $0 }
        let lenient = arguments.filter { $0 != Self.strictMCPFlag }
        let first = await attempt(account, now: now, arguments: strict ? arguments : lenient)
        guard strict, first.refusedStrictMCP else { return first.result }
        // The CLI stopped at its arguments, before any request: reading again without the flag keeps to the floor.
        strictMCP.withValue { $0 = false }
        return await attempt(account, now: now, arguments: lenient).result
    }

    /// Whether a CLI that exited without answering refused `--strict-mcp-config` (an unknown option, or a managed MCP
    /// config that forbids it), from its stderr.
    static func refusedStrictMCP(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return text.contains(strictMCPFlag) && (text.contains("unknown option") || text.contains("cannot use"))
    }

    private func attempt(_ account: Account, now: Date, arguments: [String]) async
        -> (result: Result<AccountReading, ReadError>, refusedStrictMCP: Bool) {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("juice-cli", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let env = CLIEnvironment.make(provider: .claude, folder: account.folder, extra: extraEnvironment)
        let process = CLIProcess(executable: executable, arguments: arguments, environment: env, currentDirectory: workDir)
        do { try process.start() } catch { return (.failure(.failed("could not launch claude: \(error.localizedDescription)")), false) }
        defer { process.terminate() }

        let requestID = UUID().uuidString
        do {
            try process.write(line: #"{"type":"control_request","request_id":"\#(requestID)","request":{"subtype":"get_usage"}}"#)
        } catch {
            let status = await process.waitForExit()
            let stderr = process.stderrOutput
            if stderr.isEmpty, status == 0 {
                return (.failure(.failed("could not write to claude: \(error.localizedDescription)")), false)
            }
            return (.failure(ReadError.classify(exitStatus: status, stdout: "", stderr: stderr)), Self.refusedStrictMCP(stderr))
        }

        let lines = process.lines
        let outcome: (result: Result<AccountReading, ReadError>, refusedStrictMCP: Bool)
        do {
            outcome = try await withTimeout(timeout) {
                var stdoutTail = ""
                for await line in lines {
                    stdoutTail = String((stdoutTail + line + "\n").suffix(4_000))
                    guard let data = line.data(using: .utf8),
                          let control = try? JSONDecoder().decode(ControlLine.self, from: data),
                          control.type == "control_response",
                          let response = control.response, response.request_id == requestID else { continue }
                    if response.subtype == "success", let usage = response.response {
                        do { return (.success(try usage.reading(accountID: account.id, readAt: now)), false) }
                        catch let error as ReadError { return (.failure(error), false) }
                    }
                    return (.failure(ReadError.classify(exitStatus: 0, stdout: "", stderr: response.error ?? "control request failed")), false)
                }
                // The stream ended: the CLI exited without answering.
                let status = await process.waitForExit()
                let stderr = process.stderrOutput
                return (.failure(ReadError.classify(exitStatus: status, stdout: stdoutTail, stderr: stderr)), Self.refusedStrictMCP(stderr))
            }
        } catch is TimeoutError {
            process.kill()
            return (.failure(.timeout), false)
        } catch {
            return (.failure(.failed(error.localizedDescription)), false)
        }
        return outcome
    }
}
