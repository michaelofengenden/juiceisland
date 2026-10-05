import AppKit
import IslandEngine
import JuiceCore
import SwiftUI

/// Settings › Accounts in the release build (`LiveUsageModel`), per provider: one row per account, the login its CLI
/// reported, whichever folders hold it (P93); then the folders signed out or not placed yet; then the profile
/// folders found on this Mac that the app does not read, each with Add. The header's "+" names a new folder
/// (`~/.claude-<name>`, `~/.codex-<name>`), makes it and signs in there; a provider with no folder at all shows Add
/// Account instead. Right-click stops monitoring a folder or forgets it (only a folder "+" can name again), which never
/// signs out or deletes anything, and offers nothing while the list cannot be edited. An account's right-click also
/// removes it (every folder holding it forgotten or stopped, P362), and a No plan account (P360) offers that in its row.
/// Then the browser profile sign-in pages open in, in one unlabelled group. The usage source is a development build's
/// switch: the release build offers it only while the source is Demo (`AccountsPane`), to come back from there. While
/// standalone Juice runs the list is only shown, with one line saying why, and a provider with nothing in it is left out.
struct LiveAccountsPane: View {
    @Environment(AppEnvironment.self) private var env
    let model: LiveUsageModel
    @State private var chromeProfiles: [ChromeProfile] = []

    var body: some View {
        FormPane {
            if let note = LiveAccountsText.statusLine(model) {
                Text(note)
                    .font(Fonts.sys(12.5))
                    .foregroundStyle(model.phase == .waitingForJuice ? SettingsTheme.statusAmber : SettingsTheme.ink2)
                    .padding(.horizontal, 10)
            }
            ForEach(Provider.allCases, id: \.self) { provider in
                let list = model.logins.first { $0.provider == provider }
                let found = model.canEdit ? model.discovered.filter { $0.provider == provider } : []
                let empty = (list?.logins.isEmpty ?? true) && (list?.folders.isEmpty ?? true) && found.isEmpty
                let adding = model.canEdit && model.newAccount?.provider == provider
                if !empty || model.canEdit {
                    FormSection(provider.displayName,
                                accessory: AddAccountButton(model: model, provider: provider, shown: !empty && !adding)) {
                        if adding {
                            NewAccountRow(model: model, provider: provider)
                        } else if empty {
                            EmptyAccountsRow(model: model, provider: provider)
                        }
                        ForEach(list?.logins ?? []) { row in
                            LoginRowView(row: row, now: model.now, home: model.home,
                                         monitor: { model.setMonitored(login: row.id, $0) }, canEdit: model.canEdit,
                                         stopMonitoring: model.canEdit ? { model.stopMonitoring($0.id) } : nil,
                                         forget: model.canEdit ? { model.forget($0.id) } : nil,
                                         canForget: { model.canForget(provider: $0.provider, folder: $0.folder) },
                                         remove: model.canEdit ? { model.removeAccount(login: row.id) } : nil,
                                         below: AnyView(NewFolderHooksLines(model: model, folders: row.folders)))
                        }
                        ForEach(list?.folders ?? []) { LiveLooseFolderRow(model: model, loose: $0) }
                        ForEach(found) { profile in
                            FolderRow(provider: profile.provider, path: profile.folder, home: model.home, found: true,
                                      forget: model.canForget(provider: profile.provider, folder: profile.folder)
                                          ? { model.forget(profile.id) } : nil) {
                                PushButton(title: "Add", small: true) { model.add(profile) }
                            }
                        }
                    }
                }
            }
            FormSection {
                // A Claude or Codex config folder at any path, by its path (P1055).
                AddFolderRow(model: model)
                FormRow("Sign-in browser") {
                    SettingsPopup(selection: Binding(get: { model.browserProfile ?? "" }, set: { model.browserProfile = $0.isEmpty ? nil : $0 }),
                                  options: [("", "Default browser")] + chromeProfiles.map { ($0.directory, $0.name) },
                                  label: "Browser profile")
                }
            }
        }
        .onAppear {
            model.refreshDiscovery()
            chromeProfiles = model.browserProfiles()
        }
    }
}

/// Add Folder…: a Claude or Codex config folder anywhere (a fork's, a second account outside the home folder), picked in
/// the system's folder panel and kept by its path (`LiveUsageModel.addFolder`, P1055). Why a folder was not taken shows
/// in the row, in a few words, until the next pick.
struct AddFolderRow: View {
    let model: LiveUsageModel
    @State private var problem: LiveUsageModel.AddFolderProblem?

