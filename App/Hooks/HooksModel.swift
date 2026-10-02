import Foundation
import IslandEngine
import JuiceCore

/// One Setup row (spec §4.5): a profile, its hook state in a word or two, and the one button a click may use.
struct HookSetupRow: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable { case normal, amber }

    var id: String
    var provider: Provider
    var alias: String
    /// `~/.claude-work`: shown in the app only, never written to a file.
    var folder: String
    var word: String
    /// Missing entries, the `/hooks` hint or a health issue; nil when the word says it all.
    var detail: String?
    var tone: Tone
    var action: ProfileHookAction?
    /// Why the button is unavailable, in a few words; nil when a click may go ahead.
    var refusal: String?
    var busy: Bool
    /// "14/14", "3/4": our entries against the expected set.
    var events: String
    var isMonitored: Bool

    var buttonTitle: String? { action.map(HookRowText.title(for:)) }
    var canClick: Bool { action != nil && refusal == nil && !busy }
}

/// The rest of Setup's facts: the other island apps and this build's helper. Read-only.
struct HookIntegrations: Equatable, Sendable {
    var openIslandRunning: Bool
    /// Profiles whose config holds Vibe Island's hooks.
    var vibeProfiles: Int
    /// This build carries `Contents/Helpers/OpenIslandHooks`, which Install copies.
    var helperInBuild: Bool
}

/// The managed helper against this build's (P163). Every hook command names the managed copy, which only an Update
/// click replaces: "Hook helper · Update" in Setup and on the drift rows. No hook config is written.
enum HelperUpdate: Equatable, Sendable {
    case available
    case updating
    /// The click was refused or failed, in a few words.
    case refused(String)
}

/// What Setup, Diagnostics' Hooks section and the drift rows read. `ProfileHooks` in the app, `DemoHooksModel` in
/// renders and tests. Nothing here installs, repairs or removes except `perform` and `installAllMonitored`, which
/// only a click calls (spec §3.5, §5.1 rule 5).
@MainActor
protocol HooksModel: AnyObject {
    var rows: [HookSetupRow] { get }
    /// "Hooks missing in <alias> · Repair", one per drifted profile, in Setup's order.
    var alerts: [HookDriftAlert] { get }
    var integrations: HookIntegrations { get }
    /// The last hook event per profile id (Diagnostics' "Last event"); empty while Live sessions is off.
    var lastEvents: [String: Date] { get }
    /// Why the last click on this profile was refused or failed, in a few words.
    func clickRefusal(for id: String) -> String?
    /// Install, Repair or Remove, on the owner's click only.
    func perform(_ action: ProfileHookAction, on id: String)
    /// The Setup button: Install in every monitored profile whose button offers Install right now. It never repairs:
    /// a drifted profile has its own Repair, since reinstalling moves a Codex home's trust keys (P20).
    func installAllMonitored()
    /// Starts reading and watching (the app's launch); renders never call it.
    func activate()
    /// "Hook helper · Update" while the managed helper differs from this build's; nil otherwise.
    var helperUpdate: HelperUpdate? { get }
    /// Replaces the managed helper with this build's, on the owner's click only; never a config file.
    func updateHelper()
    /// Setup's OpenCode row; nil when OpenCode is not on this Mac (P480).
    var openCodeRow: OpenCodeSetupRow? { get }
    /// The OpenCode row's Install, Update or Remove, on the owner's click only.
    func performOpenCode()
    /// Setup appeared: the plugin file is read again and the installed OpenCode's version asked (P487).
    func refreshOpenCode()
}

extension HooksModel {
    var helperUpdate: HelperUpdate? { nil }
    func updateHelper() {}
    var openCodeRow: OpenCodeSetupRow? { nil }
    func performOpenCode() {}
    func refreshOpenCode() {}

    /// Monitored rows a click could install now.
    var installableMonitoredRows: [HookSetupRow] {
        rows.filter { $0.isMonitored && $0.canClick && $0.action == .install }
    }
}

