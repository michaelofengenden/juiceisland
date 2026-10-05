import Foundation
import JuiceCore
import OpenIslandCore

/// What the desktop widget draws (spec §4.7), as the app last saw it: the rows the island's opened card leads with
/// (needs you, then running), each only as its row says it, and the Claude and Codex batteries. The app writes it to the
/// App Group container (`WidgetStore`); the widget reads it. Nothing else goes in: no command, question, diff, message,
/// prompt, path, email or account name, and no text the sessions wrote: a row is named by its project folder (the
/// chat's title only when the repo is its title), and its line is the card's status word with the tool, the step or
/// where it is answered ("Needs approval · Bash"), never a question's topic. A file another process could read then
/// tells no more than the folders and the pill's glyphs (P200, P341).
struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// The rows the file keeps: the large widget shows six, and "N more" counts the rest.
    static let rowLimit = 8

    var version = Self.currentVersion
    /// When the app wrote it.
    var written: Date
    /// False once the app quit: it can no longer tell what runs, so the widget shows no rows and no batteries (P344).
    var appRunning: Bool
    /// Needs you first, then running, in the engine's own order (P14); at most `rowLimit`.
    var rows: [Row]
    /// Rows that need you or run beyond `rows`.
    var more: Int
    var claude: [Battery]
    var codex: [Battery]
    /// Settings › Island › Glyph style and Glyph colour (and Running, below), so the widget's glyphs are the island's.
    var glyphStyle: String
    var glyphColour: String
    /// Settings › Island › Running, Liquid's running look (P385, P388): `slim` or `full`. nil in a file an older build wrote,
    /// read as Slim, the default (`runningLook`).
    var liquidRunning: String?

    /// Settings › Island › Needs you colour (P783): `pink`, `violet` or `orange`. nil in a file an older build wrote, read
    /// as Pink, the default (`needsYou`).
    var needsYouColour: String?

    /// Settings › Island › Theme (P525): `black` or `glass`. nil in a file an older build wrote, read as Black, the
    /// default (`juiceTheme`).
    var theme: String?

    /// Settings › General › Appearance, written under Solid only (P777): the look Solid's widget takes, as the island and
    /// the panel do. nil in a file an older build wrote and under every other theme, read as System: the widget's own
    /// look, which WidgetKit hands it from macOS (`appearanceChoice`).
    var appearance: String?

    /// The running look the widget's Liquid glyphs draw.
    var runningLook: LiquidRunningLook { liquidRunning.flatMap(LiquidRunningLook.init(rawValue:)) ?? .slim }

    /// What needs you, in the island's colour: Pink for a file with none, or with one this build does not know.
    var needsYou: NeedsYouColour { NeedsYouColour(stored: needsYouColour) }

    /// The theme the widget draws in: Black for a file with none, or with one this build does not know.
    var juiceTheme: JuiceTheme { JuiceTheme(stored: theme) }

    /// The Appearance Solid's widget takes: System for a file with none, or with one this build does not know.
    var appearanceChoice: AppearanceChoice { appearance.flatMap(AppearanceChoice.init(rawValue:)) ?? .system }

    /// Settings › General › Appearance as the snapshot keeps it: under Solid only, the one theme whose widget follows it.
    static func appearance(_ choice: AppearanceChoice, theme: JuiceTheme) -> String? { theme == .solid ? choice.rawValue : nil }

    struct Row: Codable, Equatable, Sendable, Identifiable {
        enum Kind: String, Codable, Sendable { case needsYou, running }

        /// The session's id: the widget's link opens it (`WidgetLink.session`).
        var id: String
        /// `claude`, `codex`, or the engine's `AgentTool` raw value for any other agent.
        var agent: String
        var kind: Kind
        /// The row's name: its project folder, or with none the agent's; never a title the owner's prompt or the agent's
        /// transcript gave (`WidgetSnapshot.title`, P200).
        var title: String
        /// `PixelGlyph`'s raw value: `bang`, `ques`, `cross`, `eq`, or `agents` for a running row whose main agent waits on
        /// its subagents (P370).
        var glyph: String
        /// A card's status line (`CardText.status`) for a row that needs you: the coloured word and what follows it
        /// ("Needs approval" and "Bash", "Question" and nil). Running rows carry neither: their tool changes every few
        /// seconds, and each change would cost the widget a reload (P340).
        var word: String?
        var detail: String?
    }

    struct Battery: Codable, Equatable, Sendable {
        enum State: Codable, Equatable, Sendable {
            case available(left: Int, low: Bool)
            case usedUp(refill: Date?)
            case signIn
            case signingIn
            case stale(last: Int?)
            case unknown
            /// A Claude login with no plan limits (P360): dimmed.
            case noPlan
            /// A Claude login billed by usage, with no plan limits (P581): dimmed like No plan.
            case noLimits
        }

        var state: State
        var isNext: Bool
        /// The account the owner's sessions run in (P815): true, or nil (an older build's file, or not in use). Its dot
        /// shows in the widget as on the panel; a change of it waits for the next reload.
        var inUse: Bool? = nil
    }

    /// The app quit (or never wrote one): nothing to show but that, in the theme it was in.
    static func closed(at date: Date, theme: JuiceTheme = .black, appearance: AppearanceChoice = .system) -> WidgetSnapshot {
        WidgetSnapshot(written: date, appRunning: false, rows: [], more: 0, claude: [], codex: [],
                       glyphStyle: GlyphStyle.pixel.rawValue, glyphColour: GlyphColourMode.byState.rawValue, theme: theme.rawValue,
                       appearance: Self.appearance(appearance, theme: theme))
    }
}

