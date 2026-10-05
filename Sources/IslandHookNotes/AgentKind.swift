import Foundation
import OpenIslandCore

/// Every coding agent Juice knows, by the word its hook commands pass as `--source` (P915).
///
/// Upstream's `AgentTool` is a closed enum in the vendored Core, which is never edited, and it has no case for GitHub
/// Copilot CLI, Devin CLI or Kilo CLI. So a session's agent is this kind: the engine keeps it per session
/// (`SessionLabels.agent`, from the hook's context note or, for Kilo, from its session id) and the app draws the mark,
/// colour and name from it. Upstream's state still files each session under a tool, its `carrierTool`.
public enum AgentKind: String, CaseIterable, Codable, Sendable {
    case claude, codex, opencode, cursor, qwen, copilot, devin, kilo
    case gemini, grok, kimi, qoder, codebuddy, factory, pi, ohmypi
    /// Antigravity CLI (`agy`), Gemini CLI's successor: its hooks name no event and carry camelCase fields, so the helper
    /// reads them itself (`AntigravityHooks`) and tells the bridge in Gemini CLI's words (P1105).
    case antigravity
    /// Amp: Juice's own plugin sends its threads in OpenCode's payload, named `amp-…` (`fromSessionID`, P1157).
    case amp

    /// The kind of an upstream tool.
    public init(tool: AgentTool) {
        switch tool {
        case .claudeCode: self = .claude
        case .codex: self = .codex
        case .openCode: self = .opencode
        case .cursor: self = .cursor
        case .qwenCode: self = .qwen
        case .geminiCLI: self = .gemini
        case .grokBuild: self = .grok
        case .kimiCLI: self = .kimi
        case .qoder: self = .qoder
        case .codebuddy: self = .codebuddy
        case .factory: self = .factory
        case .pi: self = .pi
        case .ohMyPi: self = .ohmypi
        }
    }

    /// The kind a helper's `--source` names; upstream's helper also reads `droid` as Factory. nil for a word no agent
    /// uses (never guessed).
    public init?(source: String?) {
        guard let source else { return nil }
        if source == "droid" {
            self = .factory
            return
        }
        self.init(rawValue: source)
    }

    /// The upstream tool a session of this kind is kept under. Copilot and Devin speak Claude's hook format but answer
    /// in their own words, so the helper sends their hooks to the bridge as a Claude-format fork's
    /// (`bridgeSource`): a fork's request is shown and answered at once, and no rule meant only for Claude Code (its
    /// pending window, permission modes, No and stop, Open in another account, its transcript) ever applies to them.
    /// Kilo runs our OpenCode plugin. Antigravity CLI's hooks reach the bridge in Gemini CLI's words, its sessions labelled
    /// from their notes (P1105).
    public var carrierTool: AgentTool {
        switch self {
        case .claude: .claudeCode
        case .codex: .codex
        case .opencode, .kilo: .openCode
        case .amp: .openCode
        case .cursor: .cursor
        case .qwen: .qwenCode
        case .copilot, .devin, .codebuddy: .codebuddy
        case .gemini, .antigravity: .geminiCLI
        case .grok: .grokBuild
        case .kimi: .kimiCLI
        case .qoder: .qoder
        case .factory: .factory
        case .pi: .pi
        case .ohmypi: .ohMyPi
        }
    }

    /// The `--source` the bridge is told: the kind's own word where upstream's helper knows it, else its carrier's.
    public var bridgeSource: String {
        switch self {
        case .copilot, .devin: "codebuddy"
        default: rawValue
        }
    }

    /// Upstream has no tool of its own for it: its sessions are told apart only by their label.
    public var needsLabel: Bool { AgentKind(tool: carrierTool) != self }

    /// The name the owner types (Qwen, not "Qwen Code").
    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .cursor: "Cursor"
        case .qwen: "Qwen"
        case .copilot: "Copilot"
        case .devin: "Devin"
        case .kilo: "Kilo"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .kimi: "Kimi"
        case .qoder: "Qoder"
        case .codebuddy: "CodeBuddy"
        case .factory: "Factory"
        case .pi: "Pi"
        case .ohmypi: "Oh My Pi"
        case .antigravity: "Antigravity"
        case .amp: "Amp"
        }
    }

    /// Kilo's sessions, as the Kilo source of our OpenCode plugin names them (`OpenCodePlugin.source(for: .kilo)`).
    public static let kiloSessionPrefixes = ["kilo-", "kilo2-"]

    /// Amp's threads, as Juice's Amp plugin names them (`AmpPlugin`): `amp-<thread id>`.
    public static let ampSessionPrefix = "amp-"

    /// The kind a session id alone names: only Kilo's and Amp's do.
    public static func fromSessionID(_ id: String) -> AgentKind? {
        if kiloSessionPrefixes.contains(where: { id.hasPrefix($0) }) { return .kilo }
        return id.hasPrefix(ampSessionPrefix) ? .amp : nil
    }
}
