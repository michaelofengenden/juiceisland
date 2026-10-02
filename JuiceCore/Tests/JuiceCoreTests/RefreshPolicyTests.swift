import Foundation
import Testing
@testable import JuiceCore

private func codexReading(used: Double) -> AccountReading {
    AccountReading(accountID: "codex:/x", readAt: Date(), windows: [
        UsageWindow(seconds: 18_000, usedPercent: 10, resetsAt: nil),
        UsageWindow(seconds: 604_800, usedPercent: used, resetsAt: nil),
    ])
}

@Test func intervalsFollowTheSpec() {
    let policy = RefreshPolicy()
    #expect(policy.interval(for: .claude, reading: nil, boosted: false) == 300)
    #expect(policy.interval(for: .claude, reading: nil, boosted: true) == 120)
    #expect(policy.interval(for: .codex, reading: codexReading(used: 10), boosted: false) == 60)
    #expect(policy.interval(for: .codex, reading: codexReading(used: 75), boosted: false) == 30)
    #expect(policy.interval(for: .codex, reading: codexReading(used: 90), boosted: false) == 15)
    #expect(policy.interval(for: .codex, reading: nil, boosted: false) == 60)
}

@Test func failureDelaysBackOffAndHonourRetryAfter() {
    let policy = RefreshPolicy()
    #expect(policy.delay(after: .rateLimited(retryAfter: 120), consecutiveFailures: 1, provider: .claude) == 120 + 900)
    #expect(policy.delay(after: .rateLimited(retryAfter: nil), consecutiveFailures: 1, provider: .codex) == 900)
    #expect(policy.delay(after: .signInRequired, consecutiveFailures: 1, provider: .claude) == 3_600)
    #expect(policy.delay(after: .cliNotFound, consecutiveFailures: 1, provider: .codex) == 3_600)
}

/// P106: a failed read may already have reached the vendor, so its retry never comes sooner than the provider's normal
/// floor (Claude 300 s, Codex 60 s, even near a limit), and doubles from there with each failure in a row, up to 20 min.
@Test func aFailedReadNeverComesBackSoonerThanTheFloor() {
    let policy = RefreshPolicy()
    let failures: [ReadError] = [.timeout, .failed("app-server exited"), .incomplete("no windows reported"),
                                 .cliUpdateNeeded("unknown option"), .offline]
    for error in failures {
        #expect((1...8).map { policy.delay(after: error, consecutiveFailures: $0, provider: .claude) }
                == [300, 600, 1_200, 1_200, 1_200, 1_200, 1_200, 1_200])
        #expect((1...8).map { policy.delay(after: error, consecutiveFailures: $0, provider: .codex) }
                == [60, 120, 240, 480, 960, 1_200, 1_200, 1_200])
    }
    #expect(policy.delay(after: .timeout, consecutiveFailures: 0, provider: .codex) == 60)
    #expect(policy.delay(after: .timeout, consecutiveFailures: 10_000, provider: .claude) == 1_200)
    for failures in 1...8 {
        for provider in Provider.allCases {
            #expect(policy.delay(after: .timeout, consecutiveFailures: failures, provider: provider)
                    >= policy.interval(for: provider, reading: nil, boosted: false))
        }
    }
}

/// A question (who is signed in) reads no usage: it keeps the short backoff.
@Test func aFailedQuestionKeepsTheShortBackoff() {
    let policy = RefreshPolicy()
    #expect((1...6).map { policy.questionDelay(after: .timeout, consecutiveFailures: $0) } == [30, 60, 120, 300, 600, 600])
    #expect(policy.questionDelay(after: .signInRequired, consecutiveFailures: 1) == 3_600)
}

@Test func staggerOnlyAppliesToClaude() {
    let policy = RefreshPolicy()
    #expect(policy.stagger(for: .claude) == 20)
    #expect(policy.stagger(for: .codex) == 2)
}
