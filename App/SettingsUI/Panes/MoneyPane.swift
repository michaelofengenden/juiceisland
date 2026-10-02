import JuiceCore
import SwiftUI

/// Settings › Money (spec §4.5, Juice spec §6; §8 decisions 13 and 14): one compact block per account with a key, in
/// the panel's order, then one line per source without a key. An account's top line is the tile, its name (the owner's
/// label, else `OpenRouter`, `OpenRouter 2`), the state (`Reading…`, a failure; nothing more once a figure reads), the
/// figure and Show. Its second line is the key (`Key set · Replace · Remove`, and a "+" on a source's first block while
/// it may hold another, as Accounts' "+"; the key itself is never shown again), the optional credit with its date
/// (Anthropic, OpenAI) or top-up (OpenRouter, RunPod), the id the source's path needs (xAI's team, Fireworks' account),
/// a name once a source holds two keys, and the runway thresholds on the first account that burns (RunPod, Vast.ai), on
/// one line when they fit, else the key on a line of its own and, if still too wide, the thresholds on another; a
/// source's blocks, once it holds two keys, all put the key on a line of its own, so their fields sit alike. While a
/// key is typed, or Remove asks, that line is the key field or the question. A source without any key is its name and
/// Add key… (only a dev build's mirror, which has no button, says `Not set up`). Demo data lists only the sources it
/// draws.
struct MoneyPane: View {
    static let amberChoices = [24, 36, 48, 72, 96, 120]
    static let redChoices = [6, 12, 18, 24, 36, 48]
    @Environment(AppEnvironment.self) private var env
    /// Headless renders open an account's key line in a given state.
    @Environment(\.moneyKeyPreview) private var preview

    var body: some View {
        let listed = Self.listed(money: env.liveMoney, drawn: env.usage.panel.money.map(\.id))
        let thresholds = listed.keyed.first { $0.source.hasRunway }
        FormPane {
            if !listed.keyed.isEmpty {
                FormSection {
                    ForEach(listed.keyed, id: \.self) { account in
                        let siblings = listed.keyed.filter { $0.source == account.source }
                        MoneyAccountBlock(account: account, showsThresholds: account == thresholds, siblings: siblings.count,
                                          addsAnother: siblings.first == account, preview: preview[account])
                    }
                }
            }
            if !listed.unkeyed.isEmpty {
                FormSection {
                    ForEach(listed.unkeyed, id: \.self) { MoneyAccountBlock(account: $0, preview: preview[$0]) }
                }
            }
        }
        // A key file made or deleted by hand shows when the pane opens, not only on the next 30 s tick.
        .onAppear { env.liveMoney?.refreshKeyFiles() }
    }

    /// The accounts with a key, in the panel's order, and the sources with none (their first account; a source whose
    /// first key went but a further one stayed is listed once, with its keys). With no money model (demo data), the
    /// accounts the usage source draws, all keyed.
    static func listed(money: LiveMoneyModel?, drawn: [String]) -> (keyed: [MoneyAccount], unkeyed: [MoneyAccount]) {
        guard let money else { return (drawn.compactMap(MoneyAccount.init(rawValue:)).sorted(), []) }
        let keyed = money.accounts.filter { money.keyFiles[$0] != nil }
        return (keyed, MoneyAccount.firsts.filter { first in !keyed.contains { $0.source == first.source } })
    }
}

/// An account's key line: at rest, typing its key (or another key of its source), or asking before Remove; with why the
/// last Save or Remove failed.
enum MoneyKeyMode: Equatable {
    case idle
    case adding(error: String?)
    /// Typing a further key of the source (`OpenRouter 2`), from the key line's "+".
    case addingAnother(error: String?)
    case confirmingRemove(error: String?)

    var error: String? {
        switch self {
        case .idle: nil
        case .adding(let error), .addingAnother(let error), .confirmingRemove(let error): error
        }
    }

    var isTyping: Bool {
        switch self {
        case .adding, .addingAnother: true
        case .idle, .confirmingRemove: false
        }
    }
}

