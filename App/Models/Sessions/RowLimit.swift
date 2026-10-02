import Foundation
import IslandEngine
import JuiceCore

/// A limit or an API error a session's last turn stopped on, as its row and card say it (P700): "Limit reached ·
/// resets 15:00", "API error · overloaded", and once a usage limit's reset has passed, "Limit reset" (quiet: it no
/// longer needs the owner, P702). Plain values, worded once here for every surface.
struct RowLimit: Equatable, Sendable {
    var kind: SessionLimit.Kind
    var resetsAt: Date?
    /// The usage limit's reset had passed when the row was mapped.
    var passed = false
    /// The session's provider and its own profile folder (its account tag), for the best other account
    /// (`LimitAlternative`); nil when the session's account is not known, and then none is offered.
    var provider: Provider?
    var folder: String?
    /// The id of the account whose folder it is (the tag's `accountID`), which names the session's login whatever link
    /// the folder is reached by (`LoginIndex`).
    var accountID: String?
    /// "resets 15:00" as the row was mapped (`resetText`).
    var resets: String?

    init(_ limit: SessionLimit, provider: Provider? = nil, folder: String? = nil, accountID: String? = nil, now: Date,
         zone: TimeZone = .current) {
        kind = limit.kind
        resetsAt = limit.resetsAt
        passed = limit.hasReset(at: now)
        self.provider = provider
        self.folder = folder
        self.accountID = accountID
        resets = limit.resetsAt.flatMap { passed ? nil : Self.resetText($0, now: now, zone: zone) }
    }

    var isUsageLimit: Bool { kind == .usageLimit }

    /// The status line's word: "Limit reached", "Limit reset", "API error".
    var word: String {
        guard isUsageLimit else { return "API error" }
        return passed ? "Limit reset" : "Limit reached"
    }

    /// What follows the word: when the limit lifts, or the API error's kind.
    var text: String? {
        switch kind {
        case .usageLimit: resets
        case .rateLimited: "rate limited"
        case .overloaded: "overloaded"
        case .serverError: "server error"
        }
    }

    /// The word and its text, as one line ("Limit reached · resets 15:00").
    var line: String { [word, text].compactMap { $0 }.joined(separator: " · ") }

    /// It still warns (in the needs-you colour, `NeedsYouColour`); a reset limit is quiet.
    var warns: Bool { !passed }

    /// Another account helps only with the account's own limit, while it holds.
    var offersAlternative: Bool { isUsageLimit && !passed && provider != nil && folder != nil }

    /// "resets 15:00" today, "resets Fri 15:00" within the week, "resets Oct 7" further out, in the Mac's zone, 24-hour
    /// as the app's other times ("checked 15:00").
    static func resetText(_ date: Date, now: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)).day ?? 0
        formatter.dateFormat = days <= 0 ? "HH:mm" : days < 7 ? "EEE HH:mm" : "MMM d"
        return "resets " + formatter.string(from: date)
    }
}

/// The best other account of the same provider for a session stopped on its usage limit (P704): the login with the most
/// left on its battery, read from the batteries Juice already reads. Never the session's own login, never one that is
/// not monitored, and only a battery that has a reading to tell (`available`): a No plan or No limits login, one used
/// up, stale, signed out or not read yet is never offered. Ties go to the first in the account list's order.
struct LimitAlternative: Equatable, Sendable {
    var loginID: String
    /// The battery's name ("lab", "sam · Research Lab").
    var name: String
    var percentLeft: Int
    var provider: Provider
    /// The login's folder the new session runs under: its first (the provider's default folder first).
    var folder: String

    /// "lab has 71% left".
    var line: String { "\(name) has \(percentLeft)% left" }
    var action: String { "Open in \(name)" }

    static func best(for limit: RowLimit, logins: [ProviderLogins]) -> LimitAlternative? {
        guard limit.offersAlternative, let provider = limit.provider, let own = limit.folder else { return nil }
        let rows = logins.first { $0.provider == provider }?.logins ?? []
        // The session's own login: the one whose folders hold the session's folder. Not known, nothing is offered: the
        // one offered could be the session's own.
        var index = LoginIndex(rows)
        guard let mine = index.login(holding: own, accountID: limit.accountID) else { return nil }
        var best: LimitAlternative?
        for row in rows where row.id != mine.id && row.monitored {
            guard case let .available(left, _) = row.battery.state, left > 0, let folder = row.folders.first?.folder,
                  !same(folder, own), left > (best?.percentLeft ?? 0) else { continue }
            best = LimitAlternative(loginID: row.id, name: row.battery.alias, percentLeft: left, provider: provider, folder: folder)
        }
        return best
    }

    /// Two spellings of one folder (`~` or the home folder written out, a trailing slash).
    static func same(_ a: String, _ b: String) -> Bool { plain(a) == plain(b) }

    /// One spelling of a folder: `~` written out, standardized. No link is followed (nothing on disk is looked at).
    static func plain(_ path: String) -> String { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path }
}

/// The login whose folders hold a session's profile folder (P810, P704): by the id of the account whose folder it is,
/// when the engine's tag names one (exact, whatever link or spelling reaches the folder: the engine follows links, the
/// accounts file keeps the folder as written), else by the folder's spelling (`LimitAlternative.same`), for a folder
/// the engine's list does not name yet and for the demo. Built once over one provider's logins; the spellings are made
/// only at the first lookup the ids do not answer, once each.
struct LoginIndex {
    private let rows: [LoginRow]
    private var byID: [String: Int] = [:]
    private var byFolder: [String: Int]?

    init(_ rows: [LoginRow]) {
        self.rows = rows
        for (index, row) in rows.enumerated() {
            for folder in row.folders where byID[folder.id] == nil { byID[folder.id] = index }
        }
    }

    mutating func login(holding folder: String, accountID: String?) -> LoginRow? {
        if let accountID, let index = byID[accountID] { return rows[index] }
        let byFolder = self.byFolder ?? {
            var made: [String: Int] = [:]
            for (index, row) in rows.enumerated() {
                for held in row.folders {
                    let key = LimitAlternative.plain(held.folder)
                    if made[key] == nil { made[key] = index }
                }
            }
            return made
        }()
        self.byFolder = byFolder
        return byFolder[LimitAlternative.plain(folder)].map { rows[$0] }
    }
}
