import Foundation

extension ReadError {
    /// Claude's `get_usage` says `rate_limits_available:false` while it names a `subscription_type`: the login is signed in
    /// and the CLI has no plan limits for it, as when its subscription ended (P360) or its organization's seat was taken
    /// away (P583: a Team or Enterprise plan named is no exception). A read with no limits and no explicit answer is
    /// `.incomplete("plan limits missing")` instead, and none without a plan is `.signInRequired`.
    public static let noPlanLimits = ReadError.incomplete("plan limits not available")

    /// Claude reports no plan limits for a login that is billed by usage, not by a plan with limits (P581): a Team or
    /// Enterprise organization's `get_usage` with `rate_limits_available:true` and every window null, and an Anthropic
    /// Console login (`SignInIdentity.usageBilled`, whose `get_usage` looks like a signed-out one's). Such a login is not
    /// "subscription ended?" and not signed out: after a streak (`NoPlanStreak`) it is **No limits**.
    public static let noLimitsReported = ReadError.incomplete("no plan limits reported")

    /// The CLI said the login has no plan limits, either way (`noPlanLimits`, `noLimitsReported`).
    public var saysNoPlanLimits: Bool { self == .noPlanLimits || self == .noLimitsReported }
}

/// A Claude login's reads that said it has no plan limits (`ReadError.noPlanLimits`, `.noLimitsReported`), in a row
/// (P360, P581). The login is **No plan** once `minimumReads` of them came, the first and the latest at least `span`
/// apart: its battery dims with the words "No plan", it is never Next, never stale or retrying and never raises
/// attention, and it is read again only every `interval`, until a good read clears it. One such answer never makes it
/// No plan: the vendor's side can say so for a while (an outage, a plan being changed). When the latest answer was a
/// login billed by usage (`usageBased`) the same streak makes it **No limits** instead (`AccountState.noLimits`): the
/// same dimmed battery, waits and rules, in words that do not ask whether a subscription ended.
///
/// `minimumReads` is 3: two answers could be one passing state read twice, and three are three separate looks (under the
/// read backoff, P106, a failing login is read at 0, 5, 15 and 35 minutes). The `span` of 30 minutes is what keeps a
/// passing state out: a Refresh can bring reads closer than the backoff (its floor is 120 s), never make three answers
/// span half an hour sooner. On the backoff alone the fourth read, 35 minutes after the first, is the first to meet
/// both, so a login is No plan about 35 minutes after its plan ended.
///
/// An outcome that says nothing about the plan (a timeout, offline, a CLI missing or failing, a 429, a read skipped)
/// neither counts nor ends the streak; a good read, a sign-in failure and another incomplete answer end it. Kept in the
/// login's record (`AccountRecord.noPlan`), so it survives a relaunch as the other waits do.
public struct NoPlanStreak: Codable, Sendable, Equatable, Hashable {
    /// The first answer of the streak, and the latest.
    public var since: Date
    public var last: Date
    /// How many answers came in a row.
    public var reads: Int
    /// The latest answer was `ReadError.noLimitsReported`: a login billed by usage. Nil (streaks saved before this
    /// existed) and false are a plan's limits gone (`noPlanLimits`).
    public var usageBased: Bool?

    public init(since: Date, last: Date, reads: Int, usageBased: Bool? = nil) {
        self.since = since
        self.last = last
        self.reads = reads
        self.usageBased = usageBased
    }

    public static let minimumReads = 3
    public static let span: TimeInterval = 1_800
    /// A No plan login's reads: every 6 hours, above every floor (Claude 300 s), Retry-After + 900 s included when longer.
    public static let interval: TimeInterval = 21_600
    /// A No plan battery's hover.
    public static let hover = "Claude reports no plan limits — subscription ended?"
    /// A No limits battery's hover (P581).
    public static let usageHover = "Claude reports no plan limits — billed by usage"

    /// The login is No plan.
    public var holds: Bool { reads >= Self.minimumReads && last.timeIntervalSince(since) >= Self.span }

    /// The streak after one more outcome at `at`.
    public static func after(_ result: Result<AccountReading, ReadError>, at: Date, previous: NoPlanStreak?) -> NoPlanStreak? {
        guard case .failure(let error) = result else { return nil }
        if error.saysNoPlanLimits {
            let usageBased: Bool? = error == .noLimitsReported ? true : nil
            guard let previous else { return NoPlanStreak(since: at, last: at, reads: 1, usageBased: usageBased) }
            return NoPlanStreak(since: min(previous.since, at), last: max(previous.last, at), reads: previous.reads + 1,
                                usageBased: usageBased)
        }
        return error.saysNothingAboutThePlan ? previous : nil
    }
}

extension ReadError {
    /// The read did not reach an answer about the account (`NoPlanStreak`): the CLI missing, failing or too old, a
    /// timeout, offline, a 429, or a read the scheduler skipped.
    var saysNothingAboutThePlan: Bool {
        switch self {
        case .cliNotFound, .cliUpdateNeeded, .rateLimited, .timeout, .offline, .failed: true
        case .incomplete: self == RefreshScheduler.skipped
        case .signInRequired: false
        }
    }
}

extension AccountRecord {
    /// The login's streak holds (`NoPlanStreak.holds`): No plan, or No limits when it is billed by usage. Either way it
    /// is read every 6 hours and is never Next.
    public var isNoPlan: Bool { noPlan?.holds == true }
    /// The streak holds and its latest answer was a login billed by usage: No limits (P581).
    public var isNoLimits: Bool { isNoPlan && noPlan?.usageBased == true }
}