/// A render's key line state per account, with the text already typed (only its length shows, as dots), and an id the
/// field refused.
struct MoneyKeyPreview: Equatable {
    var mode: MoneyKeyMode
    var draft = ""
    var idRefusal: String?
}

extension EnvironmentValues {
    @Entry var moneyKeyPreview: [MoneyAccount: MoneyKeyPreview] = [:]
}

/// One account's block: at least 58 pt with a key (a switched-off account draws its text at 55 %), one 40 pt line
/// without.
struct MoneyAccountBlock: View {
    @Environment(AppEnvironment.self) private var env
    let account: MoneyAccount
    /// This account carries RunPod's and Vast.ai's amber and red (the first account that burns).
    var showsThresholds = false
    /// How many keys its source holds: from two on, each is named.
    var siblings = 1
    /// The source's first block with a key: its key line carries Add another.
    var addsAnother = false
    @State private var mode: MoneyKeyMode
    /// The key being typed: in this field only, emptied on Save and on Cancel.
    @State private var draft: String
    /// Why the id field did not keep what was typed there (`Not a team ID`), until an id is kept or the field emptied.
    @State private var idRefusal: String?

    init(account: MoneyAccount, showsThresholds: Bool = false, siblings: Int = 1, addsAnother: Bool = false, preview: MoneyKeyPreview? = nil) {
        self.account = account
        self.showsThresholds = showsThresholds
        self.siblings = siblings
        self.addsAnother = addsAnother
        _mode = State(initialValue: preview?.mode ?? .idle)
        _draft = State(initialValue: preview?.draft ?? "")
        _idRefusal = State(initialValue: preview?.idRefusal)
    }

    private var source: MoneySource { account.source }
    private var id: String { account.rawValue }
    private var row: MoneyRowModel? { env.usage.panel.money.first { $0.id == id } }
    private var detail: MoneyDetail? { env.usage.moneyDetails[id] }
    /// The release build's (or a dev build's mirroring) money model; nil for demo data, which has no key files.
    private var money: LiveMoneyModel? { env.liveMoney }
    /// The key file the next read uses, when the money model knows (nil: none, or demo data).
    private var keyFile: String? { money?.keyFiles[account] }
    /// Demo data draws every account it lists as keyed; real data only an account with a key file.
    private var hasKey: Bool { money == nil || keyFile != nil }
    private var label: String? { env.settings.money.labels[account] }
    private var name: String { label ?? account.defaultName }

