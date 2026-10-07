import Foundation
import IslandEngine
import IslandHookNotes
import JuiceCore
import Observation
import OpenIslandCore

/// What Settings › Agents reads (P935 to P939). `AgentsPaneModel` in the app and in renders; nothing here writes except
/// `perform`, `performProfile` and `removeFromAll`, which only a click calls.
@MainActor
protocol AgentsModel: AnyObject {
    /// One row per agent found on this Mac: Claude Code, Codex, OpenCode, then each source's.
    var rows: [AgentRow] { get }
    /// Known agents not found here, by name: the pane's one quiet line.
    var notFound: [String] { get }
    /// Something is connected that Remove from all agents would take out.
    var canRemoveFromAll: Bool { get }
    /// The helper path Add by hand's lines name.
    var helperPathForSnippets: String { get }
    func perform(_ action: AgentRowAction, on id: String)
    /// A profile folder's own button under Claude or Codex.
    func performProfile(_ action: ProfileHookAction, on id: String)
    /// Takes Juice's hooks and plugin out of every agent and folder, one after another (backed up as each Remove is).
    func removeFromAll()
    /// The pane appeared: agents are found again and their files read again; nothing is written.
    func refresh()
    /// The table's agents found and read again, returning once their rows show it. Reads only.
    func readAgain() async
}

/// Settings › Agents over `HooksModel` (Claude's and Codex's folders, OpenCode's plugin) and the agents table's
/// sources. Claude and Codex are found by a folder Setup lists or by their command; OpenCode as its row says; every
/// other agent by its source.
@MainActor
@Observable
final class AgentsPaneModel: AgentsModel {
    /// The agents table's rows, set by the app; empty in renders.
    @ObservationIgnored var sources: [any AgentRowSource] = []
    /// Whether the app answers Codex now (Answer Codex in Juice, in either mode since P1050): Approve, else Watch (P947).
    @ObservationIgnored var answersCodex: @MainActor () -> Bool = { true }
    /// The managed helper's path, for Add by hand's lines: the app's own (`HookHome`, P900).
    @ObservationIgnored var helperPath: @MainActor () -> String = { HookHome.current.helperURL.path }
    /// Finds `claude` and `codex` on this Mac off the main actor; renders find none.
    @ObservationIgnored var findCommands: @Sendable () -> Set<String> = { [] }
    @ObservationIgnored private let hooks: @MainActor () -> any HooksModel
    /// The commands found at the last `refresh`.
    private(set) var commands: Set<String> = []

    init(hooks: @escaping @MainActor () -> any HooksModel) {
        self.hooks = hooks
    }

    /// The app's: `claude` and `codex` are looked up in the login shell's PATH and the usual install places (P937).
    func live() {
        findCommands = {
            let home = NSHomeDirectory(), directories = AgentDetector.appDirectories()
            return Set(["claude", "codex"].filter {
                AgentDetector.isPresent(AgentFootprint(executables: [$0], folders: []), home: home, directories: directories)
            })
        }
    }

    var helperPathForSnippets: String { helperPath() }

    var rows: [AgentRow] {
        let hooks = hooks()
        let helper = helperPath()
        var rows: [AgentRow] = []
        for provider in Provider.allCases {
            let profiles = hooks.rows.filter { $0.provider == provider }
            guard !profiles.isEmpty || commands.contains(provider.command) else { continue }
            rows.append(AgentRowText.parent(provider, profiles: profiles, helperPath: helper,
                                            reach: provider == .codex && !answersCodex() ? .watch : .approve))
        }
        if let openCode = hooks.openCodeRow { rows.append(AgentRowText.openCode(openCode)) }
        for source in sources { rows += source.rows }
        return rows
    }

    var notFound: [String] {
        let hooks = hooks()
        var names: [String] = []
        for provider in Provider.allCases where !hooks.rows.contains(where: { $0.provider == provider }) && !commands.contains(provider.command) {
            names.append(AgentRowText.name(provider))
        }
        if hooks.openCodeRow == nil { names.append("OpenCode") }
        for source in sources { names += source.notFound }
        return names
    }

    var canRemoveFromAll: Bool { !AgentRowText.removals(rows).isEmpty }

    func perform(_ action: AgentRowAction, on id: String) {
        let hooks = hooks()
        if let provider = Provider.allCases.first(where: { AgentRowText.id($0) == id }) {
            let profiles = hooks.rows.filter { $0.provider == provider }
            let (profileAction, ids) = AgentRowText.profileRun(action, profiles: profiles)
            if let profileAction, !ids.isEmpty { hooks.run(profileAction, on: ids) }
        } else if id == AgentRowText.openCodeID {
            if action == .remove { hooks.removeOpenCode() } else { hooks.performOpenCode() }
        } else if let source = sources.first(where: { $0.rows.contains { $0.id == id } }) {
            source.perform(action, on: id)
        }
    }

    func performProfile(_ action: ProfileHookAction, on id: String) { hooks().perform(action, on: id) }

