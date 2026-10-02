import Foundation
import Testing
@testable import JuiceCore

@Test func duplicateIdentitiesCollapseToTheFirstInOrder() {
    let a = Account(provider: .claude, folder: "/h/.claude", alias: "a", knownEmail: "me@x.com")
    let b = Account(provider: .claude, folder: "/h/.claude-b", alias: "b", knownEmail: "ME@x.com")
    let c = Account(provider: .codex, folder: "/h/.codex", alias: "c")
    let d = Account(provider: .codex, folder: "/h/.codex-d", alias: "d")
    let now = Date()
    let records = [
        c.id: AccountRecord(lastGood: AccountReading(accountID: c.id, readAt: now, email: "team@x.com", windows: [])),
        d.id: AccountRecord(lastGood: AccountReading(accountID: d.id, readAt: now, email: "team@x.com", windows: [])),
    ]
    let unique = AccountIdentity.uniqueAccounts([a, b, c, d], records: records)
    #expect(unique.map(\.alias) == ["a", "c"])
    #expect(AccountIdentity.duplicateOf(b, in: [a, b, c, d], records: records)?.alias == "a")
    #expect(AccountIdentity.duplicateOf(a, in: [a, b, c, d], records: records) == nil)
    #expect(AccountIdentity.email(for: c, records: records) == "team@x.com")
}

@Test func oneEmailOnTwoProvidersIsTwoAccounts() {
    let claude = Account(provider: .claude, folder: "/h/.claude", alias: "claude", knownEmail: "me@x.com")
    let codex = Account(provider: .codex, folder: "/h/.codex", alias: "codex", knownEmail: "me@x.com")
    #expect(AccountIdentity.duplicateOf(codex, in: [claude, codex], records: [:]) == nil)
    #expect(AccountIdentity.uniqueAccounts([claude, codex], records: [:]).map(\.alias) == ["claude", "codex"])
}

@Test func aCopyWhoseAliasHasChangedStillResolves() {
    let first = Account(provider: .claude, folder: "/h/.claude", alias: "first", knownEmail: "me@x.com")
    let second = Account(provider: .claude, folder: "/h/.claude-second", alias: "second", knownEmail: "me@x.com")
    var stale = second
    stale.alias = "renamed"
    stale.monitored = false
    #expect(AccountIdentity.duplicateOf(stale, in: [first, second], records: [:])?.alias == "first")
    #expect(AccountIdentity.duplicateOf(first, in: [first, second], records: [:]) == nil)
}
