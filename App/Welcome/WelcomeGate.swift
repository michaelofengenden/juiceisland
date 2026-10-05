import AppKit
import Foundation
import IslandEngine
import IslandHookNotes
import JuiceCore

/// Whether the welcome shows by itself (P950, P951): only on a Mac where this app never ran (no setting of ours, and not
/// the welcome's own mark) and no Juice hooks are installed, of this flavor or the other. So an owner who updates, or
/// who opens the public Juice beside the private app, never sees it uninvited; Settings › About › Show welcome opens
/// it on any Mac.
enum WelcomeGate {
    /// `juiceHooks` is asked only when there was no earlier launch.
    static func showsByItself(earlierLaunch: Bool, juiceHooks: @autoclosure () -> Bool) -> Bool { !earlierLaunch && !juiceHooks() }

    /// The launch's decision, as the shell makes it before any window: whether the welcome shows by itself. On a first
    /// run Launch at Login waits for its Pick a look (P962). The welcome's mark is set either way, so the next launch is
    /// never a first run, and the agents this build can connect that the last launch's could not are recorded (P966).
    @MainActor
    static func atLaunch(_ settings: AppSettings, juiceHooks: @autoclosure () -> Bool) -> Bool {
        let firstRun = showsByItself(earlierLaunch: settings.welcomeSeen || settings.hadEarlierLaunch, juiceHooks: juiceHooks())
        if firstRun { settings.loginItemAwaitsChoice = true }
        settings.welcomeSeen = true
        settings.newAgents = NewAgents.atLaunch(waiting: settings.newAgents, known: settings.agentsKnown, firstRun: firstRun)
        settings.agentsKnown = NewAgents.catalog
        return firstRun
    }

    /// Juice's hooks on this Mac: either flavor's helper installed in its home (Connect copies it there before any hook
    /// names it), or a Claude or Codex folder whose hook file names `JuiceHooks`. Reads names, and those small files only
    /// when no helper is there.
    static func juiceHooksPresent(home: String = NSHomeDirectory(), fileManager: FileManager = .default,
                                  publicFolder: String? = AppFlavor.current.isPublic ? AppFlavor.current.supportFolderName : nil) -> Bool {
        let folders = [AppFlavor.privateProductName, publicFolder].compactMap { $0 }
        for folder in folders where fileManager.fileExists(atPath: HookHome(supportFolderNamed: folder, home: home).helperURL.path) {
            return true
        }
        let profiles = Provider.allCases.map { home + "/" + $0.defaultFolderName }
            + ProfileFolderDiscovery.discover(home: home).map(\.folder)
        for folder in profiles {
            for file in ["settings.json", "hooks.json"] {
                let url = URL(fileURLWithPath: folder).appendingPathComponent(file)
                guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= 1 << 20,
                      let data = try? Data(contentsOf: url) else { continue }
                if String(decoding: data, as: UTF8.self).contains(HookHome.helperName) { return true }
            }
        }
        return false
    }
}

/// "2 new agents can connect" (P966): after an update whose build can connect agents the last one could not, the island
/// and the window name them once, with Connect, until it is clicked or closed. Only agents found on this Mac that are not
/// connected yet count. A first run names none: its Agents screen lists them all.
enum NewAgents {
    /// What builds before this record could connect: Claude Code, Codex and OpenCode.
    static let before = ["claude", "codex", AgentRowText.openCodeID]

    /// Every agent this build can connect, by Settings › Agents' ids.
    static var catalog: [String] { before + AgentHookTable.wave1.map(\.kind.rawValue) }

    /// The agents to name after this launch: those still waiting, and those this build added since the last launch's
    /// (`known`; nil before any build recorded it, which reads as `before`). None on a first run.
    static func atLaunch(waiting: [String], known: [String]?, catalog: [String] = catalog, firstRun: Bool) -> [String] {
        guard !firstRun else { return [] }
        let base = Set(known ?? before)
        var names = waiting
        for id in catalog where !base.contains(id) && !names.contains(id) { names.append(id) }
        return names
    }

    /// The rows the line names: found here, offering Connect now, among `ids`.
    static func shown(_ ids: [String], rows: [AgentRow]) -> [AgentRow] {
        rows.filter { ids.contains($0.id) && $0.profiles.isEmpty && $0.actions.contains(.connect) && $0.canClick }
    }

    static func line(_ count: Int) -> String { count == 1 ? "1 new agent can connect" : "\(count) new agents can connect" }
}
