import Foundation
import JuiceCore
import Observation

/// Settings › Money per account (Juice spec §6; Juice Island spec §8 decision 14): the key file's path (never the key),
/// an optional credit with its date (Anthropic, OpenAI), an optional top-up (OpenRouter, RunPod), the id a source's path
/// needs (xAI's team, Fireworks' account) and the account's short name. Keys are `ji.money.<field>.<account>`, so a
/// source's first key keeps the keys it had before a source could hold more (`ji.money.topUp.RunPod`) and a further one
/// has its own (`ji.money.label.OpenRouter 2`); the Show switches and the runway thresholds stay in `AppSettings`.
/// `defaults` nil keeps everything in memory.
@MainActor
@Observable
final class MoneySettings {
    enum Key {
        static func keyFile(_ id: MoneyAccount) -> String { "ji.money.keyFile.\(id.rawValue)" }
        static func credit(_ id: MoneyAccount) -> String { "ji.money.credit.\(id.rawValue)" }
        static func creditDate(_ id: MoneyAccount) -> String { "ji.money.creditDate.\(id.rawValue)" }
        static func topUp(_ id: MoneyAccount) -> String { "ji.money.topUp.\(id.rawValue)" }
        static func accountID(_ id: MoneyAccount) -> String { "ji.money.accountID.\(id.rawValue)" }
        static func label(_ id: MoneyAccount) -> String { "ji.money.label.\(id.rawValue)" }
    }

    /// A label is a short name: at most this many characters.
    static let labelLimit = 24

    @ObservationIgnored private let defaults: UserDefaults?
    /// In memory only (renders and tests): the money readers never start.
    var isEphemeral: Bool { defaults == nil }

    /// A picked key file, `~`-abbreviated. Absent: the default lookup under `~/.config/<provider>/`.
    var keyFiles: [MoneyAccount: String] { didSet { save(keyFiles, oldValue, Key.keyFile) } }
    var credits: [MoneyAccount: Double] { didSet { save(credits, oldValue, Key.credit) } }
    var creditDates: [MoneyAccount: Date] { didSet { save(creditDates, oldValue, Key.creditDate) } }
    var topUps: [MoneyAccount: Double] { didSet { save(topUps, oldValue, Key.topUp) } }
    /// xAI's team id, Fireworks' account id, as typed (the readers trim and lower-case it).
    var accountIDs: [MoneyAccount: String] { didSet { save(accountIDs, oldValue, Key.accountID) } }
    var labels: [MoneyAccount: String] { didSet { save(labels, oldValue, Key.label) } }

    init(defaults: UserDefaults?) {
        self.defaults = defaults
        func load<Value>(_ key: (MoneyAccount) -> String, _ type: Value.Type) -> [MoneyAccount: Value] {
            Dictionary(uniqueKeysWithValues: MoneyAccount.allCases.compactMap { id in
                (defaults?.object(forKey: key(id)) as? Value).map { (id, $0) }
            })
        }
        keyFiles = load(Key.keyFile, String.self)
        credits = load(Key.credit, Double.self)
        creditDates = load(Key.creditDate, Date.self)
        topUps = load(Key.topUp, Double.self)
        accountIDs = load(Key.accountID, String.self)
        labels = load(Key.label, String.self)
    }

    /// What the scheduler and the rules need for `account`.
    func source(_ account: MoneyAccount) -> MoneySourceSettings {
        let source = account.source
        return MoneySourceSettings(keyPath: keyFiles[account], credit: source.takesCredit ? credits[account] : nil,
                                   creditDate: source.takesCredit ? creditDates[account] : nil,
                                   topUp: source.takesTopUp ? topUps[account] : nil,
                                   accountID: source.accountIDName == nil ? nil : accountIDs[account], label: labels[account])
    }

    /// The settings of `accounts`.
    func all(_ accounts: [MoneyAccount]) -> [MoneyAccount: MoneySourceSettings] {
        Dictionary(uniqueKeysWithValues: accounts.map { ($0, source($0)) })
    }

    /// Keeps `text` as the account's id when it is one of its source's pattern, as the path takes it
    /// (`MoneySource.acceptedID`: `accounts/my-team` keeps `my-team`); empty clears it. Anything else is not kept, so a
    /// key pasted into the wrong field never reaches the defaults, and its word comes back (`Not a team ID`).
    func setAccountID(_ text: String?, for account: MoneyAccount) -> String? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            if accountIDs[account] != nil { accountIDs[account] = nil }
            return nil
        }
        guard let id = account.source.acceptedID(trimmed) else { return account.source.notAnIDWord ?? "Not valid" }
        if accountIDs[account] != id { accountIDs[account] = id }
        return nil
    }

    /// The account's name as the owner typed it: trimmed, at most `labelLimit` characters, one line; empty is no label.
    static func cleanLabel(_ text: String) -> String? {
        let line = text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        let cut = String(line.prefix(labelLimit)).trimmingCharacters(in: .whitespaces)
        return cut.isEmpty ? nil : cut
    }

    /// Everything kept here for a further key whose key file is gone: its settings go with it, so a key added in that
    /// place later starts clean (its Show switch goes too: `AppSettings.forgetMoney`). Only what is set is cleared.
    func forget(_ account: MoneyAccount) {
        guard !account.isFirst else { return }
        if keyFiles[account] != nil { keyFiles[account] = nil }
        if credits[account] != nil { credits[account] = nil }
        if creditDates[account] != nil { creditDates[account] = nil }
        if topUps[account] != nil { topUps[account] = nil }
        if accountIDs[account] != nil { accountIDs[account] = nil }
        if labels[account] != nil { labels[account] = nil }
    }

    /// Writes only what changed, so one change never rewrites every account's key.
    private func save<Value: Equatable>(_ values: [MoneyAccount: Value], _ old: [MoneyAccount: Value], _ key: (MoneyAccount) -> String) {
        guard let defaults else { return }
        for id in Set(values.keys).union(old.keys) where values[id] != old[id] {
            if let value = values[id] { defaults.set(value, forKey: key(id)) } else { defaults.removeObject(forKey: key(id)) }
        }
    }
}
