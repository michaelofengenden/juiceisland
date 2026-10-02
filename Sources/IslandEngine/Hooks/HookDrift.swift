import Foundation
import JuiceCore

/// One hook entry Open Island's installer writes: the event, its group's matcher and the hook's timeout. The
/// command is the profile's managed command.
public struct HookEntrySpec: Hashable, Sendable {
    public let event: String
    public let matcher: String?
    public let timeout: Int?

    public init(event: String, matcher: String?, timeout: Int?) {
        self.event = event
        self.matcher = matcher
        self.timeout = timeout
    }
}

/// What upstream's installers write, per provider. The tables are private upstream, so they are repeated here and
/// `ExpectedHookEntriesDriftTests` fails when an upstream change makes them differ.
public enum ExpectedHookEntries {
    public static let claude: [HookEntrySpec] = [
        HookEntrySpec(event: "UserPromptSubmit", matcher: nil, timeout: nil),
        HookEntrySpec(event: "SessionStart", matcher: nil, timeout: nil),
        HookEntrySpec(event: "SessionEnd", matcher: nil, timeout: nil),
        HookEntrySpec(event: "Stop", matcher: nil, timeout: nil),
        HookEntrySpec(event: "StopFailure", matcher: nil, timeout: nil),
        HookEntrySpec(event: "SubagentStart", matcher: nil, timeout: nil),
        HookEntrySpec(event: "SubagentStop", matcher: nil, timeout: nil),
        HookEntrySpec(event: "Notification", matcher: "*", timeout: nil),
        HookEntrySpec(event: "PreToolUse", matcher: "*", timeout: nil),
        HookEntrySpec(event: "PermissionRequest", matcher: "*", timeout: 86_400),
        HookEntrySpec(event: "PostToolUse", matcher: "*", timeout: nil),
        HookEntrySpec(event: "PostToolUseFailure", matcher: "*", timeout: nil),
        HookEntrySpec(event: "PermissionDenied", matcher: "*", timeout: nil),
        HookEntrySpec(event: "PreCompact", matcher: nil, timeout: nil),
    ]

    public static let codex: [HookEntrySpec] = [
        HookEntrySpec(event: "SessionStart", matcher: "startup|resume", timeout: 45),
        HookEntrySpec(event: "UserPromptSubmit", matcher: nil, timeout: 45),
        HookEntrySpec(event: "PermissionRequest", matcher: nil, timeout: 3_600),
        HookEntrySpec(event: "Stop", matcher: nil, timeout: 45),
    ]

    public static func entries(for provider: Provider) -> [HookEntrySpec] {
        provider == .claude ? claude : codex
    }
}

/// What one drift check found in a profile's settings.json or hooks.json.
public enum HookDriftReading: Equatable, Sendable {
    /// Empty or not valid JSON: someone is probably saving the file right now. No alert and no state change;
    /// the next file event checks again (P51).
    case beingEdited
    /// Our command is in no hook of the file (or there is no file).
    case notInstalled
    /// Every expected entry is there.
    case complete
    /// Our command is there, but these entries are not (missing, or with another matcher or timeout).
    case drifted(missing: [HookEntrySpec])
}

/// The one row the window and island show for a profile whose hooks drifted. Repair is Install, on a click.
public struct HookDriftAlert: Equatable, Sendable {
    public let targetID: String
    public let alias: String
    public let missing: [HookEntrySpec]

    public init(targetID: String, alias: String, missing: [HookEntrySpec]) {
        self.targetID = targetID
        self.alias = alias
        self.missing = missing
    }

    public var text: String { "Hooks missing in \(alias) · Repair" }
}

