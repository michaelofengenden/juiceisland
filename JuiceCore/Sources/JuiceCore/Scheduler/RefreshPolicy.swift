import Foundation

/// The cadence rules from spec §8.1 and §9.5, as numbers with no clock attached.
public struct RefreshPolicy: Sendable, Equatable {
    public var claudeInterval: TimeInterval = 300
    public var claudeBoostedInterval: TimeInterval = 120
    public var codexInterval: TimeInterval = 60
    public var codexIntervalAt75: TimeInterval = 30
    public var codexIntervalAt90: TimeInterval = 15
    public var retryAfterMargin: TimeInterval = 900
    /// A failed read's wait doubles from the provider's normal floor with each failure in a row, up to this (P106).
    public var maxReadBackoff: TimeInterval = 1_200
    /// A failed question's wait (who is signed in: `claude auth status`, Codex `account/read`), never a usage read's.
    public var failureBackoff: [TimeInterval] = [30, 60, 120, 300, 600]
    /// Sign-in needed and CLI missing are not fixed by polling; try again hourly in case the user fixed it outside Juice.
    public var userFixableDelay: TimeInterval = 3_600
    public var boostDuration: TimeInterval = 600
    public var maxConcurrentReads = 3
    /// Seconds between accounts re-read after a sleep/resume, when their own schedule doesn't already keep them apart.
    public var resumeStagger: TimeInterval = 3

    public init() {}

    public func interval(for provider: Provider, reading: AccountReading?, boosted: Bool) -> TimeInterval {
        switch provider {
        case .claude:
            return boosted ? claudeBoostedInterval : claudeInterval
        case .codex:
            let used = reading?.windows.map(\.usedPercent).max() ?? 0
            if used >= 90 { return codexIntervalAt90 }
            if used >= 75 { return codexIntervalAt75 }
            return codexInterval
        }
    }

    /// The wait after a failed usage read. A 429 waits Retry-After plus the margin; sign-in needed and a missing CLI, the
    /// user-fixable delay. Every other failure (a timeout, an app-server error, an incomplete reading, an outdated CLI,
    /// offline) may already have reached the vendor, so it never comes back sooner than a normal read would: the
    /// provider's floor (Claude 300 s, Codex 60 s, whatever the use), doubled with each failure in a row, up to
    /// `maxReadBackoff` (P106).
    public func delay(after error: ReadError, consecutiveFailures: Int, provider: Provider) -> TimeInterval {
        switch error {
        case .rateLimited(let retryAfter): return (retryAfter ?? 0) + retryAfterMargin
        case .signInRequired, .cliNotFound: return userFixableDelay
        default:
            let floor = interval(for: provider, reading: nil, boosted: false)
            let doublings = min(max(consecutiveFailures, 1) - 1, 16)
            return min(floor * Double(1 << doublings), max(floor, maxReadBackoff))
        }
    }

    /// The wait after a failed question (who is signed in: `claude auth status`, or a Codex home's `account/read` from a
    /// fresh app-server), which reads no usage: 30 s, then 60, 120, 300 and 600. A question that found the folder signed
    /// out waits the user-fixable delay. Never for a usage read: those wait `delay(after:consecutiveFailures:provider:)`.
    public func questionDelay(after error: ReadError, consecutiveFailures: Int) -> TimeInterval {
        switch error {
        case .rateLimited(let retryAfter): return (retryAfter ?? 0) + retryAfterMargin
        case .signInRequired, .cliNotFound: return userFixableDelay
        default: return failureBackoff[min(max(consecutiveFailures, 1) - 1, failureBackoff.count - 1)]
        }
    }

    /// Seconds between the first reads of consecutive accounts of one provider.
    public func stagger(for provider: Provider) -> TimeInterval {
        provider == .claude ? 20 : 2
    }
}
