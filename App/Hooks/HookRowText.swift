import Foundation
import IslandEngine
import JuiceCore
import OpenIslandCore

/// Setup's words, as pure functions of the engine's status (unit-tested): a word or two per state, a few words per
/// refusal, never a path beyond the row's own `~/…` folder.
enum HookRowText {
    static let trustHint = "Run /hooks once in Codex here"

    static func title(for action: ProfileHookAction) -> String {
        switch action {
        case .install: "Install"
        case .repair: "Repair"
        case .remove: "Remove"
        }
    }

    /// The state word (spec §3.5's states).
    static func word(for state: ProfileHookStatus.State) -> String {
        switch state {
        case .installed: "Installed"
        case .notInstalled: "Not installed"
        case let .partial(installed, expected): "Partial \(installed)/\(expected)"
        case .codexFeatureOff: "Hooks off"
        case .codexNeedsTrust: "Needs /hooks"
        case .blockedByOtherIsland: "Vibe Island hooks"
        case .broken: "Broken"
        case .linkedConfig: "Linked file"
        case .hasComments: "Has comments"
        case .unreadable: "Unreadable"
        case .folderMissing: "Folder missing"
        }
    }

    static func isProblem(_ state: ProfileHookStatus.State) -> Bool {
        switch state {
        case .installed, .notInstalled: false
        default: true
        }
    }

    /// The second line: what is missing, what to run, or what is broken. The refusal line covers the rest.
    static func detail(for state: ProfileHookStatus.State, missing: [HookEntrySpec]) -> String? {
        switch state {
        case .partial:
            guard !missing.isEmpty else { return nil }
            var seen: Set<String> = []
            return "Missing " + missing.map(\.event).filter { seen.insert($0).inserted }.joined(separator: ", ")
        case .codexNeedsTrust: return trustHint
        case .codexFeatureOff: return "Codex hooks are off in config.toml"
        case let .broken(issues): return issues.first.map(issue)
        default: return nil
        }
    }

    static func issue(_ issue: HookHealthReport.Issue) -> String {
        switch issue {
        case .binaryNotFound: "Helper missing"
        case .binaryNotExecutable: "Helper can't run"
        case .configMalformedJSON: "Config isn't valid JSON"
        case .staleCommandPath: "Hooks point to a missing helper"
        case .otherHooksDetected: "Other hooks too"
        case .manifestMissing: "Manifest missing"
        case .pluginMissing: "Plugin missing"
        }
    }

    /// A few words, shown beside the unavailable button.
    static func refusal(_ refusal: ProfileHookRefusal) -> String {
        switch refusal {
        case .openIslandRunning: "Quit Open Island first"
        case .folderMissing: "Folder missing"
        case let .linkedConfig(file), let .hasComments(file): "Edit \(file) by hand"
        case let .unreadable(file): "Can't read \(file)"
        case .otherIslandHooks: "Remove Vibe Island first"
        case .helperMissing: "No helper in this build"
        case .writeFailed: "Couldn't write the hooks"
        }
    }

    /// `/Users/me/.claude-work` → `~/.claude-work`.
    static func folder(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = ProfileHookTargets.normalized(home)
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// One row from the engine's reading of the profile. `status` nil: not read yet.
    static func row(target: ProfileHookTarget, status: ProfileHookStatus?, setupState: ProfileHookStatus.State?,
                    choice: ProfileHookChoice?, missing: [HookEntrySpec], busy: Bool, clickRefusal: ProfileHookRefusal?,
                    home: String = NSHomeDirectory()) -> HookSetupRow {
        let expected = ExpectedHookEntries.entries(for: target.provider).count
        guard let status, let state = setupState else {
            return HookSetupRow(id: target.id, provider: target.provider, alias: target.alias, folder: folder(target.folder, home: home),
                                word: "…", detail: nil, tone: .normal, action: nil, refusal: nil, busy: busy,
                                events: "–/\(expected)", isMonitored: target.isMonitored)
        }
        let installed: Int = if case let .partial(count, _) = state { count } else { status.managedEventCount }
        let refusal = (choice?.refusal).map(Self.refusal) ?? clickRefusal.map(Self.refusal)
        return HookSetupRow(id: target.id, provider: target.provider, alias: target.alias, folder: folder(target.folder, home: home),
                            word: word(for: state), detail: detail(for: state, missing: missing),
                            tone: isProblem(state) ? .amber : .normal, action: choice?.action, refusal: refusal,
                            busy: busy, events: "\(installed)/\(status.expectedEventCount)", isMonitored: target.isMonitored)
    }

    /// Diagnostics' footnote: the helper, Open Island and Vibe Island, in one line. Open Island is left out when the
    /// pane says it runs already (`openIslandSaid`: the Bridge row's refusal).
    static func integrationsLine(_ integrations: HookIntegrations, openIslandSaid: Bool = false) -> String {
        [integrations.helperInBuild ? "Helper in this build" : "No helper in this build",
         openIslandSaid ? nil : integrations.openIslandRunning ? "Open Island running" : "Open Island not running",
         integrations.vibeProfiles == 0 ? "no Vibe Island hooks"
             : "Vibe Island hooks in \(integrations.vibeProfiles) profile\(integrations.vibeProfiles == 1 ? "" : "s")"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}
