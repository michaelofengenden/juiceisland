import Foundation

/// Two folders can hold the same login. Identity is the email, from the folder (Claude) or the last reading (Codex), and
/// the organization the last reading names (P580: one email in two Claude organizations is two logins). A folder whose
/// reading names no organization (standalone Juice's own reads, a folder not read yet) goes with the first folder of its
/// email, as before organizations were named. A folder that is signed out holds no login, so it is
/// nobody's duplicate: it keeps its own battery, which asks for a sign-in, and never hides the folder that holds its
/// last login now.
public enum AccountIdentity {
    public static func email(for account: Account, records: [String: AccountRecord]) -> String? {
        if records[account.id]?.lastError == .signInRequired { return nil }
        let email = account.knownEmail ?? records[account.id]?.lastGood?.email
        return email?.lowercased()
    }

    /// The organization the folder's last reading names, when that reading is its email's; nil otherwise.
    static func org(for account: Account, email: String, records: [String: AccountRecord]) -> String? {
        guard let reading = records[account.id]?.lastGood, reading.email?.lowercased() == email else { return nil }
        return reading.org
    }

    /// The earlier account, in user order, with the same provider and email, and the same organization where both name
    /// one; nil if this one is the first or has no identity.
    ///
    /// `account` is located in `accounts` by `id` (provider and folder), never by whole-value equality: a caller can
    /// hold a copy whose alias or monitored flag has since changed, and that copy must still resolve. An account that
    /// is not in `accounts` at all has nothing earlier than it, so the answer is nil.
    public static func duplicateOf(_ account: Account, in accounts: [Account], records: [String: AccountRecord]) -> Account? {
        guard let email = email(for: account, records: records),
              let position = accounts.firstIndex(where: { $0.id == account.id }) else { return nil }
        let org = org(for: account, email: email, records: records)
        return accounts[..<position].first { other in
            guard other.provider == account.provider, let otherEmail = self.email(for: other, records: records), otherEmail == email else {
                return false
            }
            guard let org, let otherOrg = self.org(for: other, email: otherEmail, records: records) else { return true }
            return otherOrg == org
        }
    }

    public static func uniqueAccounts(_ accounts: [Account], records: [String: AccountRecord]) -> [Account] {
        accounts.filter { duplicateOf($0, in: accounts, records: records) == nil }
    }
}