    var body: some View {
        let shown = env.settings.moneyShown[account] ?? true
        let dim = shown || !hasKey ? 1 : 0.55
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                MoneySourceTile(id: id, size: 16)
                Text(name).font(Fonts.sys(13, .medium)).foregroundStyle(SettingsTheme.ink).lineLimit(1)
                if let status { Text(status.word).font(Fonts.sys(11.5)).foregroundStyle(status.colour).lineLimit(1) }
                Spacer(minLength: 8)
                if hasKey {
                    if let row, row.amount != nil { MoneyPaneFigure(row: row, detail: detail) }
                    SettingsSwitch(isOn: Binding(get: { shown }, set: { env.settings.moneyShown[account] = $0 }), label: "Show \(name)")
                } else if mode == .idle, money?.editsKeys == true {
                    PushButton(title: "Add key…", small: true) { startAdding() }
                }
            }
            .opacity(dim)
            secondLine.padding(.leading, 26).opacity(mode == .idle ? dim : 1)
        }
        // A refusal is about the text it refused: typing again clears it.
        .onChange(of: draft) {
            switch mode {
            case .adding(_?): mode = .adding(error: nil)
            case .addingAnother(_?): mode = .addingAnother(error: nil)
            default: break
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minHeight: hasKey || mode != .idle ? 58 : 40, alignment: .leading)
    }

    @ViewBuilder private var secondLine: some View {
        switch mode {
        case .adding:
            MoneyKeyField(source: source, name: name, draft: $draft, save: { save(for: account) }, cancel: cancel)
        case .addingAnother:
            if let next = money?.nextAccount(for: source) {
                MoneyKeyField(source: source, name: next.defaultName, prompt: MoneyKeyField.anotherPrompt(source), draft: $draft,
                              save: { save(for: next) }, cancel: cancel)
            }
        case .confirmingRemove:
            confirmRemove
        case .idle where hasKey:
            // One line when it fits; else the key on its own line, and the thresholds on another when still too wide. A
            // source with two keys never uses one line, so its blocks' fields sit alike.
            if siblings > 1 {
                ViewThatFits(in: .horizontal) {
                    keyOverFields
                    keyOverFieldsOverThresholds
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        if let money { keyLine(money) }
                        fields
                        if showsThresholds { runwayThresholds }
                        Spacer(minLength: 0)
                    }
                    keyOverFields
                    keyOverFieldsOverThresholds
                }
            }
        case .idle:
            EmptyView()
        }
    }

    private var keyOverFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let money { keyLine(money) }
            HStack(spacing: 16) {
                fields
                if showsThresholds { runwayThresholds }
            }
        }
    }

    private var keyOverFieldsOverThresholds: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let money { keyLine(money) }
            HStack(spacing: 16) { fields }
            if showsThresholds { runwayThresholds }
        }
    }

    /// Room for the longest name a label may be (`MoneySettings.labelLimit`).
    static let nameFieldWidth: CGFloat = 156

    @ViewBuilder private var fields: some View {
        if let idName = source.accountIDName { MoneyTextField(title: idName, value: idBinding, width: source == .xAI ? 272 : 150, mono: true) }
        if source.takesCredit { MoneyCreditField(account: account) }
        if source.takesTopUp { MoneyAmountField(title: "Top-up", value: topUpBinding) }
        if siblings > 1 || label != nil {
            MoneyTextField(title: "Name", value: labelBinding, width: Self.nameFieldWidth, prompt: account.defaultName)
        }
    }

    // MARK: Status

    /// The state word after the name, or nil once a figure reads: why the last Save or Remove failed, or why the id
    /// field kept nothing (`Not a team ID`); with no key, nothing where Add key… says it, `Not set up` in a dev build's
    /// mirror; with a key but no reading yet, `Reading…`; then the account's own word (a failure, `Stale`,
    /// `Team ID not set`).
    private var status: (word: String, colour: Color)? {
        if let error = mode.error { return (error, SettingsTheme.statusAmber) }
        if let idRefusal { return (idRefusal, SettingsTheme.statusAmber) }
        if let money, keyFile == nil { return money.editsKeys ? nil : ("Not set up", SettingsTheme.ink3) }
        guard let word = detail?.status else { return money == nil ? nil : ("Reading…", SettingsTheme.ink3) }
        switch word {
        case "Connected": return nil
        case "Reading…": return (word, SettingsTheme.ink3)
        default: return (word, SettingsTheme.statusAmber)
        }
    }

    // MARK: Key

    /// `Key set · Replace · Remove` in the build that reads money, then a "+" on a source's first block while the
    /// source may hold another (`Add another OpenRouter key` on hover); a dev build's mirror only says `Key set`.
    private func keyLine(_ money: LiveMoneyModel) -> some View {
        HStack(spacing: 5) {
            Text("Key set").font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink2)
            if money.editsKeys {
                MoneyKeyLink(title: "Replace") { startAdding() }
                MoneyKeyLink(title: "Remove") { mode = .confirmingRemove(error: nil) }
                if addsAnother, money.nextAccount(for: source) != nil {
                    MoneyAddAnotherButton(source: source) {
                        draft = ""
                        mode = .addingAnother(error: nil)
                    }
                    .padding(.leading, 5)
                }
            }
        }
        .fixedSize()
    }

    /// `Delete ~/.config/runpod/key?` with Delete and Cancel; for a file picked elsewhere, `Stop using <name>?` (the
    /// file stays). When another key file the lookup finds is read after it, a grey line under the question names it,
    /// so an older key never comes back unsaid. No alert: the question is the line itself.
    private var confirmRemove: some View {
        let removal = money?.removal(for: account)
        let next = money?.keyAfterRemoval(for: account)
        let (question, button): (String, String?) = switch removal {
        case .delete(let path): ("Delete \(path)?", "Delete")
        case .forget(let path): ("Stop using \(MoneyKeyFile.displayName(path))? The file stays.", "Stop Using")
        case nil: ("The key file is gone.", nil)
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(question).font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink).lineLimit(1).truncationMode(.middle)
                if let button { MoneyDeleteButton(title: button) { remove() } }
                PushButton(title: "Cancel", quiet: true, small: true) { mode = .idle }
            }
            if let next {
                Text("Then \(next) is used").font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink2)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
    }

    private func startAdding() {
        draft = ""
        mode = .adding(error: nil)
    }

    private func save(for target: MoneyAccount) {
        guard let money else { return }
        if let error = money.saveKey(draft, for: target) {
            mode = target == account ? .adding(error: error.message) : .addingAnother(error: error.message)
            return
        }
        draft = ""
        mode = .idle
    }

    private func cancel() {
        draft = ""
        mode = .idle
    }

    private func remove() {
        guard let money else { return }
        if let error = money.removeKey(for: account) {
            mode = .confirmingRemove(error: error.message)
            return
        }
        mode = .idle
    }

    // MARK: Amounts

    private var topUpBinding: Binding<Double?> {
        Binding(get: { env.settings.money.topUps[account] }, set: { env.settings.money.topUps[account] = $0 })
    }

    /// xAI's team id, Fireworks' account id: kept only when it is one (`MoneySettings.setAccountID`); anything else
    /// leaves the field as it was, and the state word says why.
    private var idBinding: Binding<String?> {
        Binding(get: { env.settings.money.accountIDs[account] }, set: { value in
            idRefusal = env.settings.money.setAccountID(value, for: account)
        })
    }

    private var labelBinding: Binding<String?> {
        Binding(get: { env.settings.money.labels[account] }, set: { env.settings.money.labels[account] = $0.flatMap(MoneySettings.cleanLabel) })
    }

    /// Amber and Red, never wrapped: their own line when the key's line has no room for them.
    private var runwayThresholds: some View {
        @Bindable var settings = env.settings
        return HStack(spacing: 6) {
            Text("Amber").font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink2).fixedSize()
            SettingsPopup(selection: $settings.runwayAmberHours, options: MoneyPane.amberChoices.map { ($0, "\($0) h") }, label: "Amber under")
            Text("Red").font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink2).fixedSize().padding(.leading, 4)
            SettingsPopup(selection: $settings.runwayRedHours, options: MoneyPane.redChoices.map { ($0, "\($0) h") }, label: "Red under")
        }
        .fixedSize()
    }
}

