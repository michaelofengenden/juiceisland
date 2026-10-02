import Foundation
import Observation

public enum SignInPhase: Sendable, Equatable {
    case idle
    case opening
    /// Waiting on the browser. `wantsCode`: the CLI asks for the code its sign-in page shows at the end (Claude's
    /// `Paste code here if prompted`), which `submitCode` sends.
    case inBrowser(url: URL?, wantsCode: Bool = false)
    /// The login CLI has the code, or has exited; then the identity check.
    case checking
    /// The email the identity check reported; nil when it named none (a remembered email is never put in its place).
    case done(email: String?)
    case wrongIdentity(found: String, expected: String)
    case failed(String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .done, .failed, .cancelled: true
        default: false
        }
    }
}

/// Spec §7. One flow at a time; the vendor CLI does the login in the account's own folder; Juice only watches it.
@MainActor
@Observable
public final class SignInCoordinator {
    public struct Configuration: Sendable {
        public var claudeExecutable: URL?
        public var codexExecutable: URL?
        /// A script that opens `$1` in the chosen browser profile; exported as `BROWSER`.
        public var browserHelper: URL?
        /// Exported as `JUICE_BROWSER_PROFILE` for the helper.
        public var browserProfile: String?
        public var extraEnvironment: [String: String] = [:]
        public var timeout: Duration = .seconds(600)

        public init(claudeExecutable: URL?, codexExecutable: URL?, browserHelper: URL? = nil, browserProfile: String? = nil) {
            self.claudeExecutable = claudeExecutable
            self.codexExecutable = codexExecutable
            self.browserHelper = browserHelper
            self.browserProfile = browserProfile
        }
    }

    public var configuration: Configuration
    /// Replaceable: a CLI found after the coordinator was built has to reach the check too, or a sign-in would
    /// keep checking through the readers Juice happened to have at launch.
    public var identity: any IdentityChecker
    public private(set) var phase: SignInPhase = .idle
    public private(set) var activeAccount: Account?
    public private(set) var lastURL: URL?
    /// The one-time code a CLI printed for the person to type on its sign-in page (a device-code login). Shown with
    /// Copy while the flow waits on the browser; never logged, and gone when the flow ends.
    public private(set) var deviceCode: String?
    /// The last code `submitCode` sent was refused and the CLI still waits for one.
    public private(set) var codeRefused = false
    /// Called once per flow when it reaches done, failed or cancelled.
    public var onFinished: ((Account, SignInPhase) -> Void)?

    private var process: CLIProcess?
    private var task: Task<Void, Never>?
    /// Set when a code has gone to this flow's CLI. From then on none of the CLI's output is kept or shown (no
    /// transcript, no URL, no error text), so an echo of the code cannot be either. Shared with the reading task.
    private var codeSent: LockedBox<Bool>?

    /// The login child process while a flow is running, so tests can prove Cancel really stops the CLI.
    var runningProcess: CLIProcess? { process }

    public init(configuration: Configuration, identity: any IdentityChecker) {
        self.configuration = configuration
        self.identity = identity
    }

    /// Starts the flow for `account`, or does nothing if one is already running (the caller shows the running one).
    public func signIn(_ account: Account) {
        guard activeAccount == nil else { return }
        activeAccount = account
        lastURL = nil
        deviceCode = nil
        codeRefused = false
        checkedIdentity = nil
        phase = .opening
        JuiceLog.signIn.notice("\(JuiceLog.folder(account.folder), privacy: .public): sign-in started")
        task = Task { [weak self] in await self?.run(account) }
    }

    public func cancel() {
        guard activeAccount != nil else { return }
        task?.cancel()
        process?.terminate()
        finish(.cancelled)
    }

    public func openBrowser() {
        guard let lastURL else { return }
        _ = try? runHelper(lastURL)
    }

