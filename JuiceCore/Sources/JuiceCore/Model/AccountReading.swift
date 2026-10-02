import Foundation

/// A successful read of one account's limits.
public struct AccountReading: Codable, Sendable, Equatable {
    public var accountID: String
    public var readAt: Date
    /// "max", "pro", "team", "plus" … as the vendor reports it, lowercased.
    public var plan: String?
    public var email: String?
    /// The login's organization, when its CLI named one (Claude's `claude auth status`): its key
    /// (`LoginOrganization.key`, never the id) and the name it may be shown by (`LoginOrganization.shownName`). A reading
    /// gets them from its login as it gets the email; nil in Codex readings and in readings saved before this existed.
    public var org: String?
    public var orgName: String?
    public var windows: [UsageWindow]
    /// Codex reports `ordinaryUsageAllowed: false` while rate limited; Claude readings are always true.
    public var ordinaryUsageAllowed: Bool
    /// Codex extra-usage credit balance, when the account has one.
    public var creditsBalance: Double?
    /// Codex rate-limit reset credits the account holds, and when the first of them expires, when the response says;
    /// nil in Claude readings and in readings saved before this existed.
    public var resetCredits: Int?
    public var resetCreditExpires: Date?

    public init(accountID: String, readAt: Date, plan: String? = nil, email: String? = nil, org: String? = nil, orgName: String? = nil,
                windows: [UsageWindow], ordinaryUsageAllowed: Bool = true, creditsBalance: Double? = nil,
                resetCredits: Int? = nil, resetCreditExpires: Date? = nil) {
        self.accountID = accountID
        self.readAt = readAt
        self.plan = plan
        self.email = email
        self.org = org
        self.orgName = orgName
        self.windows = windows
        self.ordinaryUsageAllowed = ordinaryUsageAllowed
        self.creditsBalance = creditsBalance
        self.resetCredits = resetCredits
        self.resetCreditExpires = resetCreditExpires
    }
}

extension AccountReading {
    /// The login the reading names: its email and organization, and its plan's kind; nil when it names no email.
    public var login: LoginIdentity? {
        email.map { LoginIdentity(email: $0, org: org, orgName: orgName, kind: LoginIdentity.PlanKind(plan: plan)) }
    }
}