/// Where a key is typed: a secure field (dots only; the key is never shown), Save and Cancel. Return saves and Escape
/// cancels. ⌘V comes from the app menu's Edit › Paste, which Settings has while it is open.
struct MoneyKeyField: View {
    let source: MoneySource
    /// The account the key is for, as VoiceOver names the field (`OpenRouter 2 key`).
    var name: String?
    /// The grey prompt; the source's kind of key (`prompt(_:)`) when nil.
    var prompt: String?
    @Binding var draft: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            SecureField("", text: $draft)
                .textFieldStyle(.plain)
                .font(Fonts.mono(11.5))
                .foregroundStyle(SettingsTheme.ink)
                .focused($focused)
                .lineLimit(1)
                // The prompt drawn by us, grey, so it never reads as typed text.
                .background(alignment: .leading) {
                    if draft.isEmpty {
                        Text(prompt ?? Self.prompt(source)).font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink3).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 7)
                .frame(width: 230, height: SettingsTheme.Metrics.pushHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(SettingsTheme.field))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? SettingsTheme.accent.opacity(0.6) : SettingsTheme.controlEdge, lineWidth: focused ? 2 : 0.5))
                .onSubmit { if !Self.isBlank(draft) { save() } }
                .onExitCommand(perform: cancel)
                .onAppear { focused = true }
                .accessibilityLabel("\(name ?? source.name) key")
            PushButton(title: "Save", blue: true, small: true, action: save)
                .disabled(Self.isBlank(draft))
            PushButton(title: "Cancel", quiet: true, small: true, action: cancel)
        }
    }

    /// What the source's key is (`MoneySource.keyKind`): `Admin key` for the cost reports and fal.ai, `Management key`
    /// for xAI, `API token` for Hetzner and DigitalOcean, `API key` for the rest.
    static func prompt(_ source: MoneySource) -> String { source.keyKind }

    /// The prompt for a further key of the source: `Another API key`, `Another admin key`.
    static func anotherPrompt(_ source: MoneySource) -> String {
        let kind = source.keyKind
        return "Another " + (kind.hasPrefix("API") ? kind : kind.prefix(1).lowercased() + kind.dropFirst())
    }

    static func isBlank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Replace and Remove after `Key set`: small blue words, a dot before each.
