import SwiftUI

/// What's new (P716): after an update opened this build, a small card of what changed, the commit subjects the updater
/// read from its checkout's log, in the window under the header and in the island under its header, as the hook lines
/// are (`HookDriftRows`). It shows from this build's first launch until ✕; "and N more" opens Settings › About with the
/// whole list, which About keeps. Nothing while no update opened this build, or when nothing was new.
struct WhatsNewCard: View {
    enum Size { case window, island }

    var size: Size = .window
    @Environment(AppEnvironment.self) private var env
    @Environment(\.juiceTheme) private var theme

    /// How many subjects the card lists before "and N more".
    static func limit(_ size: Size) -> Int { size == .window ? 4 : 3 }

    /// The dot before "What's new": the update's blue, the dark static Glass's tone nudges for each look (an adaptive
    /// twin would be read through its light side and move Glass in Dark).
    static let blue = Color(hex: 0x0A84FF)

    var body: some View {
        let controller = env.updateController
        if controller.showsWhatsNewCard, let note = controller.whatsNew {
            let lines = note.lines(limit: Self.limit(size))
            let font = Fonts.sys(size == .window ? 12 : 11)
            let palette = theme.island
            VStack(alignment: .leading, spacing: size == .window ? 4 : 2) {
                HStack(spacing: 6) {
                    Circle().fill(palette.tone(Self.blue)).frame(width: 6, height: 6)
                    Text(UpdateText.whatsNewTitle(automatic: controller.installedAutomatically)).font(font.weight(.semibold)).foregroundStyle(HookDriftLine.text(theme)).lineLimit(1)
                    Spacer(minLength: 8)
                    Button { controller.dismissWhatsNew() } label: {
                        CrossIcon(colour: HookDriftLine.dot(theme)).frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close What's new")
                }
                ForEach(Array(lines.shown.enumerated()), id: \.offset) { _, subject in
                    Text(subject).font(font).foregroundStyle(Self.subject(theme)).lineLimit(1).truncationMode(.tail)
                        .padding(.leading, 12)
                }
                if lines.more > 0 {
                    Button {
                        controller.showsWhatsNewList = true
                        env.actions.openSettings(.about)
                    } label: {
                        Text("and \(lines.more) more").font(font).foregroundStyle(palette.toneText(Self.blue))
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 12)
                    .help("Every change, in Settings › About")
                }
            }
            .padding(size == .window ? EdgeInsets(top: 8, leading: 22, bottom: 9, trailing: 18)
                                     : EdgeInsets(top: 2, leading: 8, bottom: 5, trailing: 4))
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                if size == .window { WindowTheme.hairline.frame(height: 1) }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("What's new")
        }
    }

    /// A subject's grey: Black's ink2 (#8E8E93), or the glass look's ink2 on Glass.
    static func subject(_ theme: JuiceTheme) -> Color { theme.adapts ? theme.island.ink2 : Color(hex: 0x8E8E93) }
}