    func removeFromAll() {
        let hooks = hooks()
        let removals = AgentRowText.removals(rows)
        if !removals.profiles.isEmpty { hooks.run(.remove, on: removals.profiles) }
        if removals.openCode { hooks.removeOpenCode() }
        for id in removals.others {
            sources.first { $0.rows.contains { $0.id == id } }?.perform(.remove, on: id)
        }
    }

    /// The agents table's agents only, found and read again (the launch's "new agents" line, P966): nothing is run, nothing
    /// written.
    func refreshSources() {
        for source in sources { source.refresh() }
    }

    func readAgain() async {
        for source in sources { await source.readAgain() }
    }

    func refresh() {
        hooks().refreshOpenCode()
        for source in sources { source.refresh() }
        let find = findCommands
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { find() }.value
            self?.commands = found
        }
    }
}

extension Provider {
    /// The agent's command.
    var command: String { self == .claude ? "claude" : "codex" }
}

/// Settings › Agents' words, as pure functions of the rows below it (unit-tested): a word or two per state, one line why
/// where the word needs it, the buttons a state offers.
enum AgentRowText {
    static let openCodeID = "opencode"
    static let codexTrustWhy = "Codex runs new hooks only after you trust them."
    static let moveWhy = "They still call Open Island's helper."
    static let vibeWhy = "Remove Vibe Island's hooks first"
    /// A table agent's state as its row says it (P936): words, the Copy, the buttons.
    static func table(_ state: AgentHookState, spec: AgentHookSpec, place: String) -> (AgentRowStatus, [AgentRowAction]) {
        switch state {
        case .notFound: (.attention(word: "Not set up", detail: "Start it once first"), [])
        case .notConnected: (.notConnected, [.connect])
        case .connected: (.connected, [.remove])
        // Put in by hand, in a file Juice will not edit: taken out by hand too.
        case .connectedByHand: (.connected, [])
        case let .partial(installed, expected): (.attention(word: "Partial \(installed)/\(expected)", detail: nil), [.repair, .remove])
        case let .vibeIsland(_, ours): (.attention(word: "Vibe Island hooks", detail: vibeWhy), ours > 0 ? [.remove] : [])
        case .outdated: (.attention(word: "Older than this build", detail: nil), [.update, .remove])
        case let .addByHand(file, snippet, replaces): (.addByHand(file: file, snippet: snippet, replacesHooks: replaces), [])
        case let .unreadable(file): (.attention(word: "Unreadable", detail: "Can't read \(file)"), [])
        }
    }

    static func id(_ provider: Provider) -> String { provider == .claude ? "claude" : "codex" }
    static func name(_ provider: Provider) -> String { provider == .claude ? "Claude Code" : "Codex" }

    /// A profile folder's state as Agents words it. A row from before the engine's state was carried falls back on its
    /// button: Remove means its hooks are in, Install that they are not.
    static func profileStatus(_ row: HookSetupRow, helperPath: String) -> AgentRowStatus {
        guard let state = row.state else {
            if row.word == "…" { return .checking }
            switch row.action {
            case .remove: return .connected
            case .install: return .notConnected
            default: return .attention(word: row.word, detail: row.detail)
            }
        }
        if row.movesToJuiceHelper { return .moveToJuiceHelper }
        switch state {
        case .installed: return .connected
        case .notInstalled: return .notConnected
        case .codexNeedsTrust: return .needsCodexTrust
        case let .linkedConfig(file), let .hasComments(file):
            guard let snippet = AgentSnippets.profile(row.provider, file: file, helperPath: helperPath) else {
                return .attention(word: row.word, detail: row.detail)
            }
            return .addByHand(file: file, snippet: snippet, replacesHooks: false)
        case .blockedByOtherIsland: return .attention(word: row.word, detail: vibeWhy)
        default: return .attention(word: row.word, detail: row.detail)
        }
    }

    /// A folder's button title: Connect for Install; Move for the Repair that points old hooks at Juice's helper.
    static func profileButton(_ row: HookSetupRow) -> String? {
        guard let action = row.action else { return nil }
        switch action {
        case .install: return "Connect"
        case .repair: return row.movesToJuiceHelper ? "Move" : "Repair"
        case .remove: return "Remove"
        }
    }

    /// A folder whose hooks are in: Connected, waiting on Codex's trust, or still calling Open Island's helper.
    static func isConnected(_ status: AgentRowStatus) -> Bool {
        switch status {
        case .connected, .needsCodexTrust, .moveToJuiceHelper: true
        default: false
        }
    }

