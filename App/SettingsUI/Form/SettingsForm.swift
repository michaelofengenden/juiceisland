import SwiftUI

/// The dark Settings form primitives (prototype.md §1.5, CSS `.fs`, `.fs-h`, `.fs-g`, `.fr`, `.fn`).

/// A pane's column of sections: 20 pt between sections, 6 pt above the first.
struct FormPane<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsTheme.Metrics.sectionTop) { content }
            .padding(.top, SettingsTheme.Metrics.firstSectionTop)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A section: optional header (with an optional control at its right end, such as Accounts' "+"), the rounded group,
/// optional footnote.
struct FormSection<Content: View>: View {
    var title: String?
    var footnote: String?
    var accessory: AnyView?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    init<Accessory: View>(_ title: String, accessory: Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = AnyView(accessory)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(SettingsTheme.TypeScale.sectionHeader)
                        .foregroundStyle(SettingsTheme.ink)
                    if let accessory {
                        Spacer(minLength: 0)
                        accessory
                    }
                }
                .padding(EdgeInsets(top: 0, leading: 10, bottom: 8, trailing: 10))
            }
            FormGroup { content }
            if let footnote { FormFootnote(footnote) }
        }
    }
}

/// The rounded group (white 5 %, radius 10, 0.5 pt white 6 % inner edge) with 1 pt separators between its rows,
/// inset 12 pt on both sides.
struct FormGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Group(subviews: content) { rows in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    row.overlay(alignment: .top) {
                        if index > 0 { SettingsTheme.separator.frame(height: 1).padding(.horizontal, 12) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: SettingsTheme.Metrics.groupRadius).fill(SettingsTheme.group))
        .overlay(RoundedRectangle(cornerRadius: SettingsTheme.Metrics.groupRadius).strokeBorder(SettingsTheme.groupStroke, lineWidth: 0.5))
    }
}

/// One row: label (and grey subtitle) on the left, the control on the right. `dimmed` greys the label to 50 %.
struct FormRow<Control: View>: View {
    var label: String
    var subtitle: String?
    var dimmed = false
    @ViewBuilder var control: Control

    init(_ label: String, subtitle: String? = nil, dimmed: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label
        self.subtitle = subtitle
        self.dimmed = dimmed
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            if !label.isEmpty || subtitle != nil {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(SettingsTheme.TypeScale.row).foregroundStyle(SettingsTheme.ink)
                    if let subtitle {
                        Text(subtitle).font(SettingsTheme.TypeScale.rowSubtitle).foregroundStyle(SettingsTheme.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .lineSpacing(1.5)
                .opacity(dimmed ? 0.5 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: 0)
            }
            control
        }
        // CSS border-box: the minimum height includes the padding.
        .padding(SettingsTheme.Metrics.rowPadding)
        .frame(minHeight: SettingsTheme.Metrics.rowMinHeight)
    }
}

/// The grey note under a group (11.5 / 1.45, padding 7 10 0).
struct FormFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(SettingsTheme.TypeScale.footnote)
            .foregroundStyle(SettingsTheme.ink2)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .padding(EdgeInsets(top: 7, leading: 10, bottom: 0, trailing: 10))
    }
}

// MARK: Controls

/// The switch: 32 × 19, radius 10, off `#4A4A4E`, on blue, a 15 pt white knob that slides in 0.15 s.
struct SettingsSwitch: View {
    @Binding var isOn: Bool
    var label: String
    var disabled = false

    var body: some View {
        let size = SettingsTheme.Metrics.switchSize, knob = SettingsTheme.Metrics.switchKnob
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? SettingsTheme.accent : SettingsTheme.switchOff)
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 1)
                    .padding(2)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}

/// The segmented control: `#3A3A3C` radius 6 padding 1; 12.5 pt buttons, padding 2 10, radius 5, selected `#636366`.
struct SettingsSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var label: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let (value, title) = options[index]
                Button {
                    selection = value
                } label: {
                    Text(title)
                        .font(SettingsTheme.TypeScale.segment)
                        .foregroundStyle(SettingsTheme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 2.5)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selection == value ? SettingsTheme.segmentSelected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 6).fill(SettingsTheme.control))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

/// The pop-up: its value, then a 20 pt circle (white 10 %) with the up/down chevron. Opens a native menu.
struct SettingsPopup<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    var label: String

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                let (value, title) = options[index]
                Button { selection = value } label: {
                    if selection == value { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
        } label: {
            PopupFace(title: options.first { $0.0 == selection }?.1 ?? "")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(label)
    }
}

/// The pop-up's face without a menu (read-only fixture values).
struct PopupFace: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(SettingsTheme.TypeScale.row).foregroundStyle(SettingsTheme.ink)
            SVGIcon(svg: ChromeIcon.upDown, size: CGSize(width: 7, height: 11), colour: SettingsTheme.ink)
                .frame(width: 20, height: 20)
                .background(Circle().fill(SettingsTheme.popupCircle))
        }
        .frame(height: 22)
    }
}

/// The push button: 22 pt tall, radius 6, `#56565A` (or blue), 13 pt, padding 0 11. `quiet` is the secondary look
/// for a button repeated down a list (Setup's Remove): grey text on a faint fill, no top highlight.
struct PushButton: View {
    let title: String
    var blue = false
    var quiet = false
    var small = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Fonts.sys(small ? 12 : 13))
                .foregroundStyle(quiet ? SettingsTheme.ink2 : blue ? .white : SettingsTheme.pushInk)
                .lineLimit(1)
                .padding(.horizontal, small ? 9 : 11)
                .frame(height: SettingsTheme.Metrics.pushHeight)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(blue ? SettingsTheme.accent : quiet ? SettingsTheme.pushQuiet : SettingsTheme.push))
                .overlay(alignment: .top) {
                    if !quiet {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsTheme.controlEdge, lineWidth: 0.5).mask(alignment: .top) {
                            Rectangle().frame(height: 1)
                        }
                    }
                }
                .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// Monospaced grey value text (folders, versions, floors): 11.5 pt SF Mono, `#98989D`, ellipsised.
struct MonoText: View {
    let text: String
    var colour: Color = SettingsTheme.ink2
    var lines = 1
    init(_ text: String, colour: Color = SettingsTheme.ink2, lines: Int = 1) {
        self.text = text
        self.colour = colour
        self.lines = lines
    }

    var body: some View {
        Text(text).font(Fonts.mono(11.5)).foregroundStyle(colour).lineLimit(lines).truncationMode(.tail)
    }
}
