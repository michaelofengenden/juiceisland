import Foundation
import Testing
@testable import JuiceCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let homeDir = "/h"
private let codexHome = Account(provider: .codex, folder: "/h/.codex", alias: "default")
private let side = Account(provider: .codex, folder: "/h/.codex-side", alias: "Side")
private let fresh = Account(provider: .codex, folder: "/h/.codex-fresh", alias: "Fresh")
private let preset = Account(provider: .codex, folder: "/h/.codex-preset", alias: "Preset")
private let work = Account(provider: .claude, folder: "/h/.claude-work", alias: "Work")

private func login(_ provider: Provider, _ email: String, used: Double? = nil, at date: Date = t0, monitored: Bool = true) -> Login {
    let record = used.map { used in
        AccountRecord(lastGood: AccountReading(accountID: "", readAt: date, plan: "pro",
                                               windows: [UsageWindow(seconds: 18_000, usedPercent: used, resetsAt: date + 3_600)]),
                      lastAttemptAt: date)
    }
    return Login(provider: provider, email: email, monitored: monitored, record: record)
}

private func byID(_ logins: Login...) -> [String: Login] {
    Dictionary(uniqueKeysWithValues: logins.map { ($0.id, $0) })
}

/// One row per login a folder holds, labelled by its email, with its plan and battery and every folder that holds it,
/// the default folder first; then the folders signed out or not asked yet. Logins follow the account list's order of
/// their first folder; one no folder holds is not listed, though it keeps its record. The panel draws the monitored
/// logins, and a signed-out folder raises the sign-in badge with no battery of its own.
@Test func eachLoginIsOneRowWithItsFolders() throws {
    let a = login(.codex, "a@example.com", used: 30), b = login(.codex, "b@example.com", used: 60, monitored: false)
    let gone = login(.codex, "c@example.com", used: 90, at: t0 - 60)
    let w = login(.claude, "w@example.com")
    let accounts = [side, codexHome, fresh, preset, work]
    let folders: [String: FolderState] = [side.id: .signedIn(login: a.id), codexHome.id: .signedIn(login: a.id),
                                          fresh.id: .signedIn(login: b.id), preset.id: .signedOut, work.id: .signedIn(login: w.id)]
    let lists = LoginList.build(accounts: accounts, logins: byID(a, b, gone, w), folders: folders, signingIn: [], now: t0 + 30,
                                home: homeDir)
    #expect(lists.map(\.provider) == [.claude, .codex])
    let codex = try #require(lists.last)
    #expect(codex.logins.map(\.email) == ["a@example.com", "b@example.com"])
    #expect(codex.logins[0].folders == [codexHome, side] && codex.logins[1].folders == [fresh])
    #expect(codex.logins[0].plan == "Pro" && codex.logins[0].battery.alias == "a" && codex.logins[0].battery.isNext)
    #expect(codex.logins[0].battery.state == .available(percentLeft: 70, isLow: false))
    #expect(codex.logins[1].monitored == false && !codex.logins[1].battery.isNext)
    #expect(codex.folders == [LooseFolder(folder: preset, state: .signedOut)])
    #expect(lists.first?.logins.map(\.battery.state) == [.unknown])

    let entries = LoginList.panelEntries(lists)
    #expect(entries.map(\.id) == [w.id, a.id])
    #expect(LoginList.needsSignIn(lists))
    let panel = PanelModelBuilder.build(entries: entries, records: [a.id: a.record!, gone.id: gone.record!], signingIn: [],
                                        attention: LoginList.needsSignIn(lists), money: [], now: t0 + 30)
    #expect(panel.rows.last?.batteries.map(\.alias) == ["a"] && panel.attentionNeeded)
    #expect(panel.rows.last?.availability == Rules.Availability(available: 1, total: 1, isKnown: true))
}

/// A folder not asked yet, or switched off, holds no login row; a login no enabled folder holds is left out, with or
/// without a reading; a provider with nothing to show has no part.
@Test func foldersAndLoginsWithNothingToShowAreLeftOut() {
    let old = login(.codex, "old@example.com", used: 10)
    let empty = login(.codex, "empty@example.com")
    var off = side
    off.monitored = false
    let a = login(.codex, "a@example.com")
    let lists = LoginList.build(accounts: [off, fresh], logins: byID(old, empty, a), folders: [off.id: .signedIn(login: a.id)],
                                signingIn: [], now: t0, home: homeDir)
    #expect(lists.count == 1 && lists[0].logins.isEmpty && lists[0].folders == [LooseFolder(folder: fresh, state: .unknown)])
    #expect(!LoginList.needsSignIn(lists))
    #expect(LoginList.build(accounts: [], logins: byID(old), folders: [:], signingIn: [], now: t0, home: homeDir).isEmpty)
}

/// A battery is named after its email's local part, or the whole email where two logins would share one.
@Test func twoLoginsNeverShareABatteryName() {
    let names = LoginList.names([login(.codex, "sam@example.com"), login(.codex, "sam@example.org"), login(.codex, "kit@example.com")])
    #expect(Set(names.values) == ["sam@example.com", "sam@example.org", "kit"])
}
