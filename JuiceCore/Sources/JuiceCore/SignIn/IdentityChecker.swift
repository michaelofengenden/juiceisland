import Foundation

/// Who a CLI says is signed in to a folder. For Claude also the organization the login is in (`claude auth status`
/// names it: one email can sign in to a personal Max plan and to a Team or Enterprise organization, the sign-in page
/// picks one) and whether it is a login billed by usage (`usageBilled`).
public struct SignInIdentity: Sendable, Equatable {
    public var email: String?
    public var plan: String?
    /// The organization's key (`LoginOrganization.key`, a hash of its id, never the id); nil when the CLI names none
    /// (Codex, an older Claude CLI, a login that is not claude.ai's).
    public var org: String?
    /// The organization's name as it may be shown (`LoginOrganization.shownName`): nil for the personal one Claude names
    /// after the email, and when the CLI names none.
    public var orgName: String?
    /// Signed in with an Anthropic Console key that `/login` made (`apiKeySource` "/login managed key", no
    /// subscription): its usage is billed by the token, and `get_usage` reports no plan limits for it.
    public var usageBilled: Bool

    public init(email: String?, plan: String?, org: String? = nil, orgName: String? = nil, usageBilled: Bool = false) {
        self.email = email
        self.plan = plan
        self.org = org
        self.orgName = orgName
        self.usageBilled = usageBilled
    }

    /// The login this names; nil without an email, which names none. A Console login's organization bills by usage.
    public var login: LoginIdentity? {
        email.map { LoginIdentity(email: $0, org: org, orgName: orgName, kind: usageBilled ? .organization : LoginIdentity.PlanKind(plan: plan)) }
    }
}

/// A login as a CLI reported it: its email and, when the CLI names one, its organization. Two folders of one email in two
/// organizations are two logins (`LoginsStore.id`), read and shown apart.
public struct LoginIdentity: Sendable, Equatable, Hashable {
    public var email: String
    /// `LoginOrganization.key` of the organization's id; nil when the CLI named none.
    public var org: String?
    /// `LoginOrganization.shownName`; nil for the personal organization and when none was named.
    public var orgName: String?
    /// The kind of plan the CLI named with it (P586), nil when it named none. Not part of who the login is (a plan
    /// changes with an upgrade, so two identities that differ only here are equal): it tells which organization an
    /// email's login from before organizations were named was in (`LoginsStore.place`).
    public var kind: PlanKind?

    /// A personal plan (Pro, Max) or an organization's (Team, Enterprise; a Console login's).
    public enum PlanKind: String, Codable, Sendable {
        case personal, organization

        /// The kind of a plan word (`subscription_type`, `subscriptionType`); nil for none.
        public init?(plan: String?) {
            guard let plan = plan?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !plan.isEmpty else { return nil }
            self = ClaudeUsageResponse.organizationPlans.contains(plan) ? .organization : .personal
        }
    }

    public init(email: String, org: String? = nil, orgName: String? = nil, kind: PlanKind? = nil) {
        self.email = email
        self.org = org
        self.orgName = orgName
        self.kind = kind
    }

    public static func == (a: LoginIdentity, b: LoginIdentity) -> Bool {
        a.email == b.email && a.org == b.org && a.orgName == b.orgName
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(email)
        hasher.combine(org)
        hasher.combine(orgName)
    }
}

/// A Claude organization as Juice Island keeps it: its id only as a hash, its name only when it may be shown.
public enum LoginOrganization {
    /// The organization's key: the same 16 hex digits of the FNV-1a hash an email's key is (`LoginsStore.key`), of the
    /// trimmed, lowercased id. The id itself is never stored, logged or shown.
    public static func key(for orgID: String) -> String? {
        let id = orgID.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : LoginsStore.key(for: id)
    }

    /// The name to show for an organization, or nil. Claude names a personal account's own organization after its email
    /// ("<email>'s Organization"): that one is the account's default and is shown as the account alone, and no name that
    /// holds an "@" is ever shown, since it would show an email.
    public static func shownName(_ name: String?, email: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.contains("@") else { return nil }
        if let email, isPersonal(name, email: email) { return nil }
        return name
    }

