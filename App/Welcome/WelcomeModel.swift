import AppKit
import Foundation
import IslandEngine
import IslandHookNotes
import JuiceCore
import Observation

/// What the welcome does outside itself: every file it writes goes through the agents' own models on a click, and
/// every app, terminal, pasteboard and sound through here, so tests and renders use a fake that only records (P950 to
/// P974).
@MainActor
protocol WelcomeServices: AnyObject {
    /// Open Island runs now (it has its own helper and socket since P900: two islands would show).
    var openIslandRunning: Bool { get }
    /// A screen of this Mac has a notch: Pick a look starts on Island.
    var hasNotch: Bool { get }
    /// The terminal Start opens: the one running, else the one installed (`FreshSessionLaunch.usualHost`).
    var terminalName: String { get }
    /// Vibe Island's entries in the agents' configs. Reads only, off the main actor.
    func findVibeIsland() async -> [VibeIslandHooks.Found]
    /// Switch to Juice's click: Vibe Island is asked to quit, then its entries come out, each file backed up first.
    func switchFromVibeIsland(_ found: [VibeIslandHooks.Found]) async -> [URL: VibeIslandHooks.Outcome]
    /// Quit Open Island's click: it is asked to quit, as its own Quit would.
    func askOpenIslandToQuit()
    /// Start's click: a new window in the usual terminal, in `folder` (the home folder when nil or gone), typing
    /// `command`; true when it opened.
    func start(command: String, folder: String?) async -> Bool
    func copy(_ text: String)
    /// The short sound of a turn done (muted with Sound's Mute).
    func chime()
}

/// The first run (P950 to P974): four screens in one small window, with the real island answering at the top of the
/// screen on every step. Hello plays a short demo on the island; Agents lists what this Mac has, ticked, and its Connect
/// is the only click that writes anything; Pick a look chooses Island or Window, a glyph style and Launch at Login
/// (registered only as the owner leaves that screen); First session opens the usual terminal on the first connected
/// agent's command, and the window closes itself once that session reaches the island. Return always moves on.
@MainActor
@Observable
final class WelcomeModel {
    enum Step: Int, CaseIterable, Comparable, Sendable {
        case hello, agents, look, start

        static func < (lhs: Step, rhs: Step) -> Bool { lhs.rawValue < rhs.rawValue }
        var next: Step? { Step(rawValue: rawValue + 1) }
    }

    /// How the welcome ended.
    enum Outcome: Equatable, Sendable { case closed, later, firstSession }
    enum VibeChoice: Equatable, Sendable { case undecided, switching, switched, kept }
    enum OpenIslandChoice: Equatable, Sendable { case undecided, quitAsked, kept }
    enum StartState: Equatable, Sendable { case idle, opening, opened, failed }

