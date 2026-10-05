import Foundation

/// Approve: the island can answer the agent's prompts. Watch: the island shows the agent's sessions and jumps there,
/// and its prompts are answered where they show (P935).
enum AgentReach: String, Equatable, Sendable {
    case approve, watch

    var title: String { self == .approve ? "Approve" : "Watch" }

    /// The tag's tooltip: what the word promises.
    var help: String {
        self == .approve ? "Answer its prompts from the island" : "See its sessions and jump to them; answer its prompts there"
    }
}

/// The one state an agent's row shows, with what it needs (P936).
enum AgentRowStatus: Equatable, Sendable {
    /// Not read yet.
    case checking
    case connected
    case notConnected
    /// Claude's and Codex's own rows: some of their folders are connected.
    case partly(connected: Int, of: Int)
    /// Codex runs a new hook only once the owner trusts it in `/hooks`.
    case needsCodexTrust
    /// The hooks still call Open Island's helper; one Move click points them at Juice's own.
    case moveToJuiceHelper
    /// A file Juice will not edit (a link, comments, a format it cannot write back as it was): the exact lines to paste.
    /// `replacesHooks`: the file has `"hooks"` already, and the lines are that member as Connect would leave it (P938).
    case addByHand(file: String, snippet: String, replacesHooks: Bool = false)
    /// Any other state that needs a look ("Partial 12/14", "Broken", "Hooks off").
    case attention(word: String, detail: String?)

    var word: String {
        switch self {
        case .checking: "…"
        case .connected: "Connected"
        case .notConnected: "Not connected"
        case let .partly(connected, total): "\(connected) of \(total) connected"
        case .needsCodexTrust: "Needs Codex trust"
        case .moveToJuiceHelper: "Move to \(Product.name)'s helper"
        case .addByHand: "Add by hand"
        case let .attention(word, _): word
        }
    }

    /// The second line: why, in one line; nil where the word says it all.
    var detail: String? {
        switch self {
        case .needsCodexTrust: AgentRowText.codexTrustWhy
        case .moveToJuiceHelper: AgentRowText.moveWhy
        case let .addByHand(file, snippet, replaces):
            // A snippet that is a whole file (Factory Droid's `hooks.json`, P1126) takes the file's place.
            !replaces ? "Paste it into \(file)." : snippet.hasPrefix("{") ? "Put it in place of everything in \(file)."
                : "Put it in place of \"hooks\" in \(file)."
        case let .attention(_, detail): detail
        default: nil
        }
    }

    /// Amber: something waits on the owner.
    var isAmber: Bool {
        switch self {
        case .checking, .connected, .notConnected, .partly: false
        default: true
        }
    }

    /// The text a Copy button puts on the clipboard, with the button's title; nil without one.
    var copy: (title: String, text: String)? {
        switch self {
        case .needsCodexTrust: ("Copy /hooks", "/hooks")
        case let .addByHand(_, snippet, _): ("Copy snippet", snippet)
        default: nil
        }
    }
}

/// A row's button. Only a click calls one, and only through `AgentsModel.perform`.
enum AgentRowAction: String, Equatable, Sendable {
    case connect, repair, move, update, remove

    var title: String {
        switch self {
        case .connect: "Connect"
        case .repair: "Repair"
        case .move: "Move"
        case .update: "Update"
        case .remove: "Remove"
        }
    }
}

/// One agent in Settings › Agents (P935 to P939): found on this Mac, its mark, whether the island can answer it, its
/// state and its buttons. Claude and Codex carry their profile folders, each a row of its own.
struct AgentRow: Identifiable, Equatable, Sendable {
    /// Stable: "claude", "codex", "opencode", then the agents table's own keys.
    var id: String
    /// Plain: "Claude Code", "Codex", "OpenCode", "Copilot CLI".
    var name: String
    var look: AgentLook
    var reach: AgentReach
    /// Where it is set up, `~/…` only ("~/.cursor/hooks.json"); nil for Claude and Codex, whose folders say it.
    var place: String?
    var status: AgentRowStatus
    /// In order; Remove is drawn quiet. Empty: no button.
    var actions: [AgentRowAction]
    /// Why no button works now, a few words ("Start it once first").
    var refusal: String?
    var busy: Bool = false
    /// Claude and Codex: one row per profile folder. Empty for every other agent.
    var profiles: [HookSetupRow] = []
    /// The part of an Approve agent that is Watch ("Qoder CLI; the Qoder IDE is Watch"), under its name (P1190).
    var reachNote: String? = nil

    /// Its buttons can be clicked now.
    var canClick: Bool { refusal == nil && !busy }
}

/// Every agent besides Claude, Codex and OpenCode reaches the pane through one of these: the engine's agents table.
/// Reading and detection only, except `perform`, which only a click calls.
@MainActor
protocol AgentRowSource: AnyObject {
    /// Found agents only, in the table's order.
    var rows: [AgentRow] { get }
    /// The table's agents not found on this Mac, by name, for the pane's one quiet line.
    var notFound: [String] { get }
    /// Connect, Repair, Move, Update or Remove, on the owner's click only; the file is backed up before it is written.
    func perform(_ action: AgentRowAction, on id: String)
    /// The pane appeared: find and read again, off the main actor; nothing is written.
    func refresh()
    /// Find and read again, and return once the rows show it: before a click that depends on them (the welcome's
    /// Switch to Juice connects the agents it freed, P955). Reads only.
    func readAgain() async
}

extension AgentRowSource {
    func readAgain() async { refresh() }
}