/// Drift detection: compares the expected (event, matcher, command, timeout) set with the file. It never writes and
/// never repairs; nothing installs or repairs hooks by itself (P26, changed to click-to-repair).
public enum HookDrift {
    public static func read(fileData: Data?, command: String, expected: [HookEntrySpec]) -> HookDriftReading {
        guard let fileData else { return .notInstalled }
        guard !fileData.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: fileData)) as? [String: Any] else { return .beingEdited }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        func groups(_ event: String) -> [[String: Any]] { (hooks[event] as? [[String: Any]]) ?? [] }
        func ours(_ group: [String: Any]) -> [[String: Any]] {
            ((group["hooks"] as? [[String: Any]]) ?? []).filter { $0["command"] as? String == command }
        }
        guard hooks.keys.contains(where: { groups($0).contains { !ours($0).isEmpty } }) else { return .notInstalled }
        let present = expected.filter { spec in
            groups(spec.event).contains { group in
                group["matcher"] as? String == spec.matcher && ours(group).contains { $0["timeout"] as? Int == spec.timeout }
            }
        }
        if present.count == expected.count { return .complete }
        return .drifted(missing: expected.filter { !present.contains($0) })
    }

    /// A drifted profile always gets the row. A profile with none of our entries gets it when its hooks were there
    /// before: the owner installed there (intent `installed`, which `recordedIntent` also sets the first time a
    /// profile hooked outside the app reads complete), or the previous reading was complete or drifted. Never right
    /// after the owner's own Remove (intent `removed`), and never for a profile that was simply never installed.
    public static func alert(for target: ProfileHookTarget, intent: ProfileHookIntent, reading: HookDriftReading,
                             previous: HookDriftReading? = nil) -> HookDriftAlert? {
        switch reading {
        case .drifted(let missing):
            return HookDriftAlert(targetID: target.id, alias: target.alias, missing: missing)
        case .notInstalled where intent != .removed:
            let hadHooks: Bool
            switch previous {
            case .complete, .drifted: hadHooks = true
            default: hadHooks = intent == .installed
            }
            guard hadHooks else { return nil }
            return HookDriftAlert(targetID: target.id, alias: target.alias,
                                  missing: ExpectedHookEntries.entries(for: target.provider))
        default:
            return nil
        }
    }

    /// The intent to store after a check. A profile that reads complete counts as installed from then on, even when
    /// its hooks came from elsewhere (the default profiles, which Open Island hooked and cutover never reinstalls),
    /// so losing every entry later still raises the row, after a relaunch too. Otherwise the intent is unchanged.
    public static func recordedIntent(after reading: HookDriftReading, intent: ProfileHookIntent) -> ProfileHookIntent {
        reading == .complete ? .installed : intent
    }

    /// Setup's and Diagnostics' state word, from the inspector's state and the drift reading of the same file: a
    /// missing entry, or one with another matcher or timeout, makes an installed profile `partial`, so the count
    /// (n/14, n/4) compares the whole expected set. Refusals, health errors and "not installed" pass through.
    public static func setupState(_ status: ProfileHookStatus, reading: HookDriftReading) -> ProfileHookStatus.State {
        guard case let .drifted(missing) = reading else { return status.state }
        switch status.state {
        case .installed, .partial, .codexFeatureOff, .codexNeedsTrust:
            return .partial(installed: max(0, status.expectedEventCount - missing.count), expected: status.expectedEventCount)
        default:
            return status.state
        }
    }
}

/// When drift checks run. A file event starts a 2 s quiet period for that profile, and every later event restarts
/// it; the check runs once the file has been quiet that long. Launch, wake and a profile change check every profile
/// at once (M3 calls `read` directly for those).
public struct HookDriftSchedule: Sendable {
    public static let quietPeriod: TimeInterval = 2
    private var lastEventAt: [String: Date] = [:]

    public init() {}

    public mutating func fileChanged(_ targetID: String, at date: Date) {
        lastEventAt[targetID] = date
    }

    /// Profiles whose files have been quiet for 2 s; each is returned once per burst of events.
    public mutating func takeDue(now: Date) -> [String] {
        let due = lastEventAt.filter { now.timeIntervalSince($0.value) >= Self.quietPeriod }.keys.sorted()
        for id in due { lastEventAt[id] = nil }
        return due
    }

    /// When the next waiting profile's quiet period ends; nil when no event waits.
    public var nextDue: Date? { lastEventAt.values.min().map { $0.addingTimeInterval(Self.quietPeriod) } }
}
