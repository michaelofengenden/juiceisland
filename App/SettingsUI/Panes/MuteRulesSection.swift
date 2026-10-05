import SwiftUI

/// Settings › Island › Mute rules (P420, P421, P1010): one row per rule, what it matches (Folder, Title, First prompt or
/// Tool), the text that contains (a Tool rule's, the tool's name, `*` for any run), whose (Any agent or one) and its
/// remove button; the header's "+" adds a rule, and with none one row
/// offers Add Rule. Under the rules, how many sessions they match now, live as the owner types. A rule is kept as it is
/// typed; one with no text matches nothing.
struct MuteRulesSection: View {
    @Binding var rules: [MuteRule]
    @Environment(AppEnvironment.self) private var env
    @FocusState private var focused: UUID?

    /// The widest choice of each pop-up ("First prompt", "CodeBuddy") with its chevron.
    static let fieldColumn: CGFloat = 106
    static let agentColumn: CGFloat = 104

    var body: some View {
        if rules.isEmpty {
            FormSection(MuteRulesText.title) {
                FormRow(MuteRulesText.empty) {
                    PushButton(title: "Add Rule", small: true) { add() }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                FormSection(MuteRulesText.title, accessory: AddRuleButton(action: add)) {
                    ForEach(rules) { rule in row(rule) }
                }
                // Read only here, so the rest of the pane never redraws with the sessions.
                FormFootnote(MuteRules.countText(MuteRules.matchCount(env.sessions.rows, rules: rules)))
            }
        }
    }

    private func row(_ rule: MuteRule) -> some View {
        HStack(spacing: 8) {
            // Fixed columns, so every rule's field starts and ends where the one above does.
            SettingsPopup(selection: binding(rule.id, \.field, fallback: .folder), options: MuteRules.fields, label: "Mute rule matches")
                .frame(width: Self.fieldColumn, alignment: .leading)
            RuleTextField(text: binding(rule.id, \.text, fallback: ""), prompt: MuteRulesText.prompt(rule.field))
                .focused($focused, equals: rule.id)
            SettingsPopup(selection: binding(rule.id, \.agent, fallback: nil), options: MuteRules.agents, label: "Mute rule agent")
                .frame(width: Self.agentColumn, alignment: .trailing)
            RemoveRuleButton { remove(rule.id) }
        }
        .padding(SettingsTheme.Metrics.rowPadding)
        .frame(minHeight: SettingsTheme.Metrics.rowMinHeight)
    }

    private func add() {
        let rule = MuteRule()
        rules.append(rule)
        // Its field takes the keys once it is built.
        Task { @MainActor in focused = rule.id }
    }

    private func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
    }

    /// One field of one rule, found by its id, so an edit never lands on another rule after a removal.
    private func binding<Value>(_ id: UUID, _ path: WritableKeyPath<MuteRule, Value>, fallback: Value) -> Binding<Value> {
        Binding(get: { rules.first { $0.id == id }?[keyPath: path] ?? fallback },
                set: { value in
                    guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
                    rules[index][keyPath: path] = value
                })
    }
}

/// The section's few words (unit-tested).
enum MuteRulesText {
    static let title = "Mute rules"
    /// The one row with no rule: what a rule matches.
    static let empty = "Match a folder, title, prompt or tool"

    /// The empty field's grey hint: what the text is matched against.
    static func prompt(_ field: MuteRule.Field) -> String {
        switch field {
        case .folder: "Folder contains…"
        case .title: "Title contains…"
        case .prompt: "Prompt contains…"
        case .tool: "Bash, mcp__github__*…"
        }
    }
}

/// A rule's text, as the pop-ups' face is drawn: 12 pt on the control grey, radius 5, 20 pt tall; it takes what room the
/// row leaves.
private struct RuleTextField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Fonts.sys(12))
            .foregroundStyle(SettingsTheme.ink)
            .lineLimit(1)
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(prompt).font(Fonts.sys(12)).foregroundStyle(SettingsTheme.ink3).allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(SettingsTheme.control))
            .accessibilityLabel("Mute rule text")
    }
}

/// The header's "+", as Accounts' is drawn.
private struct AddRuleButton: View {
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
        .help("Add rule")
        .accessibilityLabel("Add mute rule")
    }
}

/// A rule's remove button: a minus in the pop-ups' 20 pt circle.
private struct RemoveRuleButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(SettingsTheme.ink)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? SettingsTheme.roundHover : SettingsTheme.popupCircle))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove")
        .accessibilityLabel("Remove mute rule")
    }
}
