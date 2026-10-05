import Foundation
import IslandEngine
import IslandHookNotes
import Observation

/// The agents table in Settings › Agents (P915 to P934): one row per table agent found on this Mac, its Approve or
/// Watch tag, its file's state and the buttons that state offers. Finding and reading run off the main actor and write
/// nothing; Connect, Repair, Move, Update and Remove run only on a click, one at a time per agent, through
/// `AgentHookInstaller` (a backup first, Juice's own entries only).
@MainActor
@Observable
final class TableAgents: AgentRowSource {
    private(set) var states: [AgentKind: AgentHookState] = [:]
    private(set) var found: Set<AgentKind> = []
    /// Agents a click sent to the installer, until it is done.
    private(set) var busy: Set<AgentKind> = []
    /// Why the last click on an agent was refused or failed, in a few words.
    private(set) var refusals: [AgentKind: String] = [:]
    /// Detection has run once: until then no agent is "not found".
    private(set) var checked = false

    @ObservationIgnored let installer: AgentHookInstaller
    @ObservationIgnored let specs: [AgentHookSpec]
    /// Where commands are looked for (`AgentDetector.searchDirectories`), asked off the main actor.
    @ObservationIgnored let directories: @Sendable () -> [String]

    init(installer: AgentHookInstaller, specs: [AgentHookSpec] = AgentHookTable.wave1,
         directories: @escaping @Sendable () -> [String]) {
        self.installer = installer
        self.specs = specs
        self.directories = directories
    }

    /// The app's: this Mac's home, the app's helper home, the login shell's PATH and the usual install places.
    static func app() -> TableAgents {
        TableAgents(installer: .app(bundledHelper: HelperSync.bundledHelperURL()), directories: { AgentDetector.appDirectories() })
    }

    // MARK: AgentRowSource

    var rows: [AgentRow] {
        specs.filter { found.contains($0.kind) }.map(row)
    }

    var notFound: [String] {
        checked ? specs.filter { !found.contains($0.kind) }.map(\.name) : []
    }

    func row(_ spec: AgentHookSpec) -> AgentRow {
        let place = installer.shownPath(spec)
        let (status, actions) = states[spec.kind].map { AgentRowText.table($0, spec: spec, place: place) } ?? (.checking, [])
        // The place the agent reads now names the row: Kimi CLI where only its older folder is there (P1132).
        let name = found.contains(spec.kind) ? installer.resolved(spec).name : spec.name
        return AgentRow(id: spec.kind.rawValue, name: name, look: AgentLook.of(EngineSessionsModel.agent(spec.kind)),
                        reach: spec.answers == .approve ? .approve : .watch, place: place, status: status, actions: actions,
                        refusal: refusals[spec.kind], busy: busy.contains(spec.kind), reachNote: spec.reachNote)
    }

    func perform(_ action: AgentRowAction, on id: String) {
        guard let spec = specs.first(where: { $0.kind.rawValue == id }), !busy.contains(spec.kind) else { return }
        busy.insert(spec.kind)
        refusals[spec.kind] = nil
        let installer = installer
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> (String?, AgentHookState) in
                var refusal: String?
                do {
                    if action == .remove { try installer.remove(spec) } else { try installer.install(spec) }
                } catch let failure as AgentHookInstaller.Failure {
                    refusal = Self.refusal(failure)
                } catch {
                    refusal = "Couldn't write the hooks"
                }
                return (refusal, installer.status(spec))
            }.value
            refusals[spec.kind] = outcome.0
            states[spec.kind] = outcome.1
            busy.remove(spec.kind)
        }
    }

    func refresh() {
        Task { await readAgain() }
    }

    func readAgain() async {
        let specs = specs, installer = installer, directories = directories
        let read = await Task.detached(priority: .utility) { () -> (Set<AgentKind>, [AgentKind: AgentHookState]) in
            let home = installer.home.path, search = directories()
            var found: Set<AgentKind> = []
            var states: [AgentKind: AgentHookState] = [:]
            for spec in specs {
                // Every folder the agent reads hooks from says it is here (Kimi Code's and the older Kimi CLI's, P1132),
                // or the folders that name it when its own would say another agent too (Antigravity CLI, P1100).
                var seen: Set<String> = []
                let folders = installer.places(spec).flatMap(\.footprintFolders).map { "~/" + $0 }.filter { seen.insert($0).inserted }
                let footprint = AgentFootprint(executables: spec.executables, folders: folders, namesakes: spec.namesakeFormulae)
                guard AgentDetector.isPresent(footprint, home: home, directories: search) else { continue }
                found.insert(spec.kind)
                states[spec.kind] = installer.status(spec)
            }
            return (found, states)
        }.value
        found = read.0
        for (kind, state) in read.1 where !busy.contains(kind) { states[kind] = state }
        checked = true
    }

    /// A refused or failed click, in a few words (as Setup's refusals read).
    nonisolated static func refusal(_ failure: AgentHookInstaller.Failure) -> String {
        switch failure {
        case .folderMissing: "Start it once first"
        case .vibeIsland: AgentRowText.vibeWhy
        case .addByHand: "Add it by hand"
        case .unreadable: "Can't read its file"
        case .foreign: "Another file is there"
        case .helper(.bundledHelperMissing): "No helper in this build"
        case .helper: "Couldn't copy the helper"
        case .writeFailed: "Couldn't write the hooks"
        }
    }
}