    /// "<email>'s Organization", any case, either apostrophe.
    static func isPersonal(_ name: String, email: String) -> Bool {
        let plain = name.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return plain == LoginsStore.normalized(email) + "'s organization"
    }
}

public protocol IdentityChecker: Sendable {
    func identity(for account: Account) async -> Result<SignInIdentity, ReadError>
}

/// Claude: `claude auth status --json`. Codex: the app-server's `account/read`, through the pool's reading.
public struct CLIIdentityChecker: IdentityChecker {
    public var claudeExecutable: URL?
    public var codexPool: CodexReaderPool?

    public init(claudeExecutable: URL?, codexPool: CodexReaderPool?) {
        self.claudeExecutable = claudeExecutable
        self.codexPool = codexPool
    }

    /// `claude auth status --json` (Claude Code 2.1): `loggedIn`, `authMethod`, `apiKeySource`, and for a claude.ai
    /// login `email`, `orgId`, `orgName` and `subscriptionType` ("pro", "max", "team", "enterprise", or null).
    private struct ClaudeAuthStatus: Decodable {
        var loggedIn: Bool?
        var authMethod: String?
        var apiKeySource: String?
        var email: String?
        var orgId: String?
        var orgName: String?
        var subscriptionType: String?
    }

    /// Where `/login` keeps an Anthropic Console account's key (`apiKeySource`).
    static let consoleKeySource = "/login managed key"

    public func identity(for account: Account) async -> Result<SignInIdentity, ReadError> {
        switch account.provider {
        case .codex:
            guard let codexPool else { return .failure(.cliNotFound) }
            // The pool's app-server for this home was started before the login and answers from the session it had
            // then, so it could still report the account the folder had before. Drop it and read through a fresh one.
            await codexPool.shutdown(folder: account.folder)
            return await codexPool.read(account, now: Date()).map { SignInIdentity(email: $0.email, plan: $0.plan) }
        case .claude:
            guard let claudeExecutable else { return .failure(.cliNotFound) }
            let process = CLIProcess(executable: claudeExecutable, arguments: ["auth", "status", "--json"],
                                     environment: CLIEnvironment.make(provider: .claude, folder: account.folder))
            do { try process.start() } catch { return .failure(.failed("could not run claude auth status")) }
            process.closeInput()
            var output = ""
            do {
                output = try await withTimeout(.seconds(20)) {
                    var text = ""
                    for await line in process.lines { text += line }
                    // `lines` also ends when this task is cancelled, with the child still running. Returning the
                    // partial text here would leave a `claude auth status` behind, so throw and let the `catch`
                    // below stop it — a cancelled check's answer is discarded by the caller anyway.
                    try Task.checkCancellation()
                    return text
                }
            } catch is CancellationError {
                process.kill()
                return .failure(.failed("the check was cancelled"))
            } catch { process.kill(); return .failure(.timeout) }
            return Self.claudeIdentity(fromAuthStatus: output)
        }
    }

    /// What `claude auth status --json` printed, as an identity. The organization's id is hashed here and goes no
    /// further; its name is kept only when it may be shown (`LoginOrganization.shownName`).
    public static func claudeIdentity(fromAuthStatus output: String) -> Result<SignInIdentity, ReadError> {
        guard let start = output.firstIndex(of: "{"), let data = String(output[start...]).data(using: .utf8),
              let status = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: data) else {
            // Fixed words: the CLI's output names the email and the organization's id, and a failure is stored (P580).
            return .failure(.cliUpdateNeeded("auth status: no answer \(AppFlavor.current.productName) can read"))
        }
        guard status.loggedIn == true else { return .failure(.signInRequired) }
        let plan = status.subscriptionType?.lowercased()
        return .success(SignInIdentity(email: status.email, plan: plan, org: status.orgId.flatMap(LoginOrganization.key(for:)),
                                       orgName: LoginOrganization.shownName(status.orgName, email: status.email),
                                       usageBilled: plan == nil && status.apiKeySource == consoleKeySource))
    }
}