    var body: some View {
        FormRow("Folder at another path", subtitle: problem.map(LiveAccountsText.addFolder)) {
            PushButton(title: "Add Folder…", small: true) { choose() }
                .disabled(!model.canEdit)
                .help(model.canEdit ? "A Claude or Codex config folder, anywhere" : LiveUsageModel.juiceRunningText)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: model.home, isDirectory: true)
        panel.prompt = "Add"
        panel.message = "Choose a Claude or Codex config folder."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated {
                if case let .failure(why) = model.addFolder(at: url.path) { problem = why } else { problem = nil }
            }
        }
    }
}

/// The pane's few words (unit-tested).
@MainActor
enum LiveAccountsText {
    /// Why Add Folder… did not take a folder.
    static func addFolder(_ problem: LiveUsageModel.AddFolderProblem) -> String {
        switch problem {
        case .cannotEdit: LiveUsageModel.juiceRunningText
        case .notAProfile: "No Claude or Codex files there"
        case .both: "Holds both Claude and Codex files"
        case .listed: "Already in the list"
        case .home: "That is your home folder, not a config folder"
        case .aboveHome: "That holds your home folder, not a config folder"
        }
    }

    /// One line above the list, only when there is something to say.
    static func statusLine(_ model: LiveUsageModel) -> String? {
        if let reason = model.refreshUnavailableReason { return reason }
        if let progress = model.refreshProgress { return "Refreshing \(progress) of \(model.refreshTotal)…" }
        return missing(model.missingCLIs)
    }

    /// "Codex CLI not found", "Claude and Codex CLIs not found"; nil when none is missing.
    static func missing(_ providers: [Provider]) -> String? {
        guard !providers.isEmpty else { return nil }
        let names = providers.map(\.displayName).joined(separator: " and ")
        return names + (providers.count > 1 ? " CLIs not found" : " CLI not found")
    }

    /// `~/.claude-work` for a folder in the home folder.
    static func folder(_ path: String, home: String = NSHomeDirectory()) -> String {
        path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// The folders an account's row lists under its email: `~/.codex · ~/.codex-side`.
    static func folders(_ folders: [Account], home: String = NSHomeDirectory()) -> String {
        folders.map { folder($0.folder, home: home) }.joined(separator: " · ")
    }
}

/// One account: grid 16 · 1fr · 66 · 45 · 32, gap 10, at least 40 pt tall. Its email (cut at the end, the whole of it
/// on hover), and its organization's name after it when it is not the personal one (P580, never cut), over the folders
/// that hold it, then plan, battery and Monitor; `below`, a line under it. Right-click stops
/// monitoring one of its folders, or forgets one `canForget` allows, or removes the account (`remove`, P362): that
/// asks once more in the row itself, the plan's column turning into "Remove — click again" for 3 s (no dialog). A No
/// plan account (P360) shows Remove there from the start; its plan word is its ended subscription's. With no actions
/// passed there is no menu and no Remove.
struct LoginRowView: View {
    @Environment(\.juiceTheme) private var theme
    let row: LoginRow
    var now: Date
    var home: String = NSHomeDirectory()
    /// The Monitor switch's action; nil drops the switch column (Juice's readings, read only).
    var monitor: ((Bool) -> Void)?
    var canEdit = true
    var stopMonitoring: ((Account) -> Void)?
    var forget: ((Account) -> Void)?
    /// Whether a folder may be forgotten (one "+" can name again).
    var canForget: (Account) -> Bool = { _ in false }
    /// Remove account (P362); nil offers none.
    var remove: (() -> Void)?
    var below: AnyView?
    /// Remove's confirmation, in the row (renders pass one already armed).
    @State var removal = RemoveConfirmation()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            line
            if let below { below }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(minHeight: 40)
        .contextMenu {
            if let stopMonitoring {
                ForEach(row.folders) { folder in
                    let path = LiveAccountsText.folder(folder.folder, home: home)
                    Button("Stop Monitoring \(path)") { stopMonitoring(folder) }
                    if let forget, canForget(folder) { Button("Forget \(path)") { forget(folder) } }
                }
            }
            if remove != nil {
                if stopMonitoring != nil { Divider() }
                Button(removal.armedAt == nil ? RemoveConfirmation.menuTitle : RemoveConfirmation.armedTitle) { pressRemove() }
            }
        }
        // Only while armed: the confirmation lapses after its window, and nothing runs at rest.
        .task(id: removal.armedAt) {
            guard removal.armedAt != nil else { return }
            try? await Task.sleep(for: .seconds(RemoveConfirmation.window))
            if !Task.isCancelled { removal.disarm() }
        }
    }