    /// Sends the code the sign-in page showed to the CLI that asked for it, as one line on its stdin, and moves on to
    /// checking. Surrounding white space and line breaks are dropped. The code goes to the CLI and nowhere else: it is
    /// not kept, logged or shown, and it does not reach a phase, an error or a transcript. Does nothing unless the
    /// CLI is waiting for a code.
    public func submitCode(_ code: String) {
        let line = code.filter { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, case .inBrowser(_, true) = phase, let process, let codeSent else { return }
        // Marked before the write: the CLI can answer before `write` returns, and that answer (a refusal, an echo of
        // the code) must already be read as one that came after a code.
        codeSent.withValue { $0 = true }
        // A CLI that has just exited (the browser's own redirect finished the login) takes nothing; the flow moves on
        // by itself.
        guard (try? process.write(line: line)) != nil else {
            codeSent.withValue { $0 = false }
            return
        }
        codeRefused = false
        phase = .checking
    }

    /// After `.wrongIdentity`: keep the folder with the identity that is actually signed in. Returns that email.
    public func useThisAccount() -> String? {
        guard case .wrongIdentity(let found, _) = phase else { return nil }
        finish(.done(email: found))
        return found
    }

    /// After `.wrongIdentity` or `.failed`: run the flow again for the same account.
    public func signInAgain() {
        guard let account = activeAccount ?? lastAccount else { return }
        activeAccount = nil
        signIn(account)
    }

    /// The account of the last finished flow, so Settings can show its failure on the right row.
    public private(set) var lastAccount: Account?
    /// What the current or last flow's identity check found: the email `.done` carries, with the organization the owner
    /// picked on the sign-in page (P580). Nil until a check answers; a new flow clears it.
    public private(set) var checkedIdentity: SignInIdentity?

    private func finish(_ final: SignInPhase) {
        phase = final
        process = nil
        task = nil
        codeSent = nil
        deviceCode = nil
        codeRefused = false
        if let account = activeAccount {
            JuiceLog.signIn.notice("\(JuiceLog.folder(account.folder), privacy: .public): sign-in \(Self.logWord(final), privacy: .public)")
            lastAccount = account
            activeAccount = nil
            onFinished?(account, final)
        }
    }

    /// How a flow ended, for the log: never who signed in, never the CLI's words.
    static func logWord(_ phase: SignInPhase) -> String {
        switch phase {
        case .done(let email): email == nil ? "done, no identity named" : "done"
        case .wrongIdentity: "found another identity"
        case .failed: "failed"
        case .cancelled: "cancelled"
        case .idle, .opening, .inBrowser, .checking: "ended"
        }
    }

    // MARK: - The flow

    private func run(_ account: Account) async {
        // Cancel can land before this task's first tick: the flow is over, so start no CLI and leave the phase
        // Cancel set. Nothing below awaits before `process.start()`, so this also guards the start itself.
        if Task.isCancelled { return }
        guard let executable = account.provider == .claude ? configuration.claudeExecutable : configuration.codexExecutable,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            finish(.failed("\(account.provider.rawValue) CLI not found"))
            return
        }
        var arguments = account.provider == .claude ? ["auth", "login"] : ["login"]
        if account.provider == .claude, let email = account.knownEmail { arguments += ["--email", email] }
        var extra = configuration.extraEnvironment
        if let helper = configuration.browserHelper { extra["BROWSER"] = helper.path }
        if let profile = configuration.browserProfile { extra["JUICE_BROWSER_PROFILE"] = profile }
        let env = CLIEnvironment.make(provider: account.provider, folder: account.folder, extra: extra)

        let process = CLIProcess(executable: executable, arguments: arguments, environment: env, interactive: true)
        do { try process.start() } catch {
            finish(.failed("could not start \(executable.lastPathComponent): \(error.localizedDescription)"))
            return
        }
        // And a child that did start must never outlive the flow that was cancelled while it started.
        if Task.isCancelled {
            process.terminate()
            return
        }
        self.process = process
        let codeSent = LockedBox(false)
        self.codeSent = codeSent
        phase = .inBrowser(url: nil)

        let lines = process.lines, errorLines = process.errorLines
        let status: Int32
        let transcript: String
        do {
            (status, transcript) = try await withTimeout(configuration.timeout) {
                // A CLI that refuses a code and keeps waiting says so on stderr (Claude: `Invalid code. …`).
                let refusals = Task {
                    for await line in errorLines where codeSent.withValue({ $0 }) && SignInOutput.refusesCode(line) {
                        await MainActor.run { self.codeWasRefused() }
                    }
                }
                defer { refusals.cancel() }
                var output = SignInOutput()
                var seen = ""
                for await line in lines {
                    let events = output.read(line)
                    guard !codeSent.withValue({ $0 }) else {
                        // Asking again means the code was not taken; nothing else after a code is kept.
                        if events.contains(.wantsCode) { await MainActor.run { self.codeWasRefused() } }
                        continue
                    }
                    seen = String((seen + line + "\n").suffix(4_000))
                    for event in events { await MainActor.run { self.note(event) } }
                }
                return (await process.waitForExit(), seen)
            }
        } catch is TimeoutError {
            process.kill()
            if !Task.isCancelled { finish(.failed("The sign-in did not finish within \(Formatting.duration(TimeInterval(configuration.timeout.components.seconds))).")) }
            return
        } catch {
            if !Task.isCancelled { finish(.failed(error.localizedDescription)) }
            return
        }
        if Task.isCancelled { return }
        guard status == 0 else {
            // After a code, the CLI's own words are not shown: they could repeat it.
            if codeSent.withValue({ $0 }) {
                finish(.failed(Self.codeNotAccepted))
                return
            }
            // This text is shown in Settings and kept on the row, so the CLI's output is masked first (spec §8.3).
            let stderr = ReadError.redact(process.stderrOutput).trimmingCharacters(in: .whitespacesAndNewlines)
            finish(.failed(stderr.isEmpty ? "exit \(status): \(ReadError.redact(transcript).suffix(300))" : String(stderr.suffix(300))))
            return
        }

        phase = .checking
        let checked = await identity.identity(for: account)
        // Spec §6: Cancel ends the flow. A check that only answers after Cancel is discarded, so the phase
        // stays the one Cancel set and `onFinished` fires at most once for a flow.
        if Task.isCancelled { return }
        if case .success(let found) = checked { checkedIdentity = found }
        switch checked {
        case .failure(.signInRequired):
            finish(.failed("The CLI finished but reports no login."))
        case .failure(let error):
            finish(.failed("Could not check the account: \(error.shortDescription)"))
        case .success(let found):
            let expected = account.knownEmail?.lowercased()
            if let expected, let email = found.email?.lowercased(), email != expected {
                phase = .wrongIdentity(found: found.email ?? "", expected: account.knownEmail ?? "")
            } else {
                finish(.done(email: found.email))
            }
        }
    }

    private func note(_ event: SignInOutput.Event) {
        guard case .inBrowser(_, let wantsCode) = phase else {
            if case .url(let url) = event { lastURL = url }
            return
        }
        switch event {
        case .url(let url):
            lastURL = url
            phase = .inBrowser(url: url, wantsCode: wantsCode)
        case .wantsCode:
            phase = .inBrowser(url: lastURL, wantsCode: true)
        case .deviceCode(let code):
            deviceCode = code
        }
    }

    /// The CLI refused the code and still waits: back to the browser step, to paste it again.
    private func codeWasRefused() {
        guard phase == .checking, process?.isRunning == true else { return }
        codeRefused = true
        phase = .inBrowser(url: lastURL, wantsCode: true)
    }

    static let codeNotAccepted = "The code was not accepted."

    private func runHelper(_ url: URL) throws {
        let process = Process()
        if let helper = configuration.browserHelper {
            process.executableURL = helper
            process.arguments = [url.absoluteString]
            var env = ProcessInfo.processInfo.environment
            if let profile = configuration.browserProfile { env["JUICE_BROWSER_PROFILE"] = profile }
            process.environment = env
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url.absoluteString]
        }
        try process.run()
    }
}