    @ObservationIgnored let env: AppEnvironment
    @ObservationIgnored let services: any WelcomeServices
    private(set) var step: Step
    /// Ticks by line id (an agent's, or a Claude or Codex folder's); a line not here is ticked.
    var ticks: [String: Bool] = [:]
    /// Connect was clicked: the button says Next from then on.
    var connectClicked = false
    /// The "i" beside Connect's line: the exact files it writes.
    var showsFiles = false
    /// Vibe Island's entries found on this Mac (read at the Agents screen).
    var vibe: [VibeIslandHooks.Found] = []
    private(set) var vibeChoice: VibeChoice = .undecided
    private(set) var vibeOutcomes: [URL: VibeIslandHooks.Outcome] = [:]
    private(set) var openIsland: OpenIslandChoice = .undecided
    /// Pick a look: on a first run Island on a Mac with a notch, Window on one without; from Show welcome, the owner's
    /// Show as (P973).
    var surface: ShowAs
    /// A screen of this Mac has a notch: Hello says the island is in it.
    @ObservationIgnored let hasNotch: Bool
    /// Pick a look's Launch at Login: on a first run shown on, registered only as the owner leaves the screen (P962); from
    /// Show welcome, what macOS says of the item now, so walking through changes nothing (P973).
    var launchAtLogin: Bool
    /// The row shows only where macOS can register this app (the installed release build); renders say so themselves.
    var showsLaunchAtLogin: Bool
    private(set) var startState: StartState = .idle
    private(set) var finished = false
    /// The window moves: rows drop in, the icon tips. Off in renders and tests, which draw each screen at rest.
    @ObservationIgnored var animates = false
    /// Hello's demo on the island, while Hello shows (the shell makes it, `WelcomeWindowController`).
    var hello: HelloDemo?
    var helloPhase: HelloDemo.Phase { hello?.phase ?? .idle }
    /// The sessions there as First session began: a session not among them is the first real one (P961).
    @ObservationIgnored private(set) var sessionsAtStart: Set<String> = []
    /// The shell's: the window closes and the chosen look applies.
    @ObservationIgnored var onFinish: @MainActor (Outcome) -> Void = { _ in }
    /// The shell's: a step began (Hello plays its demo on the island; any other step stops it).
    @ObservationIgnored var onStep: @MainActor (Step) -> Void = { _ in }

    /// `firstRun`: the welcome showed by itself (`WelcomeGate`); else it is Show welcome's, on a Mac where the app ran.
    init(env: AppEnvironment, services: any WelcomeServices, step: Step = .hello, firstRun: Bool = false) {
        self.env = env
        self.services = services
        self.step = step
        hasNotch = services.hasNotch
        if firstRun {
            surface = hasNotch ? .island : .window
            launchAtLogin = true
        } else {
            surface = env.settings.showAs
            env.launchAtLogin?.refresh()
            launchAtLogin = env.launchAtLogin.map { $0.isAvailable ? $0.isOn : env.settings.launchAtLogin } ?? env.settings.launchAtLogin
        }
        showsLaunchAtLogin = env.launchAtLogin?.isAvailable ?? false
    }

    // MARK: Steps

    /// The main button, and Return: Hello and Pick a look move on; Agents connects first while something ticked waits,
    /// then moves on; First session starts the agent, or ends the welcome when there is none.
    func primary() {
        switch step {
        case .hello, .look: advance()
        case .agents:
            if connects { connect() } else { advance() }
        case .start:
            if firstAgent != nil, startState == .idle || startState == .failed { start() } else { finish(.later) }
        }
    }

    /// The next screen. Leaving Pick a look stores the look and registers Launch at Login as chosen (P962).
    func advance() {
        guard let next = step.next else { return finish(.later) }
        if step == .look { leaveLook() }
        go(to: next)
    }

    func go(to next: Step) {
        guard !finished else { return }
        step = next
        if next == .agents { readAgents() }
        if next == .start { sessionsAtStart = Set(env.sessions.rows.map(\.id)) }
        onStep(next)
    }

    /// The agents are found and read again, and Vibe Island's entries looked for. Nothing is written.
    func readAgents() {
        env.agents.refresh()
        let services = services
        Task { [weak self] in
            let found = await services.findVibeIsland()
            self?.vibe = found
        }
    }

    private func leaveLook() {
        env.settings.showAs = surface
        // Only where the row showed is anything chosen (P973).
        env.launchAtLogin?.chooseAtWelcome(launchAtLogin)
    }