    /// The first press arms Remove for 3 s, a second one within them removes the account.
    private func pressRemove() {
        if removal.press(at: Date()) { remove?() }
    }

    /// The plan's column: the plan word; Remove on a No plan account, or on any while armed.
    @ViewBuilder private var planColumn: some View {
        if remove != nil, removal.armedAt != nil || row.battery.state == .noPlan {
            RemoveAccountButton(armed: removal.armedAt != nil, action: pressRemove)
                .frame(minWidth: 66, alignment: .leading)
        } else {
            Text(row.plan ?? "").font(Fonts.sys(12)).foregroundStyle(SettingsTheme.ink2).lineLimit(1)
                .frame(width: 66, alignment: .leading)
        }
    }

    private var line: some View {
        HStack(spacing: 10) {
            ProviderMarkView(provider: row.provider, size: 16, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 0) {
                    Text(row.email)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let org = row.org {
                        Text(" · " + org).lineLimit(1).layoutPriority(1)
                    }
                }
                .font(Fonts.sys(13, .medium))
                .foregroundStyle(SettingsTheme.ink)
                .help(row.title)
                let folders = LiveAccountsText.folders(row.folders, home: home)
                MonoText(folders).help(folders)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            planColumn
            BatteryView(battery: row.battery, now: now, theme: theme)
                .opacity(row.monitored ? 1 : 0.42)
                .frame(width: 45)
            if let monitor {
                SettingsSwitch(isOn: Binding(get: { row.monitored }, set: { monitor($0) }), label: "Monitor \(row.title)", disabled: !canEdit)
                    .frame(width: 32)
            }
        }
        .frame(minHeight: 30)
    }
}

/// Remove account's confirmation, built into the row (P362; no system dialog): the first press arms it for `window`, and
/// only a second press within it removes. Pure, so its rule is tested without a view.
struct RemoveConfirmation: Equatable {
    static let window: TimeInterval = 3
    static let menuTitle = "Remove Account"
    static let buttonTitle = "Remove"
    static let armedTitle = "Remove — click again"

    private(set) var armedAt: Date?

    init(armedAt: Date? = nil) { self.armedAt = armedAt }

    func isArmed(at now: Date) -> Bool {
        guard let armedAt else { return false }
        return now >= armedAt && now.timeIntervalSince(armedAt) < Self.window
    }

    /// A press at `now`: true when it confirms (a second press within the window), which disarms it; else it arms.
    mutating func press(at now: Date) -> Bool {
        if isArmed(at: now) {
            armedAt = nil
            return true
        }
        armedAt = now
        return false
    }

    mutating func disarm() { armedAt = nil }
}

/// Remove in an account's row (P362): grey "Remove", then red "Remove — click again" while armed.
struct RemoveAccountButton: View {
    var armed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(armed ? RemoveConfirmation.armedTitle : RemoveConfirmation.buttonTitle)
                .font(Fonts.sys(12))
                .foregroundStyle(armed ? .white : SettingsTheme.pushInk)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(height: SettingsTheme.Metrics.pushHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(armed ? SettingsTheme.destructive : SettingsTheme.push))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Nothing is signed out")
        .accessibilityLabel(armed ? RemoveConfirmation.armedTitle : "Remove account")
    }
}

/// A folder titled by its path: one no account row lists (signed out, or not asked yet), or one found on this Mac that
/// the app does not read (`found`: its mark faded). `trailing` is its control; `below` a sign-in's line while one runs.
/// Right-click stops monitoring it or forgets it, where the pane passes those.
struct FolderRow<Trailing: View, Below: View>: View {
    @Environment(\.juiceTheme) private var theme
    let provider: Provider
    let path: String
    var home: String = NSHomeDirectory()
    var found = false
    var stopMonitoring: (() -> Void)?
    var forget: (() -> Void)?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var below: Below

