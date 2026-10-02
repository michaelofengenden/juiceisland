import Foundation

/// General › Show as.
enum ShowAs: String, CaseIterable, Sendable { case window, island }
/// General › Window header.
enum HeaderLayout: String, CaseIterable, Sendable { case section, strip }
/// Island › Style.
enum IslandStyle: String, CaseIterable, Sendable { case clean, detailed }
/// Island › Usage placement in the island.
enum UsagePlacement: String, CaseIterable, Sendable { case section, headerStrip }
/// Island › Usage shows first (P813): the accounts the owner's sessions use (`AccountsInUse`), or the Next one, as it was.
enum UsageFirst: String, CaseIterable, Sendable { case inUse, next }
/// Island › Glyph colour.
enum GlyphColourMode: String, CaseIterable, Sendable { case byState, byAgent }
/// Island › Glyph style.
enum GlyphStyle: String, CaseIterable, Sendable { case pixel, liquid, sand }
/// Island › Running (Liquid only): Slim, a thin band a crest runs along (the default), or Full, the round body that rocks.
enum LiquidRunningLook: String, CaseIterable, Sendable { case slim, full }
/// Island › Pill count: the active sessions (`SessionActivity`), or only the ones that need you.
enum PillCount: String, CaseIterable, Sendable {
    case active, needsYou

    /// A stored choice. "allSessions", the count before it meant active sessions, reads as `active`.
    init?(stored: String) { self.init(rawValue: stored == "allSessions" ? Self.active.rawValue : stored) }
}
/// Island › When a session finishes: open the Done card, or keep the island closed with a green dot on the pill.
enum FinishBehaviour: String, CaseIterable, Sendable { case card, glance }
/// Island › Stalled after: how long a running session may show no sign of life, with nothing waiting on the owner, before
/// its row says Stalled and the island gives its one quiet notice (P312). Off: neither.
enum StallLimit: String, CaseIterable, Sendable {
    case off, fiveMinutes, tenMinutes, thirtyMinutes

    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .fiveMinutes: 5 * 60
        case .tenMinutes: 10 * 60
        case .thirtyMinutes: 30 * 60
        }
    }
}
/// Island › Archive idle sessions after (P727): a session done or idle this long is archived on its own (`AutoTidy`).
/// More than a day, as the owner asked; 3 days by default.
enum ArchiveAfter: String, CaseIterable, Sendable {
    case off, twoDays, threeDays, oneWeek

    var seconds: TimeInterval? {
        switch self {
        case .off: nil
        case .twoDays: 2 * 86_400
        case .threeDays: 3 * 86_400
        case .oneWeek: 7 * 86_400
        }
    }

    var label: String {
        switch self {
        case .off: "Off"
        case .twoDays: "2 days"
        case .threeDays: "3 days"
        case .oneWeek: "1 week"
        }
    }
}

/// Island › Motion: how the island opens, closes and swaps a card (`MotionTuning`). An A/B for the owner; once they have
/// picked, the other goes.
/// Liquid is Refined with the liquid outline (`LiquidPath`): the island moves as a liquid, and a card buds out below the
/// list.
enum MotionFeel: String, CaseIterable, Sendable { case original, refined, liquid }
/// Island › Hover: how the pill swells under the pointer and how long a rest opens it (`MotionTuning`). An A/B, as Motion.
enum HoverFeel: String, CaseIterable, Sendable { case calm, quick }
/// Diagnostics › Motion › Outline: who draws the island's black outline and the clip that reveals its content. SwiftUI
/// steps it on the app's main thread, a frame at a time; Core Animation plays the model's plan for it in the render
/// server (`IslandSurfaceLayers`), so a busy main thread no longer holds the edge. An A/B for the owner, as Motion.
enum IslandOutline: String, CaseIterable, Codable, Sendable { case swiftUI, coreAnimation }

/// A sound choice: a system sound by name (`NSSound(named:)`), or none.
enum SoundChoice: Equatable, Sendable {
    case none
    case system(String)

    var storageValue: String {
        switch self {
        case .none: ""
        case let .system(name): name
        }
    }

    init(storageValue: String) { self = storageValue.isEmpty ? .none : .system(storageValue) }
}

/// Settings › Accounts › Usage source: standalone Juice's files (read only), or the fictional demo figures.
enum UsageSource: String, CaseIterable, Sendable {
    case juiceReadings, demo

    var title: String {
        switch self {
        case .juiceReadings: "Juice's readings (read-only)"
        case .demo: "Demo"
        }
    }
}