// MARK: From the app's models

extension WidgetSnapshot {
    /// The snapshot of `env` now: its rows as the island ranks them (a quiet row only while its card waits, as the pill
    /// counts it, P254) and its batteries as the panel builds them (P41).
    @MainActor
    static func make(_ env: AppEnvironment, at date: Date) -> WidgetSnapshot {
        let shown = env.sessions.rows.filter { row in
            row.tells && (row.bucket == .needsYou || row.bucket == .running)
        }
        let rows = shown.prefix(rowLimit).map { row(for: $0, card: env.card(for: $0.id)) }
        // The panel's order, the accounts in use marked (P815).
        let inUse = env.accountsInUseNow
        func batteries(_ row: ProviderRowModel?) -> [Battery] {
            (row?.batteries ?? []).map { Battery($0, inUse: inUse.contains($0.id)) }
        }
        return WidgetSnapshot(written: date, appRunning: true, rows: rows, more: shown.count - rows.count,
                              claude: batteries(env.usage.claudeRow), codex: batteries(env.usage.codexRow),
                              glyphStyle: env.settings.glyphStyle.rawValue, glyphColour: env.settings.glyphColour.rawValue,
                              liquidRunning: env.settings.liquidRunning.rawValue, needsYouColour: env.settings.needsYouColour.rawValue,
                              theme: env.settings.juiceTheme.rawValue,
                              appearance: Self.appearance(env.settings.appearance, theme: env.settings.juiceTheme))
    }

    /// One row: its agent, name and glyph, and for one that needs you the status line its card's header carries, less
    /// any words the session wrote.
    static func row(for row: SessionRow, card: SessionCard?) -> Row {
        let kind: Row.Kind = row.bucket == .needsYou ? .needsYou : .running
        var word: String?
        var detail: String?
        if kind == .needsYou {
            if let card {
                let status = CardText.status(withoutSessionText(card), host: row.host)
                word = status.word
                detail = status.text
            } else {
                word = SessionRowText.cleanStatus(row).word
            }
        }
        return Row(id: row.id, agent: agentKey(row.agent), kind: kind, title: title(row),
                   glyph: row.glyph.rawValue, word: word, detail: detail)
    }

    /// A row's name in the file (P200): a title lives in memory only, so a row the owner's prompt or the agent's
    /// transcript titled goes by its project folder, or with none by its agent; a row the repo titles keeps it.
    static func title(_ row: SessionRow) -> String {
        if row.titleSource == .repo { return IslandRowText.title(row) }
        return row.project.isEmpty ? row.agent.displayName : row.project
    }

    /// The card with the words its session wrote left out of its status line: a question's topics (the agent's own
    /// header text) and a failed turn's message unless it is one of the error kinds (`TurnFailure.words`). An
    /// approval's tool, a subagent's type, a plan's step count, a question's step and where it is answered stay.
    static func withoutSessionText(_ card: SessionCard) -> SessionCard {
        switch card {
        case var .question(model):
            model.topic = nil
            model.shown = model.shown.map { var shown = $0; shown.topic = nil; return shown }
            return .question(model)
        case var .done(model) where model.failed && !TurnFailure.words.values.contains(model.message):
            model.message = ""
            return .done(model)
        default:
            return card
        }
    }