    init(provider: Provider, path: String, home: String = NSHomeDirectory(), found: Bool = false,
         stopMonitoring: (() -> Void)? = nil, forget: (() -> Void)? = nil,
         @ViewBuilder trailing: () -> Trailing, @ViewBuilder below: () -> Below = { EmptyView() }) {
        self.provider = provider
        self.path = path
        self.home = home
        self.found = found
        self.stopMonitoring = stopMonitoring
        self.forget = forget
        self.trailing = trailing()
        self.below = below()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ProviderMarkView(provider: provider, size: 16, opacity: found ? 0.5 : 1, theme: theme)
                let folder = LiveAccountsText.folder(path, home: home)
                MonoText(folder, colour: found ? SettingsTheme.ink2 : SettingsTheme.ink)
                    .help(folder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            .frame(minHeight: 26)
            below
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 34)
        .contextMenu {
            if let stopMonitoring { Button("Stop Monitoring") { stopMonitoring() } }
            if let forget { Button("Forget") { forget() } }
        }
    }
}

/// A folder being asked who is signed in: "…" until its CLI answers.
struct UnplacedMark: View {
    var body: some View {
        Text(verbatim: "…").font(Fonts.sys(13)).foregroundStyle(SettingsTheme.ink3)
            .help("Checking who is signed in")
            .accessibilityLabel("Checking who is signed in")
    }
}

/// A signed-out or unplaced folder in the release build: Sign In (Cancel while its sign-in runs, with the sign-in's line
/// under it); "…" while it is asked who is signed in; Sign In again when its CLI could not say (the vendor's own login
/// settles it); nothing when its CLI is missing, which the status line says once.
struct LiveLooseFolderRow: View {
    let model: LiveUsageModel
    let loose: LooseFolder

    var body: some View {
        let signIn = model.signInPhase(for: loose.id)
        // Sign In needs the provider's CLI; the status line says when it is missing.
        let cannotSignIn = !model.canEdit || !model.signingIn.isEmpty || model.missingCLIs.contains(loose.folder.provider)
        FolderRow(provider: loose.folder.provider, path: loose.folder.folder, home: model.home,
                  stopMonitoring: model.canEdit ? { model.stopMonitoring(loose.id) } : nil,
                  forget: model.canEdit && model.canForget(provider: loose.folder.provider, folder: loose.folder.folder)
                      ? { model.forget(loose.id) } : nil) {
            switch signIn {
            case .opening?, .inBrowser?, .checking?, .wrongIdentity?:
                PushButton(title: "Cancel", small: true) { model.signInCoordinator.cancel() }
            default:
                if loose.state == .signedOut {
                    PushButton(title: "Sign In", blue: true, small: true) { model.signIn(id: loose.id) }
                        .disabled(cannotSignIn)
                } else if model.asking.contains(loose.id) {
                    UnplacedMark()
                } else if model.unanswered.contains(loose.id) {
                    PushButton(title: "Sign In", small: true) { model.signIn(id: loose.id) }
                        .disabled(cannotSignIn)
                        .help("Could not check who is signed in")
                }
            }
        } below: {
            if let signIn { SignInLine(model: model, phase: signIn) }
        }
    }
}

/// A sign-in's line under its row: the browser step, the check, a different account (keep it or sign in again), or
/// why it failed. Juice spec §7; the vendor's CLI does the login, nothing is signed out. The browser step also takes
/// the code a sign-in page shows at the end, when the CLI asks for one, and shows a one-time code the CLI printed for
/// the page.
struct SignInLine: View {
    let model: LiveUsageModel
    let phase: SignInPhase

    var body: some View {
        let coordinator = model.signInCoordinator
        HStack(spacing: 8) {
            switch phase {
            case .opening:
                caption("Opening sign-in…")
            case .inBrowser(_, let wantsCode):
                // The field says what to do once the CLI asks for a code; only a refusal needs words then.
                if coordinator.codeRefused {
                    caption("Code not accepted", colour: SettingsTheme.statusRed)
                } else if !wantsCode {
                    caption("Finish in your browser")
                }
                PushButton(title: "Open Browser", small: true) { coordinator.openBrowser() }
                    .disabled(coordinator.lastURL == nil)
                if let code = coordinator.deviceCode { SignInDeviceCode(code: code) }
                if wantsCode { SignInCodeField { coordinator.submitCode($0) } }
            case .checking:
                caption("Checking account…")
            case .wrongIdentity(let found, _):
                caption("Signed in as \(found)", colour: SettingsTheme.statusAmber)
                PushButton(title: "Use This Account", small: true) { _ = model.signInCoordinator.useThisAccount() }
                PushButton(title: "Sign In Again", small: true) { model.signInCoordinator.signInAgain() }
            case .failed(let why):
                caption(why, colour: SettingsTheme.statusRed)
            default:
                EmptyView()
            }
        }
        .padding(.leading, 26)
    }

