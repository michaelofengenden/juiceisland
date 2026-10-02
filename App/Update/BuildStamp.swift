import Foundation

/// What `scripts/build-app.sh` stamps into the built app's Info.plist: the commit it was built from (with "-dirty"
/// when the tree had uncommitted changes), when, and the repository it came from. A build without the stamp (Xcode
/// runs, `swift test`) reads as "unknown build" and never offers an update.
struct BuildStamp: Equatable, Sendable {
    enum Key {
        static let commit = "JIBuildCommit"
        static let date = "JIBuildDate"
        static let repo = "JIRepoPath"
    }

    static let dirtySuffix = "-dirty"
    static let unknownText = "unknown build"

    /// The full commit, without "-dirty"; nil when the stamp is missing or is not a commit id.
    var commit: String?
    var dirty = false
    var date: Date?
    /// The repository's absolute path.
    var repoPath: String?

    init(commit: String?, dirty: Bool = false, date: Date? = nil, repoPath: String?) {
        self.commit = commit
        self.dirty = dirty
        self.date = date
        self.repoPath = repoPath
    }

    /// Reads the stamp from an Info.plist dictionary.
    init(info: [String: Any]?) {
        var raw = (info?[Key.commit] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.hasSuffix(Self.dirtySuffix) {
            dirty = true
            raw.removeLast(Self.dirtySuffix.count)
        }
        commit = Self.isCommitID(raw) ? raw.lowercased() : nil
        if commit == nil { dirty = false }
        date = (info?[Key.date] as? String).flatMap(Self.parseDate)
        let repo = (info?[Key.repo] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        repoPath = repo.hasPrefix("/") ? repo : nil
    }

    /// The running app's stamp.
    static var current: BuildStamp { BuildStamp(info: Bundle.main.infoDictionary) }

    var isKnown: Bool { commit != nil }
    var shortCommit: String? { commit.map { String($0.prefix(7)) } }

    /// Settings › About: "Build 1a2b3c4 · 2026-09-24 14:05", "-dirty" after the id for a dirty build.
    func aboutLine(timeZone: TimeZone = .current) -> String {
        guard let short = shortCommit else { return Self.unknownText }
        let id = short + (dirty ? Self.dirtySuffix : "")
        guard let date else { return "Build \(id)" }
        return "Build \(id) · \(Self.format(date, timeZone: timeZone))"
    }

    static func isCommitID(_ text: String) -> Bool {
        (7...64).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    static func parseDate(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    static func format(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