struct MoneyKeyLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text("·").font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink3)
            Button(action: action) {
                Text(title).font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.accent.opacity(hovering ? 0.75 : 1))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
    }
}

/// Another key for a source that has one (`OpenRouter 2`): the Accounts pane's "+", named on hover.
struct MoneyAddAnotherButton: View {
    let source: MoneySource
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SettingsTheme.ink)
                .frame(width: 16, height: 16)
                .background(Circle().fill(SettingsTheme.popupCircle))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Add another \(source.name) key")
        .accessibilityLabel("Add another \(source.name) key")
    }
}

/// Remove's Delete: the push button's shape in the destructive red.
struct MoneyDeleteButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.sys(12))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: SettingsTheme.Metrics.pushHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(SettingsTheme.destructive.opacity(0.85)))
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// The figure as the Money pane draws it: amber or red by runway (as the thresholds are now), else as its row is toned
/// (a quota low as a battery is), grey when it is money spent.
struct MoneyPaneFigure: View {
    @Environment(AppEnvironment.self) private var env
    let row: MoneyRowModel
    let detail: MoneyDetail?

    var body: some View {
        let runway = MoneyDetail.tone(runwayHours: detail?.runwayHours, amber: env.settings.runwayAmberHours, red: env.settings.runwayRedHours)
        let tone = detail?.runwayHours == nil ? row.emphasis : runway
        let colour: Color = switch tone {
        case .attention: SettingsTheme.statusRed
        case .warn: SettingsTheme.statusAmber
        case .normal: row.isSpent ? SettingsTheme.ink2 : SettingsTheme.ink
        }
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(row.amount ?? "").font(Fonts.num(12.5, .semibold)).foregroundStyle(colour)
            if let suffix = row.suffix ?? (row.isSpent ? "spent" : nil) {
                Text(suffix).font(Fonts.sys(11)).foregroundStyle(tone == .normal ? SettingsTheme.ink2 : colour)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Credit and the UTC day it was bought (Anthropic, OpenAI). The date shows once a credit is set.
struct MoneyCreditField: View {
    @Environment(AppEnvironment.self) private var env
    let account: MoneyAccount

    var body: some View {
        let money = env.settings.money
        HStack(spacing: 6) {
            MoneyAmountField(title: "Credit", value: Binding(get: { money.credits[account] }, set: { value in
                money.credits[account] = value
                if value != nil, money.creditDates[account] == nil { money.creditDates[account] = MoneyRules.startOfDay(Date()) }
            }))
            if money.credits[account] != nil {
                Text("since").font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink2)
                DatePicker("", selection: Binding(get: { money.creditDates[account] ?? MoneyRules.startOfDay(Date()) },
                                                  set: { money.creditDates[account] = MoneyRules.startOfDay($0) }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .environment(\.timeZone, MoneyRules.utc.timeZone)
                    .fixedSize()
            }
        }
    }
}

/// An optional dollar amount, written when editing ends (Return or leaving the field), never on each keystroke.
struct MoneyAmountField: View {
    let title: String
    @Binding var value: Double?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink2)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Fonts.num(12))
                .foregroundStyle(SettingsTheme.ink)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(SettingsTheme.control))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear { text = Self.format(value) }
                .onChange(of: value) { _, new in if !focused { text = Self.format(new) } }
                .accessibilityLabel(title)
        }
        .fixedSize()
    }

    private func commit() {
        let parsed = Self.parse(text)
        if parsed != value { value = parsed }
        text = Self.format(parsed)
    }

    static func format(_ value: Double?) -> String {
        guard let value, value.isFinite, value < limit else { return "" }
        return value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    /// An amount at or past this is no amount (and never reaches the `Int` conversion above).
    static let limit: Double = 1e12

    /// `1400`, `$1,400`, `1400.50`; empty, unreadable or absurd is no amount.
    static func parse(_ text: String) -> Double? {
        let digits = text.filter { $0.isASCII && ($0.isNumber || $0 == ".") }
        guard let value = Double(digits), value > 0, value < limit else { return nil }
        return value
    }
}