    private func caption(_ text: String, colour: Color = SettingsTheme.ink2) -> some View {
        Text(text).font(Fonts.sys(12)).foregroundStyle(colour).lineLimit(2)
    }
}

/// Where the code a sign-in page shows at the end goes (Claude's `Paste code here if prompted`). Return or Continue
/// sends it to the waiting CLI and empties the field; the text is in this field and nowhere else until then. ⌘V comes
/// from the app menu's Edit › Paste, which Settings has while it is open.
struct SignInCodeField: View {
    let submit: (String) -> Void
    @State private var code = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Paste code", text: $code)
                .textFieldStyle(.plain)
                .font(Fonts.mono(11.5))
                .foregroundStyle(SettingsTheme.ink)
                .autocorrectionDisabled()
                .focused($focused)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .frame(minWidth: 96, maxWidth: .infinity, minHeight: SettingsTheme.Metrics.pushHeight,
                       maxHeight: SettingsTheme.Metrics.pushHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(SettingsTheme.field))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? SettingsTheme.accent.opacity(0.6) : SettingsTheme.controlEdge, lineWidth: focused ? 2 : 0.5))
                .onSubmit(send)
                .onAppear { focused = true }
                .accessibilityLabel("Sign-in code")
            PushButton(title: "Continue", small: true, action: send)
                .disabled(Self.trimmed(code).isEmpty)
        }
    }

    private func send() {
        guard !Self.trimmed(code).isEmpty else { return }
        submit(code)
        code = ""
    }

    static func trimmed(_ code: String) -> String { code.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A one-time code the CLI printed for its sign-in page (a device-code login), to type or paste there.
struct SignInDeviceCode: View {
    let code: String

    var body: some View {
        HStack(spacing: 6) {
            Text(code)
                .font(Fonts.mono(12.5, .semibold))
                .foregroundStyle(SettingsTheme.ink)
                .textSelection(.enabled)
                .fixedSize()
            PushButton(title: "Copy", small: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
            }
        }
    }
}

// MARK: Adding an account

/// The words for a name "+" cannot use (unit-tested); none while nothing is typed.
enum NewAccountText {
    static func word(_ problem: NewProfileFolder.Problem) -> String? {
        switch problem {
        case .empty: nil
        case .invalid: "Letters, digits, - or _"
        case .reserved: "Reserved name"
        case .exists: "Exists"
        case .failed: "Could not create"
        }
    }

    /// `~/.claude-`: the part of the new folder's path the name follows.
    static func prefix(_ provider: Provider) -> String { "~/" + provider.defaultFolderName + "-" }
}

/// The "+" at the right of a provider's header: opens the name row. Shown while the list can be edited and the
/// provider's CLI was found (the status line says when it is missing); greyed, with the reason on hover, while a
/// sign-in runs.
struct AddAccountButton: View {
    let model: LiveUsageModel
    let provider: Provider
    var shown = true

    var body: some View {
        if shown, model.canEdit, !model.isMissingCLI(provider) {
            let reason = model.addUnavailableReason(provider)
            Button {
                model.newAccount = NewAccountDraft(provider: provider)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SettingsTheme.ink)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(SettingsTheme.popupCircle))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(reason != nil)
            .help(reason ?? "Add account")
            .accessibilityLabel("Add \(provider.displayName) account")
        }
    }
}

/// A provider with no folder at all: Add Account opens the name row; the CLI's absence, in its place, when it is missing.
struct EmptyAccountsRow: View {
    let model: LiveUsageModel
    let provider: Provider

    var body: some View {
        HStack(spacing: 10) {
            if model.isMissingCLI(provider) {
                Text(LiveAccountsText.missing([provider]) ?? "").font(Fonts.sys(12)).foregroundStyle(SettingsTheme.ink2)
            } else {
                let reason = model.addUnavailableReason(provider)
                PushButton(title: "Add Account", small: true) { model.newAccount = NewAccountDraft(provider: provider) }
                    .disabled(reason != nil)
                    .help(reason ?? "")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: SettingsTheme.Metrics.rowMinHeight)
    }
}

/// The "+" row: the new folder's path being typed (`~/.claude-` then the name, used lower-cased; the field keeps what was
/// typed, so the caret never jumps), why Add cannot act now or why the name cannot be used, in a word or two, Cancel,
/// and Add (Restore for a forgotten folder). Return adds, Esc cancels.
struct NewAccountRow: View {
    @Environment(\.juiceTheme) private var theme
    let model: LiveUsageModel
    let provider: Provider
    @FocusState private var focused: Bool

