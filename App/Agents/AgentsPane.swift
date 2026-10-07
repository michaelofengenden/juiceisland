import AppKit
import IslandEngine
import JuiceCore
import SwiftUI

/// Settings › Agents (P935 to P939): one row per agent found on this Mac with its mark, Approve or Watch, its state in a
/// word or two and the buttons that state offers; Claude and Codex unfold into their profile folders. Under the list,
/// one quiet line names the agents not found, beside Remove from all agents. Above, the hook helper's Update while it is
/// older; below, SSH hosts and the other island apps, as Setup had them. Nothing is written without a click here or on
/// a drift row.
struct AgentsPane: View {
    @Environment(AppEnvironment.self) private var env
    @State private var confirmsRemoveAll = false

    var body: some View {
        let agents = env.agents
        let hooks = env.hooks
        @Bindable var settings = env.settings
        let rows = agents.rows
        let notFound = agents.notFound
        let integrations = hooks.integrations
        // Juice's hooks have their own helper now (P900): Open Island running holds only OpenCode's row, which says so
        // itself, so nothing is said of it above the list (P946, revised).
        FormPane {
            if let helper = hooks.helperUpdate {
                FormSection("Hook helper") {
                    FormRow("Older than this build") {
                        if case let .refused(reason) = helper {
                            AgentWord(reason, amber: true)
                        } else {
                            PushButton(title: helper == .updating ? "…" : "Update", blue: true, small: true) { hooks.updateHelper() }
                                .disabled(helper != .available)
                                .help("Replace the hook helper with this build's; no hook settings change")
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                FormSection {
                    if integrations.vibeIslandRunning {
                        // A notice, never a block: Vibe Island has its own helper and socket (P914).
                        FormRow("Vibe Island is running") { AgentWord(AgentsPaneText.vibeIslandRunning, amber: true) }
                    }
                    if rows.isEmpty {
                        FormRow("No agents found on this Mac") { EmptyView() }
                    }
                    ForEach(rows) { row in
                        AgentRowView(row: row, quietRefusal: nil)
                        ForEach(row.profiles) { AgentProfileRowView(row: $0, quietRefusal: nil) }
                    }
                }
                if !notFound.isEmpty || agents.canRemoveFromAll {
                    HStack(alignment: .center, spacing: 12) {
                        if !notFound.isEmpty {
                            // A few names, or a count with every name in its help: never cut (P1192).
                            Text(AgentsPaneText.notFound(notFound))
                                .font(SettingsTheme.TypeScale.footnote).foregroundStyle(SettingsTheme.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                                .help(AgentsPaneText.notFoundHelp(notFound))
                        }
                        Spacer(minLength: 0)
                        if agents.canRemoveFromAll {
                            PushButton(title: "Remove from all agents", quiet: true, small: true) { confirmsRemoveAll = true }
                                .help("Take \(Product.name)'s hooks out of every agent; each file is backed up first")
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            // Claude Code's own background sessions (wave 8, P1450, P1470).
            FormSection("Claude Code") {
                FormRow(AgentsPaneText.keepRunningTitle, subtitle: AgentsPaneText.keepRunning) {
                    SettingsSwitch(isOn: $settings.keepClaudeRunning, label: AgentsPaneText.keepRunningTitle)
                }
            }
            RemoteHostsSection()
            // Other apps, read-only, and only while one of them holds the buttons up.
            if integrations.vibeProfiles > 0 || !integrations.helperInBuild {
                FormSection("Other apps") {
                    if integrations.vibeProfiles > 0 {
                        FormRow("Vibe Island") {
                            AgentWord("Hooks in \(integrations.vibeProfiles) profile\(integrations.vibeProfiles == 1 ? "" : "s")")
                        }
                    }
                    if !integrations.helperInBuild {
                        FormRow("Hook helper") { AgentWord("Missing from this build", amber: true) }
                    }
                }
            }
        }
        .task { agents.refresh() }
        .confirmationDialog(AgentsPaneText.removeAllTitle, isPresented: $confirmsRemoveAll) {
            Button("Remove", role: .destructive) { agents.removeFromAll() }
        } message: {
            Text(AgentsPaneText.removeAllMessage)
        }
    }
}

/// The pane's own words.
enum AgentsPaneText {
    /// "Not found: Copilot CLI, Kilo", up to five names; more are a count, "16 agents not found", whose names are in
    /// `notFoundHelp` (P1192).
    static func notFound(_ names: [String]) -> String {
        names.count <= notFoundListed ? "Not found: " + names.joined(separator: ", ") : "\(names.count) agents not found"
    }

    /// The most names the line lists: five fit its two lines beside Remove from all agents.
    static let notFoundListed = 5

    /// The line's help: every name.
    static func notFoundHelp(_ names: [String]) -> String { "Not found: " + names.joined(separator: ", ") }
    static var removeAllTitle: String { "Remove \(Product.name) from every agent?" }
    static let removeAllMessage = "Each file is backed up first. Connect puts it back."
    /// Vibe Island beside this app: both draw their island.
    static let vibeIslandRunning = "Two islands show"
    /// The switch that moves Claude sessions into Claude Code's own background (P1450, P1470).
    static let keepRunningTitle = "Keep Claude sessions running when their window closes"
    /// What it does, which its name alone does not say.
    static var keepRunning: String {
        "Send to island types /background into its tab, which moves it into Claude Code's background: send or clear what you "
            + "typed there first. Sessions \(Product.name) starts begin there."
    }
}

/// One agent: mark, name with its Approve or Watch tag, where it is set up; its state and why; then Copy and its buttons,
/// or why they are unavailable. Claude's and Codex's own row shows only its word and its buttons over every folder: the
/// folders under it say why, and carry the Copy.
struct AgentRowView: View {
    let row: AgentRow
    /// A refusal the pane says once above the list (Open Island running): not repeated here.
    var quietRefusal: String?
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            AgentLookMark(look: row.look, size: 18, theme: theme)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name).font(Fonts.sys(13, .semibold)).foregroundStyle(SettingsTheme.ink).lineLimit(1)
                    ReachTag(reach: row.reach)
                }
                // Two lines, then cut in the middle, never at the end: the file name is what the row is there to show
                // (P948).
                if let place = row.place { MonoText(place, lines: 2, truncation: .middle) }
                // Approve holds for part of the agent only: the rest is named, whole (P1190).
                if let note = row.reachNote {
                    Text(note).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 200, alignment: .leading)
            AgentStatusText(status: row.status, showsDetail: row.profiles.isEmpty)
            HStack(spacing: 6) {
                if row.profiles.isEmpty, let copy = row.status.copy { CopyButton(title: copy.title, text: copy.text) }
                if let refusal = row.refusal, !row.busy {
                    if refusal != quietRefusal { AgentRefusal(refusal) }
                } else {
                    ForEach(row.actions, id: \.self) { action in
                        PushButton(title: row.busy ? "…" : action.title, blue: action != .remove, quiet: action == .remove, small: true) {
                            env.agents.perform(action, on: row.id)
                        }
                        .disabled(!row.canClick)
                        .help(AgentButtonHelp.text(action, row: row))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 46)
        .accessibilityElement(children: .contain)
    }
}

/// One Claude or Codex profile folder under its agent: alias and folder, its state and why, Copy, then its one button
/// (Connect, Repair, Move or Remove), or why it is unavailable.
struct AgentProfileRowView: View {
    let row: HookSetupRow
    var quietRefusal: String?
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let status = AgentRowText.profileStatus(row, helperPath: env.agents.helperPathForSnippets)
        let refusal = row.refusal ?? env.hooks.clickRefusal(for: row.id)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.alias).font(Fonts.sys(13)).foregroundStyle(SettingsTheme.ink).lineLimit(1)
                MonoText(row.folder)
            }
            // The agent's own row: 12 + its mark 18 + 10 + its name 200 = the folder's 40 + 200, so the words line up.
            .frame(width: 200, alignment: .leading)
            AgentStatusText(status: status)
            HStack(spacing: 6) {
                if let copy = status.copy { CopyButton(title: copy.title, text: copy.text) }
                // Add by hand says it with its Copy; the refusal would only repeat it.
                if let refusal, !row.busy {
                    if case .addByHand = status {} else if refusal != row.word, refusal != quietRefusal { AgentRefusal(refusal) }
                } else if let title = AgentRowText.profileButton(row), let action = row.action {
                    PushButton(title: row.busy ? "…" : title, blue: action != .remove, quiet: action == .remove, small: true) {
                        env.agents.performProfile(action, on: row.id)
                    }
                    .disabled(!row.canClick)
                    .help(title)
                }
            }
        }
        .padding(.leading, 40)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 40)
    }
}

/// A state's word, amber when it waits on the owner, with its one line why under it (`showsDetail`).
private struct AgentStatusText: View {
    let status: AgentRowStatus
    var showsDetail = true

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Wrapped, never cut: a narrow column beside two buttons still says the whole word and why (P948).
            Text(status.word).font(Fonts.sys(12.5))
                .foregroundStyle(status.isAmber ? SettingsTheme.statusAmber : SettingsTheme.ink2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if showsDetail, let detail = status.detail {
                Text(detail).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink2).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Approve or Watch, as a small tag beside the agent's name.
struct ReachTag: View {
    let reach: AgentReach

    var body: some View {
        Text(reach.title)
            .font(Fonts.sys(10, .semibold))
            .foregroundStyle(reach == .approve ? SettingsTheme.accent : SettingsTheme.ink2)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(Capsule().fill(reach == .approve ? SettingsTheme.accent.opacity(0.14) : SettingsTheme.chip))
            .fixedSize()
            .help(reach.help)
    }
}

/// Copy /hooks or Copy snippet: the text goes on the clipboard on a click, and the title says Copied for a moment.
private struct CopyButton: View {
    let title: String
    let text: String
    @State private var copied = false

    var body: some View {
        PushButton(title: copied ? "Copied" : title, small: true) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
        .help(text.count > 40 ? "Copy the lines to paste" : "Copy \(text)")
    }
}

/// Why a row's buttons are unavailable, in a few words.
private struct AgentRefusal: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Fonts.sys(11)).foregroundStyle(SettingsTheme.ink3).lineLimit(2)
            .multilineTextAlignment(.trailing).frame(maxWidth: 170, alignment: .trailing)
    }
}

/// A grey status word; amber for a problem.
private struct AgentWord: View {
    let text: String
    var amber = false
    init(_ text: String, amber: Bool = false) {
        self.text = text
        self.amber = amber
    }