    /// Ends the welcome: the look applies (when Pick a look was left), the window closes.
    func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        env.settings.welcomeSeen = true
        onFinish(outcome)
    }

    // MARK: Agents

    /// What one line on the Agents screen shows.
    enum LineState: Equatable, Sendable {
        /// Connect would write it: ticked or not.
        case tick(Bool)
        case connected
        /// A click on it runs.
        case working
        /// Codex runs new hooks only once trusted: Copy /hooks.
        case trust
        /// A file Juice will not edit: Copy snippet. `replacesHooks`: the lines take the place of the file's `"hooks"` (P938).
        case addByHand(file: String, snippet: String, replacesHooks: Bool = false)
        /// Vibe Island's hooks are in its file: Switch to Juice takes them out.
        case vibe
        /// The owner kept Vibe Island: left as it is.
        case kept
        /// Any other state, in its row's own word ("Start it once first").
        case word(String)
    }

    /// One line on the Agents screen: an agent, or one of Claude's or Codex's folders under it.
    struct Line: Identifiable, Equatable, Sendable {
        enum Kind: Equatable, Sendable { case agent, profile, parent }
        var id: String
        var kind: Kind
        var name: String
        /// A folder's `~/.claude-work`.
        var detail: String?
        var look: AgentLook?
        var reach: AgentReach?
        var state: LineState
        /// A Claude or Codex line over its folders: "2 folders".
        var note: String?
        /// The part of an Approve agent that is Watch, under its name (Qoder's IDE, P1190).
        var reachNote: String?
    }

    /// The agents found on this Mac, as Settings › Agents lists them.
    var rows: [AgentRow] { env.agents.rows }

    /// Every line, in order. Claude and Codex with one folder are one line; with more, a line each under theirs.
    var lines: [Line] {
        var lines: [Line] = []
        for row in rows {
            if row.profiles.isEmpty {
                lines.append(Line(id: row.id, kind: .agent, name: row.name, look: row.look, reach: row.reach, state: state(of: row),
                                  reachNote: row.reachNote))
            } else if row.profiles.count == 1, let only = row.profiles.first {
                lines.append(Line(id: only.id, kind: .profile, name: row.name, look: row.look, reach: row.reach, state: state(of: only)))
            } else {
                let profiles = row.profiles.map { profile in
                    Line(id: profile.id, kind: .profile, name: profile.alias, detail: profile.folder, state: state(of: profile))
                }
                // Its tick ticks every folder that Connect could write; it is on while all of them are.
                let ticks = profiles.compactMap { line -> Bool? in if case let .tick(on) = line.state { on } else { nil } }
                let state: LineState = if !ticks.isEmpty { .tick(ticks.allSatisfy { $0 }) }
                    else if profiles.allSatisfy({ $0.state == .connected }) { .connected } else { .word("") }
                lines.append(Line(id: row.id, kind: .parent, name: row.name, look: row.look, reach: row.reach, state: state,
                                  note: WelcomeText.folders(profiles.count)))
                lines += profiles
            }
        }
        return lines
    }

    /// The files Switch to Juice left with Vibe Island's lines still in them (a link, comments, a write that failed), by
    /// the line that shows each (a Claude or Codex folder's, else the agent's), with what to take out by hand (P974).
    var vibeLeft: [String: String] {
        var left: [String: String] = [:]
        for item in vibe {
            guard case let .left(why)? = vibeOutcomes[item.place.url] else { continue }
            left[lineID(of: item.place)] = WelcomeText.vibeLeft(why, plugin: item.place.layout == .plugin)
        }
        return left
    }

    /// How many files still hold Vibe Island's lines after the switch.
    var vibeFilesLeft: Int {
        vibeOutcomes.values.filter { if case .left = $0 { true } else { false } }.count
    }

    /// The line a Vibe Island file shows on: the Claude or Codex folder it sits in (by the folder's name, as every
    /// folder found is one in the home folder), else its agent's.
    private func lineID(of place: VibeIslandHooks.Place) -> String {
        guard place.layout != .plugin, let row = rows.first(where: { $0.id == place.agentID }), !row.profiles.isEmpty else { return place.agentID }
        let folder = place.url.deletingLastPathComponent().lastPathComponent
        return row.profiles.first { ($0.folder as NSString).lastPathComponent == folder }?.id ?? place.agentID
    }

    /// The agents Vibe Island is connected to, by Settings › Agents' ids.
    var vibeAgents: Set<String> { Set(VibeIslandHooks.agents(vibe)) }

    func state(of row: AgentRow) -> LineState {
        if row.busy { return .working }
        switch row.status {
        case .connected: return .connected
        case .needsCodexTrust: return .trust
        case let .addByHand(file, snippet, replaces): return .addByHand(file: file, snippet: snippet, replacesHooks: replaces)
        default: break
        }
        if vibeAgents.contains(row.id), vibeChoice != .switched { return vibeChoice == .kept ? .kept : .vibe }
        if row.actions.contains(.connect), row.canClick { return .tick(ticks[row.id] ?? true) }
        return .word(row.refusal ?? row.status.word)
    }

    func state(of profile: HookSetupRow) -> LineState {
        if profile.busy { return .working }
        switch profile.state {
        case .installed?, .oldHelper?: return .connected
        case .codexNeedsTrust?: return .trust
        case let .linkedConfig(file)?, let .hasComments(file)?:
            if let snippet = AgentSnippets.profile(profile.provider, file: file, helperPath: env.agents.helperPathForSnippets) {
                return .addByHand(file: file, snippet: snippet)
            }
        case .blockedByOtherIsland?:
            return vibeChoice == .kept ? .kept : .vibe
        default: break
        }
        if profile.action == .install, profile.canClick { return .tick(ticks[profile.id] ?? true) }
        // Vibe Island's hooks in a file that also has ours hold its Install up (P904).
        if profile.refusal != nil, vibeAgents.contains(profile.provider == .claude ? "claude" : "codex"), vibeChoice != .switched {
            return vibeChoice == .kept ? .kept : .vibe
        }
        return .word(profile.refusal ?? profile.word)
    }

    func toggle(_ id: String) {
        let lines = lines
        guard let line = lines.first(where: { $0.id == id }), case let .tick(on) = line.state else { return }
        guard line.kind == .parent, let row = rows.first(where: { $0.id == id }) else { return ticks[id] = !on }
        for profile in row.profiles {
            if case .tick = lines.first(where: { $0.id == profile.id })?.state { ticks[profile.id] = !on }
        }
    }

    /// What Connect would write now: the ticked folders, the ticked agents.
    var ticked: (profiles: [String], agents: [String]) {
        var profiles: [String] = [], agents: [String] = []
        for line in lines where line.state == .tick(true) {
            if line.kind == .profile { profiles.append(line.id) } else if line.kind == .agent { agents.append(line.id) }
        }
        return (profiles, agents)
    }

    /// Something is still being written.
    var connecting: Bool { lines.contains { $0.state == .working } }

    /// The main button is Connect: nothing written yet, and a line ticked.
    var connects: Bool {
        guard !connectClicked, !connecting else { return false }
        let ticked = ticked
        return !ticked.profiles.isEmpty || !ticked.agents.isEmpty
    }

    /// Connect's click, the only one on these screens that writes an agent's config: the ticked folders one after
    /// another (`HooksModel.run`, P945), then each ticked agent, every file backed up first.
    func connect() {
        let (profiles, agents) = ticked
        connectClicked = true
        if !profiles.isEmpty { env.hooks.run(.install, on: profiles) }
        for id in agents { env.agents.perform(.connect, on: id) }
    }

    /// The files Connect writes for the ticked lines, `~/…`, for the "i" (P953).
    var files: [String] {
        var files: [String] = []
        for row in rows {
            if row.profiles.isEmpty {
                guard ticked.agents.contains(row.id) else { continue }
                if row.id == AgentRowText.openCodeID {
                    files.append((row.place ?? "~/.config/opencode") + "/plugins/" + OpenCodePlugin.fileName)
                } else if let place = row.place {
                    files.append(place)
                }
            } else {
                for profile in row.profiles where ticked.profiles.contains(profile.id) {
                    files.append(profile.folder + "/" + (profile.provider == .claude ? "settings.json" : "hooks.json"))
                    if profile.provider == .codex { files.append(profile.folder + "/config.toml") }
                }
            }
        }
        if !files.isEmpty { files.append(WelcomeText.helperPlace(HookHome.current.helperURL.path)) }
        return files
    }

    // MARK: Other islands

    /// The Vibe Island card shows: its entries were found and no choice is made yet (or one runs).
    var showsVibeCard: Bool { !vibe.isEmpty && (vibeChoice == .undecided || vibeChoice == .switching) }

    /// Switch to Juice's click (the owner's decision B, P955): Vibe Island is asked to quit, each config backed up and
    /// only its entries taken out, then ours connected where ticked, for the agents it freed only (P974).
    func switchToJuice() {
        guard vibeChoice == .undecided else { return }
        vibeChoice = .switching
        let found = vibe, freed = vibeAgents, services = services, hooks = env.hooks
        Task { [weak self] in
            let outcomes = await services.switchFromVibeIsland(found)
            await hooks.readAgain()
            guard let self else { return }
            // The freed agents' files read again before Connect counts them, or a table agent's row would still say
            // Vibe Island's hooks are there and stay out of Connect.
            await self.env.agents.readAgain()
            self.vibeOutcomes = outcomes
            self.vibeChoice = .switched
            self.connect(only: freed)
        }
    }

    /// The switch's Connect: the ticked lines of the agents the card named. Any other ticked line waits for Connect, which
    /// still says so (P974).
    private func connect(only agents: Set<String>) {
        let (profiles, ids) = ticked
        let freed = Set(rows.filter { agents.contains($0.id) }.flatMap(\.profiles).map(\.id))
        let folders = profiles.filter(freed.contains)
        if !folders.isEmpty { env.hooks.run(.install, on: folders) }
        for id in ids where agents.contains(id) { env.agents.perform(.connect, on: id) }
    }

    func keepVibeIsland() {
        guard vibeChoice == .undecided else { return }
        vibeChoice = .kept
    }

    var showsOpenIslandCard: Bool { services.openIslandRunning && openIsland == .undecided }

    func quitOpenIsland() {
        openIsland = .quitAsked
        services.askOpenIslandToQuit()
    }

    func keepOpenIsland() { openIsland = .kept }

    // MARK: First session

    /// The first connected agent (Claude, Codex, OpenCode, then the table's), else the first found; nil with none.
    var firstAgent: AgentRow? {
        rows.first { row in
            if AgentRowText.isConnected(row.status) { return true }
            if case .partly = row.status { return true }
            return false
        } ?? rows.first
    }

    /// The command Start types for `row`.
    static func command(for row: AgentRow) -> String {
        switch row.id {
        case "claude": "claude"
        case "codex": "codex"
        case AgentRowText.openCodeID: "opencode"
        default: AgentKind(rawValue: row.id).flatMap(AgentHookTable.spec)?.executables.first ?? row.id
        }
    }

    func start() {
        guard let agent = firstAgent else { return }
        startState = .opening
        sessionsAtStart = Set(env.sessions.rows.map(\.id))
        let command = Self.command(for: agent), folder = startFolder, services = services
        Task { [weak self] in
            let opened = await services.start(command: command, folder: folder)
            self?.startState = opened ? .opened : .failed
        }
    }

    /// Where Start opens the agent: the latest session's folder on this Mac (never an SSH host's), so it starts in a
    /// project and not in the home folder, which Claude Code warns about; nil with none (P960).
    var startFolder: String? {
        env.sessions.rows.filter { $0.remoteHost == nil && !($0.folder ?? "").isEmpty }.max { $0.updatedAt < $1.updatedAt }?.folder
    }

    func copyCommand() {
        guard let agent = firstAgent else { return }
        services.copy(Self.command(for: agent))
    }

    /// The island's sessions changed: on First session, a session that was not there as it began is the first real
    /// one, and the welcome ends with a chime (P961).
    func sessionsChanged(_ ids: [String]) {
        guard step == .start, !finished, ids.contains(where: { !sessionsAtStart.contains($0) }) else { return }
        services.chime()
        finish(.firstSession)
    }
}