    var body: some View {
        let draft = model.newAccount ?? NewAccountDraft(provider: provider)
        let check = model.checkNewAccount(draft.name, provider: provider)
        let problem = draft.failure ?? { if case .problem(let problem) = check { problem } else { nil } }()
        HStack(spacing: 10) {
            ProviderMarkView(provider: provider, size: 16, theme: theme)
            HStack(spacing: 0) {
                Text(verbatim: NewAccountText.prefix(provider)).font(Fonts.mono(11.5)).foregroundStyle(SettingsTheme.ink2)
                TextField("name", text: Binding(get: { draft.name },
                                                set: { model.newAccount = NewAccountDraft(provider: provider, name: $0) }))
                    .textFieldStyle(.plain)
                    .font(Fonts.mono(11.5))
                    .foregroundStyle(SettingsTheme.ink)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .lineLimit(1)
                    .onSubmit(add)
                    .accessibilityLabel("New \(provider.displayName) folder name")
            }
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, minHeight: SettingsTheme.Metrics.pushHeight, maxHeight: SettingsTheme.Metrics.pushHeight,
                   alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(SettingsTheme.field))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(focused ? SettingsTheme.accent.opacity(0.6) : SettingsTheme.controlEdge, lineWidth: focused ? 2 : 0.5))
            // A sign-in started after the row opened greys Add: the row says why.
            if let word = model.addUnavailableReason(provider) ?? problem.flatMap(NewAccountText.word) {
                Text(word).font(Fonts.sys(12)).foregroundStyle(SettingsTheme.statusAmber).lineLimit(1).fixedSize()
            }
            PushButton(title: "Cancel", small: true) { model.newAccount = nil }
            PushButton(title: { if case .forgotten = check { "Restore" } else { "Add" } }(), blue: true, small: true, action: add)
                .disabled(problem != nil || !model.canAddAccount(provider))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(minHeight: 34)
        .onAppear { focused = true }
        .onExitCommand { model.newAccount = nil }
    }

    private func add() {
        guard let draft = model.newAccount, draft.provider == provider else { return }
        model.addAccount(draft.name, provider: provider)
    }
}

/// Under an account row, for each of its folders "+" made in this run: Setup's Install for that folder's session hooks
/// while Setup offers it (the owner's click; nothing installs by itself), then, in amber, what Setup says when the
/// folder needs more (a Codex home's `/hooks`). The folder is named when the row lists several. ✕ closes the line.
struct NewFolderHooksLines: View {
    @Environment(AppEnvironment.self) private var env
    let model: LiveUsageModel
    let folders: [Account]

    var body: some View {
        let offered = folders.filter { model.added.contains($0.id) }
        ForEach(offered) { folder in
            let id = Account.id(provider: folder.provider, folder: ProfileHookTargets.normalized(folder.folder))
            if let row = env.hooks.rows.first(where: { $0.id == id }) {
                line(row, folder: folder, named: folders.count > 1)
            }
        }
    }

    @ViewBuilder private func line(_ row: HookSetupRow, folder: Account, named: Bool) -> some View {
        let refusal = row.refusal ?? env.hooks.clickRefusal(for: row.id)
        let offersInstall = row.action == .install || row.busy
        if offersInstall || row.tone == .amber {
            HStack(spacing: 8) {
                let title = named ? "Session hooks · " + LiveAccountsText.folder(folder.folder, home: model.home) : "Session hooks"
                if offersInstall {
                    caption(title)
                    if let refusal, !row.busy {
                        caption(refusal, colour: SettingsTheme.ink3)
                    } else {
                        PushButton(title: row.busy ? "…" : HookRowText.title(for: .install), blue: true, small: true) {
                            env.hooks.perform(.install, on: row.id)
                        }
                        .disabled(!row.canClick)
                    }
                } else {
                    caption(title, colour: SettingsTheme.statusAmber)
                    caption(row.detail ?? row.word)
                }
                Button { model.dismissHooksOffer(folder.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(SettingsTheme.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(.leading, 26)
        }
    }

    private func caption(_ text: String, colour: Color = SettingsTheme.ink2) -> some View {
        Text(text).font(Fonts.sys(12)).foregroundStyle(colour).lineLimit(1)
    }
}