    var body: some View {
        Text(text).font(Fonts.sys(12.5)).foregroundStyle(amber ? SettingsTheme.statusAmber : SettingsTheme.ink2)
    }
}

/// What each button does, in its tooltip.
enum AgentButtonHelp {
    static func text(_ action: AgentRowAction, row: AgentRow) -> String {
        let many = row.profiles.count > 1
        return switch action {
        case .connect: many ? "Connect every folder that is not connected yet" : "Add \(Product.name)'s hooks; the file is backed up first"
        case .repair: "Put back what is missing"
        case .move: "Point the hooks at \(Product.name)'s own helper"
        case .update: "Replace it with this build's"
        case .remove: many ? "Take \(Product.name)'s hooks out of every folder" : "Take \(Product.name)'s hooks out"
        }
    }
}

/// An agent's mark from its look: Claude's and OpenAI's marks, else the drawn shape, in its colour (as `AgentMarkView`).
struct AgentLookMark: View {
    let look: AgentLook
    var size: CGFloat
    var theme = JuiceTheme.black

    var body: some View {
        let colour = theme.island.tone(look.colour)
        Group {
            switch look.mark {
            case .claude: ProviderMarkView(provider: .claude, size: size, tint: colour)
            case .openAI: ProviderMarkView(provider: .codex, size: size, tint: colour)
            default: AgentShapeMark(mark: look.mark, side: size, ink: colour)
            }
        }
        .accessibilityLabel(look.name)
    }
}
