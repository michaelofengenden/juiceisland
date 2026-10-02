import SwiftUI

/// The closed pill's count (prototype L1608): the active sessions (`SessionActivity`) or only the ones that need you.
/// Its one glyph is `PillLead`'s, in the agent's own look (P151).
struct PillSummary: Equatable {
    /// nil draws no count (nothing active, or Needs you with nothing waiting).
    var count: Int?

    static func make(rows: [SessionRow], countMode: PillCount, now: Date) -> PillSummary {
        let counted = switch countMode {
        case .active: rows.filter { SessionActivity.isActive($0, now: now) }.count
        case .needsYou: rows.filter { $0.bucket == .needsYou }.count
        }
        return PillSummary(count: counted == 0 ? nil : counted)
    }

    /// The count in words, for VoiceOver: "3 active sessions", "1 needs you".
    static func spoken(_ count: Int, mode: PillCount) -> String {
        switch mode {
        case .active: "\(count) active \(count == 1 ? "session" : "sessions")"
        case .needsYou: "\(count) \(count == 1 ? "needs" : "need") you"
        }
    }
}