/// The welcome's words, as pure functions (unit-tested): one line of text a screen, one main button.
enum WelcomeText {
    static let connect = "Connect"

    /// `notch`: a screen of this Mac has one; without, the island sits at the top of the screen.
    static func headline(_ step: WelcomeModel.Step, notch: Bool = true) -> String {
        switch step {
        case .hello: notch ? "Your agents, in the notch." : "Your agents, at the top of the screen."
        case .agents: "Connect your agents."
        case .look: "Pick a look."
        case .start: "Start a session."
        }
    }

    /// Hello's small line under the headline: what the island above asks for, then what happened.
    static func helloHint(answered: Bool) -> String { answered ? "That's all it takes." : "Answer it up there." }

    @MainActor static func agentsButton(_ model: WelcomeModel) -> String {
        guard model.connects else { return "Next" }
        let ticked = model.ticked
        return connectCount(ticked.profiles.count + ticked.agents.count)
    }

    /// Connect with the number of lines it writes, so a ticked line below the fold counts on the button too (P1186);
    /// plain Connect for one, Next for none.
    static func connectCount(_ lines: Int) -> String {
        switch lines {
        case 0: "Next"
        case 1: connect
        default: "\(connect) \(lines)"
        }
    }

    /// Over the bottom of a list that goes on below what shows (P1186).
    static func moreBelow(_ lines: Int) -> String { "\(lines) more below" }