/// A short optional text (an account's name, xAI's team id), written when editing ends, never on each keystroke; empty
/// is none. The grey prompt, when given, is what shows without one (`OpenRouter 2`).
struct MoneyTextField: View {
    let title: String
    @Binding var value: String?
    var width: CGFloat = 110
    var mono = false
    var prompt: String?
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Fonts.sys(11.5)).foregroundStyle(SettingsTheme.ink2)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(mono ? Fonts.mono(11.5) : Fonts.sys(12))
                .foregroundStyle(SettingsTheme.ink)
                .lineLimit(1)
                .background(alignment: .leading) {
                    if text.isEmpty, let prompt {
                        Text(prompt).font(Fonts.sys(12)).foregroundStyle(SettingsTheme.ink3).allowsHitTesting(false)
                    }
                }
                .frame(width: width)
                .padding(.horizontal, 6)
                .frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(SettingsTheme.control))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
                .onAppear { text = value ?? "" }
                .onChange(of: value) { _, new in if !focused { text = new ?? "" } }
                .accessibilityLabel(title)
        }
        .fixedSize()
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = trimmed.isEmpty ? nil : trimmed
        if new != value { value = new }
        text = value ?? ""
    }
}

/// A money source's tile, for any of its accounts (`OpenRouter 2` draws OpenRouter's): OpenAI's mark, or a monogram
/// (700 8.5 pt white) on the source's tint, radius 4.
struct MoneySourceTile: View {
    @Environment(\.juiceTheme) private var theme
    let id: String
    var size: CGFloat = 16

    var body: some View {
        let source = MoneyAccount(rawValue: id)?.source
        if source == .openAI {
            ProviderMarkView(provider: .codex, size: size, theme: theme)
        } else {
            let (text, tint) = source.map(Self.monogram) ?? (String(id.prefix(1)), Color(hex: 0x4A4A50))
            Text(text)
                .font(.system(size: 8.5 * size / 16, weight: .bold))
                .tracking(-0.2)
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: 4 * size / 16).fill(tint))
        }
    }

    static func monogram(_ source: MoneySource) -> (String, Color) {
        typealias T = SettingsTheme.SourceTint
        return switch source {
        case .openRouter: ("OR", T.openRouter)
        case .anthropic: ("A", T.anthropic)
        case .openAI: ("O", Color(hex: 0x4A4A50))
        case .runPod: ("RP", T.runPod)
        case .hetzner: ("H", T.hetzner)
        case .deepSeek: ("DS", T.deepSeek)
        case .moonshot: ("M", T.moonshot)
        case .xAI: ("x", T.xAI)
        case .fireworks: ("FW", T.fireworks)
        case .fal: ("f", T.fal)
        case .elevenLabs: ("11", T.elevenLabs)
        case .vastAI: ("V", T.vastAI)
        case .digitalOcean: ("DO", T.digitalOcean)
        }
    }
}