/// Setup's fixture profiles: fictional aliases and folders, nothing read or written. Its buttons do nothing.
@MainActor
final class DemoHooksModel: HooksModel {
    let rows: [HookSetupRow]
    let alerts: [HookDriftAlert]
    let integrations = HookIntegrations(openIslandRunning: false, vibeProfiles: 0, helperInBuild: true)
    let lastEvents: [String: Date]
    let helperUpdate: HelperUpdate?
    let openCodeRow: OpenCodeSetupRow?

    /// `showsDrift`: the window and island rows for Lab's drift (their own renders); `helperUpdate`: the helper's
    /// Update line; `openCodeRow`: the OpenCode row. Off by default, so other renders stay as they were.
    init(showsDrift: Bool = false, helperUpdate: HelperUpdate? = nil, openCodeRow: OpenCodeSetupRow? = nil,
         now: Date = DemoClock.now) {
        rows = Self.fixture
        self.helperUpdate = helperUpdate
        self.openCodeRow = openCodeRow
        let lab = Self.fixture.first { $0.alias == "Lab" }
        let target = lab.map { ProfileHookTarget(provider: $0.provider, folder: $0.folder, alias: $0.alias, isDefaultFolder: false,
                                                 accountID: nil, isMonitored: true) }
        alerts = showsDrift ? target.map { [HookDriftAlert(targetID: $0.id, alias: $0.alias, missing: [
            HookEntrySpec(event: "Notification", matcher: "*", timeout: nil), HookEntrySpec(event: "PreCompact", matcher: nil, timeout: nil),
        ])] } ?? [] : []
        let ages: [String: TimeInterval] = ["Main": 60, "Work": 720, "Research": 180, "Lab": 7_200, "Studio": 172_800,
                                            "Home": 20, "Team": 3_600, "Spare": 10_800]
        lastEvents = Dictionary(uniqueKeysWithValues: Self.fixture.compactMap { row in
            ages[row.alias].map { (row.id, now.addingTimeInterval(-$0)) }
        })
    }

    func clickRefusal(for id: String) -> String? { nil }
    func perform(_ action: ProfileHookAction, on id: String) {}
    func installAllMonitored() {}
    func activate() {}

    private static func row(_ alias: String, _ provider: Provider, _ folder: String, _ word: String, detail: String? = nil,
                            amber: Bool = false, action: ProfileHookAction?, refusal: String? = nil, events: String) -> HookSetupRow {
        HookSetupRow(id: Account.id(provider: provider, folder: folder), provider: provider, alias: alias, folder: folder, word: word,
                     detail: detail, tone: amber ? .amber : .normal, action: action, refusal: refusal, busy: false, events: events,
                     isMonitored: true)
    }

    static let fixture: [HookSetupRow] = [
        row("Main", .claude, "~/.claude", "Installed", action: .remove, events: "14/14"),
        row("Work", .claude, "~/.claude-work", "Installed", action: .remove, events: "14/14"),
        row("Research", .claude, "~/.claude-research", "Installed", action: .remove, events: "14/14"),
        row("Lab", .claude, "~/.claude-lab", "Partial 12/14", detail: "Missing Notification, PreCompact", amber: true,
            action: .repair, events: "12/14"),
        row("Studio", .claude, "~/.claude-studio", "Installed", action: .remove, events: "14/14"),
        row("Alt", .claude, "~/.claude-alt", "Not installed", action: .install, events: "0/14"),
        row("Home", .codex, "~/.codex", "Installed", action: .remove, events: "4/4"),
        row("Team", .codex, "~/.codex-team", "Needs /hooks", detail: HookRowText.trustHint, amber: true, action: .remove, events: "4/4"),
        row("Night", .codex, "~/.codex-night", "Has comments", amber: true, action: nil,
            refusal: HookRowText.refusal(.hasComments(file: "hooks.json")), events: "0/4"),
        row("Spare", .codex, "~/.codex-spare", "Installed", action: .remove, events: "4/4"),
        row("Edge", .codex, "~/.codex-edge", "Not installed", action: .install, events: "0/4"),
    ]
}