    /// The line under the list: what Connect does, before and after.
    static func connectLine(clicked: Bool, nothingFound: Bool) -> String {
        if nothingFound { return "No agents found yet. Settings › Agents finds them later." }
        return clicked ? "Each file was backed up before it changed." : "Only Connect changes files, each backed up first."
    }

    static func folders(_ count: Int) -> String { "\(count) folders" }
    static let trust = "Codex asks once: trust the hooks."
    static let vibeStillThere = "Vibe Island's"
    static let kept = "Kept with Vibe Island"

    static func vibeCard(agents: Int) -> String { "Vibe Island is connected to \(agents) agent\(agents == 1 ? "" : "s")." }
    static let vibeSwitched = "Vibe Island restores its hooks when it opens. Use its own uninstall to remove it fully."

    /// The line under the card after the switch: done, or how many files still hold Vibe Island's lines (P974).
    static func vibeSwitched(left: Int) -> String {
        guard left > 0 else { return vibeSwitched }
        let files = left == 1 ? "1 file still holds" : "\(left) files still hold"
        return "\(files) Vibe Island's lines. Vibe Island also restores its hooks when it opens: use its own uninstall to remove it fully."
    }

    /// A file the switch left: why, unless the line's Add by hand says it, and what to take out by hand (P974).
    static func vibeLeft(_ why: String, plugin: Bool = false) -> String {
        let lead = why == "Add by hand" ? "" : why + ". "
        return lead + (plugin ? "Vibe Island's plugin is still there: delete vibe-island.js."
            : "Vibe Island's lines are still in it: take out those naming vibe-island-bridge.")
    }
    static let openIslandCard = "Open Island is running. Two islands would show."

    static func start(_ agent: AgentRow?) -> String { agent.map { "Start \($0.name)" } ?? "Done" }
    static func automation(terminal: String) -> String { "macOS will ask to let \(Product.name) use \(terminal) first." }
    static func waiting(_ agent: AgentRow?) -> String { "Waiting for \(agent?.name ?? "the session")…" }
    static func failed(terminal: String) -> String { "\(terminal) did not open. Copy the command instead." }
    static let noAgent = "Install an agent, then connect it in Settings › Agents."

    /// The helper's place, `~/…` when under the home folder.
    static func helperPlace(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