    /// Claude's or Codex's own row over its folders: Move first, then Codex's trust, then how many are connected. It
    /// offers Connect while a folder could be connected now, Move while one needs moving, and Remove once every folder
    /// that can be is connected. A refusal every folder shares (Open Island running) is the row's.
    static func parent(_ provider: Provider, profiles: [HookSetupRow], helperPath: String, reach: AgentReach) -> AgentRow {
        let look = AgentLook.of(provider == .claude ? GlyphPalette.Agent.claude : .codex)
        guard !profiles.isEmpty else {
            return AgentRow(id: id(provider), name: name(provider), look: look, reach: reach, place: nil, status: .notConnected,
                            actions: [], refusal: "Start it once first")
        }
        let statuses = profiles.map { profileStatus($0, helperPath: helperPath) }
        let connected = statuses.filter(isConnected).count
        // A folder that is gone counts for nothing: it can be neither connected nor left out.
        let total = profiles.filter { $0.state != .folderMissing }.count
        let status: AgentRowStatus
        if statuses.contains(.checking) {
            status = .checking
        } else if statuses.contains(.moveToJuiceHelper) {
            status = .moveToJuiceHelper
        } else if statuses.contains(.needsCodexTrust) {
            status = .needsCodexTrust
        } else if connected == total, total > 0 {
            status = .connected
        } else if connected == 0 {
            status = .notConnected
        } else {
            status = .partly(connected: connected, of: total)
        }
        var actions: [AgentRowAction] = []
        if profiles.contains(where: { $0.action == .install && $0.canClick }) { actions.append(.connect) }
        if profiles.contains(where: { $0.movesToJuiceHelper && $0.action == .repair && $0.canClick }) { actions.append(.move) }
        if actions.isEmpty, connected > 0, profiles.contains(where: { $0.action == .remove && $0.canClick }) { actions.append(.remove) }
        let refusals = Set(profiles.compactMap(\.refusal))
        let shared = refusals.count == 1 && profiles.allSatisfy { $0.refusal != nil } ? refusals.first : nil
        return AgentRow(id: id(provider), name: name(provider), look: look, reach: reach, place: nil, status: status,
                        actions: shared == nil ? actions : [], refusal: shared, busy: profiles.contains(where: \.busy),
                        profiles: profiles)
    }

    /// The parent row's click as one action on its folders: Connect installs every folder that offers Install now (never
    /// a Repair, P20), Move repairs the folders that still call Open Island's helper, Remove takes ours out of every
    /// folder that offers Remove.
    static func profileRun(_ action: AgentRowAction, profiles: [HookSetupRow]) -> (ProfileHookAction?, [String]) {
        switch action {
        case .connect: (.install, profiles.filter { $0.action == .install && $0.canClick }.map(\.id))
        case .move: (.repair, profiles.filter { $0.movesToJuiceHelper && $0.action == .repair && $0.canClick }.map(\.id))
        case .remove: (.remove, profiles.filter { $0.action == .remove && $0.canClick }.map(\.id))
        case .repair, .update: (nil, [])
        }
    }

    /// OpenCode's row from Setup's (P480, P949): Juice's plugin in (this build's, older or newer: it works, and an older one
    /// offers Update), out, Open Island's (it calls Open Island's helper) or someone else's file.
    static func openCode(_ row: OpenCodeSetupRow) -> AgentRow {
        let status: AgentRowStatus = switch row.word {
        case OpenCodeWords.missing: .notConnected
        case OpenCodeWords.installed, OpenCodeWords.older, OpenCodeWords.newer: .connected
        default: .attention(word: row.word, detail: nil)
        }
        // Juice's own older plugin can be updated or taken out; Open Island's only replaced.
        let actions: [AgentRowAction] = switch row.action {
        case .install: [.connect]
        case .update: row.word == OpenCodeWords.older ? [.update, .remove] : [.update]
        case .remove: [.remove]
        case nil: []
        }
        let refusal = row.refusal == row.word ? nil : row.refusal
        return AgentRow(id: openCodeID, name: "OpenCode", look: AgentLook.of(GlyphPalette.Agent.other(.openCode)), reach: .approve,
                        place: row.folder, status: status, actions: refusal == nil ? actions : [], refusal: refusal, busy: row.busy)
    }

    /// What Remove from all agents takes out: every folder whose button is Remove (connected, Codex's trust waiting) or
    /// Move (Juice's older hooks, still on Open Island's helper, P932), OpenCode's plugin when it is Juice's, and every
    /// other agent that offers Remove.
    static func removals(_ rows: [AgentRow]) -> AgentRemovals {
        var removals = AgentRemovals()
        for row in rows {
            if !row.profiles.isEmpty {
                removals.profiles += row.profiles.filter { ($0.action == .remove || $0.movesToJuiceHelper) && $0.canClick }.map(\.id)
            } else if row.canClick, row.actions.contains(.remove) {
                if row.id == openCodeID { removals.openCode = true } else { removals.others.append(row.id) }
            }
        }
        return removals
    }
}

/// `OpenCodePluginChoice`'s words for Juice's own plugin.
enum OpenCodeWords {
    static let missing = "Not installed"
    static let installed = "Installed"
    static let older = "Older than this build"
    static let newer = "Newer than this build"
}

/// What Remove from all agents takes out.
struct AgentRemovals: Equatable, Sendable {
    var profiles: [String] = []
    var openCode = false
    var others: [String] = []

    var isEmpty: Bool { profiles.isEmpty && !openCode && others.isEmpty }
}