    static func agentKey(_ agent: GlyphPalette.Agent) -> String {
        switch agent {
        case .claude: "claude"
        case .codex: "codex"
        case let .other(tool): tool.rawValue
        case let .kind(kind): "kind:" + kind.rawValue
        }
    }

    /// What the widget ever needs to reload for at once (P340): a request that comes or goes or changes its line, the
    /// app quitting, a battery that changes its kind (available, low, used up, signed out, stale), the theme, Solid's
    /// Appearance or the needs-you colour (the owner just picked it in Settings and looks for it, P525, P777, P783). A title, a session that starts or
    /// ends a turn, or a battery's percent waits for the next reload (`WidgetReloadPolicy`).
    var urgentKey: UrgentKey {
        UrgentKey(appRunning: appRunning,
                  needsYou: rows.filter { $0.kind == .needsYou }.map { [$0.id, $0.word ?? "", $0.detail ?? ""] },
                  batteries: (claude + codex).map(\.category), theme: juiceTheme, appearance: appearanceChoice, needsYouColour: needsYou)
    }

    struct UrgentKey: Equatable, Sendable {
        var appRunning: Bool
        var needsYou: [[String]]
        var batteries: [String]
        var theme: JuiceTheme = .black
        var appearance: AppearanceChoice = .system
        var needsYouColour: NeedsYouColour = .pink
    }

    /// Every battery's refill time still ahead of `date`: the widget's timeline adds an entry at each, so a used-up
    /// battery flips to "due" with no reload (P347).
    func refills(after date: Date) -> [Date] {
        Set((claude + codex).compactMap { battery -> Date? in
            guard case let .usedUp(refill?) = battery.state, refill > date else { return nil }
            return refill
        }).sorted()
    }
}

extension WidgetSnapshot.Battery {
    init(_ model: BatteryModel) { self.init(model, inUse: false) }

    init(_ model: BatteryModel, inUse: Bool) {
        let state: State = switch model.state {
        case let .available(left, low): .available(left: left, low: low)
        case let .usedUp(refill): .usedUp(refill: refill)
        case .signInNeeded: .signIn
        case .signingIn: .signingIn
        case let .stale(last): .stale(last: last)
        case .unknown: .unknown
        case .noPlan: .noPlan
        case .noLimits: .noLimits
        }
        self.init(state: state, isNext: model.isNext, inUse: inUse ? true : nil)
    }

    /// Its dot shows (P815).
    var showsInUse: Bool { inUse == true }

    /// The panel's own battery for it, for `BatteryView` (no id, name or hover label: the widget has no hover).
    func model(_ index: Int, provider: Provider) -> BatteryModel {
        let account: AccountState = switch state {
        case let .available(left, low): .available(percentLeft: left, isLow: low)
        case let .usedUp(refill): .usedUp(refill: refill)
        case .signIn: .signInNeeded
        case .signingIn: .signingIn
        case let .stale(last): .stale(lastPercentLeft: last)
        case .unknown: .unknown
        case .noPlan: .noPlan
        case .noLimits: .noLimits
        }
        return BatteryModel(id: "\(provider.rawValue)-\(index)", alias: "", state: account, isNext: isNext,
                            hoverLabel: accessibilityText)
    }

    /// A battery's kind, without its percent: a change of kind reloads the widget at once.
    var category: String {
        switch state {
        case let .available(_, low): low ? "low" : "available"
        case .usedUp: "usedUp"
        case .signIn: "signIn"
        case .signingIn: "signingIn"
        case .stale: "stale"
        case .unknown: "unknown"
        case .noPlan: "noPlan"
        case .noLimits: "noLimits"
        }
    }

    var accessibilityText: String {
        switch state {
        case let .available(left, _): "\(left) percent left"
        case .usedUp: "Used up"
        case .signIn: "Sign-in needed"
        case .signingIn: "Signing in"
        case .stale: "Not read lately"
        case .unknown: "Unknown"
        case .noPlan: "No plan"
        case .noLimits: "No limits"
        }
    }
}
